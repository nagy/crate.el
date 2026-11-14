# Read a local crate with `cargo metadata`

We decided to let `crate-visit-directory` open the crate of a local
directory.  The directory must hold a `Cargo.toml`, and the command
reads its fields and its dependency list with

```sh
cargo metadata --no-deps --offline --format-version 1
```

then maps the answer onto the record shape that a database row builds.
`crate-local-path` tells the buffer that the record came from a
directory, and the section inserters branch on it only where the two
sources truly differ.

The buffer is named `Crate: <name> (<path>)`, so a local checkout and
the published crate of the same name keep separate buffers.  The
Modules section stays empty, because no rustdoc build feeds a local
crate yet.

## Considered Options

- **Parse `Cargo.toml` in Elisp.**  No external process, but workspace
  inheritance, `[dependencies.x]` tables, target sections and renamed
  dependencies all need hand-written handling, and the code would
  disagree with cargo about the answers.
- **Run `cargo metadata` with dependencies.**  Gives the full resolve
  graph, but needs the registry index and may need a lockfile, so it
  breaks on a fresh checkout offline.  `--no-deps` reads the manifest
  and the workspace only.
- **Reuse `find-crate` and detect a path.**  One entry point, but the
  command would mix two data sources and two buffer-naming rules.
- **Build local docs with Nix.**  A sandbox build of a local path needs
  its own derivation and a lockfile step.  Deferred until the metadata
  path proves useful.

## Consequences

- `crate-visit-directory` needs cargo on `executable-find`.  A missing
  cargo, a missing manifest and a failing call all signal a
  `user-error` that names the directory.
- A dependency row of a local crate carries a `(KIND . TARGET)` source
  spec in its fifth slot, so a path or a git dependency shows
  `{ path = "../foo" }` and stays plain text.  Only a registry row is a
  `crate-link`, because only it has a crates.io page.
- The local record memoizes in `crate--data-cache` under the manifest
  path, and `crate--revert` drops that entry before it renders, so `g`
  shows an edited description or dependency list.
- The bookmark record gains a `directory` property.  A record that
  carries one reopens through `crate-visit-directory`, and every other
  record keeps the `find-crate` path.
