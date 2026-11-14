;;; evil-crate.el --- Evil bindings for crate -*- lexical-binding: t -*-

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

;; Optional evil integration.  The file needs evil, but the package
;; does not declare it, so a user without evil installs nothing.
;; crate.el loads this file when evil loads:
;;
;;   (with-eval-after-load 'evil (require 'evil-crate))
;;
;; and `crate-evil-auto-enable' enables the bindings at that moment.
;; A user who has no evil never loads this file.
;;
;; The mode installs one local minor mode per crate buffer.  Evil
;; state maps take precedence over a major mode map, so every command
;; key needs a state binding to reach the buffer.  The evil motions
;; stay untouched: j, k, gg, G, C-d, C-u, /, n and N keep their
;; meaning.
;;
;; Every key that evil already binds goes through a key remap of the
;; evil command, for example [remap evil-ret].  A remap follows the
;; command and not the key, so a user who moves evil-ret to another
;; key keeps the crate behavior on the new key.  A key with no evil
;; command, such as gr, stays a plain key binding.
;;
;; Detail buffers: RET opens the link at point; TAB folds the section
;; of point; q quits the window; gr, r and R refresh; c opens the
;; crates.io page; y and Y copy a Cargo.toml dependency line.
;;
;; Browse buffers: RET opens the row; o opens it in another window; y
;; and Y copy a dependency line; c opens the crates.io page; S sorts
;; the column at point; gc and gm export the visible rows; q quits
;; the window; gr, r and R refresh.  A visual line selection followed
;; by y copies the dependency lines of every selected row.
;;
;; The fold commands of evil reach the sections too: zc closes, zo
;; opens and za toggles the section of point.  `evil-fold-list' holds
;; an entry for `outline-minor-mode' and none for a Magit section
;; buffer, and `evil--mode-p' compares the major mode itself, so this
;; file adds a `crate-mode' entry of its own.

;;; Code:

;; The file loads from crate.el when evil loads, so crate.el is always
;; loaded first.  A plain `(require 'crate)' here would recurse through
;; `with-eval-after-load' while crate.el is still loading.
(require 'evil)

(declare-function crate--dependency-line "crate" (name version))
(declare-function crate-browse--cell-text "crate" (cell))
(declare-function crate-browse-export-cargo "crate" ())
(declare-function crate-browse-export-markdown "crate" ())
(declare-function crate-browse-open-other-window "crate" ())
(declare-function crate-browse-search-url "crate" ())
(declare-function crate-browse-visit "crate" ())
(declare-function crate-copy-dependency "crate" (&optional name))
(defvar crate--crates-io-url)
(defvar crate-name)
(defvar magit-root-section)

(defcustom crate-evil-auto-enable t
  "Non-nil if the evil bindings load without an explicit call.
Set this option to nil before evil loads to keep the bindings off
until a user calls `crate-evil-mode'."
  :type 'boolean
  :group 'crate)

;;; Keys

(defvar crate-evil-detail-keys
  '(([remap evil-ret] . push-button)
    ;; TAB is C-i, the jump of the evil jump list, in the normal
    ;; state.  A detail buffer folds the section of point instead.
    ("TAB" . magit-section-toggle)
    ([remap evil-record-macro] . quit-window)
    ("gr" . revert-buffer)
    ([remap evil-replace] . revert-buffer-quick)
    ([remap evil-enter-replace-state] . revert-buffer-quick)
    ([remap evil-change] . crate-evil-open-web)
    ([remap evil-yank] . crate-copy-dependency)
    ([remap evil-yank-line] . crate-copy-dependency))
  "Keys that `crate-evil-mode' binds in detail buffers.")

(defvar crate-evil-browse-keys
  '(([remap evil-ret] . crate-browse-visit)
    ([remap evil-open-below] . crate-browse-open-other-window)
    ([remap evil-change] . crate-browse-search-url)
    ([remap evil-yank] . crate-copy-dependency)
    ([remap evil-yank-line] . crate-copy-dependency)
    ([remap evil-change-whole-line] . tabulated-list-sort)
    ([remap evil-record-macro] . quit-window)
    ("gr" . revert-buffer)
    ("gc" . crate-browse-export-cargo)
    ("gm" . crate-browse-export-markdown)
    ([remap evil-replace] . revert-buffer-quick)
    ([remap evil-enter-replace-state] . revert-buffer-quick))
  "Keys that `crate-evil-mode' binds in browse buffers.")

(defvar crate-evil-browse-visual-keys
  '(([remap evil-yank] . crate-evil-browse-copy-dependencies))
  "Keys that `crate-evil-mode' binds in visual state of browse buffers.")

(defun crate-evil-open-web ()
  "Open the crates.io page of the crate of the current buffer."
  (interactive nil crate-mode)
  (browse-url (concat crate--crates-io-url crate-name)))

(defun crate-evil--row-dependency-line ()
  "Return the `Cargo.toml' line of the table row at point."
  (let ((name (tabulated-list-get-id)))
    (when name
      (crate--dependency-line
       name
       (crate-browse--cell-text (aref (tabulated-list-get-entry) 1))))))

(defun crate-evil-browse-copy-dependencies (start end)
  "Copy the dependency lines of the rows between START and END.
One line per row, in display order."
  (interactive "r" crate-browse-mode)
  (let (lines)
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (when-let* ((line (crate-evil--row-dependency-line)))
          (push line lines))
        (forward-line 1)))
    (if lines
        (progn
          (kill-new (mapconcat #'identity (nreverse lines) "\n"))
          (message "Copied %d dependency lines" (length lines)))
      (user-error "No rows selected"))))

;;; Folding

;; `magit-section-toggle', `magit-section-show' and `magit-section-hide'
;; take the section as an argument, so the fold list wraps them in a
;; command that reads the section of point.
(add-to-list 'evil-fold-list
             `((crate-mode)
               :open-all   (lambda ()
                             (magit-section-show magit-root-section))
               :close-all  magit-section-show-level-1-all
               :toggle     (lambda ()
                             (magit-section-toggle (magit-current-section)))
               :open       (lambda ()
                             (magit-section-show (magit-current-section)))
               :open-rec   (lambda ()
                             (magit-section-show-children
                              (magit-current-section)))
               :close      (lambda ()
                             (magit-section-hide (magit-current-section)))))

;;; Local minor modes

(define-minor-mode crate-evil-detail-mode
  "Install the evil bindings of crate detail buffers.
Enable `crate-evil-mode' instead."
  :group 'crate
  :lighter nil)

(define-minor-mode crate-evil-browse-mode
  "Install the evil bindings of crate browse buffers.
Enable `crate-evil-mode' instead."
  :group 'crate
  :lighter nil)

(defun crate-evil--key-sequence (key)
  "Return the key sequence of KEY.
A `[remap COMMAND]' vector passes through unchanged."
  (if (vectorp key) key (key-parse key)))

(defun crate-evil--bind (state mode keys)
  "Bind STATE's evil keys for MODE from the KEYS list."
  (apply #'evil-define-minor-mode-key state mode
         (mapcan (lambda (binding)
                   (list (crate-evil--key-sequence (car binding))
                         (cdr binding)))
                 keys)))

(crate-evil--bind 'normal 'crate-evil-detail-mode crate-evil-detail-keys)
(crate-evil--bind 'normal 'crate-evil-browse-mode crate-evil-browse-keys)
(crate-evil--bind 'visual 'crate-evil-browse-mode
                  crate-evil-browse-visual-keys)

;;; Global mode

(defun crate-evil--maybe-enable ()
  "Enable the matching local evil mode in the current buffer."
  (cond
   ((derived-mode-p 'crate-mode)
    (crate-evil-detail-mode 1))
   ((derived-mode-p 'crate-browse-mode)
    (crate-evil-browse-mode 1))))

(defun crate-evil--disable ()
  "Disable every local evil mode in the current buffer."
  (crate-evil-detail-mode -1)
  (crate-evil-browse-mode -1))

;;;###autoload
(defun crate-evil-auto-setup ()
  "Enable `crate-evil-mode' when the option allows it."
  (when crate-evil-auto-enable
    (crate-evil-mode 1)))

;;;###autoload
(define-minor-mode crate-evil-mode
  "Install the evil bindings of the crate modes.
The mode is global: it enables one local minor mode in each crate
buffer and follows new buffers through the major mode hook."
  :global t
  :group 'crate
  (if crate-evil-mode
      (progn
        (add-hook 'after-change-major-mode-hook
                  #'crate-evil--maybe-enable)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (crate-evil--maybe-enable))))
    (remove-hook 'after-change-major-mode-hook
                 #'crate-evil--maybe-enable)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (crate-evil--disable)))))

(provide 'evil-crate)

;;; evil-crate.el ends here
