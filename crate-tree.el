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
(require 'crate)

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
for every type and `cargo-modules' prints none of them.  A trait
impl that the crate writes itself stays: `cargo-modules' shows its
methods under the type."
  (let (entries)
    (dolist (impl-id (crate-tree--ids (gethash "impls" inner)))
      (when-let* ((impl-item (crate-tree--json-item index impl-id))
                  (impl (gethash "impl" (gethash "inner" impl-item)))
                  ((hash-table-p impl))
                  ((not (eq t (gethash "is_synthetic" impl))))
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
  (let ((key (plist-get state :sort)))
    (if (or (null key) (eq key 'source))
        (copy-sequence items)
      (let ((sorted
             (sort (copy-sequence items)
                   (lambda (first second)
                     (let ((left (crate-tree--sort-value first key))
                           (right (crate-tree--sort-value second key)))
                       (if (equal left right)
                           (string< (or (crate-tree-item-name first) "")
                                    (or (crate-tree-item-name second) ""))
                         (string< left right)))))))
        (if (plist-get state :reverse) (nreverse sorted) sorted)))))

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

(provide 'crate-tree)

;;; crate-tree.el ends here
