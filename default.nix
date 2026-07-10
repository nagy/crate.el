{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
}:

let
  testCratesJson = pkgs.writeText "test-crates.json" ''
    {
      "serde": {
        "created_at": "2020-01-09 20:22:35.387945+00",
        "description": "A generic serialization/deserialization framework",
        "documentation": "https://docs.rs/serde",
        "homepage": "https://serde.rs",
        "id": 11646.0,
        "max_features": null,
        "max_upload_size": null,
        "name": "serde",
        "repository": "https://github.com/serde-rs/serde",
        "trustpub_only": false,
        "updated_at": "2026-06-27 22:26:12.785151+00"
      },
      "tokio": {
        "created_at": "2016-09-27 20:50:13.879354+00",
        "description": "An event-driven, non-blocking I/O platform for writing asynchronous I/O backed applications.",
        "documentation": "https://docs.rs/tokio",
        "homepage": null,
        "id": 3844.0,
        "max_features": null,
        "max_upload_size": null,
        "name": "tokio",
        "repository": "https://github.com/tokio-rs/tokio",
        "trustpub_only": false,
        "updated_at": "2026-07-09 16:41:56.215247+00"
      }
    }
  '';
in

melpaBuild {
  pname = "crate";
  version = "0.1.0";
  src = lib.cleanSource ./.;

  packageRequires = [ ];

  turnCompilationWarningToError = true;

  postPatch = ''
    substituteInPlace crate-tests.el \
      --replace-fail '@testCratesJson@' ${testCratesJson}
  '';

  checkPhase = ''
    runHook preCheck
    emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile crate.el
    emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile crate-tests.el
    emacs --batch -L . \
      -l crate-tests.el \
      -f ert-run-tests-batch-and-exit
    runHook postCheck
  '';

  doCheck = true;

  meta = {
    description = "Browse Rust crates from Emacs";
    longDescription = ''
      Provides an interactive interface for browsing Rust crates
      from a local static.crates.io JSON dump.  Includes a major
      mode for viewing crate details, bookmark support, Org link
      integration, and a browse-url handler for crates.io URLs.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/crate.el";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
}
