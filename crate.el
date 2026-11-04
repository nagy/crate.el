;;; crate.el --- Rust crates -*- lexical-binding: t -*-

;; Copyright (C) 2025-2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; This package provides an interactive interface for browsing Rust
;; crates from a local crates.io SQLite database.
;;
;; Data sources are configurable via `defcustom':
;;
;;   - `crate-data-path'  -- Path to a crates-io.db SQLite database.
;;
;; Commands:
;;
;;   M-x find-crate  -- look up a Rust crate by name
;;   M-x crate-copy-dependency -- copy a Cargo.toml dependency line
;;   M-x crate-install-cargo-toml-capf -- crate names in Cargo.toml
;;
;; Deep integration:
;;
;;   - `crate-mode' (major mode) powers the detail buffer with
;;     bookmark support.
;;
;;   - `crate-install-browse-url-handler' registers a handler so
;;     that crates.io URLs opened with `browse-url' are redirected
;;     to `find-crate'.
;;
;;   - Org link support for `crate:' links via `ol-crate'.
;;
;; Usage:
;;
;;   (crate-install-browse-url-handler)

;;; Code:

(require 'bookmark)
(require 'json)
(require 'cl-lib)
(require 'goto-addr)
;; `thing-at-point-provider-alist' is defined here; crate-mode sets it
;; buffer-locally, so the file must be loaded for the variable to exist.
(require 'thingatpt)



(defvar browse-url-default-handlers)
(defvar thing-at-point-provider-alist)

(defvar-local crate-name nil)
(defvar-local crate-data nil)

(defgroup crate nil
  "Browse Rust crates from a local SQLite database."
  :group 'tools
  :prefix "crate-"
  :link '(url-link :tag "Repository" "https://github.com/nagy/crate.el"))

(defcustom crate-data-path nil
  "Path to a crates-io.db SQLite database.

The database should contain a `crates' table with columns:
name, display_name, description, documentation, homepage,
repository, created_at, updated_at.

The `name` column holds the published crate name, `display_name`
the pretty form.  Lookups use canonical names (see
`crate--canonical-name`); display uses the `name' field.

All caches key on this path, so changing it — even via plain
`setq' — serves fresh data with no `crate-refresh-cache' call."
  :type 'file
  :group 'crate)


(defconst crate--crates-io-url "https://crates.io/crates/"
  "Base URL for crates.io crate pages.")

(defcustom crate-annotation-width 70
  "Maximum width of the description annotation shown during completion."
  :type 'integer
  :group 'crate)

(defcustom crate-browse-name-min-width 20
  "Smallest width of the Crate column of a narrow browse table.
The table shrinks its columns when the window cannot hold them,
and the Crate column stops here."
  :type 'integer
  :group 'crate)

(defcustom crate-browse-description-min-width 30
  "Width that the Description column keeps when the columns shrink.
The last column takes the remaining space, so this value decides
how much the columns before it must give up."
  :type 'integer
  :group 'crate)

(defcustom crate-browse-refit-max-entries 2000
  "Largest table that refits its columns after a window size change.
A refit reprints the table, and `tabulated-list-print' sorts the
entries again, so a full crates.io dump would stall on every frame
resize.  A table above this size keeps the widths of its last fit.
Set it to nil to refit every table."
  :type '(choice (const :tag "Every table" nil) integer)
  :group 'crate)

(defcustom crate-browse-version-max-width 28
  "Widest Version column of a browse table.
The column grows to the longest visible version, up to this width,
so a pre-release suffix stays readable."
  :type 'integer
  :group 'crate)


(defun crate--canonical-name (name)
  "Return the canonical form of crate NAME.
Downcases and replaces hyphens with underscores for consistent
lookup in `crate--data-cache'."
  (declare (pure t) (side-effect-free t))
  (downcase (string-replace "-" "_" name)))


(defcustom crate-repository-directory nil
  "Directory for local crate repository checkouts.
If non-nil and the crate has a repository URL, `crate-mode' sets
`default-directory' to a local checkout directory derived from
the URL.  Can be a string (a directory path under which repo
directories live) or a function that receives the repository URL
and returns a directory path."
  :type '(choice (const :tag "Off" nil)
                 (directory :tag "Base directory")
                 (function :tag "Mapping function"))
  :group 'crate)

(defcustom crate-visit-hook nil
  "Hook run after `find-crate' opens a crate detail buffer.

Runs in the Crate: <name> buffer, after `crate-name' and
`crate-data' have been set (and the buffer rendered).  This is the
single place all entry points converge: interactive `find-crate',
crates.io URL handling, `crate-browse-visit', bookmarks, and
dependency buttons.

Functions may use the buffer-local `crate-name' and `crate-data'
to, e.g., set `default-directory' to a local checkout."
  :type 'hook
  :group 'crate)

(defcustom crate-display-buffer-action nil
  "Display action for the `find-crate' detail buffer.
nil keeps `switch-to-buffer', which replaces the current buffer.
Set it to `crate--other-window-action' to open a crate beside the
buffer that you started from.  The `o' key and the middle mouse
button of `crate-browse-mode' bind this option for one call."
  :type '(choice (const :tag "Selected window" nil) function)
  :group 'crate)

(defcustom crate-goto-address t
  "Whether a detail buffer links the URLs in its text.
When non-nil, `goto-address-mode' turns the homepage, repository
and documentation URL of a crate into a link, so a click and RET
open it.  Set it to nil to keep the URLs as plain text."
  :type 'boolean
  :group 'crate)

(defconst crate--other-window-action
  '((display-buffer-reuse-window display-buffer-pop-up-window)
    (inhibit-same-window . t))
  "Display action that opens a buffer in another window.
Emacs has no ready-made action for this: it reuses a window that
already shows the buffer, or splits one, and never uses the
selected window.")

(defun crate--display-buffer (buffer)
  "Show BUFFER through `crate-display-buffer-action'."
  (if crate-display-buffer-action
      (pop-to-buffer buffer crate-display-buffer-action)
    (switch-to-buffer buffer)))

;;; Cache

(defvar crate--data-cache (make-hash-table :test #'equal))

(defun crate--list ()
  "Load crate data from the SQLite database at `crate-data-path'.
Returns a hash table keyed by canonical crate name, or nil if
the file is missing or cannot be read.  Results are memoized
via `with-memoization'; a :failed sentinel prevents retrying
a corrupt or missing file on every subsequent call.  The cache
key includes `crate-data-path', so a path switch self-invalidates."
  (let ((cached
         (with-memoization (gethash (list 'data crate-data-path) crate--data-cache)
           (if (and crate-data-path (file-exists-p crate-data-path))
               (condition-case nil
                   (let* ((db (sqlite-open crate-data-path))
                          ;; `unwind-protect', never `prog1': a failed
                          ;; query must not leak the handle.
                          (rows
                           (unwind-protect
                               (sqlite-select
                                db
                                "SELECT name, display_name, description,
                                    documentation, homepage, repository,
                                    created_at, updated_at,
                                    latest_version, license, downloads
                             FROM crates")
                             (sqlite-close db)))
                          (table (make-hash-table :test #'equal)))
                     (dolist (row rows)
                       (let ((entry (make-hash-table :test #'equal)))
                         (puthash "name" (nth 0 row) entry)
                         (when (nth 1 row)
                           (puthash "display_name" (nth 1 row) entry))
                         (when (nth 2 row)
                           (puthash "description" (nth 2 row) entry))
                         (when (nth 3 row)
                           (puthash "documentation" (nth 3 row) entry))
                         (when (nth 4 row)
                           (puthash "homepage" (nth 4 row) entry))
                         (when (nth 5 row)
                           (puthash "repository" (nth 5 row) entry))
                         (when (nth 6 row)
                           (puthash "created_at" (nth 6 row) entry))
                         (when (nth 7 row)
                           (puthash "updated_at" (nth 7 row) entry))
                         (when (nth 8 row)
                           (puthash "latest_version" (nth 8 row) entry))
                         (when (nth 9 row)
                           (puthash "license" (nth 9 row) entry))
                         (puthash "downloads" (or (nth 10 row) 0) entry)
                         (puthash (crate--canonical-name (nth 0 row)) entry table)))
                     table)
                 (error :failed))
             :failed))))
    (unless (eq cached :failed)
      cached)))


;;; Doc Build

(defcustom crate-doc-enable t
  "When non-nil, enable on-demand rustdoc builds via Nix.
When enabled, `crate-mode' can build and display full rustdoc
documentation (module trees, type signatures, docstrings) by
invoking `nix-build' on the companion crate-doc.nix file.
When nil, no module tree is shown.

Requires Nix and the nightly rustc toolchain (fetched
automatically by the Nix expression)."
  :type 'boolean
  :group 'crate)

(defvar crate-doc--cache (make-hash-table :test #'equal)
  "Cache mapping (crate name, database path) keys to parsed rustdoc JSON.
Memoized — cleared by `crate-refresh-cache'.")

(defun crate-doc--nix-path ()
  "Return the absolute path to the companion crate-doc.nix file.
Uses `locate-library' to find it relative to crate.el on
`load-path' (the source tree keeps it in the nix/ subdirectory,
the installed package next to crate.el).  Returns nil if the file
cannot be found."
  (when-let* ((lib (locate-library "crate"))
              (dir (file-name-directory lib)))
    (seq-find #'file-exists-p
              (list (expand-file-name "crate-doc.nix" dir)
                    (expand-file-name "nix/crate-doc.nix" dir)))))

(defvar crate-doc--in-flight (make-hash-table :test #'equal)
  "In-flight async doc builds keyed by crate name.
A second request for the same crate reuses the running build.")

(defvar crate-doc--generation 0
  "Generation counter for async doc builds.
Bumped by `crate-refresh-cache'; results from older generations
are discarded.")

(defun crate-doc--json-from-build (out)
  "Parse the rustdoc JSON from nix-build output buffer OUT, or nil.
Extracts the Nix store path from the last output line, then picks
the crate's JSON (non-driver) under share/doc."
  (with-current-buffer out
    (goto-char (point-max))
    (forward-line -1)
    (let ((path (string-trim (buffer-substring (point) (point-max)))))
      (when (and path (not (string-empty-p path)) (file-exists-p path))
        (let ((doc-dir (expand-file-name "share/doc" path)))
          (when (file-directory-p doc-dir)
            (let ((json-file
                   ;; Pick the crate's JSON (non-driver).
                   (car (cl-remove-if
                         (lambda (f)
                           (or (string-match-p "/crate_doc_driver\\.json$" f)
                               (not (string-suffix-p ".json" f))))
                         (directory-files-recursively doc-dir "")))))
              (when json-file
                (with-temp-buffer
                  (insert-file-contents json-file)
                  (goto-char (point-min))
                  (condition-case nil
                      (json-parse-buffer)
                    (error nil)))))))))))

(defun crate-doc--start-build (name buffer)
  "Start an async rustdoc build for crate NAME, re-rendering BUFFER.
Returns non-nil when a build is running (started now or reused),
nil when unavailable (missing `nix-build', missing crate-doc.nix,
or a spawn failure) — in which case the `:failed' sentinel caches
the negative (graceful degradation: no module tree, no error).
The process sentinel stores the parsed JSON and re-renders BUFFER;
results from stale generations (after `crate-refresh-cache') are
discarded."
  (cond
   ;; Reuse the running build instead of spawning a second one.
   ((gethash name crate-doc--in-flight) t)
   ((when-let* ((nix-path (crate-doc--nix-path))
                ((executable-find "nix-build")))
      (let ((gen crate-doc--generation)
            (path crate-data-path)
            (out (generate-new-buffer " *crate-doc-build*")))
        (condition-case nil
            (progn
              (make-process
               :name (format "crate-doc-build-%s" name)
               :buffer out
               :command (list "nix-build" nix-path
                              "--argstr" "crateName" name)
               :noquery t
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (unwind-protect
                       (let ((json (and (eq 0 (process-exit-status proc))
                                        (crate-doc--json-from-build out))))
                         (remhash name crate-doc--in-flight)
                         ;; Discard stale results (e.g. cache refresh
                         ;; mid-build) — the generation moved on.
                         (when (= gen crate-doc--generation)
                           (puthash (list name path) (or json :failed)
                                    crate-doc--cache)
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (crate--render)))
                           (unless json
                             (message "crate: rustdoc build failed for %s"
                                      name))))
                     (when (buffer-live-p out)
                       (kill-buffer out))))))
              (puthash name t crate-doc--in-flight)
              t)
          (error
           ;; Spawn failure: degrade like missing Nix.
           (when (buffer-live-p out)
             (kill-buffer out))
           (puthash (list name path) :failed crate-doc--cache)
           nil)))))
   (t
    ;; Missing nix-build or crate-doc.nix: cache the negative so
    ;; renders don't re-probe; `crate-refresh-cache' clears it.
    (puthash (list name crate-data-path) :failed crate-doc--cache)
    nil)))

(defun crate-doc--json (name)
  "Return the parsed rustdoc JSON for crate NAME, or nil.
First use starts an ASYNC build (see `crate-doc--start-build') and
returns nil; the crate buffer re-renders with the module tree when
the build completes.  Also nil while building, when docs cannot be
built, or after a prior build failed (cached `:failed' sentinel)."
  (when-let* ((table (and crate-doc-enable (crate--list))))
    (when (gethash name table)
      (let ((cached (gethash (list name crate-data-path) crate-doc--cache)))
        (cond
         ((eq cached :failed) nil)
         (cached cached)
         (t
          (crate-doc--start-build name (current-buffer))
          nil))))))

(defun crate-doc--module-tree (json)
  "Return the module tree from rustdoc JSON.
JSON is a hash table as returned by `json-parse-buffer' from a
rustdoc JSON file.  Returns a nested list:

  ((NAME KIND (CHILDREN...) DOC) ...)

where children have the same structure.  KIND is a symbol:
`module', `struct', `trait', `function', `macro', `enum', etc.
DOC is the first sentence of the item's docstring, or nil.
Non-module items have nil as children."
  (declare (pure t) (side-effect-free t))
  (when-let* ((root-id (gethash "root" json))
              (index (gethash "index" json))
              (root-num (if (integerp root-id) root-id
                          (string-to-number root-id)))
              (root-str (number-to-string root-num))
              (root-item (gethash root-str index)))
    (cl-labels
        ((doc-summary (raw)
           (when (and raw (not (eq raw :null))
                      (not (string-empty-p raw)))
             (let ((s (string-replace "\n" " " raw)))
               (string-limit
                (or (when-let* ((dot (string-search ". " s)))
                      (substring s 0 (1+ dot)))
                    (when-let* ((hash (string-search " ##" s)))
                      (substring s 0 hash))
                    s)
                80))))
         (walk (id-str)
           (when-let* ((item (gethash id-str index)))
             (let* ((name (gethash "name" item))
                    (inner (gethash "inner" item))
                    (docs (doc-summary (gethash "docs" item)))
                    (kind (and inner
                               (let ((keys (hash-table-keys inner)))
                                 (when keys (intern (car keys))))))
                    (children
                     (when (and inner (eq kind 'module))
                       (when-let* ((mod (gethash "module" inner))
                                   (ids (gethash "items" mod)))
                         ;; `walk' returns nil for IDs missing from the
                         ;; index; drop them so callers never see nil
                         ;; entries (which `insert-doc-tree' can't render).
                         (delq nil (mapcar (lambda (id)
                                             (walk (if (integerp id)
                                                       (number-to-string id)
                                                     (number-to-string (floor id)))))
                                           ids))))))
               (list name kind children docs)))))
      (delq nil (mapcar (lambda (id)
                          (walk (if (integerp id)
                                    (number-to-string id)
                                  (number-to-string (floor id)))))
                        (gethash "items" (gethash "module" (gethash "inner" root-item))))))))


;;; Helpers

(defun crate--description ()
  "Return the description of the current crate.
Collapses newlines and truncates to `fill-column'.  Returns an
empty string when the description is missing or :null."
  (declare (side-effect-free t))
  (or (when-let* ((it (gethash "description" crate-data))
                  ((not (eq it :null))))
        (setq it (string-replace "\n" "" it))
        (setq it (truncate-string-to-width it fill-column nil nil t))
        it)
      ""))

(defun crate--deps (name)
  "Return dependency rows for crate NAME from the SQLite database.
Returns a list of (dep_name req kind optional) lists, or nil.
Memoized in `crate--data-cache' keyed by database path; a :failed
sentinel prevents retrying failed queries, and nil results (no
rows) are cached."
  (when (and crate-data-path (file-exists-p crate-data-path))
    (let ((cached (with-memoization
                    (gethash (list 'deps crate-data-path name) crate--data-cache)
                    ;; Return :failed sentinel so with-memoization
                    ;; doesn't retry failed queries on every call.
                    (condition-case nil
                        (let ((db (sqlite-open crate-data-path)))
                          ;; `unwind-protect', never `prog1': a failed
                          ;; query must not leak the handle.
                          (unwind-protect
                              (sqlite-select db
                                             "SELECT dep_name, req, kind, optional
                                  FROM dependencies WHERE crate_name = ?
                                  ORDER BY optional, kind, dep_name"
                                             (list name))
                            (sqlite-close db)))
                      (error :failed)))))
      (unless (eq cached :failed)
        cached))))

(defun crate--dependents (name)
  "Return the names of crates depending on crate NAME.
A reverse lookup on the `dependencies' table.  Memoized like
`crate--deps', keyed by database path with a :failed sentinel."
  (when (and crate-data-path (file-exists-p crate-data-path))
    (let ((cached
           (with-memoization
               (gethash (list 'dependents crate-data-path name) crate--data-cache)
             (condition-case nil
                 (let ((db (sqlite-open crate-data-path)))
                   (unwind-protect
                       (mapcar #'car
                               (sqlite-select
                                db
                                "SELECT DISTINCT crate_name
                             FROM dependencies WHERE dep_name = ?
                                  ORDER BY crate_name"
                                (list name)))
                     (sqlite-close db)))
               (error :failed)))))
      (unless (eq cached :failed)
        cached))))

(defun crate--format-downloads (n)
  "Format N as a human-readable download count."
  (declare (pure t) (side-effect-free t))
  (cond
   ((>= n 1000000000) (format "%.1fB" (/ n 1000000000.0)))
   ((>= n 1000000) (format "%.1fM" (/ n 1000000.0)))
   ((>= n 1000) (format "%dK" (/ n 1000)))
   (t (number-to-string n))))

;;; Faces

(defface crate-name-face
  '((t :inherit (package-name bold) :height 1.2))
  "Face for the crate name in `crate-mode' detail buffers.
Inherits from `package-name' when available, otherwise `bold'."
  :group 'crate)

(defface crate-field-label
  '((t :inherit (package-help-section-name bold)))
  "Face for field labels in `crate-mode' detail buffers.
Inherits from `package-help-section-name' when available."
  :group 'crate)

(defface crate-url
  '((t :inherit link))
  "Face for URLs in `crate-mode' detail buffers."
  :group 'crate)

(defface crate-date
  '((t :inherit marginalia-date))
  "Face for update dates in `crate-mode' detail buffers.
Inherits from `marginalia-date' when available."
  :group 'crate)

(defface crate-id
  '((t :inherit marginalia-number))
  "Face for crate ID numbers in `crate-mode' detail buffers.
Inherits from `marginalia-number' when available."
  :group 'crate)

(defface crate-version
  '((t :inherit (shadow)))
  "Face for crate versions in `crate-mode' detail buffers."
  :group 'crate)

(defface crate-license
  '((t :inherit (shadow)))
  "Face for crate license values in `crate-mode' detail buffers."
  :group 'crate)

(defface crate-description
  '((t :inherit (package-description default)))
  "Face for descriptions in `crate-browse-mode'.
Inherits from `package-description' when available."
  :group 'crate)

(defvar crate-font-lock-keywords
  `(;; Field labels: "Name:", "Description:", etc.
    ("^\\([A-Z][a-z]+:\\)[[:space:]]*"
     (1 'crate-field-label))
    ;; Crate name value
    ("^Name:[[:space:]]+\\(.+\\)"
     (1 'crate-name-face))
    ;; Description value
    ("^Description:[[:space:]]+\\(.+\\)"
     (1 'crate-description))
    ;; Version value
    ("^Version:[[:space:]]+\\(.+\\)"
     (1 'crate-version))
    ;; License value
    ("^License:[[:space:]]+\\(.+\\)"
     (1 'crate-license))
    ;; URLs on Homepage/Documentation/Repository lines
    ("^\\(?:Homepage\\|Documentation\\|Repository\\):[[:space:]]+\\(https?://[^[:space:]\n]+\\)"
     (1 'crate-url nil t))
    ;; Updated date
    ("^Updated:[[:space:]]+\\(.+\\)"
     (1 'crate-date))
    ;; Downloads number
    ("^Downloads:[[:space:]]+\\([0-9.]+[KMB]?\\)"
     (1 'crate-id))
    ;; Crate id number
    ("^Id:[[:space:]]+\\([0-9]+\\)"
     (1 'crate-id))
    ;; Kind tags in the rustdoc module tree ("- [struct] name")
    ("^[[:space:]]*- \\(\\[[a-z]+\\]\\)"
     (1 'crate-version)))
  "Font-lock keywords for `crate-mode'.")

;;; Text buttons

;; A link is a text button of the type `crate-link'.  The type carries
;; the face, the mouse face and the follow link rule, so every link
;; answers the mouse the same way and a renderer names no mouse face of
;; its own.  A button that opens a crate keeps its own action, because
;; only a URL button opens a browser.

(defun crate--button-url (button)
  "Open the crates.io URL of BUTTON in a browser."
  (when (integer-or-marker-p button)
    (goto-char button))
  (browse-url (button-get button 'crate-url)))

(define-button-type 'crate-link
  'action #'crate--button-url
  'face 'crate-url
  'mouse-face 'highlight
  'follow-link t
  'help-echo "Open link")

;;; Point keeping

;; A render erases the buffer, so `crate--render' records the line of
;; point before the render and restores it after the render.  The
;; record names the line and not a buffer position: a field key, a
;; module path, the URL of a crate link or, for a line without such an
;; identity, the text of the line and its ordinal among the equal lines
;; above it.  A blank line leans on the nearest line above that has an
;; identity, and the column of point travels with the line.  So a
;; refresh keeps the reader on the same value even when the lines above
;; changed their length.

(defun crate--line-text ()
  "Return the text of the current line without properties."
  (declare (side-effect-free t))
  (string-trim-right
   (buffer-substring-no-properties (line-beginning-position)
                                   (line-end-position))))

(defun crate--line-occurrence (text)
  "Return the number of lines above point that hold TEXT.
The count is the ordinal of the line of point among the equal
lines of the buffer, so a renderer that keeps one of two equal
lines keeps the right one."
  (declare (side-effect-free t))
  (let ((origin (line-beginning-position)))
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (< (point) origin)
          (when (equal (crate--line-text) text)
            (setq count (1+ count)))
          (forward-line 1))
        count))))

(defun crate--line-identity ()
  "Return the identity of the line of point, or nil.
The identity is a cons of a kind and a value: `field' and the
field key, `module' and the path of the item in the module tree,
`link' and the URL of a crate link, or `text' and a cons of the
text of the line and its ordinal among the equal lines above it.
A line of whitespace alone has no identity, because its text would
match every blank line."
  (declare (side-effect-free t))
  (let ((start (line-beginning-position)))
    (or (when-let* ((key (get-text-property start 'crate-field)))
          (cons 'field key))
        (when-let* ((path (get-text-property start 'crate-module)))
          (cons 'module path))
        (when-let* ((url (get-text-property start 'crate-url)))
          (cons 'link url))
        (let ((text (crate--line-text)))
          (unless (string-empty-p text)
            (cons 'text (cons text (crate--line-occurrence text))))))))

(defun crate--point-record (&optional position)
  "Return a record of the line at POSITION, or nil.
POSITION defaults to point.  The record holds the identity of the
line, the number of lines from the line that the identity names to
the line of POSITION, and the column of POSITION.  A line of
whitespace alone leans on the nearest line above that has an
identity, so the record keeps the distance from that line.  Return
nil when no line of the buffer has an identity, because then there
is no place to keep."
  (let ((offset 0)
        column
        identity)
    (save-excursion
      (goto-char (or position (point)))
      (setq column (- (point) (line-beginning-position)))
      (beginning-of-line)
      (let ((done nil))
        (while (not done)
          (setq identity (crate--line-identity))
          (cond (identity (setq done t))
                ((bobp) (setq done t))
                (t
                 (setq offset (1+ offset))
                 (forward-line -1))))))
    (when identity
      (list :identity identity :offset offset :column column))))

(defun crate--goto-property (property value)
  "Move point to the line whose PROPERTY equals VALUE.
Return non-nil when the buffer holds such a line.  `equal'
compares the value, because a string property is not `eq' to
another string that spells the same text."
  (let ((position (point-min))
        found)
    (while (and (not found) (< position (point-max)))
      (when (equal (get-text-property position property) value)
        (setq found position))
      (setq position (or (next-single-property-change position property
                                                      nil (point-max))
                         (point-max))))
    (when found
      (goto-char found)
      (beginning-of-line)
      t)))

(defun crate--goto-text (line)
  "Move point to the line that LINE names.
LINE is a cons of the text of a line and its ordinal among the
equal lines above it.  Return non-nil when the function found such
a line.  When the buffer holds fewer equal lines than the ordinal,
the last one serves, because a new line can push an old one down,
and the reader stays in the same part of the buffer."
  (let ((text (car line))
        (ordinal (cdr line))
        (index 0)
        found
        last)
    (goto-char (point-min))
    (while (re-search-forward (concat "^" (regexp-quote text) "[ \t]*$")
                              nil t)
      (setq last (line-beginning-position))
      (unless (or found (< index ordinal))
        (setq found last))
      (setq index (1+ index)))
    (when (or found last)
      (goto-char (or found last))
      t)))

(defun crate--goto-identity (identity)
  "Move point to the line that IDENTITY names.
Return non-nil when the function found that line.  It leaves point
at `point-min' when it found none."
  (pcase identity
    (`(field . ,key) (crate--goto-property 'crate-field key))
    (`(module . ,path) (crate--goto-property 'crate-module path))
    (`(link . ,url) (crate--goto-property 'crate-url url))
    (`(text . ,line) (crate--goto-text line))
    (_ nil)))

(defun crate--record-position (record)
  "Return the buffer position that RECORD names, or nil.
The position is the start of the line that the identity of RECORD
names, moved down by the recorded number of lines and set to the
recorded column.  A shorter line clips the column to its end."
  (declare (side-effect-free t))
  (when record
    (save-excursion
      (goto-char (point-min))
      (when (crate--goto-identity (plist-get record :identity))
        (forward-line (plist-get record :offset))
        (let ((column (plist-get record :column)))
          (unless (zerop column)
            (goto-char (min (+ (line-beginning-position) column)
                            (line-end-position)))))
        (point)))))

(defun crate--restore-point (record)
  "Move point to the position that RECORD describes.
A nil RECORD moves point to the start of the buffer, because no
line carried an identity before the render.  The column of point
travels with the line, so a reader stays on the same column of the
same value."
  (goto-char (or (crate--record-position record) (point-min))))

(defun crate--window-records ()
  "Return the record of every other window that shows the buffer.
Every window but the selected one contributes one cons of the
window and its record.  The selected window needs no entry,
because its point is the point of the buffer.  A window whose line
has no identity contributes a nil record."
  (declare (side-effect-free t))
  (let ((buffer (current-buffer))
        (selected (selected-window))
        records)
    (dolist (window (get-buffer-window-list buffer nil t))
      (unless (eq window selected)
        (push (cons window (crate--point-record (window-point window)))
              records)))
    records))

(defun crate--restore-window-points (records)
  "Move the point of every window of RECORDS to its recorded line.
A window whose line is gone shows the start of the buffer, and a
dead window stays alone."
  (dolist (record records)
    (let ((window (car record)))
      (when (window-live-p window)
        (set-window-point window
                          (or (crate--record-position (cdr record))
                              (point-min)))))))

;;; Major Mode

;;;###autoload
(defun crate--thing-at-point-url ()
  "Return the crates.io URL for a dependency crate name at point.
Used as a `thing-at-point-provider-alist' entry for `crate-mode'
so `thing-at-point \\='url' (and `browse-url-at-point') treat a
dependency crate name as a link to its crates.io page.  Returns nil
unless point is on text carrying a `crate-url' property."
  (get-text-property (point) 'crate-url))

(defvar-keymap crate-mode-map
  :doc "Keymap for `crate-mode'."
  :parent special-mode-map
  "w" #'crate-copy-dependency)

(define-derived-mode crate-mode special-mode "Crate"
  "Major mode for displaying Rust crate details.

\\{crate-mode-map}
This mode is not intended to be invoked directly; use
`find-crate' instead.  The buffer content is inserted by
`crate--render' after the mode is set up."
  (setq-local default-directory temporary-file-directory)
  (setq-local font-lock-defaults '(crate-font-lock-keywords))
  (when crate-goto-address
    (goto-address-mode 1))
  (setq-local bookmark-make-record-function #'crate--bookmark-make-record-function)
  (setq-local revert-buffer-function #'crate--revert)
  ;; Make dependency crate names detectable as crates.io URLs by
  ;; `thing-at-point' / `browse-url-at-point'.
  (setq-local thing-at-point-provider-alist
              (cons '(url . crate--thing-at-point-url)
                    thing-at-point-provider-alist))
  ;; `crate-data' is set after the mode (by `find-crate'), so the
  ;; description isn't available here; `crate--render' fills the buffer.
  (setq-local list-buffers-directory nil))

(defun crate--revert (&optional _ignore-auto _noconfirm _preserve-modes)
  "Re-render the current crate buffer.

`revert-buffer-function' for `crate-mode'.  Re-renders from the
live `crate-name' / `crate-data' buffer-locals so `g' works."
  (crate--render))

(defun crate--render ()
  "Render the current crate detail buffer.

Inserts the fields for `crate-data' (with `crate-name' as
fallback), dependency buttons, and the rustdoc module tree.
Erases existing content first, so re-rendering is idempotent.
Keeps point on the line that it was on before the render, by the
identity of that line, and keeps its column.  Every other window
that shows the buffer keeps the line of its own point too."
  ;; The record of the line of point comes before the erase, because
  ;; the erase removes the text that both the identity and the window
  ;; point markers point into.
  (let ((record (crate--point-record))
        (windows (crate--window-records)))
    ;; Bind `inhibit-read-only' for the whole render: the buffer may
    ;; already be read-only from a previous render.
    (let ((inhibit-read-only t))
      (erase-buffer)
    (cl-labels
        ((field (label key)
           "Insert LABEL, then the value of KEY from `crate-data'.
If the value is nil or :null, nothing is inserted after the label.
The label carries `crate-field' with KEY, so a render keeps point
on the field."
           (insert (propertize label 'crate-field key))
           (let ((val (gethash key crate-data)))
             (unless (or (null val) (eq val :null))
               (insert val)))
           (insert "\n"))
         (insert-doc-tree (items level path)
           "Insert ITEMS (from `crate-doc--module-tree') at LEVEL indentation.
PATH names the module that holds the items.  Each item is (NAME
KIND CHILDREN DOC); KIND renders as a bracketed tag before the
name, and the name carries `crate-module' with its full path, so a
render keeps point on the item."
           (dolist (item items)
             (let* ((name (car item))
                    (kind (cadr item))
                    (children (caddr item))
                    (docs (cadddr item))
                    (identity (if (string-empty-p path)
                                  name
                                (concat path "/" name))))
               (unless (eq name :null)
                 (insert (make-string (* level 2) ?\s)
                         "- ")
                 (when kind
                   (insert (format "[%s] " kind)))
                 (insert (propertize name 'crate-module identity))
                 (if children
                     (progn
                       (insert "\n")
                       (insert-doc-tree children (1+ level) identity))
                   (when docs
                     (insert (propertize (concat " — " docs)
                                         'face 'crate-description)))
                   (insert "\n")))))))
      (insert (propertize "Name:          " 'crate-field 'name))
      (insert (or (gethash "name" crate-data) crate-name) "\n")
      (insert (propertize "Description:   " 'crate-field 'description))
      (insert (crate--description))
      (insert "\n")
      (field "Homepage:      " "homepage")
      ;; Repository
      (insert (propertize "Repository:    " 'crate-field 'repository))
      (when-let* ((repo (gethash "repository" crate-data))
                  ((not (eq repo :null))))
        (insert repo)
        (when crate-repository-directory
          (let ((dir (cond
                      ((functionp crate-repository-directory)
                       (funcall crate-repository-directory repo))
                      ((stringp crate-repository-directory)
                       (expand-file-name
                        (string-replace "/" "__"
                                        (string-remove-prefix "https://" repo))
                        crate-repository-directory)))))
            (when (and dir (file-exists-p dir))
              (setq-local default-directory dir)))))
      (insert "\n")
      ;; Documentation (with docs.rs fallback)
      (insert (propertize "Documentation: " 'crate-field 'documentation))
      (let ((doc (gethash "documentation" crate-data)))
        (if (and doc (not (eq doc :null)))
            (insert doc)
          (let ((url (format "https://docs.rs/%s"
                             (downcase (string-replace "_" "-"
                                                       (or (gethash "name" crate-data) crate-name))))))
            (insert-text-button url
                                :type 'crate-link
                                'action (lambda (_) (browse-url url))
                                'help-echo "Open documentation on docs.rs"))))
      (insert "\n")
      (field "Version:       " "latest_version")
      (field "License:       " "license")
      (insert (propertize "Downloads:     " 'crate-field 'downloads))
      (when-let* ((dls (gethash "downloads" crate-data)))
        (insert (crate--format-downloads dls)))
      (insert "\n")
      (field "Updated:       " "updated_at")
      ;; Dependencies from the crate's default version.
      (when-let* ((deps (crate--deps crate-name)))
        (insert "\nDependencies:\n")
        (dolist (d deps)
          (let* ((dname (nth 0 d))
                 (kind (nth 2 d))
                 (rest (format "%-12s %-8s%s"
                               (or (nth 1 d) "") kind
                               (if (eq (nth 3 d) 1) "  (optional)" "")))
                 (pad (- 40 (length dname))))
            (insert-text-button dname
                                :type 'crate-link
                                'action (lambda (_) (find-crate dname))
                                'help-echo (format "View crate: %s" dname)
                                'crate-url (concat crate--crates-io-url dname))
            (insert (make-string (max pad 1) ?\s) rest "\n"))))
      ;; Reverse dependencies: who depends on this crate.
      (when-let* ((dependents (crate--dependents crate-name)))
        (insert "\nDependents:\n")
        (dolist (dname dependents)
          (insert-text-button dname
                              :type 'crate-link
                              'action (lambda (_) (find-crate dname))
                              'help-echo (format "View crate: %s" dname)
                              'crate-url (concat crate--crates-io-url dname))
          (insert "\n")))
      ;; Module structure from rustdoc JSON (built async on demand).
      (let ((doc-json (crate-doc--json crate-name)))
        (cond
         (doc-json
          (insert "Modules:\n")
          (insert-doc-tree (crate-doc--module-tree doc-json) 0 ""))
         ((gethash (list crate-name crate-data-path) crate-doc--cache)
          (insert "Modules: (rustdoc unavailable)\n"))
         ((and crate-doc-enable (gethash crate-name crate-doc--in-flight))
          (insert "Modules: (rustdoc build in progress…)\n"))))
      ;; `goto-address-mode' links the URLs, so the renderer adds no
      ;; mouse face of its own.
      (font-lock-ensure)
      (set-buffer-modified-p nil))
    (crate--restore-point record)
    (crate--restore-window-points windows))))


;;; Completion

(defun crate--sql-like-escape (s)
  "Escape LIKE wildcards in S for use with ESCAPE '\\'.
Underscore and percent are valid crate-name characters, so they
must match literally."
  (declare (pure t) (side-effect-free t))
  (setq s (string-replace "\\" "\\\\" s))
  (setq s (string-replace "%" "\\%" s))
  (string-replace "_" "\\_" s))

(defun crate--match-names (prefix)
  "Return published crate names starting with PREFIX.
Queries SQLite per call — no full name list materializes, so
completion scales to a full crates.io dump.  The prefix pattern
matches the collection contract (`complete-with-action'
prefix-filters each query); completion styles query with their own
strings and filter further on top.  Wildcards in PREFIX are
escaped via `crate--sql-like-escape'."
  (when (and crate-data-path (file-exists-p crate-data-path))
    (condition-case nil
        (let ((db (sqlite-open crate-data-path)))
          (unwind-protect
              (mapcar #'car
                      (sqlite-select
                       db
                       "SELECT name FROM crates WHERE name LIKE ? ESCAPE '\\'
                        ORDER BY name"
                       (list (concat (crate--sql-like-escape prefix) "%"))))
            (sqlite-close db)))
      (error nil))))

(defun crate--annotate (candidate)
  "Completion annotation function for crate CANDIDATE."
  (let* ((table (crate--list))
         (data (when table
                 (gethash (crate--canonical-name candidate) table)))
         (desc (and data (gethash "description" data))))
    (when (and desc (not (eq desc :null))
               (not (string-empty-p desc)))
      (concat (propertize " " 'display '(space :align-to center))
              (string-limit (string-replace "\n" " " desc)
                            crate-annotation-width)))))

(defun crate--collection (string predicate action)
  "Completion collection for crates.
See `completing-read' for the meaning of STRING, PREDICATE and
ACTION."
  (pcase action
    ('metadata
     '(metadata
       (category . crate)
       (annotation-function . crate--annotate)))
    (_
     (complete-with-action action (crate--match-names string) string predicate))))

(defun crate-refresh-cache ()
  "Discard cached crate data.
The next `find-crate' or completion invocation will reload from
the database."
  (interactive)
  (setq crate--data-cache (make-hash-table :test 'equal)
        crate-doc--cache (make-hash-table :test 'equal)
        crate-doc--in-flight (make-hash-table :test 'equal))
  ;; Discard results of builds started before the refresh.
  (cl-incf crate-doc--generation)
  (message "crate: cache cleared"))


;;; Interactive Commands

;;;###autoload
(defun find-crate (&optional name)
  "Display details for the Rust crate NAME in `crate-mode'.
When called interactively, prompt for a crate name with
completion.  If NAME is a crates.io URL, the URL prefix is
stripped first; a trailing version path segment is dropped with a
message naming the requested version.  Creates a new buffer named
\"Crate: <name>\" or switches to an existing one.
`crate-display-buffer-action' chooses the window that shows it."
  (interactive)
  (let ((cand (or name
                  (completing-read "crate> " #'crate--collection))))
    ;; Strip crates.io URL prefix and any trailing version path.
    (when (string-prefix-p crate--crates-io-url cand)
      (setq cand (string-remove-prefix crate--crates-io-url cand))
      (when-let* ((slash (string-search "/" cand)))
        ;; Don't drop the version silently — surface it.
        (let ((version (substring cand (1+ slash))))
          (setq cand (substring cand 0 slash))
          (unless (string-empty-p version)
            (message "crate: requested version %s ignored (showing latest)"
                     version)))))
    (setq cand (crate--canonical-name cand))
    (let* ((data (crate--list))
           (entry (when data (gethash cand data))))
      ;; No database at all: blame the configuration, not the name.
      (unless data
        (if crate-data-path
            (user-error "Crate database `%s' unreadable" crate-data-path)
          (user-error "No crate database configured — set `crate-data-path'")))
      (unless entry
        (user-error "Crate `%s' not found" cand))
      (let ((bufname (format "Crate: %s" cand)))
        (crate--display-buffer bufname)
        (crate-mode)
        ;; Set the crate locals after `crate-mode' (whose
        ;; `kill-all-local-variables' would otherwise wipe them),
        ;; then render.  Re-rendering an existing buffer is safe:
        ;; `crate--render' erases first.
        (setq-local crate-name cand)
        (setq-local crate-data entry)
        (crate--render)
        (run-hooks 'crate-visit-hook)))))


;;;###autoload
(defun crate-browse-url (url &rest _args)
  "Browse a Rust crate URL by dispatching to `find-crate'.
Intended for use as a `browse-url' handler.  The URL is passed
directly to `find-crate', which strips the crates.io prefix."
  (find-crate url))

;;;###autoload
(defun crate-install-browse-url-handler ()
  "Make `browse-url' open crates.io URLs with `find-crate'."
  (interactive)
  (with-eval-after-load 'browse-url
    (add-to-list 'browse-url-default-handlers
                 (cons (concat "^" (regexp-quote crate--crates-io-url))
                       'crate-browse-url))))

;;; Bookmarks

(defun crate--bookmark-make-record-function ()
  "Create a bookmark record for the current crate buffer.
Intended for use as `bookmark-make-record-function'."
  `(,(concat "Rust Crate: " crate-name)
    (handler . crate-bookmark-jump)
    (crate . ,crate-name)
    ;; This location tag is used as a description in the bookmark menu list
    (location . ,(crate--description))))


;;;###autoload
(defun crate-bookmark-jump (bm)
  "Restore a crate bookmark BM.
Called by the bookmark system.  Extracts the crate name from BM
and delegates to `find-crate'."
  (interactive (list (read-from-minibuffer "Bookmark: ")))
  (let ((name (bookmark-prop-get bm 'crate)))
    (find-crate name)))
(put 'crate-bookmark-jump 'bookmark-handler-type "Crate")

;;; Org Integration

(with-eval-after-load 'org
  (require 'ol-crate))


;;; Browse Mode

(defvar-keymap crate-browse-export-map
  :doc "Export keymap for `crate-browse-mode'."
  "c" #'crate-browse-export-cargo
  "m" #'crate-browse-export-markdown)

(defvar-keymap crate-browse-mode-map
  :doc "Keymap for `crate-browse-mode'."
  :parent tabulated-list-mode-map
  "RET" #'crate-browse-visit
  "o"   #'crate-browse-open-other-window
  "<mouse-2>" #'crate-browse-open-other-window-mouse
  "<follow-link>" #'crate-browse--click-selects-row
  "b"   #'crate-browse-search-url
  "w"   #'crate-copy-dependency
  "e"   crate-browse-export-map)

(define-derived-mode crate-browse-mode tabulated-list-mode "Crate-Browse"
  "Major mode for browsing Rust crates in a sortable table.

\\{crate-browse-mode-map}
\\<crate-browse-mode-map>
\\[crate-browse-visit] on an entry to view full details,
\\[crate-browse-open-other-window] to view them in another window,
\\[crate-browse-search-url] to open on crates.io,
\\[crate-browse-widen-column] and \\[crate-browse-narrow-column] to
resize a column,
\\[revert-buffer] to reload the data.
The `e' prefix exports the visible rows: \\[crate-browse-export-cargo]
and \\[crate-browse-export-markdown].

The table shrinks its columns when the window is narrow."
  :interactive nil
  (setq tabulated-list-format
        [("Crate" 40 t)
         ("Version" 12 crate-browse--version-lessp)
         ("Description" 0 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Crate" . nil))
  (setq-local crate-browse--declared-widths (crate-browse--column-widths))
  (setq-local crate-browse--canonical-widths crate-browse--declared-widths)
  (tabulated-list-init-header)
  (hl-line-mode 1)
  (add-hook 'tabulated-list-revert-hook #'crate-browse--reload nil t)
  (add-hook 'kill-buffer-hook #'crate-browse--cancel-fit nil t)
  (setq-local tabulated-list-printer #'crate-browse--print-entry)
  (when (boundp 'context-menu-functions)
    (add-hook 'context-menu-functions #'crate-browse--context-menu nil t))
  (setq-local bookmark-make-record-function
              #'crate-browse--bookmark-make-record))

(defvar-local crate-browse--name-list nil
  "Buffer-local list of crate names that the browse buffer is filtered to.
When nil, all crates are shown.")
(put 'crate-browse--name-list 'permanent-local t)

(defvar-local crate-browse--name-prefix nil
  "Buffer-local search term used for naming the browse buffer.")
(put 'crate-browse--name-prefix 'permanent-local t)

(defvar-local crate-browse--declared-widths nil
  "Column widths that `crate-browse-mode' declares.
Neither a window fit nor a bookmark changes this list, so it stays
the source for the width function.")

(defvar-local crate-browse--canonical-widths nil
  "Column widths that a window fit starts from.
A fit starts here, so a wide window gets the declared widths back
and a manual resize is undone by the next fit.  A bookmark may
replace it with the widths that it saved.")

(defvar-local crate-browse--fit-timer nil
  "Pending timer that refits this table after a window size change.")

(defconst crate--version-re
  "\\`\\([0-9]+\\)\\(?:\\.\\([0-9]+\\)\\)?\\(?:\\.\\([0-9]+\\)\\)?\\(?:-\\([^+]+\\)\\)?\\(?:\\+.*\\)?\\'"
  "Regexp splitting a version string into its numeric and pre-release parts.
The minor and patch groups are optional, because a few old crates
publish a two-segment version such as \"0.1\".")

(defun crate--version-parts (version)
  "Return VERSION as (MAJOR MINOR PATCH PRE), or nil if it is no semver.
MAJOR, MINOR and PATCH are integers, and a missing segment counts
as 0, so \"0.1\" reads as 0.1.0.  PRE is nil for a release, or a
list of pre-release identifiers, each an integer or a string.  The
build metadata after a plus sign does not affect precedence, so it
is dropped."
  (declare (pure t) (side-effect-free t))
  (when (and (stringp version)
             (string-match crate--version-re version))
    (list (string-to-number (match-string 1 version))
          (string-to-number (or (match-string 2 version) "0"))
          (string-to-number (or (match-string 3 version) "0"))
          (when-let* ((pre (match-string 4 version)))
            (mapcar (lambda (identifier)
                      (if (string-match-p "\\`[0-9]+\\'" identifier)
                          (string-to-number identifier)
                        identifier))
                    (split-string pre "\\."))))))

(defun crate--semver-identifier-lessp (a b)
  "Return non-nil when pre-release identifier A sorts before B.
A numeric identifier sorts before an alphanumeric one, and two
numeric identifiers compare as numbers."
  (declare (pure t) (side-effect-free t))
  (cond ((and (integerp a) (integerp b)) (< a b))
        ((integerp a) t)
        ((integerp b) nil)
        (t (string< a b))))

(defun crate--semver-pre-lessp (a b)
  "Return non-nil when pre-release list A sorts before list B.
A numeric identifier sorts before an alphanumeric one, and a list
that prefixes a longer list sorts first, so \"alpha\" comes before
\"alpha.1\"."
  (declare (pure t) (side-effect-free t))
  (cond ((null a) t)
        ((null b) nil)
        ((equal (car a) (car b))
         (crate--semver-pre-lessp (cdr a) (cdr b)))
        (t (crate--semver-identifier-lessp (car a) (car b)))))

(defun crate--version-lessp (a b)
  "Return non-nil when version string A sorts before version string B.
Compare as semver, so \"1.9.0\" sorts before \"1.10.0\" and
\"1.0.0-rc.1\" before \"1.0.0\".  `version<' rejects a pre-release,
so it cannot do this job.  A value that is no semver falls back to
`string<', and an empty value sorts last."
  (declare (pure t) (side-effect-free t))
  (let ((a-parts (crate--version-parts a))
        (b-parts (crate--version-parts b)))
    (cond ((and a-parts b-parts)
           (let ((a-core (butlast a-parts))
                 (b-core (butlast b-parts))
                 (a-pre (nth 3 a-parts))
                 (b-pre (nth 3 b-parts)))
             (cond ((version-list-< a-core b-core) t)
                   ((version-list-< b-core a-core) nil)
                   ;; A release sorts after a pre-release of the
                   ;; same core version.
                   ((null a-pre) nil)
                   ((null b-pre) t)
                   (t (crate--semver-pre-lessp a-pre b-pre)))))
          ((string-empty-p (or a "")) nil)
          ((string-empty-p (or b "")) t)
          (t (string< a b)))))

(defun crate-browse--cell-text (cell)
  "Return table CELL as a string.
A cell holds a string or a cons of a label and button properties."
  (declare (pure t) (side-effect-free t))
  (cond ((stringp cell) cell)
        ((consp cell) (format "%s" (car cell)))
        (t "")))

(defun crate-browse--version-lessp (a b)
  "Return non-nil when `tabulated-list' entry A sorts before B.
A and B are `tabulated-list-entries' entries.  The Version column
compares semvers rather than the strings it prints, so \"1.9\"
lands before \"1.10\".  An entry without a version sorts last."
  (declare (side-effect-free t))
  (crate--version-lessp (crate-browse--cell-text (aref (cadr a) 1))
                        (crate-browse--cell-text (aref (cadr b) 1))))

(defun crate-browse--entry (name data)
  "Return a `tabulated-list' entry for crate NAME with DATA."
  (declare (side-effect-free t))
  (let ((desc (gethash "description" data))
        (version (gethash "latest_version" data)))
    (list name
          (vector (propertize name 'face 'crate-name-face)
                  (propertize (or version "") 'face 'crate-version)
                  (propertize (if (and desc (not (eq desc :null)))
                                  (string-limit (string-replace "\n" " " desc)
                                                crate-annotation-width)
                                "")
                              'face 'crate-description)))))

(defun crate-browse--entry-less (a b)
  "Return non-nil if tabulated-list entry A sorts before B by name.
A and B are `tabulated-list-entries' entries whose car is the crate
name.  Used to make the browse display order deterministic."
  (declare (side-effect-free t))
  (string< (car a) (car b)))

(defun crate-browse--entries (&optional name-list)
  "Generate `tabulated-list-entries' for all crates.
When NAME-LIST is non-nil, only include entries whose names
appear in the list.  The entries are sorted by name so the
initial display is deterministic (hash iteration order is not)."
  (let ((items (crate--list))
        entries)
    (when items
      (if name-list
          (dolist (name name-list (sort entries #'crate-browse--entry-less))
            (let ((data (or (gethash name items)
                            (gethash (crate--canonical-name name) items))))
              (when data
                (push (crate-browse--entry (or (gethash "name" data) name) data)
                      entries))))
        (maphash (lambda (key data)
                   (push (crate-browse--entry (or (gethash "name" data) key) data)
                         entries))
                 items)
        (setq entries (sort entries #'crate-browse--entry-less))))))

(defun crate-browse--current-name ()
  "Return the crate name at point, or signal an error."
  (or (tabulated-list-get-id)
      (user-error "No crate on this line")))

;;; Mouse and context menu

(defconst crate-browse--mouse-help
  "mouse-2: open in another window, mouse-3: menu"
  "Help text that every browse table row carries.")

(defun crate-browse--print-entry (id columns)
  "Print one table row for ID and COLUMNS, then add its mouse help.
`tabulated-list-print' calls this through `tabulated-list-printer'
for every entry, so a line without an entry stays plain.  The whole
row explains the mouse, and the name cell carries `mouse-face', so
the pointer highlights the name alone."
  (let ((beg (point)))
    (tabulated-list-print-entry id columns)
    (when id
      (let* ((end (1- (point)))
             (text (crate-browse--cell-text (aref columns 0)))
             (name-start (+ beg tabulated-list-padding))
             (name-end (min (+ name-start (string-width text)) end)))
        (add-text-properties beg end (list 'help-echo crate-browse--mouse-help))
        (when (< name-start name-end)
          (add-text-properties name-start name-end
                               '(mouse-face highlight)))))))

(defun crate-browse--click-selects-row (&rest _ignored)
  "Return nil, so one click selects a row and follows no link.
`tabulated-list-mode-map' binds `follow-link' to `mouse-face', and
that value turns a click on a marked cell into a `mouse-2' event.
The name cell carries `mouse-face', so this predicate keeps the
click from opening a detail buffer.  The middle button opens one."
  nil)

(defun crate-browse--context-command (position buffer function)
  "Return a command that moves point to POSITION in BUFFER, then calls FUNCTION.
A context menu click leaves point alone, and the menu command can
run in another buffer, so the command restores both first."
  (lambda ()
    (interactive)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (integer-or-marker-p position)
          (goto-char (min position (point-max))))
        (funcall function)))))

(defun crate-browse--context-menu (menu click)
  "Fill MENU with the table commands for the row under CLICK.
A click below the last row adds nothing, so the plain Emacs menu
stays.  `crate-browse-mode' adds this function to
`context-menu-functions' buffer-locally."
  (let* ((position (posn-point (event-start click)))
         (buffer (current-buffer))
         (name (crate-browse--name-at-event click)))
    (when (and name (derived-mode-p 'crate-browse-mode))
      (let ((command (lambda (function)
                       (crate-browse--context-command position buffer
                                                     function))))
        (define-key-after menu [crate-browse-open]
          (list 'menu-item "Open Details"
                (funcall command
                         (lambda ()
                           (crate-browse--display name nil)))))
        (define-key-after menu [crate-browse-open-other-window]
          (list 'menu-item "Open in Other Window"
                (funcall command
                         (lambda ()
                           (crate-browse--display
                            name crate--other-window-action)))))
        (define-key-after menu [crate-browse-copy-dependency]
          (list 'menu-item "Copy Dependency Line"
                (funcall command (lambda () (crate-copy-dependency name)))))
        (define-key-after menu [crate-browse-export-cargo]
          (list 'menu-item "Export as Cargo.toml"
                #'crate-browse-export-cargo))
        (define-key-after menu [crate-browse-export-markdown]
          (list 'menu-item "Export as Markdown"
                #'crate-browse-export-markdown))
        (define-key-after menu [crate-browse-search-url]
          (list 'menu-item "Open on crates.io"
                (funcall command
                         (lambda ()
                           (browse-url (concat crate--crates-io-url name))))))
        (define-key-after menu [crate-browse-refresh-separator]
          menu-bar-separator)
        (define-key-after menu [crate-browse-revert]
          '(menu-item "Refresh" revert-buffer))))
    menu))

;;; Column widths

(defun crate-browse--column-widths ()
  "Return the current width of every column of the table."
  (declare (side-effect-free t))
  (mapcar (lambda (column) (nth 1 column))
          (append tabulated-list-format nil)))

(defun crate-browse--format-widths (format widths)
  "Return a copy of FORMAT with the widths of WIDTHS.
`tabulated-list-format' may share constant lists across buffers, so
copy a column before it changes."
  (declare (pure t) (side-effect-free t))
  (apply #'vector
         (cl-mapcar (lambda (column width)
                      (let ((copy (copy-sequence column)))
                        (setcar (cdr copy) width)
                        copy))
                    (append format nil)
                    widths)))

(defun crate-browse--longest-cell (entries column)
  "Return the width of the widest COLUMN cell of ENTRIES.
ENTRIES has the shape of `tabulated-list-entries'."
  (declare (pure t) (side-effect-free t))
  (let ((longest 0))
    (dolist (entry entries longest)
      (setq longest
            (max longest
                 (string-width
                  (crate-browse--cell-text (aref (cadr entry) column))))))))

(defun crate-browse--content-widths (entries)
  "Return the declared widths with the Version column sized to ENTRIES.
The column grows to the longest visible version, capped by
`crate-browse-version-max-width'.  The header label is the floor,
so the label never truncates."
  (declare (side-effect-free t))
  (let* ((widths (append (or crate-browse--declared-widths
                             (crate-browse--column-widths))
                         nil))
         (header (string-width (car (aref tabulated-list-format 1))))
         (longest (crate-browse--longest-cell entries 1)))
    (setcar (nthcdr 1 widths)
            (min crate-browse-version-max-width
                 (max header longest)))
    widths))

(defun crate-browse--base-widths ()
  "Return the widths that a window fit starts from."
  (declare (side-effect-free t))
  (crate-browse--content-widths tabulated-list-entries))

(defun crate-browse--fit-widths (widths budget)
  "Return WIDTHS shrunk to fit BUDGET columns.
WIDTHS holds one width per column, and the last column takes the
remaining space, so `crate-browse-description-min-width' bounds its
share.  A column before the last shrinks to 8, and the Crate column
stops at `crate-browse-name-min-width'.  The result keeps every
value when the columns already fit."
  (declare (side-effect-free t))
  (let* ((last (1- (length widths)))
         (fitted (append widths nil))
         (fixed (let ((total tabulated-list-padding))
                  (dotimes (index last)
                    (setq total (+ total (nth index fitted) 1)))
                  total))
         (over (- (+ fixed crate-browse-description-min-width) budget)))
    (cl-labels ((shrink (index floor)
                  (when (> over 0)
                    (let* ((room (max (- (nth index fitted) floor) 0))
                           (take (min room over)))
                      (setcar (nthcdr index fitted)
                              (- (nth index fitted) take))
                      (setq over (- over take))))))
      (let ((index (1- last)))
        (while (>= index 1)
          (shrink index 8)
          (setq index (1- index))))
      (when (> last 0)
        (shrink 0 crate-browse-name-min-width)))
    fitted))

(defun crate-browse--fit (window)
  "Return a `tabulated-list-format' that fits WINDOW, or nil.
The fit starts from `crate-browse--canonical-widths', so a resize
in either direction reaches the right widths.  Return nil when the
current widths already equal the fitted ones."
  (declare (side-effect-free t))
  (when (and (windowp window) crate-browse--canonical-widths)
    (let* ((current (crate-browse--column-widths))
           (target (crate-browse--fit-widths crate-browse--canonical-widths
                                             (window-width window))))
      (unless (equal target current)
        (crate-browse--format-widths tabulated-list-format target)))))

(defun crate-browse--fit-format ()
  "Fit the columns to the window that shows this buffer, without a reprint.
The browse command runs this before its first print, because that
print lands in the selected window.  The fit also refreshes the
base widths, so the Version column follows the visible rows."
  (setq-local crate-browse--canonical-widths (crate-browse--base-widths))
  (when-let* ((fitted (crate-browse--fit (or (get-buffer-window nil t)
                                             (selected-window)))))
    (setq tabulated-list-format fitted)
    (tabulated-list-init-header)))

(defun crate-browse--refit (window)
  "Fit the columns of WINDOW to WINDOW, and reprint on a change."
  (when (and (window-live-p window)
             (buffer-live-p (window-buffer window)))
    (with-current-buffer (window-buffer window)
      (setq crate-browse--fit-timer nil)
      (when-let* ((fitted (crate-browse--fit window)))
        (setq tabulated-list-format fitted)
        (tabulated-list-init-header)
        (tabulated-list-print t)))))

(defun crate-browse--refit-p ()
  "Return non-nil when the current table may refit after a resize."
  (declare (side-effect-free t))
  (or (null crate-browse-refit-max-entries)
      (not (listp tabulated-list-entries))
      (<= (length tabulated-list-entries) crate-browse-refit-max-entries)))

(defun crate-browse--schedule-refit (buffer window)
  "Refit BUFFER for WINDOW after the current redisplay.
Redisplay runs the window size hook, so the reprint waits for a
timer.  One pending timer per buffer is enough.  A table larger
than `crate-browse-refit-max-entries' keeps its widths."
  (when (and (buffer-live-p buffer)
             (not (timerp (buffer-local-value 'crate-browse--fit-timer
                                              buffer)))
             (with-current-buffer buffer (crate-browse--refit-p)))
    (with-current-buffer buffer
      (setq crate-browse--fit-timer
            (run-at-time 0 nil #'crate-browse--refit window)))))

(defun crate-browse--cancel-fit ()
  "Cancel a pending window size refit of the current table buffer."
  (when (timerp crate-browse--fit-timer)
    (cancel-timer crate-browse--fit-timer)
    (setq crate-browse--fit-timer nil)))

(defun crate-browse--window-size-changed (frame)
  "Refit the crate tables shown in the windows of FRAME.
A size change alters the space that the last column needs, and the
other columns give way when the window is too narrow."
  (dolist (window (window-list frame 'nomini))
    (when (buffer-local-value 'crate-browse--canonical-widths
                              (window-buffer window))
      (crate-browse--schedule-refit (window-buffer window) window))))

(add-hook 'window-size-change-functions #'crate-browse--window-size-changed)


(defun crate-browse-visit ()
  "Display details for the crate at point."
  (interactive)
  (find-crate (crate-browse--current-name)))

(defun crate-browse-search-url ()
  "Open the current crate on crates.io."
  (interactive)
  (browse-url (concat crate--crates-io-url
                      (crate-browse--current-name))))

(defun crate-browse--display (name action)
  "Display the detail buffer of crate NAME with display ACTION."
  (unless (derived-mode-p 'crate-browse-mode)
    (user-error "Not a crate table buffer"))
  (unless name
    (user-error "No crate on this line"))
  (let ((crate-display-buffer-action action))
    (find-crate name)))

(defun crate-browse-open-other-window ()
  "Open the crate at point in another window."
  (interactive)
  (crate-browse--display (tabulated-list-get-id)
                        crate--other-window-action))

(defun crate-browse--name-at-event (event)
  "Return the crate name of the table row under mouse click EVENT."
  (let* ((start (event-start event))
         (window (posn-window start))
         (position (posn-point start)))
    (when (and (windowp window) (integer-or-marker-p position))
      (with-current-buffer (window-buffer window)
        (save-excursion
          (goto-char position)
          (tabulated-list-get-id))))))

(defun crate-browse-open-other-window-mouse (event)
  "Open the table row under mouse click EVENT in another window."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start)))
    (unless (windowp window)
      (user-error "No crate under the mouse"))
    (with-current-buffer (window-buffer window)
      (crate-browse--display (crate-browse--name-at-event event)
                            crate--other-window-action))))

;;; Export

(defun crate-browse--rows ()
  "Return the rows of the current table buffer in display order.
Each row is a cons of its entry ID and its column vector.  A line
without an entry adds no row."
  (save-excursion
    (goto-char (point-min))
    (let (rows)
      (while (not (eobp))
        (when-let* ((columns (tabulated-list-get-entry)))
          (push (cons (tabulated-list-get-id) columns) rows))
        (forward-line 1))
      (nreverse rows))))

(defun crate-browse--export-cell (cell)
  "Return table CELL as plain text on one line.
A cell holds a string or a cons of a label and button properties.
The face of a cell goes away with the properties."
  (declare (pure t) (side-effect-free t))
  (string-trim
   (replace-regexp-in-string
    "[ \t\n\r]+" " "
    (substring-no-properties (crate-browse--cell-text cell)))))

(defun crate-browse--export-markdown (rows)
  "Return ROWS as a Markdown table.
ROWS comes from `crate-browse--rows'.  The header names the columns
of `tabulated-list-format'.  A pipe inside a cell is escaped, so
the table keeps its shape."
  (declare (side-effect-free t))
  (let* ((labels (mapcar (lambda (column) (car column))
                         (append tabulated-list-format nil)))
         (line (lambda (cells)
                 (concat "| "
                         (mapconcat (lambda (text)
                                      (string-replace "|" "\\|" text))
                                    cells " | ")
                         " |")))
         (header (funcall line labels))
         (separator (concat "|"
                            (mapconcat (lambda (_label) " --- |")
                                       labels "")))
         (body '()))
    (dolist (row rows)
      (push (funcall line (mapcar #'crate-browse--export-cell
                                  (append (cdr row) nil)))
            body))
    (concat (mapconcat #'identity
                       (cons header (cons separator (nreverse body)))
                       "\n")
            "\n")))

(defun crate-browse--export-cargo (rows)
  "Return ROWS as `Cargo.toml' dependency lines.
The lines read the Version cell of each row, so the export follows
the visible data."
  (declare (pure t) (side-effect-free t))
  (if (null rows)
      ""
    (concat (mapconcat (lambda (row)
                         (crate--dependency-line
                          (car row)
                          (crate-browse--export-cell (aref (cdr row) 1))))
                       rows "\n")
            "\n")))

(defun crate-browse--export-buffer (label text)
  "Show TEXT in a read-only export buffer named for LABEL.
A repeat export of the same format reuses the buffer."
  (let ((buffer (get-buffer-create (format "*Crates export: %s*" label))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (special-mode)
        (set-buffer-modified-p nil)))
    (crate--display-buffer buffer)))

(defun crate-browse-export-cargo ()
  "Export the visible table rows as `Cargo.toml' dependency lines.
The export follows the current sort and the filter.  Paste the
block into a `[dependencies]' section."
  (interactive)
  (unless (derived-mode-p 'crate-browse-mode)
    (user-error "Not a crate table buffer"))
  (crate-browse--export-buffer "Cargo.toml"
                              (crate-browse--export-cargo
                               (crate-browse--rows))))

(defun crate-browse-export-markdown ()
  "Export the visible table rows to a read-only Markdown buffer.
The export follows the current sort and the filter."
  (interactive)
  (unless (derived-mode-p 'crate-browse-mode)
    (user-error "Not a crate table buffer"))
  (crate-browse--export-buffer "markdown"
                              (crate-browse--export-markdown
                               (crate-browse--rows))))

(defun crate-browse--reload ()
  "Rebuild `tabulated-list-entries' from the buffer-local filter.
The `tabulated-list-revert-hook' of a browse buffer calls this, so
`revert-buffer' (`g') keeps the filter.  `crate-browse-crates'
calls it before the first print.  The content widths follow the new
entries, so a reload never leaves a stale Version column."
  (setq tabulated-list-entries
        (crate-browse--entries crate-browse--name-list))
  (crate-browse--fit-format))

(defun crate--filter-by-name (name-prefix)
  "Return a list of crate names from the live cache matching NAME-PREFIX.
NAME-PREFIX matches as a substring (not a prefix)."
  (let ((names nil)
        (items (crate--list)))
    (when items
      (maphash (lambda (_key data)
                 (let ((name (gethash "name" data)))
                   (when (and name
                              (string-match-p (regexp-quote name-prefix) name))
                     (push name names))))
               items)
      (nreverse names))))

(defun crate-browse--bookmark-make-record ()
  "Create a bookmark record for the current browse buffer."
  `(,(format "Crates: %s"
             (or crate-browse--name-prefix "all"))
    (name-prefix . ,crate-browse--name-prefix)
    (sort-key . ,tabulated-list-sort-key)
    (widths . ,(crate-browse--column-widths))
    (handler . crate-browse--bookmark-jump)))

(defun crate-browse--restore-state (bookmark)
  "Restore the sort key and column widths that BOOKMARK holds.
A sort key that names no column and a width list that does not
match the table are ignored, so an old bookmark still opens.
Restoring a saved width makes it the width that a later fit starts
from.  The table reprints only when a value lands."
  (let ((sort-key (alist-get 'sort-key bookmark))
        (widths (alist-get 'widths bookmark))
        (columns (append tabulated-list-format nil))
        (restored nil))
    (when (derived-mode-p 'crate-browse-mode)
      (when (and (consp sort-key)
                 (member (car sort-key) (mapcar #'car columns)))
        (setq tabulated-list-sort-key (cons (car sort-key) (cdr sort-key))
              restored t))
      (when (and (listp widths)
                 (cl-every #'integerp widths)
                 (= (length widths) (length columns)))
        (setq tabulated-list-format
              (crate-browse--format-widths tabulated-list-format widths)
              restored t)
        (setq-local crate-browse--canonical-widths widths))
      (when restored
        (tabulated-list-init-header)
        (tabulated-list-print t)))))

(defun crate-browse--bookmark-jump (bookmark)
  "Restore a crate browse BOOKMARK.
Re-derives the filtered name-list from the live cache so newly
added crates appear on reopen."
  (let ((name-prefix (bookmark-prop-get bookmark 'name-prefix))
        name-list)
    (when name-prefix
      (setq name-list (crate--filter-by-name name-prefix)))
    (crate-browse-crates name-list name-prefix)
    (crate-browse--restore-state bookmark)))

;;;###autoload
(defun crate-browse-crates (&optional name-list name-prefix)
  "Display Rust crates in a browseable table.

When NAME-LIST is non-nil (a list of names), only those crates
are displayed.  This is used by Embark export.

When NAME-PREFIX is non-nil, it is appended to the buffer name
(e.g. \"*Crates: serde*\"), allowing multiple searches to
coexist in separate buffers."
  (interactive)
  (let* ((buf-name (if name-prefix
                       (format "*Crates: %s*" name-prefix)
                     "*Crates*"))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (crate-browse-mode)
      (setq-local crate-browse--name-list name-list)
      (setq-local crate-browse--name-prefix name-prefix)
      (crate-browse--reload)
      (tabulated-list-print))
    (switch-to-buffer buf)))


;;; Dependency Copy

(defun crate--dependency-line (name version)
  "Return a `Cargo.toml' dependency line for crate NAME at VERSION.
VERSION is the published version string, or nil, `:null' or an
empty string when the version is unknown, which becomes \"*\"."
  (declare (pure t) (side-effect-free t))
  (format "%s = \"%s\"" name
          (if (and (stringp version) (not (string-empty-p version)))
              version
            "*")))

(defun crate-copy-dependency (&optional name)
  "Copy a Cargo.toml dependency line for crate NAME to the kill-ring.
The line has the form NAME = \"VERSION\", ready to paste into a
`[dependencies]' section.  When the version cannot be determined,
it falls back to \"*\".  Interactively, NAME is the current crate
in `crate-mode' or the entry at point in `crate-browse-mode';
Embark passes its candidate directly."
  (interactive)
  (let* ((name (or name
                   (cond
                    ((derived-mode-p 'crate-mode) crate-name)
                    ((derived-mode-p 'crate-browse-mode)
                     (crate-browse--current-name))
                    (t (user-error "No crate to copy")))))
         (data (or (and crate-name (string= name crate-name) crate-data)
                   (let ((table (crate--list)))
                     (when table
                       (or (gethash name table)
                           (gethash (crate--canonical-name name) table))))))
         (version (and data (gethash "latest_version" data)))
         (line (crate--dependency-line name version)))
    (kill-new line)
    (message "Copied: %s" line)))


;;; Cargo.toml Integration

(defcustom crate-cargo-toml-modes '(toml-mode toml-ts-mode)
  "Major modes treated as `Cargo.toml' for crate-name completion.
The modes themselves stay external — crate.el never hard-requires
a TOML mode; this list is how `crate-cargo-completion-at-point'
recognizes compatible buffers."
  :type '(repeat symbol)
  :group 'crate)

(defun crate--cargo-in-dependencies-p ()
  "Return non-nil if point is inside a dependency section.
Recognizes the flat `[dependencies]', `[dev-dependencies]', and
`[build-dependencies]' headers.  Dotted `[dependencies.foo]`
tables are excluded — the crate name is already written there."
  (save-excursion
    (when (re-search-backward "^\\[\\([^]]+\\)\\][[:space:]]*$" nil t)
      (member (match-string 1)
              '("dependencies" "dev-dependencies" "build-dependencies")))))

(defun crate-cargo-completion-at-point ()
  "Complete a crate name at point inside Cargo.toml dependency sections.
Intended for `completion-at-point-functions' in the modes of
`crate-cargo-toml-modes' (see `crate-install-cargo-toml-capf')."
  (when (and (memq major-mode crate-cargo-toml-modes)
             (crate--cargo-in-dependencies-p))
    (let ((end (point)) start)
      (save-excursion
        (skip-chars-backward "a-zA-Z0-9_.-")
        (setq start (point)))
      (when (< start end)
        (list start end #'crate--collection)))))

;;;###autoload
(defun crate-install-cargo-toml-capf ()
  "Enable crate-name completion in `Cargo.toml' dependency sections.
Registers `crate-cargo-completion-at-point' globally; the function
itself stays silent outside TOML modes and dependency sections."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'crate-cargo-completion-at-point))


;;; Embark

(defvar embark-exporters-alist)
(defvar embark-keymap-alist)
(defvar embark-general-map)

(defun crate--embark-export (candidates)
  "Embark export function for crate CANDIDATES.
Opens a `crate-browse-mode' buffer filtered to CANDIDATES.
Grabs the minibuffer search term as the name-prefix so bookmarks
can re-derive results from the live cache."
  (let ((name-prefix (when (minibufferp)
                       (let ((s (minibuffer-contents)))
                         (and (not (string-empty-p s)) s)))))
    (crate-browse-crates candidates name-prefix)))

(defun crate--embark-browse-url (cand)
  "Open CAND on crates.io."
  (browse-url (concat crate--crates-io-url cand)))

(with-eval-after-load 'embark
  (defvar-keymap crate-embark-map
    :doc "Embark actions for crate candidates."
    :parent embark-general-map
    "RET" #'find-crate
    "b"   #'crate--embark-browse-url
    "w"   #'crate-copy-dependency
    "i"   #'insert)
  (add-to-list 'embark-exporters-alist
               '(crate . crate--embark-export))
  (add-to-list 'embark-keymap-alist
               '(crate . crate-embark-map)))

(provide 'crate)
;;; crate.el ends here
