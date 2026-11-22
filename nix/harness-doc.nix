# harness-doc.nix — rustdoc JSON for the test fixture crate
#
# The fixture crate at test/fixtures/harness/ holds no dependency, so
# this derivation needs no registry, no lockfile and no network.  It
# documents the crate with `--document-private-items`, which is the
# only way a private item reaches the document, and installs the JSON
# as $out/harness.json.  The ERT suite reads that path through the
# `@testHarnessJson@` placeholder that nix/default.nix substitutes.
#
# Stable rustc emits JSON behind `-Z unstable-options'.  RUSTC_BOOTSTRAP
# lifts the gate, so no nightly toolchain is needed.  The rustc version
# pins the document format: rustc 1.99 answers format_version 61.

{
  pkgs ? import <nixpkgs> { },
}:

pkgs.stdenv.mkDerivation {
  pname = "crate-test-harness-doc";
  version = "0.1.0";

  preferLocalBuild = true;

  src = ./../test/fixtures/harness;

  nativeBuildInputs = [
    pkgs.cargo
    pkgs.rustc
  ];

  RUSTC_BOOTSTRAP = "1";
  RUSTDOCFLAGS = "-Zunstable-options --output-format json";
  CARGO_NET_OFFLINE = "true";

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    export CARGO_HOME=$TMPDIR/cargo-home
    mkdir -p "$CARGO_HOME"

    cargo doc --lib --no-deps --document-private-items --offline

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -D target/doc/harness.json $out/harness.json

    runHook postInstall
  '';

  meta = {
    description = "Rustdoc JSON of the crate.el test fixture crate";
  };
}
