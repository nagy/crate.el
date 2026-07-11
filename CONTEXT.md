# crate.el — Browse Rust Crates in Emacs

A text-based, Emacs-native equivalent of docs.rs, backed by a local
`static.crates.io` JSON dump with optional on-demand rustdoc builds.

## Language

**Crate**:
A Rust package published on crates.io, identified by name.
_Avoid_: Package, library, project

**Crate metadata**:
Name, description, homepage, repository, version, and other fields from
the `static.crates.io` JSON dump. Always available once the dump is
loaded — no build required.

**Module structure**:
The tree of public modules within a crate. Provided by `cargo-modules`
when docs are disabled; superseded by the rustdoc JSON output when docs
are built.

**Crate docs**:
Full rustdoc output — module tree, type signatures, and docstrings.
Built on-demand via Nix + crane + nightly rustc's
`-Zunstable-options --output-format json`.

**Tier 1 / Tier 2**:
Internal terms for the two data levels: Tier 1 is metadata (always
present), Tier 2 is rustdoc JSON (built on demand). Not user-visible.
