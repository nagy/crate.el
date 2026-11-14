# AGENTS.md — crate.el

## Overview

Single-package Emacs project (`crate.el`) providing an interactive
interface for browsing Rust crates from a local crates.io SQLite
database.  Browse URL handler integration redirects crates.io
URLs to `find-crate`.

## Build & test

```sh
nix build                       # build
nix flake check                 # build + ERT suites + lint
nix build .#screenshot          # regenerate README screenshot
nix build .#gitrepo             # bare .git dir holding the screenshot
emacs --batch -L . -L test -l test/crate-test.el -f ert-run-tests-batch-and-exit
emacs --batch -L . -L test -l test/evil-crate-test.el -f ert-run-tests-batch-and-exit
```

Dev shell tools: an Emacs wrapper that carries `magit-section` and
`evil` on its load path, plus Nix and sqlite, so both suites and the
byte-compile command below run in a plain shell.

Test layout: `test/` holds one suite per source file, named
`<unit>-test.el`, plus `test/crate-test-helper.el` for the shared
fixtures.  The helper name never matches `*-test.el`, because the
`checkPhase` loads the suites through a `test/*-test.el` glob.  A new
suite therefore needs no Nix edit, and a suite pulls the fixtures in
with `(require 'crate-test-helper)`.

Flake outputs: `packages.crate` (= `default`) is `nix/default.nix`
(`melpaBuild`); its `checkPhase` runs both ERT suites against
`nix/test-crates-db.nix`.  `melpaBuild` propagates `packageRequires`
but does not put it on the load path of the build, so `preBuild`
prepends an `emacsWithPackages` wrapper that carries `magit-section`
and `evil` to `PATH`; the wrapper sets `EMACSLOADPATH` itself.  The
package declares `magit-section` and declares no dependency on evil,
which only `evil-crate.el` needs.  `packages.screenshot` and
`packages.gitrepo` come from `nix/emacs-screenshot.nix`, which uses
`mkGitRepository` imported from the `nur-packages` flake input (not
vendored).  `checks.lint` comes from `nix/lint.nix`: checkdoc plus
package-lint over `*.el` and `test/*.el`.

The version follows the house scheme for an unreleased package:
`0.1.0-unstable-<commit date>`.  The flake derives the date from
`self.sourceInfo.lastModifiedDate` and passes it to the package
expression; `postPatch` writes the same string into the `;; Version:`
header of `crate.el`, so the header and the package directory agree.

Byte-compile with warnings as errors (wired into the Nix
build's checkPhase for all elisp files — crate.el, ol-crate.el,
evil-crate.el and every file under `test/`):

```sh
emacs --batch -L . -L test --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile crate.el
```

## Architecture

Files:

- `crate.el` — main package
- `ol-crate.el` — Org link support
- `evil-crate.el` — optional evil layer (soft dependency)
- `nix/crate-doc.nix` — Nix expression for rustdoc JSON builds
- `nix/lint.nix` — checkdoc plus package-lint gate (`checks.lint`)
- `test/crate-test.el` — ERT suite of the main package
- `test/crate-test-helper.el` — shared fixtures and stubs
- `test/evil-crate-test.el` — ERT suite of the evil layer
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
5. **`crate-insert-module-items`** — recursive inserter inside the
   Modules section.  Writes the tree with two spaces of indentation
   per level and a bracketed KIND tag (`  - [struct] name`, fontified
   through `crate-font-lock-keywords`), shows a doc summary after a
   leaf item, skips `:null`-named items (use imports), and opens one
   `crate-module` section per item whose value is the full path, so a
   fold and the line of point survive a render.

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
   `defconst`, and the limit custom options `crate-completion-limit`
   and `crate-dependents-limit`)
3. Cache (hash-table vars, `with-memoization`, cache keys include
   `crate-data-path` for self-invalidation; `crate--list` for the
   whole table, `crate--crate` for one record, `crate--crates-columns`
   and its two SQL constants)
4. Doc Build (`crate-doc-enable` defcustom, `crate-doc--start-build`,
   `crate-doc--json-from-build`, `crate-doc--json`,
   `crate-doc--module-tree`)
5. Helpers (`crate--description`, `crate--deps`, `crate--dependents`,
   `crate--dependents-data`, `crate--format-downloads`)
6. Faces (`defface` definitions, `crate-font-lock-keywords`)
7. Text Buttons and Point Keeping (`crate-link` button type,
   `crate--line-record` and the restore helpers, which keep point
   across the erase of a render)
8. Sections (`crate-detail-sections-hook`, `crate-detail-fields`, and
   the inserters `crate-insert-fields`, `crate-insert-field`,
   `crate-insert-dependencies`, `crate-insert-dependents`,
   `crate-insert-modules`, `crate-insert-module-items`)
9. Major Mode (`crate-mode`, derived from `magit-section-mode` for
   the section tree, the folds and the keymap, plus `special-mode`
   read-only + `q`/`g` conventions; thin: only `setq-local` for
   font-lock defaults, the two section options, `goto-address-mode`,
   the bookmark record function and `revert-buffer-function`; `RET`
   is `push-button`; content is inserted by `crate--render`, which
   uses the `crate-name` / `crate-data` buffer-locals)
10. Completion (`crate--match-names`, `crate--annotate`,
   `crate--collection`, `crate-refresh-cache`)
11. Marginalia (`crate--marginalia-annotator`, registered for
    `crate` category)
12. Interactive Commands (`find-crate`, `crate-browse-url`,
    `crate-install-browse-url-handler`; `find-crate` is the single
    funnel for all entry points — interactive, URL handler, browse
    visit, bookmarks, dependency buttons — and runs
    `crate-visit-hook` at the end, after `crate-name` and
    `crate-data` are set and the buffer rendered; the window comes
    from `crate-display-buffer-action`; the record comes from
    `crate--crate`, so a visit reads one row)
13. Bookmarks (`crate--bookmark-make-record-function`,
    `crate-bookmark-jump`)
14. Org Integration (deferred load of `ol-crate`)
15. Evil Integration (deferred load of `evil-crate` when evil loads,
    and the `crate-evil-auto-setup` call)
16. Browse Mode (`crate-browse-mode`, `crate-browse-crates`,
    bookmark support for filtered views)
17. Dependency Copy (`crate-copy-dependency`, bound to `w` in
    `crate-mode-map`, `crate-browse-mode-map`, and
    `crate-embark-map`; copies `NAME = "VERSION"` for
    `Cargo.toml`)
18. Cargo.toml Integration (`crate-cargo-completion-at-point`,
    `crate-install-cargo-toml-capf`, `crate-cargo-toml-modes` —
    crate-name completion in `[dependencies]` family sections,
    soft TOML-mode dep via the modes list)
19. Embark (action keymap `crate-embark-map`, export function,
    category registration)

## Conventions

### Byte-compiler silencing

External vars/faces from optional deps are declared with a
value-less `(defvar <var>)` to silence the byte-compiler without
clobbering the real default value (which would be lost if the
package loads before the dependency).  Cross-file function refs
use `declare-function`.  Required deps get `(require 'package)`.

### `cl-labels` for mode-local helpers

Helper functions that only a major mode body calls belong in a
`cl-labels` closure, not in a top-level `defun`.  The closure keeps
them private and makes the mode self-contained.

**A section inserter is the exception.**  It carries a `crate-`
prefix, takes no arguments and lives at top level, because a user
reorders it in `crate-detail-sections-hook` and calls it by name.
`crate-insert-field` and `crate-insert-module-items` follow that
rule.

```elisp
;; Top-level, because the hook names it:
(defun crate-insert-dependents ()
  "Insert the Dependents section of the current crate."
  ...)

;; Mode-local, because nothing outside the body calls it:
(cl-labels ((field-key (line) ...))
  ...)
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

`pure` means the result depends on the arguments only, so a
function that reads a variable (a defcustom, a buffer-local, a
face) must not carry it.  Such a function gets `side-effect-free`
alone: the compiler may drop a call whose value nothing uses, but
must not fold the call:

```elisp
(defun crate-browse--entry (name data)
  "Return a `tabulated-list' entry for crate NAME with DATA."
  ;; reads `crate-annotation-width' and the faces
  (declare (side-effect-free t))
  ...)
```

A function that writes a hash table, a file, or a buffer has
neither declaration (`crate--list`, `crate-browse--reload`).

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

`crate--canonical-name` (downcase, hyphens to underscores) is the
single lookup form.  `crate--list` keys its hash by it, and
`crate--crate` keys its cache by it.  The entry's `"name"` field
holds the published crate name — display, completion candidates,
and URLs use it, never the canonical form.  `"display_name"`
holds the pretty form.

A canonical form is not a published name, so `crate--crate` asks
for both spellings (`crate--crate-spellings`): `async-trait` and
`async_trait`.  Two spellings suffice, measured on a full dump of
358 423 names: no published name mixes both separators, and no two
names share a canonical form.

### One crate record, not the whole table

`crate--crate` reads one row through the `name` primary-key btree
and memoizes that record.  `crate--list` reads every row into one
hash table per crate, and a full dump makes that 358 423 hash
tables: 1.8 s and +647 MiB of resident memory.  So the single-crate
path takes `crate--crate` — `find-crate`, `crate--annotate`,
`crate-doc--json`, `crate-copy-dependency`.  Only a view that needs
every crate takes `crate--list` (`crate-browse--entries` without a
name list, `crate--filter-by-name`), and it keeps the whole table.

Measured on the 422 MB dump, `find-crate` for serde went from
5.27 s to 0.09 s and from 1 022 MiB to 146 MiB.

`crate--database-readable-p` separates two answers that
`crate--crate` reports alike: a missing crate and an unreadable
database both return nil.  `find-crate` asks it only on the nil
path, so a missing crate still blames the name and a corrupt file
still blames the path.

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

**`crate--match-names` turns on `case_sensitive_like`.**  `LIKE`
compares case-insensitively by default, and that keeps SQLite off
the `name` primary-key btree: `EXPLAIN QUERY PLAN` answers `SCAN
crates`, and one keystroke costs 50 ms on a full dump.  All
published names are lowercase, so the connection sets the pragma
and the prefix is downcased first.  The query then walks the btree
and `crate-completion-limit` stops the walk: 0.03 ms.

**Every candidate costs a row fetch, so the query stops at a
limit.**  A prefix of one letter matches tens of thousands of
names (35 628 under `s`), and each candidate also asks for its
description through `crate--annotate`.  `crate-completion-limit`
(default 200) caps that; a nil value fetches every match.

### Memoization

JSON data and crate structure results use `with-memoization`
on `(gethash key hash-table)`.  Since the SQLite database is a
static file on disk, results never go stale — but they DO go
stale across `crate-data-path` switches, so every cache key
includes the path (`(list 'data crate-data-path)`, `(list 'crate
path canonical)`, `(list 'deps path name)`, `(list name path)`,
`(list 'keys path)`).  Plain
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

**A cached result that is a list of names must not be nil.**
`crate--dependents-data` stores `(NAMES . TRUNCATED)`, and a crate
that nothing depends on stores `(nil . nil)` — a cons survives the
`or` of `with-memoization`, a bare nil does not.  `crate--deps`
solves the same problem with the `:failed` sentinel in reverse: it
lets an empty row list recompute, which costs one indexed query of
0.3 ms.

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

Eight custom faces (`crate-name-face`, `crate-url`, `crate-date`,
`crate-id`, `crate-version`, `crate-license`, `crate-description`,
`crate-field-label`) inherit from `package.el` or standard faces when
available, with built-in fallbacks.  No `(require 'package)` needed —
the `:inherit` list resolves left-to-right, skipping undefined faces.

A field label and a section heading read unlike each other on purpose.
A field label keeps its trailing colon and takes `crate-field-label`.
A section heading carries no colon and takes `magit-section-heading`,
the face of every Magit heading, so the sections of a crate buffer
read like a Magit buffer.  A module name is the content of the section
above it, so it takes the `default` face.

**Every face must be declared as a `crate-font-lock-keywords` rule,
never set via `propertize`.  `crate-mode` calls `font-lock-ensure`
after rendering, and that call unfontifies the buffer first, which
removes a `face` property *and* a `font-lock-face` property from text
that no keyword matches.**  So a plain `propertize` face on a module
name or a doc summary does not survive, and neither does the
`font-lock-face` that `magit-insert-heading` paints.  Hence the label,
group heading, kind tag, module name and doc summary rules all live
in `crate-font-lock-keywords`, and a rule needs an anchor in the text:
the `- ` bullet of a module line is that anchor for the module tree.

### Links in a detail buffer

`crate-mode` enables `goto-address-mode` through the
`crate-goto-address` option, which defaults to t.  The minor mode
links the homepage, repository and documentation URLs, so the
renderer adds no link of its own: `goto-address` marks a URL with
an evaporating overlay that carries the mouse face, the `RET` and
`mouse-2` keys and the help text.  A renderer never sets
`mouse-face` on a URL, because an overlay survives re-fontification
and a text property that hints at a link without an action only
misleads.

`RET` in `crate-mode-map` is `push-button`, the built-in command.
Emacs 31 `push-button` returns nil on text without a button and does
not signal, so a plain line answers nothing.  The `keymap` text
property of a `crate-link` button wins over the major mode map at a
link, and the `goto-address` overlay of a URL keeps its own bindings.

### Point keeping across a render

`crate--render` erases the buffer, so it records the line of point
before the render and restores it after the render
(`crate--window-records`, `crate--restore-window-records`).  The record
names a **section** and not a buffer position: the section object at
point, the distance in lines from the start of that section and the
column (`crate--line-record`).  `magit-section-goto-successor` finds
the section again through `magit-section-ident`, which walks the type
and value of the section and its parents, so a re-render that makes
new objects still finds the same place.  A line without a section
holds no record, and a section that the render dropped leaves point at
`point-min`.

The record covers the buffer point and the point of every window that
shows the buffer.  The buffer record is a cons with nil in place of a
window, because a buffer can show in no window.  The restore for a
window runs inside `save-excursion`: a window keeps the point of the
buffer point, so a restore must not move the buffer point while it
serves another window.

A section value that a render keeps must stay stable across renders.
A field carries its key, a module carries its full path, and a group
carries nil.  A module path and not a bare name, because two modules
of different parents can share a name.

A line inside a section body keeps its line offset and not its text.
A dependency row is a line of the Dependencies section and not a
section of its own, so a new row above point moves point to the row
that now sits on its line
(`crate-mode-render-keeps-the-line-inside-a-section` covers that).
Give a row its own section only if it needs its own identity.

### Sections and folds

A detail buffer is a tree of `magit-section` sections, and
`crate-mode` derives from `magit-section-mode`.  `crate--render`
erases the buffer, opens one `crate-detail` root section, and runs
`crate-detail-sections-hook` through `magit-run-section-hook`.  Every
inserter uses `magit-insert-section` and writes its heading through
`magit-insert-heading`, so a heading line, the `TAB` fold, the section
motions (`n`, `p`, `^`, `1`-`4`), the current-section highlight and
the fringe click all come from `magit-section`.

**`crate-detail-sections-hook` is the one extension point for the
section list.**  A user reorders or drops a section with `setopt` or
`add-hook`, and `crate-detail-fields` does the same for the field
lines.  An inserter takes no arguments and reads the `crate-name` and
`crate-data` buffer-locals.  Do not add a second `defcustom` that
lists sections.

**`magit-section-inhibit-markers` stays t.**  A section records the
start and end of its region, and a marker per end makes a render
quadratic in the size of the module tree: 4000 nested sections take
1.4s with markers and 0.06s without, because each insert has to move
every later marker.  A crate buffer inserts once and then only reads,
so plain positions serve until the next render rebuilds them.

**`magit-section-show-child-count` stays at its default.**  A reader
decides whether a heading carries its count, and `crate-mode` never
binds it.

**A heading carries no colon.**  With markers inhibited the automatic
child count rewrites the heading of a section that ends in a colon
*after* the children record their positions, which leaves those
positions short by the width of the count, and a fold of the Modules
section would then leave the tail of the heading visible.

**The count goes into the heading string before the body starts.**
`crate-insert-dependencies`, `crate-insert-dependents` and
`crate-insert-modules` pass the number through `crate--child-count` to
`magit-insert-heading`, which writes ` (N)` at once, paints it with
`magit-section-child-count` and reads
`magit-section-show-child-count` itself.  So no later insert moves a
child position.  `crate--child-count` answers nil for a zero count and
for a reader who turned the option off, so no heading carries a zero.
`crate--module-count` drops the `:null`-named use imports, which
insert no section.

**The Dependents section stops at `crate-dependents-limit`.**  A
popular crate has over a hundred thousand dependents (serde has
135 172), and one text button per dependent costs 1.3 s to render.
`crate--dependents-data` asks SQLite for one name past the limit,
so the section pays for no count it never shows, and the heading
marks the cut list `(200+)`.  `magit-insert-heading` formats a
count it receives, so that heading carries its two faces itself:
the section face on the label and `magit-section-child-count` on
the number.

A covering index `(dep_name, crate_name)` on `dependencies` would
make the capped query stream, measured 90 ms to 0.2 ms on the full
dump, at the cost of +86.5 MB.  The stock crates.io dump does not
carry it, and the query is memoized per crate, so the code does
not need it.

**The folds need no code of their own.**  A section keeps its
visibility by ident in `magit-section-visibility-cache`, so
`crate--render` only has to end with
`(magit-section-show magit-root-section)` under
`(let ((magit-section-cache-visibility nil)) ...)`.  That binding
keeps the cache small: an entry appears only for a section that a user
folded or unfolded, and the hook that reads the cache walks only those
entries.

`crate-link-map` keeps a `TAB` entry, now `magit-section-toggle`: a
dependency row is both a button and a line of the Dependencies
section, and the `keymap` text property of a button wins over the
major mode map.  Without the entry `TAB` on a link would run the
`button-map` command `forward-button`.

`evil-fold-list` holds no `magit-section-mode` entry, and
`evil--mode-p` compares the major mode name itself, so a detail buffer
needs a `crate-mode` entry.  `evil-crate.el` adds one, with lambdas,
because `magit-section-toggle` and its siblings take the section as an
argument.

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
                    :type 'crate-link
                    'action (lambda (_) (find-crate dname))
                    'crate-url (concat crate--crates-io-url dname))
```

`thing-at-point-provider-alist` is defined by `thingatpt`, which
`crate.el` requires explicitly — a value-less `defvar` alone leaves
the variable void and `setq-local` signals in a bare Emacs.  The
provider only uses text properties at point, so it returns nil on
any non-button text.

`crate-browse-mode` installs its own provider,
`crate-browse--thing-at-point-url`, for the `url` thing.  The name
cell of a row carries `crate-url`, and every other cell answers
through the entry ID of the row, so `C-c C-o`
(`browse-url-at-point') follows the crate of any cell.  The name cell
and not the whole row carries the property, because `equal` on a cell
and a bare string must stay true, and the export of a row strips the
properties anyway.

### One text button type for links

`crate-link` is the one text button type for a link: it carries the
`crate-url` face, the `mouse-face`, the `follow-link` rule and a
default `help-echo`.  A renderer writes `:type 'crate-link` and the
properties that differ — the `action` and the tooltip — so the
pointer highlights every link the same way and no call repeats a
mouse face.  A crate link keeps its own `action` (`find-crate`) and
keeps `crate-url` for the `thing-at-point` provider.  A URL link
falls back to the default action (`crate--button-url`), which opens
the `crate-url` in a browser.

### Browse table reload

`crate-browse--reload' rebuilds `tabulated-list-entries' from the
buffer-local `crate-browse--name-list', and `crate-browse-mode'
adds it to `tabulated-list-revert-hook' buffer-locally, so `g'
(`revert-buffer') keeps the filter.  No `revert-buffer-function'
override and no refresh defun exist.  `crate-browse-crates' calls
`crate-browse--reload' before its first print.  It then refits the
columns (`crate-browse--fit-format'), so the content widths follow
the new data instead of staying stale.  The fit picks the window
that shows the buffer, and the selected window when none does.

**A column SORT element may be a predicate** over entries, and the
Version column uses `crate-browse--version-lessp'.  The built-in
`t' sorts the cell strings, which puts "1.10.0" before "1.9.0".
Do not swap in `version<': it signals "Invalid version syntax" on
any pre-release ("1.0.0-rc.1"), and crates.io publishes those.
`crate--version-lessp' parses semver itself (`crate--version-parts`
plus `crate--semver-pre-lessp`), drops build metadata, falls back
to `string<' on garbage, and sorts an empty version last.
`crate--version-parts' makes the minor and patch segments optional
and pads them with 0, because a few old crates publish `0.1' and
that value must not fall through to the string comparison (`0.9'
would then land after `0.10').
`crate-browse--cell-text' is the one reader of a cell that may be
a string or a `(LABEL . PROPS)' cons.

**A table fits its columns to its window.**
`crate-browse--fit-widths' shrinks a middle column to 8 and then
the Crate column to `crate-browse-name-min-width', so the last
column keeps `crate-browse-description-min-width'.
`crate-browse-mode' stores the widths it declares in
`crate-browse--declared-widths'; `crate-browse--fit-format` builds
the base widths from them and records `crate-browse--canonical-widths',
and every later fit starts there, so a resize in either direction
lands right.  The browse command fits before its first print,
because that print lands in the selected window.  A frame resize
schedules one refit per buffer through `run-at-time' (redisplay
runs `window-size-change-functions'), and the refit reprints only
when a width changed.  The refit reprints, and `tabulated-list-print'
sorts the entries again, so `crate-browse-refit-max-entries' skips a
table above that size (nil refits every table).  A full crates.io
dump keeps the widths of its last fit instead of stalling on a
resize.  `tabulated-list-format' is buffer-local, so
one width serves every window, and a manual resize lasts until the
next frame resize.

The Version column widens to the longest visible version through
`crate-browse--content-widths', capped by
`crate-browse-version-max-width'.  It reads
`crate-browse--declared-widths', never a fitted or bookmarked
value, so no feedback loop exists.

**`{` and `}` come from `tabulated-list-mode-map`** (bound to
`tabulated-list-narrow-current-column` and
`tabulated-list-widen-current-column`).  crate.el declares no resize
command of its own: a wrapper here would only repeat them.

**`crate-display-buffer-action' picks the window of a detail
buffer.**  nil keeps `switch-to-buffer' (the original behavior and
what most tests assume); any other value goes to `pop-to-buffer'
as its display action.  `crate--other-window-action' is the action
for "open a crate beside the table": it reuses a window that
already shows the buffer, else splits, and never uses the selected
window.  Emacs has no `display-buffer-other-window' function, so do
not reach for it.

**`tabulated-list-printer' is `crate-browse--print-entry`.**  It
paints `help-echo` on the whole row and `mouse-face` on the name
cell alone, so the pointer highlights one cell.  `<follow-link>` is
`crate-browse--click-selects-row`, which returns nil: with the
`tabulated-list-mode-map` default (`mouse-face`) a click on the
highlighted name would turn into a `mouse-2` event and open a
detail buffer.  `context-menu-functions` carries
`crate-browse--context-menu` buffer-locally, guarded by `boundp`.
A menu click leaves point alone, so each menu command wraps
`crate-browse--context-command`, which restores the buffer and
moves point before the command runs.

**Exports read the printed buffer, not the cache.**
`crate-browse-export-cargo' (`e c') and
`crate-browse-export-markdown' (`e m') walk the lines through
`crate-browse--rows', so an export follows the current sort and the
filter.  The Cargo export reuses `crate--dependency-line', the same
formatter as `crate-copy-dependency', so an unknown version becomes
`\"*\"'.  The Markdown export escapes a pipe and strips text
properties.  Both live under the `e' prefix keymap
`crate-browse-export-map' and write a `special-mode' buffer through
`crate-browse--export-buffer'.  `crate--display-buffer' is the one
place that honors `crate-display-buffer-action', and `find-crate'
uses it too.

**A table bookmark saves the sort key and the column widths.**
The record holds `name-prefix', `sort-key' (a `(NAME . FLIP)' cons)
and `widths' (one integer per column), so a saved filtered view
reopens the way it looked.  The filtered name-list is still
re-derived from the live cache.  `crate-browse--restore-state'
applies both after the browse command returns: it ignores a sort
key that names no column and a width list of the wrong length (an
old bookmark must still open), makes a restored width the base of a
later fit through `crate-browse--canonical-widths', and reprints
once when a value lands.

### Org link support

Org link types live in `ol-crate.el`, loaded via
`(with-eval-after-load 'org (require 'ol-crate))`.  Cross-file
references to functions and variables from `crate.el` use
`declare-function` and `defvar` in `ol-crate.el`.

### Evil layer

`evil-crate.el` is the optional evil layer, and the package never
requires evil.  `crate.el` loads it from
`(with-eval-after-load 'evil (require 'evil-crate))` and then calls
`crate-evil-auto-setup`, which enables the global `crate-evil-mode`
unless `crate-evil-auto-enable` is nil.  A user without evil loads no
evil code.

`evil-crate.el` must not `(require 'crate)`.  When a user loads evil
before crate.el, the `with-eval-after-load` block runs while crate.el
is still loading, and a `require` of crate there signals "Recursive
`require'".  The file uses `declare-function` and `defvar` for
everything it takes from crate.el.

The global mode enables one local minor mode per buffer
(`crate-evil-detail-mode` in `crate-mode`, `crate-evil-browse-mode` in
`crate-browse-mode`) through `after-change-major-mode-hook`, because
`define-derived-mode` wipes local state.  Evil keeps the state maps of
a minor mode apart from the major mode map, so every command key needs
a state binding to reach the buffer.

A key that evil already binds goes through `[remap COMMAND]`.  A remap
follows the command and not the key, so a user who moves `evil-ret`
keeps the crate behavior on the new key.  A key that evil leaves free,
such as `gr`, `gc` or `gm`, is a plain key string.  The evil motions
(`j`, `k`, `gg`, `G`, `C-d`, `C-u`, `/`, `n`, `N`) stay untouched.

The fold commands of evil (`zc`, `zo`, `za`) reach the sections through
`evil-fold-list`.  The list holds an `outline-minor-mode` entry and no
`magit-section-mode` entry, and `evil--mode-p` compares the major mode
name itself, so `evil-crate.el` adds a `crate-mode` entry whose actions
wrap `magit-section-toggle` and its siblings in a lambda: those
commands take the section as an argument.  `TAB` stays a plain key
binding to `magit-section-toggle`, for the same reason as in
`crate-link-map`.

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

Test files live in `test/`, one suite per source file, named
`<unit>-test.el`.  Shared fixtures live in
`test/crate-test-helper.el`, which each suite requires by name.  The
checkPhase loads the suites through a `test/*-test.el` glob, so a new
suite needs no Nix edit, and the helper name stays clear of that glob.
Every `ert-deftest` name carries the package prefix; a test of
`find-crate` therefore starts with `crate-find-crate-`.  `find-crate`
itself joins the checked prefixes through `package-lint--sane-prefixes`
in `nix/lint.nix`, because the public entry point has no `crate-`
prefix.

The `checkPhase` writes the fixture database path over the
`@testCratesDb@` placeholder in `test/crate-test.el`, so the end-to-end
tests skip in a plain shell and run inside the Nix build.

- `crate-test--data-hash` builds a mock `crate-data` hash table from
  keyword-value pairs (inner record, not keyed by crate name).
- `crate-test--cache-crate` stores such a record where
  `crate--crate` reads it, keyed by canonical name and database
  path, so a test can exercise `find-crate` without a database.
- `crate-test--insert-dependents` fills the `dependencies` table of a
  fixture database, which the helper creates empty.
- A test that mocks `sqlite-select` must mock `sqlite-execute` too:
  `crate--match-names` sets `PRAGMA case_sensitive_like` first, and
  an unmocked call raises, which the `condition-case` turns into a
  nil answer.
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
- Do not `cl-letf` a `defsubst` such as `tabulated-list-get-id`:
  byte-compiled callers carry their own copy of the call, so the
  mock works from source and silently fails in the Nix build.  Fill
  `tabulated-list-entries`, call `tabulated-list-print`, and move
  point instead.
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
- Evil tests live in `test/evil-crate-test.el` and need evil on the load
  path.  The file requires evil before crate, so the auto setup runs at
  load and `crate-evil-mode` starts on: a test that expects it off
  disables it first.  A key test uses `evil-local-mode` plus
  `evil-normal-state` (or `evil-visual-line`) in the mode buffer, then
  `key-binding` on the key.
- Evil is not a package dependency, so `test/crate-test.el` must not
  require it.  A test that needs no evil keeps passing in a build
  without it.
- A section test reads the tree, not the text: `magit-current-section`,
  `(oref section type)`, `(oref section value)` and
  `(oref section hidden)`, plus the helper `crate-test--section` for a
  section by type and value.  A fold moves point out of a hidden body
  and `search-forward` skips invisible text, so find a section through
  its visible heading.
- A fold test asserts visibility with `invisible-p` on a position
  inside the body, and a fold-survives-a-render test asserts
  `(oref section hidden)` on the section of the new render.

## Dependencies

| Dependency | Required? | Why |
|-----------|-----------|-----|
| Emacs 30.1 | yes | `json-parse-buffer`, `with-memoization`, `string-replace`, `cl-labels` |
| ol (org) | soft | org link support via `ol-crate.el` |
| bookmark | yes | built-in, used for crate bookmarks |
| browse-url | soft | crates.io URL handler via `crate-install-browse-url-handler` |
| goto-addr | yes | built-in, links the URLs of a detail buffer |
| magit-section | yes | folds, highlights and moves between the sections of a detail buffer |
| evil | soft | optional key layer in `evil-crate.el`; the package never requires it |
| nix (external) | soft | required only when `crate-doc-enable` is t; runs `nix-build` on `nix/crate-doc.nix` for on-demand rustdoc JSON |

## TODO

None right now.  The former Cargo.toml completion-at-point TODO
shipped as section 18.
