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
;; In explicit unshared mode, restore moves queued messages into the draft
;; and clear keeps discarded text in the kill ring.  A shared queue belongs
;; to every frontend: its removal needs confirmation and acknowledged ALL
;; text becomes requester-only suspended recovery, never automatic input.
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
(require 'pilish-drafts)

(declare-function pilish--cancel-tool-times-state "pilish-render" ())
(declare-function pilish--paint-retired-tool-times "pilish-render" (retired))
(declare-function pilish--cancel-process-dialogs "pilish-dialog" (process))

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

(defun pilish--queue-panel-queue-lines ()
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
               (if (pilish--process-shared-p pilish--process) "Recover ALL" "Restore")
               'pilish-restore-queued-messages
               "recover queued messages; a shared queue belongs to every frontend")
              " "
              (pilish--queue-control
               "Clear" 'pilish-clear-queued-messages
               "clear queued messages; a shared queue belongs to every frontend")))))))

(defun pilish--queue-panel-lines ()
  "Return queued work and explicit local recovery controls above the draft."
  (append
   (pilish--queue-panel-queue-lines)
   (when (and (pilish--process-shared-p pilish--process)
              (or (pilish--queued-steering) (pilish--queued-followups)))
     (list (propertize "Shared queue: clear affects EVERY frontend; recovery belongs to the requester."
                       'face 'pilish-queued-message)))
   (when pilish--input-quarantine
     (list (concat (propertize (format "Suspended/recovered input (%d): "
                                      (length pilish--input-quarantine))
                               'face 'pilish-queued-message)
                   (pilish--queue-control "Select and reuse"
                                          'pilish-restore-quarantined-input
                                          "select old-context input and confirm reuse; never automatically send"))))))

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
  (when (eq (plist-get response :success) t)
    (let ((data (plist-get response :data)))
      (seq-filter #'stringp
                  (append (plist-get data :steering)
                          (plist-get data :followUp) nil)))))

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
        (if (pilish--process-shared-p (pilish--get-process))
            (pilish--remove-shared-queued-messages)
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
            (pilish--finish-queue-removal '(:success t) local restore))))))))

;;;; Destructive shared queue control

(defun pilish--confirm-shared-queue-clear ()
  "Ask permission to remove the runtime's global shared input queue.
Confirmation applies to one intentional action, never a later automatic retry.
A single y or n answers; RET answers yes."
  (let ((y-or-n-p-map (define-keymap :parent y-or-n-p-map "RET" #'y-or-n-p-insert-y))
        (query-replace-map (define-keymap :parent query-replace-map "RET" 'act)))
    (y-or-n-p
     (concat "Clear queued input for EVERY attached frontend? ALL acknowledged recovered text "
             "goes only to this requester; some input may already have been delivered. "
             "(default y)"))))

(defun pilish--retain-shared-queue-response (response context)
  "Retain only acknowledged shared queue text from RESPONSE, bound to CONTEXT."
  (if (eq (plist-get response :success) t)
      (let ((messages (pilish--cleared-messages response)))
        (when messages
          (pilish--quarantine-input "shared-queue-requester-recovery" context
                                   :followups messages :shared t))
        (message (concat "Pi: Shared queue clear acknowledged; %d messages retained for this requester only. "
                         "Select suspended input to reuse; nothing was resubmitted.")
                 (length messages)))
    (pilish--quarantine-input
     "shared-queue-clear-uncertain" context :uncertain t
     :diagnostic (or (plist-get response :error) "Clear was not acknowledged"))
    (message "Pi: Shared queue clear not acknowledged; removal/delivery is uncertain. No recovered input was inferred.")))

(defun pilish--clear-shared-queue-confirmed (proc context &optional callback)
  "Clear PROC's queue after one explicit confirmation and retain its result.
CONTEXT is the file/branch at authorization, not at callback time.  CALLBACK,
when present, receives the actual response after requester-only recovery."
  (let ((chat (pilish--get-chat-buffer)))
    (condition-case err
        (pilish--rpc-async
         proc (if (process-get proc 'pilish-detached)
                  (list :type "clear_queue" :pimuxContext
                        (or (plist-get context :runtime-context) :null))
                '(:type "clear_queue"))
         (lambda (response)
           (when (buffer-live-p chat)
             (with-current-buffer chat
               (pilish--retain-shared-queue-response response context)))
           (when callback (funcall callback response))))
      (error
       (let ((response (list :success nil :error (error-message-string err))))
         (when (buffer-live-p chat)
           (with-current-buffer chat
             (pilish--retain-shared-queue-response response context)))
         (when callback (funcall callback response)))))))

(defun pilish--remove-shared-queued-messages ()
  "Confirm one global clear and suspend its acknowledged recovery locally."
  (let* ((proc (pilish--get-process))
         (input-context (pilish--capture-input-context proc))
         (context (pilish--draft-context)))
    (when (pilish--confirm-shared-queue-clear)
      (unless (equal input-context (pilish--capture-input-context proc))
        (user-error "Queue confirmation belongs to a previous conversation; nothing was cleared"))
      (let ((local (pilish--take-unsubmitted-followups)))
        (when local
          (pilish--quarantine-input "local-queue-recovery" context :followups local))
        (pilish--clear-shared-queue-confirmed proc context)))))

(defun pilish--abort-shared-turn ()
  "Confirm global queue removal, suspend local work and abort this shared run.
Called by the owning Abort control, before it changes queues or stop intent.
Later delayed-start aborts must send only Abort, not clear new shared input."
  (let* ((proc (pilish--get-process))
         (input-context (pilish--capture-input-context proc))
         (context (pilish--draft-context)))
    (when (pilish--confirm-shared-queue-clear)
      (unless (equal input-context (pilish--capture-input-context proc))
        (user-error "Abort confirmation belongs to a previous conversation; nothing was cleared or aborted"))
      (let* ((local (pilish--take-unsubmitted-followups))
             (retired (pilish--cancel-tool-times-state)))
      (unwind-protect
          (progn
            (when local
              (pilish--quarantine-input "local-abort-recovery" context :followups local))
            (pilish--set-aborted t input-context)
            (pilish--clear-shared-queue-confirmed proc context)
            (pilish--cancel-process-dialogs proc)
            (pilish--rpc-async proc (pilish--bind-input-context '(:type "abort") input-context)
                               #'ignore))
        (pilish--paint-retired-tool-times retired))
      (message "Pi: Aborting the shared turn; acknowledged cleared input is recoverable here only")
      t))))

;;;###autoload
(defun pilish-restore-queued-messages (&optional event)
  "Recover queued messages without stopping Pi.
An unshared queue goes before the draft, steering first.  Shared clearing
requires confirmation and retains all acknowledged input as requester-only
suspended recovery, never automatically in the draft.  EVENT identifies
the clicked session's control."
  (interactive (list last-nonmenu-event))
  (pilish--remove-queued-messages event t))

;;;###autoload
(defun pilish-clear-queued-messages (&optional event)
  "Clear queued messages without stopping Pi.
Unshared text stays in the kill ring.  Shared clearing requires explicit
every-frontend confirmation and keeps acknowledged recovery here only.
EVENT identifies the clicked session's control."
  (interactive (list last-nonmenu-event))
  (pilish--remove-queued-messages event nil))

(provide 'pilish-queue)
;;; pilish-queue.el ends here
