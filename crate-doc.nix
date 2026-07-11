# crate-doc.nix — companion Nix file for crate.el
#
# Invoked by crate.el as:
#   nix-build crate-doc.nix --argstr crateName serde
#
# Fully sandbox-safe: downloads the crates.io-index via fetchFromGitHub
# (fixed-output derivation), generates Cargo.lock offline, then builds
# rustdoc JSON via crane + nightly rustc.  Every derivation is cached
# in the Nix store — repeated requests reuse cached results.
#
# Output: a directory containing rustdoc JSON files for the crate
# (under $out/share/doc/).
#
# TODO: switch to stable rustc once
# <https://github.com/rust-lang/cargo/issues/12103> stabilizes.

{
  pkgs ? import <nixpkgs> { },
  crateName,
}:

let
  # ---------------------------------------------------------------------------
  # Pinned dependencies — no flakes, no channels, pure evaluation
  # ---------------------------------------------------------------------------

  rustOverlaySrc = builtins.fetchTarball {
    # Pinned rev: e598b37857b895b81020a65a802ef55f5bbed72f
    url = "https://github.com/oxalica/rust-overlay/archive/e598b37857b895b81020a65a802ef55f5bbed72f.tar.gz";
    sha256 = "133ws36cq49h7h66apzjiin3mdz5260jgp08jisnvrnfxx1ajmra";
  };
  rustOverlay = import rustOverlaySrc;
  pkgsNightly = pkgs.extend rustOverlay;

  nightlyToolchain = pkgsNightly.rust-bin.nightly.latest.default.override {
    extensions = [ "rust-src" ];
  };

  craneSrc = builtins.fetchTarball {
    url = "https://github.com/ipetkov/crane/archive/v0.20.2.tar.gz";
    sha256 = "0lz1wp9v5iqsl4xcapvjmrkcl310pw8qkkmqd6wicmcj29688z3y";
  };
  crane = import craneSrc { inherit pkgs; };

  # ---------------------------------------------------------------------------
  # Offline lockfile generation (sandbox-safe, like mkCargoLock)
  # ---------------------------------------------------------------------------

  cratesIoIndex = pkgs.fetchFromGitHub {
    owner = "rust-lang";
    repo = "crates.io-index";
    rev = "b0be0971bd0fc1a9496da6e44e4391205f26445f";
    hash = "sha256-mOBKMzftjO6MpGsYqec4nakDJwP1ci0Jb3k2dHQ1t2g=";
  };

  # cargo config that uses the local crates.io-index, fully offline
  cargoConfig = pkgs.linkFarm "crate-doc-cargo-home" {
    "config.toml" = pkgs.writers.writeTOML "config.toml" {
      source.crates-io.replace-with = "local-copy";
      source.local-copy.local-registry = pkgs.linkFarm "crates.io-index" {
        index = cratesIoIndex;
      };
    };
  };

  cargoToml = pkgs.writeText "Cargo.toml" ''
    [package]
    name = "crate-doc-driver"
    version = "0.0.1"
    edition = "2021"

    [dependencies]
    ${crateName} = "*"
  '';

  cargoLock =
    pkgs.runCommand "crate-doc-lock-${crateName}"
      {
        nativeBuildInputs = [ pkgs.cargo ];
        CARGO_HOME = cargoConfig;
      }
      ''
        mkdir src
        touch src/main.rs
        ln -s ${cargoToml} Cargo.toml
        cargo generate-lockfile
        cp Cargo.lock $out
      '';

  # ---------------------------------------------------------------------------
  # Project source
  # ---------------------------------------------------------------------------

  src = pkgs.runCommand "crate-doc-src-${crateName}" { } ''
    mkdir -p $out/src
    touch $out/src/lib.rs
    ln -s ${cargoToml} $out/Cargo.toml
    ln -s ${cargoLock} $out/Cargo.lock
  '';

in

crane.cargoDoc {
  inherit src;

  cargoArtifacts = null;

  cargoDocExtraArgs = "--output-format json";

  cargoExtraArgs = "-Zunstable-options";

  doCheck = false;

  nativeBuildInputs = [ nightlyToolchain ];

  RUSTC_BOOTSTRAP = "1";

  preferLocalBuild = false;
}
