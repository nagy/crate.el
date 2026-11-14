;;; crate.el --- Browse Rust crates offline -*- lexical-binding: t -*-

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
;; URL: https://github.com/nagy/crate.el
;; Package-Requires: ((emacs "30.1") (magit-section "3.0.0"))

;;; Commentary:

;; This package provides an interactive interface for browsing Rust
;; crates from a local crates.io SQLite database, and a detail view of
;; a local crate directory.
;;
;; Data sources are configurable via `defcustom':
;;
;;   - `crate-data-path'  -- Path to a crates-io.db SQLite database.
;;
;; Commands:
;;
;;   M-x find-crate  -- look up a Rust crate by name
;;   M-x crate-visit-directory -- show the crate of a local directory
;;   M-x crate-copy-dependency -- copy a Cargo.toml dependency line
;;   M-x crate-install-cargo-toml-capf -- crate names in Cargo.toml
;;
;; Deep integration:
;;
;;   - `crate-mode' (major mode) powers the detail buffer with
;;     bookmark support.  The buffer is a tree of `magit-section'
;;     sections, so it folds and moves like a Magit buffer, and
;;     `crate-detail-sections-hook' decides which sections appear.
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
(require 'button)
(require 'cl-lib)
(require 'goto-addr)
(require 'magit-section)
(require 'seq)
;; `thing-at-point-provider-alist' is defined here; crate-mode sets it
;; buffer-locally, so the file must be loaded for the variable to exist.
(require 'thingatpt)



(defvar browse-url-default-handlers)
(defvar thing-at-point-provider-alist)

(defvar-local crate-name nil)
(defvar-local crate-data nil)
(defvar-local crate-local-path nil)

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

Lookups use canonical names (see `crate--canonical-name').

All caches key on this path, so changing it — even via plain
`setq' — serves fresh data with no `crate-refresh-cache' call."
  :type 'file
  :group 'crate)

(defcustom crate-cargo-program "cargo"
  "Cargo executable that `crate-visit-directory' runs.
The Nix build substitutes the store path of the packaged cargo.
Set it to nil to turn the local-crate command off."
  :type '(choice (const :tag "Off" nil)
                 (file :tag "Cargo executable"))
  :group 'crate)


(defcustom crate-rustc-program "rustc"
  "Rustc executable that the crate tree mode runs.
Cargo runs the compiler that this name reaches, and the Nix build
substitutes the store path of the packaged rustc.  Set it to nil to
let cargo pick the compiler that sits beside it."
  :type '(choice (const :tag "Cargo default" nil)
                 (file :tag "Rustc executable"))
  :group 'crate)

(defconst crate--crates-io-url "https://crates.io/crates/")

(defcustom crate-annotation-width 70
  "Maximum width of the description annotation."
  :type 'integer
  :group 'crate)

(defcustom crate-completion-limit 200
  "Maximum number of crate names one completion query returns.
A short prefix matches tens of thousands of names, and every
candidate costs a row fetch, so the query stops here.  Set it to
nil to fetch every match."
  :type '(choice (const :tag "Every match" nil) integer)
  :group 'crate)

(defcustom crate-dependents-limit 200
  "Maximum number of dependents the Dependents section lists.
serde has 135 172 dependents, and one button per dependent takes
1.3 s to render, so the section marks a cut list with a plus
sign.  Set it to nil to list every dependent."
  :type '(choice (const :tag "Every dependent" nil) integer)
  :group 'crate)

(defcustom crate-browse-name-min-width 20
  "Smallest width of the Crate column."
  :type 'integer
  :group 'crate)

(defcustom crate-browse-description-min-width 30
  "Width that the Description column keeps when the columns shrink."
  :type 'integer
  :group 'crate)

(defcustom crate-browse-refit-max-entries 2000
  "Largest table that refits its columns after a window size change.
A refit reprints the table, and `tabulated-list-print' sorts the
entries again, so a full crates.io dump would stall on every frame
resize.  Set it to nil to refit every table."
  :type '(choice (const :tag "Every table" nil) integer)
  :group 'crate)

(defcustom crate-browse-version-max-width 28
  "Widest Version column of a browse table."
  :type 'integer
  :group 'crate)


(defun crate--canonical-name (name)
  "Return the canonical lookup form of crate NAME."
  (declare (pure t) (side-effect-free t))
  (downcase (string-replace "-" "_" name)))


(defcustom crate-repository-directory nil
  "Directory for local crate repository checkouts.
A string is the base directory of the checkouts, a function maps
each repository URL to a directory, and nil turns the mapping off."
  :type '(choice (const :tag "Off" nil)
                 (directory :tag "Base directory")
                 (function :tag "Mapping function"))
  :group 'crate)

(defcustom crate-visit-hook nil
  "Hook run after a crate buffer opens.
Runs in the crate buffer, after `crate-name', `crate-data' and
`crate-local-path' are set and the buffer rendered.  `find-crate'
and `crate-visit-directory' both run it."
  :type 'hook
  :group 'crate)

(defcustom crate-display-buffer-action nil
  "Display action for the `find-crate' detail buffer.
nil keeps `switch-to-buffer'.  Any other value goes to
`pop-to-buffer' as its display action."
  :type '(choice (const :tag "Selected window" nil) function)
  :group 'crate)

(defcustom crate-goto-address t
  "Non-nil if a detail buffer links the URLs in its text."
  :type 'boolean
  :group 'crate)

(defcustom crate-detail-sections-hook
  '(crate-insert-fields
    crate-insert-dependencies
    crate-insert-dependents
    crate-insert-modules)
  "Functions that insert the sections of a crate detail buffer.
`crate--render' runs the entries in order through
`magit-run-section-hook'.  An entry takes no arguments, runs in
the crate buffer and inserts through `magit-insert-section'."
  :type '(repeat function)
  :group 'crate)

(defcustom crate-detail-fields
  '((name . "Name")
    (description . "Description")
    (homepage . "Homepage")
    (repository . "Repository")
    (documentation . "Documentation")
    (latest_version . "Version")
    (license . "License")
    (downloads . "Downloads")
    (updated_at . "Updated"))
  "Fields of a crate detail buffer, in display order.
Each entry pairs a key of the `crates' table with the label of its
line."
  :type '(alist :key-type symbol :value-type string)
  :group 'crate)

(defconst crate--field-label-format "%-15s")

(defconst crate--other-window-action
  '((display-buffer-reuse-window display-buffer-pop-up-window)
    (inhibit-same-window . t))
  "Display action that never uses the selected window.")

(defun crate--display-buffer (buffer)
  "Show BUFFER through `crate-display-buffer-action'."
  (if crate-display-buffer-action
      (pop-to-buffer buffer crate-display-buffer-action)
    (switch-to-buffer buffer)))

;;; Cache

(defvar crate--data-cache (make-hash-table :test #'equal)
  "Cache of crate data keyed by database path.")

(defconst crate--crates-columns
  '(name display_name description documentation homepage repository
         created_at updated_at latest_version license downloads))

(defconst crate--crates-sql
  (format "SELECT %s FROM crates"
          (mapconcat #'symbol-name crate--crates-columns ", ")))

(defconst crate--crate-sql
  (format "SELECT %s FROM crates WHERE name IN (?, ?)"
          (mapconcat #'symbol-name crate--crates-columns ", ")))

(defun crate--crate-spellings (name)
  "Return the published spellings that crate NAME can have.
No published name mixes both separators, and no two names share a
canonical form, so two spellings reach every crate of a full dump
of 358 423 names."
  (declare (side-effect-free t))
  (let ((canonical (crate--canonical-name name)))
    (list canonical (string-replace "_" "-" canonical))))

(defun crate--crate-entry (row)
  "Return a crate record built from the `crates' table ROW.
A nil value inserts no key."
  (declare (side-effect-free t))
  (let ((entry (make-hash-table :test #'equal)))
    (cl-loop for column in crate--crates-columns
             for value in row
             when value
             do (puthash (symbol-name column) value entry))
    (unless (gethash "downloads" entry)
      (puthash "downloads" 0 entry))
    entry))

(defun crate--list ()
  "Load every crate from the SQLite database at `crate-data-path'.
Returns nil if the file is missing or cannot be read.

A full crates.io dump holds 358 423 rows, so this builds 358 423
hash tables: 1.8 s and 647 MiB.  A single-crate lookup reads
`crate--crate' instead."
  (let ((cached
         (with-memoization (gethash (list 'data crate-data-path) crate--data-cache)
           (if (and crate-data-path (file-exists-p crate-data-path))
               (condition-case nil
                   (let* ((db (sqlite-open crate-data-path))
                          ;; `unwind-protect', never `prog1': a failed
                          ;; query must not leak the handle.
                          (rows (unwind-protect
                                    (sqlite-select db crate--crates-sql)
                                  (sqlite-close db)))
                          (table (make-hash-table :test #'equal)))
                     (dolist (row rows)
                       (let ((entry (crate--crate-entry row)))
                         (puthash (crate--canonical-name (nth 0 row)) entry table)))
                     table)
                 (error :failed))
             :failed))))
    (unless (eq cached :failed)
      cached)))

(defun crate--crate (name)
  "Return the crates-table record for crate NAME, or nil.
One lookup through the `name' primary-key btree costs 0.07 ms on a
full crates.io dump, so this scales where `crate--list' does not."
  (let* ((canonical (crate--canonical-name name))
         (key (list 'crate crate-data-path canonical))
         (cached (with-memoization (gethash key crate--data-cache)
                   (or (crate--crate-query canonical) :failed))))
    (unless (eq cached :failed)
      cached)))

(defun crate--crate-query (name)
  "Return the crates-table record for NAME from SQLite, without the cache."
  (when (and crate-data-path (file-exists-p crate-data-path))
    (condition-case nil
        (let ((db (sqlite-open crate-data-path)))
          ;; `unwind-protect', never `prog1'.
          (unwind-protect
              (when-let* ((row (car (sqlite-select db crate--crate-sql
                                                   (crate--crate-spellings name)))))
                (crate--crate-entry row))
            (sqlite-close db)))
      (error nil))))

(defun crate--database-readable-p ()
  "Return non-nil when `crate-data-path' answers a query.
A missing file and a file that is not a database both answer nil."
  (and crate-data-path
       (file-exists-p crate-data-path)
       (condition-case nil
           (let ((db (sqlite-open crate-data-path)))
             (unwind-protect
                 (progn (sqlite-select db "SELECT name FROM crates LIMIT 1") t)
               (sqlite-close db)))
         (error nil))))


;;; Local Crates

;; A local crate is a directory that holds a `Cargo.toml', so it has
;; no row in the crates.io database.  `cargo metadata' answers the
;; fields and the dependency list of that directory, and the command
;; maps the answer onto the same record that a database row builds, so
;; every section inserter works on both sources unchanged.

(defun crate-local--manifest (dir)
  "Return the manifest path of the Cargo package in DIR."
  (declare (pure t) (side-effect-free t))
  (expand-file-name "Cargo.toml" (file-name-as-directory (expand-file-name dir))))

(defun crate-local--metadata (dir)
  "Return the `cargo metadata' JSON of the package in DIR, or nil.
`--no-deps' resolves no dependency and downloads nothing, and
`--offline' guarantees that promise."
  (when-let* ((program crate-cargo-program)
              (cargo (executable-find program)))
    (with-temp-buffer
      (when (eq 0 (let ((default-directory
                         (file-name-as-directory (expand-file-name dir))))
                    (call-process cargo nil '(t nil) nil
                                  "metadata" "--no-deps" "--offline"
                                  "--format-version" "1")))
        (goto-char (point-min))
        (condition-case nil
            (json-parse-buffer)
          (error nil))))))

(defun crate-local--package (json manifest)
  "Return the package of `cargo metadata' JSON that MANIFEST names.
A workspace directory answers every package of the workspace, so
the first package answers as a fallback."
  (declare (side-effect-free t))
  (when-let* ((packages (gethash "packages" json)))
    (or (seq-find (lambda (package)
                    (equal (expand-file-name (gethash "manifest_path" package))
                           (expand-file-name manifest)))
                  packages)
        (car packages))))

(defun crate-local--git-url (source)
  "Return the web URL that git SOURCE names."
  (declare (pure t) (side-effect-free t))
  (let ((url (string-remove-prefix "git+" source)))
    (if-let* ((hash (string-search "#" url)))
        (substring url 0 hash)
      url)))

(defun crate-local--dependency-row (dep dir)
  "Return a dependency row for the `cargo metadata' dependency DEP.
The row has the shape of a `dependencies' database row plus a
`(KIND . TARGET)' source spec, which says where the code of a path
or a git dependency lives.  Cargo answers a path as an absolute
name, so the row makes it relative to DIR."
  (declare (side-effect-free t))
  (let ((kind (gethash "kind" dep))
        (optional (gethash "optional" dep))
        (path (gethash "path" dep))
        (source (gethash "source" dep)))
    (list (gethash "name" dep)
          (gethash "req" dep)
          (if (or (null kind) (eq kind :null)) "normal" kind)
          (if (eq optional t) 1 0)
          (cond
           ((stringp path)
            (cons "path" (file-relative-name path (expand-file-name dir))))
           ((and (stringp source) (string-prefix-p "git+" source))
            (cons "git" (crate-local--git-url source)))))))

(defun crate-local--entry (package dir)
  "Return a crate record for the `cargo metadata' PACKAGE in DIR.
The record reads like a database record and adds the `path' key,
which a reader can show by adding `(path . \"Path\")' to
`crate-detail-fields'."
  (declare (side-effect-free t))
  (let ((entry (make-hash-table :test #'equal))
        (path (directory-file-name (file-name-as-directory
                                    (expand-file-name dir)))))
    (dolist (key '("name" "description" "homepage" "repository"
                   "documentation" "license"))
      (let ((value (gethash key package)))
        (unless (or (null value) (eq value :null))
          (puthash key value entry))))
    (when-let* ((version (gethash "version" package)))
      (puthash "latest_version" version entry))
    (puthash "path" path entry)
    (puthash "dependencies"
             (mapcar (lambda (dep) (crate-local--dependency-row dep dir))
                     (gethash "dependencies" package))
             entry)
    entry))

(defun crate-local--record (dir)
  "Return the crate record of the local crate in DIR, or nil."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (manifest (crate-local--manifest dir))
         (cached (with-memoization
                     (gethash (list 'local manifest) crate--data-cache)
                   (or (when-let* ((json (crate-local--metadata dir))
                                   (package (crate-local--package json manifest)))
                         (crate-local--entry package dir))
                       :failed))))
    (unless (eq cached :failed)
      cached)))

(defun crate-local--forget (dir)
  "Drop the cached record of the local crate in DIR."
  (remhash (list 'local (crate-local--manifest dir)) crate--data-cache))


;;; Doc Build

(defcustom crate-doc-enable t
  "When non-nil, enable on-demand rustdoc builds via Nix.
Requires Nix and the nightly rustc toolchain, which the companion
crate-doc.nix fetches."
  :type 'boolean
  :group 'crate)

(defvar crate-doc--cache (make-hash-table :test #'equal)
  "Cache mapping (crate name, database path) keys to parsed rustdoc JSON.
Memoized — cleared by `crate-refresh-cache'.")

(defun crate-doc--nix-path ()
  "Return the path of the companion crate-doc.nix file, or nil."
  (when-let* ((lib (locate-library "crate"))
              (dir (file-name-directory lib)))
    (seq-find #'file-exists-p
              (list (expand-file-name "crate-doc.nix" dir)
                    (expand-file-name "nix/crate-doc.nix" dir)))))

(defvar crate-doc--in-flight (make-hash-table :test #'equal)
  "In-flight async doc builds keyed by crate name.")

(defvar crate-doc--render-function nil
  "Function that re-renders the buffer of a finished rustdoc build.
A buffer that starts a build sets this buffer-locally.  nil means
`crate--render', the detail buffer.")

(defvar crate-doc--generation 0
  "Generation counter for async doc builds.
Bumped by `crate-refresh-cache'; results from older generations
are discarded.")

(defun crate-doc--json-from-build (out)
  "Parse the rustdoc JSON from `nix-build' output buffer OUT, or nil."
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
Returns non-nil when a build is running, nil when unavailable: a
missing `nix-build', a missing crate-doc.nix or a spawn failure
caches the `:failed' sentinel, so the buffer shows no module tree
and no error."
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
                               (funcall (or crate-doc--render-function
                                            #'crate--render))))
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
A first call starts an async build and answers nil.  The build
re-renders the crate buffer when it completes."
  (when (and crate-doc-enable (crate--crate name))
    (let ((cached (gethash (list name crate-data-path) crate-doc--cache)))
      (cond
       ((eq cached :failed) nil)
       (cached cached)
       (t
        (crate-doc--start-build name (current-buffer))
        nil)))))

(defun crate-doc--module-tree (json)
  "Return the module tree from rustdoc JSON.
Returns a nested list `((NAME KIND (CHILDREN...) DOC) ...)', where
KIND is a symbol such as `module' or `struct' and DOC is the first
sentence of the item's docstring, or nil."
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
                         ;; entries (which `crate-insert-module-items' can't render).
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
Truncates to `fill-column', and answers an empty string when the
description is missing or :null."
  (declare (side-effect-free t))
  (or (when-let* ((it (gethash "description" crate-data))
                  ((not (eq it :null))))
        (setq it (string-replace "\n" "" it))
        (setq it (truncate-string-to-width it fill-column nil nil t))
        it)
      ""))

(defun crate--deps (name)
  "Return dependency rows for crate NAME from the SQLite database.
Each row is `(DEP_NAME REQ KIND OPTIONAL)'."
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

(defconst crate--dependents-sql
  "SELECT DISTINCT crate_name FROM dependencies WHERE dep_name = ?
   ORDER BY crate_name")

(defun crate--dependents (name)
  "Return the names of crates depending on crate NAME.
A reverse lookup on the `dependencies' table, cut at
`crate-dependents-limit' rows."
  (car (crate--dependents-data name)))

(defun crate--dependents-truncated-p (name)
  "Return non-nil when `crate--dependents' cut the list for NAME."
  (cdr (crate--dependents-data name)))

(defun crate--dependents-data (name)
  "Return the (NAMES . TRUNCATED) pair that describes the dependents of NAME.
TRUNCATED is non-nil when more crates depend on NAME than NAMES
lists.  A crate that nothing depends on caches `(nil . nil)', which
survives the `or' of `with-memoization'."
  (when (and crate-data-path (file-exists-p crate-data-path))
    (let ((cached
           (with-memoization
               (gethash (list 'dependents crate-data-path name) crate--data-cache)
             (condition-case nil
                 (let* ((db (sqlite-open crate-data-path))
                        (limit (and crate-dependents-limit
                                    (1+ crate-dependents-limit)))
                        (rows
                         (unwind-protect
                             (mapcar #'car
                                     (if limit
                                         (sqlite-select
                                          db (concat crate--dependents-sql " LIMIT ?")
                                          (list name limit))
                                       (sqlite-select db crate--dependents-sql
                                                      (list name))))
                           (sqlite-close db))))
                   (if limit
                       (cons (seq-take rows crate-dependents-limit)
                             (> (length rows) crate-dependents-limit))
                     (cons rows nil)))
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
  "Face for the crate name."
  :group 'crate)

(defface crate-url
  '((t :inherit link))
  "Face for URLs."
  :group 'crate)

(defface crate-date
  '((t :inherit marginalia-date))
  "Face for update dates."
  :group 'crate)

(defface crate-id
  '((t :inherit marginalia-number))
  "Face for ID numbers."
  :group 'crate)

(defface crate-version
  '((t :inherit (shadow)))
  "Face for versions."
  :group 'crate)

(defface crate-license
  '((t :inherit (shadow)))
  "Face for licenses."
  :group 'crate)

(defface crate-description
  '((t :inherit (package-description default)))
  "Face for descriptions."
  :group 'crate)

(defface crate-field-label
  '((t :inherit font-lock-variable-name-face))
  "Face for a field label."
  :group 'crate)

(defvar crate-font-lock-keywords
  `(;; Field labels: "Name:", "Description:".
    ;; `font-lock-ensure' wipes a `face' property that no keyword
    ;; matches, so every face of the renderer lives in this list and
    ;; not in a `propertize' call.
    ("^\\([A-Z][a-z]+\\):" (1 'crate-field-label))
    ;; Section headings: "Dependencies", "Modules (12)".  A heading
    ;; carries no colon, so it reads unlike a field label and the
    ;; automatic child count never rewrites it.
    ("^\\([A-Z][a-z]+\\)\\(?: ([0-9]+)\\)?$" (1 'magit-section-heading))
    ;; Child count of a section heading.  `magit-insert-heading'
    ;; writes it into the heading string before the body starts.
    ("^\\(?:[A-Z][a-z]+\\)\\( ([0-9]+)\\)$" (1 'magit-section-child-count))
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
    ;; Kind tags in the rustdoc module tree ("  - [struct] name")
    ("^[[:space:]]*- \\(\\[[a-z]+\\]\\)"
     (1 'crate-version))
    ;; Names of the rustdoc module tree.  A node is the content of
    ;; the section above it, so it carries no heading face.
    ("^[[:space:]]*- \\(?:\\[[a-z]+\\] \\)?\\([^[:space:]\n]+\\)"
     (1 'default))
    ;; Doc summaries of the rustdoc module tree
    ("^[[:space:]]*- \\(?:\\[[a-z]+\\] \\)?[^[:space:]\n]+ \\(— .*\\)$"
     (1 'crate-description)))
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

(defvar-keymap crate-link-map
  :doc "Keymap of a text button link.
TAB folds the section of point instead of moving to the next
link."
  :parent button-map
  "TAB" #'magit-section-toggle)

(define-button-type 'crate-link
  'action #'crate--button-url
  'face 'crate-url
  'mouse-face 'highlight
  'follow-link t
  'keymap crate-link-map
  'help-echo "Open link")

;;; Point keeping

;; A render erases the buffer, so `crate--render' records the line of
;; point before the render and restores it after the render.  The
;; record names the section of the line, the distance in lines from the
;; start of that section and the column, and `magit-section' finds the
;; section again through the value that it carries.  A render that
;; drops the section of point leaves point at the start of the buffer.

(defun crate--line-record (position)
  "Return a record of the line at POSITION, or nil.
A line without a section holds no place to keep, so it has no
record."
  (when-let* ((section (magit-section-at position)))
    (cons section
          (list (- (line-number-at-pos position)
                   (line-number-at-pos (oref section start)))
                (- position (save-excursion
                              (goto-char position)
                              (line-beginning-position)))))))

(defun crate--window-records ()
  "Return a record of the buffer point and of the point of each window.
The first record carries nil in place of a window, because a buffer
can show in no window."
  (cons (cons nil (crate--line-record (point)))
        (mapcar (lambda (window)
                  (cons window (crate--line-record (window-point window))))
                (get-buffer-window-list (current-buffer) nil t))))

(defun crate--restore-record (record)
  "Move point to the line that RECORD names.
A record of a section that the render dropped leaves point at the
start of the buffer."
  (pcase-let ((`(,section . (,line ,column)) record))
    (when section
      (unless (magit-section-goto-successor section line column)
        (goto-char (point-min))))))

(defun crate--goto-start ()
  "Move the buffer point and every window point to the start of the buffer."
  (goto-char (point-min))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-point window (point-min))))

(defun crate--restore-window-records (records)
  "Move the point of the buffer and of every window of RECORDS."
  (dolist (record records)
    (let ((window (car record)))
      (cond
       ((null window)
        (crate--restore-record (cdr record)))
       ((window-live-p window)
        ;; A window keeps the point of the buffer point, so a restore
        ;; for a window must not move the point of the buffer.
        (save-excursion
          (crate--restore-record (cdr record))
          (set-window-point window (point))))))))

;;; Sections

;; A detail buffer is a tree of `magit-section' sections, so it folds,
;; highlights and moves like a Magit buffer.  Every section carries a
;; value that a later render finds again, which is how two things
;; survive an erase: `magit-section' restores the folds through
;; `magit-section-visibility-cache' (keyed by that value), and
;; `crate--restore-record' puts point back on its line.
;;
;; `magit-section-inhibit-markers' stays on, because a marker per
;; section end makes a render quadratic in the size of the module tree:
;; four thousand sections take 1.4s with markers and 0.06s without.
;; A crate buffer inserts once and then only reads, so plain positions
;; serve until the next render rebuilds them.
;; A heading therefore carries no colon.  With markers inhibited,
;; `magit-insert-child-count' rewrites the heading of a section that
;; ends in a colon after its children recorded their positions, so a
;; fold would cut at the wrong place.  Instead `magit-insert-heading'
;; writes the count into the heading string before the body starts,
;; reads `magit-section-show-child-count' for it, and paints the number
;; with `magit-section-child-count'.  A field label keeps its colon and
;; carries the `crate-field-label' face, so a reader tells a field from
;; a foldable section at a glance.

(defun crate--child-count (count)
  "Return COUNT for a section heading, or nil.
A section without a child and a reader that turns
`magit-section-show-child-count' off both get nil."
  (declare (side-effect-free t))
  (and (> count 0) magit-section-show-child-count count))

(defun crate--module-count (items)
  "Return the number of sections that ITEMS inserts.
An item named `:null' is a use import and starts no section."
  (declare (side-effect-free t))
  (crate--child-count
   (cl-count-if-not (lambda (item) (eq (car item) :null)) items)))

(defun crate-insert-field (key label)
  "Insert the section of the field KEY, labelled LABEL.
The section carries KEY as its value, so a render keeps point on
the field."
  (magit-insert-section (crate-field key)
    (insert (format crate--field-label-format (concat label ":")))
    (pcase key
      ('name (insert (or (gethash "name" crate-data) crate-name)))
      ('description (insert (crate--description)))
      ('repository (crate--insert-repository))
      ('documentation (crate--insert-documentation))
      ('downloads (crate--insert-downloads))
      (_ (crate--insert-value (symbol-name key))))
    (insert "\n")))

(defun crate--insert-value (key)
  "Insert the value of KEY from `crate-data'.
Nothing follows the label when the value is nil or a JSON null."
  (let ((value (gethash key crate-data)))
    (unless (or (null value) (eq value :null))
      (insert value))))

(defun crate--insert-downloads ()
  "Insert the download count of `crate-data', formatted for reading."
  (when-let* ((count (gethash "downloads" crate-data)))
    (insert (crate--format-downloads count))))

(defun crate--insert-repository ()
  "Insert the repository URL and select its local checkout.
A local crate makes its own directory the `default-directory'."
  (crate--insert-value "repository")
  (if crate-local-path
      (setq-local default-directory (file-name-as-directory crate-local-path))
    (when-let* ((repo (gethash "repository" crate-data))
                ((not (eq repo :null)))
                (dir (crate--repository-directory repo)))
      (when (file-exists-p dir)
        (setq-local default-directory dir)))))

(defun crate--repository-directory (repo)
  "Return the local checkout directory of REPO, or nil."
  (declare (side-effect-free t))
  (cond
   ((functionp crate-repository-directory)
    (funcall crate-repository-directory repo))
   ((stringp crate-repository-directory)
    (expand-file-name (string-replace "/" "__"
                                      (string-remove-prefix "https://" repo))
                      crate-repository-directory))))

(defun crate--insert-documentation ()
  "Insert the documentation URL, or a link to the docs.rs page."
  (let ((doc (gethash "documentation" crate-data)))
    (if (and doc (not (eq doc :null)))
        (insert doc)
      (let ((url (format "https://docs.rs/%s"
                         (downcase (string-replace "_" "-"
                                                   (or (gethash "name" crate-data)
                                                       crate-name))))))
        (insert-text-button url
                            :type 'crate-link
                            'action (lambda (_) (browse-url url))
                            'help-echo "Open documentation on docs.rs")))))

(defun crate-insert-fields ()
  "Insert one field section per entry of `crate-detail-fields'."
  (dolist (field crate-detail-fields)
    (crate-insert-field (car field) (cdr field))))

(defun crate--dependencies ()
  "Return the dependency rows of the current crate."
  (if crate-local-path
      (gethash "dependencies" crate-data)
    (crate--deps crate-name)))

(defun crate--dependency-target (dep local)
  "Return the version or the source column of dependency row DEP.
A LOCAL row comes from `cargo metadata', so a registry dependency
reads like a Cargo.toml line and a path or a git dependency shows
the table that names its origin."
  (declare (pure t) (side-effect-free t))
  (if-let* ((source (nth 4 dep)))
      (format "{ %s = \"%s\" }" (car source) (cdr source))
    (if local
        (format "= \"%s\"" (string-remove-prefix "^" (or (nth 1 dep) "*")))
      (or (nth 1 dep) ""))))

(defun crate--dependency-note (dep)
  "Return the kind and optional note of dependency row DEP."
  (declare (pure t) (side-effect-free t))
  (concat (when-let* ((kind (nth 2 dep))
                      ((not (equal kind "normal"))))
            (format "  %s" kind))
          (when (memq (nth 3 dep) '(1 t))
            "  (optional)")))

(defun crate-insert-dependencies ()
  "Insert the Dependencies section of the current crate."
  (when-let* ((deps (crate--dependencies)))
    (insert "\n")
    (magit-insert-section (crate-dependencies)
      (magit-insert-heading (crate--child-count (length deps))
                            "Dependencies")
      (dolist (dep deps)
        (let ((name (nth 0 dep))
              (source (nth 4 dep)))
          ;; A path or a git dependency has no crates.io page of its
          ;; own, so its name stays plain text.
          (if source
              (insert name)
            (insert-text-button name
                                :type 'crate-link
                                'action (lambda (_) (find-crate name))
                                'help-echo (format "View crate: %s" name)
                                'crate-url (concat crate--crates-io-url name)))
          (insert (make-string (max (- 40 (length name)) 1) ?\s)
                  (crate--dependency-target dep crate-local-path)
                  (crate--dependency-note dep)
                  "\n"))))))

(defun crate-insert-dependents ()
  "Insert the Dependents section of the current crate.
The heading marks a list that `crate-dependents-limit' cut with a
plus sign."
  (when-let* ((dependents (crate--dependents crate-name)))
    (insert "\n")
    (magit-insert-section (crate-dependents)
      (if (and magit-section-show-child-count
               (crate--dependents-truncated-p crate-name))
          ;; `magit-insert-heading' formats a count it receives, so
          ;; the whole heading carries its faces here.
          (magit-insert-heading
           (concat (propertize "Dependents " 'font-lock-face 'magit-section-heading)
                   (propertize (format "(%d+)" (length dependents))
                               'font-lock-face 'magit-section-child-count)))
        (magit-insert-heading (crate--child-count (length dependents))
                              "Dependents"))
      (dolist (name dependents)
        (insert-text-button name
                            :type 'crate-link
                            'action (lambda (_) (find-crate name))
                            'help-echo (format "View crate: %s" name)
                            'crate-url (concat crate--crates-io-url name))
        (insert "\n")))))

(defun crate-insert-modules ()
  "Insert the Modules section of the current crate.
It appears only when `crate-doc--json' answers, a build runs, or a
build failed.  A local crate shows no section, because no rustdoc
build feeds it yet."
  (unless crate-local-path
    (let* ((json (crate-doc--json crate-name))
           (tree (and json (crate-doc--module-tree json)))
           (failed (gethash (list crate-name crate-data-path) crate-doc--cache))
           (building (and crate-doc-enable
                          (gethash crate-name crate-doc--in-flight))))
      (when (or json failed building)
        (insert "\n")
        (magit-insert-section (crate-modules)
          (magit-insert-heading (crate--module-count tree) "Modules")
          (cond
           (json
            (crate-insert-module-items tree 0 ""))
           (failed
            (insert "(rustdoc unavailable)\n"))
           (building
            (insert "(rustdoc build in progress…)\n"))))))))

(defun crate-insert-module-items (items depth path)
  "Insert ITEMS of the module tree at DEPTH, inside the module PATH.
Each item becomes a section whose value is its full path, so the
fold of a module and the line of point survive a render."
  (dolist (item items)
    (let ((name (car item))
          (kind (cadr item))
          (children (caddr item))
          (docs (cadddr item)))
      (unless (eq name :null)
        (let ((identity (if (string-empty-p path)
                            name
                          (concat path "/" name))))
          (magit-insert-section (crate-module identity)
            (insert (make-string (* depth 2) ?\s) "- ")
            (when kind
              (insert (format "[%s] " kind)))
            (insert name)
            (when docs
              (insert " — " docs))
            (magit-insert-heading)
            (when children
              (crate-insert-module-items children (1+ depth) identity))))))))

;;; Major Mode

(defun crate--thing-at-point-url ()
  "Return the crates.io URL for a dependency crate name at point.
Serves as a `thing-at-point-provider-alist' entry for `crate-mode'.
Returns nil unless point is on text carrying a `crate-url'
property."
  (get-text-property (point) 'crate-url))

(defvar-keymap crate-mode-map
  :doc "Keymap for `crate-mode'."
  :parent magit-section-mode-map
  "RET" #'push-button
  "w" #'crate-copy-dependency)

(define-derived-mode crate-mode magit-section-mode "Crate"
  "Major mode for displaying Rust crate details.

\\{crate-mode-map}
Do not invoke this mode directly.  Use `find-crate' for a crates.io
crate and `crate-visit-directory' for a local directory that holds
a `Cargo.toml'.  `crate--render' inserts the buffer content after
the mode is set up."
  :interactive nil
  (setq-local font-lock-defaults '(crate-font-lock-keywords))
  ;; See the comment above `crate-insert-field': a marker per section
  ;; end makes a render quadratic in the size of the module tree.
  ;; `magit-section-show-child-count' stays at its default, because the
  ;; reader decides whether a heading carries its count.
  (setq-local magit-section-inhibit-markers t)
  (when crate-goto-address
    (goto-address-mode 1))
  (setq-local bookmark-make-record-function
              #'crate--bookmark-make-record-function)
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
A local crate reads its `Cargo.toml' again first, so `g' shows an
edited description or dependency list."
  (when crate-local-path
    (crate-local--forget crate-local-path)
    (when-let* ((record (crate-local--record crate-local-path)))
      (setq-local crate-data record)))
  (crate--render))

(defun crate--render ()
  "Render the current crate detail buffer.
Erases existing content first, so re-rendering is idempotent.
Keeps point, its column and the point of every window on the same
line, by the section of that line, and keeps the folds."
  ;; The records come before the erase, because the erase removes the
  ;; text that both the sections and the window points point into.
  (let* ((fresh (= (point-min) (point-max)))
         (records (unless fresh (crate--window-records))))
    ;; Bind `inhibit-read-only' for the whole render: the buffer may
    ;; already be read-only from a previous render.
    (let ((inhibit-read-only t))
      (erase-buffer)
      (magit-insert-section (crate-detail)
        (magit-run-section-hook 'crate-detail-sections-hook))
      (font-lock-ensure)
      (set-buffer-modified-p nil))
    ;; Show the root section with the visibility cache off, so the cache
    ;; holds an entry only for a section that a user folded or
    ;; unfolded, and the hook that reads it stays cheap.
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (if fresh
        (crate--goto-start)
      (crate--restore-window-records records))))


;;; Completion

(defun crate--sql-like-escape (s)
  "Escape LIKE wildcards in S for use with ESCAPE '\\'.
Underscore and percent are valid crate-name characters, so they
must match literally."
  (declare (pure t) (side-effect-free t))
  (setq s (string-replace "\\" "\\\\" s))
  (setq s (string-replace "%" "\\%" s))
  (string-replace "_" "\\_" s))

(defconst crate--match-names-sql
  "SELECT name FROM crates WHERE name LIKE ? ESCAPE '\\' ORDER BY name")

(defun crate--match-names (prefix)
  "Return published crate names starting with PREFIX.
Queries SQLite per call, so no full name list materializes.

The connection turns on `case_sensitive_like'.  `LIKE' compares
case-insensitively by default, which keeps SQLite off the `name'
primary-key btree: `EXPLAIN QUERY PLAN' answers `SCAN crates', and
one keystroke costs 50 ms.  Stored names are all lowercase, so a
case-sensitive LIKE over a downcased PREFIX walks the btree
instead: 0.03 ms."
  (when (and crate-data-path (file-exists-p crate-data-path))
    (condition-case nil
        (let ((db (sqlite-open crate-data-path))
              (pattern (concat (crate--sql-like-escape (downcase prefix)) "%")))
          ;; `unwind-protect', never `prog1'.
          (unwind-protect
              (progn
                (sqlite-execute db "PRAGMA case_sensitive_like=ON")
                (mapcar #'car
                        (if crate-completion-limit
                            (sqlite-select db (concat crate--match-names-sql " LIMIT ?")
                                           (list pattern crate-completion-limit))
                          (sqlite-select db crate--match-names-sql (list pattern)))))
            (sqlite-close db)))
      (error nil))))

(defun crate--annotate (candidate)
  "Return the completion annotation for crate CANDIDATE."
  (let* ((data (crate--crate candidate))
         (desc (and data (gethash "description" data))))
    (when (and desc (not (eq desc :null))
               (not (string-empty-p desc)))
      (concat (propertize " " 'display '(space :align-to center))
              (string-limit (string-replace "\n" " " desc)
                            crate-annotation-width)))))

(defun crate--collection (string predicate action)
  "Return the completion collection for crates.
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
  "Discard cached crate data."
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
Interactively, prompt for a crate name with completion.  A
crates.io URL loses its prefix and any trailing version path."
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
    (let ((entry (crate--crate cand)))
      ;; No database at all: blame the configuration, not the name.
      (unless crate-data-path
        (user-error "No crate database configured — set `crate-data-path'"))
      (unless entry
        (if (crate--database-readable-p)
            (user-error "Crate `%s' not found" cand)
          (user-error "Crate database `%s' unreadable" crate-data-path)))
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

(defun crate-local--read-directory ()
  "Read the directory of a local crate with completion.
The `file-directory-p' predicate keeps files out of the
candidates."
  (completing-read "Crate directory: "
                   #'completion-file-name-table
                   #'file-directory-p
                   t nil 'file-name-history
                   (expand-file-name default-directory)))

;;;###autoload
(defun crate-visit-directory (&optional dir)
  "Display the Rust crate in local directory DIR in `crate-mode'.
DIR defaults to `default-directory' and must hold a `Cargo.toml'.
The buffer shows no Dependents and no Modules section for a crate
that the database does not hold."
  (interactive (list (crate-local--read-directory)))
  (let ((dir (file-name-as-directory
              (expand-file-name (or dir default-directory)))))
    (unless (file-exists-p (crate-local--manifest dir))
      (user-error "No Cargo.toml in `%s'" (directory-file-name dir)))
    (let ((record (crate-local--record dir)))
      (unless record
        (user-error "Cannot read the crate metadata of `%s'"
                    (directory-file-name dir)))
      (let* ((name (crate--canonical-name (gethash "name" record)))
             (bufname (format "Crate: %s (%s)" name
                              (directory-file-name dir))))
        (crate--display-buffer bufname)
        (crate-mode)
        ;; Set the crate locals after `crate-mode', whose
        ;; `kill-all-local-variables' would otherwise wipe them.
        (setq-local crate-name name)
        (setq-local crate-data record)
        (setq-local crate-local-path (directory-file-name dir))
        (crate--render)
        (run-hooks 'crate-visit-hook)))))


;;;###autoload
(defun crate-browse-url (url &rest _args)
  "Browse a Rust crate URL by dispatching to `find-crate'."
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
A local crate records its directory, so the handler reopens that
checkout and not the published crate of the same name."
  (let ((label (if crate-local-path
                   (format "Rust Crate: %s (%s)" crate-name crate-local-path)
                 (concat "Rust Crate: " crate-name))))
    `(,label
      (handler . crate-bookmark-jump)
      (crate . ,crate-name)
      (directory . ,crate-local-path)
      ;; This location tag is used as a description in the bookmark menu list
      (location . ,(crate--description)))))


;;;###autoload
(defun crate-bookmark-jump (bm)
  "Restore a crate bookmark BM.
A record with a directory goes to `crate-visit-directory' and
every other record to `find-crate'."
  (interactive (list (read-from-minibuffer "Bookmark: ")))
  (let ((dir (bookmark-prop-get bm 'directory)))
    (if dir
        (crate-visit-directory dir)
      (find-crate (bookmark-prop-get bm 'crate)))))
(put 'crate-bookmark-jump 'bookmark-handler-type "Crate")

;;; Org Integration

(with-eval-after-load 'org
  (require 'ol-crate))

;;; Evil Integration

;; The layer lives in its own file, so a user who has no evil loads no
;; evil code.  A user who loads evil after crate.el gets the layer at
;; that moment, and `crate-evil-auto-enable' decides whether the layer
;; enables itself.
(declare-function crate-evil-auto-setup "evil-crate" ())

(with-eval-after-load 'evil
  (require 'evil-crate)
  (crate-evil-auto-setup))


;;; Browse Mode

(defvar-keymap crate-browse-export-map
  :doc "Export keymap for `crate-browse-mode'."
  "c" #'crate-browse-export-cargo
  "m" #'crate-browse-export-markdown)

(defvar-keymap crate-browse-mode-map
  :doc "Keymap for `crate-browse-mode'."
  :parent tabulated-list-mode-map
  "RET" #'crate-browse-visit
  "C-c C-o" #'browse-url-at-point
  "o"   #'crate-browse-open-other-window
  "<mouse-2>" #'crate-browse-open-other-window-mouse
  "<follow-link>" #'crate-browse--click-selects-row
  "b"   #'crate-browse-search-url
  "w"   #'crate-copy-dependency
  "e"   crate-browse-export-map)

(define-derived-mode crate-browse-mode tabulated-list-mode "Crate-Browse"
  "Major mode for browsing Rust crates in a sortable table.

\\{crate-browse-mode-map}
The table shrinks its columns when the window is narrow."
  :interactive nil
  (setq tabulated-list-format
        [("Crate" 40 t)
         ("Version" 12 crate-browse--version-lessp)
         ("Description" 0 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Crate" . nil))
  ;; Make any cell of a row detectable as the crates.io URL of the
  ;; crate, so `browse-url-at-point' follows the row of point.
  (setq-local thing-at-point-provider-alist
              (cons '(url . crate-browse--thing-at-point-url)
                    thing-at-point-provider-alist))
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
  "Buffer-local list of crate names that the browse buffer is filtered to.")
(put 'crate-browse--name-list 'permanent-local t)

(defvar-local crate-browse--name-prefix nil
  "Buffer-local search term used for naming the browse buffer.")
(put 'crate-browse--name-prefix 'permanent-local t)

(defvar-local crate-browse--declared-widths nil
  "Column widths that `crate-browse-mode' declares.
Neither a window fit nor a bookmark changes this list.")

(defvar-local crate-browse--canonical-widths nil
  "Column widths that a window fit starts from.
A bookmark may replace it with the widths that it saved.")

(defvar-local crate-browse--fit-timer nil)

(defconst crate--version-re
  "\\`\\([0-9]+\\)\\(?:\\.\\([0-9]+\\)\\)?\\(?:\\.\\([0-9]+\\)\\)?\\(?:-\\([^+]+\\)\\)?\\(?:\\+.*\\)?\\'"
  "Regexp that splits a version string into its numeric and pre-release parts.
The minor and patch groups are optional, because a few old crates
publish a two-segment version such as \"0.1\".")

(defun crate--version-parts (version)
  "Return VERSION as (MAJOR MINOR PATCH PRE), or nil if it is no semver.
A missing segment counts as 0, so \"0.1\" reads as 0.1.0.  PRE is
nil for a release, or a list of pre-release identifiers.  Build
metadata after a plus sign does not affect precedence, so it is
dropped."
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
A numeric identifier sorts before an alphanumeric one."
  (declare (pure t) (side-effect-free t))
  (cond ((and (integerp a) (integerp b)) (< a b))
        ((integerp a) t)
        ((integerp b) nil)
        (t (string< a b))))

(defun crate--semver-pre-lessp (a b)
  "Return non-nil when pre-release list A sorts before list B.
A list that prefixes a longer list sorts first, so \"alpha\" comes
before \"alpha.1\"."
  (declare (pure t) (side-effect-free t))
  (cond ((null a) t)
        ((null b) nil)
        ((equal (car a) (car b))
         (crate--semver-pre-lessp (cdr a) (cdr b)))
        (t (crate--semver-identifier-lessp (car a) (car b)))))

(defun crate--version-lessp (a b)
  "Return non-nil when version string A sorts before version string B.
Compare as semver, so \"1.9.0\" sorts before \"1.10.0\" and
\"1.0.0-rc.1\" before \"1.0.0\".  A value that is no semver falls
back to `string<', and an empty value sorts last."
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
The Version column compares semvers rather than the strings it
prints."
  (declare (side-effect-free t))
  (crate--version-lessp (crate-browse--cell-text (aref (cadr a) 1))
                        (crate-browse--cell-text (aref (cadr b) 1))))

(defun crate-browse--entry (name data)
  "Return a `tabulated-list' entry for crate NAME with DATA."
  (declare (side-effect-free t))
  (let ((desc (gethash "description" data))
        (version (gethash "latest_version" data)))
    (list name
          (vector (propertize name 'face 'crate-name-face
                              'crate-url (concat crate--crates-io-url name))
                  (propertize (or version "") 'face 'crate-version)
                  (propertize (if (and desc (not (eq desc :null)))
                                  (string-limit (string-replace "\n" " " desc)
                                                crate-annotation-width)
                                "")
                              'face 'crate-description)))))

(defun crate-browse--entry-less (a b)
  "Return non-nil if tabulated-list entry A sorts before B by name."
  (declare (side-effect-free t))
  (string< (car a) (car b)))

(defun crate-browse--entries (&optional name-list)
  "Generate `tabulated-list-entries' for all crates.
When NAME-LIST is non-nil, only include entries whose names
appear in the list.  The entries are sorted by name, because hash
iteration order is not."
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

(defun crate-browse--thing-at-point-url ()
  "Return the crates.io URL of the table row at point.
Serves as a `thing-at-point-provider-alist' entry for
`crate-browse-mode'."
  (declare (side-effect-free t))
  (or (crate--thing-at-point-url)
      (when-let* ((name (tabulated-list-get-id)))
        (concat crate--crates-io-url name))))

;;; Mouse and context menu

(defconst crate-browse--mouse-help
  "mouse-2: open in another window, mouse-3: menu")

(defun crate-browse--print-entry (id columns)
  "Print one table row for ID and COLUMNS, then add its mouse help.
The whole row explains the mouse, and the name cell carries
`mouse-face'."
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
The middle button opens a detail buffer."
  nil)

(defun crate-browse--context-command (position buffer function)
  "Return a command that moves point to POSITION in BUFFER, then calls FUNCTION.
A context menu click leaves point alone, and the menu command can
run in another buffer."
  (lambda ()
    (interactive)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (integer-or-marker-p position)
          (goto-char (min position (point-max))))
        (funcall function)))))

(defun crate-browse--context-menu (menu click)
  "Fill MENU with the table commands for the row under CLICK.
A click below the last row adds nothing."
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
  "Return the width of the widest cell of ENTRIES in COLUMN."
  (declare (pure t) (side-effect-free t))
  (let ((longest 0))
    (dolist (entry entries longest)
      (setq longest
            (max longest
                 (string-width
                  (crate-browse--cell-text (aref (cadr entry) column))))))))

(defun crate-browse--content-widths (entries)
  "Return the declared widths with the Version column sized to ENTRIES.
The header label is the floor, so the label never truncates."
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
The last column takes the remaining space, and the columns before
it give way: a middle column shrinks to 8 and the Crate column to
`crate-browse-name-min-width'."
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
Answers nil when the current widths already fit."
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
print lands in the selected window."
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
timer.  One pending timer per buffer is enough."
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
  "Refit the crate tables shown in the windows of FRAME."
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
Each row is a cons of its entry ID and its column vector, and a
line without an entry adds no row."
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
The face of a cell goes away with the properties."
  (declare (pure t) (side-effect-free t))
  (string-trim
   (replace-regexp-in-string
    "[ \t\n\r]+" " "
    (substring-no-properties (crate-browse--cell-text cell)))))

(defun crate-browse--export-markdown (rows)
  "Return ROWS as a Markdown table.
The header names the columns of `tabulated-list-format'."
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
  "Return ROWS as `Cargo.toml' dependency lines."
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
  "Show the export LABEL with TEXT in a read-only buffer."
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
The export follows the current sort and the filter."
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
`revert-buffer' (`g') keeps the filter."
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
match the table are ignored, so an old bookmark still opens."
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
The filtered name-list is re-derived from the live cache."
  (let ((name-prefix (bookmark-prop-get bookmark 'name-prefix))
        name-list)
    (when name-prefix
      (setq name-list (crate--filter-by-name name-prefix)))
    (crate-browse-crates name-list name-prefix)
    (crate-browse--restore-state bookmark)))

;;;###autoload
(defun crate-browse-crates (&optional name-list name-prefix)
  "Display Rust crates in a browseable table.
NAME-LIST restricts the table to the listed crates.  NAME-PREFIX
names the buffer \"*Crates: serde*\", so several searches coexist
in separate buffers."
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
A nil, `:null' or empty VERSION becomes \"*\"."
  (declare (pure t) (side-effect-free t))
  (format "%s = \"%s\"" name
          (if (and (stringp version) (not (string-empty-p version)))
              version
            "*")))

(defun crate-copy-dependency (&optional name)
  "Copy a Cargo.toml dependency line for crate NAME to the `kill-ring'.
The line has the form NAME = \"VERSION\" and falls back to \"*\" when
the version is unknown.  Interactively, NAME is the current crate
in `crate-mode' or the entry at point in `crate-browse-mode'."
  (interactive)
  (let* ((name (or name
                   (cond
                    ((derived-mode-p 'crate-mode) crate-name)
                    ((derived-mode-p 'crate-browse-mode)
                     (crate-browse--current-name))
                    (t (user-error "No crate to copy")))))
         (data (or (and crate-name (string= name crate-name) crate-data)
                   (crate--crate name)))
         (version (and data (gethash "latest_version" data)))
         (line (crate--dependency-line
                (or (and data (gethash "name" data)) name)
                version)))
    (kill-new line)
    (message "Copied: %s" line)))


;;; Cargo.toml Integration

(defcustom crate-cargo-toml-modes '(toml-mode toml-ts-mode)
  "Major modes treated as `Cargo.toml' for crate-name completion.
crate.el never hard-requires a TOML mode."
  :type '(repeat symbol)
  :group 'crate)

(defun crate--cargo-in-dependencies-p ()
  "Return non-nil if point is inside a dependency section.
Recognizes the flat `[dependencies]', `[dev-dependencies]' and
`[build-dependencies]' headers, and excludes dotted tables, where
the crate name is already written."
  (save-excursion
    (when (re-search-backward "^\\[\\([^]]+\\)\\][[:space:]]*$" nil t)
      (member (match-string 1)
              '("dependencies" "dev-dependencies" "build-dependencies")))))

(defun crate-cargo-completion-at-point ()
  "Complete a crate name at point inside Cargo.toml dependency sections."
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
The function stays silent outside TOML modes and dependency
sections."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'crate-cargo-completion-at-point))


;;; Embark

(defvar embark-exporters-alist)
(defvar embark-keymap-alist)
(defvar embark-general-map)

(defun crate--embark-export (candidates)
  "Export crate CANDIDATES for Embark.
The minibuffer search term becomes the name-prefix, so a bookmark
can re-derive the results."
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
