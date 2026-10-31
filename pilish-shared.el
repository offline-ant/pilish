;;; pilish-shared.el --- Pi processes shared with other frontends -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; pimux runs `pi --mode rpc' for the frontend that starts it (here Pilish,
;; with `pilish-executable' set to ("pimux" "--" "pi")) and lets other
;; frontends attach to the same process, so all of them see one
;; conversation live.  Its records have types starting with \"pimux_\";
;; pi-ant's `orchestration/pimux/README.md' is the contract.  This module
;; handles them for a chat buffer:
;;
;; - `pimux_hello' marks the process shared (`pilish--process-shared-p').
;; - `pimux_dialog_closed' closes a dialog answered elsewhere, expired or
;;   abandoned; on a shared process a new run cancels no dialog.
;; - `pimux_snapshot' ... `pimux_live' is a snapshot sequence: the state at
;;   one point of Pi's output, then replayed records of the work in flight
;;   there, which pass through the ordinary event handler.  A snapshot
;;   naming another session than the chat's, whatever caused it, makes the
;;   chat adopt that session in place: same process, same buffers, draft
;;   and queued follow-ups kept.  A tree move, a lost stretch of output
;;   (`pimux_gap') or a requested snapshot rebuilds the transcript the same
;;   way.  Never through `pilish-reload', which restarts the process.
;;   `pimux_live' ends the sequence: dialogs, statuses and widgets it did
;;   not replay are gone.  A status is cleared only then, not before the
;;   replay, so one that stays never flickers for its observers.
;; - A snapshot whose replay lost part of the run (`run.tailTruncated')
;;   says so in the chat; when the run ends, a requested snapshot brings
;;   the complete transcript.
;; - `pimux_model_changed' updates the model.  Thinking level and session
;;   name changes come as Pi's own events.
;;
;; Requests Pilish itself is switching sessions for (resume, new, fork) are
;; rebuilt by their own transition, so their snapshot only replays.

;;; Code:

(require 'pilish-menu)

(defun pilish-session-mux (chat-buffer)
  "Return the pimux identity of CHAT-BUFFER's process, or nil.
The value is the `pimux_hello' record (:muxId, :socket, :piPid ...) when
other frontends can attach to the process."
  (when (buffer-live-p chat-buffer)
    (pilish--process-shared-p (buffer-local-value 'pilish--process chat-buffer))))

(defun pilish--shared-handle-record (event)
  "Handle the pimux record EVENT for the current chat buffer's process."
  (let ((proc pilish--process))
    (when (pilish--process-shared-p proc)
      (pcase (plist-get event :type)
        ("pimux_dialog_closed"
         (pilish--extension-dialog-close proc (plist-get event :id)))
        ("pimux_gap"
         ;; Updates were lost: paint nothing more until the snapshot.
         (pilish--cancel-stream-delta-flush)
         (pilish--cancel-tool-update-flush)
         (pilish--cancel-tool-times-state))
        ("pimux_snapshot" (pilish--shared-apply-snapshot proc event))
        ("pimux_live" (pilish--shared-finish-snapshot proc event))
        ("pimux_snapshot_failed"
         (process-put proc 'pilish-mux-snapshot nil)
         (message "Pi: Shared session snapshot failed: %s" (plist-get event :error)))
        ("pimux_model_changed"
         (setq pilish--state (plist-put pilish--state :model (plist-get event :model)))
         (force-mode-line-update t))))))

;;;; Snapshots

(defun pilish--shared-replaying-p ()
  "Return non-nil while the current chat's process replays a snapshot.
Replayed records keep their content but not their time: a tool start
arrives when it is replayed, not when the tool started."
  (and (processp pilish--process)
       (process-get pilish--process 'pilish-mux-snapshot)
       t))

(defun pilish--shared-apply-snapshot (proc snapshot)
  "Rebuild the current chat from PROC's SNAPSHOT before its replay arrives."
  (let ((generation (plist-get snapshot :generation))
        (run (plist-get snapshot :run)))
    (when (> generation (or (process-get proc 'pilish-mux-generation) 0))
      (process-put proc 'pilish-mux-generation generation)
      (process-put proc 'pilish-mux-snapshot snapshot)
      ;; What is still open is replayed; `pimux_live' closes the rest.
      (dolist (request (pilish--extension-dialog-pending proc))
        (pilish--extension-dialog-set proc (plist-get request :id) :pilish-stale t))
      (unless pilish--session-transition-active
        (if (pilish--shared-session-moved-p snapshot)
            (pilish--shared-adopt-session proc snapshot)
          (pilish--shared-rebuild snapshot)))
      (process-put proc 'pilish-mux-stale-ui (pilish--shared-ui-keys))
      (setq pilish--settle-releases-streaming (eq (plist-get run :active) t))
      (when (and (eq (plist-get run :active) t)
                 (eq (plist-get run :tailTruncated) t))
        (process-put proc 'pilish-mux-refresh t)
        (pilish--add-chat-notice
         "⚠ Part of this run's output was lost; the full text follows when it ends."
         'pilish-retry-notice)))))

(defun pilish--shared-session-moved-p (snapshot)
  "Return non-nil when SNAPSHOT names another session than the current chat's.
It need not say `session_changed': a client that falls behind loses that
snapshot and gets the session in a later one."
  (or (equal (plist-get snapshot :reason) "session_changed")
      (let* ((session (plist-get snapshot :session))
             (file (plist-get pilish--state :session-file))
             (new-file (pilish--shared-session-file session))
             (dir (pilish--shared-session-directory (plist-get session :cwd))))
        (or (and file new-file (not (equal file new-file)))
            (and dir (not (equal dir (file-name-as-directory
                                      (pilish--chat-session-directory)))))))))

(defun pilish--shared-ui-keys ()
  "Return the current chat's extension statuses and widgets as (KIND . KEY)."
  (append (mapcar (lambda (status) (cons 'status (car status)))
                  pilish--extension-status)
          (mapcar (lambda (widget) (cons 'widget (car widget)))
                  pilish--extension-widgets)))

(defun pilish--shared-note-ui-replay (proc event)
  "Keep the extension UI that PROC's snapshot replay EVENT names."
  (when (and (pilish--process-shared-p proc)
             (process-get proc 'pilish-mux-snapshot))
    (process-put proc 'pilish-mux-stale-ui
                 (delete (pcase (plist-get event :method)
                           ("setStatus" (cons 'status (plist-get event :statusKey)))
                           ("setWidget" (cons 'widget (plist-get event :widgetKey))))
                         (process-get proc 'pilish-mux-stale-ui)))))

(defun pilish--shared-finish-snapshot (proc live)
  "End PROC's snapshot sequence LIVE: what it did not replay is gone."
  (when (equal (plist-get live :generation)
               (plist-get (process-get proc 'pilish-mux-snapshot) :generation))
    (process-put proc 'pilish-mux-snapshot nil)
    (dolist (request (pilish--extension-dialog-pending proc))
      (when (plist-get request :pilish-stale)
        (pilish--extension-dialog-close proc (plist-get request :id))))
    (pcase-dolist (`(,kind . ,key) (process-get proc 'pilish-mux-stale-ui))
      (if (eq kind 'status)
          (pilish--extension-ui-set-status (list :statusKey key))
        (pilish--set-extension-widget key nil)))
    (process-put proc 'pilish-mux-stale-ui nil)))

(defun pilish--shared-refresh-after-run (proc)
  "Ask PROC for a snapshot if the settled run's replay was truncated."
  (when (and (pilish--process-shared-p proc)
             (process-get proc 'pilish-mux-refresh))
    (process-put proc 'pilish-mux-refresh nil)
    (pilish--rpc-async
     proc '(:type "pimux_bootstrap" :include ["messages"])
     (lambda (response)
       (unless (eq (plist-get response :success) t)
         (message "Pi: Shared session snapshot failed: %s"
                  (plist-get response :error)))))))

(defun pilish--shared-session-file (session)
  "Return the file of the snapshot's SESSION as a path of the current chat."
  (pilish--passive-emacs-path
   (pilish--normalize-string-or-null (plist-get session :file))
   (pilish--chat-session-directory)))

(defun pilish--shared-apply-session-state (snapshot)
  "Set the current chat's session state from SNAPSHOT."
  (let* ((session (plist-get snapshot :session))
         (messages (plist-get snapshot :messages))
         (name (plist-get session :name)))
    (setq pilish--state
          (list :status pilish--status
                :model (plist-get snapshot :model)
                :thinking-level (plist-get snapshot :thinkingLevel)
                :session-id (plist-get session :id)
                :session-file (pilish--shared-session-file session)
                :message-count (and (vectorp messages) (length messages))
                :pending-message-count (plist-get pilish--state :pending-message-count))
          pilish--session-name (and (stringp name) name))))

(defun pilish--shared-rebuild (snapshot)
  "Rebuild the current chat's transcript from SNAPSHOT in place.
Work in flight at the snapshot follows as replayed events, so the chat
starts without it: idle, unless a prompt of its own awaits its start."
  (setq pilish--status (if (and (eq pilish--status 'sending)
                                (pilish--prompt-start-wait-active-p))
                           'sending
                         'idle)
        pilish--pre-compaction-status nil
        pilish--assistant-header-shown nil
        pilish--in-thinking-block nil
        pilish--in-code-block nil
        pilish--line-parse-state 'line-start
        pilish--local-user-message nil)
  (pilish--clear-local-user-message-region)
  (when (eq pilish--status 'idle)
    (pilish--set-activity-phase "idle"))
  (pilish--shared-apply-session-state snapshot)
  (pilish--display-session-history (plist-get snapshot :messages) (current-buffer))
  (when pilish--process
    (pilish--dialog-reanchor (current-buffer)))
  (force-mode-line-update t))

(defun pilish--shared-adopt-session (proc snapshot)
  "Make the current chat show the session of PROC's SNAPSHOT.
Another frontend or an extension replaced Pi's session.  The chat keeps
its process, draft and queued follow-ups.  Its buffers move to the session's
directory, under a free name if another chat has theirs there."
  (let* ((followups pilish--followup-queue)
         (prompt-wait pilish--prompt-wait)
         (dir (pilish--shared-session-directory
               (plist-get (plist-get snapshot :session) :cwd))))
    (when (and dir (not (equal dir (file-name-as-directory
                                    (pilish--chat-session-directory)))))
      (pilish--retarget-session-identity dir (pilish--shared-free-session-name dir)))
    (pilish--reset-session-state)
    (setq pilish--followup-queue followups
          pilish--prompt-wait prompt-wait)
    (pilish--queue-changed)
    (pilish--shared-rebuild snapshot)
    (pilish--answer-history-loaded)
    (pilish--refresh-header)
    (pilish--refresh-commands proc)
    (pilish--note-session-identity)))

(defun pilish--shared-session-directory (cwd)
  "Return Pi's session CWD as a session directory of the current chat, or nil."
  (when-let* ((path (pilish--passive-emacs-path
                     (pilish--normalize-string-or-null cwd)
                     (pilish--chat-session-directory))))
    (file-name-as-directory path)))

(defun pilish--shared-free-session-name (dir)
  "Return the current chat's session name if free in DIR, else a free number."
  (let ((name (pilish--chat-session-name))
        (number 1))
    (while (or (pilish--find-session dir name)
               (get-buffer (pilish--buffer-name :chat dir name))
               (get-buffer (pilish--buffer-name :input dir name)))
      (setq name (number-to-string (setq number (1+ number)))))
    name))

(provide 'pilish-shared)
;;; pilish-shared.el ends here
