;;; crate-tree.el --- Rust crate structure as a table -*- lexical-binding: t -*-

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

;;; Commentary:

;; The item structure of one crate, built from rustdoc JSON.
;;
;; The tree answers the same question as `cargo-modules structure':
;; which item lives in which module, with what kind and what
;; visibility.  Rustdoc JSON adds the span, the doc comment and the
;; attributes of every item.
;;
;; Item paths name a row and never change across a render, so a fold
;; keyed by a path survives a refresh.
;;
;; The parser keeps source order.  `crate-tree--structure-text' sorts
;; each sibling list by name and prints the `cargo-modules' format, so
;; a test compares the two tools line by line.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'crate)

(declare-function browse-url "browse-url" (url &rest args))

;;; Items

(cl-defstruct (crate-tree-item (:constructor crate-tree-item--create))
  "One item of a crate structure tree."
  path
  name
  kind
  kind-word
  vis-word
  span
  docs
  attrs
  deprecation
  children)

;;; Parsing

(defconst crate-tree--min-format 57
  "Oldest rustdoc JSON `format_version' that this parser reads.
Format 57 came with rustc 1.97 and format 61 with rustc 1.99, and
both parse the fixture crate the same way.  The field set moves
between releases, so the gate stays a range and an unknown number
refuses to parse instead of failing halfway.")

(defconst crate-tree--max-format 61
  "Newest rustdoc JSON `format_version' that this parser reads.")

(defconst crate-tree--structure-kinds
  '(module struct union enum trait type-alias function)
  "Item kinds that `cargo-modules structure' prints.")

(defun crate-tree--id-key (id)
  "Return ID as the string key that the rustdoc index uses."
  (if (integerp id)
      (number-to-string id)
    (number-to-string (floor id))))

(defun crate-tree--ids (value)
  "Return VALUE as a list of item ids.
`json-parse-buffer' answers a JSON array as a vector, and JSON null
as `:null'."
  (cond ((vectorp value) (append value nil))
        ((consp value) value)))

(defun crate-tree--json-item (index id)
  "Return the rustdoc item that INDEX holds under ID."
  (when (numberp id)
    (gethash (crate-tree--id-key id) index)))

(defun crate-tree--inner-key (item)
  "Return the variant name of the `inner' object of ITEM."
  (when-let* ((inner (gethash "inner" item))
              ((hash-table-p inner)))
    (car (hash-table-keys inner))))

(defun crate-tree--kind (inner-key)
  "Return the item kind symbol for INNER-KEY."
  (intern (string-replace "_" "-" inner-key)))

(defun crate-tree--function-word (function)
  "Return the kind word of a function whose object is FUNCTION."
  (let* ((header (gethash "header" function))
         (header (if (hash-table-p header) header (make-hash-table)))
         (modifiers
          (delq nil
                (list (and (eq t (gethash "is_async" header)) "async")
                      (and (eq t (gethash "is_unsafe" header)) "unsafe")
                      (and (eq t (gethash "is_const" header)) "const")))))
    (mapconcat #'identity (append modifiers '("fn")) " ")))

(defun crate-tree--kind-word (kind object root-p)
  "Return the display word of an item of KIND whose object is OBJECT.
ROOT-P marks the crate root, which `cargo-modules' calls a crate
and not a module."
  (pcase kind
    ('module (if root-p "crate" "mod"))
    ('function (crate-tree--function-word object))
    ('trait (if (eq t (gethash "is_unsafe" object))
                "unsafe trait"
              "trait"))
    ('type-alias "type")
    ('constant "const")
    ('assoc-const "const")
    ('assoc-type "type")
    ('struct-field "field")
    ('variant "variant")
    ('proc-macro "proc macro")
    ('struct "struct")
    ('union "union")
    ('enum "enum")
    ('static "static")
    ('macro "macro")
    ('use "use")
    (_ (symbol-name kind))))

(defun crate-tree--visibility-word (visibility containing parent trait-impl-p)
  "Return the visibility word of an item.
VISIBILITY is the rustdoc value: \"public\", \"crate\", \"default\" or
a `restricted' object.  CONTAINING and PARENT name the module that
holds the item and the module above it, in the `::a::b' form that
rustdoc uses for a restricted path.  TRAIT-IMPL-P marks a member of
a trait implementation, whose effective visibility rustdoc leaves
implicit and `cargo-modules' prints as `pub(crate)'."
  (cond
   ((equal visibility "public") "pub")
   ((equal visibility "crate") "pub(crate)")
   ((equal visibility "default") (if trait-impl-p "pub(crate)" "pub(self)"))
   ((hash-table-p visibility)
    (let* ((restricted (gethash "restricted" visibility))
           (path (and (hash-table-p restricted) (gethash "path" restricted))))
      (cond
       ((equal path containing) "pub(self)")
       ((equal path parent) "pub(super)")
       ((and (stringp path) (string-prefix-p "::" path))
        (format "pub(in crate%s)" path))
       (t "pub(self)"))))
   (t "pub(self)")))

(defun crate-tree--span (item)
  "Return (FILENAME LINE) of ITEM, or nil.
An impl item carries no span, and the members of that impl carry
one."
  (when-let* ((span (gethash "span" item))
              ((hash-table-p span))
              (filename (gethash "filename" span))
              (begin (gethash "begin" span))
              ((vectorp begin)))
    (list filename (aref begin 0))))

(defun crate-tree--doc-summary (docs)
  "Return the first sentence of DOCS on one line, or nil."
  (when (and (stringp docs)
             (not (string-empty-p (string-trim docs))))
    (let ((text (string-trim (string-replace "\n" " " docs))))
      (string-trim
       (or (when-let* ((dot (string-search ". " text)))
             (substring text 0 (1+ dot)))
           text)))))

(defun crate-tree--attrs (item)
  "Return the attributes of ITEM as strings."
  (let ((attrs (gethash "attrs" item)))
    (delq nil
          (mapcar (lambda (attr)
                    (cond ((stringp attr) attr)
                          ((hash-table-p attr) (gethash "other" attr))))
                  (crate-tree--ids attrs)))))

(defun crate-tree--deprecation (item)
  "Return the deprecation note of ITEM, or nil."
  (when-let* ((deprecation (gethash "deprecation" item))
              ((hash-table-p deprecation))
              (note (gethash "note" deprecation))
              ((not (eq note :null))))
    note))

(defun crate-tree--module-scope (path)
  "Return the rustdoc path of the module that PATH names.
PATH starts with the crate name, and rustdoc writes a scope as
`::api::net' with no crate name.  The crate root answers an empty
string."
  (if-let* ((rest (cdr path)))
      (concat "::" (mapconcat #'identity rest "::"))
    ""))

(defun crate-tree--field-ids (kind)
  "Return the field ids of a struct or union KIND object."
  (cond
   ((hash-table-p kind)
    (or (crate-tree--ids (gethash "tuple" kind))
        (let ((plain (gethash "plain" kind)))
          (and (hash-table-p plain)
               (crate-tree--ids (gethash "fields" plain))))
        (crate-tree--ids (gethash "fields" kind))))
   (t nil)))

(defun crate-tree--impl-entries (index inner)
  "Return (ID . TRAIT-IMPL-P) entries from INDEX for the impls of INNER.
A synthetic impl and a blanket impl drop, because rustdoc writes one
for every type and `cargo-modules' prints none of them.  A derived
impl drops too: rustdoc tags it with `automatically_derived', and its
`clone' or `fmt' method says nothing that the type does not.  A trait
impl that the crate writes itself stays: `cargo-modules' shows its
methods under the type."
  (let (entries)
    (dolist (impl-id (crate-tree--ids (gethash "impls" inner)))
      (when-let* ((impl-item (crate-tree--json-item index impl-id))
                  (impl (gethash "impl" (gethash "inner" impl-item)))
                  ((hash-table-p impl))
                  ((not (eq t (gethash "is_synthetic" impl))))
                  ((not (member "automatically_derived"
                                (crate-tree--attrs impl-item))))
                  (blanket (gethash "blanket_impl" impl))
                  ((or (null blanket) (eq blanket :null))))
        (let ((trait (gethash "trait" impl)))
          (dolist (child-id (crate-tree--ids (gethash "items" impl)))
            (push (cons child-id (and trait (not (eq trait :null)) t))
                  entries)))))
    (nreverse entries)))

(defun crate-tree--child-entries (index kind inner)
  "Return (ID . TRAIT-IMPL-P) entries for the children of an item.
INDEX holds the rustdoc item table.  KIND names the item kind and
INNER holds its rustdoc object, with the kind key already removed."
  (let ((direct
         (pcase kind
           ('module (crate-tree--ids (gethash "items" inner)))
           ('trait (crate-tree--ids (gethash "items" inner)))
           ('enum (crate-tree--ids (gethash "variants" inner)))
           ('struct (crate-tree--field-ids (gethash "kind" inner)))
           ('union (crate-tree--field-ids inner)))))
    (append (mapcar #'list direct)
            (when (memq kind '(struct union enum))
              (crate-tree--impl-entries index inner)))))

(defun crate-tree--items (json)
  "Return the root `crate-tree-item' of the rustdoc document JSON.
Answer nil when JSON is not a rustdoc document.  Signal a
`user-error' when the document names a format version that this
parser does not read."
  (when (hash-table-p json)
    (let ((version (gethash "format_version" json)))
      (when (and version
                 (not (and (integerp version)
                           (<= crate-tree--min-format version)
                           (<= version crate-tree--max-format))))
        (user-error "Rustdoc JSON format %s is not supported" version))
      (let ((index (gethash "index" json)))
        (when (hash-table-p index)
          (cl-labels
              ((walk (item path containing parent root-p trait-impl-p)
                 (let* ((inner-key (crate-tree--inner-key item))
                        (object (and inner-key
                                     (gethash inner-key (gethash "inner" item))))
                        (kind (and inner-key (crate-tree--kind inner-key)))
                        (name (or (let ((value (gethash "name" item)))
                                   (unless (eq value :null) value))
                                 ;; A `use' item carries its name in
                                 ;; its own object.
                                 (and (eq kind 'use)
                                      (hash-table-p object)
                                      (gethash "name" object))))
                        (child-containing
                         (if (eq kind 'module)
                             (crate-tree--module-scope path)
                           containing))
                        (child-parent
                         (if (eq kind 'module) containing parent)))
                   (crate-tree-item--create
                    :path (mapconcat #'identity path "::")
                    :name name
                    :kind kind
                    :kind-word (crate-tree--kind-word kind object root-p)
                    :vis-word (crate-tree--visibility-word
                               (gethash "visibility" item)
                               containing parent trait-impl-p)
                    :span (crate-tree--span item)
                    :docs (crate-tree--doc-summary (gethash "docs" item))
                    :attrs (crate-tree--attrs item)
                    :deprecation (crate-tree--deprecation item)
                    :children
                    (delq nil
                          (mapcar
                           (lambda (entry)
                             (when-let* ((child (crate-tree--json-item
                                                 index (car entry)))
                                         (child-name
                                          (or (let ((value (gethash "name" child)))
                                                (unless (eq value :null) value))
                                              (let ((inner (gethash "use"
                                                                    (gethash "inner" child))))
                                                (and (hash-table-p inner)
                                                     (gethash "name" inner))))))
                               (walk child (append path (list child-name))
                                     child-containing child-parent nil
                                     (cdr entry))))
                           (crate-tree--child-entries index kind object)))))))
            (when-let* ((root (crate-tree--json-item index (gethash "root" json)))
                        (root-name (gethash "name" root)))
              (walk root (list root-name) "" nil t nil))))))))

;;; Rows

(defconst crate-tree--default-kinds
  '(module struct union enum trait type-alias function)
  "Kinds that a tree shows before a filter command runs.
The set matches what `cargo-modules structure' prints.")

(defun crate-tree--sort-value (item key)
  "Return the value of ITEM that sort KEY compares."
  (pcase key
    ('kind (crate-tree-item-kind-word item))
    ('visibility (crate-tree-item-vis-word item))
    (_ (or (crate-tree-item-name item) ""))))

(defun crate-tree--sort-children (items state)
  "Return ITEMS in the sibling order that STATE asks for.
The source order stands unless STATE names another sort key.  A
reversed order reverses the whole list, not one key."
  (let ((key (plist-get state :sort))
        (reverse (plist-get state :reverse)))
    (if (or (null key) (eq key 'source))
        (let ((source (copy-sequence items)))
          (if reverse (nreverse source) source))
      (let ((sorted
             (sort (copy-sequence items)
                   (lambda (first second)
                     (let ((left (crate-tree--sort-value first key))
                           (right (crate-tree--sort-value second key)))
                       (if (equal left right)
                           (string< (or (crate-tree-item-name first) "")
                                    (or (crate-tree-item-name second) ""))
                         (string< left right)))))))
        (if reverse (nreverse sorted) sorted)))))

(defun crate-tree--focus-keep-p (item focus cache)
  "Return non-nil when ITEM or a descendant matches FOCUS.
CACHE memoizes the answer by item path, so one pass costs one match
per item."
  (let* ((path (crate-tree-item-path item))
         (cached (gethash path cache :unset)))
    (if (not (eq cached :unset))
        cached
      (let ((keep (or (string-match-p focus path)
                      (seq-some (lambda (child)
                                  (crate-tree--focus-keep-p child focus cache))
                                (crate-tree-item-children item)))))
        (puthash path keep cache)
        keep))))

(defun crate-tree--rows (root state)
  "Return ROOT flattened into the (ITEM . DEPTH) rows that STATE shows.
STATE is a plist.  `:folded' holds a hash set of folded paths, `:kinds'
holds a list of shown kinds, and `:public-only', `:focus',
`:max-depth', `:sort' and `:reverse' follow.  ROOT always shows, and
a folded item keeps its own row and drops its children."
  (declare (side-effect-free t))
  (let ((folded (plist-get state :folded))
        (kinds (if (plist-member state :kinds)
                   (plist-get state :kinds)
                 crate-tree--default-kinds))
        (public-only (plist-get state :public-only))
        (focus (plist-get state :focus))
        (max-depth (plist-get state :max-depth))
        (focus-cache (make-hash-table :test #'equal)))
    (cl-labels
        ((shown-p (item inside)
           (or inside
               (and (memq (crate-tree-item-kind item) kinds)
                    (or (not public-only)
                        (equal (crate-tree-item-vis-word item) "pub"))
                    (or (null focus)
                        (crate-tree--focus-keep-p item focus focus-cache)))))
         (walk (item depth inside)
           (when (or (= depth 0) (shown-p item inside))
             (let ((inside (or inside
                               (and focus
                                    (string-match-p
                                     focus (crate-tree-item-path item))))))
               (cons (cons item depth)
                     (when (and (not (and folded
                                          (gethash (crate-tree-item-path item)
                                                   folded)))
                                (or (null max-depth) (< depth max-depth)))
                       (mapcan (lambda (child) (walk child (1+ depth) inside))
                               (crate-tree--sort-children
                                (crate-tree-item-children item) state))))))))
      (walk root 0 nil))))

;;; The `cargo-modules structure' format

(defun crate-tree--structure-print-p (item)
  "Return non-nil when `cargo-modules structure' prints ITEM."
  (and (memq (crate-tree-item-kind item) crate-tree--structure-kinds)
       (crate-tree-item-name item)))

(defun crate-tree--structure-descend-p (item)
  "Return non-nil when `cargo-modules structure' prints the children of ITEM.
A trait prints no member, and a nested `use' prints nothing at all."
  (not (memq (crate-tree-item-kind item) '(trait use))))

(defun crate-tree--structure-sort (items)
  "Return ITEMS sorted by name, the `cargo-modules' order.
The sort is stable, so two items of one name keep source order."
  (sort (copy-sequence items)
        (lambda (first second)
          (string< (or (crate-tree-item-name first) "")
                   (or (crate-tree-item-name second) "")))))

(defun crate-tree--structure-children (item prefix)
  "Return the children of ITEM rendered below PREFIX."
  (if (not (crate-tree--structure-descend-p item))
      ""
    (let* ((children (crate-tree--structure-sort
                      (seq-filter #'crate-tree--structure-print-p
                                  (crate-tree-item-children item))))
           (last-index (1- (length children))))
      (cl-loop for child in children
               for index from 0
               concat (format "%s%s%s %s: %s\n"
                              prefix
                              (if (= index last-index) "└── " "├── ")
                              (crate-tree-item-kind-word child)
                              (crate-tree-item-name child)
                              (crate-tree-item-vis-word child))
               concat (crate-tree--structure-children
                       child
                       (concat prefix
                               (if (= index last-index) "    " "│   ")))))))

(defun crate-tree--structure-text (root)
  "Return ROOT rendered in the `cargo-modules structure' format."
  (when root
    (concat (format "crate %s\n" (crate-tree-item-name root))
            (crate-tree--structure-children root ""))))

;;; Faces

(defface crate-tree-kind
  '((t :inherit font-lock-keyword-face))
  "Face for the kind word of a tree row."
  :group 'crate)

(defface crate-tree-module-name
  '((t :inherit bold))
  "Face for the name of a module row."
  :group 'crate)

(defface crate-tree-visibility
  '((t :inherit font-lock-constant-face))
  "Face for the visibility word of a tree row."
  :group 'crate)

(defface crate-tree-location
  '((t :inherit line-number))
  "Face for the file and line of a tree row."
  :group 'crate)

(defface crate-tree-docs
  '((t :inherit shadow))
  "Face for the doc summary of a tree row."
  :group 'crate)

(defface crate-tree-fold-marker
  '((t :inherit shadow))
  "Face for the fold marker of a row that holds children."
  :group 'crate)

(defface crate-tree-count
  '((t :inherit shadow))
  "Face for the count of a folded row."
  :group 'crate)

;;; Mode

(defconst crate-tree--all-kinds
  '(module struct union enum trait type-alias function constant static
    macro use struct-field variant assoc-const assoc-type proc-macro)
  "Every item kind that the parser emits.
The kind filter offers this list, and `crate-tree--default-kinds'
names the subset that a fresh table shows.")

(defvar-local crate-tree--root nil
  "Root item of the tree that the buffer shows.")

(defvar-local crate-tree--name nil
  "Name of the crate that the buffer shows.")

(defvar-local crate-tree--directory nil
  "Directory of the crate source, or nil for a crate with no source.")

(defvar-local crate-tree--folded nil
  "Hash set of the item paths that are folded.")

(defvar-local crate-tree--kinds nil
  "Item kinds that the table shows.")

(defvar-local crate-tree--public-only nil
  "When non-nil, the table shows only items of public visibility.")

(defvar-local crate-tree--focus nil
  "Regexp that keeps the matching subtree, or nil for no focus.")

(defvar-local crate-tree--max-depth nil
  "Deepest row that the table shows, or nil for every depth.")

(defvar-local crate-tree--sort nil
  "Sort key of the sibling lists: `source', `name', `kind' or `visibility'.")

(defvar-local crate-tree--reverse nil
  "When non-nil, the table reverses each sibling list.")

(defvar-local crate-tree--rows nil
  "Rows of the last print, as (ITEM . DEPTH) conses.")

(defvar-local crate-tree--items nil
  "Hash table from an item path to the item of the last print.")

(defvar-local crate-tree--pending-row nil
  "Item path that the next print puts point on, or nil.
A bookmark jump sets it, because a build that still runs leaves no
row to move to at once.")

(defun crate-tree--bookmark-make-record ()
  "Return a bookmark record for the current tree buffer.
The record holds the source, the fold set, the filters, the depth,
the sort and the row at point, so a jump lands on the same view."
  (let ((label (if crate-tree--directory
                   (format "Crate tree: %s (%s)"
                           crate-tree--name crate-tree--directory)
                 (format "Crate tree: %s" crate-tree--name))))
    `(,label
      (handler . crate-tree-bookmark-jump)
      (crate . ,crate-tree--name)
      (directory . ,crate-tree--directory)
      (folds . ,(hash-table-keys crate-tree--folded))
      (kinds . ,crate-tree--kinds)
      (public . ,crate-tree--public-only)
      (focus . ,crate-tree--focus)
      (depth . ,crate-tree--max-depth)
      (sort . ,crate-tree--sort)
      (reverse . ,crate-tree--reverse)
      (row . ,(tabulated-list-get-id)))))

(defvar-keymap crate-tree-filter-map
  :doc "Filter keymap for `crate-tree-mode'."
  "p" #'crate-tree-toggle-public
  "k" #'crate-tree-kind-filter
  "f" #'crate-tree-focus
  "r" #'crate-tree-reset-filters)

(defvar-keymap crate-tree-mode-map
  :doc "Keymap for `crate-tree-mode'."
  :parent tabulated-list-mode-map
  "TAB" #'crate-tree-toggle
  "<double-mouse-1>" #'crate-tree-mouse-toggle
  "RET" #'crate-tree-visit
  "s" #'crate-tree-sort
  "S" #'crate-tree-reverse-sort
  "f" crate-tree-filter-map
  "y" #'crate-tree-copy-path
  "w" #'crate-tree-copy-dependency
  "C-c C-o" #'crate-tree-browse-url)

;; Depth keys: `1' shows the root alone, and `9' shows every depth.
(dotimes (number 10)
  (let ((depth number))
    (define-key crate-tree-mode-map (number-to-string depth)
      (lambda ()
        (interactive)
        (crate-tree-set-depth depth)))))

(define-derived-mode crate-tree-mode tabulated-list-mode "Crate-Tree"
  "Major mode for the item structure of one Rust crate.

\\{crate-tree-mode-map}
\\<crate-tree-mode-map>
\\[crate-tree-toggle] folds or unfolds a row, `1' to `9' set the
depth, \\[crate-tree-sort] cycles the sibling order, and the `f'
prefix filters the table.  \\[crate-tree-visit] opens the source of
a row of a local crate, \\[crate-tree-browse-url] opens its docs.rs
page, and \\[crate-tree-copy-path] copies its item path."
  :interactive nil
  (setq-local crate-tree--folded (make-hash-table :test #'equal))
  (setq-local crate-tree--kinds crate-tree--default-kinds)
  (setq-local crate-tree--sort 'source)
  (setq-local crate-tree--items (make-hash-table :test #'equal))
  (setq-local tabulated-list-entries nil)
  (setq-local tabulated-list-padding 0)
  (setq-local tabulated-list-sort-key nil)
  (setq-local tabulated-list-format (crate-tree--format nil))
  (setq-local tabulated-list-printer #'crate-tree--print-entry)
  (setq-local revert-buffer-function #'crate-tree--revert)
  (setq-local bookmark-make-record-function
              #'crate-tree--bookmark-make-record)
  (tabulated-list-init-header)
  (hl-line-mode 1))

;;; Commands

;;;###autoload
(defun crate-tree (name)
  "Show the item structure of the database crate NAME."
  (interactive (list (completing-read "Crate tree> " #'crate--collection)))
  (let ((record (crate--crate name)))
    (unless record
      (user-error "No crate `%s'" name))
    (crate-tree--open (or (gethash "name" record) name) nil)))

;;;###autoload
(defun crate-tree-directory (directory)
  "Show the item structure of the crate in DIRECTORY."
  (interactive (list (crate-local--read-directory)))
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (record (progn
                   (unless (file-exists-p (crate-local--manifest directory))
                     (user-error "No Cargo.toml in `%s'"
                                 (directory-file-name directory)))
                   (crate-local--record directory))))
    (unless record
      (user-error "Cannot read the crate metadata of `%s'"
                  (directory-file-name directory)))
    (crate-tree--open (gethash "name" record) directory)))

(defun crate-tree--open (name directory)
  "Show the tree of crate NAME, whose source sits in DIRECTORY.
A nil DIRECTORY names a database crate, which reads its document from
the Nix build.  A buffer that already holds the tree keeps its folds,
so a second call only displays it."
  (let ((buffer (if directory
                    (format "Crate Tree: %s (%s)"
                            name (directory-file-name directory))
                  (format "Crate Tree: %s" name))))
    (crate--display-buffer buffer)
    (unless (derived-mode-p 'crate-tree-mode)
      (crate-tree-mode)
      (setq-local crate-tree--name name)
      (setq-local crate-tree--directory
                  (and directory (directory-file-name directory)))
      (if directory
          (crate-tree--apply-json (crate-tree--json directory))
        (setq-local crate-doc--render-function
                    #'crate-tree--render-from-build)
        (crate-tree--apply-doc name)))
    (current-buffer)))

(defun crate-tree--render-from-build ()
  "Reprint the tree from a finished Nix rustdoc build."
  (crate-tree--apply-doc crate-tree--name))

(defun crate-tree-copy-dependency ()
  "Copy a Cargo.toml line for the crate of this table."
  (interactive)
  (let* ((data (if crate-tree--directory
                   (crate-local--record crate-tree--directory)
                 (crate--crate crate-tree--name)))
         (line (crate--dependency-line
                (or (and data (gethash "name" data)) crate-tree--name)
                (and data (gethash "latest_version" data)))))
    (kill-new line)
    (message "Copied: %s" line)))

;;; Local rustdoc builds

;; `cargo doc' type-checks the crate, so the build costs about the same
;; as `cargo check'.  It needs the dependencies of the crate, so the
;; command runs online and outside Nix: a local development crate
;; usually has its dependencies in the cargo cache already.

(defvar crate-tree--json-cache (make-hash-table :test #'equal)
  "Parsed rustdoc JSON keyed by (tree MANIFEST).
A :failed sentinel caches a build that cannot run, so a reprint never
retries it.  `crate-tree--refresh' drops the entry before a rebuild.")

(defvar crate-tree--in-flight (make-hash-table :test #'equal)
  "Running rustdoc builds keyed by crate manifest.")

(defvar crate-tree--reason (make-hash-table :test #'equal)
  "Reason that a crate has no rustdoc JSON, keyed like the JSON cache.
A reader without a row must learn what to fix, so every failed start
and every failed build stores its reason here.")

(defvar-local crate-tree--status nil
  "Rustdoc build status of this table buffer.
nil means that no build ran, `running' a build that still runs, and
a string the reason that the crate has no rustdoc JSON.")

(defun crate-tree--json-cache-key (directory)
  "Return the cache key of the crate in DIRECTORY."
  (list 'tree (crate-local--manifest directory)))

(defun crate-tree--lib-target (package)
  "Return the library target of the `cargo metadata' PACKAGE.
A package without a library target answers nil, and the tree mode
builds nothing for it."
  (when-let* ((targets (gethash "targets" package)))
    (seq-find (lambda (target)
                (seq-some (lambda (kind)
                            (member kind '("lib" "rlib" "dylib"
                                           "proc-macro")))
                          (crate-tree--ids (gethash "kind" target))))
              (append targets nil))))

(defun crate-tree--json-file (metadata manifest)
  "Return the rustdoc JSON path that METADATA names for MANIFEST."
  (when-let* ((package (crate-local--package metadata manifest))
              (target (crate-tree--lib-target package))
              (directory (gethash "target_directory" metadata))
              (name (gethash "name" target)))
    (expand-file-name (concat name ".json")
                      (expand-file-name "doc" directory))))

(defun crate-tree--read-json (file)
  "Return the parsed rustdoc JSON of FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (json-parse-buffer)
        (error nil)))))

(defun crate-tree--build-environment ()
  "Return the environment list of a rustdoc build.
Stable rustc writes JSON behind `-Z unstable-options', and
RUSTC_BOOTSTRAP lifts that gate."
  (append (list "RUSTC_BOOTSTRAP=1"
                "RUSTDOCFLAGS=-Zunstable-options --output-format json")
          (when-let* ((program crate-rustc-program)
                      (rustc (executable-find program)))
            (list (concat "RUSTC=" rustc)))))

(defun crate-tree--set-status (buffer status)
  "Set the rustdoc build status of BUFFER to STATUS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq crate-tree--status status))))

(defun crate-tree--no-cargo-reason ()
  "Return the reason that no cargo command answers."
  (declare (side-effect-free t))
  (if crate-cargo-program
      (format "cargo `%s' is not on `executable-find'" crate-cargo-program)
    "`crate-cargo-program' is nil"))

(defun crate-tree--build-failed (buffer key reason)
  "Mark BUFFER, the tree of KEY, with the REASON of a failed start.
The JSON cache holds `:failed' for KEY, so a reprint never retries
the build, and BUFFER names the reason in place of the rows."
  (puthash key :failed crate-tree--json-cache)
  (puthash key reason crate-tree--reason)
  (crate-tree--set-status buffer reason)
  nil)

(defun crate-tree--failure-line (out)
  "Return the last line of OUT, the buffer of a `cargo doc' run."
  (with-current-buffer out
    (goto-char (point-max))
    (let (line)
      (while (and (not line) (not (bobp)))
        (forward-line -1)
        (let ((text (string-trim (buffer-substring (point) (line-end-position)))))
          (when (not (string-empty-p text))
            (setq line text))))
      line)))

(defun crate-tree--finish-build (process out buffer key manifest json-file)
  "Record the result of the build that PROCESS ran.
OUT holds its output, BUFFER the tree, and KEY, MANIFEST and
JSON-FILE say where the cache entry, the build and the JSON live.
A failed build keeps OUT as `*crate-tree-build*' and names its last
line in BUFFER, in place of the rows."
  (let* ((exited (eq 0 (process-exit-status process)))
         (json (and exited (crate-tree--read-json json-file)))
         (reason (unless json
                   (if exited
                       "`cargo doc' wrote no rustdoc JSON"
                     (or (crate-tree--failure-line out)
                         "`cargo doc' exited with an error")))))
    (remhash manifest crate-tree--in-flight)
    (puthash key (or json :failed) crate-tree--json-cache)
    (if reason
        (puthash key reason crate-tree--reason)
      (remhash key crate-tree--reason))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'crate-tree-mode)
          (setq crate-tree--status reason)
          (crate-tree--apply-json (or json :failed))
          (when reason
            (message "crate-tree: %s" reason)))))
    (when (buffer-live-p out)
      (if reason
          (with-current-buffer out
            (rename-buffer "*crate-tree-build*" t))
        (kill-buffer out)))))

(defun crate-tree--start-local-build (directory buffer)
  "Document the crate in DIRECTORY, then reprint BUFFER.
Return non-nil when a build runs, nil when no cargo, no manifest or
no library target answers.  The failed start caches `:failed' and
its reason, so the table can name the fix."
  (let* ((manifest (crate-local--manifest directory))
         (key (crate-tree--json-cache-key directory))
         (program (and crate-cargo-program
                       (executable-find crate-cargo-program)))
         (metadata (and program (crate-local--metadata directory)))
         (json-file (and metadata (crate-tree--json-file metadata manifest))))
    (cond
     ((gethash manifest crate-tree--in-flight)
      (crate-tree--set-status buffer 'running)
      t)
     ((null program)
      (crate-tree--build-failed buffer key (crate-tree--no-cargo-reason)))
     ((null metadata)
      (crate-tree--build-failed
       buffer key "`cargo metadata' cannot read the manifest"))
     ((null json-file)
      (crate-tree--build-failed buffer key "the package has no library target"))
     (t
      (let ((out (generate-new-buffer " *crate-tree-build*"))
            (doc (file-name-nondirectory
                  (directory-file-name (file-name-directory manifest))))
            (environment (crate-tree--build-environment)))
        (condition-case nil
            (progn
              (let ((process-environment (append environment
                                                 process-environment))
                    ;; `make-process' runs the child in the
                    ;; `default-directory' of the current buffer.
                    (default-directory
                     (file-name-as-directory (expand-file-name directory))))
                (make-process
                 :name (format "crate-tree-build-%s" doc)
                 :buffer out
                 :command (list program "doc" "--lib" "--no-deps"
                                "--document-private-items")
                 :noquery t
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (crate-tree--finish-build process out buffer key
                                               manifest json-file)))))
              (puthash manifest t crate-tree--in-flight)
              (crate-tree--set-status buffer 'running)
              t)
          (error
           (when (buffer-live-p out)
             (kill-buffer out))
           (crate-tree--build-failed buffer key "the build cannot start"))))))))

(defun crate-tree--json (directory)
  "Return the rustdoc JSON of the crate in DIRECTORY, or nil.
A cache miss starts an asynchronous `cargo doc' for the buffer that
asks, and that buffer reprints when the build ends."
  (when-let* ((manifest (crate-local--manifest directory))
              ((file-exists-p manifest)))
    (let* ((key (crate-tree--json-cache-key directory))
           (cached (gethash key crate-tree--json-cache)))
      (cond
       ((eq cached :failed)
        (setq crate-tree--status (gethash key crate-tree--reason))
        nil)
       (cached cached)
       (t
        (crate-tree--start-local-build directory (current-buffer))
        nil)))))

(defun crate-tree--forget-local (directory)
  "Drop the cached JSON and the cached reason of the crate in DIRECTORY."
  (let ((key (crate-tree--json-cache-key directory)))
    (remhash key crate-tree--json-cache)
    (remhash key crate-tree--reason)))

(defun crate-tree--apply-json (json)
  "Store JSON as the tree of the buffer and print it.
A `:failed' sentinel or nil leaves the old tree and its status in
place, so the table keeps naming why it holds no row."
  (when (and json (not (eq json :failed)))
    (setq crate-tree--root (crate-tree--items json)
          crate-tree--status nil))
  (crate-tree--reprint))

(defun crate-tree--apply-doc (name)
  "Load the rustdoc JSON of the database crate NAME and print the table.
A nil answer leaves the build status in `crate-tree--status', so a
build that still runs or that cannot start shows in place of the
rows."
  (let ((json (crate-doc--json name)))
    (unless json
      (setq crate-tree--status (crate-doc--status-of name)))
    (crate-tree--apply-json json)))

(defun crate-tree--refresh (&rest _ignored)
  "Load the rustdoc JSON of the buffer source, then print it.
A local crate runs `cargo doc' again, and a database crate drops its
cached document first, so `g' retries a Nix build that could not
start."
  (interactive)
  (if crate-tree--directory
      (progn
        (crate-tree--forget-local crate-tree--directory)
        (crate-tree--apply-json
         (crate-tree--json crate-tree--directory)))
    (crate-doc--forget crate-tree--name)
    (crate-tree--apply-doc crate-tree--name))
  (when (null crate-tree--root)
    (message "crate-tree: %s" (crate-tree--status-message))))

;;; Cells

(defun crate-tree--state ()
  "Return the row state of the current buffer."
  (list :folded crate-tree--folded
        :kinds crate-tree--kinds
        :public-only crate-tree--public-only
        :focus crate-tree--focus
        :max-depth crate-tree--max-depth
        :sort crate-tree--sort
        :reverse crate-tree--reverse))

(defun crate-tree--text-width (text)
  "Return the display width of TEXT."
  (string-width (substring-no-properties (or text ""))))

(defun crate-tree--folded-p (item)
  "Return non-nil when ITEM is folded."
  (and crate-tree--folded (gethash (crate-tree-item-path item)
                                   crate-tree--folded)))

(defun crate-tree--kind-cell (item)
  "Return the kind cell of ITEM."
  (propertize (crate-tree-item-kind-word item) 'face 'crate-tree-kind))

(defun crate-tree--name-cell (item depth)
  "Return the name cell of ITEM at DEPTH."
  (let* ((children (length (crate-tree-item-children item)))
         (folded (crate-tree--folded-p item))
         (glyph (cond ((zerop children) "  ")
                      (folded (propertize "▸ " 'face 'crate-tree-fold-marker))
                      (t (propertize "▾ " 'face 'crate-tree-fold-marker)))))
    (concat (make-string (* 2 depth) ?\s)
            (when (and children folded)
              (propertize glyph
                          'keymap (let ((map (make-sparse-keymap)))
                                    (define-key map [mouse-1]
                                                #'crate-tree-mouse-toggle)
                                    map)
                          'mouse-face 'highlight
                          'help-echo "mouse-1: unfold"))
            (unless (and children folded) glyph)
            (propertize (or (crate-tree-item-name item) "")
                        'face (if (eq (crate-tree-item-kind item) 'module)
                                  'crate-tree-module-name
                                'default))
            (if (and children folded)
                (propertize (format " (%d)" children)
                            'face 'crate-tree-count)
              ""))))

(defun crate-tree--visibility-cell (item)
  "Return the visibility cell of ITEM."
  (propertize (crate-tree-item-vis-word item)
              'face 'crate-tree-visibility))

(defun crate-tree--location-cell (item)
  "Return the location cell of ITEM."
  (if-let* ((span (crate-tree-item-span item)))
      (propertize (format "%s:%s"
                          (file-name-nondirectory (car span))
                          (cadr span))
                  'face 'crate-tree-location)
    ""))

(defun crate-tree--docs-cell (item)
  "Return the doc summary cell of ITEM."
  (propertize (or (crate-tree-item-docs item) "")
              'face 'crate-tree-docs))

(defun crate-tree--entry (row)
  "Return the `tabulated-list' entry for ROW."
  (let ((item (car row))
        (depth (cdr row)))
    (list (crate-tree-item-path item)
          (vector (crate-tree--kind-cell item)
                  (crate-tree--name-cell item depth)
                  (crate-tree--visibility-cell item)
                  (crate-tree--location-cell item)
                  (crate-tree--docs-cell item)))))

(defun crate-tree--print-entry (id columns)
  "Print one table row for ID and COLUMNS, then add its help text."
  (let ((beg (point)))
    (tabulated-list-print-entry id columns)
    (when-let* ((item (and id (gethash id crate-tree--items))))
      (add-text-properties
       beg (1- (point))
       (list 'help-echo
             (concat (crate-tree-item-path item)
                     (if-let* ((docs (crate-tree-item-docs item)))
                         (concat "\n" docs)
                       "")))))))

;;; Column widths

(defun crate-tree--column-width (rows function minimum)
  "Return the width of a column of ROWS, computed by FUNCTION.
MINIMUM wins over a shorter content."
  (let ((width minimum))
    (dolist (row rows)
      (setq width (max width
                       (crate-tree--text-width (funcall function row)))))
    width))

(defun crate-tree--name-column-width (rows)
  "Return the width of the name column for ROWS."
  (crate-tree--column-width
   rows (lambda (row) (crate-tree--name-cell (car row) (cdr row))) 20))

(defun crate-tree--window-width ()
  "Return the width of the window that shows the table."
  (window-width (or (get-buffer-window (current-buffer))
                    (selected-window))))

(defun crate-tree--format (rows)
  "Return `tabulated-list-format' for ROWS.
The Kind, Vis and Location columns size to their content, the Name
column takes the longest visible name within the window, and the
Docs column takes the rest."
  (let* ((kind (crate-tree--column-width
                rows (lambda (row) (crate-tree--kind-cell (car row))) 8))
         (vis (crate-tree--column-width
               rows (lambda (row) (crate-tree--visibility-cell (car row))) 3))
         (location (min 24 (crate-tree--column-width
                            rows (lambda (row)
                                   (crate-tree--location-cell (car row)))
                            7)))
         (fixed (+ kind vis location 4))
         (name (max 20
                    (min (crate-tree--name-column-width rows)
                         (- (crate-tree--window-width) fixed)))))
    (vector (list "Kind" kind nil)
            (list "Name" name nil)
            (list "Vis" vis nil)
            (list "Location" location nil)
            (list "Docs" 0 nil))))

;;; Rendering

(defun crate-tree--fill-items (rows)
  "Store the items of ROWS in `crate-tree--items'."
  (setq crate-tree--items (make-hash-table :test #'equal))
  (dolist (row rows)
    (puthash (crate-tree-item-path (car row)) (car row)
             crate-tree--items)))

(defun crate-tree--goto-path (path)
  "Move point to the row of PATH, and answer non-nil when it exists."
  (let ((index (seq-position (mapcar #'car tabulated-list-entries)
                             path #'equal)))
    (when index
      (goto-char (point-min))
      (forward-line index)
      (beginning-of-line)
      t)))

(defun crate-tree--status-message ()
  "Return the line that a table without rows shows."
  (declare (side-effect-free t))
  (cond
   ((eq crate-tree--status 'running)
    "Rustdoc build in progress…")
   ((stringp crate-tree--status)
    (concat "No rustdoc JSON: " crate-tree--status))
   (t "No rustdoc JSON yet.")))

(defun crate-tree--reprint ()
  "Print the table from the state of the current buffer."
  (let* ((rows (if crate-tree--root
                   (crate-tree--rows crate-tree--root (crate-tree--state))))
         (entries (mapcar #'crate-tree--entry rows)))
    (setq-local crate-tree--rows rows)
    (crate-tree--fill-items rows)
    (setq-local tabulated-list-format (crate-tree--format rows))
    (tabulated-list-init-header)
    (setq-local tabulated-list-entries entries)
    (tabulated-list-print t)
    (when crate-tree--pending-row
      (when (crate-tree--goto-path crate-tree--pending-row)
        (setq crate-tree--pending-row nil)))
    (when (null rows)
      (let ((inhibit-read-only t))
        (insert (propertize (crate-tree--status-message) 'face 'shadow) "\n")))))

(defun crate-tree--revert (&rest _ignored)
  "Rebuild the rustdoc JSON of the buffer source, then reprint."
  (crate-tree--refresh))

;;; Bookmarks

(defun crate-tree--bookmark-prop-set-p (record property)
  "Return non-nil when RECORD carries PROPERTY.
`bookmark-prop-get' answers nil for an absent key and for a saved
nil alike, so a key that holds a list needs this test."
  (assq property (cdr record)))

(defun crate-tree--restore-bookmark (record)
  "Apply the view of RECORD to the current tree buffer.
A fold path that the rebuilt tree no longer holds stays in the set
and hides nothing, so a stale record still opens."
  (when (crate-tree--bookmark-prop-set-p record 'folds)
    (setq crate-tree--folded (make-hash-table :test #'equal))
    (dolist (path (bookmark-prop-get record 'folds))
      (when (stringp path)
        (puthash path t crate-tree--folded))))
  (when (crate-tree--bookmark-prop-set-p record 'kinds)
    (setq crate-tree--kinds (bookmark-prop-get record 'kinds)))
  (setq crate-tree--public-only (and (bookmark-prop-get record 'public) t))
  (setq crate-tree--focus (bookmark-prop-get record 'focus))
  (when (crate-tree--bookmark-prop-set-p record 'depth)
    (setq crate-tree--max-depth (bookmark-prop-get record 'depth)))
  (when (crate-tree--bookmark-prop-set-p record 'sort)
    (setq crate-tree--sort (bookmark-prop-get record 'sort)))
  (setq crate-tree--reverse (and (bookmark-prop-get record 'reverse) t))
  (setq crate-tree--pending-row
        (bookmark-prop-get record 'row))
  (crate-tree--reprint))

(defun crate-tree-bookmark-jump (record)
  "Restore a crate tree bookmark RECORD.
A record that names a directory reopens that checkout, and a record
without one reopens the database crate."
  (interactive (list (read-from-minibuffer "Bookmark: ")))
  (let ((name (bookmark-prop-get record 'crate))
        (directory (bookmark-prop-get record 'directory)))
    (when (and directory
               (not (file-exists-p (crate-local--manifest directory))))
      (user-error "No crate in `%s'" directory))
    (crate-tree--open name directory)
    (crate-tree--restore-bookmark record)))
(put 'crate-tree-bookmark-jump 'bookmark-handler-type "Crate tree")

;;; Row commands

(defun crate-tree--item-at-point ()
  "Return the item of the row at point, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (gethash id crate-tree--items)))

(defun crate-tree--row-item ()
  "Return the item of the row at point, or signal a `user-error'."
  (or (crate-tree--item-at-point)
      (user-error "No item at point")))

(defun crate-tree--set-folded (item folded)
  "Store ITEM as folded or unfolded according to FOLDED, then reprint."
  (let ((path (crate-tree-item-path item)))
    (if folded
        (puthash path t crate-tree--folded)
      (remhash path crate-tree--folded))
    (crate-tree--reprint)))

(defun crate-tree-fold ()
  "Fold the row at point."
  (interactive)
  (let ((item (crate-tree--row-item)))
    (unless (crate-tree-item-children item)
      (user-error "%s has no children" (crate-tree-item-name item)))
    (crate-tree--set-folded item t)))

(defun crate-tree-unfold ()
  "Unfold the row at point."
  (interactive)
  (let ((item (crate-tree--row-item)))
    (unless (crate-tree-item-children item)
      (user-error "%s has no children" (crate-tree-item-name item)))
    (crate-tree--set-folded item nil)))

(defun crate-tree-toggle ()
  "Fold or unfold the row at point."
  (interactive)
  (let ((item (crate-tree--row-item)))
    (unless (crate-tree-item-children item)
      (user-error "%s has no children" (crate-tree-item-name item)))
    (crate-tree--set-folded item (not (crate-tree--folded-p item)))))

(defun crate-tree-mouse-toggle (event)
  "Fold or unfold the row that EVENT names."
  (interactive "e")
  (mouse-set-point event)
  (crate-tree-toggle))

(defun crate-tree-set-depth (depth)
  "Show every row below DEPTH.
DEPTH 1 shows the crate row alone, and DEPTH 9 shows everything."
  (interactive "nDepth: ")
  (setq-local crate-tree--max-depth
              (if (or (null depth) (>= depth 9)) nil (1- depth)))
  (crate-tree--reprint))

(defun crate-tree-sort ()
  "Sort the sibling lists by the next key."
  (interactive)
  (setq-local crate-tree--sort
              (pcase crate-tree--sort
                ('source 'name)
                ('name 'kind)
                ('kind 'visibility)
                (_ 'source)))
  (crate-tree--reprint)
  (message "Sorted by %s" crate-tree--sort))

(defun crate-tree-reverse-sort ()
  "Reverse the sibling lists."
  (interactive)
  (setq-local crate-tree--reverse (not crate-tree--reverse))
  (crate-tree--reprint)
  (message "Sibling order %s" (if crate-tree--reverse "reversed" "forward")))

(defun crate-tree-toggle-public ()
  "Show only public items, or every item."
  (interactive)
  (setq-local crate-tree--public-only (not crate-tree--public-only))
  (crate-tree--reprint)
  (message "Public items %s"
           (if crate-tree--public-only "only" "and private items")))

(defun crate-tree-kind-filter (kinds)
  "Show only the item KINDS that the user names.
KINDS is a list of kind symbols.  An empty list shows the crate row
alone."
  (interactive
   (list (mapcar #'intern
                 (completing-read-multiple
                  "Kinds (empty for none): "
                  (mapcar #'symbol-name crate-tree--all-kinds) nil t
                  (mapconcat #'symbol-name crate-tree--kinds ",")))))
  (setq-local crate-tree--kinds kinds)
  (crate-tree--reprint))

(defun crate-tree-focus (regexp)
  "Keep the subtree that REGEXP matches, or every row for an empty REGEXP."
  (interactive (list (read-string "Focus on item path (empty for all): ")))
  (setq-local crate-tree--focus
              (let ((trimmed (string-trim regexp)))
                (unless (string-empty-p trimmed) trimmed)))
  (crate-tree--reprint))

(defun crate-tree-reset-filters ()
  "Drop every filter and sort of the table."
  (interactive)
  (setq-local crate-tree--kinds crate-tree--default-kinds)
  (setq-local crate-tree--public-only nil)
  (setq-local crate-tree--focus nil)
  (setq-local crate-tree--max-depth nil)
  (setq-local crate-tree--sort 'source)
  (setq-local crate-tree--reverse nil)
  (crate-tree--reprint))

(defun crate-tree-copy-path ()
  "Copy the item path of the row at point."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path
      (user-error "No item at point"))
    (kill-new path)
    (message "Copied %s" path)))

(defun crate-tree--docs-url (path)
  "Return the docs.rs URL of item PATH."
  (when crate-tree--name
    (let ((item (string-remove-prefix (concat crate-tree--name "::") path)))
      (format "https://docs.rs/%s/latest/%s/%s"
              crate-tree--name crate-tree--name
              (string-replace "::" "/" item)))))

(defun crate-tree-browse-url ()
  "Open the docs.rs page of the row at point."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path
      (user-error "No item at point"))
    (browse-url (crate-tree--docs-url path))))

(defun crate-tree--source-bases (directory)
  "Return the base directories that a span may be relative to for DIRECTORY.
The crate directory comes first, then its ancestors that hold a
`Cargo.toml', so a member of a workspace answers both its own
spans and the spans that rustdoc writes against the root."
  (declare (side-effect-free t))
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (bases (list directory))
         (parent (file-name-directory (directory-file-name directory))))
    (while (and parent
                (not (equal parent
                            (file-name-directory
                             (directory-file-name parent)))))
      (when (file-exists-p (expand-file-name "Cargo.toml" parent))
        (setq bases (append bases (list parent))))
      (setq parent (file-name-directory (directory-file-name parent))))
    bases))

(defun crate-tree--source-file (directory file)
  "Return the source file of DIRECTORY that FILE names.
Rustdoc writes a filename relative to the package, or to the
workspace root of one member, so the first base that holds the
file answers."
  (declare (side-effect-free t))
  (let ((bases (crate-tree--source-bases directory)))
    (or (seq-find #'file-exists-p
                  (mapcar (lambda (base) (expand-file-name file base))
                          bases))
        (expand-file-name file (car bases)))))

(defun crate-tree-visit ()
  "Open the source of the row at point.
A crate that came from the database carries no source on disk, so
this command signals a `user-error' there."
  (interactive)
  (let ((item (crate-tree--item-at-point)))
    (unless item
      (user-error "No item at point"))
    (unless crate-tree--directory
      (user-error "No source for this crate"))
    (let ((span (crate-tree-item-span item)))
      (unless span
        (user-error "%s carries no span" (crate-tree-item-name item)))
      (find-file (crate-tree--source-file crate-tree--directory (car span)))
      (goto-char (point-min))
      (forward-line (1- (cadr span))))))

(provide 'crate-tree)

;;; crate-tree.el ends here
