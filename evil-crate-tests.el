;;; evil-crate-tests.el --- Tests of the optional evil layer -*- lexical-binding: t -*-

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

;; Tests of evil-crate.el.  Evil is a build-time test dependency, not
;; a package dependency.

;;; Code:

(require 'ert)
(require 'evil)
(require 'crate)
(require 'evil-crate)

(defun crate-evil-test--binding (mode key &optional visual)
  "Return the command that KEY runs in a buffer with MODE and evil.
VISUAL selects a visual line state instead of the normal state."
  (with-temp-buffer
    (funcall mode)
    (crate-evil--maybe-enable)
    (evil-local-mode 1)
    (if visual (evil-visual-line) (evil-normal-state))
    (key-binding (kbd key))))

(ert-deftest crate-evil-modes-defined ()
  "The global mode and the two local modes exist."
  (should (fboundp 'crate-evil-mode))
  (should (fboundp 'crate-evil-detail-mode))
  (should (fboundp 'crate-evil-browse-mode)))

(ert-deftest crate-evil-local-mode-detail ()
  "A detail buffer adopts the detail bindings."
  (with-temp-buffer
    (crate-mode)
    (crate-evil--maybe-enable)
    (should crate-evil-detail-mode)
    (should-not crate-evil-browse-mode)))

(ert-deftest crate-evil-local-mode-browse ()
  "A browse buffer adopts the browse bindings."
  (with-temp-buffer
    (crate-browse-mode)
    (crate-evil--maybe-enable)
    (should crate-evil-browse-mode)
    (should-not crate-evil-detail-mode)))

(ert-deftest crate-evil-local-mode-disable ()
  "The helper disables both local modes again."
  (with-temp-buffer
    (crate-mode)
    (crate-evil-detail-mode 1)
    (crate-evil--disable)
    (should-not crate-evil-detail-mode)
    (should-not crate-evil-browse-mode)))

(ert-deftest crate-evil-detail-keys-remap ()
  "The detail bindings reach the crate commands through a remap."
  (should (eq (crate-evil-test--binding #'crate-mode "RET")
              #'crate-open-at-point))
  (should (eq (crate-evil-test--binding #'crate-mode "TAB")
              #'crate-toggle-section))
  (should (eq (crate-evil-test--binding #'crate-mode "q")
              #'quit-window))
  (should (eq (crate-evil-test--binding #'crate-mode "gr")
              #'revert-buffer))
  (should (eq (crate-evil-test--binding #'crate-mode "r")
              #'revert-buffer-quick))
  (should (eq (crate-evil-test--binding #'crate-mode "R")
              #'revert-buffer-quick))
  (should (eq (crate-evil-test--binding #'crate-mode "c")
              #'crate-evil-open-web))
  (should (eq (crate-evil-test--binding #'crate-mode "y")
              #'crate-copy-dependency))
  (should (eq (crate-evil-test--binding #'crate-mode "Y")
              #'crate-copy-dependency)))

(ert-deftest crate-evil-browse-keys-remap ()
  "The browse bindings reach the table commands through a remap."
  (should (eq (crate-evil-test--binding #'crate-browse-mode "RET")
              #'crate-browse-visit))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "o")
              #'crate-browse-open-other-window))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "c")
              #'crate-browse-search-url))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "y")
              #'crate-copy-dependency))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "S")
              #'tabulated-list-sort))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "gc")
              #'crate-browse-export-cargo))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "gm")
              #'crate-browse-export-markdown))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "q")
              #'quit-window))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "gr")
              #'revert-buffer))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "gc" 'visual)
              #'crate-browse-export-cargo))
  (should (eq (crate-evil-test--binding #'crate-browse-mode "y" 'visual)
              #'crate-evil-browse-copy-dependencies)))

(ert-deftest crate-evil-browse-copy-dependencies ()
  "A visual range copies one dependency line per row."
  (with-temp-buffer
    (crate-browse-mode)
    (setq-local tabulated-list-entries
                (list (list "serde" (vector "serde" "1.0.219" "framework"))
                      (list "tokio" (vector "tokio" "1.40.0" "runtime"))))
    (tabulated-list-print)
    (let ((kill-ring nil))
      (crate-evil-browse-copy-dependencies (point-min) (point-max))
      (should (equal (car kill-ring) "serde = \"1.0.219\"\ntokio = \"1.40.0\"")))))

(ert-deftest crate-evil-browse-copy-dependencies-empty ()
  "A selection without a row signals."
  (with-temp-buffer
    (crate-browse-mode)
    (should-error (crate-evil-browse-copy-dependencies (point-min) (point-max))
                  :type 'user-error)))

(ert-deftest crate-evil-fold-keys-reach-sections ()
  "The evil fold commands close and open a crate section."
  (let ((crate--data-cache (make-hash-table :test 'equal))
        (crate-doc-enable nil))
    (cl-letf (((symbol-function 'crate--deps) #'ignore)
              ((symbol-function 'crate--dependents) #'ignore))
      (with-temp-buffer
        (crate-mode)
        (crate-evil--maybe-enable)
        (evil-local-mode 1)
        (evil-normal-state)
        (setq-local crate-name "test-crate")
        (setq-local crate-data
                    (let ((table (make-hash-table :test 'equal)))
                      (puthash "name" "test-crate" table)
                      (puthash "license" "MIT" table)
                      table))
        (crate--render)
        (goto-char (point-min))
        (evil-close-fold)
        (should (equal (crate--collapsed-sections) '(fields)))
        (evil-open-fold)
        (should-not (crate--collapsed-sections))))))

(ert-deftest crate-evil-open-web ()
  "The c command opens the crates.io page of the crate."
  (let ((opened nil)
        (crate-name "serde"))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url &rest _args) (setq opened url))))
      (with-temp-buffer
        (crate-mode)
        (crate-evil-open-web)
        (should (equal opened (concat crate--crates-io-url "serde")))))))

(ert-deftest crate-evil-remap-follows-command ()
  "A remap keeps the crate command on a new key of the evil command."
  (keymap-set evil-normal-state-map "C-c C-r" #'evil-ret)
  (unwind-protect
      (should (eq (crate-evil-test--binding #'crate-browse-mode "C-c C-r")
                  #'crate-browse-visit))
    (keymap-unset evil-normal-state-map "C-c C-r")))

(ert-deftest crate-evil-remap-stays-local ()
  "A buffer without a crate mode keeps the plain evil command."
  (with-temp-buffer
    (evil-local-mode 1)
    (evil-normal-state)
    (should (eq (key-binding (kbd "RET")) #'evil-ret))))

(ert-deftest crate-evil-auto-enable-default ()
  "The bindings install without an explicit call by default."
  (should (default-value 'crate-evil-auto-enable)))

(ert-deftest crate-evil-auto-setup-on ()
  "The auto setup turns the global mode on when the option allows it."
  (let ((crate-evil-auto-enable t))
    (unwind-protect
        (progn
          (crate-evil-auto-setup)
          (should crate-evil-mode))
      (crate-evil-mode -1))))

(ert-deftest crate-evil-auto-setup-off ()
  "The auto setup leaves the global mode off when the option says no."
  (let ((crate-evil-auto-enable nil))
    (crate-evil-mode -1)
    (unwind-protect
        (progn
          (crate-evil-auto-setup)
          (should-not crate-evil-mode))
      (crate-evil-mode -1))))

(ert-deftest crate-evil-mode-follows-existing-buffers ()
  "Enabling the global mode reaches an existing crate buffer."
  (let ((buffer (get-buffer-create "*Crate evil*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (crate-mode))
          (unwind-protect
              (progn
                (crate-evil-mode 1)
                (with-current-buffer buffer
                  (should crate-evil-detail-mode)))
            (crate-evil-mode -1))
          (with-current-buffer buffer
            (should-not crate-evil-detail-mode)))
      (kill-buffer buffer))))

(provide 'evil-crate-tests)

;;; evil-crate-tests.el ends here
