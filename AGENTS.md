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

Byte-compile with warnings as errors (not yet wired into the Nix
build's checkPhase — add `turnCompilationWarningToError = true` and
a `checkPhase` once the test file is byte-compilable):

```sh
emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile crate.el
```

## Architecture

Files:

- `crate.el` — main package
- `ol-crate.el` — Org link support
- `crate-tests.el` — ERT test suite
- `default.nix` — Nix build

`crate.el` sections roughly:

1. defgroup / defcustom
2. Cache (hash-table vars, `with-memoization`, `crate-list-json`)
3. Helpers (`crate--description`, `crate--insert-field`)
4. Faces (`defface` definitions, `crate-font-lock-keywords`)
5. Major Mode (`crate-mode`, derived from `text-mode`)
6. Interactive Commands (`find-crate`, `crate-browse-url`,
   `crate-install-browse-url-handler`)
7. Bookmarks (`crate--bookmark-make-record-function`,
   `crate-bookmark-jump`)
8. Org Integration (deferred load of `ol-crate`)

## Conventions

### Byte-compiler silencing

External vars/faces from optional deps are declared with
`(defvar <var>)` without a value.  Cross-file function refs use
`declare-function`.

### Memoization

JSON data and crate structure results use `with-memoization`
on `(gethash key hash-table)`.  Since the JSON dump is a
static file on disk, results never go stale.

```elisp
(with-memoization (gethash key cache)
  expensive-computation...)
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

Five custom faces (`crate-name-face`, `crate-field-label`,
`crate-url`, `crate-date`, `crate-id`) inherit from `package.el`
or standard faces when available, with built-in fallbacks.  No
`(require 'package)` needed — the `:inherit` list resolves
left-to-right, skipping undefined faces.

### Org link support

Org link types live in `ol-crate.el`, loaded via
`(with-eval-after-load 'org (require 'ol-crate))`.  The store
function (`crate--org-store-link`) is defined in `ol-crate.el`
with `declare-function` and `defvar` for cross-file references.

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
- Mock `find-crate`, `crate-mode`, `switch-to-buffer`, and
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
| Emacs 30.1 | yes | `json-parse-buffer`, `with-memoization`, `string-replace` |
| ol (org) | soft | org link support via `ol-crate.el` |
| bookmark | yes | built-in, used for crate bookmarks |
| browse-url | soft | crates.io URL handler via `crate-install-browse-url-handler` |
| ansi-color | soft | used by `insert-crate-structure` for cargo-modules output |

## TODO

- **docs.rs fallback for missing documentation** — crates.io
  automatically links to `https://docs.rs/{name}` when a crate
  has no custom documentation URL.  Do the same: when the
  `documentation` field is null, insert
  `https://docs.rs/{crate-name}` as the documentation link.

- **Batch package metadata** — `crate-structure` invokes
  `cargo-modules` per-crate from a temp directory.  Potentially
  slow for crates with large dependency trees.  Consider caching
  or precomputing.

- **Tests in checkPhase** — wire `crate-tests.el` into
  `default.nix`'s checkPhase once the test file byte-compiles
  without warnings.

- **Tabulated list mode** — add a `crate-browse-crates` command
  showing all crates in a sortable `tabulated-list-mode` table
  (like nixos.el's `nixos-browse-options` / `nixos-browse-packages`).
  Use the `nixos--define-browse-mode` macro pattern.

- **Marginalia annotators** — register `crate` completion category
  annotator showing description and version in `marginalia`.

- **Embark integration** — add Embark export and action keymaps
  for crate candidates.
