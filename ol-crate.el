;;; ol-crate.el --- Org links to Rust crates -*- lexical-binding: t -*-

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

;; Org link type for crate.el.
;;
;;   [[crate:serde]]
;;
;; Loaded automatically via `with-eval-after-load' in crate.el.

;;; Code:

(require 'ol)

(declare-function find-crate "crate")

(defvar crate-name)
(defvar crate-mode)
(defvar crate--crates-io-url)

(defun crate--org-store-link (_interactive-p)
  "Store a `crate:' link when in `crate-mode'."
  (when (eq major-mode 'crate-mode)
    (org-link-store-props :type "crate"
                          :link (format "crate:%s" crate-name)
                          :description
                          (format "Rust Crate: %s" crate-name))
    t))

(defun crate-org-export (path description backend _info)
  "Export a `crate:' link to crates.io.
PATH is the crate name, DESCRIPTION is the link text,
BACKEND is the export backend."
  (let ((url (format "%s%s" crate--crates-io-url
                     (url-hexify-string path)))
        (desc (or description path)))
    (pcase backend
      ('html (format "<a href=\"%s\">%s</a>" url desc))
      ('latex (format "\\href{%s}{%s}" url desc))
      (_ desc))))

(org-link-set-parameters "crate"
                         :follow #'find-crate
                         :store #'crate--org-store-link
                         :export #'crate-org-export)

(provide 'ol-crate)
;;; ol-crate.el ends here
