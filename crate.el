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
;; crates from a local static.crates.io JSON dump.
;;
;; Data sources are configurable via `defcustom':
;;
;;   - `crate-data-path'  -- Path to a static.crates.io JSON dump file.
;;
;; Commands:
;;
;;   M-x find-crate  -- look up a Rust crate by name
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
(require 'ansi-color)


(defvar url-knowledge-url nil)
(defvar browse-url-default-handlers nil)

(defvar-local crate-name nil)
(put 'crate-name 'permanent-local t)
(defvar-local crate-data nil)
(put 'crate-data 'permanent-local t)

(defgroup crate nil
  "Browse Rust crates from a local JSON dump."
  :group 'tools
  :prefix "crate-"
  :link '(url-link :tag "Repository" "https://github.com/nagy/crate.el"))

(defcustom crate-data-path nil
  "Path to a static.crates.io JSON dump file.

The file should contain a flat JSON object where each key is a
crate name and each value is an object with fields like
\"description\", \"repository\", \"homepage\", etc."
  :type 'file
  :group 'crate)

(defcustom crate-modules-program "cargo-modules"
  "Name or path of the `cargo-modules' executable.

Used to generate crate module structure trees via
`cargo modules structure'.  Set to nil to disable."
  :type 'string
  :risky t
  :group 'crate)

(defconst crate--crates-io-url "https://crates.io/crates/"
  "Base URL for crates.io crate pages.")

(defcustom crate-annotation-width 70
  "Maximum width of the description annotation shown during completion."
  :type 'integer
  :group 'crate)

;;; Cache

(defvar crate--data-cache (make-hash-table :test #'equal))

(defun crate-list-json ()
  "Load the crate JSON dump from `crate-data-path'.
Returns a hash table keyed by lowercase crate name, or nil if the
file is missing or cannot be parsed.  Results are memoized via
`with-memoization'."
  (with-memoization (gethash 'data crate--data-cache)
    (when (and crate-data-path (file-exists-p crate-data-path))
      (condition-case nil
          (let ((raw (with-temp-buffer
                       (insert-file-contents crate-data-path)
                       (goto-char (point-min))
                       (json-parse-buffer)))
                (table (make-hash-table :test 'equal)))
            (maphash (lambda (key val)
                       (puthash (downcase key) val table))
                     raw)
            table)
        (error nil)))))

(defvar crate-structure--cache (make-hash-table :test #'equal))

(defun crate-structure (name)
  "Return the module structure tree for the crate NAME.
Invokes `crate-modules-program' to generate an ANSI-colored
tree.  Results are memoized per crate name via
`with-memoization'.  Returns nil on failure."
  (with-memoization (gethash name crate-structure--cache)
    (condition-case nil
        (with-temp-buffer
          (let ((pkg-dir (string-replace "_" "-" name))
                (exitcode (call-process crate-modules-program nil t nil "structure" "--package" (string-replace "_" "-" name) "--lib")))
            ;; the case in esp-hal crate
            (unless (eq 0 exitcode)
              (erase-buffer)
              (let ((default-directory pkg-dir))
                (call-process crate-modules-program nil t nil "structure" "--package" pkg-dir "--lib")))
            (string-remove-prefix "\n" (buffer-string))))
      (error nil))))

(defun insert-crate-structure ()
  "Insert the module structure tree for `crate-name' at point.
Applies ANSI color escapes in the inserted region.  Does nothing
if `crate-structure' returns nil."
  (when-let* ((tree (crate-structure crate-name)))
    (let ((p (point)))
      (insert tree)
      (ansi-color-apply-on-region p (point)))))


;;; Helpers

(defun crate--description ()
  "Return the description of the current crate.
Collapses newlines and truncates to `fill-column'.  Returns an
empty string when the description is missing or :null."
  (or (when-let* ((it (gethash "description" crate-data))
                  ((not (eq it :null))))
        (setq it (string-replace "\n" "" it))
        (setq it (truncate-string-to-width it fill-column nil nil t))
        it)
      ""))

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
    ;; URLs on Homepage/Documentation/Repository lines
    ("^\\(?:Homepage\\|Documentation\\|Repository\\):[[:space:]]+\\(https?://[^[:space:]\n]+\\)"
     (1 'crate-url nil t))
    ;; Updated date
    ("^Updated:[[:space:]]+\\(.+\\)"
     (1 'crate-date))
    ;; Crate id number
    ("^Id:[[:space:]]+\\([0-9]+\\)"
     (1 'crate-id)))
  "Font-lock keywords for `crate-mode'.")

;;; Major Mode

;;;###autoload
(define-derived-mode crate-mode text-mode "Crate"
  "Major mode for displaying Rust crate details.

\\{crate-mode-map}
This mode is not intended to be invoked directly; use
`find-crate' instead."
  (cd temporary-file-directory)
  (setq-local font-lock-defaults '(crate-font-lock-keywords))
  (setq-local bookmark-make-record-function #'crate--bookmark-make-record-function)
  (setq-local revert-buffer-function #'ignore)
  (setq-local url-knowledge-url (concat crate--crates-io-url crate-name))
  (setq-local list-buffers-directory (gethash "description" crate-data))
  (cl-labels
      ((field (label key)
         "Insert LABEL, then the value of KEY from `crate-data'.
If the value is nil or :null, nothing is inserted after the label."
         (insert label)
         (let ((val (gethash key crate-data)))
           (unless (or (null val) (eq val :null))
             (insert val)))
         (insert "\n")))
    (insert "Name:          ")
    (insert (or (gethash "name" crate-data) crate-name) "\n")
    (insert "Description:   ")
    (insert (crate--description))
    (insert "\n")
    ;; Repository (special: may cd into local checkout)
    (insert "Repository:    ")
    (when-let* ((it (gethash "repository" crate-data)))
      (unless (eq it :null)
        (insert (propertize it 'mouse-face 'highlight))
        (let ((filename (format "/mnt/archive/%s.git.sqfs/"
                                (string-replace "/" "__"
                                                (string-remove-prefix "https://" it)))))
          (when (file-exists-p filename)
            (cd filename)))))
    (insert "\n")
    (field "Homepage:      " "homepage")
    ;; Documentation (with docs.rs fallback)
    (insert (propertize "Documentation: " 'face 'crate-field-label))
    (let ((doc (gethash "documentation" crate-data)))
      (if (and doc (not (eq doc :null)))
          (insert doc)
        (let ((url (format "https://docs.rs/%s"
                           (downcase (string-replace "_" "-"
                                                     (or (gethash "name" crate-data) crate-name))))))
          (insert-text-button url
                              'action (lambda (_) (browse-url url))
                              'follow-link t
                              'face 'link
                              'help-echo "Open documentation on docs.rs"))))
    (insert "\n")
    (field "Updated:       " "updated_at")
    (insert "Id:            ")
    (when-let* ((it (gethash "id" crate-data)))
      (unless (eq it :null)
        (insert (number-to-string (floor it)))))
    (insert "\n\n")
    (insert-crate-structure)
    ;; Apply mouse-face to URLs (font-lock only handles the `face' property)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "https?://[^[:space:]\n]+" nil t)
        (add-text-properties (match-beginning 0) (match-end 0)
                             '(mouse-face highlight))))
    (font-lock-ensure)
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (read-only-mode 1)))


;;; Completion

(defvar crate--keys-cache nil
  "Cached list of lowercase crate names for completion.
Set by `crate--keys' and cleared by `crate-refresh-cache'.")

(defun crate--keys ()
  "Return the list of all crate names for completion.
Loads from `crate-data-path' if needed and caches the result."
  (unless crate--keys-cache
    (let ((data (crate-list-json)))
      (when data
        (setq crate--keys-cache (hash-table-keys data)))))
  crate--keys-cache)

(defun crate--annotate (candidate)
  "Completion annotation function for crate CANDIDATE."
  (let* ((data (gethash candidate (crate-list-json)))
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
     (complete-with-action action (crate--keys) string predicate))))

(defun crate-refresh-cache ()
  "Discard cached crate data.
The next `find-crate' or completion invocation will reload from
the JSON file."
  (interactive)
  (setq crate--data-cache (make-hash-table :test 'equal)
        crate--keys-cache nil
        crate-structure--cache (make-hash-table :test 'equal))
  (message "crate: cache cleared"))


;;; Marginalia

(defun crate--marginalia-annotator (cand)
  "Marginalia annotator for `crate' completion candidates.
Shows the crate description."
  (when-let* ((data (gethash cand (crate-list-json)))
              (desc (gethash "description" data))
              ((not (eq desc :null))))
    desc))

(defvar marginalia-annotator-registry nil)

(with-eval-after-load 'marginalia
  (add-to-list 'marginalia-annotator-registry
               '(crate crate--marginalia-annotator builtin none)))


;;; Interactive Commands

;;;###autoload
(defun find-crate (&optional name)
  "Display details for the Rust crate NAME in `crate-mode'.
When called interactively, prompt for a crate name with
completion.  If NAME is a crates.io URL, the URL prefix is
stripped first.  Creates a new buffer named \"Crate: <name>\"
or switches to an existing one."
  (interactive)
  (let ((cand (or name
                  (completing-read "crate> " #'crate--collection))))
    (when (string-prefix-p crate--crates-io-url cand)
      (setq cand (string-remove-prefix crate--crates-io-url cand)))
    (setq cand (downcase (string-replace "-" "_" cand)))
    (let ((bufname (format "Crate: %s" cand)))
      (if (get-buffer bufname)
          (switch-to-buffer bufname)
        (switch-to-buffer bufname)
        (setq-local crate-name cand)
        (setq-local crate-data
                    (when-let* ((data (crate-list-json)))
                      (or (gethash crate-name data)
                          (gethash (string-replace "_" "-" crate-name) data))))
        (if crate-data
            (crate-mode)
          (user-error "Crate `%s' not found" cand))))))


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

(defvar-keymap crate-browse-mode-map
  :doc "Keymap for `crate-browse-mode'."
  :parent tabulated-list-mode-map
  "RET" #'crate-browse-visit
  "b"   #'crate-browse-search-url
  "g"   #'crate-browse-refresh)

(define-derived-mode crate-browse-mode tabulated-list-mode "Crate-Browse"
  "Major mode for browsing Rust crates in a sortable table.

\\{crate-browse-mode-map}
\\<crate-browse-mode-map>
\\[crate-browse-visit] on an entry to view full details,
\\[crate-browse-search-url] to open on crates.io,
\\[crate-browse-refresh] to reload the data."
  :interactive nil
  (setq tabulated-list-format
        [("Crate" 40 t) ("Description" 0 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Crate" . nil))
  (tabulated-list-init-header)
  (hl-line-mode 1)
  (setq-local bookmark-make-record-function
              #'crate-browse--bookmark-make-record))

(defvar-local crate-browse--name-list nil
  "Buffer-local list of crate names that the browse buffer is filtered to.
When nil, all crates are shown.")

(defvar-local crate-browse--name-prefix nil
  "Buffer-local search term used for naming the browse buffer.")

(defun crate-browse--entry (name data)
  "Return a `tabulated-list' entry for crate NAME with DATA."
  (let ((desc (gethash "description" data)))
    (list name
          (vector (propertize name 'face 'crate-name-face)
                  (propertize (if (and desc (not (eq desc :null)))
                                  (string-limit (string-replace "\n" " " desc)
                                                crate-annotation-width)
                                "")
                              'face 'crate-description)))))

(defun crate-browse--entries (&optional name-list)
  "Generate `tabulated-list-entries' for all crates.
When NAME-LIST is non-nil, only include entries whose names
appear in the list."
  (let ((items (crate-list-json))
        entries)
    (when items
      (if name-list
          (dolist (name name-list (nreverse entries))
            (let ((data (gethash name items)))
              (when data
                (push (crate-browse--entry name data) entries))))
        (maphash (lambda (name data)
                   (push (crate-browse--entry name data) entries))
                 items)
        (setq entries (nreverse entries))))))

(defun crate-browse--current-name ()
  "Return the crate name at point, or signal an error."
  (or (tabulated-list-get-id)
      (user-error "No crate on this line")))

(defun crate-browse-visit ()
  "Display details for the crate at point."
  (interactive)
  (find-crate (crate-browse--current-name)))

(defun crate-browse-search-url ()
  "Open the current crate on crates.io."
  (interactive)
  (browse-url (concat crate--crates-io-url
                      (crate-browse--current-name))))

(defun crate-browse-refresh ()
  "Refresh the crate browse table."
  (interactive)
  (setq tabulated-list-entries
        (crate-browse--entries crate-browse--name-list))
  (tabulated-list-print t))

(defun crate-browse--bookmark-make-record ()
  "Create a bookmark record for the current browse buffer."
  `(,(format "Crates: %s"
             (or crate-browse--name-prefix
                 (format "%d items" (length tabulated-list-entries))))
    (name-list . ,crate-browse--name-list)
    (name-prefix . ,crate-browse--name-prefix)
    (handler . crate-browse--bookmark-jump)))

(defun crate-browse--bookmark-jump (bookmark)
  "Restore a crate browse BOOKMARK."
  (let ((name-list (alist-get 'name-list bookmark))
        (name-prefix (alist-get 'name-prefix bookmark)))
    (crate-browse-crates name-list name-prefix)))

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
      (setq tabulated-list-entries
            (crate-browse--entries name-list))
      (tabulated-list-print))
    (switch-to-buffer buf)))


;;; Embark

(defvar embark-exporters-alist nil)
(defvar embark-keymap-alist nil)
(defvar embark-general-map nil)

(defun crate--embark-export (candidates)
  "Embark export function for crate CANDIDATES.
Opens a `crate-browse-mode' buffer filtered to CANDIDATES."
  (crate-browse-crates candidates))

(defun crate--embark-browse-url (cand)
  "Open CAND on crates.io."
  (browse-url (concat crate--crates-io-url cand)))

(defvar-keymap crate-embark-map
  :doc "Embark actions for crate candidates."
  :parent embark-general-map
  "RET" #'find-crate
  "b"   #'crate--embark-browse-url
  "i"   #'insert)

(with-eval-after-load 'embark
  (add-to-list 'embark-exporters-alist
               '(crate . crate--embark-export))
  (add-to-list 'embark-keymap-alist
               '(crate . crate-embark-map)))

(provide 'crate)
;;; crate.el ends here
