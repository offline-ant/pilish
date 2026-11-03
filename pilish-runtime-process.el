;;; pilish-runtime-process.el --- Detached runtime transport -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The short-lived compiled pimux launcher commits ownership before returning a
;; receipt.  Pilish then opens a direct Unix socket as an ordinary peer.  Closing
;; this transport never sends EOF or a signal to Pi.  Only explicit control stops
;; a runtime.  An unavailable transport never causes an implicit second launch.

;;; Code:

(require 'pilish-shared)

(defvar pilish-runtime-pi-executable nil
  "Absolute Pi executable of the configured immutable release.")
(defvar pilish-runtime-pimux-executable nil
  "Absolute compiled pimux executable of the configured immutable release.")
(defvar pilish-runtime-task-status-executable nil
  "Absolute read-only task-status executable of the configured release.")
(defvar pilish-runtime-pi-version "1.4.0"
  "Exact host version passed to the managed launcher.")
(defvar pilish-runtime-pi-sha256 nil
  "Optional release entry-point digest passed to the managed launcher.")
(defvar pilish-runtime-mode 'unshared
  "Selected launch mode: `unshared' or `detached'.")
(defvar-local pilish--runtime nil
  "Retained runtime identity, independent of its current transport.")
(defvar-local pilish--runtime-launcher nil
  "This view's uncommitted launcher process, if any.")
(defvar-local pilish--runtime-ready-callback nil
  "Callback awaiting this view's authoritative live boundary.")
(defvar pilish-session-closed-functions nil
  "Functions called with CHAT before its terminated view is removed.
Public session/runtime/desktop accessors remain available during notification.
This hook never runs for transport loss, frontend exit or local disconnection.
Observers must not dispose the buffers.  Failures are retained as diagnostics;
remaining observers and teardown still run, and Close reports the errors.")
(defvar-local pilish--runtime-close-callbacks nil
  "Callbacks waiting for authoritative termination of this view's runtime.")
(defvar-local pilish--runtime-close-timer nil
  "Bounded wait for a dispatched worker cancellation.")
(defvar-local pilish--runtime-task-timer nil
  "Read-only polling of this view's captured worker task evidence.")
(defvar-local pilish--runtime-retiring nil
  "Non-nil while authoritative retirement owns this view's teardown.")

(declare-function pilish--runtime-retire-view "pilish-runtime" (chat))
(declare-function pilish--runtime-finish-close "pilish-runtime" (chat error))
(declare-function pilish--runtime-worker-terminated "pilish-runtime-task" (chat))
(declare-function pilish--runtime-task-cancel-poll "pilish-runtime-task" ())

(declare-function pilish-session-process "pilish" (chat-buffer))
(declare-function pilish-session-directory "pilish" (chat-buffer))
(declare-function pilish-session-name "pilish" (chat-buffer))
(declare-function pilish-list-runtimes "pilish-runtime" ())

(defun pilish--runtime-once (callback)
  "Return a CALLBACK wrapper accepting one error argument at most once."
  (let (called)
    (lambda (error)
      (unless called
        (setq called t)
        (when callback (funcall callback error))))))

(defun pilish-runtime-configured-p ()
  "Return non-nil when managed detached launches are explicitly configured."
  (eq pilish-runtime-mode 'detached))

(defun pilish--note-desktop-state ()
  "Notify observers after this view's runtime identity or availability changes."
  (pilish--note-desktop-local-state)
  (pilish--note-session-identity))

(defun pilish--runtime-process-identity (pid)
  "Return Linux PID's exact start/boot identity, or nil when not live.
Unreadable metadata is not proof of termination.  This function never signals."
  (when (and (integerp pid) (> pid 0))
    (condition-case nil
        (let* ((stat (with-temp-buffer
                       (insert-file-contents (format "/proc/%d/stat" pid))
                       (buffer-string)))
               (fields (and (string-match ") \\([^\n]+\\)" stat)
                            (split-string (substring stat (match-beginning 1)))))
               (start (nth 19 fields))
               (boot (with-temp-buffer
                       (insert-file-contents "/proc/sys/kernel/random/boot_id")
                       (string-trim (buffer-string)))))
          (when (and start (string-match-p "\\`[0-9]+\\'" start)
                     (not (member (car fields) '("Z" "X"))))
            (list :pid pid :start-time start :boot-id boot)))
      (file-error nil))))

(defun pilish--runtime-normalize (record)
  "Return discovery or launcher RECORD as the public runtime identity."
  (let* ((pi (plist-get record :piIdentity))
         (pid (plist-get record :piPid))
         (identity (or (and pi (listp pi) (not (eq pi :null))
                            (list :pid pid :start-time (plist-get pi :startTime)
                                  :boot-id (plist-get pi :bootId)))
                       (pilish--runtime-process-identity pid)))
         (owner (plist-get record :ownerIdentity))
         (owner-observed (pilish--runtime-process-identity (plist-get record :pid)))
         (session (plist-get record :session)))
    (list :protocol (plist-get record :protocol)
          :owner-start-time (or (plist-get owner :startTime) (plist-get owner-observed :start-time))
          :owner-boot-id (or (plist-get owner :bootId) (plist-get owner-observed :boot-id))
          :mux-id (plist-get record :muxId) :socket (plist-get record :socket)
          :pid (plist-get record :pid) :pi-pid pid
          :pi-start-time (plist-get identity :start-time)
          :pi-boot-id (plist-get identity :boot-id)
          :operation-id (plist-get record :operationId)
          :session-file (or (plist-get record :sessionFile)
                            (and (listp session) (plist-get session :file)))
          :directory (plist-get record :cwd)
          :placement (or (plist-get record :placement) "root")
          :parent (plist-get record :parent)
          :orchestration (plist-get record :orchestration)
          :state (if (equal (plist-get record :state) "stopped") "stopped"
                   (or (plist-get record :status) "disconnected")))))

(defun pilish--runtime-environment (environment)
  "Return launcher environment with explicit per-session ENVIRONMENT."
  (let ((process-environment (copy-sequence process-environment)))
    (dolist (entry (reverse environment)) (setenv (car entry) (cdr entry)))
    (setenv "PHIMACS_PI_VERSION" pilish-runtime-pi-version)
    (when pilish-runtime-pi-sha256
      (setenv "PHIMACS_PI_SHA256" pilish-runtime-pi-sha256))
    process-environment))

(defun pilish--runtime-call (arguments directory environment callback)
  "Run compiled pimux ARGUMENTS in DIRECTORY with ENVIRONMENT.
CALLBACK receives (value error).  Its bounded receipt is never treated as an
RPC transport.  Cancellation kills only this launcher, whose provisional IPC
protocol owns cleanup; a committed runtime is left available for attachment."
  (unless (and (stringp pilish-runtime-pimux-executable)
               (file-name-absolute-p pilish-runtime-pimux-executable)
               (file-executable-p pilish-runtime-pimux-executable))
    (error "Configure an absolute compiled release pimux executable first"))
  (let* ((default-directory directory)
         (process-environment (pilish--runtime-environment environment))
         (output "") (stderr (generate-new-buffer " *pilish-runtime-diagnostic*"))
         (completed nil) timer process
         (finish (lambda (value error)
                   (unless completed
                     (setq completed t)
                     (when timer (cancel-timer timer))
                     (when (buffer-live-p stderr) (kill-buffer stderr))
                     (funcall callback value error)))))
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name "pilish-runtime-launcher" :noquery t :connection-type 'pipe
                 :command (cons pilish-runtime-pimux-executable arguments)
                 :stderr stderr
                 :filter (lambda (proc chunk)
                           (if (> (+ (string-bytes output) (string-bytes chunk))
                                  (* 4 1024 1024))
                               (progn
                                 (funcall finish nil "Runtime receipt exceeds its bound; outcome uncertain")
                                 (delete-process proc))
                             (setq output (concat output chunk))))
                 :sentinel
                 (lambda (proc _event)
                   (unless (process-live-p proc)
                     (if (zerop (process-exit-status proc))
                         (condition-case parse-error
                             (funcall finish
                                      (json-parse-string (string-trim output)
                                                         :object-type 'plist)
                                      nil)
                           (error (funcall finish nil (error-message-string parse-error))))
                       (let ((diagnostic
                              (when (buffer-live-p stderr)
                                (with-current-buffer stderr
                                  (buffer-substring-no-properties
                                   (max (point-min) (- (point-max) 4096))
                                   (point-max))))))
                         (funcall finish nil
                                  (format "Runtime control failed; reconcile before retry: %s"
                                          (or diagnostic "launcher exited")))))))))
          (when-let* ((error-process (get-buffer-process stderr)))
            (set-process-filter
             error-process
             (lambda (_proc chunk)
               (when (buffer-live-p stderr)
                 (with-current-buffer stderr
                   (goto-char (point-max)) (insert chunk)
                   (when (> (buffer-size) 65536)
                     (delete-region (point-min) (- (point-max) 65536))))))))
          (setq timer (run-at-time
                       45 nil (lambda ()
                                (funcall finish nil "Runtime control timed out; outcome uncertain, no retry was sent")
                                (when (process-live-p process) (delete-process process)))))
          process)
      (error
       (funcall finish nil (error-message-string err))
       nil))))

(defun pilish--runtime-private-socket-p (socket)
  "Return non-nil for a same-user private local SOCKET and its directory."
  (and (stringp socket) (file-name-absolute-p socket)
       (not (file-remote-p socket))
       (not (file-symlink-p socket))
       (condition-case nil
           (let* ((directory (directory-file-name (file-name-directory socket)))
                  (attributes (file-attributes socket 'integer))
                  (parent (file-attributes directory 'integer)))
             (and attributes parent
                  (eq (aref (file-attribute-modes attributes) 0) ?s)
                  (eq (file-attribute-type parent) t)
                  (equal directory (file-truename directory))
                  (equal (file-attribute-user-id attributes) (user-uid))
                  (equal (file-attribute-user-id parent) (user-uid))
                  (zerop (logand #o077 (file-modes socket)))
                  (zerop (logand #o077 (file-modes directory)))))
         (file-error nil))))

(defun pilish--runtime-complete-ready (chat error)
  "Settle CHAT's pending ready callback once, with ERROR or nil."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (when-let* ((callback pilish--runtime-ready-callback))
        (setq pilish--runtime-ready-callback nil)
        (funcall callback error)))))

(defun pilish--runtime-accept-hello (process hello)
  "Validate PROCESS's protocol-2 HELLO against its expected runtime identity."
  (let ((runtime (process-get process 'pilish-runtime-expect)))
    (unless (and runtime (equal (plist-get hello :protocol) 2)
                 (not (plist-member hello :role))
                 (equal (plist-get hello :muxId) (plist-get runtime :mux-id))
                 (equal (plist-get hello :piPid) (plist-get runtime :pi-pid))
                 (equal (plist-get hello :socket) (plist-get runtime :socket))
                 (cl-every (lambda (capability)
                             (member capability (append (plist-get hello :capabilities) nil)))
                           '("snapshot" "stop" "detached" "contextual-input")))
      (error "Unsupported or mismatched pimux owner; no duplicate launch attempted"))
    (let ((identity (pilish--runtime-process-identity (plist-get runtime :pi-pid))))
      (unless (and identity
                   (equal (plist-get identity :start-time) (plist-get runtime :pi-start-time))
                   (equal (plist-get identity :boot-id) (plist-get runtime :pi-boot-id)))
        (error "Owned Pi process identity changed or is unavailable")))
    (process-put process 'pilish-mux-awaiting-snapshot t)
    (process-put process 'pilish-mux hello)))

(defun pilish--runtime-note-snapshot (process snapshot)
  "Update PROCESS's retained identity from its authoritative SNAPSHOT."
  (let ((chat (process-get process 'pilish-chat-buffer))
        (session (plist-get snapshot :session)))
    (unless (and (stringp (plist-get session :file))
                 (file-name-absolute-p (plist-get session :file))
                 (stringp (plist-get session :cwd))
                 (file-name-absolute-p (plist-get session :cwd)))
      (error "Detached snapshot lacks an exact persisted session identity"))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (setq pilish--runtime (plist-put pilish--runtime :session-file (plist-get session :file)))
        (setq pilish--runtime (plist-put pilish--runtime :directory (plist-get session :cwd)))
        (setq pilish--runtime (plist-put pilish--runtime :state "synchronizing"))
        (pilish--note-desktop-state)))))

(defun pilish--runtime-live (process)
  "Enable PROCESS's view after its authoritative snapshot/replay boundary."
  (when-let* ((chat (process-get process 'pilish-chat-buffer))
              ((buffer-live-p chat)))
    (with-current-buffer chat
      (setq pilish--runtime (plist-put pilish--runtime :state "live"))
      (when-let* ((timer (process-get process 'pilish-runtime-ready-timer)))
        (cancel-timer timer)
        (process-put process 'pilish-runtime-ready-timer nil))
      (pilish--note-desktop-state)
      (pilish--runtime-complete-ready chat nil))))

(defun pilish--runtime-snapshot-failed (process reason)
  "Keep PROCESS's view unavailable after snapshot failure REASON."
  (when-let* ((chat (process-get process 'pilish-chat-buffer))
              ((buffer-live-p chat)))
    (with-current-buffer chat
      (setq pilish--runtime (plist-put pilish--runtime :state "unavailable"))
      (pilish--note-desktop-state)
      (pilish--runtime-complete-ready chat (format "Snapshot unavailable: %s" reason)))))

(defun pilish--runtime-note-exit (process event)
  "Record authoritative PROCESS termination EVENT, never infer it from EOF."
  (when-let* ((chat (process-get process 'pilish-chat-buffer))
              ((buffer-live-p chat)))
    (with-current-buffer chat
      (when (eq process pilish--process)
        (setq pilish--runtime (plist-put pilish--runtime :state "stopped"))
        (setq pilish--runtime (plist-put pilish--runtime :exit event))
        (if (equal (plist-get pilish--runtime :placement) "worker")
            (pilish--runtime-worker-terminated chat)
          (pilish--runtime-retire-view chat))))))

(defun pilish--runtime-transport-exit (process)
  "Preserve runtime identity when PROCESS's frontend transport disappears."
  (when (process-get process 'pilish-detached)
    (when-let* ((timer (process-get process 'pilish-runtime-ready-timer)))
      (cancel-timer timer))
    (when-let* ((chat (process-get process 'pilish-chat-buffer))
                ((buffer-live-p chat)))
      (with-current-buffer chat
        (when (eq process pilish--process)
          (unless (equal (plist-get pilish--runtime :state) "stopped")
            (setq pilish--runtime (plist-put pilish--runtime :state "disconnected")))
          (pilish--quarantine-local-work
           "Transport disconnected; delivery is uncertain" (pilish--draft-context))
          (pilish--note-desktop-state)
          (unless (and (equal (plist-get pilish--runtime :placement) "worker")
                       (plist-get pilish--runtime :task-cancel-requested))
            (pilish--runtime-finish-close chat "Close outcome uncertain after disconnection; reconnect or reconcile the retained identity"))
          (pilish--runtime-complete-ready chat "Disconnected before readiness; reconnect explicitly"))))))

(defun pilish--runtime-register-socket (process chat runtime)
  "Associate PROCESS with CHAT and expected RUNTIME before accepting records."
  (unless (process-get process 'pilish-detached)
    (process-put process 'pilish-detached t)
    ;; Generic buffer/Emacs exit only disconnects this socket, so it must
    ;; not ask the native-Pi termination question.
    (process-put process 'pilish-skip-kill-confirmation t)
    (process-put process 'pilish-runtime-expect runtime)
    (process-put process 'pilish-chat-buffer chat)
    (process-put process 'pilish-mux-awaiting-snapshot t)
    (set-process-buffer process chat)
    (with-current-buffer chat
      (pilish--set-process process)
      (pilish--register-display-handler process))))

(defun pilish--runtime-connect (chat runtime callback)
  "Connect CHAT directly to RUNTIME; call CALLBACK only after live or failure."
  (with-current-buffer chat
    (setq callback (pilish--runtime-once callback))
    (when pilish--runtime-ready-callback
      (pilish--runtime-complete-ready chat "Connection replaced by explicit reconnect"))
    (when (and (processp pilish--process) (process-live-p pilish--process))
      (delete-process pilish--process))
    (let ((next (plist-put (copy-tree runtime) :state "synchronizing")))
      (if (cl-every (lambda (key) (equal (plist-get runtime key) (plist-get pilish--runtime key)))
                    '(:mux-id :socket :pi-pid :pi-start-time :pi-boot-id :parent :placement))
          ;; Discovery does not contain this equal client's cancellation history.
          ;; Reconnection must not unpin the task or rearm ambiguous slash input.
          (dolist (key '(:task-binding :task-status :task-cancel-requested :task-error))
            (when (plist-member pilish--runtime key)
              (setq next (plist-put next key (copy-tree (plist-get pilish--runtime key))))))
        (pilish--runtime-task-cancel-poll)
        (pilish--runtime-finish-close chat "View reconnected to a different runtime"))
      (setq pilish--runtime next
            pilish--runtime-ready-callback callback))
    (condition-case err
        (progn
          (unless (pilish--runtime-private-socket-p (plist-get runtime :socket))
            (error "Runtime socket is missing or not same-user/private"))
          (let ((process
                 (make-network-process
                  :name "pilish-runtime" :family 'local
                  :service (plist-get runtime :socket) :noquery t
                  :coding 'utf-8-unix
                  :filter (lambda (proc output)
                            (pilish--runtime-register-socket proc chat runtime)
                            (pilish--process-filter proc output))
                  :sentinel #'pilish--process-sentinel)))
            (pilish--runtime-register-socket process chat runtime)
            (process-put process 'pilish-runtime-ready-timer
                         (run-at-time
                          30 nil (lambda ()
                                   (when (and (buffer-live-p chat)
                                              (eq process (pilish-session-process chat))
                                              (not (pilish--shared-input-ready-p process)))
                                     (pilish--runtime-snapshot-failed process "Readiness timed out")
                                     (delete-process process)))))
            (pilish--note-desktop-state)
            process))
      (error
       (setq pilish--runtime (plist-put pilish--runtime :state "unavailable"))
       (pilish--note-desktop-state)
       (pilish--runtime-complete-ready chat (error-message-string err))
       nil))))

(defun pilish--runtime-start-view (chat directory args environment callback)
  "Explicitly launch a runtime for CHAT in DIRECTORY with ARGS/ENVIRONMENT.
CALLBACK takes nil/error once.  No initial prompt or inferred recovery is sent."
  (with-current-buffer chat
    (setq callback (pilish--runtime-once callback))
    (when (or (process-live-p pilish--runtime-launcher)
              (process-live-p pilish--process))
      (error "This view already has an active launch or transport"))
    (setq pilish--runtime (list :protocol 2 :state "starting"
                               :session-file (plist-get pilish--state :session-file)))
    (let ((command (append (list "start" "--json" "--" pilish-runtime-pi-executable
                                 "--mode" "rpc")
                           pilish-extra-args (pilish--project-trust-args) args)))
      (setq pilish--runtime-launcher
            (pilish--runtime-call
             command directory environment
             (lambda (receipt error)
               (when (buffer-live-p chat)
                 (with-current-buffer chat
                   (setq pilish--runtime-launcher nil)
                   (if (or error
                           (not (and (equal (plist-get receipt :protocol) 2)
                                     (equal (plist-get receipt :state) "committed")
                                     (member (plist-get receipt :outcome) '("started" "attached")))))
                       (progn
                         (setq pilish--runtime (plist-put pilish--runtime :state "unavailable"))
                         (pilish--add-chat-notice
                          (or error "Invalid runtime commitment receipt; inspect discovery") 'pilish-error-notice)
                         (pilish--note-desktop-state)
                         (when callback (funcall callback (or error "Invalid runtime commitment receipt"))))
                     (condition-case failure
                         (let ((runtime (seq-find
                                         (lambda (item)
                                           (equal (plist-get item :mux-id) (plist-get receipt :muxId)))
                                         (pilish-list-runtimes))))
                           (unless (and runtime
                                        (equal (plist-get runtime :pi-pid) (plist-get receipt :piPid))
                                        (equal (plist-get runtime :socket) (plist-get receipt :socket)))
                             (error "Committed runtime discovery unavailable; inspect its retained receipt"))
                           ;; Preserve authoritative task/host placement.  The
                           ;; launch receipt alone must not promote a worker to root.
                           (pilish--runtime-connect chat runtime callback))
                       (error
                        (setq pilish--runtime (pilish--runtime-normalize receipt))
                        (setq pilish--runtime (plist-put pilish--runtime :state "unavailable"))
                        (pilish--note-desktop-state)
                        (when callback (funcall callback (error-message-string failure))))))))))))
    (pilish--note-desktop-state)))

(defun pilish--runtime-kill-view ()
  "Disconnect this view; cancel only its own uncommitted launcher, if any."
  (pilish--runtime-task-cancel-poll)
  (when pilish--runtime-close-timer
    (cancel-timer pilish--runtime-close-timer)
    (setq pilish--runtime-close-timer nil))
  (pilish--runtime-finish-close (current-buffer) "View disconnected before close was acknowledged")
  (when (process-live-p pilish--runtime-launcher)
    (delete-process pilish--runtime-launcher))
  (when (and pilish--runtime (process-live-p pilish--process))
    (delete-process pilish--process)))

(add-hook 'pilish--process-exit-functions #'pilish--runtime-transport-exit)

(provide 'pilish-runtime-process)
;;; pilish-runtime-process.el ends here
