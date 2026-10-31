;;; pilish-queue.el --- Queued messages above the draft -*- lexical-binding: t; -*-

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

;; Shows the messages waiting behind the current run above the draft and
;; takes them back, like Pi's terminal interface:
;;
;;   Steering: check the Firefox case too
;;   Follow-up: commit once the tests pass
;;   ↳ [Restore M-<up>] [Clear C-c C-u]
;;
;; `pilish-restore-queued-messages' moves every queued message into the
;; draft and `pilish-clear-queued-messages' discards them, keeping the text
;; in the kill ring.  Neither stops the run.  `pilish-abort' restores them
;; too.
;;
;; A session has two queues: Pi's own, known through `queue_update'
;; snapshots, and Pilish's local follow-ups.  Pi's `clear_queue' takes its
;; queue as a whole and returns what it removed, and that answer decides
;; what was taken: a displayed message may have been delivered meanwhile.
;; Pi has no command to remove one message, so neither does Pilish.  A local
;; follow-up already submitted as a prompt stays until Pi answers: it is no
;; longer Pilish's to take back.

;;; Code:

(require 'pilish-ui)

(defconst pilish--queue-panel-rows 4
  "Most queued messages shown above the draft.")

(defface pilish-queued-message
  '((t :inherit pilish-extension-widget))
  "Face for the queued messages above the prompt draft."
  :group 'pilish)

;;;; Panel

(defun pilish--queue-control (label command help)
  "Return a clickable control running COMMAND, labelled LABEL and its key.
HELP describes it.  Pressing does nothing, so point stays in the draft."
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'ignore)
    (define-key map [mouse-1] command)
    (propertize (substitute-command-keys
                 (format "[%s \\<pilish-input-mode-map>\\[%s]]" label command) t)
                'face 'pilish-queued-message
                'keymap map
                'mouse-face 'highlight
                'help-echo (concat "mouse-1: " help))))

(defun pilish--queue-panel-lines ()
  "Return the lines showing the current chat buffer's queued messages."
  (let* ((rows (append (mapcar (lambda (text) (cons "Steering" text))
                               (pilish--queued-steering))
                       (mapcar (lambda (text) (cons "Follow-up" text))
                               (pilish--queued-followups))))
         (hidden (- (length rows) pilish--queue-panel-rows)))
    (when rows
      (append
       (mapcar (lambda (row)
                 (propertize (format "%s: %s" (car row)
                                     (pilish--queue-message-preview (cdr row)))
                             'face 'pilish-queued-message))
               (seq-take rows pilish--queue-panel-rows))
       (when (> hidden 0)
         (list (propertize (format "+%d more" hidden)
                           'face 'pilish-queued-message)))
       (list (concat
              (propertize "↳ " 'face 'pilish-queued-message)
              (pilish--queue-control
               "Restore" 'pilish-restore-queued-messages
               "move the queued messages into the draft")
              " "
              (pilish--queue-control
               "Clear" 'pilish-clear-queued-messages
               "discard the queued messages, keeping them in the kill ring")))))))

;;;; Taking messages back

(defun pilish--followup-submitted-p ()
  "Return non-nil when the oldest follow-up awaits Pi's answer as a prompt."
  (and (pilish--prompt-start-wait-active-p)
       (pilish--prompt-wait-followup pilish--prompt-wait)
       (not (pilish--prompt-wait-accepted pilish--prompt-wait))))

(defun pilish--take-unsubmitted-followups ()
  "Remove the local follow-ups not yet submitted and return them, oldest first."
  (let* ((followups (pilish--followups-in-fifo-order))
         (submitted (pilish--followup-submitted-p))
         (taken (if submitted (cdr followups) followups)))
    (when taken
      (setq pilish--followup-queue (and submitted (list (car followups))))
      (pilish--queue-changed))
    taken))

(defun pilish--cleared-messages (response)
  "Return the texts Pi removed according to `clear_queue' RESPONSE."
  (let ((data (plist-get response :data)))
    (append (plist-get data :steering) (plist-get data :followUp) nil)))

(defun pilish--restore-messages (messages)
  "Put the texts MESSAGES before the draft, like Pi's terminal interface."
  (when messages
    (pilish--restore-input-text (string-join messages "\n\n"))))

(defun pilish--finish-queue-removal (response local restore)
  "Finish taking queued messages back after `clear_queue' RESPONSE.
LOCAL are the local follow-ups taken before it.  With RESTORE, LOCAL is
already in the draft and Pi's messages go before it; otherwise all of
them go to the kill ring."
  (let* ((messages (append (pilish--cleared-messages response) local))
         (count (length messages))
         (noun (if (= count 1) "message" "messages")))
    (if restore
        (pilish--restore-messages (pilish--cleared-messages response))
      (when messages
        (kill-new (string-join messages "\n\n"))))
    (when (and restore messages)
      (pilish-open-input))
    (cond
     ((not (eq (plist-get response :success) t))
      (message "Pi: Pi kept its queued messages: %s"
               (or (plist-get response :error) "unknown error")))
     ((zerop count) (message "Pi: No queued messages"))
     (restore (message "Pi: Restored %d queued %s to the draft" count noun))
     (t (message "Pi: Cleared %d queued %s (kept in the kill ring)" count noun)))))

(defun pilish--remove-queued-messages (event restore)
  "Take back the queued messages of EVENT's session or the current one.
With RESTORE they go to the draft, otherwise to the kill ring.  Local
follow-ups leave at once, so they cannot start while Pi answers."
  (let ((chat (with-current-buffer (if (mouse-event-p event)
                                       (window-buffer (posn-window (event-start event)))
                                     (current-buffer))
                (pilish--get-chat-buffer))))
    (unless (buffer-live-p chat)
      (user-error "No pi session for this buffer"))
    (with-current-buffer chat
      (if (pilish--session-transition-active-p)
          (message "Pi: Cannot change queued messages while session is switching")
        (let ((local (pilish--take-unsubmitted-followups))
              (proc (pilish--get-process)))
          (when restore
            (pilish--restore-messages local))
          (if (and proc (process-live-p proc))
              (condition-case err
                  (pilish--rpc-async
                   proc '(:type "clear_queue")
                   (lambda (response)
                     (when (buffer-live-p chat)
                       (with-current-buffer chat
                         (pilish--finish-queue-removal response local restore)))))
                (error
                 (pilish--finish-queue-removal
                  (list :success nil :error (error-message-string err))
                  local restore)))
            (pilish--finish-queue-removal '(:success t) local restore)))))))

;;;###autoload
(defun pilish-restore-queued-messages (&optional event)
  "Move every queued message into the draft, without stopping Pi.
They go before the current draft, steering first.  EVENT is the click
on the control above the draft, whose session this acts on."
  (interactive (list last-nonmenu-event))
  (pilish--remove-queued-messages event t))

;;;###autoload
(defun pilish-clear-queued-messages (&optional event)
  "Discard every queued message, without stopping Pi.
The text stays in the kill ring.  EVENT is the click on the control
above the draft, whose session this acts on."
  (interactive (list last-nonmenu-event))
  (pilish--remove-queued-messages event nil))

(provide 'pilish-queue)
;;; pilish-queue.el ends here
