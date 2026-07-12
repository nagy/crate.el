# AGENTS.md — crate.el

## Overview

Single-package Emacs project (`crate.el`) providing an interactive
interface for browsing Rust crates from a local `static.crates.io`
JSON dump.  Browse URL handler integration redirects crates.io
URLs to `find-crate`.

## Build & test

```sh
nix-build --no-out-link default.nix          # build
emacs --batch -L . -l crate-tests.el -f ert-run-tests-batch-and-exit
```

Byte-compile with warnings as errors (wired into the Nix
build's checkPhase):

```sh
emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile crate.el
```

## Architecture

Files:

- `crate.el` — main package
- `ol-crate.el` — Org link support
- `crate-doc.nix` — Nix expression for rustdoc JSON builds
- `crate-tests.el` — ERT test suite
- `default.nix` — Nix build
- `emacs-screenshot.nix` — Nix expression for screenshot generation
- `README.org` — project README with screenshot
- `CONTEXT.md` — domain glossary
- `LICENSE` — AGPLv3
- `docs/adr/` — architectural decision records

### Rustdoc JSON pipeline

1. **`crate-doc.nix`** — companion Nix file. Uses a pinned crates.io-index
   to generate Cargo.lock offline (sandbox-safe), then crane + nightly
   rustc runs `cargo doc --output-format json`. Fully sandboxed.
2. **`crate-doc--build`** — calls `nix-build` synchronously, returns
   the Nix store output path.
3. **`crate-doc--json`** — parses the JSON, memoized with `:failed`
   sentinel to avoid retrying failed builds.
4. **`crate-doc--module-tree`** — pure function, parses JSON into nested
   `(NAME KIND (CHILDREN...) DOC)` tuples. `KIND` is a symbol (struct,
   trait, function, module, macro, enum, etc.).
5. **`insert-doc-tree`** — `cl-labels` helper in `crate-mode`. Renders
   the tree with indentation; shows doc summaries after leaf items,
   skips `:null`-named items (use imports).

### Tree tuple shape

The `crate-doc--module-tree` tuple always has 4 elements even when DOC
is nil. Callers must use `(cadddr item)` to get docs:

```elisp
;; Each tree item:
;;   (NAME KIND (CHILDREN...) DOC)
;;
;; Examples:
;;   ("foo" struct nil "A foo struct.")      ;; leaf with doc
;;   ("bar" function nil nil)                 ;; leaf without doc
;;   ("submod" module (("baz" ...)) nil)      ;; module with children
```

`crate.el` sections roughly:

1. Forward declarations and buffer-local state (`defvar-local`
   with `permanent-local` for `crate-name`, `crate-data`)
2. defgroup / defcustom (including `crate--crates-io-url`
   `defconst`)
3. Cache (hash-table vars, `with-memoization`, `crate-list-json`)
4. Doc Build (`crate-doc-enable` defcustom, `crate-doc--build`,
   `crate-doc--json`, `crate-doc--module-tree`)
5. Helpers (`crate--description`)
6. Faces (`defface` definitions, `crate-font-lock-keywords`)
7. Major Mode (`crate-mode`, derived from `text-mode`, with
   `cl-labels` local helper)
8. Completion (`crate--keys`, `crate--annotate`,
   `crate--collection`, `crate-refresh-cache`)
9. Marginalia (`crate--marginalia-annotator`, registered for
    `crate` category)
10. Interactive Commands (`find-crate`, `crate-browse-url`,
    `crate-install-browse-url-handler`)
11. Bookmarks (`crate--bookmark-make-record-function`,
    `crate-bookmark-jump`)
12. Org Integration (deferred load of `ol-crate`)
13. Browse Mode (`crate-browse-mode`, `crate-browse-crates`,
    bookmark support for filtered views)
14. Embark (action keymap `crate-embark-map`, export function,
    category registration)

## Conventions

### Byte-compiler silencing

External vars/faces from optional deps are declared with
`(defvar <var> nil)` with an explicit `nil` value.  Cross-file
function refs use `declare-function`.  Required deps get
`(require 'package)`.

### `cl-labels` for mode-local helpers

Helper functions that are only called from within a major mode
body should be defined as `cl-labels` closures scoped to the
mode, not as top-level `defun`s.  This keeps them private and
makes the mode self-contained.

```elisp
(define-derived-mode crate-mode text-mode "Crate"
  "Docstring."
  (cl-labels ((field (label key)
                (insert label)
                ...))
    (field "Homepage: " "homepage")
    ...))
```

### `permanent-local` for mode-surviving state

`define-derived-mode` calls `kill-all-local-variables`, which
wipes all buffer-local bindings before the mode body runs.
Variables set with `setq-local` before the mode call must carry
`(put 'var 'permanent-local t)` to survive the wipe:

```elisp
(defvar-local crate-data nil)
(put 'crate-data 'permanent-local t)

;; In find-crate:
(setq-local crate-data ...)  ; survives crate-mode's kill-all-local-variables
(crate-mode)
```

Without `permanent-local`, `crate-mode`'s body sees the default
value (nil) instead of the caller's value.

### Graceful load failures

`crate-list-json` wraps the entire file-load and JSON-parse in
`condition-case` so decompression failures, parse errors, and
missing files all silently return nil.  Callers (`find-crate`,
`crate--keys`) check for nil and either signal a `user-error` or
return an empty completion list.

```elisp
(condition-case nil
    (let ((raw (with-temp-buffer
                 (insert-file-contents path)
                 (goto-char (point-min))
                 (json-parse-buffer))))
      ;; ... build table ...)
  (error nil))
```

In `lexical-binding: t`, plain `let` evaluates all init forms in
the outer scope — later bindings cannot reference earlier ones.
Use `let*` when one binding's init form depends on a prior
binding.

```elisp
;; Wrong — desc can't see data
(let ((data (gethash key hash))
      (desc (gethash "description" data)))
  ...)

;; Correct
(let* ((data (gethash key hash))
       (desc (gethash "description" data)))
  ...)
```

### `declare` for pure functions

Functions with no I/O or global state should declare their purity:

```elisp
(declare (pure t) (side-effect-free t))
```

This enables the byte-compiler to optimize calls. Used on
`crate-doc--module-tree` and `crate-browse--entry`.

### `defconst` for shared strings

Non-configurable constants that appear in multiple places should
use `defconst`:

```elisp
(defconst crate--crates-io-url "https://crates.io/crates/"
  "Base URL for crates.io crate pages.")
```

### Completion conventions

The completion collection function (`crate--collection`) returns
`(metadata (category . crate) (annotation-function . ...))` for
the `metadata` action.  This gives Marginalia and Embark a
category to hook into.  Crate names are cached in
`crate--keys-cache` to avoid rebuilding the list from the JSON
hash on every keystroke.

### Memoization

JSON data and crate structure results use `with-memoization`
on `(gethash key hash-table)`.  Since the JSON dump is a
static file on disk, results never go stale.

```elisp
(with-memoization (gethash key cache)
  expensive-computation...)
```

`with-memoization` evaluates its place with `or` — if the body
returns nil, the computation re-runs every call.  For results
where nil is a valid "don't recompute" outcome, use a sentinel:

```elisp
;; Wrong — retries on nil (e.g. failed build)
(with-memoization (gethash name cache)
  (crate-doc--build name))

;; Correct — :failed caches the negative result
(let ((cached (with-memoization (gethash name cache)
                (or (crate-doc--build name)
                    :failed))))
  (unless (eq cached :failed)
    cached))
```

### Avoid `let-alist` on hash tables

`let-alist` expands to `(cdr (assq …))` — it works only on alists.
`json-parse-buffer` returns hash tables (the default).  Use
`gethash` directly when the source is a hash table.

```elisp
;; Wrong — json-parse-buffer returns a hash table, not an alist
(let-alist (json-parse-buffer) …)

;; Correct
(let ((result (json-parse-buffer)))
  (gethash "key" result) …)
```

### Faces

Six custom faces (`crate-name-face`, `crate-field-label`,
`crate-url`, `crate-date`, `crate-id`, `crate-description`)
inherit from `package.el`
or standard faces when available, with built-in fallbacks.  No
`(require 'package)` needed — the `:inherit` list resolves
left-to-right, skipping undefined faces.

### Org link support

Org link types live in `ol-crate.el`, loaded via
`(with-eval-after-load 'org (require 'ol-crate))`.  Cross-file
references to functions and variables from `crate.el` use
`declare-function` and `defvar` in `ol-crate.el`.

### Null guard in `when-let*` conditions

JSON `null` becomes the keyword `:null` from `json-parse-buffer`.
String functions like `string-replace` error on `:null`, so guard
against it in the `when-let*` binding, not in the body:

```elisp
;; Wrong — string-replace errors on :null before the if check
(when-let* ((it (gethash "key" data)))
  (setq it (string-replace "\n" "" it))
  (if (eq it :null) "" it))

;; Correct — guard rejects :null before string operations
(or (when-let* ((it (gethash "key" data))
                ((not (eq it :null))))
      (string-replace "\n" "" it))
    "")
```

### Test conventions

- `crate-test--data-hash` builds a mock `crate-data` hash table from
  keyword-value pairs (inner record, not keyed by crate name).
- `crate-test--crate-table` builds a mock top-level table keyed by
  crate name, suitable as the return value of `crate-list-json`.
- `crate-test--with-crate` macro binds `crate-name` and `crate-data`
  for testing functions that read those buffer-local variables.
- Mock `find-crate`, `switch-to-buffer`, and
  `org-link-store-props` with `cl-letf` on `symbol-function`.
- Hash tables with identical content are not `equal` in Elisp —
  compare individual `gethash` values instead.
- When mocking `org-link-store-props`, use a `&rest` lambda and
  `plist-get` to extract `:type` and `:link` — the real function
  uses `&key` which doesn't compose with `cl-letf` closures.
- Tests that need `browse-url-default-handlers` must `(require
  'browse-url)` first — `crate-install-browse-url-handler` uses
  `with-eval-after-load`, which is a no-op if browse-url isn't loaded.

## Dependencies

| Dependency | Required? | Why |
|-----------|-----------|-----|
| Emacs 30.1 | yes | `json-parse-buffer`, `with-memoization`, `string-replace`, `cl-labels` |
| ol (org) | soft | org link support via `ol-crate.el` |
| bookmark | yes | built-in, used for crate bookmarks |
| browse-url | soft | crates.io URL handler via `crate-install-browse-url-handler` |
| nix (external) | soft | required only when `crate-doc-enable` is t; runs `nix-build` on `crate-doc.nix` for on-demand rustdoc JSON |

## TODO

- **Completion-at-point for `Cargo.toml`** — provide crate name
  completion in `[dependencies]` sections of `Cargo.toml` buffers.
  Hook into `completion-at-point-functions` with a custom function
  that queries `crate--keys` for matching crate names.  Would make
  crate.el a genuine Rust developer tool.
- **Render rustdoc JSON in `crate-mode`** — parse the module tree
  from the JSON output of `crate-doc.nix` and display it in the
  crate detail buffer.  Done.
