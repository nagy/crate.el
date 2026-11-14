{
  description = "Browse Rust crates from Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # Provides lib/git.nix with mkGitRepository, used to publish the
    # README screenshot as a git branch.
    nur-packages = {
      url = "github:nagy/nur-packages";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nur-packages,
      ...
    }:
    # Last commit date as YYYY-MM-DD, for the version string.
    let
      lastModifiedDate = self.sourceInfo.lastModifiedDate;
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Elisp is architecture-independent.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          ...
        }:
        let
          # Fixture crates-io.db for the test suite and the screenshot.
          testCratesDb = pkgs.callPackage ./nix/test-crates-db.nix { };

          # Version: `<upstream>-unstable-<commit date>'.
          crateEl = pkgs.callPackage ./nix/default.nix {
            inherit testCratesDb harnessDoc;
            version = "0.1.0-unstable-${commitDate}";
          };

          # checkdoc plus package-lint over the package and test sources.
          lint = pkgs.callPackage ./nix/lint.nix { inherit (crateEl) src; };

          # Rustdoc JSON of the test fixture crate.  The tree suite reads
          # it through a placeholder, so the suite runs no rustc and
          # parses the same document on every machine.
          harnessDoc = pkgs.callPackage ./nix/harness-doc.nix { };

          # Needs Xvfb, so it stays out of `checks'.
          screenshot = pkgs.callPackage ./nix/emacs-screenshot.nix {
            inherit crateEl testCratesDb;
            nurLib = import "${nur-packages}/lib/git.nix" { inherit pkgs; };
          };
        in
        {
          packages = {
            crate = crateEl;
            default = crateEl;

            # README screenshot as a dual light/dark SVG.  `gitrepo' is
            # the bare `.git' directory of the branch that the README
            # links to.
            screenshot = screenshot.svg;
            inherit (screenshot) gitrepo;
          };

          checks = {
            default = crateEl;
            inherit crateEl lint;

            # The fixture JSON builds on its own, so a broken fixture
            # crate fails here before the suite ever reads it.
            harness-doc = harnessDoc;
          };

          # Emacs plus the tools that the rustdoc path, the local-crate
          # command and the tests shell out to.
          devShells.default = pkgs.mkShell {
            # The wrapper carries magit-section and evil on the load
            # path.  Evil stays optional for the package, but the suite
            # needs it.
            packages = [
              (pkgs.emacsPackages.emacsWithPackages (epkgs: [
                epkgs.magit-section
                epkgs.evil
              ]))
              pkgs.nix
              pkgs.sqlite
              pkgs.cargo
              pkgs.rustc
            ];
          };

          formatter = pkgs.nixfmt;
        };
    };
}
