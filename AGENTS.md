# AGENTS.md — crate.el

## Overview

Single-package Emacs project (`crate.el`) providing an interactive
interface for browsing Rust crates from a local crates.io SQLite
database.  Browse URL handler integration redirects crates.io
URLs to `find-crate`.

## Build & test

```sh
nix build                       # build
nix flake check                 # build + ERT suite
nix build .#screenshot          # regenerate README screenshot
nix build .#gitrepo             # bare .git dir holding the screenshot
emacs --batch -L . -l crate-tests.el -f ert-run-tests-batch-and-exit
```

Dev shell tools: Emacs, Nix, sqlite.

Flake outputs: `packages.crate` (= `default`) is `nix/default.nix`
(`melpaBuild`); its `checkPhase` runs the ERT suite against
`nix/test-crates-db.nix`.  `packages.screenshot` and `packages.gitrepo`
come from `nix/emacs-screenshot.nix`, which uses
`mkGitRepository` imported from the `nur-packages` flake input (not
vendored).

Byte-compile with warnings as errors (wired into the Nix
build's checkPhase for all elisp files — crate.el, ol-crate.el,
crate-tests.el):

```sh
emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile crate.el
```

## Architecture

Files:

- `crate.el` — main package
- `ol-crate.el` — Org link support
- `nix/crate-doc.nix` — Nix expression for rustdoc JSON builds
- `crate-tests.el` — ERT test suite
- `nix/default.nix` — package expression (`melpaBuild`)
- `nix/test-crates-db.nix` — fixture SQLite database for tests/screenshots
- `nix/emacs-screenshot.nix` — Nix expression for screenshot generation
- `flake.nix` — flake outputs; package expressions live under `nix/`
- `flake.lock` — pinned nixpkgs/flake-parts/nur-packages inputs
- `README.org` — project README with screenshot
- `CONTEXT.md` — domain glossary
- `LICENSE` — AGPLv3
- `docs/adr/` — architectural decision records

### Rustdoc JSON pipeline

1. **`nix/crate-doc.nix`** — companion Nix file. Uses a pinned crates.io-index
   to generate Cargo.lock offline (sandbox-safe), then crane + nightly
   rustc runs `cargo doc --output-format json`. Fully sandboxed.
2. **`crate-doc--start-build`** — spawns `nix-build` ASYNCHRONOUSLY via
   `make-process` (Emacs never blocks; cold builds take minutes).
   Missing `nix-build`, missing `crate-doc.nix`, or a spawn failure
   caches the `:failed` sentinel (graceful degradation: status line,
   `find-crate` unaffected).  A second request for the same crate
   reuses the in-flight build; the generation counter
   (`crate-doc--generation`, bumped by `crate-refresh-cache`) makes
   the sentinel discard stale results.  On completion the sentinel
   re-renders the crate buffer via `crate-doc--json-from-build`,
   which extracts the store path and parses the non-driver JSON.
   `crate-doc--nix-path` looks for
   `crate-doc.nix` next to `crate.el` and then in `nix/` (the source
   tree keeps the file under `nix/`).
3. **`crate-doc--json`** — cache lookup only (path-keyed); starts an
   async build on miss and returns nil (the buffer shows "build in
   progress" and re-renders on completion).  `:failed` sentinel
   avoids retrying failed builds.
4. **`crate-doc--module-tree`** — pure function, parses JSON into nested
   `(NAME KIND (CHILDREN...) DOC)` tuples. `KIND` is a symbol (struct,
   trait, function, module, macro, enum, etc.).
5. **`insert-doc-tree`** — `cl-labels` helper in `crate-mode`. Renders
   the tree with indentation, each item prefixed with its KIND as a
   bracketed tag (`- [struct] name`, fontified via
   `crate-font-lock-keywords`); shows doc summaries after leaf items,
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
3. Cache (hash-table vars, `with-memoization`, cache keys include
   `crate-data-path` for self-invalidation)
4. Doc Build (`crate-doc-enable` defcustom, `crate-doc--start-build`,
   `crate-doc--json-from-build`, `crate-doc--json`,
   `crate-doc--module-tree`)
5. Helpers (`crate--description`, `crate--deps`, `crate--dependents`,
   `crate--format-downloads`)
6. Faces (`defface` definitions, `crate-font-lock-keywords`)
7. Major Mode (`crate-mode`, derived from `special-mode` for
   read-only + `q`/`g` conventions, thin: only
   `setq-local` for font-lock defaults, bookmark record function, and
   `revert-buffer-function`; content is inserted by `crate--render`,
   which uses the `crate-name` / `crate-data` buffer-locals)
8. Completion (`crate--match-names`, `crate--annotate`,
   `crate--collection`, `crate-refresh-cache`)
9. Marginalia (`crate--marginalia-annotator`, registered for
    `crate` category)
10. Interactive Commands (`find-crate`, `crate-browse-url`,
    `crate-install-browse-url-handler`; `find-crate` is the single
    funnel for all entry points — interactive, URL handler, browse
    visit, bookmarks, dependency buttons — and runs
    `crate-visit-hook` at the end, after `crate-name` and
    `crate-data` are set and the buffer rendered)
11. Bookmarks (`crate--bookmark-make-record-function`,
    `crate-bookmark-jump`)
12. Org Integration (deferred load of `ol-crate`)
13. Browse Mode (`crate-browse-mode`, `crate-browse-crates`,
    bookmark support for filtered views)
14. Dependency Copy (`crate-copy-dependency`, bound to `w` in
    `crate-mode-map`, `crate-browse-mode-map`, and
    `crate-embark-map`; copies `NAME = "VERSION"` for
    `Cargo.toml`)
15. Cargo.toml Integration (`crate-cargo-completion-at-point`,
    `crate-install-cargo-toml-capf`, `crate-cargo-toml-modes` —
    crate-name completion in `[dependencies]` family sections,
    soft TOML-mode dep via the modes list)
16. Embark (action keymap `crate-embark-map`, export function,
    category registration)

## Conventions

### Byte-compiler silencing

External vars/faces from optional deps are declared with a
value-less `(defvar <var>)` to silence the byte-compiler without
clobbering the real default value (which would be lost if the
package loads before the dependency).  Cross-file function refs
use `declare-function`.  Required deps get `(require 'package)`.

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
`crate-name` and `crate-data` dodge this by being set *after*
`crate-mode` in `find-crate` (mode first, then `setq-local`, then
`crate--render`), so they need no `permanent-local`.

`permanent-local` is still used where state must survive a
re-entrant mode call — the browse-mode filters:

```elisp
(defvar-local crate-browse--name-list nil)
(put 'crate-browse--name-list 'permanent-local t)
```

Variables set with `setq-local` *before* a mode call that wipes
locals must carry `(put 'var 'permanent-local t)` to survive:

```elisp
;; In find-crate (after the separation refactor):
(crate-mode)
(setq-local crate-name cand)   ; set after the wipe — survives
(setq-local crate-data entry)
(crate--render)
```

### Graceful load failures

`crate-list-json` wraps the entire file-load and JSON-parse in
`condition-case` so decompression failures, parse errors, and
missing files all silently return nil.  Callers (`find-crate`,
`crate--keys`) check for nil and either signal a `user-error` or
return an empty completion list.  `find-crate` blames the
configuration first ("No crate database configured" / "unreadable")
before any name lookup, so a missing DB never masquerades as a
missing crate.

SQLite handles close via `unwind-protect`, never `prog1` — a query
error must not leak the handle.

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
`crate-doc--module-tree`, `crate-browse--entry`, and
`crate-browse--entry-less`.

`crate-browse--entries` sorts entries by name with
`crate-browse--entry-less` so the initial browse display is
deterministic (hash iteration order is unspecified).

### `defconst` for shared strings

Non-configurable constants that appear in multiple places should
use `defconst`:

```elisp
(defconst crate--crates-io-url "https://crates.io/crates/"
  "Base URL for crates.io crate pages.")
```

### Canonical crate names

`crate--list` keys its hash by `crate--canonical-name` (downcase,
hyphens to underscores), so every lookup canonicalizes input and
stays single-form.  The entry's `"name"` field holds the published
crate name — display, completion candidates, and URLs use it,
never the hash key.  `"display_name"` holds the pretty form.

### Completion conventions

The completion collection function (`crate--collection`) returns
`(metadata (category . crate) (annotation-function . ...))` for
the `metadata` action.  This gives Marginalia and Embark a
category to hook into.  Candidate names come from per-keystroke
SQL prefix queries (`crate--match-names`) — no full name list
materializes, so completion scales to a full crates.io dump.
LIKE wildcards in user input are escaped (`crate--sql-like-escape`)
since `_` is a valid crate-name character; the prefix pattern
matches the `complete-with-action' contract, and completion styles
query with their own strings and filter further on top.

### Memoization

JSON data and crate structure results use `with-memoization`
on `(gethash key hash-table)`.  Since the SQLite database is a
static file on disk, results never go stale — but they DO go
stale across `crate-data-path` switches, so every cache key
includes the path (`(list 'data crate-data-path)`, `(list 'deps
path name)`, `(list name path)`, `(list 'keys path)`).  Plain
`setq` of `crate-data-path` then self-invalidates; no defcustom
`:set` function needed.

```elisp
(with-memoization (gethash key cache)
  expensive-computation...)
```

`with-memoization` evaluates its place with `or` — if the body
returns nil, the computation re-runs every call.  For results
where nil is a valid "don't recompute" outcome, use a sentinel:

```elisp
;; Wrong — retries on nil (e.g. failed query)
(with-memoization (gethash key cache)
  (crate--deps name))

;; Correct — :failed caches the negative result
(let ((cached (with-memoization (gethash key cache)
                (or (crate--deps name)
                    :failed))))
  (unless (eq cached :failed)
    cached))
```

The async doc-build path (`crate-doc--json`) reads the cache
directly instead — `with-memoization` fits synchronous computation
only.

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

### Faces, display faces, and font-lock keywords

Nine custom faces (`crate-name-face`, `crate-field-label`,
`crate-url`, `crate-date`, `crate-id`, `crate-version`,
`crate-license`, `crate-description`) inherit from `package.el`
or standard faces when available, with built-in fallbacks.  No
`(require 'package)` needed — the `:inherit` list resolves
left-to-right, skipping undefined faces.

**Value faces must be declared as `crate-font-lock-keywords` rules,
not set via `propertize`.  `crate-mode` calls `font-lock-ensure`
after rendering, so a `face` text property on text that no keyword
matches is wiped by re-fontification (a plain `propertize` face on
the version value becomes nil).  This is why the version/date/id/
description/URL value faces all live in `crate-font-lock-keywords`
as `(1 'face)` group 1 rules on `^Label:[[:space:]]+` patterns.
Where a text property is genuinely needed (e.g. `mouse-face` on
URLs), use non-`face` properties.

### `thing-at-point` URL provider for dependency names

Dependency crate-name buttons in `crate-mode` carry a `crate-url`
text property set to their crates.io URL.  `crate-mode` installs a
buffer-local `thing-at-point-provider-alist` entry for `url` whose
provider (`crate--thing-at-point-url`) reads that property, so
`thing-at-point \\='url'` and `browse-url-at-point` treat a dependency
name as a link to its crates.io page:

```elisp
;; In crate-mode body:
(setq-local thing-at-point-provider-alist
            (cons '(url . crate--thing-at-point-url)
                  thing-at-point-provider-alist))

;; Tag each dependency button with its URL:
(insert-text-button dname
                    'action (lambda (_) (find-crate dname))
                    'face 'crate-url
                    'crate-url (concat crate--crates-io-url dname))
```

`thing-at-point-provider-alist` is defined by `thingatpt`, which
`crate.el` requires explicitly — a value-less `defvar` alone leaves
the variable void and `setq-local` signals in a bare Emacs.  The
provider only uses text properties at point, so it returns nil on
any non-button text.

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
- Bookmark handler tests must pass the full record shape
  `(NAME (prop . val) ...)` — `bookmark-prop-get` returns nil on
  bare alists (no name-string car), matching what
  `bookmark-handle-bookmark` really passes to handlers.
- Tests that need `browse-url-default-handlers` must `(require
  'browse-url)` first — `crate-install-browse-url-handler` uses
  `with-eval-after-load`, which is a no-op if browse-url isn't loaded.
- Hyphenated-name tests use `crate-test--sqlite-db` with a row
  named e.g. `async-trait`; assert published names surface while
  lookups accept both forms.
- `crate-visit-hook` tests bind the hook to nil locally and
  `add-hook` their lambda, then assert on `(buffer-name)`, `crate-name`,
  and `crate-data` inside the hook — verifying it fires once per
  `find-crate` call, in the crate buffer, after locals are set.

## Dependencies

| Dependency | Required? | Why |
|-----------|-----------|-----|
| Emacs 30.1 | yes | `json-parse-buffer`, `with-memoization`, `string-replace`, `cl-labels` |
| ol (org) | soft | org link support via `ol-crate.el` |
| bookmark | yes | built-in, used for crate bookmarks |
| browse-url | soft | crates.io URL handler via `crate-install-browse-url-handler` |
| nix (external) | soft | required only when `crate-doc-enable` is t; runs `nix-build` on `nix/crate-doc.nix` for on-demand rustdoc JSON |

## TODO

None right now.  The former Cargo.toml completion-at-point TODO
shipped as section 15.
