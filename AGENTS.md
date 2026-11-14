# AGENTS.md — crate.el

## Overview

Emacs package for browsing Rust crates from a local crates.io SQLite
database, plus a detail view of a local crate directory read through
`cargo metadata`.  `ol-crate.el` adds Org links, `evil-crate.el` an
optional evil layer.  A browse-url handler redirects crates.io URLs to
`find-crate`.

## Build & test

```sh
nix build                       # build
nix flake check                 # build + ERT suites + lint
nix build .#screenshot          # regenerate README screenshot
nix build .#gitrepo             # bare .git dir holding the screenshot
emacs --batch -L . -L test -l test/crate-test.el -f ert-run-tests-batch-and-exit
emacs --batch -L . -L test -l test/evil-crate-test.el -f ert-run-tests-batch-and-exit
```

Byte-compile with warnings as errors (the Nix checkPhase does this for
every elisp file):

```sh
emacs --batch -L . -L test --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile crate.el
```

The dev shell provides an Emacs wrapper with `magit-section` and `evil`
on the load path, plus Nix, sqlite and cargo.

Tests: one suite per source file, `test/<unit>-test.el`, plus
`test/crate-test-helper.el` for shared fixtures.  The checkPhase loads
the suites through a `test/*-test.el` glob, so a new suite needs no Nix
edit and the helper name must not match that glob.

`test/fixtures/harness/` holds a dependency-free crate, and
`nix/harness-doc.nix` documents it with rustdoc JSON (`RUSTC_BOOTSTRAP=1`,
`--document-private-items`).  A suite reads that document through the
`@testHarnessJson@` placeholder that `postPatch` substitutes, the same
way the SQLite tests read `@testCratesDb@`.

Flake outputs: `packages.crate` (= `default`) is `nix/default.nix`
(`melpaBuild`); its `checkPhase` runs both ERT suites against
`nix/test-crates-db.nix`.  `melpaBuild` propagates `packageRequires`
but does not put it on the build's load path, so `preBuild` prepends an
`emacsWithPackages` wrapper that sets `EMACSLOADPATH`.  The package
declares `magit-section` and no dependency on evil, which only
`evil-crate.el` needs.  `packages.screenshot` and `packages.gitrepo`
come from `nix/emacs-screenshot.nix`, which imports `mkGitRepository`
from the `nur-packages` flake input.  `checks.lint` is `nix/lint.nix`
(checkdoc plus package-lint over `*.el` and `test/*.el`).
`checks.harness-doc` is `nix/harness-doc.nix`, so a fixture crate that
stops compiling fails before a suite reads its JSON.

The version is `0.1.0-unstable-<commit date>`.  The flake derives the
date from `self.sourceInfo.lastModifiedDate`; `postPatch` writes the
same string into the `;; Version:` header, and writes the store path of
`pkgs.cargo` into the `crate-cargo-program` default.

## Files

- `crate.el` — main package
- `crate-tree.el` — crate item structure from rustdoc JSON
- `ol-crate.el` — Org link support
- `evil-crate.el` — optional evil layer (soft dependency)
- `nix/crate-doc.nix` — rustdoc JSON build
- `nix/harness-doc.nix` — rustdoc JSON of the test fixture crate
- `nix/lint.nix` — checkdoc plus package-lint gate
- `nix/default.nix` — package expression (`melpaBuild`)
- `nix/test-crates-db.nix` — fixture SQLite database
- `nix/emacs-screenshot.nix` — screenshot and git branch
- `flake.nix`, `flake.lock` — flake outputs and pinned inputs
- `test/crate-test.el`, `test/crate-test-helper.el`,
  `test/crate-tree-test.el`, `test/evil-crate-test.el` — ERT suites and
  fixtures
- `test/fixtures/harness/` — dependency-free crate for rustdoc parsing
  tests, plus `test/fixtures/harness.structure.txt`, its cargo-modules
  output
- `README.org`, `CONTEXT.md`, `docs/adr/`, `LICENSE`

`crate.el` is organized by `;;;` headings: cache, local crates, doc
build, helpers, faces, buttons, point keeping, sections, major mode,
completion, marginalia, commands, bookmarks, integrations, browse mode,
dependency copy, Cargo.toml completion, Embark.

### Rustdoc JSON pipeline

1. **`nix/crate-doc.nix`** uses a pinned crates.io index to generate
   `Cargo.lock` offline, then crane and nightly rustc run
   `cargo doc --output-format json`.  Fully sandboxed.
2. **`crate-doc--start-build`** spawns `nix-build` asynchronously
   through `make-process`.  A missing `nix-build`, a missing
   `crate-doc.nix` or a spawn failure caches `:failed`, so the status
   line degrades and `find-crate` keeps working.  A second request
   reuses the in-flight build.  The generation counter
   (`crate-doc--generation`, bumped by `crate-refresh-cache`) drops
   stale results.  On completion the sentinel re-renders the crate
   buffer from `crate-doc--json-from-build`.
   `crate-doc--nix-path` looks next to `crate.el` and then in `nix/`.
3. **`crate-doc--json`** reads the cache only (keyed by name and path);
   a miss starts a build and answers nil.
4. **`crate-doc--module-tree`** is pure and parses the JSON into
   `(NAME KIND (CHILDREN...) DOC)` tuples.  `KIND` is a symbol.
5. **`crate-insert-module-items`** writes two spaces of indentation per
   level and a bracketed kind tag.  It skips `:null`-named use imports
   and opens one `crate-module` section per item, valued by the full
   path, so a fold and the line of point survive a render.

### Tree tuple shape

The tuple always has 4 elements, even when DOC is nil; callers read
docs with `(cadddr item)`.

```elisp
;;   ("foo" struct nil "A foo struct.")   ;; leaf with doc
;;   ("bar" function nil nil)             ;; leaf without doc
;;   ("submod" module (("baz" ...)) nil)  ;; module with children
```

### Tree structure

`crate-tree--items` is pure and turns the same rustdoc document into
one `crate-tree-item` struct per item: path, name, kind, kind word,
visibility word, span, docs, attrs, deprecation and children.  A row
keys on its item path, so a fold survives a re-render.  The path is
built during the walk, because rustdoc's `paths` table lists no
associated item (no impl method, no trait member).

Children come from four places: `module.items`, `trait.items`, the
fields and variants of a type, and the impls that the type lists.  A
synthetic impl and a blanket impl drop.  A trait impl that the crate
writes itself stays, because `cargo-modules` prints its methods under
the type.  Rustdoc leaves the visibility of those members implicit
(`default`), and `cargo-modules` prints `pub(crate)`, so the parser
follows that word.

A restricted visibility path equal to the containing module reads
`pub(self)`, a path equal to the module above it reads `pub(super)`,
and any other path reads `pub(in crate::…)`.  Rustdoc reports a
private item of a `pub(crate)` type as restricted to the crate, so
`pub(crate)` covers it.

`crate-tree--rows` flattens the tree into `(ITEM . DEPTH)` conses for
the state that a buffer holds: `:folded` (a hash set keyed by path),
`:kinds`, `:public-only`, `:focus` (a regexp on the path),
`:max-depth`, `:sort` and `:reverse`.  The root row always survives a
filter.  A folded item keeps its own row and drops its subtree, and a
filtered item drops its subtree too.  The focus keeps the matching
subtree and the ancestors of the match, so no row loses its parent.
`(plist-member state :kinds)` tells an empty kind list from an absent
key, so `:kinds ()` shows the root alone, and a nil `:kinds` means
`crate-tree--default-kinds`.

The parser keeps source order.  `crate-tree--structure-text` sorts
every sibling list by name and prints the `cargo-modules structure`
format.  `test/fixtures/harness.structure.txt` holds the output of
that tool for the fixture crate, so one ERT test compares the two
line by line.

### Local rustdoc builds

`crate-tree--start-local-build` runs `cargo doc --lib --no-deps
--document-private-items` in the crate directory through
`crate-cargo-program`, with `RUSTC_BOOTSTRAP=1` and a `RUSTDOCFLAGS`
that asks for JSON.  `make-process` takes no environment keyword, so
the child inherits a `process-environment` binding.  `RUSTC` names
`crate-rustc-program` when that program resolves, and cargo finds its
own compiler otherwise.

The command runs online and outside Nix, because `cargo doc`
type-checks the crate and needs its dependencies, which a development
crate usually holds in the cargo cache already.  The JSON path comes
from `cargo metadata`: the `target_directory`, the `doc` directory and
the library target name.  A package with no library target builds
nothing.

`crate-tree--json` caches the parsed document under
`(tree MANIFEST)` with a `:failed` sentinel, and `crate-tree--refresh`
drops the entry before a rebuild, so `g` reads the source as it stands.
The Nix build substitutes both the cargo and the rustc store paths
into the defcustom defaults.

### Crate tree mode

`crate-tree-mode` derives from `tabulated-list-mode`, so one buffer
holds one table: Kind, Name, Vis, Location and Docs.  The caller sets
`crate-tree--root`, `crate-tree--name` and `crate-tree--directory`
after the mode and then calls `crate-tree--reprint`, because
`define-derived-mode` wipes the locals.

A row id is the item path, so `tabulated-list-print` with
REMEMBER-POS leaves point on its row when a fold hides rows above it.
Each reprint rebuilds the entries from the state, computes the column
widths from the visible rows, and stores the visible items in
`crate-tree--items` for the row commands.  The Docs column declares
width 0, which `tabulated-list` reads as "take the rest of the line".

`crate-tree--sort-children` reads the state and sorts a copy, so a
sort never touches the parsed tree.  Reverse applies to the source
order too, otherwise the reverse command would do nothing until a
sort ran.

The name cell carries the fold marker, the indentation and the child
count of a folded row.  The marker alone carries a `keymap` text
property for `mouse-1`, because a click on a name selects the row.
The printer adds `help-echo` with the full item path and the doc
comment.  The `%` of the header line names the row count, the public
filter and the focus.

Depth keys `1` to `9` set `crate-tree--max-depth` to one less, and
`9` means nil (every depth).  The keymap overrides the digit argument
of `tabulated-list-mode-map`, which this mode never needs.

### Tree bookmarks

`crate-tree--bookmark-make-record` saves the source (a name or a
directory), the fold set, the kind list, the public flag, the focus,
the depth, the sort and the row at point.  The label reads
`Crate tree: NAME` or `Crate tree: NAME (PATH)`.

`crate-tree-bookmark-jump` opens the buffer and applies the record.  A
build that still runs prints no row, so the jump leaves the row path
in `crate-tree--pending-row`, and `crate-tree--reprint` moves point
once the row appears.  A fold path that the rebuilt tree lacks stays in
the set and hides nothing, so an old bookmark still opens.

`bookmark-prop-get` answers nil for an absent key and for a saved nil
alike, so the kind list, the depth and the sort read the record props
through `crate-tree--bookmark-prop-set-p` before they replace the
buffer state.  Without that test an old record with no `kinds` would
set an empty kind list and show the crate row alone.

### Entry points

`S` in `crate-mode` and in `crate-browse-mode` runs `crate-tree-show`,
which lives in `crate.el` and requires `crate-tree` at call time, so a
reader who never opens the table never loads it.
`crate-insert-structure` is the section inserter that puts the entry
point inside a detail buffer, and it renders one `crate-link` button.
The default `crate-detail-sections-hook` ends with it.

A tree buffer keys on its name: `Crate Tree: NAME` for a database
crate and `Crate Tree: NAME (PATH)` for a local one.  A second open of
the same buffer only displays it, so folds and filters survive, and
`crate-tree-mode` runs once.

`format_version` 57 through 61 parse, because rustc 1.97 in the flake
and rustc 1.99 on the development machine both read the fields that
this parser uses.  Any other value signals a `user-error` instead of
half-reading the document.  A struct field, a
variant and a `use` item carry a span.  An impl item carries none and
never becomes a row.

## Conventions

### Docstrings

Keep one line when the name, arguments and body already say it.  Keep
facts that the code does not show: measurements, formats, invariants,
external quirks and Emacs API contracts.  checkdoc requires a docstring
on every `defun`; `defcustom` and `defface` make it positional, so they
need at least a one-line string.

### Byte-compiler silencing

Declare external vars and faces from optional deps with a value-less
`(defvar <var>)`, never a value (the real default would be lost).
Cross-file functions use `declare-function`.  Required deps get
`(require 'package)`.

### `cl-labels` for mode-local helpers

A helper that only a major mode body calls belongs in a `cl-labels`
closure.  A section inserter is the exception: it carries a `crate-`
prefix, takes no arguments and lives at top level, because a user names
it in `crate-detail-sections-hook`.

### `permanent-local` for mode-surviving state

`define-derived-mode` calls `kill-all-local-variables`.
`crate-name`, `crate-data` and `crate-local-path` are set after
`crate-mode`, so they need no `permanent-local`.  A variable set with
`setq-local` before a mode call needs `(put 'var 'permanent-local t)`;
the browse-mode filters do this.

### Graceful load failures

`crate--list` wraps the file load and the queries in `condition-case`,
so a missing or corrupt database answers nil.  `find-crate` blames the
configuration before the name, through `crate--database-readable-p`, so
a missing DB never masquerades as a missing crate.  Close SQLite handles
with `unwind-protect`, never `prog1`.

In `lexical-binding: t`, plain `let` evaluates all init forms in the
outer scope.  Use `let*` when one binding depends on a prior one.

### `declare` for pure functions

`(declare (pure t) (side-effect-free t))` when the result depends on the
arguments only.  A function that reads a defcustom, a buffer-local or a
face gets `side-effect-free` alone.  A function that writes a hash
table, a file or a buffer gets neither.

### `defconst` for shared strings

A non-configurable string used in several places is a `defconst`.

### Canonical crate names

`crate--canonical-name` (downcase, hyphens to underscores) is the single
lookup form.  `crate--list` and `crate--crate` key by it.  The entry's
`"name"` holds the published name, and display, completion and URLs use
it.  A canonical form is not a published name, so `crate--crate` asks
for both spellings (`async-trait` and `async_trait`).  Two spellings
suffice on a full dump of 358 423 names: no name mixes both separators
and no two names share a canonical form.

### Local crates go through `cargo metadata`

`crate-visit-directory` reads a directory through
`crate-local--metadata` (`cargo metadata --no-deps --offline`, using
`crate-cargo-program`, where nil turns the command off).
`crate-local--entry` maps the package onto the shape of a `crates` row,
so every section inserter works on both sources.  `crate-local-path`
tells the sources apart: `crate--dependencies` reads `crate-data` for a
local crate, `crate--insert-repository` makes the crate directory the
`default-directory`, and `crate-insert-modules` shows no section.

A local record memoizes under `(list 'local MANIFEST)` with the same
`:failed` sentinel, so `crate-refresh-cache` drops it.
`crate--revert` forgets the entry first, so `g` picks up an edited
manifest.  A local crate keeps its own buffer,
`Crate: <name> (<path>)`, and its bookmark carries the directory.

`cargo metadata` answers canonical paths, so `crate-local--truename`
resolves the symlinks on both sides of a manifest comparison and on
the base of a path dependency.  A directory that a reader reaches
through a symlink then answers its own package.  `packages` parses
as a vector, so the fallback reads `seq-first`, never `car`.

A local dependency row has the database shape plus a `(KIND . TARGET)`
source spec in its fifth slot.  A registry dependency carries no spec;
a path or git dependency prints `{ path = "../foo" }` or
`{ git = "URL" }` and is no button, because it has no crates.io page.

### One crate record, not the whole table

`crate--crate` reads one row through the `name` primary-key btree and
memoizes it.  `crate--list` reads every row, which on a full dump makes
358 423 hash tables: 1.8 s and +647 MiB.  So `find-crate`,
`crate--annotate`, `crate-doc--json` and `crate-copy-dependency` use
`crate--crate`; only a view over every crate uses `crate--list`, and it
keeps the whole table.  Measured on the 422 MB dump, `find-crate` for
serde went from 5.27 s to 0.09 s and from 1 022 MiB to 146 MiB.

### Completion conventions

`crate--collection` returns `(metadata (category . crate)
(annotation-function . ...))` for the `metadata` action, so Marginalia
and Embark can hook in.  Candidates come from per-keystroke SQL prefix
queries in `crate--match-names`; no full name list materializes.  Escape
LIKE wildcards, because `_` is a valid crate-name character.

**`crate--match-names` turns on `case_sensitive_like`.**  `LIKE`
compares case-insensitively by default, which leaves SQLite off the
`name` btree: `EXPLAIN QUERY PLAN` answers `SCAN crates`, and one
keystroke costs 50 ms.  All published names are lowercase, so the pragma
plus a downcased prefix walks the btree in 0.03 ms.

Every candidate costs a row fetch, so `crate-completion-limit` (default
200) stops the query; nil fetches every match.

### Memoization

JSON data and crate structure results use `with-memoization` on
`(gethash key hash-table)`.  Every cache key includes `crate-data-path`,
so a path switch self-invalidates.

`with-memoization` evaluates its place with `or`, so a nil body
recomputes.  Use a `:failed` sentinel where nil is a valid cached
outcome.  A cached list of names must not be nil: `crate--dependents-data`
stores `(NAMES . TRUNCATED)`, and `(nil . nil)` survives the `or`.

The doc-build cache reads the hash table directly, because that path is
asynchronous.

### Avoid `let-alist` on hash tables

`let-alist` expands to `(cdr (assq ...))`, so it works on alists only.
`json-parse-buffer` returns hash tables.  Use `gethash`.

### Faces, display faces, and font-lock keywords

Faces inherit from `package.el` or standard faces where available, and
fall back left-to-right over undefined faces.  A field label keeps its
colon and takes `crate-field-label`; a section heading carries no colon
and takes `magit-section-heading`; a module name takes `default`.

**Every face is a `crate-font-lock-keywords` rule, never a `propertize`
call.**  `crate-mode` calls `font-lock-ensure`, which unfontifies the
buffer first and removes a `face` property that no keyword matches.

### Links in a detail buffer

`crate-mode` enables `goto-address-mode` through `crate-goto-address`
(default t), which links the homepage, repository and documentation
URLs with an evaporating overlay.  A renderer never sets `mouse-face`
on a URL.

`RET` is `push-button`.  The `keymap` text property of a `crate-link`
button wins over the major mode map.

### Point keeping across a render

`crate--render` erases the buffer, so it records the line of point
first and restores it after the render.  The record names a **section**
(the section object at point), the distance in lines from the start of
that section and the column (`crate--line-record`).
`magit-section-goto-successor` finds the section again through
`magit-section-ident`, which walks type and value.  A line without a
section holds no record, and a dropped section leaves point at
`point-min`.

The record covers the buffer point and the point of every window that
shows the buffer.  The buffer record carries nil in place of a window,
because a buffer can show in no window.  Restore a window point inside
`save-excursion`, because a window keeps the point of the buffer point.

**A buffer that held no text restores no line.**  `fresh` comes from
`(= (point-min) (point-max))` before the erase, and a fresh render calls
`crate--goto-start`.  Without that step a first `find-crate` would leave
point at the end of the inserted text.

A section value that a render keeps must stay stable.  A field carries
its key, a module its full path (two modules of different parents can
share a name), and a group nil.  A line inside a section body keeps its
line offset, not its text, so a dependency row moves with its line
(`crate-mode-render-keeps-the-line-inside-a-section` covers that).

### Sections and folds

`crate-mode` derives from `magit-section-mode`.  `crate--render` opens
one `crate-detail` root section and runs `crate-detail-sections-hook`
through `magit-run-section-hook`.  Every inserter uses
`magit-insert-section` and `magit-insert-heading`, so folds, motions,
the highlight and fringe clicks come from `magit-section`.

**`crate-detail-sections-hook` is the one extension point for the
section list.**  Do not add a second defcustom that lists sections.

**`magit-section-inhibit-markers` stays t.**  A marker per section end
makes a render quadratic in the module tree: 4000 nested sections take
1.4 s with markers and 0.06 s without.  A crate buffer inserts once and
then only reads.

**A heading carries no colon.**  With markers inhibited,
`magit-insert-child-count` rewrites the heading of a section that ends
in a colon after its children recorded their positions, and a fold then
cuts at the wrong place.  Instead the count goes into the heading string
before the body starts, through `crate--child-count` and
`magit-insert-heading`.  `crate--child-count` answers nil for a zero
count and for a reader who turned `magit-section-show-child-count` off,
so no heading carries a zero.  `crate--module-count` drops the
`:null`-named use imports.

**The Dependents section stops at `crate-dependents-limit`.**  serde
has 135 172 dependents, and one button per dependent costs 1.3 s to
render.  `crate--dependents-data` asks for one name past the limit, so
it pays for no count it never shows, and the heading marks a cut list
`(200+)`.

**The folds need no code of their own.**  A section keeps its
visibility by ident in `magit-section-visibility-cache`, so
`crate--render` only ends with `(magit-section-show
magit-root-section)` under `(let ((magit-section-cache-visibility
nil)) ...)`.  That binding keeps the cache small.

`crate-link-map` keeps a `TAB` entry for `magit-section-toggle`,
because a dependency row is both a button and a line of the Dependencies
section, and a button's `keymap` wins over the major mode map.

### `thing-at-point` URL provider

`crate-mode` adds `crate--thing-at-point-url` to
`thing-at-point-provider-alist` for `url`, so a dependency name (which
carries a `crate-url` text property) answers
`thing-at-point 'url` and `browse-url-at-point`.  Require `thingatpt`
explicitly, because a value-less `defvar` leaves the variable void.

`crate-browse-mode` adds `crate-browse--thing-at-point-url`, which falls
back to the entry ID, so any cell answers the crate URL.  Only the name
cell carries `crate-url`, because `equal` on a cell and a bare string
must stay true and the export strips properties.

### One text button type for links

`crate-link` carries the `crate-url` face, the `mouse-face`, the
`follow-link` rule and a default `help-echo`.  A renderer writes
`:type 'crate-link` and only the properties that differ.  A URL button
falls back to `crate--button-url`.

### Browse table reload

`crate-browse--reload` rebuilds `tabulated-list-entries` from the
buffer-local `crate-browse--name-list`; `crate-browse-mode` adds it to
`tabulated-list-revert-hook` buffer-locally, so `g` keeps the filter.
`crate-browse-crates` calls it before the first print and then refits
the columns, because that print lands in the selected window.

**A column SORT element may be a predicate** over entries.
`crate-browse--version-lessp` calls `crate--version-lessp`, because the
built-in `t` sorts "1.10.0" before "1.9.0".  Do not use `version<`: it
signals on pre-releases such as "1.0.0-rc.1".  `crate--version-parts`
makes minor and patch optional, because a few old crates publish "0.1".
`crate-browse--cell-text` reads a cell that is a string or a
`(LABEL . PROPS)` cons.

**A table fits its columns to its window.**  `crate-browse--fit-widths`
shrinks a middle column to 8 and then the Crate column to
`crate-browse-name-min-width`, so the last column keeps
`crate-browse-description-min-width`.  `crate-browse-mode` stores the
declared widths in `crate-browse--declared-widths`;
`crate-browse--fit-format` builds the base widths from them into
`crate-browse--canonical-widths`, so a resize in either direction lands
right.  A frame resize schedules one refit per buffer through
`run-at-time` and reprints only when a width changed.
`crate-browse-refit-max-entries` skips a table above that size, because
a reprint sorts again.

The Version column widens to the longest visible version through
`crate-browse--content-widths`, capped by
`crate-browse-version-max-width`.  It reads
`crate-browse--declared-widths`, never a fitted or bookmarked value.

**`{` and `}` come from `tabulated-list-mode-map`.**  crate.el declares
no resize command of its own.

**`crate-display-buffer-action` picks the window of a detail buffer.**
nil keeps `switch-to-buffer`; any other value goes to `pop-to-buffer`.
`crate--other-window-action` reuses a window that already shows the
buffer, else splits, and never uses the selected window.

**`tabulated-list-printer` is `crate-browse--print-entry`.**  It paints
`help-echo` on the row and `mouse-face` on the name cell.
`<follow-link>` is `crate-browse--click-selects-row`, which answers nil:
the default (`mouse-face`) would turn a click on the name into `mouse-2`
and open a detail buffer.  A context-menu command wraps
`crate-browse--context-command`, which restores the buffer and moves
point first.

**Exports read the printed buffer, not the cache.**
`crate-browse-export-cargo` (`e c`) and `crate-browse-export-markdown`
(`e m`) walk the lines through `crate-browse--rows`, so an export
follows the current sort and filter.  The Cargo export reuses
`crate--dependency-line`, so an unknown version becomes `"*"`.
`crate--display-buffer` is the one place that honors
`crate-display-buffer-action`.

**A table bookmark saves the sort key and the column widths.**  The
filtered name-list is still re-derived from the live cache.
`crate-browse--restore-state` ignores a sort key that names no column
and a width list of the wrong length, and reprints once when a value
lands.

### Org link support

Org link types live in `ol-crate.el`, loaded through
`(with-eval-after-load 'org (require 'ol-crate))`.  Cross-file
references use `declare-function` and `defvar`.

### Evil layer

`evil-crate.el` is optional and never required by `crate.el`, which
loads it from `(with-eval-after-load 'evil ...)` and calls
`crate-evil-auto-setup`.  `crate-evil-auto-enable` decides whether the
global mode starts.

`evil-crate.el` must not `(require 'crate)`: when evil loads before
crate.el, the `with-eval-after-load` block runs during the load of
crate.el and a `require` signals "Recursive `require'".

The global mode enables one local minor mode per buffer through
`after-change-major-mode-hook`.  Evil keeps the state maps of a minor
mode apart from the major mode map, so every command key needs a state
binding.  A command that evil already binds goes through
`[remap COMMAND]`; a key that evil leaves free (`gr`, `gc`, `gm`) is a
plain key string.

The fold commands (`zc`, `zo`, `za`) reach the sections through
`evil-fold-list`.  The list has no `magit-section-mode` entry, and
`evil--mode-p` compares the major mode name itself, so `evil-crate.el`
adds a `crate-mode` entry whose actions wrap `magit-section-toggle` and
its siblings in lambdas, because those commands take the section as an
argument.  A second entry serves `crate-tree-mode`: its actions call
`crate-tree-toggle`, `crate-tree-fold` and `crate-tree-unfold`, and its
`:open-all` and `:close-all` set the depth instead of walking sections.

A tree buffer gives evil commands away on purpose: the state map binds
`TAB`, `s`, `S`, `y`, `w`, `fp`, `fk`, `ff`, `fr`, `gr`, the digits
and `C-c C-o`, so `evil-substitute`, `evil-find-char`, `evil-yank` and
the count prefix stay out of the way.  The filter commands take a plain
two-key binding (`fp`) in the state map, because a keymap value that a
state map holds must exist when `evil-crate.el` loads, and
`crate-tree.el` may load later.  `crate-tree-set-depth` takes an
argument, so `crate-evil--depth-command` builds one command per digit.

### Null guard in `when-let*` conditions

JSON `null` becomes `:null`, and `string-replace` errors on it, so guard
in the `when-let*` binding, not in the body:

```elisp
(or (when-let* ((it (gethash "key" data))
                ((not (eq it :null))))
      (string-replace "\n" "" it))
    "")
```

## Test conventions

Every `ert-deftest` name carries the package prefix; `find-crate` joins
the checked prefixes through `package-lint--sane-prefixes` in
`nix/lint.nix`, because it has no `crate-` prefix.

The `checkPhase` writes the fixture database path over the
`@testCratesDb@` placeholder in `test/crate-test.el`, so the end-to-end
tests skip in a plain shell and run inside the Nix build.  It writes
the fixture rustdoc JSON path over `@testHarnessJson@` in
`test/crate-tree-test.el` the same way, and
`crate-tree-test--with-root` skips a test when that path is absent.

- `crate-test--data-hash` builds a mock `crate-data` record from
  keyword-value pairs.
- `crate-test--cache-crate` stores such a record where `crate--crate`
  reads it, so a test reaches `find-crate` without a database.
- `crate-test--insert-dependents` fills the `dependencies` table.
- Mock `sqlite-select` and `sqlite-execute` together:
  `crate--match-names` sets `PRAGMA case_sensitive_like` first, and an
  unmocked call raises.
- `crate-test--crate-table` builds a mock top-level table for
  `crate-list-json`.
- `crate-test--with-crate` binds `crate-name` and `crate-data`.
- `crate-test--cargo-metadata` and `crate-test--cargo-dependency` build
  `cargo metadata` JSON and round-trip it through `json-serialize`, so
  the fixture has the shape that `json-parse-buffer` answers.  Mock
  `crate-local--metadata`, so no test needs cargo.
- `crate-test--with-local-crate` creates a temporary crate directory.
  A local test that renders must mock `crate--dependents`, and its
  `switch-to-buffer` mock answers `(get-buffer-create name)`.
- Mock `find-crate`, `switch-to-buffer` and `org-link-store-props` with
  `cl-letf` on `symbol-function`.  The `org-link-store-props` mock takes
  `&rest` and reads the plist, because the real `&key` does not compose
  with `cl-letf`.
- Hash tables with equal content are not `equal`; compare `gethash`
  values.
- A bookmark handler test passes the full `(NAME (prop . val) ...)`
  record, matching what `bookmark-handle-bookmark` passes.
- Do not `cl-letf` a `defsubst` such as `tabulated-list-get-id`: a
  byte-compiled caller carries its own copy.  Fill
  `tabulated-list-entries`, print, and move point.
- Tests that need `browse-url-default-handlers` require `browse-url`
  first, because `crate-install-browse-url-handler` uses
  `with-eval-after-load`.
- Hyphenated-name tests use a row such as `async-trait` and assert that
  published names surface while both spellings resolve.
- `crate-visit-hook` tests bind the hook to nil and add a lambda, then
  assert on buffer name and locals inside the hook.
- A section test reads the tree (`magit-current-section`,
  `magit-section` slots) through `crate-test--section`, not the text.
  A fold test asserts `invisible-p` or `(oref section hidden)`.
- `crate-tree-test--with-buffer` opens a `crate-tree-mode` buffer on
  the fixture tree, and `crate-tree-test--goto` moves point to a row
  by item path.  Assert on `tabulated-list-entries`,
  `tabulated-list-get-id` and `header-line-format`, not on the text.
- `crate-tree-test--item` walks the fixture tree by name, and
  `crate-tree-test--walk` visits a subtree.  Assertions read item
  slots, because the tree holds structs that no buffer shows.
- The cargo-modules parity test compares
  `crate-tree--structure-text` with the committed
  `test/fixtures/harness.structure.txt`.  Regenerate that file with
  `NO_COLOR=1 cargo-modules structure --lib` in
  `test/fixtures/harness/` after an edit to the fixture crate, and
  check the diff before committing it.
- Evil tests live in `test/evil-crate-test.el`, which requires evil
  before crate.  A key test enables `evil-local-mode`, enters a state
  and calls `key-binding`.

## Dependencies

| Dependency | Required? | Why |
|-----------|-----------|-----|
| Emacs 30.1 | yes | `json-parse-buffer`, `with-memoization`, `string-replace`, `cl-labels` |
| cargo | soft | `crate-visit-directory` reads a local crate through `cargo metadata --no-deps`; option `crate-cargo-program` |
| rustc | soft | the tree mode runs `cargo doc` on a local crate; option `crate-rustc-program` |
| ol (org) | soft | Org link support via `ol-crate.el` |
| bookmark | yes | built-in crate bookmarks |
| browse-url | soft | crates.io URL handler |
| goto-addr | yes | links the URLs of a detail buffer |
| magit-section | yes | folds, highlights, section motions |
| evil | soft | optional key layer in `evil-crate.el` |
| nix (external) | soft | on-demand rustdoc JSON when `crate-doc-enable` is t |

## TODO

None.
