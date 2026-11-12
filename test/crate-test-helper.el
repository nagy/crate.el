;;; crate-test-helper.el --- Shared fixtures for the crate test suites -*- lexical-binding: t -*-

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

;; Shared fixtures and stubs for the crate ERT suites.  The file name
;; does not match `*-test.el' on purpose: the Nix checkPhase loads the
;; suite files through a `test/*-test.el' glob, and a helper that
;; matched the glob would run as an empty test file.  Each suite
;; requires this feature by name instead.

;;; Code:

(require 'crate)
(require 'cl-lib)

(defun crate-test--sqlite-db (&rest entries)
  "Create a temporary SQLite database with mock crate data.
ENTRIES are (KEY . PLIST) pairs where PLIST contains keyword-value
pairs like :description \"foo\".  Returns the path to the .db file."
  (let ((dbpath (make-temp-file "crate-test-" nil ".db"))
        db)
    (setq db (sqlite-open dbpath))
    (sqlite-execute db "CREATE TABLE crates (
  name TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  description TEXT,
  documentation TEXT,
  homepage TEXT,
  repository TEXT,
  created_at TEXT,
  updated_at TEXT,
  latest_version TEXT,
  license TEXT,
  downloads INTEGER NOT NULL DEFAULT 0,
  trustpub_only INTEGER NOT NULL DEFAULT 0
) STRICT, WITHOUT ROWID")
    (sqlite-execute db "CREATE TABLE dependencies (
  id INTEGER PRIMARY KEY,
  crate_name TEXT NOT NULL,
  dep_name TEXT NOT NULL,
  req TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'normal',
  optional INTEGER NOT NULL DEFAULT 0
) STRICT")
    (dolist (e entries)
      (let* ((plist (cdr e))
             (name (car e))
             (desc (plist-get plist :description))
             (homepage (plist-get plist :homepage))
             (documentation (plist-get plist :documentation))
             (repository (plist-get plist :repository))
             (created_at (plist-get plist :created_at))
             (updated_at (plist-get plist :updated_at))
             (version (plist-get plist :latest_version))
             (license (plist-get plist :license))
             (downloads (or (plist-get plist :downloads) 0)))
        (sqlite-execute db "INSERT INTO crates VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
                        (list name name desc documentation homepage
                              repository created_at updated_at
                              version license downloads 0))))
    (sqlite-close db)
    dbpath))

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
the return value of `crate--list'."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (e entries table)
      (let ((inner (make-hash-table :test 'equal)))
        (cl-loop for (prop val) on (cdr e) by #'cddr
                 do (puthash (substring (symbol-name prop) 1) val inner))
        (puthash (car e) inner table)))))

(defmacro crate-test--with-crate (name data &rest body)
  "Bind `crate-name' to NAME and `crate-data' to DATA, then evaluate BODY.
DATA should be a hash table of field keys to values (the inner
record, not the top-level crate table)."
  (declare (indent 2))
  `(let ((crate-name ,name)
         (crate-data ,data))
     ,@body))

(provide 'crate-test-helper)
;;; crate-test-helper.el ends here
