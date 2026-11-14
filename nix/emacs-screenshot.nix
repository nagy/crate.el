# Render the README screenshot.
#
# Boots Emacs under Xvfb, opens the `Crate: serde' buffer and exports
# the frame.  Both dependencies come from the flake.

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  # The package, inside the screenshot Emacs.
  crateEl,
  # Fixture crates-io.db, used as `crate-data-path'.
  testCratesDb,
  # Supplies mkGitRepository for the bare `.git' directory.
  nurLib,
}:

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
        # The sandbox has no dconf or gsettings database, and without
        # this GTK init makes GLib criticals noisy.
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
          (run-at-time 10 nil (lambda () (kill-emacs 1)))
          (load-theme 'modus-${if light then "operandi" else "vivendi"} t)
          (menu-bar-mode -1)
          (tool-bar-mode -1)
          (toggle-scroll-bar -1)
          (fringe-mode 0)
          (message nil)
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
        (setq crate-data-path "${testCratesDb}")
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
        meta.description = "README screenshot, dual light/dark SVG";
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
