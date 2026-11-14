;;; crate-test.el --- Tests for crate -*- lexical-binding: t -*-

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
;;   emacs --batch -L . -L test -l test/crate-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'crate)
(require 'ol-crate)
(require 'ert)
(require 'cl-lib)
(require 'thingatpt)
(require 'browse-url)
;; Fixtures live in a `*-test-helper.el' file, which the glob loader
;; skips, so pull it in by name.
(require 'crate-test-helper)


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
  "`crate--render' renders fields: label+value, docs.rs fallback, label-only for missing."
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
                                (crate--render)
                                (let ((content (buffer-string)))
                                  ;; Homepage has a value.
                                  (should (string-match-p "Homepage:.*example.com" content))
                                  ;; Documentation is :null → docs.rs fallback link.
                                  (should (string-match-p "docs\\.rs/test-crate" content))
                                  ;; Updated has no key → label only.
                                  (should (string-match-p "Updated: *\n" content))))))))

(ert-deftest crate-mode-links-urls-with-goto-address ()
  "A detail buffer links the URLs in its text."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--deps) #'ignore))
      (with-temp-buffer
        (crate-mode)
        (setq-local crate-name "test-crate")
        (setq-local crate-data (crate-test--data-hash
                                :name "test-crate"
                                :homepage "https://example.com/"
                                :repository "https://example.org/repo"))
        (crate--render)
        (should goto-address-mode)
        (goto-address-fontify)
        (dolist (url '("https://example.com/" "https://example.org/repo"))
          (goto-char (point-min))
          (should (search-forward url nil t))
          (goto-char (match-beginning 0))
          (let ((overlay (cl-find-if
                          (lambda (candidate)
                            (overlay-get candidate 'goto-address))
                          (overlays-at (point)))))
            (should overlay)
            (should (eq (overlay-get overlay 'mouse-face) 'highlight))))))))

(ert-deftest crate-mode-goto-address-option ()
  "A nil `crate-goto-address' keeps the URLs as plain text."
  (let ((crate-goto-address nil))
    (with-temp-buffer
      (crate-mode)
      (should-not goto-address-mode))))

(ert-deftest crate-mode-deps-url-at-point ()
  "Dependency crate names are `thing-at-point' `url' detectable."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1.0" "normal" 0)))))
      (with-temp-buffer
        (crate-mode)
        (setq-local crate-name "test-crate")
        (setq-local crate-data (crate-test--data-hash :name "test-crate"))
        (crate--render)
        (goto-char (point-min))
        (search-forward "serde")
        (goto-char (match-beginning 0))
        (should (equal (thing-at-point 'url t)
                       (concat crate--crates-io-url "serde")))))))


;;; Cache

(ert-deftest crate--list-from-file ()
  "`crate--list' loads and queries a SQLite database."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (let ((result (crate--list)))
            (should (hash-table-p result))
            (should (gethash "serde" result))
            (should (equal (gethash "description" (gethash "serde" result))
                           "serialization"))))
      (delete-file tmpfile))))

(ert-deftest crate--list-missing-file ()
  "`crate--list' returns nil when the file does not exist."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/nonexistent/crate-data.db"))
    (should-not (crate--list)))

  ;; Also test when `crate-data-path' is nil.
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path nil))
    (should-not (crate--list))))

(ert-deftest crate--list-invalid-content ()
  "`crate--list' returns nil when the file is not a valid database."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (make-temp-file "crate-test-" nil ".db")))
    (unwind-protect
        (progn
          (write-region "not a database" nil tmpfile)
          (let ((crate-data-path tmpfile))
            (should-not (crate--list))))
      (delete-file tmpfile))))

(ert-deftest crate--list-memoized ()
  "`crate--list' memoizes results in `crate--data-cache'."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (let ((crate-data-path tmpfile))
      ;; First call computes.
      (should (crate--list))
      ;; Delete the file to verify second call uses cache, not disk.
      (delete-file tmpfile)
      (let ((result (crate--list)))
        (should (hash-table-p result))
        ;; Still returns original data from cache.
        (should (gethash "serde" result))
        (should (equal (gethash "description" (gethash "serde" result))
                       "serialization"))))))

(ert-deftest crate--crate-published-spellings ()
  "A lookup reaches a published name from either spelling."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (crate-test--sqlite-db
                  '("async-trait" :name "async-trait" :description "derive macros")
                  '("rand_core" :name "rand_core" :description "core random"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (should (equal (gethash "description" (crate--crate "async-trait"))
                         "derive macros"))
          (should (equal (gethash "description" (crate--crate "rand-core"))
                         "core random"))
          ;; Downcased input reaches the same record.
          (should (equal (gethash "name" (crate--crate "ASYNC-trait"))
                         "async-trait")))
      (delete-file tmpfile))))

(ert-deftest crate--crate-memoized ()
  "`crate--crate' answers from the cache after the file is gone."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (let ((crate-data-path tmpfile))
      (should (crate--crate "serde"))
      (delete-file tmpfile)
      (should (equal (gethash "description" (crate--crate "serde"))
                     "serialization")))))

(ert-deftest crate--crate-missing-name-is-cached ()
  "A missing name queries once, then answers from the sentinel."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/mock-crates.db")
        (calls 0))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) #'ignore)
              ((symbol-function 'sqlite-select)
               (lambda (&rest _) (cl-incf calls) nil))
              ((symbol-function 'sqlite-close) #'ignore))
      (should-not (crate--crate "nope"))
      (should-not (crate--crate "nope"))
      (should (= calls 1)))))

(ert-deftest crate--database-readable-p-detects-garbage ()
  "A file that is not a database reads as unreadable."
  (let ((garbage (make-temp-file "crate-test-" nil ".db"))
        (good (crate-test--sqlite-db '("serde" :name "serde"))))
    (unwind-protect
        (progn
          (with-temp-file garbage (insert "not a database"))
          (let ((crate-data-path garbage))
            (should-not (crate--database-readable-p)))
          (let ((crate-data-path "/nonexistent/crate-data.db"))
            (should-not (crate--database-readable-p)))
          (let ((crate-data-path good))
            (should (crate--database-readable-p))))
      (delete-file garbage)
      (delete-file good))))


(ert-deftest crate-data-path-setq-self-invalidates ()
  "Plain `setq' of `crate-data-path' serves fresh data without refresh.
Covers `crate--list' across nil -> db1 -> db2 switches."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc--cache (make-hash-table :test 'equal))
        (db1 (crate-test--sqlite-db
              '("serde" :name "serde" :latest_version "1.0.0")))
        (db2 (crate-test--sqlite-db
              '("tokio" :name "tokio" :latest_version "1.40.0"))))
    (unwind-protect
        (let ((crate-data-path nil))
          ;; nil path caches the :failed negative...
          (should-not (crate--list))
          ;; ...then plain setq must serve db1 fresh — no refresh call.
          (setq crate-data-path db1)
          (should (gethash "serde" (crate--list)))
          ;; Second switch: db2 data, no db1 leftovers.
          (setq crate-data-path db2)
          (should (gethash "tokio" (crate--list)))
          (should-not (gethash "serde" (crate--list))))
      (delete-file db1)
      (delete-file db2))))

(ert-deftest crate--deps-keyed-by-path ()
  "`crate--deps' results don't leak across `crate-data-path' switches."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (current nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open)
               (lambda (path) (setq current path) t))
              ((symbol-function 'sqlite-select)
               (lambda (&rest _)
                 (list (list (format "dep-of-%s" current) "^1" "normal" 0))))
              ((symbol-function 'sqlite-close) #'ignore))
      (let ((crate-data-path "/db1.db"))
        (should (equal (caar (crate--deps "serde")) "dep-of-/db1.db")))
      (let ((crate-data-path "/db2.db"))
        (should (equal (caar (crate--deps "serde")) "dep-of-/db2.db"))))))

(ert-deftest crate--dependents-reverse-query ()
  "`crate--dependents' queries dependencies by dep_name."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) #'ignore)
              ((symbol-function 'sqlite-select)
               (lambda (_db sql &rest _)
                 (when (string-match-p "WHERE dep_name" sql)
                   (list (list "tokio") (list "axum")))))
              ((symbol-function 'sqlite-close) #'ignore))
      (let ((crate-data-path "/db1.db"))
        (should (equal (crate--dependents "serde") '("tokio" "axum")))))))

(ert-deftest crate--dependents-truncates-at-the-limit ()
  "`crate--dependents' stops at `crate-dependents-limit' and reports the cut."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-dependents-limit 2)
        (tmpfile (crate-test--sqlite-db '("serde" :name "serde"))))
    (unwind-protect
        (progn
          (crate-test--insert-dependents tmpfile '("alpha" "beta" "gamma"))
          (let ((crate-data-path tmpfile))
            (should (equal (crate--dependents "serde") '("alpha" "beta")))
            (should (crate--dependents-truncated-p "serde"))
            (let ((crate-dependents-limit nil))
              (crate-refresh-cache)
              (should (equal (crate--dependents "serde")
                             '("alpha" "beta" "gamma")))
              (should-not (crate--dependents-truncated-p "serde")))))
      (delete-file tmpfile))))

(ert-deftest crate--dependents-empty-result-is-cached ()
  "A crate that nothing depends on queries once, not on every render."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/mock-crates.db")
        (calls 0))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) #'ignore)
              ((symbol-function 'sqlite-select) (lambda (&rest _) (cl-incf calls) nil))
              ((symbol-function 'sqlite-close) #'ignore))
      (should-not (crate--dependents "serde"))
      (should-not (crate--dependents "serde"))
      (should (= calls 1)))))

(ert-deftest crate-mode-renders-dependents ()
  "Dependents render as a clickable section in `crate-mode'."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--dependents)
               (lambda (_name) '("tokio" "axum"))))
      (crate-test--with-crate "serde"
                              (crate-test--data-hash :name "serde")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (let ((content (buffer-string)))
            (should (string-match-p "Dependents" content))
            (should (string-match-p "tokio" content))
            (should (string-match-p "axum" content))))))))

(ert-deftest crate-mode-dependents-heading-marks-a-cut-list ()
  "A truncated Dependents heading carries a plus sign."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-dependents-limit 2)
        (crate-doc-enable nil)
        (tmpfile (crate-test--sqlite-db '("serde" :name "serde"))))
    (unwind-protect
        (progn
          (crate-test--insert-dependents tmpfile '("alpha" "beta" "gamma"))
          (let ((crate-data-path tmpfile))
            (with-temp-buffer
              (crate-mode)
              (setq-local crate-name "serde")
              (setq-local crate-data (crate--crate "serde"))
              (crate--render)
              (goto-char (point-min))
              (should (search-forward "Dependents (2+)" nil t))
              (should-not (search-forward "gamma" nil t)))))
      (delete-file tmpfile))))


(ert-deftest crate--deps-memoized ()
  "`crate--deps' caches both empty and failed results."
  ;; Empty result (no rows) is cached: second call doesn't re-query.
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/nonexistent/crate-data.db"))
    (let ((calls 0))
      (cl-letf (((symbol-function 'sqlite-open)
                 (lambda (&rest _) (cl-incf calls) (make-hash-table :test 'equal)))
                ((symbol-function 'sqlite-select) (lambda (&rest _) nil))
                ((symbol-function 'sqlite-close) #'ignore))
        ;; File doesn't exist: returns nil without opening.
        (should-not (crate--deps "serde"))
        (should (= calls 0)))))
  ;; Failed query is cached as :failed.
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/tmp/exists.db"))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) #'ignore)
              ((symbol-function 'sqlite-select)
               (lambda (&rest _) (error "Query failed")))
              ((symbol-function 'sqlite-close) #'ignore))
      (should-not (crate--deps "serde"))
      (let ((calls 0))
        (cl-letf (((symbol-function 'sqlite-select)
                   (lambda (&rest _) (cl-incf calls) (error "Query failed"))))
          (should-not (crate--deps "serde"))
          (should (= calls 0)))))))

;;; Bookmarks

(ert-deftest crate--list-closes-db-on-error ()
  "A failing query still closes the SQLite handle in `crate--list'."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/tmp/exists.db")
        (closed 0))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) #'ignore)
              ((symbol-function 'sqlite-select)
               (lambda (&rest _) (error "Query failed")))
              ((symbol-function 'sqlite-close)
               (lambda (&rest _) (cl-incf closed))))
      (should-not (crate--list))
      (should (= closed 1)))))

(ert-deftest crate--deps-closes-db-on-error ()
  "A failing query still closes the SQLite handle in `crate--deps'."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/tmp/exists.db")
        (closed 0))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) #'ignore)
              ((symbol-function 'sqlite-select)
               (lambda (&rest _) (error "Query failed")))
              ((symbol-function 'sqlite-close)
               (lambda (&rest _) (cl-incf closed))))
      (should-not (crate--deps "serde"))
      (should (= closed 1)))))

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

(ert-deftest crate-find-crate-versioned-url-surfaces-version ()
  "A versioned crates.io URL resolves the crate and surfaces the dropped version."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil)
        (msg nil)
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname))))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (setq msg (apply #'format fmt args)))))
            (find-crate "https://crates.io/crates/serde/1.0.200")
            ;; Version path stripped: canonical crate buffer exists…
            (should (get-buffer "Crate: serde"))
            ;; …and the requested version surfaced, not swallowed.
            (should (and msg (string-match-p "1\\.0\\.200" msg)))
            (kill-buffer (get-buffer "Crate: serde"))))
      (delete-file tmpfile))))

(ert-deftest crate-find-crate-no-db-error ()
  "Missing `crate-data-path' blames the configuration, not the crate name."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path nil))
    (cl-letf (((symbol-function 'switch-to-buffer) #'ignore))
      (let ((err (should-error (find-crate "serde") :type 'user-error)))
        (should (string-match-p "No crate database configured" (cadr err)))
        (should-not (string-match-p "not found" (cadr err)))))))

(ert-deftest crate-find-crate-unreadable-db-error ()
  "An unreadable database reports the path, not `not found'."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (make-temp-file "crate-test-" nil ".db")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile (insert "not a database"))
          (let ((crate-data-path tmpfile))
            (cl-letf (((symbol-function 'switch-to-buffer) #'ignore))
              (let ((err (should-error (find-crate "serde") :type 'user-error)))
                (should (string-match-p "unreadable" (cadr err)))))))
      (delete-file tmpfile))))

(ert-deftest crate-find-crate-twice ()
  "`find-crate' on an existing buffer re-renders without error or duplication."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil)
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname)))))
            (find-crate "serde")
            (let ((buf (get-buffer "Crate: serde")))
              (should buf)
              (with-current-buffer buf
                (should (eq major-mode 'crate-mode))
                (let ((first-content (buffer-string)))
                  ;; Second visit must not error and must not duplicate.
                  (find-crate "serde")
                  (should (equal (buffer-string) first-content))))
              (kill-buffer buf))))
      (delete-file tmpfile))))

(ert-deftest crate-visit-hook-runs-after-locals-set ()
  "`crate-visit-hook' runs once, in the crate buffer, after locals are set."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil)
        (crate-visit-hook nil)
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (unwind-protect
        (let ((crate-data-path tmpfile)
              (calls nil))
          (add-hook 'crate-visit-hook
                    (lambda ()
                      (push (list (buffer-name)
                                  crate-name
                                  (and crate-data
                                       (gethash "name" crate-data)))
                            calls)))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname)))))
            (find-crate "serde")
            (find-crate "serde"))
          ;; Hook ran exactly once per visit (2 visits total), in the
          ;; crate buffer, after crate-name and crate-data were set.
          (should (= 2 (length calls)))
          (should (equal (nreverse calls)
                         '(("Crate: serde" "serde" "serde")
                           ("Crate: serde" "serde" "serde"))))
          (when (get-buffer "Crate: serde")
            (kill-buffer "Crate: serde")))
      (delete-file tmpfile))))


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
  "`crate-mode' sets up mode state; `crate--render' fills a read-only buffer."
  (crate-test--with-crate "test-crate"
    (crate-test--data-hash :description "A test crate"
                           :latest_version "0.1.0"
                           :license "MIT"
                           :downloads 12345678)
    (let ((crate--data-cache (make-hash-table :test 'equal)))
      (cl-letf (((symbol-function 'cd) #'ignore)
                ((symbol-function 'url-knowledge-url) nil)
                ((symbol-function 'crate--deps) #'ignore))
        (with-temp-buffer
          (crate-mode)
          ;; Mode setup only: no content yet.
          (should (eq major-mode 'crate-mode))
          (should (string-empty-p (buffer-string)))
          (should font-lock-defaults)
          (should (eq revert-buffer-function #'crate--revert))
          (should (eq bookmark-make-record-function
                     #'crate--bookmark-make-record-function))
          ;; Render fills the buffer and makes it read-only.
          (crate--render)
          (should buffer-read-only)
          (should (string-match-p "test-crate" (buffer-string)))
          (should (string-match-p "A test crate" (buffer-string)))
          (should (string-match-p "12.3M" (buffer-string)))
          (should (string-match-p "MIT" (buffer-string))))))))


(ert-deftest crate-revert-buffer ()
  "`crate--revert' re-renders the crate buffer, so `g' works."
  (crate-test--with-crate "test-crate"
    (crate-test--data-hash :description "A test crate"
                           :latest_version "0.1.0"
                           :license "MIT")
    (let ((crate--data-cache (make-hash-table :test 'equal)))
      (cl-letf (((symbol-function 'cd) #'ignore)
                ((symbol-function 'url-knowledge-url) nil)
                ((symbol-function 'crate--deps) #'ignore))
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (let ((first (buffer-string)))
            ;; Simulate `g': revert re-renders from the buffer-locals.
            (let ((inhibit-read-only t))
              (erase-buffer))
            (crate--revert)
            (should (equal (buffer-string) first))))))))
;;; Faces

(ert-deftest crate-font-lock-keywords-structure ()
  "`crate-font-lock-keywords' contains entries for all expected fields."
  (should (listp crate-font-lock-keywords))
  ;; Field labels, crate name, URLs, date, id.
  (should (>= (length crate-font-lock-keywords) 5))
  ;; Each entry references a quoted face symbol: a crate face, or the
  ;; `magit-section-heading', `magit-section-child-count' or `default'
  ;; face that the renderer leans on.
  (dolist (entry crate-font-lock-keywords)
    (let* ((highlight (cadr entry))
           (face-form (cadr highlight))
           (face (cadr face-form)))
      (should (eq (car-safe face-form) 'quote))
      (should (or (memq face '(magit-section-heading
                               magit-section-child-count
                               default))
                  (string-prefix-p "crate-" (symbol-name face)))))))

(ert-deftest crate-face-definitions ()
  "All custom faces are defined and inherit from known faces."
  (dolist (face '(crate-name-face crate-url crate-date
                                  crate-id crate-version crate-license
                                  crate-description crate-field-label))
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


;;; Browse mode

(ert-deftest crate-browse-entry ()
  "`crate-browse--entry' returns a proper tabulated-list entry."
  (let ((data (crate-test--data-hash :description "A test crate"
                                     :latest_version "1.0.188")))
    (let ((entry (crate-browse--entry "test-crate" data)))
      (should (equal (car entry) "test-crate"))
      (let ((cols (cadr entry)))
        (should (equal (aref cols 0) "test-crate"))
        (should (equal (aref cols 1) "1.0.188"))
        (should (equal (aref cols 2) "A test crate"))))))

(ert-deftest crate-browse-url-at-point ()
  "Any cell of a row answers the crates.io URL of its crate."
  (let ((data (crate-test--data-hash :latest_version "1.0.0"
                                     :description "framework")))
    (with-temp-buffer
      (crate-browse-mode)
      (setq tabulated-list-entries (list (crate-browse--entry "serde" data)))
      (tabulated-list-print)
      (dolist (text '("serde" "framework"))
        (goto-char (point-min))
        (should (search-forward text nil t))
        (goto-char (match-beginning 0))
        (should (equal (thing-at-point 'url t)
                       (concat crate--crates-io-url "serde")))))))

(ert-deftest crate-browse-binds-url-at-point ()
  "`browse-url-at-point' opens the crates.io page of the row of point."
  (should (eq (lookup-key crate-browse-mode-map (kbd "C-c C-o"))
              #'browse-url-at-point)))

(ert-deftest crate-browse-entries ()
  "`crate-browse--entries' generates entries from `crate--list'."
  (let* ((table (crate-test--crate-table
                 '("htop" :description "process viewer")
                 '("neovim" :description "text editor")))
         (crate--data-cache (make-hash-table :test 'equal)))
    (puthash (list 'data crate-data-path) table crate--data-cache)
    (let ((entries (crate-browse--entries)))
      (should (= (length entries) 2))
      (should (assoc "htop" entries))
      (should (assoc "neovim" entries)))))

(ert-deftest crate-browse-entries-sorted ()
  "`crate-browse--entries' returns entries sorted by name (stable order)."
  (let* ((table (crate-test--crate-table
                 '("htop" :description "process viewer")
                 '("ahash" :description "hash")
                 '("neovim" :description "text editor")))
         (crate--data-cache (make-hash-table :test 'equal)))
    (puthash (list 'data crate-data-path) table crate--data-cache)
    (let ((entries (crate-browse--entries)))
      (should (equal (mapcar #'car entries) '("ahash" "htop" "neovim"))))))

(ert-deftest crate-browse-entries-filter ()
  "`crate-browse--entries' filters by name-list."
  (let* ((table (crate-test--crate-table
                 '("htop" :description "process viewer")
                 '("neovim" :description "text editor")))
         (crate--data-cache (make-hash-table :test 'equal)))
    (puthash (list 'data crate-data-path) table crate--data-cache)
    (let ((entries (crate-browse--entries '("htop"))))
      (should (= (length entries) 1))
      (should (assoc "htop" entries)))))

(ert-deftest crate-browse-current-name ()
  "`crate-browse--current-name' returns the entry at point."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "htop" ["htop" "3.0" "process viewer"])
                (list "neovim" ["neovim" "0.10" "text editor"])))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (equal (crate-browse--current-name) "htop"))))

(ert-deftest crate-browse-current-name-error ()
  "`crate-browse--current-name' signals an error when no entry at point."
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (insert "not an entry\n"))
    (goto-char (point-min))
    (should-error (crate-browse--current-name) :type 'user-error)))

(ert-deftest crate-browse-bookmark-make-record ()
  "Browse bookmark stores name-prefix for live re-derivation, no frozen name-list."
  (with-temp-buffer
    (crate-browse-mode)
    (setq-local crate-browse--name-prefix "serde")
    (let ((rec (crate-browse--bookmark-make-record)))
      (should (string-match-p "serde" (car rec)))
      (should-not (alist-get 'name-list rec))
      (should (equal (alist-get 'name-prefix rec) "serde"))
      ;; The table state travels too.
      (should (equal (alist-get 'sort-key rec) '("Crate")))
      (should (equal (alist-get 'widths rec) '(40 12 0)))
      (should (eq (alist-get 'handler rec) 'crate-browse--bookmark-jump)))))

(ert-deftest crate-browse-restore-state-applies-sort-and-widths ()
  "A jump restores the saved sort key and column widths."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "serde" (vector "serde" "1.0.0" "framework"))))
    (crate-browse--restore-state
     '("Crates: all"
       (name-prefix)
       (sort-key "Version" . t)
       (widths 25 14 0)
       (handler . crate-browse--bookmark-jump)))
    (should (equal tabulated-list-sort-key '("Version" . t)))
    (should (equal (crate-browse--column-widths) '(25 14 0)))
    ;; The restored widths become the base of a later fit.
    (should (equal crate-browse--canonical-widths '(25 14 0)))))

(ert-deftest crate-browse-restore-state-ignores-bad-state ()
  "A stale sort key or a width list of the wrong length is ignored."
  (with-temp-buffer
    (crate-browse-mode)
    (crate-browse--restore-state
     '("Crates: all"
       (sort-key "Gone")
       (widths 25 14)))
    (should (equal tabulated-list-sort-key '("Crate")))
    (should (equal (crate-browse--column-widths) '(40 12 0)))
    ;; The mode leaves the canonical widths at its declared ones.
    (should (equal crate-browse--canonical-widths '(40 12 0))))
  ;; A bookmark without the new fields still opens the table.
  (with-temp-buffer
    (crate-browse-mode)
    (crate-browse--restore-state '("Crates: all" (name-prefix)))
    (should (equal tabulated-list-sort-key '("Crate")))))

(ert-deftest crate-browse-restore-state-skips-non-table-buffer ()
  "A detail buffer ignores table state in a bookmark."
  (with-temp-buffer
    (fundamental-mode)
    (should-not (crate-browse--restore-state
                 '("Crates: all" (sort-key "Version"))))))

(ert-deftest crate-browse-bookmark-make-record-no-prefix ()
  "Browse bookmark with nil name-prefix shows \"all\"."
  (with-temp-buffer
    (crate-browse-mode)
    (setq-local crate-browse--name-prefix nil)
    (let ((rec (crate-browse--bookmark-make-record)))
      (should (string-match-p "all" (car rec)))
      (should-not (alist-get 'name-list rec))
      (should-not (alist-get 'name-prefix rec))
      (should (eq (alist-get 'handler rec) 'crate-browse--bookmark-jump)))))

(ert-deftest crate-browse-bookmark-jump-with-prefix ()
  "`crate-browse--bookmark-jump' re-derives name-list from live cache."
  (let ((called-names nil) (called-prefix :sentinel)
        (table (make-hash-table :test 'equal))
        (crate--data-cache (make-hash-table :test 'equal)))
    ;; Populate cache with matching and non-matching crates.
    (puthash "serde" (crate-test--data-hash :name "serde") table)
    (puthash "serde_derive" (crate-test--data-hash :name "serde_derive") table)
    (puthash "tokio" (crate-test--data-hash :name "tokio") table)
    (puthash (list 'data crate-data-path) table crate--data-cache)
    (cl-letf (((symbol-function 'switch-to-buffer) #'set-buffer)
              ((symbol-function 'crate-browse-crates)
               (lambda (&optional name-list name-prefix)
                 (setq called-names name-list called-prefix name-prefix))))
      ;; Full record shape (name first), as `bookmark-handle-bookmark'
      ;; passes to handlers — `bookmark-prop-get' requires it.
      (crate-browse--bookmark-jump '("Crates: serde"
                                     (name-prefix . "serde")
                                     (handler . crate-browse--bookmark-jump)))
      (should (equal (sort called-names #'string<) '("serde" "serde_derive")))
      (should (equal called-prefix "serde")))))

(ert-deftest crate-browse-bookmark-jump-no-prefix ()
  "`crate-browse--bookmark-jump' with nil prefix opens full table."
  (let ((called-names nil) (called-prefix :sentinel))
    (cl-letf (((symbol-function 'switch-to-buffer) #'set-buffer)
              ((symbol-function 'crate-browse-crates)
               (lambda (&optional name-list name-prefix)
                 (setq called-names name-list called-prefix name-prefix))))
      (crate-browse--bookmark-jump '("Crates: all"
                                     (name-prefix . nil)
                                     (handler . crate-browse--bookmark-jump)))
      (should-not called-names)
      (should-not called-prefix))))


(ert-deftest crate--version-parts-parses-semver ()
  "`crate--version-parts' splits a semver string into numbers."
  (should (equal (crate--version-parts "1.2.3") '(1 2 3 nil)))
  (should (equal (crate--version-parts "0.10.228") '(0 10 228 nil)))
  (should (equal (crate--version-parts "1.0.0-rc.1") '(1 0 0 ("rc" 1))))
  (should (equal (crate--version-parts "1.0.0-alpha.10")
                 '(1 0 0 ("alpha" 10))))
  ;; Build metadata does not affect precedence, so it is dropped.
  (should (equal (crate--version-parts "1.0.0-rc.1+build.5")
                 '(1 0 0 ("rc" 1))))
  (should (equal (crate--version-parts "1.0.0+20130313144700")
                 '(1 0 0 nil)))
  ;; A two- or one-segment version pads the missing parts with 0.
  (should (equal (crate--version-parts "0.1") '(0 1 0 nil)))
  (should (equal (crate--version-parts "1") '(1 0 0 nil)))
  (should (equal (crate--version-parts "0.1-pre.1") '(0 1 0 ("pre" 1))))
  (should-not (crate--version-parts "not a version"))
  (should-not (crate--version-parts "1."))
  (should-not (crate--version-parts nil)))

(ert-deftest crate--version-lessp-numeric-segments ()
  "Numeric segments compare as numbers, not as strings."
  (should (crate--version-lessp "1.9.0" "1.10.0"))
  (should-not (crate--version-lessp "1.10.0" "1.9.0"))
  (should (crate--version-lessp "0.3.1" "0.10.2"))
  (should (crate--version-lessp "1.0.228" "10.0.0"))
  ;; A short version compares as a number, not as a string.
  (should (crate--version-lessp "0.9" "0.10"))
  (should-not (crate--version-lessp "0.10" "0.9")))

(ert-deftest crate--version-lessp-pre-release ()
  "A pre-release sorts before its release, per semver precedence."
  (should (crate--version-lessp "1.0.0-rc.1" "1.0.0"))
  (should-not (crate--version-lessp "1.0.0" "1.0.0-rc.1"))
  (should (crate--version-lessp "1.0.0-alpha" "1.0.0-alpha.1"))
  (should (crate--version-lessp "1.0.0-alpha.9" "1.0.0-alpha.10"))
  ;; A numeric identifier sorts before an alphanumeric one.
  (should (crate--version-lessp "1.0.0-2" "1.0.0-beta"))
  (should (crate--version-lessp "1.0.0-alpha" "1.0.0-beta")))

(ert-deftest crate--version-lessp-fallbacks ()
  "An empty version sorts last and junk falls back to `string<'."
  (should (crate--version-lessp "1.0.0" ""))
  (should-not (crate--version-lessp "" "1.0.0"))
  (should-not (crate--version-lessp "" ""))
  (should (crate--version-lessp "aaa" "bbb")))

(ert-deftest crate-browse-version-lessp-entries ()
  "The Version column predicate reads the entry cells."
  (let ((older (list "a" (vector "a" "1.9.0" "")))
        (newer (list "b" (vector "b" "1.10.0" ""))))
    (should (crate-browse--version-lessp older newer))
    (should-not (crate-browse--version-lessp newer older))
    ;; A missing version cell sorts last instead of signaling.
    (should (crate-browse--version-lessp
             older (list "c" (vector "c" nil ""))))))

(ert-deftest crate-browse-sorts-by-version ()
  "`tabulated-list-print' honors the semver sort predicate."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "c" (vector "c" "1.10.0" ""))
                (list "a" (vector "a" "1.9.0" ""))
                (list "b" (vector "b" "1.0.0-rc.1" ""))))
    (setq tabulated-list-sort-key '("Version" . nil))
    (tabulated-list-print)
    (should (equal (mapcar #'car tabulated-list-entries)
                   '("b" "a" "c")))))

(ert-deftest crate-browse-version-column-sorts-by-semver ()
  "The Version column descriptor names the semver predicate."
  (with-temp-buffer
    (crate-browse-mode)
    (should (eq (nth 2 (aref tabulated-list-format 1))
                'crate-browse--version-lessp))))

(ert-deftest crate-browse-column-widths ()
  "`crate-browse--column-widths' reports one width per column."
  (with-temp-buffer
    (crate-browse-mode)
    (should (equal (crate-browse--column-widths) '(40 12 0)))))

(ert-deftest crate-browse-format-widths-copies ()
  "`crate-browse--format-widths' sets widths without mutating FORMAT."
  (with-temp-buffer
    (crate-browse-mode)
    (let* ((original (copy-tree tabulated-list-format t))
           (widths (crate-browse--format-widths original '(30 9 0))))
      (should (equal (mapcar (lambda (column) (nth 1 column))
                             (append widths nil))
                     '(30 9 0)))
      ;; The source format keeps its widths.
      (should (equal (mapcar (lambda (column) (nth 1 column))
                             (append original nil))
                     '(40 12 0)))
      ;; Column names survive the copy.
      (should (equal (car (aref widths 0)) "Crate")))))

(ert-deftest crate-browse-fit-widths-keeps-wide-columns ()
  "A budget that already fits leaves the widths alone."
  (should (equal (crate-browse--fit-widths '(40 12 0) 200) '(40 12 0))))

(ert-deftest crate-browse-fit-widths-shrinks ()
  "A narrow budget shrinks the Version column, then the Crate column."
  ;; Version stops at 8, Crate stops at `crate-browse-name-min-width'.
  (should (equal (crate-browse--fit-widths '(40 12 0) 170) '(40 12 0)))
  (should (equal (crate-browse--fit-widths '(40 12 0) 60) '(20 8 0)))
  ;; The last column is never touched: it takes the remaining space.
  (should (= (nth 2 (crate-browse--fit-widths '(40 12 0) 40)) 0)))

(ert-deftest crate-browse-content-widths-version-follows-entries ()
  "The Version column grows to the longest visible version."
  (with-temp-buffer
    (crate-browse-mode)
    (let ((entries (list (list "a" (vector "a" "1.0.2280" ""))
                         (list "b" (vector "b" "0.1.0" "")))))
      (should (equal (nth 1 (crate-browse--content-widths entries)) 8)))
    (let ((entries (list (list "a" (vector "a" "1.2.3-alpha.11" "")))))
      (should (equal (nth 1 (crate-browse--content-widths entries)) 14)))
    ;; A bogus long version cannot eat the row.
    (let ((entries (list (list "a" (vector "a" (make-string 60 ?1) "")))))
      (should (equal (nth 1 (crate-browse--content-widths entries))
                     crate-browse-version-max-width)))
    ;; The header label is the floor, so it never truncates.
    (should (equal (nth 1 (crate-browse--content-widths nil))
                   (string-width "Version")))))

(ert-deftest crate-browse-fit-format-fits-selected-window ()
  "`crate-browse--fit-format' records base widths and fits the format."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "a" (vector "a" "1.0.0" ""))))
    (crate-browse--fit-format)
    (should (equal crate-browse--canonical-widths
                   (crate-browse--content-widths tabulated-list-entries)))
    (should (<= (+ (nth 0 (crate-browse--column-widths))
                   (nth 1 (crate-browse--column-widths))
                   tabulated-list-padding 2)
                (window-width (selected-window))))
    ;; A second fit finds nothing to change.
    (should-not (crate-browse--fit (selected-window)))))

(ert-deftest crate-browse-column-resize-comes-from-tabulated-list ()
  "The `{' and `}' resize keys stay with `tabulated-list-mode-map'."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "serde" (vector "serde" "1.0.0" "framework"))))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (eq (lookup-key crate-browse-mode-map "}")
                #'tabulated-list-widen-current-column))
    (should (eq (lookup-key crate-browse-mode-map "{")
                #'tabulated-list-narrow-current-column))
    (tabulated-list-widen-current-column 5)
    (should (equal (nth 1 (aref tabulated-list-format 0)) 45))
    (tabulated-list-narrow-current-column 5)
    (should (equal (nth 1 (aref tabulated-list-format 0)) 40))))

(ert-deftest crate-browse-refit-timer-per-buffer ()
  "A size change schedules one refit per buffer, and a kill cancels it."
  (with-temp-buffer
    (crate-browse-mode)
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (crate-browse--schedule-refit buffer (selected-window))
            (should (timerp crate-browse--fit-timer))
            (let ((first crate-browse--fit-timer))
              ;; A second request reuses the pending timer.
              (crate-browse--schedule-refit buffer (selected-window))
              (should (eq first crate-browse--fit-timer)))
            (crate-browse--cancel-fit)
            (should-not crate-browse--fit-timer))
        (crate-browse--cancel-fit)))))

(ert-deftest crate-browse-refit-skips-a-large-table ()
  "A table above `crate-browse-refit-max-entries' keeps its widths."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "a" (vector "a" "1.0.0" ""))
                (list "b" (vector "b" "1.0.0" ""))
                (list "c" (vector "c" "1.0.0" ""))))
    (let ((buffer (current-buffer))
          (crate-browse-refit-max-entries 2))
      (unwind-protect
          (progn
            (crate-browse--schedule-refit buffer (selected-window))
            (should-not crate-browse--fit-timer)
            ;; A nil cutoff refits every table.
            (let ((crate-browse-refit-max-entries nil))
              (crate-browse--schedule-refit buffer (selected-window))
              (should (timerp crate-browse--fit-timer))))
        (crate-browse--cancel-fit)))))

(ert-deftest crate-browse-window-size-change-skips-other-buffers ()
  "The frame hook ignores a window whose buffer is no crate table."
  (with-temp-buffer
    (fundamental-mode)
    (let ((buffer (current-buffer)))
      (cl-letf (((symbol-function 'window-list)
                 (lambda (&rest _) (list (selected-window))))
                ((symbol-function 'window-buffer)
                 (lambda (&optional _) buffer)))
        (crate-browse--window-size-changed (selected-frame))
        (should-not (buffer-local-value 'crate-browse--fit-timer buffer))))))

(ert-deftest crate-find-crate-switches-buffer-by-default ()
  "A nil `crate-display-buffer-action' keeps `switch-to-buffer'."
  (let ((crate-display-buffer-action nil)
        (crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/mock-crates.db")
        (crate-doc-enable nil)
        (switched nil) (popped nil))
    (crate-test--cache-crate "serde" :name "serde" :latest_version "1.0.0")
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (&rest _) (setq switched t)))
              ((symbol-function 'pop-to-buffer)
               (lambda (&rest _) (setq popped t)))
              ((symbol-function 'cd) #'ignore))
      (find-crate "serde"))
    (should switched)
    (should-not popped)))

(ert-deftest crate-find-crate-honors-display-buffer-action ()
  "`find-crate' routes a display action to `pop-to-buffer'."
  (let ((crate-display-buffer-action crate--other-window-action)
        (crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path "/mock-crates.db")
        (crate-doc-enable nil)
        (action :unset) (name nil))
    (crate-test--cache-crate "serde" :name "serde" :latest_version "1.0.0")
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buffer &optional act) (setq name buffer action act)))
              ((symbol-function 'cd) #'ignore))
      (find-crate "serde"))
    (should (equal name "Crate: serde"))
    (should (equal action crate--other-window-action))))

(ert-deftest crate-browse-open-other-window-passes-action ()
  "`crate-browse-open-other-window' binds the action for one call.
Do not mock `tabulated-list-get-id' here: it is a defsubst, so the
byte-compiled command carries its own copy of the call."
  (let ((crate-display-buffer-action nil)
        (seen-name nil) (seen-action :unset))
    (cl-letf (((symbol-function 'find-crate)
               (lambda (name)
                 (setq seen-name name
                       seen-action crate-display-buffer-action))))
      (with-temp-buffer
        (crate-browse-mode)
        (setq tabulated-list-entries
              (list (list "serde" (vector "serde" "1.0.0" "framework"))))
        (tabulated-list-print)
        (goto-char (point-min))
        (crate-browse-open-other-window)))
    (should (equal seen-name "serde"))
    (should (equal seen-action crate--other-window-action))
    ;; The option itself is untouched.
    (should-not crate-display-buffer-action)))

(ert-deftest crate-browse-display-refuses-non-table-buffer ()
  "`crate-browse--display' signals outside a table buffer."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (crate-browse--display "serde" nil) :type 'user-error)))

(ert-deftest crate-browse-display-refuses-blank-line ()
  "`crate-browse--display' signals on a line without a crate."
  (with-temp-buffer
    (crate-browse-mode)
    (should-error (crate-browse--display nil nil) :type 'user-error)))

(ert-deftest crate-browse-open-other-window-mouse-reads-clicked-row ()
  "The middle button opens the row under the click, not the selection."
  (let ((buffer (get-buffer-create "*Crates mouse*"))
        (crate-display-buffer-action nil)
        (seen-name nil) (seen-action :unset))
    (unwind-protect
        (with-current-buffer buffer
          (crate-browse-mode)
          (setq tabulated-list-entries
                (list (list "ahash" (vector "ahash" "1.0.0" "hash"))
                      (list "serde" (vector "serde" "1.0.0" "framework"))))
          (tabulated-list-print)
          (set-window-buffer (selected-window) buffer)
          ;; The click lands on the first row; point sits on the second.
          (goto-char (point-min))
          (forward-line 1)
          (cl-letf (((symbol-function 'find-crate)
                     (lambda (name)
                       (setq seen-name name
                             seen-action crate-display-buffer-action))))
            (crate-browse-open-other-window-mouse
             (list 'mouse-2 (list (selected-window) (point-min) '(0 . 0) 0)))))
      (kill-buffer buffer))
    (should (equal seen-name "ahash"))
    (should (equal seen-action crate--other-window-action))))

(ert-deftest crate-browse-binds-other-window-keys ()
  "The `o' key and the middle button open a crate elsewhere."
  (should (eq (lookup-key crate-browse-mode-map "o")
              #'crate-browse-open-other-window))
  (should (eq (lookup-key crate-browse-mode-map [mouse-2])
              #'crate-browse-open-other-window-mouse)))

(ert-deftest crate-browse-print-entry-adds-mouse-help ()
  "A printed row explains the mouse and highlights the name cell."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "serde" (vector "serde" "1.0.0" "framework"))))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'help-echo)
                   crate-browse--mouse-help))
    (should (eq (get-text-property (+ (point) tabulated-list-padding)
                                   'mouse-face)
                'highlight))
    ;; The Version cell carries no mouse face.
    (should-not (get-text-property (+ (point) tabulated-list-padding 44)
                                   'mouse-face))))

(ert-deftest crate-browse-click-selects-row ()
  "One click selects a row instead of following a link."
  (should-not (crate-browse--click-selects-row (list 'mouse-1 nil)))
  (should (eq (lookup-key crate-browse-mode-map [follow-link])
              #'crate-browse--click-selects-row)))

(ert-deftest crate-browse-context-menu-lists-row-commands ()
  "A click on a row adds the table commands to the menu."
  (let ((buffer (get-buffer-create "*Crates menu*"))
        (menu (make-sparse-keymap)))
    (unwind-protect
        (with-current-buffer buffer
          (crate-browse-mode)
          (setq tabulated-list-entries
                (list (list "serde" (vector "serde" "1.0.0" "framework"))))
          (tabulated-list-print)
          (set-window-buffer (selected-window) buffer)
          (crate-browse--context-menu
           menu (list 'mouse-3 (list (selected-window) (point-min) '(0 . 0) 0))))
      (kill-buffer buffer))
    (should (lookup-key menu [crate-browse-open]))
    (should (lookup-key menu [crate-browse-open-other-window]))
    (should (lookup-key menu [crate-browse-copy-dependency]))
    (should (lookup-key menu [crate-browse-search-url]))
    (should (lookup-key menu [crate-browse-revert]))))

(ert-deftest crate-browse-context-menu-empty-below-rows ()
  "A click outside the rows leaves the menu to Emacs."
  (let ((buffer (get-buffer-create "*Crates menu empty*"))
        (menu (make-sparse-keymap)))
    (unwind-protect
        (with-current-buffer buffer
          (crate-browse-mode)
          (setq tabulated-list-entries
                (list (list "serde" (vector "serde" "1.0.0" "framework"))))
          (tabulated-list-print)
          (set-window-buffer (selected-window) buffer)
          (crate-browse--context-menu
           menu (list 'mouse-3 (list (selected-window) (point-max) '(0 . 0) 0))))
      (kill-buffer buffer))
    (should-not (lookup-key menu [crate-browse-open]))))

(ert-deftest crate-browse-context-command-restores-buffer-and-point ()
  "A menu command lands in the clicked buffer, on the clicked row."
  (let ((buffer (get-buffer-create "*Crates ctx*"))
        (seen nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (crate-browse-mode)
            (let ((inhibit-read-only t))
              (insert "one\ntwo\nthree\n")))
          (let ((command (crate-browse--context-command
                          7 buffer (lambda () (setq seen (buffer-string))))))
            (with-temp-buffer
              (funcall command)))
          (should (equal seen "one\ntwo\nthree\n"))
          (with-current-buffer buffer
            (should (= (point) 7))))
      (kill-buffer buffer))))

(ert-deftest crate-browse-rows-skips-blank-lines ()
  "`crate-browse--rows' returns one row per entry, in display order."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "ahash" (vector "ahash" "0.8.0" "hash"))
                (list "serde" (vector "serde" "1.0.0" "framework"))))
    (tabulated-list-print)
    (let ((rows (crate-browse--rows)))
      (should (equal (mapcar #'car rows) '("ahash" "serde")))
      (should (equal (aref (cdar rows) 1) "0.8.0")))))

(ert-deftest crate-browse-export-cell-strips-properties ()
  "An exported cell has no faces and no newlines."
  (should (equal (crate-browse--export-cell
                  (propertize "a\nb   c" 'face 'bold))
                 "a b c"))
  (should (equal (crate-browse--export-cell nil) "")))

(ert-deftest crate-browse-export-cargo-lines ()
  "The Cargo export writes one dependency line per row."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "ahash" (vector "ahash" "0.8.11" "hash"))
                (list "serde" (vector "serde" "1.0.228" "framework"))))
    (tabulated-list-print)
    (should (equal (crate-browse--export-cargo (crate-browse--rows))
                   "ahash = \"0.8.11\"\nserde = \"1.0.228\"\n"))))

(ert-deftest crate-browse-export-cargo-missing-version ()
  "A row without a version exports as a wildcard requirement."
  (should (equal (crate-browse--export-cargo
                  (list (cons "foo" (vector "foo" "" ""))))
                 "foo = \"*\"\n"))
  (should (equal (crate-browse--export-cargo nil) "")))

(ert-deftest crate-browse-export-markdown-table ()
  "The Markdown export writes a header, a separator and the rows."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "serde" (vector "serde" "1.0.228" "a | b"))))
    (tabulated-list-print)
    (let ((text (crate-browse--export-markdown (crate-browse--rows))))
      (should (string-prefix-p "| Crate | Version | Description |\n" text))
      (should (string-match-p "^| --- | --- | --- |$" text))
      (should (string-match-p "^| serde | 1.0.228 | a \\\\| b |$" text)))))

(ert-deftest crate-browse-export-markdown-follows-sort ()
  "The Markdown export follows the printed order, not the cache."
  (with-temp-buffer
    (crate-browse-mode)
    (setq tabulated-list-entries
          (list (list "a" (vector "a" "1.9.0" ""))
                (list "b" (vector "b" "1.10.0" ""))))
    (setq tabulated-list-sort-key '("Version" . nil))
    (tabulated-list-print)
    (let ((text (crate-browse--export-markdown (crate-browse--rows))))
      (should (< (string-search "1.9.0" text) (string-search "1.10.0" text))))))

(ert-deftest crate-browse-export-buffer-is-read-only ()
  "An export lands in a read-only buffer that keeps its text."
  (let ((buffer nil))
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (name) (setq buffer (get-buffer name)))))
      (crate-browse--export-buffer "markdown" "| a |\n"))
    (should buffer)
    (with-current-buffer buffer
      (should (eq major-mode 'special-mode))
      (should (equal (buffer-string) "| a |\n"))
      (should buffer-read-only))
    (kill-buffer buffer)))

(ert-deftest crate-browse-export-commands-refuse-other-buffers ()
  "The export commands signal outside a table buffer."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (crate-browse-export-cargo) :type 'user-error)
    (should-error (crate-browse-export-markdown) :type 'user-error)))

(ert-deftest crate-browse-export-keymap-is-bound ()
  "`e' is the export prefix, with c for Cargo.toml and m for Markdown."
  (should (eq (lookup-key crate-browse-mode-map "e")
              crate-browse-export-map))
  (should (eq (lookup-key crate-browse-export-map "c")
              #'crate-browse-export-cargo))
  (should (eq (lookup-key crate-browse-export-map "m")
              #'crate-browse-export-markdown)))

(ert-deftest crate-dependency-line-shapes ()
  "`crate--dependency-line' writes a bare-key TOML line."
  (should (equal (crate--dependency-line "serde" "1.0.0")
                  "serde = \"1.0.0\""))
  (should (equal (crate--dependency-line "async-trait" :null)
                  "async-trait = \"*\""))
  (should (equal (crate--dependency-line "foo" "")
                  "foo = \"*\""))
  (should (equal (crate--dependency-line "foo" nil)
                  "foo = \"*\"")))

;;; End-to-end tests with test data

(defvar crate-test--data-file "@testCratesDb@"
  "Path to the test SQLite database containing serde and tokio.
Substituted at build time by default.nix.")

(defun crate-test--data-ready-p ()
  "Return non-nil if the test data file is available."
  (and (not (string-prefix-p "@" crate-test--data-file))
       (file-readable-p crate-test--data-file)))

(ert-deftest crate-e2e-load-data ()
  "End-to-end: `crate--list' loads the test data file."
  (skip-unless (crate-test--data-ready-p))
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path crate-test--data-file))
    (let ((data (crate--list)))
      (should (hash-table-p data))
      (should (= (hash-table-count data) 2))
      (should (gethash "serde" data))
      (should (gethash "tokio" data)))))

(ert-deftest crate-e2e-find-crate ()
  "End-to-end: `find-crate' displays serde detail buffer."
  (skip-unless (crate-test--data-ready-p))
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path crate-test--data-file)
        (crate-doc-enable nil))    ; skip nix-build in sandbox
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'cd) #'ignore)
              ((symbol-function 'url-knowledge-url) nil))
      (let ((buf (get-buffer-create "*Crate: serde*")))
        (unwind-protect
            (progn
              (switch-to-buffer buf)
              (find-crate "serde")
              (should (eq major-mode 'crate-mode))
              (should (string-match-p "serde" (buffer-string)))
              (should (string-match-p "serialization" (buffer-string)))
              ;; Original name from data, not the lowercased lookup key.
              (should (string-match-p "serde" (buffer-string))))
          (kill-buffer buf))))))

(ert-deftest crate-e2e-browse-crates ()
  "End-to-end: `crate-browse-crates' displays a table with test data."
  (skip-unless (crate-test--data-ready-p))
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-data-path crate-test--data-file))
    (cl-letf (((symbol-function 'switch-to-buffer) #'set-buffer))
      (let ((buf (crate-browse-crates)))
        (with-current-buffer buf
          (should (eq major-mode 'crate-browse-mode))
          (should tabulated-list-entries)
          (should (>= (length tabulated-list-entries) 2))
          (should (assoc "serde" tabulated-list-entries))
          (should (assoc "tokio" tabulated-list-entries)))
        (kill-buffer buf)))))


;;; Dependency copy

(ert-deftest crate-copy-dependency-from-crate-mode ()
  "Copies NAME = \"VERSION\" from crate buffer locals."
  (let ((kill-ring nil) (kill-ring-yank-pointer nil))
    (crate-test--with-crate "serde"
                            (crate-test--data-hash :name "serde"
                                                   :latest_version "1.0.200")
      (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
        (crate-copy-dependency "serde")))
    (should (equal (car kill-ring) "serde = \"1.0.200\""))))

(ert-deftest crate-copy-dependency-from-browse ()
  "Copies the line for the entry at point in `crate-browse-mode'."
  (let ((kill-ring nil) (kill-ring-yank-pointer nil))
    (cl-letf (((symbol-function 'crate--crate)
               (lambda (_name)
                 (crate-test--data-hash :name "tokio" :latest_version "1.40.0")))
              ((symbol-function 'crate-browse--current-name) (lambda () "tokio"))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (with-temp-buffer
        (crate-browse-mode)
        (crate-copy-dependency)))
    (should (equal (car kill-ring) "tokio = \"1.40.0\""))))

(ert-deftest crate-copy-dependency-missing-version ()
  "A missing version falls back to \"*\" (still valid TOML)."
  (let ((kill-ring nil) (kill-ring-yank-pointer nil))
    (cl-letf (((symbol-function 'crate--crate)
               (lambda (_name) (crate-test--data-hash :name "foo")))
              ((symbol-function 'crate-browse--current-name) (lambda () "foo"))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (with-temp-buffer
        (crate-browse-mode)
        (crate-copy-dependency)))
    (should (equal (car kill-ring) "foo = \"*\""))))


;;; Cargo.toml completion

(ert-deftest crate-cargo-capf-in-dependencies ()
  "CAPF bounds and collection work inside [dependencies]."
  (cl-letf (((symbol-function 'crate--match-names)
             (lambda (prefix) (list (concat prefix "-trait")))))
    (with-temp-buffer
      ;; `toml-mode' is external; fake the major mode.
      (setq-local major-mode 'toml-mode)
      (insert "[package]\nname = \"x\"\n\n[dependencies]\nser")
      (let ((capf (crate-cargo-completion-at-point)))
        (should capf)
        (pcase-let ((`(,start ,end ,table) capf))
          (should (equal (buffer-substring start end) "ser"))
          (should (member "ser-trait" (all-completions "ser" table))))))))

(ert-deftest crate-cargo-capf-silent-outside-dependencies ()
  "CAPF stays silent outside dependency sections and TOML modes."
  (with-temp-buffer
    (setq-local major-mode 'toml-mode)
    ;; [package] section.
    (insert "[package]\nna")
    (should-not (crate-cargo-completion-at-point))
    ;; [features] section.
    (erase-buffer)
    (insert "[features]\ndefault = []")
    (should-not (crate-cargo-completion-at-point))
    ;; Dotted sub-table: name already written.
    (erase-buffer)
    (insert "[dependencies.serde]\nversion = \"1\"")
    (goto-char (point-max))
    (should-not (crate-cargo-completion-at-point))
    ;; Non-TOML mode.
    (erase-buffer)
    (setq-local major-mode 'fundamental-mode)
    (insert "[dependencies]\nser")
    (should-not (crate-cargo-completion-at-point))))


;;; Gap-closing tests

(ert-deftest crate-mode-render-of-a-new-buffer-starts-at-the-top ()
  "A first render leaves point at the start of the buffer.
The render erases the buffer and inserts the text, so point would
end at the end of the buffer without a line to keep."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps) #'ignore)
              ((symbol-function 'crate--dependents) #'ignore))
      (with-temp-buffer
        (crate-mode)
        (setq-local crate-name "test-crate")
        (setq-local crate-data (crate-test--data-hash :name "test-crate"))
        (crate--render)
        (should (= (point) (point-min)))
        (should-not (= (point) (point-max)))))))

(ert-deftest crate-mode-render-keeps-point-on-field ()
  "A fresh render keeps point on the same field and column."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--deps) #'ignore)
              ((symbol-function 'crate--dependents) #'ignore)
              ((symbol-function 'crate-doc--json) #'ignore))
      (with-temp-buffer
        (crate-mode)
        (setq-local crate-name "test-crate")
        (setq-local crate-data (crate-test--data-hash
                                :name "test-crate"
                                :latest_version "1.2.3"
                                :license "MIT"))
        (crate--render)
        (goto-char (point-min))
        (search-forward "MIT")
        (goto-char (match-beginning 0))
        (let ((line (line-number-at-pos))
              (column (current-column)))
          (crate--render)
          (should (= (line-number-at-pos) line))
          (should (= (current-column) column))
          (should (equal (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position))
                         "License:       MIT")))))))

(ert-deftest crate-mode-render-keeps-point-on-blank-line ()
  "A blank line leans on the line above it, so it stays put."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps) #'ignore)
              ((symbol-function 'crate--dependents) #'ignore))
      (with-temp-buffer
        (crate-mode)
        (setq-local crate-name "test-crate")
        (setq-local crate-data (crate-test--data-hash :name "test-crate"))
        (crate--render)
        (goto-char (point-max))
        (let ((line (line-number-at-pos)))
          (crate--render)
          (should (= (line-number-at-pos) line))
          (should (string-empty-p
                   (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position)))))))))

(ert-deftest crate-mode-render-keeps-the-line-inside-a-section ()
  "A render keeps the line of point inside its section.
A dependency row is a line of the Dependencies section and not a
section of its own, so a render keeps the offset of point from the
heading, and a row that a new row pushes down moves point with it."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (deps '(("aaa" "^1" "normal" 0)
                ("serde" "^1" "normal" 0))))
    (cl-letf (((symbol-function 'crate--deps) (lambda (_name) deps))
              ((symbol-function 'crate--dependents) #'ignore))
      (with-temp-buffer
        (crate-mode)
        (setq-local crate-name "test-crate")
        (setq-local crate-data (crate-test--data-hash :name "test-crate"))
        (crate--render)
        (goto-char (point-min))
        (search-forward "serde")
        (goto-char (match-beginning 0))
        (let ((column (current-column)))
          (setq deps '(("aaa" "^1" "normal" 0)
                       ("bbb" "^1" "normal" 0)
                       ("serde" "^1" "normal" 0)))
          (crate--render)
          (should (= (current-column) column))
          (should (eq (oref (magit-current-section) type) 'crate-dependencies))
          ;; The line keeps its place, so the row that now sits there
          ;; answers, and not the row that used to.
          (should (equal (thing-at-point 'url t)
                         (concat crate--crates-io-url "bbb"))))))))

(ert-deftest crate-mode-render-keeps-point-on-module-item ()
  "A render keeps point on the same item of the module tree."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--deps) #'ignore)
              ((symbol-function 'crate--dependents) #'ignore)
              ((symbol-function 'crate-doc--json) (lambda (_name) :json))
              ((symbol-function 'crate-doc--module-tree)
               (lambda (_json)
                 '(("root" module
                    (("aaa" struct nil nil)
                     ("zed" struct nil "Zed."))
                    nil)))))
      (with-temp-buffer
        (crate-mode)
        (setq-local crate-name "test-crate")
        (setq-local crate-data (crate-test--data-hash :name "test-crate"))
        (crate--render)
        (goto-char (point-min))
        (search-forward "zed")
        (goto-char (match-beginning 0))
        (crate--render)
        (should (equal (oref (magit-current-section) value) "root/zed"))
        (should (looking-at-p "zed"))))))

(ert-deftest crate-mode-render-keeps-another-window-point ()
  "A render keeps the line of a window that is not selected."
  (let ((buffer (get-buffer-create "*Crate windows*"))
        (crate--data-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let (other position)
          (with-current-buffer buffer
            (crate-mode)
            (setq-local crate-name "test-crate")
            (setq-local crate-data (crate-test--data-hash
                                    :name "test-crate"
                                    :license "MIT"))
            (cl-letf (((symbol-function 'crate--deps) #'ignore)
                      ((symbol-function 'crate--dependents) #'ignore)
                      ((symbol-function 'crate-doc--json) #'ignore))
              (crate--render)))
          (set-window-buffer (selected-window) buffer)
          (setq other (split-window))
          (unwind-protect
              (progn
                (set-window-buffer other buffer)
                (with-current-buffer buffer
                  (setq position (save-excursion
                                   (goto-char (point-min))
                                   (search-forward "MIT")
                                   (match-beginning 0)))
                  (set-window-point other position)
                  ;; The selected window stays at the start of the buffer.
                  (goto-char (point-min))
                  (cl-letf (((symbol-function 'crate--deps) #'ignore)
                            ((symbol-function 'crate--dependents) #'ignore)
                            ((symbol-function 'crate-doc--json) #'ignore))
                    (crate--render))
                  (should (equal (buffer-substring-no-properties
                                  (window-point other)
                                  (+ (window-point other) 3))
                                 "MIT"))
                  (should (= (point) (point-min)))))
            (delete-window other)))
      (kill-buffer buffer))))

(ert-deftest crate-mode-open-link ()
  "RET follows the link at point and signals on plain text."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil)
        (seen nil))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1" "normal" 0))))
              ((symbol-function 'crate--dependents) #'ignore)
              ((symbol-function 'find-crate)
               (lambda (name) (push name seen))))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (goto-char (point-min))
          (search-forward "serde")
          (goto-char (match-beginning 0))
          (push-button)
          (should (equal seen '("serde")))
          ;; Plain text carries no button, and `push-button' does
          ;; nothing there.
          (goto-char (point-min))
          (should-not (push-button))
          (should (equal seen '("serde"))))))))

(ert-deftest crate-mode-open-url-link ()
  "RET on a URL of a detail buffer opens a browser."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil)
        (crate-goto-address t)
        (opened nil))
    (cl-letf (((symbol-function 'crate--deps) #'ignore)
              ((symbol-function 'crate--dependents) #'ignore)
              ((symbol-function 'browse-url)
               (lambda (url &rest _args) (setq opened url))))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash
                               :name "test-crate"
                               :homepage "https://example.com/")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (goto-address-fontify)
          (goto-char (point-min))
          (search-forward "https://example.com/")
          (goto-char (match-beginning 0))
          (call-interactively (key-binding (kbd "RET")))
          (should (equal opened "https://example.com/")))))))

(ert-deftest crate-mode-binds-ret-to-push-button ()
  "RET follows a link, and the button map answers it on a link."
  (should (eq (lookup-key crate-mode-map (kbd "RET"))
              #'push-button)))

;;;###autoload
(defun crate-test--section (type &optional value)
  "Return the section of TYPE with VALUE, or nil.
TYPE is the symbol in the `type' slot, VALUE the value of the
section.  A nil VALUE matches any value."
  (let (found)
    (magit-map-sections
     (lambda (section)
       (when (and (eq (oref section type) type)
                  (or (null value) (equal (oref section value) value)))
         (setq found section))))
    found))

(ert-deftest crate-mode-render-nests-sections ()
  "A detail buffer nests its sections under one root section.
The nine fields come first in `crate-detail-fields' order, then the
group sections of `crate-detail-sections-hook'."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1" "normal" 0))))
              ((symbol-function 'crate--dependents)
               (lambda (_name) '("tokio")))
              ((symbol-function 'crate-doc--json) (lambda (_name) :json))
              ((symbol-function 'crate-doc--module-tree)
               (lambda (_json)
                 '(("root" module (("zed" struct nil nil)) nil)))))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (let* ((root magit-root-section)
                 (children (oref root children)))
            (should (eq (oref root type) 'crate-detail))
            (should (equal (mapcar (lambda (section) (oref section value))
                                   (seq-take children 9))
                           '(name description homepage repository
                             documentation latest_version license downloads
                             updated_at)))
            (should (equal (mapcar (lambda (section) (oref section type))
                                   (seq-drop children 9))
                           '(crate-dependencies crate-dependents
                             crate-modules crate-structure)))
            (let* ((modules (crate-test--section 'crate-modules))
                   (root-module (car (oref modules children)))
                   (item (car (oref root-module children))))
              (should (equal (oref root-module value) "root"))
              (should (eq (oref item type) 'crate-module))
              (should (equal (oref item value) "root/zed")))))))))

(ert-deftest crate-mode-field-labels-carry-no-heading-face ()
  "A field label keeps its colon and wears `crate-field-label'.
A reader tells a field from a foldable section at a glance, so the
label takes no section heading face."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps) #'ignore)
              ((symbol-function 'crate--dependents) #'ignore))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (goto-char (point-min))
          (should (search-forward "Name:" nil t))
          (goto-char (match-beginning 0))
          (should (eq (get-text-property (point) 'face)
                      'crate-field-label)))))))

(ert-deftest crate-mode-section-heading-carries-no-colon ()
  "A group heading ends without a colon and wears the heading face.
A colon would make `magit-insert-child-count' rewrite the heading
after its children recorded their positions."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1" "normal" 0))))
              ((symbol-function 'crate--dependents) #'ignore))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (goto-char (point-min))
          (should (search-forward "Dependencies" nil t))
          (should-not (eq (char-after) ?:))
          (goto-char (match-beginning 0))
          (should (eq (get-text-property (point) 'face)
                      'magit-section-heading)))))))

(ert-deftest crate-mode-section-heading-shows-child-count ()
  "A group heading carries its count when the reader asks for it.
The label keeps the heading face and the number takes the child
count face, the way a Magit heading splits the two."
  (dolist (show '(t nil))
    (let ((crate--data-cache (make-hash-table :test 'equal))
          (crate-doc-enable nil)
          (magit-section-show-child-count show))
      (cl-letf (((symbol-function 'crate--deps)
                 (lambda (_name) '(("serde" "^1" "normal" 0)
                                   ("tokio" "^1" "normal" 0))))
                ((symbol-function 'crate--dependents) #'ignore))
        (crate-test--with-crate "test-crate"
                                (crate-test--data-hash :name "test-crate")
          (with-temp-buffer
            (crate-mode)
            (crate--render)
            (goto-char (point-min))
            (if show
                (progn
                  (should (search-forward "Dependencies (2)" nil t))
                  (let ((space-start (- (point) 4)))
                    (should (eq (get-text-property space-start 'face)
                                'magit-section-child-count))
                    (should (eq (get-text-property (1- space-start) 'face)
                                'magit-section-heading))))
              (should (search-forward "Dependencies" nil t))
              (should (looking-at-p "\n")))))))))

(ert-deftest crate-mode-toggle-section-folds-the-section-of-point ()
  "A fold at a line of a section body hides that body."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1" "normal" 0)
                                 ("tokio" "^1" "normal" 0))))
              ((symbol-function 'crate--dependents) #'ignore))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (goto-char (point-min))
          (search-forward "serde")
          (goto-char (match-beginning 0))
          (let ((section (magit-current-section)))
            (should (eq (oref section type) 'crate-dependencies))
            (let ((row (1- (oref section end))))
              (should-not (invisible-p row))
              (magit-section-toggle section)
              (should (oref section hidden))
              (should (invisible-p row))
              (magit-section-toggle section)
              (should-not (oref section hidden))
              (should-not (invisible-p row)))))))))

(ert-deftest crate-mode-render-restores-folds ()
  "A render keeps the folds of a reader."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1" "normal" 0))))
              ((symbol-function 'crate--dependents) #'ignore))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (goto-char (point-min))
          (search-forward "serde")
          (goto-char (match-beginning 0))
          (magit-section-toggle (magit-current-section))
          (crate--render)
          ;; The heading stays visible, so a search finds the section
          ;; again, and the body of the section stays hidden.
          (goto-char (point-min))
          (search-forward "Dependencies")
          (let ((section (magit-current-section)))
            (should (eq (oref section type) 'crate-dependencies))
            (should (oref section hidden))
            (should (invisible-p (oref section content)))))))))

(ert-deftest crate-mode-binds-toggle-section ()
  "TAB folds the section of point, over a link as well as over text."
  (should (eq (lookup-key crate-mode-map (kbd "TAB"))
              #'magit-section-toggle))
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1" "normal" 0))))
              ((symbol-function 'crate--dependents) #'ignore))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (goto-char (point-min))
          (search-forward "serde")
          (goto-char (match-beginning 0))
          ;; The button keymap of the link keeps RET, and TAB folds.
          (should (eq (key-binding (kbd "TAB")) #'magit-section-toggle))
          (should (eq (key-binding (kbd "RET")) #'push-button)))))))

(ert-deftest crate-mode-links-are-one-button-type ()
  "Every link of a detail buffer is a `crate-link' button.
The type carries the mouse face, so the pointer highlights a
dependency name and the docs.rs fallback alike."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1.0" "normal" 0)))))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (dolist (text '("serde" "https://docs.rs/test-crate"))
            (goto-char (point-min))
            (should (search-forward text nil t))
            (goto-char (match-beginning 0))
            (should (eq (button-type (button-at (point))) 'crate-link))
            (should (eq (get-text-property (point) 'mouse-face)
                        'highlight))))))))

(ert-deftest crate-mode-renders-dependency-buttons ()
  "Dependency rows render with name, req, kind, and optional marker."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1.0" "normal" 0)
                                 ("tokio" "^1" "dev" 1)))))
      (crate-test--with-crate "test-crate"
                              (crate-test--data-hash :name "test-crate")
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (let ((content (buffer-string)))
            (should (string-match-p "Dependencies" content))
            (should (string-match-p "serde" content))
            (should (string-match-p "\\^1\\.0" content))
            (should (string-match-p "dev" content))
            (should (string-match-p "(optional)" content))))))))

(ert-deftest crate-browse-revert-picks-up-new-data ()
  "`revert-buffer' re-derives entries from the live cache."
  (let ((table (crate-test--crate-table '("htop" :name "htop" :description "viewer"))))
    (cl-letf (((symbol-function 'crate--list) (lambda () table)))
      (with-temp-buffer
        (crate-browse-mode)
        (crate-browse--reload)
        (should (assoc "htop" tabulated-list-entries))
        ;; Cache swapped (e.g. new database) — a revert must pick it up.
        (setq table (crate-test--crate-table
                     '("neovim" :name "neovim" :description "editor")))
        (revert-buffer nil t)
        (should (assoc "neovim" tabulated-list-entries))
        (should-not (assoc "htop" tabulated-list-entries))))))

(ert-deftest crate-browse-revert-refits-the-version-column ()
  "A reload sizes the Version column to the new data."
  (let ((table (crate-test--crate-table
                '("htop" :name "htop" :latest_version "1.0.0"))))
    (cl-letf (((symbol-function 'crate--list) (lambda () table)))
      (with-temp-buffer
        (crate-browse-mode)
        (crate-browse--reload)
        (should (equal (nth 1 crate-browse--canonical-widths)
                       (string-width "Version")))
        ;; A longer version must widen the column on the next reload.
        (setq table (crate-test--crate-table
                     '("htop" :name "htop"
                             :latest_version "1.0.0-alpha.1234567890")))
        (revert-buffer nil t)
        (should (equal (nth 1 crate-browse--canonical-widths)
                       (string-width "1.0.0-alpha.1234567890")))
        ;; The printed widths come from the new base, squeezed to the
        ;; window that shows the table.
        (should (equal (crate-browse--column-widths)
                       (crate-browse--fit-widths
                        crate-browse--canonical-widths
                        (window-width (selected-window)))))))))

(ert-deftest crate-browse-search-url-opens-crates-io ()
  "`crate-browse-search-url' opens the entry on crates.io."
  (let ((opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url &rest _) (setq opened url))))
      (with-temp-buffer
        (crate-browse-mode)
        (setq tabulated-list-entries
              (list (list "htop" ["htop" "3.0" "viewer"])))
        (tabulated-list-print)
        (goto-char (point-min))
        (crate-browse-search-url))
      (should (equal opened (concat crate--crates-io-url "htop"))))))

(ert-deftest crate--filter-by-name-substring ()
  "`crate--filter-by-name' matches substrings of published names."
  (cl-letf (((symbol-function 'crate--list)
             (lambda () (crate-test--crate-table
                         '("async-trait" :name "async-trait" :description "macros")
                         '("tokio" :name "tokio" :description "runtime")))))
    ;; Mid-string hit — not prefix matching.
    (should (equal (crate--filter-by-name "sync") '("async-trait")))
    (should (equal (crate--filter-by-name "tok") '("tokio")))))

(ert-deftest crate-bookmark-roundtrip ()
  "Crate bookmark round-trips: make-record then handler jump."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil)
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname)))))
            (find-crate "serde")
            (let* ((buf (get-buffer "Crate: serde"))
                   (rec (with-current-buffer buf
                          (crate--bookmark-make-record-function))))
              (funcall (bookmark-prop-get rec 'handler) rec)
              (should (equal (buffer-name) "Crate: serde"))
              (kill-buffer buf))))
      (delete-file tmpfile))))

(ert-deftest crate-browse-bookmark-roundtrip ()
  "Browse bookmark round-trips: make-record then handler jump."
  (let ((crate--data-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'switch-to-buffer) #'set-buffer)
              ((symbol-function 'crate--list)
               (lambda () (crate-test--crate-table
                           '("serde" :name "serde" :description "serialization")
                           '("serde_derive" :name "serde_derive" :description "macros")
                           '("tokio" :name "tokio" :description "runtime")))))
      (let ((buf (crate-browse-crates nil "serde")))
        (let ((rec (with-current-buffer buf
                     (crate-browse--bookmark-make-record))))
          (funcall (bookmark-prop-get rec 'handler) rec)
          ;; Re-derived filter keeps only matching crates.
          (should (assoc "serde" tabulated-list-entries))
          (should (assoc "serde_derive" tabulated-list-entries))
          (should-not (assoc "tokio" tabulated-list-entries)))
        (kill-buffer buf)))))


;;; SQL-backed completion

(ert-deftest crate--sql-like-escape ()
  "LIKE wildcards in input match literally."
  (should (equal (crate--sql-like-escape "serde_") "serde\\_"))
  (should (equal (crate--sql-like-escape "100%") "100\\%"))
  (should (equal (crate--sql-like-escape "a\\b") "a\\\\b")))

(ert-deftest crate--match-names-prefix-query ()
  "`crate--match-names' queries per call with escaped prefix patterns."
  (let ((captured nil) (pragmas nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) #'ignore)
              ((symbol-function 'sqlite-execute)
               (lambda (_db sql) (push sql pragmas)))
              ((symbol-function 'sqlite-select)
               (lambda (_db _sql params)
                 (setq captured (car params))
                 '(("tokio") ("tokio-macros"))))
              ((symbol-function 'sqlite-close) #'ignore))
      (let ((crate-data-path "/db1.db"))
        (should (equal (crate--match-names "tok") '("tokio" "tokio-macros")))
        ;; Underscore input escaped — never a LIKE wildcard.
        (crate--match-names "tokio_")
        (should (equal captured "tokio\\_%"))
        ;; The prefix is downcased, because the connection makes LIKE
        ;; case-sensitive so that SQLite walks the name btree.
        (crate--match-names "TOKIO_")
        (should (equal captured "tokio\\_%"))
        ;; Every query turns the pragma on first.
        (should (seq-every-p (lambda (sql) (string-match-p "case_sensitive_like" sql))
                             pragmas))))))

(ert-deftest crate--match-names-honors-the-limit ()
  "A short prefix returns at most `crate-completion-limit' names."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-completion-limit 2)
        (tmpfile (crate-test--sqlite-db
                  '("tokio" :name "tokio")
                  '("tokio-auth" :name "tokio-auth")
                  '("tokio-util" :name "tokio-util"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (should (= (length (crate--match-names "tokio")) 2))
          (let ((crate-completion-limit nil))
            (should (= (length (crate--match-names "tokio")) 3))))
      (delete-file tmpfile))))

(ert-deftest crate-completion-collection-matches-prefix ()
  "The collection offers names matching the typed prefix under any style."
  (cl-letf (((symbol-function 'crate--match-names)
             (lambda (prefix)
               (delq nil
                     (mapcar (lambda (n) (when (string-prefix-p prefix n) n))
                             '("async-trait" "tokio"))))))
    (cl-flet ((names (style string)
                (let* ((completion-styles (list style))
                       (res (completion-all-completions
                             string #'crate--collection nil (length string)))
                       acc)
                  (while (consp res)
                    (push (substring-no-properties (car res)) acc)
                    (setq res (cdr res)))
                  acc)))
      ;; basic/partial-completion filter by prefix...
      (should (equal (names 'basic "tok") '("tokio")))
      ;; ...substring/flex query wider and filter themselves.
      (should (member "tokio" (names 'substring "ok"))))))


;;; Canonical names

(ert-deftest crate-find-crate-hyphenated-name ()
  "Hyphenated crate names resolve via canonical keys.
Published name, canonical form, and versioned URL all open the crate."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc-enable nil)
        (tmpfile (crate-test--sqlite-db
                  '("async-trait" :name "async-trait" :description "derive macros"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname)))))
            ;; Published name…
            (find-crate "async-trait")
            (should (get-buffer "Crate: async_trait"))
            (with-current-buffer "Crate: async_trait"
              (should (string-match-p "Name:.*async-trait" (buffer-string))))
            ;; …canonical form…
            (find-crate "async_trait")
            ;; …and a versioned URL all resolve.
            (find-crate "https://crates.io/crates/async-trait/0.1.80")
            (kill-buffer (get-buffer "Crate: async_trait"))))
      (delete-file tmpfile))))

(ert-deftest crate-completion-offers-published-names ()
  "Completion offers published (hyphenated) names; annotate resolves them."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (crate-test--sqlite-db
                  '("async-trait" :name "async-trait" :description "derive macros"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (should (member "async-trait" (crate--match-names "async")))
          (should-not (member "async_trait" (crate--match-names "async")))
          (should (string-match-p "derive macros"
                                  (or (crate--annotate "async-trait") ""))))
      (delete-file tmpfile))))

(ert-deftest crate-browse-entries-show-published-names ()
  "Browse rows use the published name, not the canonical key."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (tmpfile (crate-test--sqlite-db
                  '("async-trait" :name "async-trait" :description "derive macros"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (let ((entries (crate-browse--entries)))
            (should (assoc "async-trait" entries))
            (should-not (assoc "async_trait" entries))))
      (delete-file tmpfile))))


;;; Doc build

(ert-deftest crate-doc-build-missing-nix ()
  "Without `nix-build', no build spawns and the negative caches."
  (let ((crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc--in-flight (make-hash-table :test 'equal))
        (spawns 0))
    (cl-letf (((symbol-function 'crate-doc--nix-path)
               (lambda () "/fake/crate-doc.nix"))
              ((symbol-function 'executable-find) (lambda (_) nil))
              ((symbol-function 'make-process)
               (lambda (&rest _) (cl-incf spawns) 'fake-proc)))
      (should-not (crate-doc--start-build "serde" nil))
      (should (= spawns 0))
      (should (eq (gethash (list "serde" crate-data-path) crate-doc--cache)
                  :failed)))))

(ert-deftest crate-doc-build-spawn-error ()
  "When `make-process' signals, the negative caches and no error escapes."
  (let ((crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc--in-flight (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'crate-doc--nix-path)
               (lambda () "/fake/crate-doc.nix"))
              ((symbol-function 'executable-find) (lambda (_) "/usr/bin/nix-build"))
              ((symbol-function 'make-process)
               (lambda (&rest _)
                 (signal 'file-error '("Searching for program" "nix-build")))))
      (should-not (crate-doc--start-build "serde" nil))
      (should (eq (gethash (list "serde" crate-data-path) crate-doc--cache)
                  :failed)))))

(ert-deftest crate-doc-build-async-does-not-block ()
  "Async build spawns one process, renders progress, and reuses in-flight."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc--in-flight (make-hash-table :test 'equal))
        (crate-doc-enable t)
        (spawns 0)
        (tmpfile (crate-test--sqlite-db '("serde" :name "serde"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname))))
                    ((symbol-function 'executable-find)
                     (lambda (_) "/usr/bin/nix-build"))
                    ((symbol-function 'make-process)
                     (lambda (&rest _) (cl-incf spawns) 'fake-proc)))
            (find-crate "serde")
            (with-current-buffer "Crate: serde"
              (should (string-match-p "build in progress" (buffer-string))))
            (should (= spawns 1))
            ;; Second visit mid-flight: reuses, never re-spawns.
            (find-crate "serde")
            (should (= spawns 1))
            (kill-buffer (get-buffer "Crate: serde"))))
      (delete-file tmpfile))))

(ert-deftest crate-doc-build-stale-result-discarded ()
  "A cache refresh mid-build discards the stale result."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc--in-flight (make-hash-table :test 'equal))
        (crate-doc--generation 0)
        (sentinel nil)
        (tmpfile (crate-test--sqlite-db '("serde" :name "serde"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname))))
                    ((symbol-function 'executable-find)
                     (lambda (_) "/usr/bin/nix-build"))
                    ((symbol-function 'make-process)
                     (lambda (&rest args)
                       (setq sentinel (plist-get args :sentinel))
                       'fake-proc))
                    ((symbol-function 'process-status) (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_) 1)))
            (find-crate "serde")
            (should sentinel)
            ;; Refresh swaps caches and bumps the generation…
            (crate-refresh-cache)
            ;; …then the stale build finishes: result discarded.
            (funcall sentinel 'fake-proc "finished\n")
            (should (= (hash-table-count crate-doc--cache) 0)))
          (kill-buffer (get-buffer "Crate: serde")))
      (delete-file tmpfile))))

(ert-deftest crate-doc-build-failure-caches-failed ()
  "A failed build caches :failed and the buffer reports unavailability."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc--in-flight (make-hash-table :test 'equal))
        (crate-doc--generation 0)
        (sentinel nil)
        (tmpfile (crate-test--sqlite-db '("serde" :name "serde"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname))))
                    ((symbol-function 'executable-find)
                     (lambda (_) "/usr/bin/nix-build"))
                    ((symbol-function 'make-process)
                     (lambda (&rest args)
                       (setq sentinel (plist-get args :sentinel))
                       'fake-proc))
                    ((symbol-function 'process-status) (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_) 1)))
            (find-crate "serde")
            (funcall sentinel 'fake-proc "finished\n")
            (should (eq (gethash (list "serde" crate-data-path) crate-doc--cache)
                        :failed))
            (with-current-buffer "Crate: serde"
              (should (string-match-p "unavailable" (buffer-string)))))
          (kill-buffer (get-buffer "Crate: serde")))
      (delete-file tmpfile))))

(ert-deftest crate-doc-build-success-renders-tree ()
  "A finished build caches the JSON and re-renders the module tree."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc--in-flight (make-hash-table :test 'equal))
        (crate-doc--generation 0)
        (sentinel nil)
        (tmpfile (crate-test--sqlite-db '("serde" :name "serde"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname))))
                    ((symbol-function 'executable-find)
                     (lambda (_) "/usr/bin/nix-build"))
                    ((symbol-function 'make-process)
                     (lambda (&rest args)
                       (setq sentinel (plist-get args :sentinel))
                       'fake-proc))
                    ((symbol-function 'process-status) (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_) 0))
                    ((symbol-function 'crate-doc--json-from-build)
                     (lambda (_out) (json-parse-string "{\"fake\": 1}")))
                    ((symbol-function 'crate-doc--module-tree)
                     (lambda (_json) '(("mymod" module nil nil)))))
            (find-crate "serde")
            (funcall sentinel 'fake-proc "finished\n")
            (should (hash-table-p
                     (gethash (list "serde" crate-data-path) crate-doc--cache)))
            (with-current-buffer "Crate: serde"
              (should (string-match-p "\\[module\\] mymod" (buffer-string)))))
          (kill-buffer (get-buffer "Crate: serde")))
      (delete-file tmpfile))))

(ert-deftest crate-find-crate-degrades-without-nix ()
  "Missing `nix-build' degrades to a status line, not a broken `find-crate'.
The negative result is cached as `:failed' so renders don't re-probe."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc--cache (make-hash-table :test 'equal))
        (crate-doc--in-flight (make-hash-table :test 'equal))
        (crate-doc-enable t)
        (tmpfile (crate-test--sqlite-db
                  '("serde" :name "serde" :description "serialization"))))
    (unwind-protect
        (let ((crate-data-path tmpfile))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (bufname &optional _norecord)
                       (set-buffer (get-buffer-create bufname))))
                    ((symbol-function 'executable-find) (lambda (_) nil))
                    ((symbol-function 'make-process)
                     (lambda (&rest _) (error "Must not spawn"))))
            (find-crate "serde")
            (let ((buf (get-buffer "Crate: serde")))
              (should buf)
              (with-current-buffer buf
                (let ((content (buffer-string)))
                  (should (string-match-p "Name:.*serde" content))
                  (should (string-match-p "unavailable" content))))
              (should (eq (gethash (list "serde" crate-data-path) crate-doc--cache)
                          :failed))
              ;; Cached negative: second visit must not re-probe.
              (find-crate "serde")
              (kill-buffer buf))))
      (delete-file tmpfile))))

(ert-deftest crate-mode-renders-kind-tags ()
  "The module tree renders KIND as a bracketed tag before each name."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable t))
    (crate-test--with-crate "test-crate"
                            (crate-test--data-hash :name "test-crate")
      (cl-letf (((symbol-function 'crate-doc--json) (lambda (_) t))
                ((symbol-function 'crate-doc--module-tree)
                 (lambda (_)
                   '(("mymod" module
                      (("myfn" function nil "Does things.")
                       ("MyType" struct nil nil))
                      nil)))))
        (with-temp-buffer
          (crate-mode)
          (crate--render)
          (let ((content (buffer-string)))
            (should (string-match-p "\\[module\\] mymod" content))
            (should (string-match-p "\\[function\\] myfn" content))
            (should (string-match-p "\\[struct\\] MyType" content))))))))

(ert-deftest crate-doc-module-tree-flat ()
  "`crate-doc--module-tree' on a flat module (no children)."
  (let* ((json (json-parse-string
                "{ \"root\": 1,
                   \"index\": {
                     \"1\": { \"name\": \"my_crate\", \"inner\": {
                       \"module\": { \"is_crate\": true, \"items\": [2,3] }}},
                     \"2\": { \"name\": \"foo\", \"inner\": {
                       \"struct\": {} }},
                     \"3\": { \"name\": \"bar\", \"inner\": {
                       \"function\": {} }}
                   }}"))
         (tree (crate-doc--module-tree json)))
    (should (= (length tree) 2))
    (should (equal (mapcar #'car tree) '("foo" "bar")))
    (should (equal (mapcar #'cadr tree) '(struct function)))
    (should (equal (mapcar (lambda (x) (caddr x)) tree) '(nil nil)))))

(ert-deftest crate-doc-module-tree-nested ()
  "`crate-doc--module-tree' on nested modules."
  (let* ((json (json-parse-string
                "{ \"root\": 0,
                   \"index\": {
                     \"0\": { \"name\": \"root\", \"inner\": {
                       \"module\": { \"is_crate\": true, \"items\": [1] }}},
                     \"1\": { \"name\": \"submod\", \"inner\": {
                       \"module\": { \"is_crate\": false, \"items\": [2,3] }}},
                     \"2\": { \"name\": \"Foo\", \"inner\": {
                       \"struct\": {} }},
                     \"3\": { \"name\": \"Bar\", \"inner\": {
                       \"trait\": {} }}
                   }}"))
         (tree (crate-doc--module-tree json)))
    (should (= (length tree) 1))
    (let ((submod (car tree)))
      (should (equal (car submod) "submod"))
      (should (eq (cadr submod) 'module))
      (let ((children (caddr submod)))
        (should (equal (length children) 2))
        (should (equal (car (car children)) "Foo"))
        (should (equal (car (cadr children)) "Bar"))))))

(ert-deftest crate-doc-module-tree-null-name ()
  "Null-named items (use imports) are present in the tree;
callers must filter them by checking for :null."
  (let* ((json (json-parse-string
                "{ \"root\": 0,
                   \"index\": {
                     \"0\": { \"name\": \"root\", \"inner\": {
                       \"module\": { \"is_crate\": true, \"items\": [1,2] }}},
                     \"1\": { \"name\": null, \"inner\": {
                       \"use\": {} }},
                     \"2\": { \"name\": \"Thing\", \"inner\": {
                       \"enum\": {} }}
                   }}"))
         (tree (crate-doc--module-tree json)))
    (should (= (length tree) 2))
    (should (eq :null (car (car tree))))
    (should (equal (car (cadr tree)) "Thing"))))

(ert-deftest crate-doc-module-tree-empty ()
  "`crate-doc--module-tree' returns nil when JSON lacks a root or index."
  (let ((empty-json (make-hash-table :test 'equal)))
    (should-not (crate-doc--module-tree empty-json)))
  (let* ((json (make-hash-table :test 'equal)))
    (puthash "root" 1 json)
    (puthash "index" (make-hash-table :test 'equal) json)
    (should-not (crate-doc--module-tree json))))

(ert-deftest crate-doc-module-tree-dangling-id ()
  "`crate-doc--module-tree' skips IDs missing from the index instead of crashing."
  (let* ((json (json-parse-string
                "{ \"root\": 0,
                   \"index\": {
                     \"0\": { \"name\": \"root\", \"inner\": {
                       \"module\": { \"is_crate\": true, \"items\": [1,99] }}},
                     \"1\": { \"name\": \"foo\", \"inner\": {
                       \"struct\": {} }}
                   }}"))
         (tree (crate-doc--module-tree json)))
    ;; ID 99 is dangling: item 1 survives, dangling entry is dropped.
    (should (= (length tree) 1))
    (should (equal (car (car tree)) "foo"))))


;;; Local crates

(ert-deftest crate-local-dependency-row-registry ()
  "A registry dependency keeps its requirement and carries no source."
  (let ((row (crate-local--dependency-row
              (crate-test--cargo-dependency "serde" :req "^1.0"
                                            :source "registry+https://index")
              "/crates/mycrate")))
    (should (equal (car row) "serde"))
    (should (equal (nth 1 row) "^1.0"))
    (should (equal (nth 2 row) "normal"))
    (should (= (nth 3 row) 0))
    (should-not (nth 4 row))
    ;; A database row keeps the bare requirement, a local one reads
    ;; like the Cargo.toml line that names it.
    (should (equal (crate--dependency-target row nil) "^1.0"))
    (should (equal (crate--dependency-target row t) "= \"1.0\""))))

(ert-deftest crate-local-dependency-row-path ()
  "A path dependency names its directory and its kind."
  (let ((row (crate-local--dependency-row
              (crate-test--cargo-dependency "my-util" :kind "dev"
                                            :optional t
                                            :path "/crates/my-util")
              "/crates/mycrate")))
    (should (equal (nth 2 row) "dev"))
    (should (= (nth 3 row) 1))
    (should (equal (nth 4 row) '("path" . "../my-util")))
    (should (equal (crate--dependency-target row t)
                   "{ path = \"../my-util\" }"))
    (should (equal (crate--dependency-note row) "  dev  (optional)"))))

(ert-deftest crate-local-dependency-row-git ()
  "A git dependency drops the source scheme and the commit fragment."
  (let* ((row (crate-local--dependency-row
               (crate-test--cargo-dependency
                "some-git" :source "git+https://github.com/x/y#abc1234")
               "/crates/mycrate"))
         (spec (nth 4 row)))
    (should (equal (car spec) "git"))
    (should (equal (cdr spec) "https://github.com/x/y"))
    (should (equal (crate--dependency-target row t)
                   "{ git = \"https://github.com/x/y\" }"))
    (should (equal (crate--dependency-note row) ""))))

(ert-deftest crate-local-package-picks-the-workspace-member ()
  "A workspace directory answers the package whose manifest matches."
  (let* ((dir (make-temp-file "crate-local-ws-" t))
         (manifest (expand-file-name "Cargo.toml" dir))
         (json (crate-test--cargo-metadata
                manifest :name "my-crate" :workspace-mate "/tmp/mate/Cargo.toml")))
    (unwind-protect
        (progn
          (should (= (length (gethash "packages" json)) 2))
          (should (equal (gethash "name" (crate-local--package json manifest))
                         "my-crate")))
      (delete-directory dir t))))

(ert-deftest crate-local-package-follows-a-symlinked-directory ()
  "A directory reached through a symlink answers its own package.
`cargo metadata' answers the canonical manifest path, and an
unresolved comparison then falls back to the first package, which
signals `listp' on the JSON vector."
  (skip-unless (memq system-type '(gnu gnu/linux darwin berkeley-unix)))
  (let* ((dir (make-temp-file "crate-local-real-" t))
         (link (make-temp-file "crate-local-link-")))
    (unwind-protect
        (progn
          (delete-file link)
          (make-symbolic-link dir link)
          (let* ((manifest (crate-local--manifest link))
                 (json (crate-test--cargo-metadata
                        (crate-local--manifest dir)
                        :name "my-crate"
                        :workspace-mate (expand-file-name "mate/Cargo.toml" dir))))
            (should (equal (gethash "name" (crate-local--package json manifest))
                           "my-crate"))))
      (delete-file link)
      (delete-directory dir t))))

(ert-deftest crate-local-package-falls-back-to-the-first-package ()
  "A manifest that no package names answers the first package."
  (let* ((json (crate-test--cargo-metadata "/crates/other/Cargo.toml"
                                          :name "other"
                                          :workspace-mate "/crates/first/Cargo.toml")))
    (should (equal (gethash "name" (crate-local--package
                                    json "/crates/absent/Cargo.toml"))
                   "other"))))

(ert-deftest crate-local-record-maps-metadata ()
  "`crate-local--record' maps `cargo metadata' onto a crate record."
  (crate-test--with-local-crate dir
    (let* ((manifest (expand-file-name "Cargo.toml" dir))
           (json (crate-test--cargo-metadata
                  manifest
                  :name "my-crate"
                  :description "A demo crate."
                  :license "MIT OR Apache-2.0"
                  :dependencies (list (crate-test--cargo-dependency
                                       "serde" :req "^1.0")))))
      (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) json)))
        (let ((record (crate-local--record dir)))
          (should (equal (gethash "name" record) "my-crate"))
          (should (equal (gethash "latest_version" record) "0.3.0"))
          (should (equal (gethash "license" record) "MIT OR Apache-2.0"))
          (should (equal (gethash "description" record) "A demo crate."))
          (should (equal (gethash "path" record) (directory-file-name dir)))
          ;; A JSON null adds no key at all.
          (should-not (gethash "homepage" record))
          (should (= (length (gethash "dependencies" record)) 1)))))))

(ert-deftest crate-local-record-memoized ()
  "A second `crate-local--record' call reuses the metadata of the first."
  (crate-test--with-local-crate dir
    (let* ((manifest (expand-file-name "Cargo.toml" dir))
           (calls 0)
           (json (crate-test--cargo-metadata manifest :name "my-crate")))
      (let ((crate--data-cache (make-hash-table :test 'equal)))
        (cl-letf (((symbol-function 'crate-local--metadata)
                   (lambda (_dir) (cl-incf calls) json)))
          (should (crate-local--record dir))
          (should (crate-local--record dir))
          (should (= calls 1))
          (crate-local--forget dir)
          (should (crate-local--record dir))
          (should (= calls 2)))))))

(ert-deftest crate-local-record-without-cargo ()
  "A directory whose metadata cannot be read answers nil."
  (crate-test--with-local-crate dir
    (let ((crate--data-cache (make-hash-table :test 'equal)))
      (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) nil)))
        (should-not (crate-local--record dir))))))

(ert-deftest crate-local-metadata-uses-the-cargo-option ()
  "`crate-local--metadata' resolves `crate-cargo-program'."
  (let ((crate-cargo-program "/mock/bin/cargo")
        (asked nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program) (setq asked program) nil)))
      (should-not (crate-local--metadata "/crates/mycrate"))
      (should (equal asked "/mock/bin/cargo")))))

(ert-deftest crate-local-metadata-off-with-nil ()
  "A nil `crate-cargo-program' turns the local read off."
  (let ((crate-cargo-program nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) (error "Must not probe for cargo"))))
      (should-not (crate-local--metadata "/crates/mycrate")))))

(ert-deftest crate-local-metadata-parses-the-command ()
  "`crate-local--metadata' runs the documented arguments and parses."
  (let ((crate-cargo-program "cargo")
        (args nil)
        (dir nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) "/mock/bin/cargo"))
              ((symbol-function 'call-process)
               (lambda (_program _infile _destination _display &rest rest)
                 (setq args rest dir default-directory)
                 (insert "{\"packages\": []}")
                 0)))
      (let ((json (crate-local--metadata "/crates/mycrate")))
        (should (equal args '("metadata" "--no-deps" "--offline"
                              "--format-version" "1")))
        (should (equal dir (file-name-as-directory
                            (expand-file-name "/crates/mycrate"))))
        (should (equal (gethash "packages" json) []))))))

(ert-deftest crate-local-read-directory-completes-directories-only ()
  "The prompt completes file names and keeps only directories."
  (let ((dir (make-temp-file "crate-local-read-" t))
        (seen nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "sub" dir))
          (with-temp-file (expand-file-name "file.txt" dir) (insert "x"))
          (let ((candidates (all-completions (file-name-as-directory dir)
                                             #'completion-file-name-table
                                             #'file-directory-p)))
            (should (member "sub/" candidates))
            (should-not (member "file.txt" candidates)))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest args) (setq seen args) (concat dir "sub/"))))
            (should (equal (crate-local--read-directory) (concat dir "sub/"))))
          (should (eq (indirect-function (nth 1 seen))
                      (indirect-function 'completion-file-name-table)))
          (should (eq (indirect-function (nth 2 seen))
                      (indirect-function 'file-directory-p))))
      (delete-directory dir t))))

(ert-deftest crate-visit-directory-shows-the-local-crate ()
  "`crate-visit-directory' renders a detail buffer from local metadata."
  (crate-test--with-local-crate dir
    (let* ((manifest (expand-file-name "Cargo.toml" dir))
           (json (crate-test--cargo-metadata
                  manifest
                  :name "my-crate"
                  :description "A demo crate."
                  :license "MIT"
                  :repository "https://example.com/r"
                  :dependencies
                  (list (crate-test--cargo-dependency "serde" :req "^1.0")
                        (crate-test--cargo-dependency
                               "my-util" :path (expand-file-name "../my-util" dir))))))
      (let ((buffer-name (format "Crate: my_crate (%s)" (directory-file-name dir))))
        (unwind-protect
            (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) json))
                      ((symbol-function 'crate--dependents) #'ignore)
                      ((symbol-function 'crate-doc--start-build)
                       (lambda (&rest _) (error "Local crate must not build")))
                      ((symbol-function 'switch-to-buffer)
                       (lambda (name &optional _norecord)
                         (set-buffer (get-buffer-create name))
                         name)))
              (crate-visit-directory dir)
              (should (equal (buffer-name) buffer-name))
              (should (equal crate-name "my_crate"))
              (should (equal crate-local-path (directory-file-name dir)))
              (should (equal default-directory (file-name-as-directory dir)))
              (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "Version: *0\\.3\\.0" content))
                (should (string-match-p "License: *MIT" content))
                (should (string-match-p "Repository: .*example[.]com/r" content))
                (should (string-match-p "serde *= *\"1[.]0\"" content))
                (should (string-match-p "my-util *[{] path = \"[.][.]/my-util\" }" content))
                ;; No Modules section, because no rustdoc build feeds it.
                (should-not (string-match-p "Modules" content)))
              ;; A registry dependency is still a link, a path one is not.
              (goto-char (point-min))
              (search-forward "serde")
              (goto-char (match-beginning 0))
              (should (equal (thing-at-point 'url t)
                             (concat crate--crates-io-url "serde")))
              (search-forward "my-util")
              (goto-char (match-beginning 0))
              (should-not (thing-at-point 'url t)))
        (when (get-buffer buffer-name) (kill-buffer buffer-name)))))))

(ert-deftest crate-visit-directory-requires-a-manifest ()
  "A directory without `Cargo.toml' signals a user error."
  (let ((dir (make-temp-file "crate-local-empty-" t)))
    (unwind-protect
        (should-error (crate-visit-directory dir) :type 'user-error)
      (delete-directory dir t))))

(ert-deftest crate-visit-directory-requires-cargo-metadata ()
  "A manifest that cargo cannot read signals a user error."
  (crate-test--with-local-crate dir
    (let ((crate--data-cache (make-hash-table :test 'equal)))
      (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) nil)))
        (should-error (crate-visit-directory dir) :type 'user-error)))))

(ert-deftest crate-visit-directory-keeps-the-published-buffer ()
  "A local crate and its published namesake keep separate buffers."
  (crate-test--with-local-crate dir
    (let* ((manifest (expand-file-name "Cargo.toml" dir))
           (local-name (format "Crate: my_crate (%s)" (directory-file-name dir)))
           (json (crate-test--cargo-metadata manifest :name "my-crate"))
           (crate-data-path "/mock-crates.db"))
      (unwind-protect
          (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) json))
                    ((symbol-function 'crate--dependents) #'ignore)
                    ((symbol-function 'crate--crate)
                     (lambda (_name) (crate-test--data-hash :name "my-crate")) )
                    ((symbol-function 'crate--database-readable-p) (lambda () t))
                    ((symbol-function 'switch-to-buffer)
                     (lambda (name &optional _norecord)
                       (set-buffer (get-buffer-create name))
                       name)))
            (find-crate "my-crate")
            (crate-visit-directory dir)
            (should (get-buffer "Crate: my_crate"))
            (should (get-buffer local-name))
            (should-not (eq (get-buffer "Crate: my_crate")
                            (get-buffer local-name))))
        (when (get-buffer local-name) (kill-buffer local-name))
        (when (get-buffer "Crate: my_crate") (kill-buffer "Crate: my_crate"))))))

(ert-deftest crate-visit-directory-revert-rereads-the-manifest ()
  "`g' reads the metadata again, so an edited crate shows the edit."
  (crate-test--with-local-crate dir
    (let* ((manifest (expand-file-name "Cargo.toml" dir))
           (first (crate-test--cargo-metadata manifest :description "Old."))
           (second (crate-test--cargo-metadata manifest :description "New.")
                   )
           (json first)
           (buffer-name (format "Crate: my_crate (%s)" (directory-file-name dir))))
      (unwind-protect
          (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) json))
                    ((symbol-function 'crate--dependents) #'ignore)
                    ((symbol-function 'switch-to-buffer)
                     (lambda (name &optional _norecord)
                       (set-buffer (get-buffer-create name))
                       name)))
            (crate-visit-directory dir)
            (should (string-match-p "Old\." (buffer-string)))
            (setq json second)
            (crate--revert)
            (should (string-match-p "New\." (buffer-string)))
            (should-not (string-match-p "Old\." (buffer-string))))
        (when (get-buffer buffer-name) (kill-buffer buffer-name))))))

(ert-deftest crate-visit-hook-runs-for-a-local-crate ()
  "`crate-visit-hook' fires once in the local crate buffer."
  (crate-test--with-local-crate dir
    (let* ((manifest (expand-file-name "Cargo.toml" dir))
           (json (crate-test--cargo-metadata manifest :name "my-crate"))
           (buffer-name (format "Crate: my_crate (%s)" (directory-file-name dir)))
           (seen nil))
      (unwind-protect
          (let ((crate-visit-hook nil))
            (add-hook 'crate-visit-hook
                      (lambda ()
                        (push (list (buffer-name) crate-name crate-local-path)
                              seen)))
            (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) json))
                      ((symbol-function 'crate--dependents) #'ignore)
                      ((symbol-function 'switch-to-buffer)
                       (lambda (name &optional _norecord)
                         (set-buffer (get-buffer-create name))
                         name)))
              (crate-visit-directory dir))
            (should (equal seen
                           (list (list buffer-name "my_crate"
                                       (directory-file-name dir))))))
        (when (get-buffer buffer-name) (kill-buffer buffer-name))))))

(ert-deftest crate-local-crate-bookmark-round-trip ()
  "A local crate bookmark records its directory and reopens it."
  (crate-test--with-local-crate dir
    (let ((path (directory-file-name dir))
          (json (crate-test--cargo-metadata
                 (expand-file-name "Cargo.toml" dir) :name "my-crate"))
          (seen nil))
      (cl-letf (((symbol-function 'crate-local--metadata) (lambda (_dir) json))
                ((symbol-function 'crate--dependents) #'ignore)
                ((symbol-function 'crate--description) (lambda () "desc"))
                ((symbol-function 'switch-to-buffer)
                 (lambda (name &optional _norecord)
                        (set-buffer (get-buffer-create name))
                        name)))
        (let ((buffer-name (format "Crate: my_crate (%s)" path)))
          (unwind-protect
              (progn
                (crate-visit-directory dir)
                (let ((record (crate--bookmark-make-record-function)))
                  (should (equal (bookmark-prop-get record 'directory) path))
                  (should (equal (bookmark-prop-get record 'crate) "my_crate"))
                  (should (string-match-p (regexp-quote path) (car record)))
                  (cl-letf (((symbol-function 'crate-visit-directory)
                             (lambda (d) (setq seen d))))
                    (crate-bookmark-jump record))
                  (should (equal seen path))))
            (when (get-buffer buffer-name) (kill-buffer buffer-name))))))))

(provide 'crate-test)
;;; crate-test.el ends here
