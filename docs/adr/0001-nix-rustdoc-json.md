# Build crate docs on-demand with Nix, crane, and nightly rustdoc JSON

We decided to build crate documentation (module tree, type signatures,
docstrings) on-demand using Nix derivations, the Crane build framework
for artifact caching, and nightly rustc's unstable
`-Zunstable-options --output-format json`.  When a user opens a crate
that has not been built yet, `crate.el` shells out synchronously to
`nix-build` with an inline Nix expression shipped alongside the package.
The resulting rustdoc JSON is parsed and rendered into the same Emacs
buffer that displays the crate metadata.

## Considered Options

- **Scrape docs.rs HTML.** Fragile, and docs.rs doesn't expose a machine-readable
  API for parsed docs.
- **Parse source from `.crate` tarballs with tree-sitter.** No compilation
  required, but tree-sitter grammars don't expose type resolution or trait
  impls — the result is shallow.
- **Accept the gap.** Module structure from `cargo-modules` plus a link to
  docs.rs is the 80% solution, but we want the richer experience.
- **Pre-build a top-N set of crates.** Solves the wait-time problem but
  limits coverage; users of less-popular crates get nothing.  The on-demand
  approach covers every crate.

## Consequences

- `crate.el` gains a hard dependency on Nix (daemon + `nix-build` on PATH)
  for the doc-building path, gated by a `defcustom` so users can opt out.
- Crane is fetched at evaluation time via `builtins.fetchTarball` (pinned to
  a rev), avoiding a flake-only dependency.
- The nightly toolchain is pinned via the `rust-bin` overlay (oxalica),
  fetched alongside Crane.  This dependency is expected to be temporary
  once `--output-format json` stabilizes.
- Module-structure display via `cargo-modules` is retained as the fallback
  when the doc-building defcustom is disabled.
