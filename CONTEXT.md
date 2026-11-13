# crate.el — Browse Rust Crates in Emacs

A text-based, Emacs-native equivalent of docs.rs, backed by a local
crates.io SQLite database with on-demand rustdoc builds via Nix.

## Language

**Crate**:
A Rust package published on crates.io, identified by name.
_Avoid_: Package, library, project

**Crate metadata**:
Name, description, homepage, repository, version, and other fields from
the crates.io SQLite database. Always available once the database is
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

**Detail buffer**:
The read-only buffer that one crate opens in, named `Crate: <name>` and
rendered by `crate--render`.
_Avoid_: Page, view

**Section**:
One collapsible region of a detail buffer, carried by a `magit-section`
object with a type and a value. The groups are the field lines,
Dependencies, Dependents and Modules, and every module-tree item is a
section of its own.

**Field**:
One line of a detail buffer that shows a value of the crate metadata,
such as Version or Downloads. A field is a section whose value is the
column name of the SQLite row.
_Avoid_: Property, attribute

**Section inserter**:
A function that inserts one section of a detail buffer, listed in
`crate-detail-sections-hook`. It takes no arguments and reads
`crate-name` and `crate-data`.
