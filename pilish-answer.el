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

;; `pilish-jump-to-answer' controls automatic positioning at turn completion
;; and when the reader focuses a session from elsewhere.  A long final
;; answer shows from its beginning; a short one shows with the buffer end.
;;
;; Completion lands following windows once per answer; a reader scrolled
;; elsewhere stays.  Displaying a chat can land an answer not shown yet.
;; Focusing the session lands its latest final answer again, even if it
;; was already read.  A working session instead follows its latest output.
;; Moving between a session's chat and input, or using the minibuffer, is
;; not a new arrival.  Pending dialogs take priority over automatic jumps.
;;
;; A landed window whose point the reader left in place follows the
;; output again when the next turn starts.  `pilish--answer-windows'
;; records each landing so that a window revived later at a landing
;; position is still recognized as unmoved.

;;; Code:

(require 'pilish-ui)

(declare-function pilish-session-pending-dialogs "pilish-dialog" (chat-buffer))

(defcustom pilish-jump-to-answer nil
  "Whether to jump automatically on turn completion and session focus.
When a turn ends normally, following windows show its final answer from
its start once; a reader scrolled elsewhere stays.  Displaying a chat
can land an answer not shown yet.  Focusing a session from elsewhere
shows its latest final answer again, or follows its latest output while
working.  Chat/input moves and the minibuffer are not new arrivals.
Pending dialogs take priority.  Short answers show with the buffer end.
Setting this buffer-locally in a chat buffer, as
`pilish-toggle-jump-to-answer' does, affects only that session."
  :type 'boolean
  :group 'pilish)

(defvar-local pilish--answer-target nil
  "Marker at the start of the latest finished turn's final answer, or nil.
Retained even with automatic positioning off, until the next turn starts.")

(defvar-local pilish--answer-settled nil
  "Non-nil after `pilish--answer-target' landed on completion or display.
An explicit session focus may land it again.")

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
      ;; Keep the latest answer so enabling this after completion also
      ;; works on the next focus.  Toggling itself never moves the view.
      (message "Pilish: automatic jump %s"
               (if pilish-jump-to-answer "on" "off"))
      pilish-jump-to-answer)))

(defun pilish--answer-start (marker)
  "Return the start of the first line of the final answer at MARKER, or nil.
Nil when MARKER is nil or the final assistant message has no visible text
before the end of the buffer or the run's return receipt."
  (when-let* ((start (and marker (marker-position marker))))
    (save-excursion
      (goto-char start)
      (skip-chars-forward " \t\n")
      (unless (or (eobp) (get-text-property (point) 'pilish-run-receipt))
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
A following window does; with ARRIVAL, a reader above TARGET does too.
ARRIVAL `focus' always lands, including inside an already read answer.
Return non-nil when that settles TARGET, as does arriving inside it."
  (let ((following (pilish--window-following-p window))
        (above (< (window-point window) target)))
    (when (or following arrival)
      (when (or following above (eq arrival 'focus))
        (cond ((not (pilish--answer-visible-p window target))
               (set-window-point window target)
               (set-window-start window target)
               (setf (alist-get window pilish--answer-windows) target))
              ((or (not following) (eq arrival 'focus))
               (pilish--restore-tail-window window target))))
      t)))

(defun pilish--answer-update-window (window &optional arrival)
  "Bring WINDOW of the current chat buffer up to date with the answer state.
An unmoved landing on an earlier answer follows the output again, and an
unsettled `pilish--answer-target' lands, see `pilish--answer-land'.
ARRIVAL means the reader came to WINDOW; `focus' can land a read answer
again.  Return non-nil when that settles the target."
  (let* ((entry (assq window pilish--answer-windows))
         (target pilish--answer-target)
         (landed (and entry (eq (cdr entry) target))))
    (when (and entry (not landed))
      (when (pilish--answer-unmoved-p window (cdr entry))
        (set-window-point window (point-max)))
      (setq pilish--answer-windows (delq entry pilish--answer-windows))
      (unless (rassq (cdr entry) pilish--answer-windows)
        (set-marker (cdr entry) nil)))
    (and pilish-jump-to-answer target
         (not (pilish-session-pending-dialogs (current-buffer)))
         (or (eq arrival 'focus)
             (and (not landed) (not pilish--answer-settled)))
         (pilish--answer-land window target arrival))))

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

(defun pilish--answer-turn-end (aborted)
  "Remember the final answer and land following windows when enabled.
Run when Pi returns control, after the return receipt, so the landing
sees the run's last text.  Do nothing when the run was ABORTED or a
queued follow-up starts the next run at once."
  (when (and (not aborted)
             (not pilish--followup-queue))
    (when-let* ((start (pilish--answer-start pilish--message-start-marker)))
      (pilish--answer-arm start)
      (pilish--answer-update-live-windows))))

(defun pilish--answer-history-loaded ()
  "Land on the final answer of the session history just displayed.
The history rebuilt the chat buffer, so an earlier answer is gone."
  (pilish--answer-arm (pilish--answer-start pilish--history-answer-marker))
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

(defun pilish-position-session-on-focus (chat-buffer)
  "Apply enabled automatic positioning to CHAT-BUFFER in the selected frame.
Workspace UIs can call this for an explicit focus action, even when it
returns to the same selected window before redisplay.  A working chat
follows its output; a finished chat shows its latest final answer again.
Pending dialogs and a disabled `pilish-jump-to-answer' leave the view alone.
Do not display a hidden chat, select a window, or change the input draft."
  (when (buffer-live-p chat-buffer)
    (with-current-buffer chat-buffer
      (when (and pilish-jump-to-answer
                 (not (pilish-session-pending-dialogs chat-buffer)))
        (let ((windows (get-buffer-window-list chat-buffer nil (selected-frame))))
          (if (pilish--session-busy-p)
              (dolist (window windows)
                (pilish--restore-tail-window window (window-start window)))
            (pilish--answer-update-windows windows 'focus)))))))

(defun pilish--answer-selection-change (_frame)
  "Position a session the selection just entered, when enabled.
Moving between its chat/input windows arrives nowhere, and the minibuffer
is no departure.  Pending dialogs retain their reading position and focus."
  (unless (minibufferp (window-buffer))
    (let ((chat (with-current-buffer (window-buffer)
                  (pilish--get-chat-buffer))))
      (unless (eq chat pilish--answer-focused-chat)
        (setq pilish--answer-focused-chat chat)
        (when (buffer-live-p chat)
          (pilish-position-session-on-focus chat))))))

(defun pilish--answer-setup ()
  "Track windows displaying the current chat buffer."
  (add-hook 'window-buffer-change-functions
            #'pilish--answer-window-buffer-change nil t))

(add-hook 'pilish-chat-mode-hook #'pilish--answer-setup)
(add-hook 'window-selection-change-functions #'pilish--answer-selection-change)
;; Replacing the selected window's buffer does not count as selecting a
;; different window.  It can nevertheless enter or leave a session.
(add-hook 'window-buffer-change-functions #'pilish--answer-selection-change)

(provide 'pilish-answer)
;;; pilish-answer.el ends here
