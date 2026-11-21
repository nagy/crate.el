# AGENTS.md — crate.el

## Purpose

Emacs Lisp package that browses Rust crates from a local crates.io SQLite
database. It renders a `magit-section` detail buffer, a `tabulated-list`
browse table, and an item table of a crate from rustdoc JSON. The rustdoc
builds run through Nix, or through `cargo doc` for a local crate. Requires
Emacs 30.1. License: AGPL3+. `README.org` holds the user-facing behaviour
and every key binding.

## Layout

- `crate.el`: database access, crate records, detail buffer, browse table, links, Embark targets.
- `crate-tree.el`: rustdoc JSON parser, item table, local and database builds.
- `ol-crate.el`: the `crate:` Org link type, loaded on demand.
- `evil-crate.el`: optional Evil key layer.
- `nix/`: package expression, lint gate, fixture database, the three rustdoc builds (`crate-doc.nix`, `harness-doc.nix`, `tree-doc.nix`), screenshot.
- `test/`: one suite per source unit, plus `crate-test-helper.el` for shared fixtures.
- `test/fixtures/harness/`: dependency-free crate for the parser and the `cargo-modules` parity test.
- `docs/adr/`: accepted decisions on the rustdoc pipeline, the section tree and local crates.
- `CONTEXT.md`: domain glossary.

## Build and test

- `nix flake check`: the gate. Run before done.
- `emacs --batch -L . -L test -l test/crate-tree-test.el -f ert-run-tests-batch-and-exit`: one suite in the dev shell. A test that needs a Nix fixture skips.
- `nix build .#screenshot`: regenerate the README screenshot and its branch.
- `nix fmt`: nixfmt over the Nix files. No Elisp formatter.

## Architecture

Data flow: one SQLite row or one `cargo metadata` package builds one
`crate-data` hash table, and the section inserters render it as a
`magit-section` tree. The tree mode walks the same rustdoc document into
one `crate-tree-item` struct per item.

### Data sources

`crate--crate` reads one row through the `name` primary key and memoizes
it. `crate--list` reads every row, so only a view over every crate calls
it. `crate--canonical-name` gives the one lookup form: downcase, then
hyphens to underscores.

`crate-local--entry` maps a `cargo metadata` package onto the shape of a
`crates` row, so every section inserter serves a local crate and a
database crate alike. `crate-local-path` tells the two apart.

### Rustdoc JSON pipeline

Two producers fill two caches. For a database crate, `crate-doc--start-build`
runs `nix-build` on `nix/crate-doc.nix` and stores the document in
`crate-doc--cache`. For a local crate, `crate-tree--start-local-build`
runs `cargo doc` with JSON output and stores the document under the
manifest. A local build resists the network and the crate tree:
`crate-tree--doc-arguments` passes `--frozen` when a `Cargo.lock`
exists, `--offline` otherwise, and `CARGO_TARGET_DIR` points at
`crate-tree-target-directory`, which by default names a cache
directory keyed by the manifest, the lockfile and the rustc version.
A build thus writes no `target` directory into the crate and no
lockfile change, and a second Emacs session reuses its output.

A local crate builds in the Nix sandbox first. `crate-tree--start-nix-build`
runs `nix-build nix/tree-doc.nix --argstr crateDir WORKSPACE_ROOT
--argstr manifestPath REL --argstr libName NAME -o G croot`.
`tree-doc.nix` copies the workspace root through `builtins.path`, so a
member resolves its path dependencies, and `cargoDeps` comes from
`importCargoLock`, so a lockfile needs no vendor hash and the build
touches no network. A crate without a lockfile builds through plain
`stdenv` with `--offline`, which serves a dependency-free crate and
fails for every other one. `crate-tree--build-key` keys the cache
directory, so a changed source, lockfile or rustc selects a fresh
build, and a failed sandbox build keeps its log in
`*crate-tree-nix-build*` and retries through `cargo doc`, so a private
registry or a system library still documents. Both
`crate-doc--status` and `crate-tree--reason` hold
`running` or the reason that a crate has no document, and every entry
point shows that reason in place of the rows.

One build serves every waiting buffer. `crate-doc--waiters` and
`crate-doc--render-function` let a detail buffer and a tree of the same
crate share one Nix run. A generation counter drops the result of a
build that a cache refresh made stale.

### Rendering

`crate-mode` derives from `magit-section-mode`, and
`crate-detail-sections-hook` holds the section list. `crate--render`
records the line of point and restores it after the erase.
`crate-tree-mode` derives from `tabulated-list-mode`, one buffer for one
table, and a row id holds the item path, so a fold survives a reprint.

### Optional layers

`crate.el` never requires `ol-crate.el`, `evil-crate.el` or any other
optional package. Each integration starts from a `with-eval-after-load`
block, and each such file guards the names that it borrows.

## Rules

- Never silence a byte-compile warning. Fix the warning.
- Run `nix flake check` before you report work as done.
- `evil-crate.el` must not require `crate.el`. When Evil loads first, that require signals "Recursive `require'".
- `crate-detail-sections-hook` is the one extension point for the section list. Do not add a second defcustom.
- Keep `magit-section-inhibit-markers` at t. A marker per section end makes a render quadratic in the module tree.
- Call `crate--crate` unless the view spans every crate. One row costs one hash table, the full dump costs 358 423 of them.
- Keep `crate--canonical-name` as the single lookup form, and ask for both spellings when a name mixes separators.
- Cache a nil outcome with a `:failed` sentinel. `with-memoization` evaluates its place with `or`, so a nil body recomputes.
- A failed start or build stores its reason. Never answer a bare nil where the reader needs the fix.
- Do not hand-edit the `;; Version:` header or the `@testCratesDb@` and `@testHarnessJson@` placeholders. `nix/default.nix` writes them in `postPatch`.
- Paint a face through a `crate-font-lock-keywords` rule, never through `propertize`. `font-lock-ensure` drops a face that no keyword matches.
- Guard a JSON `:null` inside the `when-let*` binding, not in the body. `string-replace` errors on `:null`.
- Do not use `let-alist` on parsed JSON. It expands to `assq`, and `json-parse-buffer` answers hash tables.
- Mark a pure function `(declare (pure t) (side-effect-free t))`. A function that reads a defcustom or a buffer-local takes `side-effect-free` alone. A function that writes a cache takes neither.
- Declare a name from an optional dependency with a value-less `(defvar ...)` or a `declare-function`. A value would replace the real default.

## Conventions

- Prefix: `crate-` for a command or an autoload, `crate--` for an internal, one prefix per file.
- Docstring: keep one line when the name says it. Keep the facts that the code does not show, such as a measurement, a format, an invariant or an external quirk.
- In `lexical-binding: t`, `let` evaluates every init form in the outer scope. Use `let*` when one binding depends on an earlier one.
- Put a helper that only a mode body calls in a `cl-labels` closure. A section inserter stays at top level, because a user names it in a hook.
- Use a `defconst` for a non-configurable string that several places share.
- Insert an empty line before a section that follows another section.

## Testing

- One `<unit>-test.el` per source unit. The checkPhase loads them through a `test/*-test.el` glob, so a new suite needs no Nix edit.
- `test/crate-test-helper.el` holds the shared fixtures. Its name must not match the glob.
- A behavior change ships a test in the suite of the unit.
- Mock `sqlite-select` and `sqlite-execute` together, because `crate--match-names` sets a pragma first.
- Do not `cl-letf` a `defsubst` such as `tabulated-list-get-id`. A byte-compiled caller carries its own copy.
- Assert on the tree and the table data, not on the buffer text. Read a section through `crate-test--section` and a row through `tabulated-list-get-id`.
- Regenerate `test/fixtures/harness.structure.txt` with `NO_COLOR=1 cargo-modules structure --lib` in the fixture directory after an edit to that crate.

## Dependencies

| dependency | required? | why |
|---|---|---|
| Emacs 30.1 | required | `json-parse-buffer`, `with-memoization`, `string-replace`, `cl-labels` |
| magit-section | required | folds, highlights, section motions |
| bookmark | required | built-in, crate and tree bookmarks |
| goto-addr | required | links the URLs of a detail buffer |
| cargo | optional | `cargo metadata` for a local crate, `cargo doc` for its tree |
| rustc | optional | JSON output of a local `cargo doc` |
| nix | optional | rustdoc JSON of a database crate |
| org | optional | the `crate:` link type in `ol-crate.el` |
| evil | optional | the key layer in `evil-crate.el` |
| embark | optional | export, candidate actions, file and URL target finders |
| browse-url | optional | the crates.io URL handler |
| tired | optional | shortens a printed path |
| buffer-url | optional | shortens a printed URL |

`packageRequires` names `magit-section` alone. An optional package
reaches the load path of the dev shell and of the test run, never of the
build.

## Workflow

- Commit messages: one imperative line. Prefix `unit:` when the change touches one unit, for example `crate-tree: name the cause of a failed build`.
- The README screenshot stays out of git. `nix build .#screenshot` writes it and `packages.gitrepo` holds the branch that the README links to.
- The version comes from `self.sourceInfo.lastModifiedDate`. Do not bump it by hand.
