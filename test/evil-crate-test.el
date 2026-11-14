;;; evil-crate-test.el --- Tests of the optional evil layer -*- lexical-binding: t -*-

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
;;
;; Load the file in a batch Emacs, then run the tests with
;; `ert-run-tests-batch-and-exit'.  The Nix checkPhase loads every
;; `test/*-test.el' file through a glob, so no file lists it by name.

;;; Code:

(require 'ert)
(require 'evil)
(require 'crate)
(require 'crate-tree)
(require 'evil-crate)

(defun crate-evil-test--binding (mode key &optional visual)
  "In a buffer in MODE under evil, return the command bound to KEY.
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
              #'push-button))
  (should (eq (crate-evil-test--binding #'crate-mode "TAB")
              #'magit-section-toggle))
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
    (cl-letf (((symbol-function 'crate--deps)
               (lambda (_name) '(("serde" "^1" "normal" 0))))
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
        (search-forward "serde")
        (goto-char (match-beginning 0))
        (let ((section (magit-current-section)))
          (should (eq (oref section type) 'crate-dependencies))
          (evil-close-fold)
          (should (oref section hidden))
          (evil-open-fold)
          (should-not (oref section hidden)))))))

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

;;; The crate tree

(defun crate-evil-test--tree-root ()
  "Return a tiny crate tree for the tree tests."
  (let* ((connect (crate-tree-item--create
                   :path "harness::api::net::connect"
                   :name "connect" :kind 'function
                   :kind-word "fn" :vis-word "pub"))
         (net (crate-tree-item--create
               :path "harness::api::net" :name "net" :kind 'module
               :kind-word "mod" :vis-word "pub"
               :children (list connect)))
         (api (crate-tree-item--create
               :path "harness::api" :name "api" :kind 'module
               :kind-word "mod" :vis-word "pub"
               :children (list net))))
    (crate-tree-item--create
     :path "harness" :name "harness" :kind 'module
     :kind-word "crate" :vis-word "pub"
     :children (list api))))

(defmacro crate-evil-test--with-tree (&rest body)
  "Run BODY in a tree buffer with evil in the normal state."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (crate-tree-mode)
     (setq-local crate-tree--root (crate-evil-test--tree-root))
     (setq-local crate-tree--name "harness")
     (crate-tree--reprint)
     (crate-evil--maybe-enable)
     (evil-local-mode 1)
     (evil-normal-state)
     ,@body))

(defun crate-evil-test--goto (path)
  "Move point to the tree row of PATH."
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

(ert-deftest crate-evil-local-mode-tree ()
  "A tree buffer adopts the tree bindings alone."
  (crate-evil-test--with-tree
    (should crate-evil-tree-mode)
    (should-not crate-evil-detail-mode)
    (should-not crate-evil-browse-mode)))

(ert-deftest crate-evil-tree-keys ()
  "The state map reaches the tree commands that evil shadows."
  (crate-evil-test--with-tree
    (should (eq (key-binding (kbd "TAB")) #'crate-tree-toggle))
    (should (eq (key-binding (kbd "s")) #'crate-tree-sort))
    (should (eq (key-binding (kbd "S")) #'crate-tree-reverse-sort))
    (should (eq (key-binding (kbd "y")) #'crate-tree-copy-path))
    (should (eq (key-binding (kbd "w")) #'crate-tree-copy-dependency))
    (should (eq (key-binding (kbd "RET")) #'crate-tree-visit))
    (should (eq (key-binding (kbd "gr")) #'revert-buffer))
    (should (eq (key-binding (kbd "C-c C-o")) #'crate-tree-browse-url))
    (should (eq (key-binding (kbd "fp")) #'crate-tree-toggle-public))
    (should (eq (key-binding (kbd "fk")) #'crate-tree-kind-filter))
    (should (eq (key-binding (kbd "ff")) #'crate-tree-focus))
    (should (eq (key-binding (kbd "fr")) #'crate-tree-reset-filters))))

(ert-deftest crate-evil-tree-depth-keys ()
  "A digit key sets the depth of the table."
  (crate-evil-test--with-tree
    (call-interactively (key-binding (kbd "2")))
    (should (equal crate-tree--max-depth 1))
    (call-interactively (key-binding (kbd "9")))
    (should-not crate-tree--max-depth)))

(ert-deftest crate-evil-tree-fold-keys ()
  "The evil fold commands close and open a tree row."
  (crate-evil-test--with-tree
    (crate-evil-test--goto "harness::api")
    (evil-close-fold)
    (should (gethash "harness::api" crate-tree--folded))
    (should-not (member "harness::api::net"
                        (mapcar #'car tabulated-list-entries)))
    (crate-evil-test--goto "harness::api")
    (evil-open-fold)
    (should-not (gethash "harness::api" crate-tree--folded))
    (should (member "harness::api::net"
                    (mapcar #'car tabulated-list-entries)))))

(ert-deftest crate-evil-tree-disable ()
  "The helper disables the tree bindings again."
  (crate-evil-test--with-tree
    (crate-evil--disable)
    (should-not crate-evil-tree-mode)))


(provide 'evil-crate-test)

;;; evil-crate-test.el ends here
