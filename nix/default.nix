{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
  # Declared by the package.
  magitSection ? emacsPackages.magit-section,
  # Optional; the build compiles against it and the suite loads it.
  evil ? emacsPackages.evil,
  # The build writes their store paths into `crate-cargo-program' and
  # `crate-rustc-program'.
  cargo ? pkgs.cargo,
  rustc ? pkgs.rustc,
  testCratesDb,
  # Rustdoc JSON of the fixture crate, built by nix/harness-doc.nix.
  harnessDoc,
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
  src = lib.cleanSource ./..;

  packageRequires = [ magitSection ];

  turnCompilationWarningToError = true;

  nativeBuildInputs = [
    cargo
    rustc
  ];

  # `packageRequires' decorates the package set, but puts nothing on the
  # load path of this build, so build and check run through a wrapper
  # Emacs that sets `EMACSLOADPATH'.
  preBuild = ''
    export PATH="${emacsWithDeps}/bin:$PATH"
  '';

  # The fixture paths, the version header and the cargo that
  # `crate-visit-directory' runs stay build-only, so patch them in.
  # Each pattern spells the default it replaces.
  postPatch = ''
    substituteInPlace test/crate-test.el \
      --replace-fail '@testCratesDb@' ${testCratesDb}
    substituteInPlace test/crate-tree-test.el \
      --replace-fail '@testHarnessJson@' ${harnessDoc}/harness.json
    substituteInPlace crate.el \
      --replace-fail ';; Version: 0.1.0' ';; Version: ${version}'
    substituteInPlace crate.el \
      --replace-fail '(defcustom crate-cargo-program "cargo"' \
                     '(defcustom crate-cargo-program "${lib.getExe cargo}"'
    substituteInPlace crate.el \
      --replace-fail '(defcustom crate-doc-nix-file nil' \
                     '(defcustom crate-doc-nix-file "${./crate-doc.nix}"'
    substituteInPlace crate.el \
      --replace-fail '(defcustom crate-rustc-program "rustc"' \
                     '(defcustom crate-rustc-program "${lib.getExe rustc}"'
    substituteInPlace crate-tree.el \
      --replace-fail '(defcustom crate-tree-nix-file nil' \
                     '(defcustom crate-tree-nix-file "${./tree-doc.nix}"'
  '';

  checkPhase = ''
    runHook preCheck

    # `turnCompilationWarningToError' covers only the installed files.
    for f in *.el test/*.el; do
      emacs --batch -L . -L test --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile "$f"
    done

    # Load every suite through a glob, so a new `test/<unit>-test.el'
    # needs no edit here.
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
