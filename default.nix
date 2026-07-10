{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
}:

melpaBuild {
  pname = "crate";
  version = "0.1.0";
  src = lib.cleanSource ./.;

  packageRequires = [ ];

  turnCompilationWarningToError = true;

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
