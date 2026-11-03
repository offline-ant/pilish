;;; pilish-shared.el --- Authoritative symmetric pimux views -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Protocol 2 has equal socket clients, not a primary frontend.  The core/runtime
;; validate the hello and owned Pi identity before accepting commands.  This
;; module applies exact snapshot/replay/live boundaries.  Every snapshot adopts
;; the current session, branch, model and thinking level; history failure never
;; leaves the old transcript under a new identity.  Local input is context-bound
;; by pilish-drafts before replay can settle a run or release any local follow-up.
;; Dialogs close only on authoritative closure, timeout or snapshot reconciliation.

;;; Code:

(require 'pilish-menu)
(require 'pilish-drafts)

(declare-function pilish--runtime-note-snapshot "pilish-runtime" (proc snapshot))
(declare-function pilish--runtime-live "pilish-runtime" (proc))
(declare-function pilish--runtime-snapshot-failed "pilish-runtime" (proc error))
(declare-function pilish--valid-input-context-p "pilish-core" (context))

(defun pilish-session-mux (chat-buffer)
  "Return CHAT-BUFFER's validated protocol-2 hello, or nil.
This identifies a shared transport, not a frontend-owned Pi process."
  (when (buffer-live-p chat-buffer)
    (pilish--process-shared-p (buffer-local-value 'pilish--process chat-buffer))))

(defun pilish--shared-input-ready-p (proc)
  "Return non-nil after PROC's current authoritative snapshot reached live."
  (and (pilish--process-shared-p proc)
       (not (process-get proc 'pilish-mux-awaiting-snapshot))
       (not (process-get proc 'pilish-mux-snapshot))
       (integerp (process-get proc 'pilish-mux-live-generation))
       (equal (process-get proc 'pilish-mux-live-generation)
              (process-get proc 'pilish-mux-generation))
       (equal (process-get proc 'pilish-mux-applied-generation)
              (process-get proc 'pilish-mux-generation))
       (or (not (process-get proc 'pilish-detached))
           (pilish--valid-input-context-p
            (process-get proc 'pilish-input-context)))))

(defun pilish--shared-wait-for-snapshot (proc generation)
  "Discard unfinished replay/paints and wait for PROC's GENERATION boundary."
  (when (and (integerp generation)
             (> generation (max (or (process-get proc 'pilish-mux-min-generation) 0)
                                (or (process-get proc 'pilish-mux-generation) 0))))
    (process-put proc 'pilish-mux-min-generation generation)
    (process-put proc 'pilish-mux-awaiting-snapshot t)
    (process-put proc 'pilish-mux-snapshot nil)
    (process-put proc 'pilish-mux-applied-generation nil)
    (process-put proc 'pilish-input-context nil)
    (pilish--cancel-stream-delta-flush)
    (pilish--cancel-tool-update-flush)
    (pilish--cancel-tool-times-state)
    ;; The missing records may include this run's settlement.
    (pilish--reset-run-clock)))

(defun pilish--shared-handle-record (event)
  "Handle the pimux EVENT for the current chat's validated transport."
  (let ((proc pilish--process))
    (when (pilish--process-shared-p proc)
      (pcase (plist-get event :type)
        ("pimux_dialog_closed"
         (pilish--extension-dialog-close proc (plist-get event :id)))
        ((or "pimux_gap" "pimux_session_changed" "pimux_tree_changed")
         (pilish--shared-wait-for-snapshot proc (plist-get event :generation)))
        ("pimux_snapshot" (pilish--shared-apply-snapshot proc event))
        ("pimux_live" (pilish--shared-finish-snapshot proc event))
        ("pimux_snapshot_failed"
         (let ((generation (plist-get event :generation)))
           (when (and (integerp generation)
                      (>= generation (or (process-get proc 'pilish-mux-min-generation) 0))
                      (>= generation (or (process-get proc 'pilish-mux-generation) 0))
                      (> generation (or (process-get proc 'pilish-mux-live-generation) 0)))
             (pilish--shared-snapshot-application-failed
              proc (plist-get event :error) (pilish--draft-context)))))
        ("pimux_editor_text" (pilish--recover-editor-notice proc event))
        ("pimux_model_changed"
         (setq pilish--state (plist-put pilish--state :model (plist-get event :model)))
         (force-mode-line-update t))))))

;;;; Snapshots

(defun pilish--shared-replaying-p ()
  "Return non-nil while this chat's transport replays an authoritative snapshot."
  (and (processp pilish--process)
       (process-get pilish--process 'pilish-mux-snapshot) t))

(defun pilish--shared-snapshot-application-failed (proc reason context)
  "Invalidate PROC's input after snapshot failure REASON.
Suspend local work bound to CONTEXT without losing the authoritative identity."
  ;; Close the gate before any rendering, recovery or integration callback can
  ;; fail.  A following live record must not commit this unsuccessful boundary.
  (process-put proc 'pilish-mux-snapshot nil)
  (process-put proc 'pilish-mux-awaiting-snapshot t)
  (process-put proc 'pilish-mux-applied-generation nil)
  (process-put proc 'pilish-input-context nil)
  (process-put proc 'pilish-mux-application-error reason)
  (pilish--quarantine-local-work "snapshot-application-failed" context)
  (when (fboundp 'pilish--runtime-snapshot-failed)
    (pilish--runtime-snapshot-failed proc reason))
  (pilish--add-chat-notice
   (format "Shared snapshot failed: %s. Reconnect explicitly; input is not ready." reason)
   'pilish-error-notice))

(defun pilish--shared-apply-snapshot (proc snapshot)
  "Rebuild the current chat from PROC's SNAPSHOT before any replay arrives."
  (let ((generation (plist-get snapshot :generation))
        (run (plist-get snapshot :run))
        (old-context (pilish--draft-context)))
    (when (and (integerp generation)
               (> generation (or (process-get proc 'pilish-mux-generation) 0))
               (>= generation (or (process-get proc 'pilish-mux-min-generation) 0)))
      (process-put proc 'pilish-mux-generation generation)
      (process-put proc 'pilish-mux-snapshot snapshot)
      (process-put proc 'pilish-mux-awaiting-snapshot t)
      (process-put proc 'pilish-mux-applied-generation nil)
      (process-put proc 'pilish-input-context nil)
      (condition-case err
          (progn
            ;; A newer boundary abandons unfinished buffered output from the old one.
            (pilish--cancel-stream-delta-flush)
            (pilish--cancel-tool-update-flush)
            (pilish--cancel-tool-times-state)
            (dolist (request (pilish--extension-dialog-pending proc))
              (pilish--extension-dialog-set proc (plist-get request :id) :pilish-stale t))
            ;; Adopt authoritative runtime identity even when history is unavailable.
            (when (fboundp 'pilish--runtime-note-snapshot)
              (pilish--runtime-note-snapshot proc snapshot))
            (pilish--draft-adopt-context snapshot)
            (if (pilish--shared-session-moved-p snapshot)
                (pilish--shared-adopt-session proc snapshot)
              (pilish--shared-rebuild snapshot))
            (when (or (plist-get snapshot :historyError)
                      (not (vectorp (plist-get snapshot :messages)))
                      (not (vectorp (plist-get snapshot :entries))))
              (error "Snapshot history is incomplete; a full resynchronization is required"))
            (when (and (process-get proc 'pilish-detached)
                       (not (pilish--valid-input-context-p
                             (plist-get snapshot :inputContext))))
              (error "Snapshot has no valid owning input context"))
            (process-put proc 'pilish-mux-stale-ui (pilish--shared-ui-keys))
            (setq pilish--settle-releases-streaming (eq (plist-get run :active) t))
            (when (and (eq (plist-get run :active) t)
                       (eq (plist-get run :tailTruncated) t))
              (process-put proc 'pilish-mux-refresh t)
              (pilish--add-chat-notice
               "Part of this run's output was lost; the full text follows when it ends."
               'pilish-retry-notice))
            (process-put proc 'pilish-input-context
                         (copy-tree (plist-get snapshot :inputContext)))
            (process-put proc 'pilish-mux-applied-generation generation)
            (process-put proc 'pilish-mux-application-error nil))
        (error
         (pilish--shared-snapshot-application-failed
          proc (error-message-string err) old-context))))))

(defun pilish--shared-session-moved-p (snapshot)
  "Return non-nil when SNAPSHOT names another file or session directory."
  (let* ((session (plist-get snapshot :session))
         (file (plist-get pilish--state :session-file))
         (new-file (pilish--shared-session-file session))
         (dir (pilish--shared-session-directory (plist-get session :cwd))))
    (or (and file (not (equal file new-file)))
        (and dir (not (equal dir (file-name-as-directory
                                  (pilish--chat-session-directory))))))))

(defun pilish--shared-ui-keys ()
  "Return the current statuses and widgets as a list of (KIND . KEY)."
  (append (mapcar (lambda (status) (cons 'status (car status)))
                  pilish--extension-status)
          (mapcar (lambda (widget) (cons 'widget (car widget)))
                  pilish--extension-widgets)))

(defun pilish--shared-note-ui-replay (proc event)
  "Keep the extension UI that PROC's replayed EVENT names."
  (when (and (pilish--process-shared-p proc)
             (process-get proc 'pilish-mux-snapshot))
    (process-put proc 'pilish-mux-stale-ui
                 (delete (pcase (plist-get event :method)
                           ("setStatus" (cons 'status (plist-get event :statusKey)))
                           ("setWidget" (cons 'widget (plist-get event :widgetKey))))
                         (process-get proc 'pilish-mux-stale-ui)))))

(defun pilish--shared-finish-snapshot (proc live)
  "Finish PROC's matching snapshot LIVE and reconcile unreplayed UI."
  (when (and (process-get proc 'pilish-mux-snapshot)
             (equal (plist-get live :generation)
                    (process-get proc 'pilish-mux-applied-generation))
             (equal (plist-get live :generation)
                    (plist-get (process-get proc 'pilish-mux-snapshot) :generation)))
    (condition-case err
        (progn
          (dolist (request (pilish--extension-dialog-pending proc))
            (when (plist-get request :pilish-stale)
              (pilish--extension-dialog-close proc (plist-get request :id))))
          (pcase-dolist (`(,kind . ,key) (process-get proc 'pilish-mux-stale-ui))
            (if (eq kind 'status)
                (pilish--extension-ui-set-status (list :statusKey key))
              (pilish--set-extension-widget key nil)))
          (process-put proc 'pilish-mux-stale-ui nil)
          (process-put proc 'pilish-mux-snapshot nil)
          (process-put proc 'pilish-mux-awaiting-snapshot nil)
          (process-put proc 'pilish-mux-live-generation (plist-get live :generation))
          (when (fboundp 'pilish--runtime-live) (pilish--runtime-live proc)))
      (error
       (pilish--shared-snapshot-application-failed
        proc (error-message-string err) (pilish--draft-context))))))

(defun pilish--shared-refresh-after-run (proc)
  "Request the full authoritative boundary after PROC's truncated run settled."
  (when (and (pilish--process-shared-p proc)
             (process-get proc 'pilish-mux-refresh))
    (process-put proc 'pilish-mux-refresh nil)
    (process-put proc 'pilish-mux-awaiting-snapshot t)
    (process-put proc 'pilish-mux-applied-generation nil)
    (process-put proc 'pilish-input-context nil)
    (pilish--rpc-async
     proc '(:type "pimux_bootstrap" :include ["entries" "messages"])
     (lambda (response)
       (unless (eq (plist-get response :success) t)
         (message "Pi: Shared session snapshot failed: %s"
                  (plist-get response :error)))))))

(defun pilish--shared-session-file (session)
  "Return snapshot SESSION's file as an Emacs path in the current chat."
  (pilish--passive-emacs-path
   (pilish--normalize-string-or-null (plist-get session :file))
   (pilish--chat-session-directory)))

(defun pilish--shared-apply-session-state (snapshot)
  "Set file, flat entries, leaf, model and thinking from SNAPSHOT."
  (let* ((session (plist-get snapshot :session))
         (messages (plist-get snapshot :messages))
         (name (plist-get session :name)))
    (setq pilish--state
          (list :status pilish--status :model (plist-get snapshot :model)
                :thinking-level (plist-get snapshot :thinkingLevel)
                :session-id (plist-get session :id)
                :session-file (pilish--shared-session-file session)
                :leaf-id (pilish--normalize-string-or-null (plist-get snapshot :leafId))
                :entries (plist-get snapshot :entries)
                :message-count (and (vectorp messages) (length messages))
                :pending-message-count (plist-get pilish--state :pending-message-count))
          pilish--session-name (and (stringp name) name))))

(defun pilish--shared-rebuild (snapshot)
  "Replace this chat's transcript with SNAPSHOT before replaying live work."
  (setq pilish--status (if (and (eq pilish--status 'sending)
                                (pilish--prompt-start-wait-active-p))
                           'sending 'idle)
        pilish--pre-compaction-status nil
        pilish--assistant-header-shown nil
        pilish--in-thinking-block nil
        pilish--in-code-block nil
        pilish--line-parse-state 'line-start
        pilish--local-user-message nil)
  (pilish--clear-local-user-message-region)
  (when (eq pilish--status 'idle) (pilish--set-activity-phase "idle"))
  (pilish--shared-apply-session-state snapshot)
  (pilish--display-session-history (plist-get snapshot :messages) (current-buffer))
  (when-let* ((error (or (plist-get snapshot :historyError)
                        (unless (plist-member snapshot :messages)
                          "The snapshot did not include message history"))))
    (pilish--add-chat-notice (format "History unavailable: %s" error)
                             'pilish-error-notice))
  (when pilish--process (pilish--dialog-reanchor (current-buffer)))
  (pilish--note-session-identity)
  (force-mode-line-update t))

(defun pilish--shared-adopt-session (proc snapshot)
  "Adopt PROC's authoritative SNAPSHOT identity in the existing view.
Context-bound local work was quarantined before entry; never preserve an old
prompt request or automatic follow-up across this reset."
  (let ((dir (pilish--shared-session-directory
              (plist-get (plist-get snapshot :session) :cwd)))
        (followups pilish--followup-queue)
        (prompt-wait pilish--prompt-wait))
    (when (and dir (not (equal dir (file-name-as-directory
                                    (pilish--chat-session-directory)))))
      (pilish--retarget-session-identity dir (pilish--shared-free-session-name dir)))
    (pilish--reset-session-state)
    ;; Only work left after the context guard can survive initial identity
    ;; adoption; a real replacement already suspended/invalidated its owners.
    (setq pilish--followup-queue followups pilish--prompt-wait prompt-wait)
    (pilish--queue-changed)
    (pilish--shared-rebuild snapshot)
    (pilish--answer-history-loaded)
    (pilish--refresh-header)
    (pilish--refresh-commands proc)))

(defun pilish--shared-session-directory (cwd)
  "Return snapshot CWD as an Emacs session directory, or nil."
  (when-let* ((path (pilish--passive-emacs-path
                     (pilish--normalize-string-or-null cwd)
                     (pilish--chat-session-directory))))
    (file-name-as-directory path)))

(defun pilish--shared-free-session-name (dir)
  "Return this chat's name if free in DIR, otherwise a free numbered name."
  (let ((name (pilish--chat-session-name)) (number 1))
    (while (or (pilish--find-session dir name)
               (get-buffer (pilish--buffer-name :chat dir name))
               (get-buffer (pilish--buffer-name :input dir name)))
      (setq name (number-to-string (setq number (1+ number)))))
    name))

(provide 'pilish-shared)
;;; pilish-shared.el ends here
