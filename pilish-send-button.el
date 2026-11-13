;;; pilish-send-button.el --- Clickable send and stop buttons beside the draft -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; With `pilish-input-send-button', input buffers show a ⏎ button in the
;; right margin beside each window's last visible row, so scrolling a long
;; draft never hides it; mouse-1 on it runs
;; `pilish-send' in that input, like C-c C-c, or the input's remapping of
;; it, such as pi-sound's stop-and-send while dictating.  With
;; `pilish-input-stop-button', a ✕ after it stops running work like
;; C-c C-k does while busy (`pilish-abort'); it never opens the tree.
;; A click while its shared-queue confirmation is showing answers yes,
;; so a double click stops shared Pi at once.
;;
;; Each button adds `pilish--send-button-width' columns to the buffer's
;; right margin rather than setting its width, so other margin buttons,
;; such as pi-sound's microphone, keep theirs.  Both share one overlay
;; per window (its `window' property), moved on scrolling, edits, resizes
;; and display; with a one-row window the margin shows the microphone
;; first (overlay priority 2 puts these after it).

;;; Code:

(require 'pilish-input)

(defvar pilish--send-button-overlays nil
  "This input buffer's button overlays, an alist of (WINDOW . OVERLAY).")
(make-variable-buffer-local 'pilish--send-button-overlays)
;; A re-run major mode can keep its overlays, so it must keep their owner
;; too.  md-ts-mode's teardown deletes them instead, which leaves the
;; overlays without a buffer.
(put 'pilish--send-button-overlays 'permanent-local t)

(defvar-local pilish--send-button-margin 0
  "Columns the buttons currently add to the right margin.
Not permanent: a re-run major mode resets `right-margin-width' too.")

(defun pilish--set-input-button-option (symbol value)
  "Set button option SYMBOL to VALUE and update existing input buffers."
  (set-default symbol value)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'pilish-input-mode)
        (pilish--update-send-button)))))

(defcustom pilish-input-send-button nil
  "Non-nil shows a clickable send button beside the draft's last line.
The button sits in the input window's right margin, which grows by
three columns.  Setting it through Customize or `setopt' updates
existing input buffers."
  :type 'boolean
  :group 'pilish
  :set #'pilish--set-input-button-option)

(defcustom pilish-input-stop-button nil
  "Non-nil shows a clickable stop button beside the draft's last line.
A click stops running work with `pilish-abort', as
`pilish-abort-or-tree-browser' does while busy; idle, it does nothing.
A click while the confirmation to clear a shared queue is showing
answers yes.
The button sits after the send button in the input window's right
margin, which grows by three columns.  Setting it through Customize or
`setopt' updates existing input buffers."
  :type 'boolean
  :group 'pilish
  :set #'pilish--set-input-button-option)

(defconst pilish--send-button-width 3
  "Columns each button adds to the right margin.
A label takes two, but graphical frames draw ⏎ and ✕ from fallback fonts
wider than a column; the third keeps the last button from being cut off.")

(defvar-keymap pilish-send-button-map
  :doc "Bindings of the send button in the right margin."
  ;; The click acts on release; the press leaves point in the draft.
  "<right-margin> <down-mouse-1>" #'ignore
  "<right-margin> <mouse-1>" #'pilish-send-button-click)

(defvar-keymap pilish-stop-button-map
  :doc "Bindings of the stop button in the right margin."
  "<right-margin> <down-mouse-1>" #'ignore
  "<right-margin> <mouse-1>" #'pilish-stop-button-click)

(defun pilish-send-button-click (event)
  "Send the draft of the input whose margin button EVENT clicked.
A remapping of `pilish-send' in that input applies, as for its keys."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (call-interactively (or (command-remapping #'pilish-send) #'pilish-send)))

(defun pilish-stop-button-click (event)
  "Stop the running work of the input whose margin button EVENT clicked.
A click while that input's shared abort asks for confirmation answers
yes.  An unbound double click runs this as a single click."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (pilish--confirm-pending-abort (pilish--get-chat-buffer))
  (pilish-abort))

(defun pilish--send-button-label (label map help)
  "Return margin button LABEL with keymap MAP and HELP text."
  (propertize label 'mouse-face 'highlight 'pointer 'hand
              'local-map map 'help-echo help))

(defun pilish--send-button-string ()
  "Return the before-string that shows the enabled buttons in the margin."
  (propertize " " 'display
              `((margin right-margin)
                ,(concat
                  (when pilish-input-send-button
                    (pilish--send-button-label
                     " ⏎" pilish-send-button-map "mouse-1: send (C-c C-c)"))
                  (when pilish-input-stop-button
                    (pilish--send-button-label
                     " ✕" pilish-stop-button-map
                     "mouse-1: stop running work (C-c C-k)"))))))

(defun pilish--send-button-columns ()
  "Return the right-margin columns the enabled buttons need."
  (* pilish--send-button-width
     (+ (if pilish-input-send-button 1 0) (if pilish-input-stop-button 1 0))))

(defun pilish--send-button-row (window)
  "Return the start of WINDOW's last visible row of the current buffer."
  (save-excursion
    (goto-char (window-start window))
    (vertical-motion (1- (max 1 (window-body-height window))) window)
    ;; A draft shorter than the window stops within its last row.
    (vertical-motion 0 window)
    (point)))

(defun pilish--clear-send-buttons ()
  "Delete this buffer's button overlays."
  (dolist (entry pilish--send-button-overlays)
    (delete-overlay (cdr entry)))
  (setq pilish--send-button-overlays nil))

(defun pilish--place-send-buttons (&rest _)
  "Show the buttons beside the last visible row of each window of this buffer.
Windows no longer showing the buffer lose theirs."
  (let ((windows (get-buffer-window-list nil nil t))
        (string (pilish--send-button-string))
        placed)
    (dolist (window windows)
      (let ((overlay (cdr (assq window pilish--send-button-overlays)))
            (row (pilish--send-button-row window)))
        (if (and overlay (overlay-buffer overlay))
            (unless (= row (overlay-start overlay))
              (move-overlay overlay row row))
          (setq overlay (make-overlay row row))
          (overlay-put overlay 'window window)
          ;; Before-strings show in increasing priority: after the lines
          ;; above the draft and a priority-1 button such as pi-sound's.
          (overlay-put overlay 'priority 2))
        (overlay-put overlay 'before-string string)
        (push (cons window overlay) placed)))
    (dolist (entry pilish--send-button-overlays)
      (unless (memq (car entry) windows) (delete-overlay (cdr entry))))
    (setq pilish--send-button-overlays placed)))

(defconst pilish--send-button-hooks
  '(after-change-functions window-scroll-functions
    window-size-change-functions window-buffer-change-functions)
  "Buffer-local hooks after which the buttons are placed again.")

(defun pilish--reserve-send-button-margin (columns)
  "Make the buttons' share of the right margin COLUMNS wide."
  (unless (= columns pilish--send-button-margin)
    (setq-local right-margin-width
                (+ (or right-margin-width 0) (- columns pilish--send-button-margin)))
    (setq pilish--send-button-margin columns)
    (dolist (window (get-buffer-window-list nil nil t))
      (set-window-margins window (car (window-margins window)) right-margin-width))))

(defun pilish--update-send-button ()
  "Show, refresh or remove this input buffer's buttons per their options."
  (if (or pilish-input-send-button pilish-input-stop-button)
      (progn
        (dolist (hook pilish--send-button-hooks)
          (add-hook hook #'pilish--place-send-buttons nil t))
        (pilish--reserve-send-button-margin (pilish--send-button-columns))
        (pilish--place-send-buttons))
    (dolist (hook pilish--send-button-hooks)
      (remove-hook hook #'pilish--place-send-buttons t))
    (pilish--clear-send-buttons)
    (pilish--reserve-send-button-margin 0)))

(add-hook 'pilish-input-mode-hook #'pilish--update-send-button)

(provide 'pilish-send-button)
;;; pilish-send-button.el ends here
