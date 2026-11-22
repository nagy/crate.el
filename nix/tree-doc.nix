# tree-doc.nix — rustdoc JSON of a local crate, built in the sandbox
#
# Companion of crate.el, invoked as:
#   nix-build tree-doc.nix --argstr crateDir /abs/workspace \
#     --argstr manifestPath my-crate/Cargo.toml --argstr libName my_crate
#
# Output: $out/tree.json
#
# CRATE-DIR is the workspace root, because a member resolves its path
# dependencies and its `[patch]' entries against siblings.  The build
# copies that tree, so the crate source, its lockfile and the rustc
# version reach the derivation hash and the Nix store caches the
# document.  A crate without a lockfile builds with `--offline' alone,
# which succeeds for a dependency-free crate and fails for every other
# crate, because no resolver answers inside the sandbox.
#
# Stable rustc emits JSON behind `-Z unstable-options', and
# RUSTC_BOOTSTRAP lifts the gate.  The rustc version pins the document
# format.

{
  pkgs ? import <nixpkgs> { },
  # Absolute path of the workspace root.
  crateDir,
  # Manifest of the documented package, relative to CRATE-DIR.
  manifestPath,
  # Name of the library target, which names the JSON file.
  libName,
}:

let
  lib = pkgs.lib;

  src = builtins.path {
    path = crateDir;
    name = "crate-tree-src";
    filter =
      path: _type:
      let
        base = baseNameOf path;
      in
      !(lib.elem base [
        "target"
        ".git"
        ".direnv"
        ".cargo"
      ])
      && !(lib.hasSuffix "~" base);
  };

  lockFile = src + "/Cargo.lock";
  hasLock = builtins.pathExists lockFile;

  # The unpacked copy sits in the build directory and stays writable,
  # so a crate without a lockfile can write one there.  A manifest path
  # into the store copy stays read-only and no build writes it.
  manifest = "${manifestPath}";

  common = {
    pname = "crate-tree-doc";
    version = "0.1.0";
    inherit src;

    nativeBuildInputs = [
      pkgs.cargo
      pkgs.rustc
    ];

    RUSTC_BOOTSTRAP = "1";
    RUSTDOCFLAGS = "-Zunstable-options --output-format json";
    CARGO_NET_OFFLINE = "true";

    doCheck = false;
    preferLocalBuild = true;

    installPhase = ''
      runHook preInstall

      install -D "target/doc/${libName}.json" $out/tree.json

      runHook postInstall
    '';

    meta = {
      description = "Rustdoc JSON of a local Rust crate";
    };
  };
in
if hasLock then
  # `importCargoLock' reads every crate of the lockfile, so the vendor
  # step needs no hash of its own and no network during the build.
  pkgs.rustPlatform.buildRustPackage (
    common
    // {
      cargoDeps = pkgs.rustPlatform.importCargoLock { inherit lockFile; };

      buildPhase = ''
        runHook preBuild

        cargo doc --lib --no-deps --document-private-items --locked \
          --manifest-path ${manifest}

        runHook postBuild
      '';
    }
  )
else
  pkgs.stdenv.mkDerivation (
    common
    // {
      buildPhase = ''
        runHook preBuild

        export HOME=$TMPDIR
        export CARGO_HOME=$TMPDIR/cargo-home
        mkdir -p "$CARGO_HOME"

        cargo doc --lib --no-deps --document-private-items --offline \
          --manifest-path ${manifest}

        runHook postBuild
      '';
    }
  )
