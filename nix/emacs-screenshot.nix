# emacs-screenshot.nix — render the README screenshot.
#
# Composes the package under test with a fixture SQLite database,
# boots Emacs under Xvfb, drives it to the `Crate: serde' buffer and
# exports the frame.  Both dependencies are passed in by the flake so
# this expression never re-evaluates nix/default.nix.

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  # The built crate.el package, needed inside the screenshot Emacs.
  crateEl,
  # Fixture crates-io.db (nix/test-crates-db.nix) used as
  # `crate-data-path' so no real database is required.
  testCratesDb,
  # lib from the nur-packages flake input; supplies mkGitRepository,
  # which turns the SVG into a bare `.git' directory for the README.
  nurLib,
}:

let
  # Emacs reads the SQLite database directly now (no JSON dump), so
  # point it at the store path of the fixture database.
  testCratesDbPath = testCratesDb;
in
rec {
  mkEmacsScreenshot =
    {
      emacsCode ? "",
      name ? "emacs-screenshot.png",
      emacs ? pkgs.emacs,
      light ? true,
    }:
    pkgs.runCommandLocal name
      {
        NIX_PATH = "nixpkgs=${pkgs.path}";
        NIX_STATE_DIR = "/build/nix-state";
        # The sandbox has no dconf/gsettings database; without this the
        # GTK init makes GLib criticals noisy (and Emacs sometimes exits
        # before the frame is exported).
        GSETTINGS_BACKEND = "memory";
        nativeBuildInputs = [
          (emacs.pkgs.withPackages (epkgs: [
            epkgs.modus-themes
            epkgs.marginalia
            crateEl
          ]))
          pkgs.xvfb-run
          pkgs.iosevka
        ];
        emacsCodeFile = pkgs.writeText "emacscode.el" emacsCode;
        screenshotScript = pkgs.writeText "script.el" ''
          (run-at-time 10 nil (lambda () (kill-emacs 1)))   ; fallback killing
          (load-theme 'modus-${if light then "operandi" else "vivendi"} t)
          (menu-bar-mode -1)
          (tool-bar-mode -1)
          (toggle-scroll-bar -1)
          (fringe-mode 0)
          (message nil)                            ; clear out echo area
          (defun screenshot-capture ()
            "Export the selected frame as PNG and exit."
            (let ((data (x-export-frames (selected-frame) 'png)))
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert data)
                (write-region (point-min) (point-max) (getenv "out")))
              (kill-emacs 0)))
        '';
      }
      ''
        mkdir -p "$NIX_STATE_DIR"
        HOME=$PWD \
          xvfb-run --server-args="-screen 0 1920x1080x24" \
            emacs --quick --eval="(defalias (quote display-warning) (quote ignore))" \
            -f package-initialize --fullscreen \
            -l modus-themes \
            --font Iosevka\ 30 \
            -l $screenshotScript \
            -l $emacsCodeFile
      '';

  crateScreenshot =
    {
      light ? true,
    }:
    mkEmacsScreenshot {
      inherit light;
      emacsCode = ''
        (require 'crate)
        (require 'marginalia)
        (setq crate-data-path "${testCratesDbPath}")
        (defun screenshot-poll ()
          "Poll until the crate buffer is displayed, then capture."
          (when (get-buffer "*Warnings*")
            (kill-buffer "*Warnings*"))
          (if (and (get-buffer "Crate: serde")
                   (get-buffer-window "Crate: serde"))
              (progn
                (redisplay t)
                (screenshot-capture))
            (run-at-time 0.05 nil #'screenshot-poll)))
        (run-at-time 1 nil (lambda ()
                             (find-crate "serde")
                             (run-at-time 0.2 nil #'screenshot-poll)))
      '';
    };

  finalizePng =
    image:
    pkgs.runCommandLocal image.name
      {
        inherit image;
        nativeBuildInputs = [
          pkgs.imagemagick
          pkgs.pngquant
        ];
      }
      ''
        magick "$image" \
          -gravity Northwest \
          -bordercolor black -border 1 \
          -mosaic +repage \
          \( +clone -background black -shadow "80x3+3+3" \) \
          +swap \
          -background none -mosaic +repage tmp.png
        pngquant --speed 1 --force --output $out tmp.png
      '';

  svgDualTheme =
    lightImg: darkImg:
    pkgs.runCommandLocal "emacs-screenshot.svg"
      {
        inherit lightImg darkImg;
        template = pkgs.writeText "template.svg" ''
          <?xml version="1.0" encoding="utf-8"?>
          <svg version="1.1" xmlns="http://www.w3.org/2000/svg" x="0px" y="0px"
               viewBox="0 0 1920 1080" xml:space="preserve">
            <defs>
              <style type="text/css">
                  image.light { display: inherit; }
                  image.dark { display: none; }
                  @media ( prefers-color-scheme:dark ) {
                      image.light { display: none; }
                      image.dark { display: inherit; }
                  }
              </style>
            </defs>
            <image class="light" height="1080" width="1920" href="data:image/png;base64,@lightThemeB64@" ></image>
            <image class="dark" height="1080" width="1920" href="data:image/png;base64,@darkThemeB64@" ></image>
          </svg>
        '';
      }
      ''
        lightThemeB64=$(base64 -w0 < $lightImg)
        darkThemeB64=$(base64 -w0 < $darkImg)
        substitute $template $out \
          --subst-var lightThemeB64 \
          --subst-var darkThemeB64
      '';

  png = finalizePng (crateScreenshot {
    light = true;
  });

  svg =
    svgDualTheme
      (finalizePng (crateScreenshot {
        light = true;
      }))
      (
        finalizePng (crateScreenshot {
          light = false;
        })
      );

  gitrepo = nurLib.mkGitRepository svg;

}
