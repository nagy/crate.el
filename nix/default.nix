{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
  # Fixture SQLite database the ERT suite runs against.  Passed in
  # explicitly so the expression has no hidden dependency on a peer
  # file; the flake wires up nix/test-crates-db.nix.
  testCratesDb,
}:

melpaBuild {
  pname = "crate";
  version = "0.1.0";
  # `./..' is the repo root: this expression lives in nix/ but the
  # package sources and tests sit one level up.
  src = lib.cleanSource ./..;

  packageRequires = [ ];

  turnCompilationWarningToError = true;

  # Bake the store path of the fixture database into the test suite.
  postPatch = ''
    substituteInPlace crate-tests.el \
      --replace-fail '@testCratesDb@' ${testCratesDb}
  '';

  checkPhase = ''
    runHook preCheck
    for f in crate.el ol-crate.el crate-tests.el; do
      emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile "$f"
    done
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
      from a local crates.io SQLite database.  Includes a major
      mode for viewing crate details, bookmark support, Org link
      integration, and a browse-url handler for crates.io URLs.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/crate.el";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
}
