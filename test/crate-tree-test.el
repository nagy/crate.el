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

(defun crate-tree-test--root ()
  "Return the fixture tree root, or nil when the document is absent."
  (when-let* ((json (crate-tree-test--json)))
    (crate-tree--items json)))

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
