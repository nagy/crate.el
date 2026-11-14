;;; crate-tree-test.el --- Tests for crate-tree -*- lexical-binding: t -*-

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

;; To run these tests:
;;
;;   emacs --batch -L . -L test -l test/crate-tree-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'crate-tree)
(require 'ert)
(require 'cl-lib)
(require 'crate-test-helper)

;;; Fixtures

(defconst crate-tree-test--json-path "@testHarnessJson@"
  "Path to the rustdoc JSON of the fixture crate.
`nix/default.nix' substitutes the store path of `nix/harness-doc.nix'.")

(defvar crate-tree-test--json nil
  "Parsed fixture document, read once per session.")

(defun crate-tree-test--json ()
  "Return the parsed fixture document, or nil when it is absent."
  (when (and (not (string-prefix-p "@" crate-tree-test--json-path))
             (file-readable-p crate-tree-test--json-path))
    (or crate-tree-test--json
        (setq crate-tree-test--json
              (with-temp-buffer
                (insert-file-contents crate-tree-test--json-path)
                (goto-char (point-min))
                (json-parse-buffer))))))

(defvar crate-tree-test--tree nil
  "Parsed fixture tree, built once per session.")

(defun crate-tree-test--root ()
  "Return the fixture tree root, or nil when the document is absent."
  (when-let* ((json (crate-tree-test--json)))
    (or crate-tree-test--tree
        (setq crate-tree-test--tree (crate-tree--items json)))))

(defmacro crate-tree-test--with-root (&rest body)
  "Run BODY with `root' bound to the fixture tree.
Skip when no rustdoc JSON is present, which a plain shell run hits."
  (declare (indent 0) (debug t))
  `(let ((root (crate-tree-test--root)))
     (unless root
       (ert-skip "Fixture rustdoc JSON is absent"))
     ,@body))

(defun crate-tree-test--walk (item function)
  "Call the tree under ITEM through FUNCTION, ITEM included."
  (funcall function item)
  (mapc (lambda (child) (crate-tree-test--walk child function))
        (crate-tree-item-children item)))

(defun crate-tree-test--item (name)
  "Return the first item of the fixture tree named NAME."
  (let (found)
    (when-let* ((root (crate-tree-test--root)))
      (crate-tree-test--walk root
                             (lambda (item)
                               (when (and (not found)
                                          (equal (crate-tree-item-name item) name))
                                 (setq found item)))))
    found))

(defun crate-tree-test--children-names (item)
  "Return the names of the children of ITEM, in order."
  (mapcar #'crate-tree-item-name (crate-tree-item-children item)))

(defun crate-tree-test--suite-directory ()
  "Return the directory that holds this suite."
  (file-name-directory
   (or load-file-name
       (locate-library "crate-tree-test")
       default-directory)))

(defun crate-tree-test--fixture-file (name)
  "Return the path of the fixture file NAME beside the suite."
  (expand-file-name name (crate-tree-test--suite-directory)))

;;; Items

(ert-deftest crate-tree-items-root ()
  "The parser answers the crate root of the fixture."
  (crate-tree-test--with-root
    (should (equal (crate-tree-item-name root) "harness"))
    (should (eq (crate-tree-item-kind root) 'module))
    (should (equal (crate-tree-item-kind-word root) "crate"))
    (should (equal (crate-tree-item-path root) "harness"))
    (should (equal (crate-tree-item-vis-word root) "pub"))))

(ert-deftest crate-tree-items-kind-words ()
  "Each item kind reads as the word that `cargo-modules' prints."
  (crate-tree-test--with-root
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "fetch"))
                   "async fn"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "fixed"))
                   "const fn"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "risky"))
                   "unsafe fn"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "Greet"))
                   "unsafe trait"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "Alias"))
                   "type"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "LIMIT"))
                   "const"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "NAME"))
                   "static"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "make_half"))
                   "macro"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "Red"))
                   "variant"))
    (should (equal (crate-tree-item-kind-word (crate-tree-test--item "left"))
                   "field"))))

(ert-deftest crate-tree-items-visibility ()
  "Rustdoc visibility maps onto the words that `cargo-modules' prints."
  (crate-tree-test--with-root
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "Half"))
                   "pub(crate)"))
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "secret"))
                   "pub(crate)"))
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "hello"))
                   "pub(crate)"))
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "root_public"))
                   "pub"))
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "root_private"))
                   "pub(crate)"))
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "handshake"))
                   "pub(self)"))
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "inner"))
                   "pub(self)"))
    (should (equal (crate-tree-item-vis-word (crate-tree-test--item "deep"))
                   "pub"))))

(ert-deftest crate-tree-items-impl-members ()
  "Inherent and written trait impls attach to their type in source order."
  (let ((half (crate-tree-test--item "Half")))
    (should (equal (crate-tree-test--children-names half)
                   '("left" "right" "new" "secret" "fetch" "fixed" "risky"
                     "generic" "hello")))))

(ert-deftest crate-tree-items-drops-derived-impls ()
  "Synthetic and blanket impls add no row."
  (crate-tree-test--with-root
    (dolist (name '("borrow" "borrow_mut" "into" "from" "try_from"
                    "try_into" "type_id"))
      (should-not (crate-tree-test--item name)))))

(ert-deftest crate-tree-items-spans ()
  "An item carries its file and line, and an impl carries none."
  (crate-tree-test--with-root
    (let ((span (crate-tree-item-span (crate-tree-test--item "fetch"))))
      (should (equal (car span) "src/lib.rs"))
      (should (integerp (cadr span))))
    (let ((span (crate-tree-item-span (crate-tree-test--item "connect"))))
      (should (equal (car span) "src/api/net.rs")))
    (should (equal (car (crate-tree-item-span
                         (crate-tree-test--item "Request")))
                   "src/api.rs"))))

(ert-deftest crate-tree-items-docs ()
  "The parser keeps the first sentence of the doc comment."
  (crate-tree-test--with-root
    (should (equal (crate-tree-item-docs root)
                   "Harness crate for the crate.el tree tests."))
    (should (equal (crate-tree-item-docs (crate-tree-test--item "net"))
                   "Networking."))
    (should (equal (crate-tree-item-docs (crate-tree-test--item "Red"))
                   "The red variant."))
    (should-not (crate-tree-item-docs (crate-tree-test--item "Half")))))

(ert-deftest crate-tree-items-attributes ()
  "Attributes and deprecation stay on the item that carries them."
  (crate-tree-test--with-root
    (should (member "macro_export"
                    (crate-tree-item-attrs (crate-tree-test--item "make_half"))))
    (should (equal (crate-tree-item-deprecation (crate-tree-test--item "Color"))
                   "use Color instead"))
    (should-not (crate-tree-item-deprecation (crate-tree-test--item "Half")))))

(ert-deftest crate-tree-items-source-order ()
  "Module children keep declaration order, not name order."
  (crate-tree-test--with-root
    (should (equal (crate-tree-test--children-names root)
                   '("api" "hidden" "money" "Request" "root_public"
                     "root_private" "Half" "LIMIT" "NAME" "Alias" "Greet"
                     "Color" "make_half")))))

(ert-deftest crate-tree-items-unknown-format ()
  "An unknown rustdoc format version refuses to parse."
  (let ((json (make-hash-table :test #'equal)))
    (puthash "format_version" 1 json)
    (should-error (crate-tree--items json) :type 'user-error)))

(ert-deftest crate-tree-items-no-document ()
  "A value that holds no rustdoc document answers nil."
  (should-not (crate-tree--items nil))
  (should-not (crate-tree--items (make-hash-table :test #'equal))))

;;; Rows

(defun crate-tree-test--row-names (state)
  "Return the names of the rows that STATE shows."
  (mapcar (lambda (row) (crate-tree-item-name (car row)))
          (crate-tree--rows (crate-tree-test--root) state)))

(defun crate-tree-test--folded (&rest paths)
  "Return a fold set that holds PATHS."
  (let ((folded (make-hash-table :test #'equal)))
    (dolist (path paths)
      (puthash path t folded))
    folded))

(ert-deftest crate-tree-rows-default-order ()
  "The default state shows every kind of the cargo-modules set, in source order."
  (crate-tree-test--with-root
    (let ((rows (crate-tree--rows root nil)))
      (should (equal (mapcar (lambda (row) (crate-tree-item-name (car row)))
                             (seq-take rows 5))
                     '("harness" "api" "net" "connect" "handshake")))
      (should (equal (mapcar #'cdr (seq-take rows 3)) '(0 1 2)))
      (should (equal (crate-tree-item-name (car (car (last rows)))) "name")))))

(ert-deftest crate-tree-rows-default-kinds-drop-extra-kinds ()
  "Fields, variants, consts, statics, macros and uses stay hidden by default."
  (crate-tree-test--with-root
    (let ((names (crate-tree-test--row-names nil)))
      (dolist (name '("left" "Red" "LIMIT" "NAME" "make_half"))
        (should-not (member name names))))))

(ert-deftest crate-tree-rows-kind-filter ()
  "The kind list gates a whole subtree, and the root never drops."
  (crate-tree-test--with-root
    (let ((names (crate-tree-test--row-names '(:kinds (module)))))
      (should (equal names '("harness" "api" "net" "parse" "hidden"
                             "inner" "money" "currency"))))
    (should (equal (crate-tree-test--row-names '(:kinds ())) '("harness")))))

(ert-deftest crate-tree-rows-extra-kinds ()
  "A kind list that names a field shows the field and its parent."
  (crate-tree-test--with-root
    (let ((names (crate-tree-test--row-names
                  '(:kinds (module struct struct-field function)))))
      (should (member "left" names))
      (should (member "right" names))
      (should (member "Half" names))
      (should-not (member "Red" names)))))

(ert-deftest crate-tree-rows-fold ()
  "A folded item keeps its row and hides every descendant."
  (crate-tree-test--with-root
    (let ((names (crate-tree-test--row-names
                  (list :folded (crate-tree-test--folded "harness::api")))))
      (should (member "api" names))
      (should-not (member "net" names))
      (should-not (member "connect" names))
      (should (member "hidden" names)))))

(ert-deftest crate-tree-rows-fold-keeps-depth ()
  "A fold leaves the depth of the rows around it alone."
  (crate-tree-test--with-root
    (let* ((state (list :folded (crate-tree-test--folded "harness::api")))
           (rows (crate-tree--rows root state))
           (hidden (seq-find (lambda (row)
                               (equal (crate-tree-item-name (car row))
                                      "hidden"))
                             rows)))
      (should (equal (cdr hidden) 1)))))

(ert-deftest crate-tree-rows-public-only ()
  "The public filter drops a non-public item and its subtree."
  (crate-tree-test--with-root
    (let ((names (crate-tree-test--row-names '(:public-only t))))
      (should (member "connect" names))
      (should-not (member "handshake" names))
      (should-not (member "root_private" names))
      (should-not (member "hidden" names))
      ;; `hidden_public' is reachable from nowhere, because its module
      ;; is not public, so the filter drops it with its module.
      (should-not (member "hidden_public" names)))))

(ert-deftest crate-tree-rows-max-depth ()
  "The depth limit cuts every row below it."
  (crate-tree-test--with-root
    (let ((rows (crate-tree--rows root '(:max-depth 1))))
      (should (seq-every-p (lambda (row) (<= (cdr row) 1)) rows))
      (should (= (length rows) 10)))))

(ert-deftest crate-tree-rows-focus ()
  "The focus keeps the matching subtree and the ancestors of the match."
  (crate-tree-test--with-root
    (should (equal (crate-tree-test--row-names '(:focus "net"))
                   '("harness" "api" "net" "connect" "handshake"
                     "Socket" "open")))))

(ert-deftest crate-tree-rows-sort-name ()
  "A name sort orders every sibling list, parents first."
  (crate-tree-test--with-root
    (let ((names (crate-tree-test--row-names '(:sort name))))
      (should (equal (seq-take names 3) '("harness" "Alias" "Color")))
      (should (equal (seq-drop names (- (length names) 2))
                     '("root_private" "root_public"))))))

(ert-deftest crate-tree-rows-sort-reverse ()
  "A reversed sort reverses the whole list."
  (crate-tree-test--with-root
    (let ((names (crate-tree-test--row-names '(:sort name :reverse t))))
      (should (equal (seq-take names 3) '("harness" "root_public"
                                          "root_private"))))))


;;; Mode

(defmacro crate-tree-test--with-buffer (&rest body)
  "Run BODY in a `crate-tree-mode' buffer of the fixture crate."
  (declare (indent 0) (debug t))
  `(let ((root (crate-tree-test--root)))
     (unless root
       (ert-skip "Fixture rustdoc JSON is absent"))
     (with-temp-buffer
       (crate-tree-mode)
       (setq-local crate-tree--root root)
       (setq-local crate-tree--name "harness")
       (crate-tree--reprint)
       ,@body)))

(defun crate-tree-test--row-ids ()
  "Return the ids of the printed rows, in print order."
  (mapcar #'car tabulated-list-entries))

(defun crate-tree-test--goto (path)
  "Move point to the row of PATH."
  (let ((line 1)
        (found nil))
    (dolist (entry tabulated-list-entries)
      (when (and (not found) (equal (car entry) path))
        (setq found t))
      (unless found
        (setq line (1+ line))))
    (unless found
      (error "No row for %s" path))
    (goto-char (point-min))
    (forward-line (1- line))))

(ert-deftest crate-tree-mode-header ()
  "The header names the crate and the row count."
  (crate-tree-test--with-buffer
    (should (string-match-p "harness" header-line-format))
    (should (string-match-p "rows" header-line-format))))

(ert-deftest crate-tree-mode-entries ()
  "One entry per row, keyed by item path."
  (crate-tree-test--with-buffer
    (should (equal (crate-tree-test--row-ids)
                   (mapcar (lambda (row)
                             (crate-tree-item-path (car row)))
                           (crate-tree--rows root nil))))
    (should (equal (car (crate-tree-test--row-ids)) "harness"))))

(ert-deftest crate-tree-mode-columns ()
  "A printed row carries the five cells."
  (crate-tree-test--with-buffer
    (goto-char (point-min))
    (forward-line 1)
    (should (looking-at-p "[[:space:]]*mod[[:space:]]+▾ api"))
    (let ((line (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))))
      (should (string-match-p "pub" line))
      (should (string-match-p "api.rs:1" line))
      (should (string-match-p "Request handling." line)))))

(ert-deftest crate-tree-mode-toggle-folds ()
  "`TAB' hides the children of the row at point."
  (crate-tree-test--with-buffer
    (crate-tree-test--goto "harness::api")
    (crate-tree-toggle)
    (let ((ids (crate-tree-test--row-ids)))
      (should (member "harness::api" ids))
      (should-not (member "harness::api::net" ids)))
    (should (string-match-p "(3)" (buffer-substring-no-properties
                                   (point-min) (point-max))))))

(ert-deftest crate-tree-mode-toggle-unfolds ()
  "A second `TAB' shows the children again."
  (crate-tree-test--with-buffer
    (crate-tree-test--goto "harness::api")
    (crate-tree-toggle)
    (crate-tree-test--goto "harness::api")
    (crate-tree-toggle)
    (should (member "harness::api::net" (crate-tree-test--row-ids)))))

(ert-deftest crate-tree-mode-reprint-keeps-point ()
  "A reprint that hides rows above point leaves point on its row."
  (crate-tree-test--with-buffer
    (crate-tree-test--goto "harness::Half")
    (let ((id (tabulated-list-get-id)))
      (puthash "harness::api" t crate-tree--folded)
      (crate-tree--reprint)
      (should (equal (tabulated-list-get-id) id)))))

(ert-deftest crate-tree-mode-depth ()
  "The depth keys cut the rows below the depth."
  (crate-tree-test--with-buffer
    (crate-tree-set-depth 2)
    (should (= (length tabulated-list-entries) 10))
    (crate-tree-set-depth 9)
    (should (equal (crate-tree-test--row-ids)
                   (mapcar (lambda (row) (crate-tree-item-path (car row)))
                           (crate-tree--rows root nil))))))

(ert-deftest crate-tree-mode-sort-cycle ()
  "The sort command cycles through the four keys."
  (crate-tree-test--with-buffer
    (should (eq crate-tree--sort 'source))
    (crate-tree-sort)
    (should (eq crate-tree--sort 'name))
    (should (equal (nth 1 (crate-tree-test--row-ids)) "harness::Alias"))
    (crate-tree-sort)
    (should (eq crate-tree--sort 'kind))
    (crate-tree-sort)
    (should (eq crate-tree--sort 'visibility))
    (crate-tree-sort)
    (should (eq crate-tree--sort 'source))))

(ert-deftest crate-tree-mode-reverse-sort ()
  "The reverse command turns the sibling order around."
  (crate-tree-test--with-buffer
    (crate-tree-reverse-sort)
    (should crate-tree--reverse)
    ;; The last declared child of the root that the default kind
    ;; list shows comes first.
    (should (equal (nth 1 (crate-tree-test--row-ids))
                   "harness::Color"))
    (crate-tree-reverse-sort)
    (should-not crate-tree--reverse)))

(ert-deftest crate-tree-mode-public-only ()
  "The public filter drops a non-public row."
  (crate-tree-test--with-buffer
    (crate-tree-toggle-public)
    (should crate-tree--public-only)
    (should-not (member "harness::api::net::handshake"
                        (crate-tree-test--row-ids)))
    (should (member "harness::api::net::connect"
                    (crate-tree-test--row-ids)))
    (should (string-match-p "public only" header-line-format))))

(ert-deftest crate-tree-mode-kind-filter ()
  "The kind filter shows the named kinds alone."
  (crate-tree-test--with-buffer
    (crate-tree-kind-filter '(module))
    (let ((ids (crate-tree-test--row-ids)))
      (should (member "harness::api" ids))
      (should-not (member "harness::api::net::connect" ids)))
    (crate-tree-kind-filter nil)
    (should (equal (crate-tree-test--row-ids) '("harness")))))

(ert-deftest crate-tree-mode-focus ()
  "The focus keeps the matching subtree."
  (crate-tree-test--with-buffer
    (crate-tree-focus "net")
    (should (equal (crate-tree-test--row-ids)
                   '("harness" "harness::api" "harness::api::net"
                     "harness::api::net::connect"
                     "harness::api::net::handshake"
                     "harness::api::net::Socket"
                     "harness::api::net::Socket::open")))
    (should (string-match-p "focus: net" header-line-format))))

(ert-deftest crate-tree-mode-reset-filters ()
  "The reset command drops every filter."
  (crate-tree-test--with-buffer
    (crate-tree-focus "net")
    (crate-tree-toggle-public)
    (crate-tree-kind-filter '(module))
    (crate-tree-reset-filters)
    (should-not crate-tree--focus)
    (should-not crate-tree--public-only)
    (should (equal crate-tree--kinds crate-tree--default-kinds))
    (should (member "harness::api::net::connect"
                    (crate-tree-test--row-ids)))))

(ert-deftest crate-tree-mode-copy-path ()
  "The copy command puts the item path on the kill ring."
  (crate-tree-test--with-buffer
    (let (copied)
      (cl-letf (((symbol-function 'kill-new)
                 (lambda (text) (setq copied text))))
        (crate-tree-test--goto "harness::money::convert")
        (crate-tree-copy-path))
      (should (equal copied "harness::money::convert")))))

(ert-deftest crate-tree-mode-browse-url ()
  "The browse command builds the docs.rs URL of the row."
  (crate-tree-test--with-buffer
    (let (opened)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url) (setq opened url))))
        (crate-tree-test--goto "harness::api::net::connect")
        (crate-tree-browse-url))
      (should (equal opened
                     "https://docs.rs/harness/latest/harness/api/net/connect")))))

(ert-deftest crate-tree-mode-visit-without-source ()
  "A crate with no source on disk refuses to jump."
  (crate-tree-test--with-buffer
    (crate-tree-test--goto "harness::Half::fetch")
    (should-error (crate-tree-visit) :type 'user-error)))

(ert-deftest crate-tree-mode-visit-source ()
  "The visit command opens the span of the row."
  (crate-tree-test--with-buffer
    (let* ((directory (make-temp-file "crate-tree-test" t))
           (file (expand-file-name "src/lib.rs" directory)))
      (unwind-protect
          (progn
            (make-directory (expand-file-name "src" directory) t)
            (with-temp-file file
              (dotimes (line 100)
                (insert (format "// line %d\n" (1+ line)))))
            (setq-local crate-tree--directory directory)
            (crate-tree-test--goto "harness::Half::fetch")
            (crate-tree-visit)
            (should (equal (buffer-file-name) file))
            (should (equal (line-number-at-pos)
                           (cadr (crate-tree-item-span
                                  (crate-tree-test--item "fetch"))))))
        (when-let* ((buffer (find-buffer-visiting file)))
          (kill-buffer buffer))
        (delete-directory directory t)))))

(ert-deftest crate-tree-mode-empty-buffer ()
  "A tree buffer without JSON says so."
  (with-temp-buffer
    (crate-tree-mode)
    (crate-tree--reprint)
    (should (string-match-p "No rustdoc JSON yet"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))

(ert-deftest crate-tree-mode-names-a-running-build ()
  "A build that still runs says so in place of the rows."
  (with-temp-buffer
    (crate-tree-mode)
    (setq crate-tree--status 'running)
    (crate-tree--reprint)
    (should (string-match-p "build in progress"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))

(ert-deftest crate-tree-mode-names-the-reason-of-a-failure ()
  "A table without rows names why the build failed."
  (with-temp-buffer
    (crate-tree-mode)
    (setq crate-tree--status "cargo `cargo' is not on `executable-find'")
    (crate-tree--reprint)
    (should (string-match-p "No rustdoc JSON: cargo"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))


;;; Local rustdoc builds

(defun crate-tree-test--metadata (manifest target-directory &optional target-name)
  "Return a `cargo metadata' record for MANIFEST with one library target.
TARGET-DIRECTORY holds the build output, and TARGET-NAME names the
library."
  (let ((package (make-hash-table :test #'equal))
        (target (make-hash-table :test #'equal))
        (json (make-hash-table :test #'equal)))
    (puthash "name" "my_crate" package)
    (puthash "manifest_path" (expand-file-name manifest) package)
    (puthash "name" (or target-name "my_crate") target)
    (puthash "kind" ["lib"] target)
    (puthash "targets" (vector target) package)
    (puthash "target_directory" target-directory json)
    (puthash "packages" (vector package) json)
    json))

(ert-deftest crate-tree-json-file ()
  "The JSON path follows the target directory and the library name."
  (let* ((manifest (expand-file-name "Cargo.toml" "/tmp/mycrate"))
         (metadata (crate-tree-test--metadata manifest "/tmp/target")))
    (should (equal (crate-tree--json-file metadata manifest)
                   "/tmp/target/doc/my_crate.json"))))

(ert-deftest crate-tree-json-file-no-library ()
  "A package without a library target names no JSON."
  (let* ((manifest (expand-file-name "Cargo.toml" "/tmp/mycrate"))
         (metadata (crate-tree-test--metadata manifest "/tmp/target"))
         (package (aref (gethash "packages" metadata) 0))
         (target (aref (gethash "targets" package) 0)))
    (puthash "kind" ["bin"] target)
    (should-not (crate-tree--json-file metadata manifest))))

(ert-deftest crate-tree-json-cached ()
  "A cached document answers without a build."
  (crate-test--with-local-crate dir
    (let ((crate-tree--json-cache (make-hash-table :test #'equal))
          (json (make-hash-table :test #'equal)))
      (puthash (crate-tree--json-cache-key dir) json crate-tree--json-cache)
      (should (eq (crate-tree--json dir) json)))))

(ert-deftest crate-tree-json-failed-sentinel ()
  "A failed build stays failed instead of retrying."
  (crate-test--with-local-crate dir
    (let ((crate-tree--json-cache (make-hash-table :test #'equal)))
      (puthash (crate-tree--json-cache-key dir) :failed crate-tree--json-cache)
      (should-not (crate-tree--json dir))
      (should (eq (gethash (crate-tree--json-cache-key dir)
                           crate-tree--json-cache)
                  :failed)))))

(ert-deftest crate-tree-json-without-manifest ()
  "A directory without a manifest answers nil."
  (let ((directory (make-temp-file "crate-tree-empty" t)))
    (unwind-protect
        (let ((crate-tree--json-cache (make-hash-table :test #'equal)))
          (should-not (crate-tree--json directory)))
      (delete-directory directory t))))

(ert-deftest crate-tree-start-build-without-cargo ()
  "A missing cargo caches the failure and its reason."
  (crate-test--with-local-crate dir
    (let ((crate-tree--json-cache (make-hash-table :test #'equal))
          (crate-tree--reason (make-hash-table :test #'equal))
          (crate-cargo-program nil))
      (with-temp-buffer
        (crate-tree-mode)
        (should-not (crate-tree--start-local-build dir (current-buffer)))
        (should (eq (gethash (crate-tree--json-cache-key dir)
                             crate-tree--json-cache)
                    :failed))
        (should (string-match-p "crate-cargo-program"
                                (gethash (crate-tree--json-cache-key dir)
                                         crate-tree--reason)))
        (should (string-match-p "crate-cargo-program" crate-tree--status))
        (crate-tree--reprint)
        (should (string-match-p "crate-cargo-program"
                                (buffer-substring-no-properties
                                 (point-min) (point-max))))))))

(ert-deftest crate-tree-start-build-names-a-missing-cargo-program ()
  "A cargo name that resolves to nothing names that name."
  (crate-test--with-local-crate dir
    (let ((crate-tree--json-cache (make-hash-table :test #'equal))
          (crate-cargo-program "/no/such/cargo"))
      (with-temp-buffer
        (crate-tree-mode)
        (should-not (crate-tree--start-local-build dir (current-buffer)))
        (should (string-match-p "no/such/cargo" crate-tree--status))))))

(ert-deftest crate-tree-start-build-without-library-target ()
  "A package without a library target names that fact."
  (crate-test--with-local-crate dir
    (let* ((manifest (crate-local--manifest dir))
           (metadata (crate-tree-test--metadata
                      manifest (expand-file-name "target" dir)))
           (package (aref (gethash "packages" metadata) 0))
           (target (aref (gethash "targets" package) 0))
           (crate-tree--json-cache (make-hash-table :test #'equal))
           (crate-cargo-program "/mock/cargo"))
      (puthash "kind" ["bin"] target)
      (cl-letf (((symbol-function 'executable-find) (lambda (_program) "/mock/cargo"))
                ((symbol-function 'crate-local--metadata)
                 (lambda (_dir) metadata)))
        (with-temp-buffer
          (crate-tree-mode)
          (should-not (crate-tree--start-local-build dir (current-buffer)))
          (should (string-match-p "no library target" crate-tree--status))
          (should (string-match-p "no library target"
                                  (crate-tree--status-message))))))))

(ert-deftest crate-tree-json-failed-sentinel-names-its-reason ()
  "A cached failure leaves its reason for the table."
  (crate-test--with-local-crate dir
    (let ((crate-tree--json-cache (make-hash-table :test #'equal))
          (crate-tree--reason (make-hash-table :test #'equal))
          (key (crate-tree--json-cache-key dir)))
      (puthash key :failed crate-tree--json-cache)
      (puthash key "a reason" crate-tree--reason)
      (with-temp-buffer
        (should-not (crate-tree--json dir))
        (should (equal crate-tree--status "a reason"))))))

(ert-deftest crate-tree-read-json ()
  "The reader parses a rustdoc document and survives a broken file."
  (let ((file (make-temp-file "crate-tree-json" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"format_version\": 61, \"root\": 0}"))
          (should (equal (gethash "format_version"
                                  (crate-tree--read-json file))
                         61))
          (with-temp-file file
            (insert "not json"))
          (should-not (crate-tree--read-json file)))
      (delete-file file))))

(ert-deftest crate-tree-mode-refresh-local ()
  "A refresh prints the document that the builder answers."
  (crate-tree-test--with-buffer
    (setq-local crate-tree--root nil)
    (setq-local crate-tree--directory "/tmp/somewhere")
    (cl-letf (((symbol-function 'crate-tree--json)
               (lambda (_directory) (crate-tree-test--json)))
              ((symbol-function 'crate-tree--forget-local) #'ignore))
      (crate-tree--refresh))
    (should (equal (car (crate-tree-test--row-ids)) "harness"))))

(ert-deftest crate-tree-mode-refresh-keeps-tree ()
  "A refresh that answers no document keeps the rows of the last one."
  (crate-tree-test--with-buffer
    (let ((before (crate-tree-test--row-ids)))
      (setq-local crate-tree--directory "/tmp/somewhere")
      (cl-letf (((symbol-function 'crate-tree--json) (lambda (_directory) nil))
                ((symbol-function 'crate-tree--forget-local) #'ignore))
        (crate-tree--refresh))
      (should (equal (crate-tree-test--row-ids) before)))))


;;; Commands

(ert-deftest crate-tree-open-database-crate ()
  "A database crate opens its own buffer and reads the Nix document."
  (let ((displayed nil))
    (cl-letf (((symbol-function 'crate-doc--json)
               (lambda (_name) (crate-tree-test--json)))
              ((symbol-function 'crate--display-buffer)
               (lambda (buffer)
                 (setq displayed (get-buffer-create buffer))
                 (set-buffer displayed))))
      (unwind-protect
          (progn
            (crate-tree--open "harness" nil)
            (should (equal (buffer-name displayed) "Crate Tree: harness"))
            (with-current-buffer displayed
              (should (derived-mode-p 'crate-tree-mode))
              (should (equal crate-doc--render-function
                             'crate-tree--render-from-build))
              (should (equal (car (crate-tree-test--row-ids)) "harness"))))
        (when (buffer-live-p displayed)
          (kill-buffer displayed))))))

(ert-deftest crate-tree-open-local-crate ()
  "A local crate names its directory in the buffer name."
  (let ((displayed nil))
    (cl-letf (((symbol-function 'crate-tree--json)
               (lambda (_directory) (crate-tree-test--json)))
              ((symbol-function 'crate--display-buffer)
               (lambda (buffer)
                 (setq displayed (get-buffer-create buffer))
                 (set-buffer displayed))))
      (unwind-protect
          (progn
            (crate-tree--open "my-crate" "/tmp/mycrate/")
            (should (equal (buffer-name displayed)
                           "Crate Tree: my-crate (/tmp/mycrate)"))
            (with-current-buffer displayed
              (should (equal crate-tree--directory "/tmp/mycrate"))
              (should-not crate-doc--render-function)
              (should (equal (car (crate-tree-test--row-ids)) "harness"))))
        (when (buffer-live-p displayed)
          (kill-buffer displayed))))))

(ert-deftest crate-tree-open-keeps-folds ()
  "A second open of the same buffer keeps its fold state."
  (let ((displayed nil))
    (cl-letf (((symbol-function 'crate-tree--json)
               (lambda (_directory) (crate-tree-test--json)))
              ((symbol-function 'crate--display-buffer)
               (lambda (buffer)
                 (setq displayed (get-buffer-create buffer))
                 (set-buffer displayed))))
      (unwind-protect
          (progn
            (crate-tree--open "my-crate" "/tmp/mycrate/")
            (with-current-buffer displayed
              (puthash "harness::api" t crate-tree--folded)
              (crate-tree--reprint))
            (crate-tree--open "my-crate" "/tmp/mycrate/")
            (with-current-buffer displayed
              (should (gethash "harness::api" crate-tree--folded))
              (should-not (member "harness::api::net"
                                  (crate-tree-test--row-ids)))))
        (when (buffer-live-p displayed)
          (kill-buffer displayed))))))

(ert-deftest crate-tree-command-without-crate ()
  "The name command refuses a crate that the database does not hold."
  (cl-letf (((symbol-function 'crate--crate) (lambda (_name) nil)))
    (should-error (crate-tree "nope") :type 'user-error)))

(ert-deftest crate-tree-directory-without-manifest ()
  "The directory command refuses a directory without a Cargo.toml."
  (let ((directory (make-temp-file "crate-tree-no-manifest" t)))
    (unwind-protect
        (should-error (crate-tree-directory directory) :type 'user-error)
      (delete-directory directory t))))

(ert-deftest crate-tree-show-from-detail-local ()
  "`crate-tree-show' passes the directory of a local detail buffer."
  (with-temp-buffer
    (crate-mode)
    (setq-local crate-name "my-crate")
    (setq-local crate-local-path "/tmp/mycrate")
    (let (called)
      (cl-letf (((symbol-function 'crate-tree-directory)
                 (lambda (directory) (setq called directory))))
        (crate-tree-show))
      (should (equal called "/tmp/mycrate")))))

(ert-deftest crate-tree-show-from-detail-database ()
  "`crate-tree-show' passes the name of a database detail buffer."
  (with-temp-buffer
    (crate-mode)
    (setq-local crate-name "serde")
    (setq-local crate-local-path nil)
    (let (called)
      (cl-letf (((symbol-function 'crate-tree)
                 (lambda (name) (setq called name))))
        (crate-tree-show))
      (should (equal called "serde")))))

(ert-deftest crate-tree-show-from-browse ()
  "`crate-tree-show' reads the crate of the row in a browse buffer."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries '(("serde" ["serde" "1.0.0" "desc"])))
    (tabulated-list-print)
    (goto-char (point-min))
    (let (called)
      (cl-letf (((symbol-function 'crate-tree)
                 (lambda (name) (setq called name))))
        (crate-tree-show))
      (should (equal called "serde")))))

(ert-deftest crate-insert-structure-renders ()
  "The Structure section holds the button that opens the table."
  (with-temp-buffer
    (insert "body\n")
    (crate-insert-structure)
    (let ((text (buffer-substring-no-properties
                 (point-min) (point-max))))
      ;; A blank line separates it from the section above, like every
      ;; other inserter.
      (should (string-match-p "\\`body\n\nStructure" text))
      (should (string-match-p "open the crate tree" text)))))

(ert-deftest crate-detail-hook-holds-structure ()
  "The default section list ends with the Structure section."
  (should (memq 'crate-insert-structure crate-detail-sections-hook)))

(ert-deftest crate-tree-mode-keymap ()
  "The tree keymap binds the row commands."
  (crate-tree-test--with-buffer
    (should (eq (key-binding (kbd "TAB")) 'crate-tree-toggle))
    (should (eq (key-binding (kbd "s")) 'crate-tree-sort))
    (should (eq (key-binding (kbd "S")) 'crate-tree-reverse-sort))
    (should (eq (key-binding (kbd "RET")) 'crate-tree-visit))
    (should (eq (key-binding (kbd "y")) 'crate-tree-copy-path))
    (should (eq (key-binding (kbd "w")) 'crate-tree-copy-dependency))
    (should (keymapp (key-binding (kbd "f"))))))

(ert-deftest crate-tree-copy-dependency-local ()
  "The copy command reads the version of a local crate record."
  (crate-tree-test--with-buffer
    (let ((record (make-hash-table :test #'equal))
          copied)
      (puthash "name" "my-crate" record)
      (puthash "latest_version" "0.3.0" record)
      (setq-local crate-tree--name "my-crate")
      (setq-local crate-tree--directory "/tmp/mycrate")
      (cl-letf (((symbol-function 'crate-local--record)
                 (lambda (_directory) record))
                ((symbol-function 'kill-new)
                 (lambda (text) (setq copied text))))
        (crate-tree-copy-dependency))
      (should (equal copied "my-crate = \"0.3.0\"")))))


;;; Bookmarks

(defun crate-tree-test--bookmark-record (props)
  "Return a bookmark record named `Crate tree' with PROPS.
PROPS are (SYMBOL . VALUE) conses, the shape that
`bookmark-prop-get' reads."
  (cons "Crate tree" props))

(ert-deftest crate-tree-bookmark-record ()
  "The record holds the view state of the table."
  (crate-tree-test--with-buffer
    (puthash "harness::api" t crate-tree--folded)
    (setq-local crate-tree--kinds '(module))
    (setq-local crate-tree--public-only t)
    (setq-local crate-tree--focus "api")
    (setq-local crate-tree--max-depth 1)
    (setq-local crate-tree--sort 'name)
    (setq-local crate-tree--reverse t)
    (crate-tree--reprint)
    (crate-tree-test--goto "harness::api")
    (let ((record (crate-tree--bookmark-make-record)))
      (should (equal (car record) "Crate tree: harness"))
      (should (eq (bookmark-prop-get record 'handler)
                  'crate-tree-bookmark-jump))
      (should (equal (bookmark-prop-get record 'crate) "harness"))
      (should-not (bookmark-prop-get record 'directory))
      (should (equal (bookmark-prop-get record 'folds) '("harness::api")))
      (should (equal (bookmark-prop-get record 'kinds) '(module)))
      (should (bookmark-prop-get record 'public))
      (should (equal (bookmark-prop-get record 'focus) "api"))
      (should (equal (bookmark-prop-get record 'depth) 1))
      (should (eq (bookmark-prop-get record 'sort) 'name))
      (should (bookmark-prop-get record 'reverse))
      (should (equal (bookmark-prop-get record 'row) "harness::api")))))

(ert-deftest crate-tree-mode-bookmark-function ()
  "The mode installs its bookmark record function."
  (crate-tree-test--with-buffer
    (should (eq bookmark-make-record-function
                'crate-tree--bookmark-make-record))))

(ert-deftest crate-tree-bookmark-handler-type ()
  "The handler names its own type in the bookmark menu."
  (should (equal (get 'crate-tree-bookmark-jump 'bookmark-handler-type)
                 "Crate tree")))

(ert-deftest crate-tree-bookmark-jump-database ()
  "A jump restores the folds, the filters and the row at point."
  (let ((displayed nil)
        (record (crate-tree-test--bookmark-record
                 '((handler . crate-tree-bookmark-jump)
                   (crate . "harness")
                   (directory)
                   (folds . ("harness::api"))
                   (kinds . (module))
                   (public . t)
                   (focus . "api")
                   (depth . 1)
                   (sort . name)
                   (reverse . t)
                   (row . "harness::api")))))
    (cl-letf (((symbol-function 'crate-doc--json)
               (lambda (_name) (crate-tree-test--json)))
              ((symbol-function 'crate--display-buffer)
               (lambda (buffer)
                 (setq displayed (get-buffer-create buffer))
                 (set-buffer displayed))))
      (unwind-protect
          (progn
            (crate-tree-bookmark-jump record)
            (with-current-buffer displayed
              (should crate-tree--public-only)
              (should (equal crate-tree--kinds '(module)))
              (should (equal crate-tree--focus "api"))
              (should (equal crate-tree--max-depth 1))
              (should (eq crate-tree--sort 'name))
              (should crate-tree--reverse)
              (should (gethash "harness::api" crate-tree--folded))
              (should (equal (tabulated-list-get-id) "harness::api"))))
        (when (buffer-live-p displayed)
          (kill-buffer displayed))))))

(ert-deftest crate-tree-bookmark-jump-local ()
  "A jump with a directory reopens that checkout."
  (crate-test--with-local-crate dir
    (let* ((displayed nil)
           (record (crate-tree-test--bookmark-record
                    `((handler . crate-tree-bookmark-jump)
                      (crate . "my-crate")
                      (directory . ,dir)
                      (folds)
                      (kinds . (module))
                      (row . "harness")))))
      (cl-letf (((symbol-function 'crate-tree--json)
                 (lambda (_directory) (crate-tree-test--json)))
                ((symbol-function 'crate--display-buffer)
                 (lambda (buffer)
                   (setq displayed (get-buffer-create buffer))
                   (set-buffer displayed))))
        (unwind-protect
            (progn
              (crate-tree-bookmark-jump record)
              (with-current-buffer displayed
                (should (equal (buffer-name)
                               (format "Crate Tree: my-crate (%s)"
                                       (directory-file-name dir))))
                (should (equal (tabulated-list-get-id) "harness"))))
          (when (buffer-live-p displayed)
            (kill-buffer displayed)))))))

(ert-deftest crate-tree-bookmark-jump-missing-directory ()
  "A jump to a crate directory that left the disk refuses to open."
  (let ((record (crate-tree-test--bookmark-record
                 '((handler . crate-tree-bookmark-jump)
                   (crate . "my-crate")
                   (directory . "/nonexistent/crate")
                   (folds)))))
    (should-error (crate-tree-bookmark-jump record) :type 'user-error)))

(ert-deftest crate-tree-bookmark-stale-fold ()
  "A fold path that the rebuilt tree lacks hides nothing."
  (let ((displayed nil)
        (record (crate-tree-test--bookmark-record
                 '((handler . crate-tree-bookmark-jump)
                   (crate . "harness")
                   (directory)
                   (folds . ("harness::gone"))
                   (row . "harness::api")))))
    (cl-letf (((symbol-function 'crate-doc--json)
               (lambda (_name) (crate-tree-test--json)))
              ((symbol-function 'crate--display-buffer)
               (lambda (buffer)
                 (setq displayed (get-buffer-create buffer))
                 (set-buffer displayed))))
      (unwind-protect
          (progn
            (crate-tree-bookmark-jump record)
            (with-current-buffer displayed
              (should (gethash "harness::gone" crate-tree--folded))
              (should (member "harness::api::net"
                              (mapcar #'car tabulated-list-entries)))))
        (when (buffer-live-p displayed)
          (kill-buffer displayed))))))

;;; The `cargo-modules structure' format

(ert-deftest crate-tree-structure-matches-cargo-modules ()
  "The rendered tree matches the `cargo-modules structure' golden file."
  (crate-tree-test--with-root
    (let ((golden (crate-tree-test--fixture-file
                   "fixtures/harness.structure.txt")))
      (skip-unless (file-readable-p golden))
      (should (equal (crate-tree--structure-text root)
                     (with-temp-buffer
                       (insert-file-contents golden)
                       (buffer-string)))))))

(provide 'crate-tree-test)

;;; crate-tree-test.el ends here
