;;; crate-tests.el --- Tests for crate -*- lexical-binding: t -*-

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
;;   (require 'crate)
;;   (require 'ert)
;;
;; Then: M-x ert RET crate

(require 'crate)
(require 'ol-crate)
(require 'ert)
(require 'cl-lib)


;;; Helpers

(defun crate-test--data-hash (&rest props)
  "Build a hash table of mock crate field data.
PROPS are alternating keyword-value pairs like :description \"foo\".
Keyword keys are converted to strings by stripping the leading colon.
Returns a hash table suitable for binding to `crate-data'."
  (let ((table (make-hash-table :test 'equal)))
    (cl-loop for (prop val) on props by #'cddr
             do (puthash (substring (symbol-name prop) 1) val table))
    table))

(cl-defun crate-test--crate-table (&rest entries)
  "Build a hash table of mock crate data keyed by crate name.
ENTRIES are (KEY . PLIST) pairs where PLIST contains keyword-value
pairs like :description \"foo\".  Returns a hash table suitable as
the return value of `crate-list-json'."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (e entries table)
      (let ((inner (make-hash-table :test 'equal)))
        (cl-loop for (prop val) on (cdr e) by #'cddr
                 do (puthash (substring (symbol-name prop) 1) val inner))
        (puthash (car e) inner table)))))

(defmacro crate-test--with-crate (name data &rest body)
  "Evaluate BODY with `crate-name' bound to NAME and `crate-data' to DATA.
DATA should be a hash table of field keys to values (the inner
record, not the top-level crate table)."
  (declare (indent 2))
  `(let ((crate-name ,name)
         (crate-data ,data))
     ,@body))


;;; Unit tests

(ert-deftest crate-description-from-hash ()
  "`crate--description' extracts description from `crate-data'."
  (crate-test--with-crate "test-crate"
      (crate-test--data-hash :description "A test crate")
    (should (equal (crate--description) "A test crate"))))

(ert-deftest crate-description-null ()
  "`crate--description' returns empty string for :null description."
  (crate-test--with-crate "test-crate"
      (crate-test--data-hash :description :null)
    (should (equal (crate--description) ""))))

(ert-deftest crate-description-missing ()
  "`crate--description' returns empty string when key is absent from data."
  (let ((crate-name "nonexistent")
        (crate-data (make-hash-table :test 'equal)))
    (should (equal (crate--description) ""))))

(ert-deftest crate-mode-fields ()
  "`crate-mode' renders fields: label+value, docs.rs fallback, label-only for missing."
  (crate-test--with-crate "test-crate"
      (crate-test--data-hash :name "test-crate"
                             :description "a crate"
                             :homepage "https://example.com"
                             :documentation :null
                             :id 42)
    (let ((crate--data-cache (make-hash-table :test 'equal)))
      (cl-letf (((symbol-function 'cd) #'ignore)
                ((symbol-function 'url-knowledge-url) nil))
        (with-temp-buffer
          (crate-mode)
          (let ((content (buffer-string)))
            ;; Homepage has a value.
            (should (string-match-p "Homepage:.*example.com" content))
            ;; Documentation is :null → docs.rs fallback link.
            (should (string-match-p "docs\\.rs/test-crate" content))
            ;; Updated has no key → label only.
            (should (string-match-p "Updated: *\n" content))))))))


;;; Cache

(ert-deftest crate-list-json-from-file ()
  "`crate-list-json' loads and parses a JSON file."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (make-temp-file "crate-test-" nil ".json")))
    (unwind-protect
        (progn
          (write-region "{\"serde\":{\"description\":\"serialization\"}}" nil tmpfile)
          (let ((crate-data-path tmpfile))
            (let ((result (crate-list-json)))
              (should (hash-table-p result))
              (should (gethash "serde" result))
              (should (equal (gethash "description" (gethash "serde" result))
                             "serialization")))))
      (delete-file tmpfile))))

(ert-deftest crate-list-json-missing-file ()
  "`crate-list-json' returns nil when the file does not exist."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/nonexistent/crate-data.json"))
    (should-not (crate-list-json)))

  ;; Also test when `crate-data-path' is nil.
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path nil))
    (should-not (crate-list-json))))

(ert-deftest crate-list-json-invalid-content ()
  "`crate-list-json' returns nil when the file contains invalid JSON."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (make-temp-file "crate-test-" nil ".json")))
    (unwind-protect
        (progn
          (write-region "not json at all" nil tmpfile)
          (let ((crate-data-path tmpfile))
            (should-not (crate-list-json))))
      (delete-file tmpfile))))

(ert-deftest crate-list-json-memoized ()
  "`crate-list-json' memoizes results in `crate--data-cache'."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (make-temp-file "crate-test-" nil ".json")))
    (unwind-protect
        (progn
          (write-region "{\"serde\":{\"description\":\"serialization\"}}" nil tmpfile)
          (let ((crate-data-path tmpfile))
            ;; First call computes.
            (should (crate-list-json))
            ;; Change the file to verify second call uses cache, not disk.
            (write-region "{\"other\":{\"description\":\"changed\"}}" nil tmpfile)
            (let ((result (crate-list-json)))
              (should (hash-table-p result))
              ;; Still returns original data from cache.
              (should (gethash "serde" result))
              (should-not (gethash "other" result)))))
      (delete-file tmpfile))))


;;; Bookmarks

(ert-deftest crate-bookmark-make-record ()
  "`crate--bookmark-make-record-function' returns a bookmark record."
  (crate-test--with-crate "test-crate"
      (crate-test--data-hash :description "A test crate")
    (let ((rec (crate--bookmark-make-record-function)))
      (should (stringp (car rec)))
      (should (string-match-p "test-crate" (car rec)))
      (should (eq (alist-get 'handler rec) 'crate-bookmark-jump))
      (should (equal (alist-get 'crate rec) "test-crate"))
      (should (equal (alist-get 'location rec) "A test crate")))))

(ert-deftest crate-bookmark-jump ()
  "`crate-bookmark-jump' calls `find-crate' with the stored crate name."
  (let ((called-name nil))
    (cl-letf (((symbol-function 'find-crate)
               (lambda (name) (setq called-name name))))
      ;; Bookmark records use (NAME . PROPS) format where PROPS is an alist.
      (crate-bookmark-jump '("Rust Crate: serde" (crate . "serde")))
      (should (equal called-name "serde")))))

(ert-deftest crate-bookmark-jump-handler-type ()
  "`crate-bookmark-jump' has a `bookmark-handler-type' property."
  (should (equal (get 'crate-bookmark-jump 'bookmark-handler-type) "Crate")))

(ert-deftest crate-find-crate-no-data ()
  "`find-crate' signals user-error when no crate data is loaded."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'switch-to-buffer) #'ignore))
      (should-error (find-crate "nonexistent") :type 'user-error))))


;;; Interactive commands

(ert-deftest crate-browse-url-delegates-to-find-crate ()
  "`crate-browse-url' delegates to `find-crate'."
  (let ((called-url nil))
    (cl-letf (((symbol-function 'find-crate)
               (lambda (url) (setq called-url url))))
      (crate-browse-url "https://crates.io/crates/serde")
      (should (equal called-url "https://crates.io/crates/serde")))))

(ert-deftest crate-install-browse-url-handler ()
  "`crate-install-browse-url-handler' adds a handler to `browse-url-default-handlers'."
  (require 'browse-url)
  (let ((browse-url-default-handlers nil))
    (crate-install-browse-url-handler)
    (should browse-url-default-handlers)
    (should (equal (caar browse-url-default-handlers)
                   "^https://crates\\.io/crates/"))
    (should (eq (cdar browse-url-default-handlers) 'crate-browse-url))))


;;; Major mode

(ert-deftest crate-mode-initialization ()
  "`crate-mode' initializes a read-only buffer with crate details."
  (crate-test--with-crate "test-crate"
      (crate-test--data-hash :description "A test crate" :id 12345)
    (let ((crate--data-cache (make-hash-table :test 'equal)))
      (cl-letf (((symbol-function 'cd) #'ignore)
                ((symbol-function 'url-knowledge-url) nil))
        (with-temp-buffer
          (crate-mode)
          (should (eq major-mode 'crate-mode))
          (should buffer-read-only)
          (should (string-match-p "test-crate" (buffer-string)))
          (should (string-match-p "A test crate" (buffer-string)))
          (should (string-match-p "12345" (buffer-string)))
          ;; Buffer-local variables.
          (should font-lock-defaults)
          (should (eq revert-buffer-function #'ignore))
          (should (eq bookmark-make-record-function
                     #'crate--bookmark-make-record-function)))))))


;;; Faces

(ert-deftest crate-font-lock-keywords-structure ()
  "`crate-font-lock-keywords' contains entries for all expected fields."
  (should (listp crate-font-lock-keywords))
  ;; Field labels, crate name, URLs, date, id.
  (should (>= (length crate-font-lock-keywords) 5))
  ;; Each entry references a crate-* face symbol.
  (dolist (entry crate-font-lock-keywords)
    (let* ((highlight (cadr entry))
           (face-form (cadr highlight)))
      (should (eq (car-safe face-form) 'quote))
      (should (string-prefix-p "crate-" (symbol-name (cadr face-form)))))))

(ert-deftest crate-face-definitions ()
  "All custom faces are defined and inherit from known faces."
  (dolist (face '(crate-name-face crate-field-label crate-url crate-date crate-id))
    (should (facep face))
    (should (face-attribute face :inherit))))


;;; Org link support

(ert-deftest crate-org-store-link-in-crate-mode ()
  "`crate--org-store-link' stores a link when in `crate-mode'."
  (crate-test--with-crate "serde" nil
    (let ((stored-type nil)
          (stored-link nil))
      (cl-letf (((symbol-function 'org-link-store-props)
                 (lambda (&rest props)
                   (let ((plist props))
                     (setq stored-type (plist-get plist :type)
                           stored-link (plist-get plist :link))))))
        (let ((major-mode 'crate-mode))
          (should (crate--org-store-link nil))
          (should (equal stored-type "crate"))
          (should (equal stored-link "crate:serde")))))))

(ert-deftest crate-org-store-link-not-in-crate-mode ()
  "`crate--org-store-link' returns nil outside `crate-mode'."
  (with-temp-buffer
    (fundamental-mode)
    (let ((major-mode 'fundamental-mode))
      (should-not (crate--org-store-link nil)))))

(provide 'crate-tests)
;;; crate-tests.el ends here
