# crate.el — Browse Rust Crates in Emacs

A text-based, Emacs-native equivalent of docs.rs, backed by a local
`static.crates.io` JSON dump with on-demand rustdoc builds via Nix.

## Language

**Crate**:
A Rust package published on crates.io, identified by name.
_Avoid_: Package, library, project

**Crate metadata**:
Name, description, homepage, repository, version, and other fields from
the `static.crates.io` JSON dump. Always available once the dump is
loaded — no build required.

**Module tree**:
The hierarchy of public items within a crate — modules, structs, traits,
functions, macros, etc. Extracted from rustdoc JSON.

**Crate docs**:
Full rustdoc output — module tree, type signatures, and docstrings.
Built on-demand via Nix + crane + nightly rustc.

**Doc summary**:
The first sentence of a rustdoc item's documentation string. Rendered
after leaf items in the module tree.
