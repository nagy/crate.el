# Render the detail buffer as a `magit-section` tree

We decided to derive `crate-mode` from `magit-section-mode` and to
render the detail buffer as a tree of `magit-section` sections.  Every
field line, the Dependencies, Dependents and Modules lines, and every
item of the module tree is a section whose value a re-render can find
again.  `crate-detail-sections-hook` lists the functions that insert the
sections, so a user reorders or drops a section with `setopt` or
`add-hook`, the same way `magit-status-sections-hook` works.

Before this change the buffer was plain text with `crate-field`,
`crate-section` and `crate-module` text properties, folds came from
`outline-minor-mode` with a text-property heading search, and point
survived a render through a hand-written line identity of about 190
lines.

## Considered Options

- **Keep outline-minor-mode and add nested levels.**  The one real gain
  of a section library is that a module folds on its own.  Computing
  `outline-level` from the indentation of the module tree gives that
  gain with no new dependency and a much smaller diff, but leaves the
  buffer unlike any other buffer the user knows, keeps the ~190 lines of
  point identity, and offers no section list to configure.
- **Use `magit-section` only as a rendering library.**  Not possible:
  `magit-section-mode` is a major mode derived from `special-mode`, so
  the layer comes as the parent mode of `crate-mode` or not at all.
- **A hand-written section list.**  A `defcustom` of inserter functions
  over the existing text-property renderer gets the hook with no
  dependency, but every `magit-section` feature — fold, highlight,
  section motions, visibility levels, `evil-fold-list` support, fold
  restore by value, point restore by `magit-section-goto-successor` —
  would stay unimplemented.

## Consequences

- The package gains a hard dependency on `magit-section`, which pulls in
  `compat`, `cond-let`, `llama` and `seq`.  AGPL-3.0-or-later code may
  link GPL-3.0-or-later code, so the license stay compatible.
- The fold code and the point-identity code of `crate.el` shrink by
  about 250 lines, and `crate-detail-sections-hook` and
  `crate-detail-fields` arrive in their place.
- Two cosmetic behaviors follow `magit-section-mode`: `truncate-lines`
  is t, so a long Description clips at the window edge, and the section
  at point carries the Magit highlight.
- `magit-section-inhibit-markers` stays t, because a marker per section
  end makes a render quadratic in the size of the module tree (4000
  nested sections: 1.4s with markers, 0.06s without).  The mode leaves
  `magit-section-show-child-count` at its default instead of silencing
  it: a heading carries no colon, and `magit-insert-heading` writes the
  count into the heading string before the children appear, so no child
  position moves.
- A dependency row keeps its line offset inside the Dependencies
  section and not its text, because a row is not a section.  A row that
  new data pushes down therefore moves point with it.
- `RET` is the built-in `push-button`.  `crate-open-at-point` is gone.
- Every face of the renderer lives in `crate-font-lock-keywords`:
  `font-lock-ensure` removes a `face` and a `font-lock-face` property
  from text that no keyword matches, so the `font-lock-face` that
  `magit-insert-heading` paints does not survive on its own.
- A field label and a section heading read unlike each other: the label
  keeps its colon and takes `crate-field-label`, the heading carries no
  colon and takes `magit-section-heading`, and a module name takes the
  `default` face because it is the content of the section above it.
- `evil-fold-list` holds no `magit-section-mode` entry and matches the
  major mode name, so `evil-crate.el` adds its own `crate-mode` entry.
