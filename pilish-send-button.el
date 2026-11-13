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
;; right margin beside the draft's last line; mouse-1 on it runs
;; `pilish-send' in that input, like C-c C-c, or the input's remapping of
;; it, such as pi-sound's stop-and-send while dictating.  With
;; `pilish-input-stop-button', a ✕ after it stops running work like
;; C-c C-k does while busy (`pilish-abort'); it never opens the tree.
;;
;; Each button adds `pilish--send-button-width' columns to the buffer's
;; right margin rather than setting its width, so other margin buttons,
;; such as pi-sound's microphone, keep theirs.  Both share one overlay;
;; with a one-line draft the margin shows the microphone first (overlay
;; priority 2 puts these after it).

;;; Code:

(require 'pilish-input)

(defvar pilish--send-button-overlay nil
  "This input buffer's send and stop button overlay, or nil.")
(make-variable-buffer-local 'pilish--send-button-overlay)
;; A re-run major mode can keep its overlays, so it must keep their owner
;; too.  md-ts-mode's teardown deletes them instead, which leaves the
;; overlay without a buffer.
(put 'pilish--send-button-overlay 'permanent-local t)

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
two columns.  Setting it through Customize or `setopt' updates
existing input buffers."
  :type 'boolean
  :group 'pilish
  :set #'pilish--set-input-button-option)

(defcustom pilish-input-stop-button nil
  "Non-nil shows a clickable stop button beside the draft's last line.
A click stops running work with `pilish-abort', as
`pilish-abort-or-tree-browser' does while busy; idle, it does nothing.
The button sits after the send button in the input window's right
margin, which grows by two columns.  Setting it through Customize or
`setopt' updates existing input buffers."
  :type 'boolean
  :group 'pilish
  :set #'pilish--set-input-button-option)

(defconst pilish--send-button-width 2
  "Columns each button adds to the right margin.")

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
  "Stop the running work of the input whose margin button EVENT clicked."
  (interactive "e")
  (select-window (posn-window (event-start event)))
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

(defun pilish--send-button-last-line ()
  "Return the start of the draft's last line."
  (save-excursion (goto-char (point-max)) (pos-bol)))

(defun pilish--send-button-live-p ()
  "Return non-nil when this buffer shows its send button overlay."
  (and (overlayp pilish--send-button-overlay)
       (overlay-buffer pilish--send-button-overlay)))

(defun pilish--follow-send-button (&rest _)
  "Keep the send button beside the draft's last line."
  (when (pilish--send-button-live-p)
    (let ((start (pilish--send-button-last-line)))
      (unless (= start (overlay-start pilish--send-button-overlay))
        (move-overlay pilish--send-button-overlay start start)))))

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
        (unless (pilish--send-button-live-p)
          (let ((start (pilish--send-button-last-line)))
            (setq pilish--send-button-overlay (make-overlay start start)))
          ;; Before-strings show in increasing priority: after the lines
          ;; above the draft and a priority-1 button such as pi-sound's.
          (overlay-put pilish--send-button-overlay 'priority 2))
        (overlay-put pilish--send-button-overlay 'before-string
                     (pilish--send-button-string))
        (add-hook 'after-change-functions #'pilish--follow-send-button nil t)
        (pilish--reserve-send-button-margin (pilish--send-button-columns)))
    (when (overlayp pilish--send-button-overlay)
      (delete-overlay pilish--send-button-overlay)
      (setq pilish--send-button-overlay nil))
    (remove-hook 'after-change-functions #'pilish--follow-send-button t)
    (pilish--reserve-send-button-margin 0)))

(add-hook 'pilish-input-mode-hook #'pilish--update-send-button)

(provide 'pilish-send-button)
;;; pilish-send-button.el ends here
