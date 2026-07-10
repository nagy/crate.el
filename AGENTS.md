# AGENTS.md — crate.el

## Overview

Single-package Emacs project (`crate.el`) providing an interactive
interface for browsing Rust crates from a local `static.crates.io`
JSON dump.  Browse URL handler integration redirects crates.io
URLs to `find-crate`.

## Architecture

Single file (`crate.el`), sections roughly:

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

## Dependencies

| Dependency | Required? | Why |
|-----------|-----------|-----|
| Emacs 30.1 | yes | `json-parse-buffer`, `with-memoization`, `string-replace` |
| ol (org) | soft | org link support via `ol-crate.el` |
| bookmark | yes | built-in, used for crate bookmarks |
| ansi-color | soft | used by `insert-crate-structure` for cargo-modules output |
