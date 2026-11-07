;;; pilish-runtime-task.el --- Equal-client worker task completion -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runtime exit is not parent-task cleanup.  Capture the owning task binding
;; before cancellation and accept only its final complete evidence.  Polling is
;; read-only, asynchronous and survives transport loss or a local waiter
;; timeout; disposing a view cancels its polling, never the parent or worker.
;; Only the exact owning parent can publish final evidence, so pending evidence
;; whose parent is dead stays uncertain and is not polled.

;;; Code:

(require 'pilish-runtime-process)

(declare-function pilish-session-runtime "pilish-runtime" (buffer))
(declare-function pilish--runtime-retire-view "pilish-runtime" (chat &optional original))
(declare-function pilish--runtime-definitely-dead-p "pilish-runtime" (runtime))
(declare-function pilish--runtime-terminal-receipt "pilish-runtime" (runtime))
(declare-function pilish--runtime-finish-close "pilish-runtime" (chat error))
(declare-function pilish-submit-prompt "pilish-ui" (chat-buffer text callback &optional behavior input-context))

(defun pilish--runtime-task-identity-p (left right)
  "Return non-nil for exact, well-formed JSON process identities LEFT and RIGHT."
  (and (listp left) (listp right)
       (integerp (plist-get left :pid)) (> (plist-get left :pid) 0)
       (cl-every (lambda (key) (let ((value (plist-get left key)))
                                (and (stringp value) (not (string-empty-p value)))))
                 '(:startTime :bootId))
       (cl-every (lambda (key) (equal (plist-get left key) (plist-get right key)))
                 '(:pid :startTime :bootId))))

(defun pilish--runtime-task-environment (runtime)
  "Return the task CLI's environment for RUNTIME's captured socket namespace.
Signal when the CLI is unconfigured or the namespace is not a local path."
  (unless (and (stringp pilish-runtime-task-status-executable)
               (file-name-absolute-p pilish-runtime-task-status-executable)
               (not (file-remote-p pilish-runtime-task-status-executable))
               (file-executable-p pilish-runtime-task-status-executable))
    (error "Configure an absolute task-status executable before closing workers"))
  (let ((socket (plist-get runtime :socket))
        (process-environment (copy-sequence process-environment)))
    (unless (and (stringp socket) (file-name-absolute-p socket) (not (file-remote-p socket)))
      (error "Worker task evidence requires the captured runtime socket namespace"))
    (setenv "PIMUX_DIR" (directory-file-name (file-name-directory socket)))
    process-environment))

(defun pilish--runtime-task-read (runtime)
  "Read and validate RUNTIME's owning task, signalling on unknown evidence.
Use the captured socket namespace, not this frontend's ambient PIMUX_DIR."
  (let ((process-environment (pilish--runtime-task-environment runtime))
        (default-directory temporary-file-directory))
    (with-temp-buffer
      (let ((status (process-file pilish-runtime-task-status-executable nil t nil
                                  "--id" (plist-get runtime :mux-id) "--json")))
        (pilish--runtime-task-parse runtime status (buffer-string))))))

(defun pilish--runtime-task-read-async (runtime callback)
  "Start reading RUNTIME's task evidence without blocking; return its process.
CALLBACK receives a function that returns the validated record or signals."
  (let ((process-environment (pilish--runtime-task-environment runtime))
        (default-directory temporary-file-directory)
        (output (generate-new-buffer " *pilish-task-evidence*" t)))
    (condition-case failure
        (make-process
         :name "pilish-task-evidence" :buffer output :noquery t :connection-type 'pipe
         :command (list pilish-runtime-task-status-executable
                        "--id" (plist-get runtime :mux-id) "--json")
         :sentinel (lambda (process _event)
                     (unless (process-live-p process)
                       (let ((status (process-exit-status process))
                             (text (if (buffer-live-p output)
                                       (with-current-buffer output (buffer-string))
                                     "")))
                         (when (buffer-live-p output) (kill-buffer output))
                         (funcall callback
                                  (lambda () (pilish--runtime-task-parse runtime status text)))))))
      (error (kill-buffer output) (signal (car failure) (cdr failure))))))

(defun pilish--runtime-task-parse (runtime status output)
  "Validate the task CLI's OUTPUT and exit STATUS for RUNTIME, or signal.
A retained :task-binding also pins the lease and both process identities."
  (let ((binding (plist-get runtime :task-binding))
        (worker (list :pid (plist-get runtime :pi-pid)
                      :startTime (plist-get runtime :pi-start-time)
                      :bootId (plist-get runtime :pi-boot-id))))
    (unless (eq 0 status)
      (error "Worker task evidence unavailable or unsafe; view retained: %s"
             (string-trim output)))
    (let* ((record (json-parse-string output :object-type 'plist))
           (owner (and (listp record) (plist-get record :parent))))
      (unless (and (listp record) (eq (plist-get record :schema) 1)
                   (equal (plist-get record :muxId) (plist-get runtime :mux-id))
                   (pilish--runtime-task-identity-p worker (plist-get record :worker))
                   (listp owner)
                   (pilish--runtime-task-identity-p (plist-get owner :process) (plist-get owner :process))
                   (stringp (plist-get owner :taskId))
                   (not (string-empty-p (plist-get owner :taskId)))
                   (stringp (plist-get record :leaseFile))
                   (file-name-absolute-p (plist-get record :leaseFile))
                   (member (plist-get record :state) '("pending" "complete" "failed"))
                   (if (equal (plist-get record :state) "failed")
                       (and (stringp (plist-get record :error))
                            (not (string-empty-p (plist-get record :error))))
                     (not (plist-member record :error)))
                   (or (null binding)
                       (and (equal (plist-get record :leaseFile) (plist-get binding :leaseFile))
                            (pilish--runtime-task-identity-p (plist-get binding :worker)
                                                             (plist-get record :worker))
                            (pilish--runtime-task-identity-p
                             (plist-get (plist-get binding :parent) :process) (plist-get owner :process))
                            (equal (plist-get (plist-get binding :parent) :taskId)
                                   (plist-get owner :taskId))
                            (equal (plist-get binding :muxId) (plist-get record :muxId)))))
        (error "Worker task evidence missing or identity/binding changed; view retained"))
      record)))

(defconst pilish--runtime-task-orphaned-message
  "Worker task owner exited before cleanup; outcome uncertain, view retained"
  "Report for pending evidence that its dead owning parent can never finish.")

(defun pilish--runtime-task-orphaned-p (record)
  "Return non-nil when pending RECORD's owning parent is known dead.
Only that exact parent process can publish final evidence, so it never will."
  (and (equal (plist-get record :state) "pending")
       (let ((owner (plist-get (plist-get record :parent) :process)))
         (pilish--runtime-identity-dead-p (plist-get owner :pid) (plist-get owner :startTime)
                                          (plist-get owner :bootId)))))

(defun pilish--runtime-task-awaitable-p (record)
  "Return non-nil when RECORD is pending and its owner can still finish it."
  (and (equal (plist-get record :state) "pending")
       (not (pilish--runtime-task-orphaned-p record))))

(defun pilish--runtime-task-same-view-p (chat runtime)
  "Return non-nil if CHAT still displays captured worker RUNTIME."
  (and (buffer-live-p chat)
       (let ((current (pilish-session-runtime chat)))
         (cl-every (lambda (key) (equal (plist-get runtime key) (plist-get current key)))
                   '(:mux-id :socket :pi-pid :pi-start-time :pi-boot-id :parent :placement)))))

(defun pilish--runtime-task-cancel-poll ()
  "Cancel this view's read-only task polling, including an in-flight read."
  (when pilish--runtime-task-timer
    (cancel-timer pilish--runtime-task-timer)
    (setq pilish--runtime-task-timer nil))
  (when-let* ((query pilish--runtime-task-query))
    (setq pilish--runtime-task-query nil)
    (let ((output (process-buffer query)))
      (delete-process query)
      (when (buffer-live-p output) (kill-buffer output)))))

(defun pilish--runtime-task-error (chat message)
  "Retain CHAT's task uncertainty MESSAGE and settle current waiters with error."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let ((report message))
        (unless (equal message (plist-get pilish--runtime :task-error))
          (setq pilish--runtime (plist-put pilish--runtime :task-error message))
          (condition-case failure
              (progn
                (pilish--add-chat-notice message 'pilish-error-notice)
                (pilish--note-desktop-state))
            ((error quit)
             (setq report (format "%s; recovery notification: %s" message (error-message-string failure))))))
        (pilish--runtime-finish-close chat report)))))

(defun pilish--runtime-task-apply (chat record)
  "Apply validated task RECORD to CHAT; only complete retires the view."
  (with-current-buffer chat
    (let ((new-binding (not (plist-get pilish--runtime :task-binding))))
      (when new-binding
        (setq pilish--runtime (plist-put pilish--runtime :task-binding (copy-tree record))))
      (setq pilish--runtime (plist-put pilish--runtime :task-status record))
      (pcase (plist-get record :state)
        ("pending"
         (when new-binding (pilish--note-desktop-state))
         (when (pilish--runtime-task-orphaned-p record)
           (pilish--runtime-task-cancel-poll)
           (pilish--runtime-task-error chat pilish--runtime-task-orphaned-message)))
        ("complete"
         (pilish--runtime-task-cancel-poll)
         (setq pilish--runtime (plist-put pilish--runtime :state "stopped")
               pilish--runtime (plist-put pilish--runtime :task-error nil))
         (pilish--runtime-retire-view chat))
        ("failed"
         (setq pilish--runtime (plist-put pilish--runtime :state "stopped"))
         (pilish--runtime-task-cancel-poll)
         (pilish--runtime-task-error chat (format "Worker task cleanup failed: %s" (plist-get record :error))))))))

(defun pilish--runtime-task-refresh (chat runtime)
  "Reconcile CHAT's captured RUNTIME against read-only final task evidence."
  (if (pilish--runtime-task-same-view-p chat runtime)
      (pilish--runtime-task-settle
       chat runtime (lambda () (pilish--runtime-task-read (pilish-session-runtime chat))))
    (pilish--runtime-task-view-changed chat)))

(defun pilish--runtime-task-view-changed (chat)
  "Stop CHAT's polling and settle waiters: it no longer shows the captured worker."
  (when (buffer-live-p chat)
    (with-current-buffer chat (pilish--runtime-task-cancel-poll))
    (pilish--runtime-finish-close chat "Worker identity changed; original Close cannot retire its replacement")))

(defun pilish--runtime-task-settle (chat runtime read)
  "Apply the evidence READ returns to CHAT while it still displays RUNTIME.
READ returns a validated record or signals its uncertainty."
  (condition-case failure
      (let ((record (funcall read)))
        (if (pilish--runtime-task-same-view-p chat runtime)
            (pilish--runtime-task-apply chat record)
          (when (buffer-live-p chat)
            (with-current-buffer chat (pilish--runtime-task-cancel-poll)))
          (pilish--runtime-finish-close chat "Worker identity changed while reading task evidence")))
    (error
     ;; A previous pending record cannot authorize repeated queries after
     ;; current evidence becomes missing, unsafe or identity-inconsistent.
     ;; Keep the pinned binding and local work for explicit reconciliation.
     (when (buffer-live-p chat)
       (with-current-buffer chat
         (pilish--runtime-task-cancel-poll)
         (setq pilish--runtime (plist-put pilish--runtime :task-status nil))))
     (pilish--runtime-task-error chat (error-message-string failure)))))

(defun pilish-reconcile-worker-task (buffer runtime)
  "Reconcile BUFFER with captured worker RUNTIME using read-only task evidence.
Pin mux/socket and actual Pi PID/start/boot identity, not optional frontend
metadata.  Never stop, prompt or reconnect.  Only validated complete evidence
retires chat/input through the ordinary recovery, observer and callback path.
Signal on missing, pending, failed or changed evidence and cleanup errors.
Return nil on success, including an already dead BUFFER."
  (when (buffer-live-p buffer)
    (let ((current (pilish-session-runtime buffer)))
      (unless (and (equal (plist-get current :placement) "worker")
                   (cl-every (lambda (key) (equal (plist-get runtime key) (plist-get current key)))
                             '(:mux-id :socket :pi-pid :pi-start-time :pi-boot-id)))
        (error "Worker identity changed; view retained"))
      (let ((record (pilish--runtime-task-read current)))
        (unless (pilish--runtime-task-same-view-p buffer current)
          (error "Worker identity changed while reading task evidence; view retained"))
        (let ((failure (pilish--runtime-task-apply buffer record)))
          (pcase (plist-get record :state)
            ("complete" (when failure (error "%s" failure)))
            ("failed" (error "Worker task cleanup failed: %s" (plist-get record :error)))
            (_ (error "%s" (if (pilish--runtime-task-orphaned-p record)
                               pilish--runtime-task-orphaned-message
                             "Worker task cleanup is pending; view retained"))))))))
  nil)

(defun pilish--runtime-task-start-poll (chat)
  "Poll CHAT only while its last validated task evidence can still become final.
A waiter timeout never fabricates success or recalls its settled callback.
Missing or invalid evidence, or a dead owning parent, stops polling until
explicit reconciliation.  Each read is asynchronous and the next one is
scheduled only after it settles, so pending views never block Emacs."
  (with-current-buffer chat
    (when (and (not pilish--runtime-task-timer) (not pilish--runtime-task-query)
               (pilish--runtime-task-awaitable-p (plist-get pilish--runtime :task-status)))
      (setq pilish--runtime-task-timer
            (run-at-time 0.25 nil #'pilish--runtime-task-poll chat (pilish-session-runtime chat))))))

(defun pilish--runtime-task-poll (chat runtime)
  "Start one asynchronous task-evidence read for CHAT's captured RUNTIME."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (when pilish--runtime-task-timer (cancel-timer pilish--runtime-task-timer))
      (setq pilish--runtime-task-timer nil))
    (if (not (pilish--runtime-task-same-view-p chat runtime))
        (pilish--runtime-task-view-changed chat)
      (condition-case failure
          (let (query)
            (setq query
                  (pilish--runtime-task-read-async
                   (pilish-session-runtime chat)
                   (lambda (read)
                     ;; A cancelled read is no longer this view's query.
                     (when (and (buffer-live-p chat)
                                (eq query (buffer-local-value 'pilish--runtime-task-query chat)))
                       (with-current-buffer chat (setq pilish--runtime-task-query nil))
                       (pilish--runtime-task-settle chat runtime read)
                       (when (buffer-live-p chat) (pilish--runtime-task-start-poll chat))))))
            (with-current-buffer chat (setq pilish--runtime-task-query query)))
        (error (pilish--runtime-task-settle
                chat runtime (lambda () (signal (car failure) (cdr failure)))))))))

(defun pilish--runtime-worker-terminated (chat)
  "Reconcile terminated worker CHAT, never equating runtime exit with cleanup."
  (pilish--runtime-task-refresh chat (pilish-session-runtime chat))
  (when (buffer-live-p chat) (pilish--runtime-task-start-poll chat)))

(defun pilish--runtime-cancellation-rejected-p (reply)
  "Return non-nil only when REPLY proves cancellation was rejected.
Socket exit, unknown replies and uncertain delivery cannot rearm input."
  (and (eq (plist-get reply :success) :false)
       (not (plist-get reply :processExit))
       (or (equal (plist-get reply :delivery) "rejected")
           (and (equal (plist-get reply :type) "response")
                (equal (plist-get reply :command) "prompt")
                (not (plist-member reply :delivery))))))

(defun pilish--runtime-worker-ended-p (runtime)
  "Return non-nil when pimux and dead processes prove RUNTIME ended.
Pimux's terminal receipt must name RUNTIME's exact mux and launch operation."
  (and (stringp (plist-get runtime :operation-id))
       (pilish--runtime-definitely-dead-p runtime)
       (equal (plist-get (pilish--runtime-terminal-receipt runtime) :operationId)
              (plist-get runtime :operation-id))))

(defun pilish--runtime-close-worker (chat callback)
  "Close worker CHAT through its owning task; CALLBACK identifies this request.
Failed final evidence, or pending evidence whose owning parent is dead, for a
worker that pimux proves ended retires the view, settling CALLBACK with that
failure: nothing else can finish its cleanup."
  (with-current-buffer chat
    (let* ((runtime (pilish-session-runtime chat))
           (record (pilish--runtime-task-read runtime))
           (failure (cond ((equal (plist-get record :state) "failed")
                           (format "Worker task cleanup failed: %s" (plist-get record :error)))
                          ((pilish--runtime-task-orphaned-p record)
                           pilish--runtime-task-orphaned-message))))
      (unless (pilish--runtime-task-same-view-p chat runtime)
        (error "Worker identity changed while reading task evidence; nothing sent"))
      (if (and failure (pilish--runtime-worker-ended-p runtime))
          (progn
            (pilish--runtime-task-cancel-poll)
            (setq pilish--runtime (plist-put pilish--runtime :state "stopped")
                  pilish--runtime (plist-put pilish--runtime :task-status record))
            (pilish--runtime-retire-view chat failure))
        (pilish--runtime-task-apply chat record))
      (when (and (buffer-live-p chat) (pilish--runtime-task-awaitable-p record))
        (setq pilish--runtime-close-timer
              (run-at-time 45 nil
                           (lambda ()
                             (pilish--runtime-task-error
                              chat "Worker task cleanup timed out; outcome uncertain, view retained"))))
        (if (plist-get pilish--runtime :task-cancel-requested)
            ;; A prior delivery may have succeeded.  Never replay ambiguous input.
            (pilish--runtime-task-start-poll chat)
          (unless (and (process-live-p pilish--process)
                       (pilish--shared-input-ready-p pilish--process))
            (error "Reconnect the worker or cancel its parent's request"))
          (let ((transport pilish--process)
                (context (pilish--capture-input-context pilish--process)))
            (pilish--rpc-async
             transport '(:type "get_commands")
             (lambda (response)
               (when (and (buffer-live-p chat)
                          (memq callback (buffer-local-value 'pilish--runtime-close-callbacks chat)))
                 (condition-case failure
                     (with-current-buffer chat
                       (unless (and (pilish--runtime-task-same-view-p chat runtime)
                                    (eq transport pilish--process)
                                    (equal context (pilish--capture-input-context transport)))
                         (error "Worker identity/context changed during command discovery; nothing sent"))
                       (let ((commands (plist-get (plist-get response :data) :commands)))
                         (unless (and (eq (plist-get response :success) t)
                                      (or (vectorp commands) (listp commands))
                                      (seq-some
                                       (lambda (command)
                                         (and (listp command)
                                              (equal (plist-get command :name) "worker-cancel")
                                              (equal (plist-get command :source) "extension")))
                                       commands))
                           (error "Worker does not advertise its worker-cancel extension command; no prompt sent")))
                       ;; Re-read after the asynchronous getter.  A final record
                       ;; or changed binding must never become slash-text input.
                       (let ((fresh (pilish--runtime-task-read (pilish-session-runtime chat))))
                         (unless (and (pilish--runtime-task-same-view-p chat runtime)
                                      (eq transport pilish--process)
                                      (equal context (pilish--capture-input-context transport)))
                           (error "Worker identity/context changed while reading task evidence; nothing sent"))
                         (pilish--runtime-task-apply chat fresh)
                         (when (pilish--runtime-task-awaitable-p fresh)
                           (setq pilish--runtime (plist-put pilish--runtime :task-cancel-requested t))
                           (pilish--runtime-task-start-poll chat)
                           (let ((pilish--close-cancellation-context (cons transport context)))
                             (pilish-submit-prompt
                              chat "/worker-cancel"
                              (lambda (reply)
                                (when (and (pilish--runtime-task-same-view-p chat runtime)
                                           (plist-get (pilish-session-runtime chat) :task-cancel-requested)
                                           (equal (plist-get (plist-get (pilish-session-runtime chat) :task-status) :state)
                                                  "pending")
                                           (not (eq (plist-get reply :success) t)))
                                  (with-current-buffer chat
                                    (when (pilish--runtime-cancellation-rejected-p reply)
                                      (setq pilish--runtime (plist-put pilish--runtime :task-cancel-requested nil)
                                            pilish--runtime (plist-put pilish--runtime :task-error nil))
                                      (unless (plist-get pilish--runtime :exit)
                                        (pilish--runtime-task-cancel-poll)))
                                    (pilish--runtime-task-error
                                     chat (or (plist-get reply :error)
                                              "Worker cancellation dispatch uncertain; view retained")))))
                              nil context))
                           (when (buffer-live-p chat) (pilish--note-desktop-state)))))
                   (error (pilish--runtime-task-error chat (error-message-string failure)))))))))))))

(provide 'pilish-runtime-task)
;;; pilish-runtime-task.el ends here
