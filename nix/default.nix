{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
  # The detail buffer is a tree of `magit-section' sections, so the
  # package declares it.
  magitSection ? emacsPackages.magit-section,
  # Optional evil layer.  The package does not depend on evil, but the
  # build compiles evil-crate.el against it and the suite runs with it
  # on the load path.
  evil ? emacsPackages.evil,
  # Fixture SQLite database the ERT suite runs against.  Passed in
  # explicitly so the expression has no hidden dependency on a peer
  # file; the flake wires up nix/test-crates-db.nix.
  testCratesDb,
  # Version string.  The flake derives it from the commit date, so the
  # expression stays standalone-usable (nix-build nix/default.nix) with
  # the default.
  version ? "0.1.0",
}:

let
  emacsWithDeps = emacsPackages.emacsWithPackages (_: [
    magitSection
    evil
  ]);
in
melpaBuild {
  pname = "crate";
  inherit version;
  # `./..' is the repo root: this expression lives in nix/ but the
  # package sources and tests sit one level up.
  src = lib.cleanSource ./..;

  packageRequires = [ magitSection ];

  turnCompilationWarningToError = true;

  # `packageRequires' tells the package set what to propagate, but it
  # does not put anything on the load path of this build, so the build
  # and the check run through a wrapper Emacs that carries the declared
  # dependency and the optional evil layer.  The wrapper sets
  # `EMACSLOADPATH' itself, so it only has to come first on `PATH'.
  preBuild = ''
    export PATH="${emacsWithDeps}/bin:$PATH"
  '';

  # Two substitutions, both only visible inside the build:
  # * the fixture database path, so the suite need not reach for a
  #   hard-coded path;
  # * the version in the package header, which must agree with the
  #   `version' argument or `require' and package.el disagree after
  #   installation.  The pattern spells the header default, so a bump
  #   of `0.1.0' above changes both places.
  postPatch = ''
    substituteInPlace test/crate-test.el \
      --replace-fail '@testCratesDb@' ${testCratesDb}
    substituteInPlace crate.el \
      --replace-fail ';; Version: 0.1.0' ';; Version: ${version}'
  '';

  checkPhase = ''
    runHook preCheck

    # Byte-compile every file with warnings as errors, test files
    # included: `turnCompilationWarningToError' only covers the files
    # melpaBuild installs.
    for f in *.el test/*.el; do
      emacs --batch -L . -L test --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile "$f"
    done

    # Load every suite through a glob, so a new `test/<unit>-test.el'
    # needs no edit here.  printf repeats "-l %s" per match.  failglob
    # makes an empty glob a shell error, so the || guard fires even
    # without `set -e'; the default returns right after, because later
    # commands must keep default glob semantics.  The unquoted
    # $test_args is intentional: the words must split back into
    # -l <file> pairs.
    shopt -s failglob
    test_args=$(printf -- "-l %s " test/*-test.el) || { echo 'no tests matched test/*-test.el' >&2; exit 1; }
    shopt -u failglob
    emacs --batch -L . -L test \
      $test_args \
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
      An optional evil layer in evil-crate.el binds the table and
      the detail buffer in the normal and visual states.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/crate.el";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
}
