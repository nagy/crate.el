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
