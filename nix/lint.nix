{
  pkgs ? import <nixpkgs> { },
  runCommand ? pkgs.runCommand,
  emacsPackages ? pkgs.emacs.pkgs,
  # Source tree to lint.  The flake passes the package's own `src`, so
  # the gate reads exactly the tree the build compiles.
  src,
}:

# Two linters that catch what byte-compilation cannot: package-lint
# checks the package metadata and the naming rules, checkdoc checks the
# docstrings.  Test files live under `test/' and join the glob, so they
# follow the same header and docstring rules as the code under test.
runCommand "crate-lint"
  {
    nativeBuildInputs = [
      (emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
      # Gives Emacs a writable HOME, so the builder needs no `export
      # HOME=$TMPDIR' line and no two checks share a home directory.
      pkgs.writableTmpDirAsHomeHook
    ];
    inherit src;
    meta.description = "crate lint gate (package-lint plus checkdoc)";
  }
  ''
    # `src' may be pre-filtered, so copy the tree instead of relying on
    # what a build would have staged.
    cp -r "$src"/. .

    # `package-lint-main-file' is mandatory once `test/*.el' joins the
    # glob: without it package-lint treats each test file as its own
    # package and complains about the missing `Package-Requires' header.
    # `find-crate' is the public entry point and does not carry the
    # `crate-' prefix, so the sane-prefix list grows by that one name.
    # The four `with-eval-after-load' calls are deliberate: they keep
    # ol-crate, evil-crate and the browse-url handler off the load path
    # until the optional dependency arrives.  package-lint flags that
    # idiom as a warning, so only errors fail the gate.
    emacs --batch -L . -L test \
      -l package-lint \
      --eval '(setq package-lint-main-file "crate.el")' \
      --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|find-crate"))' \
      --eval '(setq package-lint-batch-fail-on-warnings nil)' \
      -f package-lint-batch-and-exit \
      *.el test/*.el

    # checkdoc exits 0 on findings, so gate on empty output.  It reads
    # the source only and needs no load path for the test helpers.
    lint_log=$(emacs --batch -l checkdoc \
      --eval '(setq checkdoc-arguments-in-order-flag t)' \
      --eval '(mapc (lambda (f) (checkdoc-file f)) command-line-args-left)' \
      *.el test/*.el 2>&1)
    if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi

    touch $out
  ''
