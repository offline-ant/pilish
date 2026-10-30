;;; pilish-answer.el --- Show the final answer of a finished turn -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; With `pilish-jump-to-answer', a finished session shows the start of its
;; final assistant message, the answer after the last tool call, so a long
;; answer is read from its beginning instead of its end.  Each answer lands
;; once per session.
;;
;; When a turn ends, chat windows following the output land; a window
;; where the reader scrolled elsewhere stays.  An answer not shown that way
;; lands when the reader arrives: when a chat window is displayed, such as
;; one of another tab, or when the selection enters the session from
;; elsewhere.  An arriving reader above the answer moves forward to it, one
;; inside the answer stays, and one at the end lands.  A session loaded
;; from history counts as a finished turn.  An answer that fits below the
;; window's top, with the end visible, shows at the end instead.
;;
;; A landed window whose point the reader left in place follows the
;; output again when the next turn starts.  `pilish--answer-windows'
;; records each landing so that a window revived later at a landing
;; position is still recognized as unmoved.

;;; Code:

(require 'pilish-ui)

(defcustom pilish-jump-to-answer nil
  "Whether a finished session shows the start of its final answer.
When non-nil, each answer of a turn that ended without being stopped,
or of a session loaded from history, lands once: chat windows following
the output move to the start of the last assistant message when the turn
ends, and otherwise the reader lands there on displaying the chat or
selecting the session from elsewhere, unless already inside the answer.
Setting it buffer-locally in a chat buffer, as
`pilish-toggle-jump-to-answer' does, affects only that session."
  :type 'boolean
  :group 'pilish)

(defvar-local pilish--answer-target nil
  "Marker at the start of the finished turn's final answer, or nil.
Non-nil from the end of a turn until the next turn starts.")

(defvar-local pilish--answer-settled nil
  "Non-nil when `pilish--answer-target' has landed and must not again.")

(defvar-local pilish--history-answer-marker nil
  "Marker at the start of the final answer of replayed history, or nil.")

(defvar pilish--answer-focused-chat nil
  "Chat of the session last selected outside the minibuffer, or nil.")

(defvar-local pilish--answer-windows nil
  "Alist of (WINDOW . MARKER) for windows landed on an answer.
MARKER is the landing position.  A window still at its MARKER when a
newer turn starts, or when it is displayed again, is unmoved.")

(defun pilish-toggle-jump-to-answer (&optional buffer)
  "Toggle `pilish-jump-to-answer' for the session of BUFFER.
BUFFER is a chat or input buffer and defaults to the current buffer.
The setting becomes buffer-local in the session's chat buffer."
  (interactive)
  (let ((chat (with-current-buffer (or buffer (current-buffer))
                (pilish--get-chat-buffer))))
    (unless (buffer-live-p chat)
      (user-error "Not in a Pilish session"))
    (with-current-buffer chat
      (setq-local pilish-jump-to-answer (not pilish-jump-to-answer))
      ;; Landed windows keep their records, so they still follow the
      ;; next turn; only a pending landing for hidden windows is dropped.
      (unless pilish-jump-to-answer
        (pilish--answer-forget-target))
      (message "Pilish: jump to answer %s"
               (if pilish-jump-to-answer "on" "off"))
      pilish-jump-to-answer)))

(defun pilish--answer-start (marker)
  "Return the start of the first line of the final answer at MARKER, or nil.
Nil when MARKER is nil or the final assistant message has no visible text."
  (when-let* ((start (and marker (marker-position marker))))
    (save-excursion
      (goto-char start)
      (skip-chars-forward " \t\n")
      (unless (eobp)
        (line-beginning-position)))))

(defun pilish--answer-visible-p (window start)
  "Return non-nil when following WINDOW shows START with the tail.
The current buffer must be WINDOW's buffer."
  (let ((height (max 1 (window-body-height window))))
    (< (pilish--count-screen-lines-up-to start (point-max) height window)
       height)))

(defun pilish--answer-unmoved-p (window marker)
  "Return non-nil when WINDOW's point is still at landing MARKER."
  (eql (window-point window) (marker-position marker)))

(defun pilish--answer-land (window target arrival)
  "Show TARGET in WINDOW of the current chat buffer, if WINDOW takes it.
A following window does; with ARRIVAL, a reader coming to WINDOW above
TARGET does too.  Return non-nil when that settles TARGET, as does
arriving inside the answer."
  (let ((following (pilish--window-following-p window))
        (above (< (window-point window) target)))
    (when (or following arrival)
      (when (or following above)
        (cond ((not (pilish--answer-visible-p window target))
               (set-window-point window target)
               (set-window-start window target)
               (push (cons window target) pilish--answer-windows))
              ((not following)
               (pilish--restore-tail-window window target))))
      t)))

(defun pilish--answer-update-window (window &optional arrival)
  "Bring WINDOW of the current chat buffer up to date with the answer state.
An unmoved landing on an earlier answer follows the output again, and an
unsettled `pilish--answer-target' lands, see `pilish--answer-land'.
ARRIVAL means the reader came to WINDOW.  Return non-nil when that
settles the target."
  (let ((entry (assq window pilish--answer-windows))
        (target pilish--answer-target))
    (unless (and entry (eq (cdr entry) target))
      (when entry
        (when (pilish--answer-unmoved-p window (cdr entry))
          (set-window-point window (point-max)))
        (setq pilish--answer-windows (delq entry pilish--answer-windows))
        (unless (rassq (cdr entry) pilish--answer-windows)
          (set-marker (cdr entry) nil)))
      (and target
           (not pilish--answer-settled)
           (pilish--answer-land window target arrival)))))

(defun pilish--answer-update-windows (windows arrival)
  "Update WINDOWS of the current chat buffer together.
ARRIVAL means the reader came to them.  Every one of them can land on
the target before it settles."
  (let (settled)
    (dolist (window windows)
      (when (pilish--answer-update-window window arrival)
        (setq settled t)))
    (when settled
      (setq pilish--answer-settled t))))

(defun pilish--answer-update-live-windows (&optional arrival)
  "Update every live window showing the current chat buffer.
ARRIVAL means the reader came to them."
  (pilish--answer-update-windows
   (get-buffer-window-list (current-buffer) nil t) arrival))

(defun pilish--answer-arm (start)
  "Make START the final answer to land on; nil clears the pending one."
  (pilish--answer-forget-target)
  (when start
    (setq pilish--answer-target (copy-marker start)
          pilish--answer-settled nil)))

(defun pilish--answer-turn-end ()
  "Land following windows on the final answer of the turn that ended.
Do nothing when the turn was stopped, a queued follow-up starts the
next turn at once, or `pilish-jump-to-answer' is nil."
  (when (and pilish-jump-to-answer
             (not pilish--aborted)
             (not pilish--followup-queue))
    (when-let* ((start (pilish--answer-start pilish--message-start-marker)))
      (pilish--answer-arm start)
      (pilish--answer-update-live-windows))))

(defun pilish--answer-history-loaded ()
  "Land on the final answer of the session history just displayed.
The history rebuilt the chat buffer, so an earlier answer is gone."
  (pilish--answer-arm
   (and pilish-jump-to-answer
        (pilish--answer-start pilish--history-answer-marker)))
  (when pilish--answer-target
    (pilish--answer-update-live-windows t)))

(defun pilish--answer-turn-start ()
  "Let unmoved landed windows follow the output of a new turn."
  (when (or pilish--answer-target pilish--answer-windows)
    (pilish--answer-forget-target)
    (pilish--answer-update-live-windows)))

(defun pilish--answer-forget-target ()
  "Clear `pilish--answer-target', keeping markers that windows record."
  (when pilish--answer-target
    (unless (rassq pilish--answer-target pilish--answer-windows)
      (set-marker pilish--answer-target nil))
    (setq pilish--answer-target nil)))

(defun pilish--answer-window-buffer-change (window)
  "Update WINDOW, newly showing a chat buffer, with the answer state."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (or pilish--answer-target pilish--answer-windows)
        (pilish--answer-update-windows (list window) t)))))

(defun pilish--answer-selection-change (_frame)
  "Land the final answer of a session the selection just entered.
Moving between a session's windows arrives nowhere, and the minibuffer
is no departure: a session reader used there can select another session."
  (unless (minibufferp (window-buffer))
    (let ((chat (with-current-buffer (window-buffer)
                  (pilish--get-chat-buffer))))
      (unless (eq chat pilish--answer-focused-chat)
        (setq pilish--answer-focused-chat chat)
        (when (buffer-live-p chat)
          (with-current-buffer chat
            (when pilish--answer-target
              (pilish--answer-update-live-windows t))))))))

(defun pilish--answer-setup ()
  "Track windows displaying the current chat buffer."
  (add-hook 'window-buffer-change-functions
            #'pilish--answer-window-buffer-change nil t))

(add-hook 'pilish-chat-mode-hook #'pilish--answer-setup)
(add-hook 'window-selection-change-functions #'pilish--answer-selection-change)

(provide 'pilish-answer)
;;; pilish-answer.el ends here
