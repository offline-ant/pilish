;;; pilish-runtime.el --- Public detached runtime and desktop API -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A view is not an agent.  Attach/reconnect never start a missing runtime.
;; The supervising service restores roots idle; desktop restore only reconnects.
;; The identity below survives
;; transport loss and identifies the actual owned Pi, not a network pseudo PID.
;; Ordinary unshared Pi remains an explicit supported mode.

;;; Code:

(require 'pilish-runtime-task)
(require 'pilish-grammars)

(declare-function pilish--session-environment "pilish" (chat-buf dir))
(declare-function pilish-session-file "pilish" (chat-buffer))
(declare-function pilish-session-name "pilish" (chat-buffer))
(declare-function pilish-session-directory "pilish" (chat-buffer))
(declare-function pilish-session-process "pilish" (chat-buffer))
(declare-function pilish-session-input-buffer "pilish" (chat-buffer))
(declare-function pilish-submit-prompt "pilish-ui" (chat-buffer text callback &optional behavior input-context))


(defun pilish-integration-capabilities ()
  "Return this fork's versioned, implemented integration capabilities."
  '(:api-version 1 :pimux-protocol 2 :symmetric-socket-client t
    :runtime-identity t :desktop-state t :stopped-view t
    :context-bound-input t :essential-grammar-installer 1 :managed-storage t
    :authoritative-close t))

(cl-defun pilish-configure-runtime
    (&key pi-executable pimux-executable task-status-executable (protocol 2) (mode 'detached))
  "Configure absolute PI-EXECUTABLE and PIMUX-EXECUTABLE without starting Pi.
PROTOCOL must be 2.  MODE is `detached' or explicit `unshared'.
TASK-STATUS-EXECUTABLE names the read-only worker task evidence CLI;
without it worker Close fails explicitly, without sending any input."
  (unless (memq mode '(detached unshared)) (error "Unsupported Pilish runtime mode"))
  (unless (equal protocol 2) (error "Pilish requires pimux protocol 2; no lifetime shim is supported"))
  (when (eq mode 'detached)
    (unless (and (eq system-type 'gnu/linux) (version<= "31.1" emacs-version))
      (error "Detached Pilish requires Linux and Emacs 31.1 or newer"))
    (dolist (file (list pi-executable pimux-executable))
      (unless (and (stringp file) (file-name-absolute-p file)
                   (not (file-remote-p file)) (file-executable-p file))
        (error "Configure absolute executable paths: %S" file)))
    (when task-status-executable
      (unless (and (stringp task-status-executable) (file-name-absolute-p task-status-executable)
                   (not (file-remote-p task-status-executable)) (file-executable-p task-status-executable))
        (error "Configure an absolute task-status executable: %S" task-status-executable))))
  (setq pilish-runtime-mode mode
        pilish-runtime-pi-executable pi-executable
        pilish-runtime-pimux-executable pimux-executable
        pilish-runtime-task-status-executable task-status-executable)
  (pilish-integration-capabilities))

(defun pilish--runtime-definitely-dead-p (runtime)
  "Return non-nil only when RUNTIME's wrapper and actual Pi are known dead."
  (cl-every
   (lambda (keys)
     (pilish--runtime-identity-dead-p (plist-get runtime (nth 0 keys))
                                      (plist-get runtime (nth 1 keys))
                                      (plist-get runtime (nth 2 keys))))
   '((:pid :owner-start-time :owner-boot-id)
     (:pi-pid :pi-start-time :pi-boot-id))))

(defun pilish-session-runtime (buffer)
  "Return BUFFER's plain retained runtime identity, or nil when unshared.
:pi-pid/:pi-start-time/:pi-boot-id identify the actual Pi.  :pid is its mux.
A disconnected socket is not proof that the agent stopped."
  (when (buffer-live-p buffer)
    (copy-tree (buffer-local-value 'pilish--runtime buffer))))

(defun pilish-session-process-identity (buffer)
  "Return BUFFER's actual Pi identity, never the socket process's pseudo PID."
  (if-let* ((runtime (pilish-session-runtime buffer)))
      (list :pid (plist-get runtime :pi-pid)
            :start-time (plist-get runtime :pi-start-time)
            :boot-id (plist-get runtime :pi-boot-id))
    (when-let* ((process (pilish-session-process buffer))
                ((process-live-p process)))
      (pilish--runtime-process-identity (process-id process)))))

(defun pilish-session-desktop-state (buffer)
  "Return BUFFER's complete serializable local desktop and runtime state.
Saved automatic input becomes suspended recovery, never a restored send queue."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (append
       (list :directory (pilish-session-directory buffer)
             :name (pilish-session-name buffer)
             :session-file (pilish-session-file buffer)
             :runtime (pilish-session-runtime buffer))
       (pilish--desktop-local-state)))))

(defun pilish-list-runtimes ()
  "List compatible and unsupported discovery identities without starting Pi.
Unsupported identities remain visible; they are never duplicate-spawn fallbacks."
  (unless (pilish-runtime-configured-p) (user-error "Configure detached runtime support first"))
  (let ((default-directory temporary-file-directory)
        (process-environment (pilish--runtime-environment nil)))
    (with-temp-buffer
      (let ((status (process-file pilish-runtime-pimux-executable nil t nil "list" "--json")))
        (unless (and (integerp status) (zerop status))
          (error "Runtime discovery failed; no replacement was started"))
        (let ((records (json-parse-string (buffer-string) :object-type 'plist)))
          (unless (vectorp records) (error "Invalid runtime discovery response"))
          (mapcar #'pilish--runtime-normalize (append records nil)))))))

(defun pilish--runtime-discovered (runtime)
  "Resolve the exact existing RUNTIME identity, or signal uncertainty/refusal."
  (let ((current (seq-find (lambda (item)
                             (equal (plist-get item :mux-id) (plist-get runtime :mux-id)))
                           (pilish-list-runtimes))))
    (unless current (error "Runtime is missing; view retained, explicit Resume is required"))
    (unless (and (equal (plist-get current :protocol) 2)
                 (equal (plist-get runtime :protocol) 2)
                 (cl-every
                  (lambda (key)
                    (or (null (plist-get runtime key))
                        (equal (plist-get runtime key) (plist-get current key))))
                  '(:socket :pid :pi-pid :pi-start-time :pi-boot-id)))
      (error "Runtime identity/protocol changed; no replacement was started"))
    current))

(defun pilish--runtime-find-view (id)
  "Return the existing local chat for mux ID, without creating a second view."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'pilish-chat-mode)
                     (equal id (plist-get pilish--runtime :mux-id)))))
            (buffer-list)))

(defun pilish--runtime-new-view (directory name)
  "Create linked non-displaying buffers in DIRECTORY with a free NAME.
This is desktop allocation only; it does not start any process."
  (let* ((directory (pilish--normalize-directory directory))
         (name name) (number 1))
    (while (or (get-buffer (pilish--buffer-name :chat directory name))
               (get-buffer (pilish--buffer-name :input directory name)))
      (setq name (format "%s-%d" (or name "view") (cl-incf number))))
    (let ((chat (pilish--get-or-create-buffer :chat directory name))
          (input (pilish--get-or-create-buffer :input directory name)))
      (with-current-buffer chat
        (pilish--set-chat-session-identity directory name)
        (pilish--set-input-buffer input)
        (add-hook 'kill-buffer-hook #'pilish--runtime-kill-view nil t))
      (with-current-buffer input
        (setq default-directory directory)
        (pilish--set-chat-buffer chat))
      chat)))

(defun pilish-attach-runtime (runtime &optional name)
  "Attach to existing RUNTIME as an equal socket client, optionally using NAME.
Return a background chat.  It accepts no input before its live boundary.
An existing view is reused.  No command starts Pi or submits a prompt."
  (unless (pilish-runtime-configured-p) (user-error "Configure detached runtime support first"))
  (let* ((current (pilish--runtime-discovered runtime))
         (existing (pilish--runtime-find-view (plist-get current :mux-id)))
         (chat (or existing
                   (pilish--runtime-new-view (or (plist-get current :directory) default-directory) name))))
    (unless (and existing (process-live-p (pilish-session-process chat)))
      (pilish--runtime-connect
       chat current (lambda (error)
                      (when error (message "Pi: %s" error)))))
    chat))

(defun pilish--runtime-service-root-p (runtime)
  "Return non-nil when RUNTIME is a root owned by the shared service."
  (let ((service (plist-get runtime :service)))
    (and (equal (plist-get runtime :protocol) 2)
         (listp service) (integerp (plist-get service :pid))
         (stringp (plist-get service :startTime))
         (stringp (plist-get service :bootId))
         (member (plist-get runtime :placement) '("root" "interactive-fork")))))

(defun pilish--runtime-reconnect-service (buffer runtime callback)
  "Resolve RUNTIME's existing service successor and connect BUFFER.
Never start an agent or replay input.  Service absence retains the view even
when the old process has a terminal receipt: it may be awaiting restoration."
  (let ((id (plist-get runtime :mux-id)))
    (with-current-buffer buffer
      (setq pilish--runtime (plist-put pilish--runtime :state "synchronizing"))
      (setq pilish--runtime-launcher
            (pilish--runtime-call
             (list "resolve" "--json" "--id" id)
             (pilish-session-directory buffer)
             (list (cons "PIMUX_DIR" (file-name-directory (plist-get runtime :socket))))
             (lambda (receipt error)
               (cond
                ((not (buffer-live-p buffer))
                 (funcall callback "View was disposed during service reconnection"))
                ((not (equal id (plist-get (pilish-session-runtime buffer) :mux-id)))
                 (funcall callback "View identity changed during service reconnection"))
                (t
                 (with-current-buffer buffer
                   (setq pilish--runtime-launcher nil)
                   (cond
                    (error
                     (pilish--runtime-stopped-view buffer error)
                     (funcall callback error))
                    ((or (null receipt) (eq receipt :null))
                     (let ((terminal (pilish--runtime-terminal-receipt runtime)))
                       (if (or terminal (plist-get runtime :exit))
                           (progn
                             (setq pilish--runtime (plist-put pilish--runtime :state "stopped"))
                             (when terminal
                               (setq pilish--runtime (plist-put pilish--runtime :terminal-receipt terminal)))
                             (let ((cleanup (pilish--runtime-retire-view buffer)))
                               (funcall callback
                                        (concat "Agent terminated while disconnected; closed view removed"
                                                (when cleanup (concat "; " cleanup))))))
                         (let ((reason "Service has no root successor or terminal evidence; view retained"))
                           (pilish--runtime-stopped-view buffer reason)
                           (funcall callback reason)))))
                    ((not (and (equal (plist-get receipt :protocol) 2)
                               (equal (plist-get receipt :state) "committed")))
                     (pilish--runtime-stopped-view buffer "Invalid service successor receipt")
                     (funcall callback "Invalid service successor receipt"))
                    (t
                     (pilish--runtime-connect-committed
                      buffer receipt (pilish-session-directory buffer)
                      (list (cons "PIMUX_DIR" (file-name-directory (plist-get runtime :socket))))
                      callback))))))))))))

(cl-defun pilish-reconnect-runtime (buffer &optional callback)
  "Reconnect BUFFER to its retained runtime only, then call CALLBACK.
CALLBACK receives nil after live, or an error string exactly once.  A missing
or unsupported runtime stays unavailable and is never started implicitly."
  (let ((callback (pilish--runtime-once callback))
        (runtime (pilish-session-runtime buffer)))
    (when (pilish--runtime-service-root-p runtime)
      (condition-case err
          (pilish--runtime-reconnect-service buffer runtime callback)
        (error (funcall callback (error-message-string err))))
      (cl-return-from pilish-reconnect-runtime nil))
    (cl-labels
        ((complete (failure)
           (if (not failure)
               (funcall callback nil)
             ;; Discovery can succeed just before the owner exits.  Reconcile
             ;; failed socket/readiness callbacks too, not only discovery errors.
             (if (equal (plist-get runtime :placement) "worker")
                 (if (not (pilish--runtime-task-same-view-p buffer runtime))
                     (funcall callback "Worker identity changed during reconnect; replacement view retained")
                   (pilish--runtime-worker-terminated buffer)
                   (if (buffer-live-p buffer)
                       (let ((reason (or (plist-get (pilish-session-runtime buffer) :task-error)
                                         "Worker task cleanup is pending; view retained")))
                         (pilish--runtime-stopped-view buffer reason)
                         (funcall callback reason))
                     (funcall callback "Worker task completed while disconnected; closed view removed")))
               (let ((receipt (and runtime (pilish--runtime-terminal-receipt runtime))))
                 (if (and receipt (buffer-live-p buffer)
                          (equal (plist-get runtime :mux-id)
                                 (plist-get (pilish-session-runtime buffer) :mux-id)))
                     (let (cleanup)
                       (with-current-buffer buffer
                         (setq pilish--runtime (plist-put pilish--runtime :state "stopped"))
                         (setq pilish--runtime (plist-put pilish--runtime :terminal-receipt receipt))
                         (setq cleanup (pilish--runtime-retire-view buffer)))
                       (funcall callback (concat "Agent terminated while disconnected; closed view removed"
                                                 (when cleanup (concat "; " cleanup)))))
                   (when (and (buffer-live-p buffer) runtime
                              (equal (plist-get runtime :mux-id)
                                     (plist-get (pilish-session-runtime buffer) :mux-id)))
                     (pilish--runtime-stopped-view buffer failure))
                   (funcall callback failure)))))))
      (condition-case err
          (progn
            (unless runtime (error "This is not a detached runtime view"))
            (unless (plist-get runtime :mux-id)
              (error "This saved view has no runtime to reconnect; use Resume stopped conversation"))
            (pilish--runtime-connect buffer (pilish--runtime-discovered runtime) #'complete))
        (error (complete (error-message-string err)))))))

(defun pilish--runtime-stopped-view (buffer reason)
  "Render BUFFER as an unavailable/stopped conversation with REASON.
An identity-free saved view is stopped, not a failed connection.  Retain any
writer identity: unavailable is not an authoritative stopped proof.  Resume
still acquires the saved file's managed claim before opening it."
  (with-current-buffer buffer
    (let ((stopped
           (or (equal (plist-get pilish--runtime :state) "stopped")
               (not (cl-some (lambda (key) (plist-get pilish--runtime key))
                             '(:mux-id :socket :pid :pi-pid
                               :owner-start-time :owner-boot-id
                               :pi-start-time :pi-boot-id))))))
      (setq pilish--runtime
            (plist-put (or pilish--runtime (list :protocol 2))
                       :state (if stopped "stopped" "unavailable")))
      (pilish--add-chat-notice
       (format "%s\nNo agent was started. %s; no input will be replayed."
               reason (cond
                       ((equal (plist-get pilish--runtime :placement) "worker")
                        "Reconcile the owning parent task; workers cannot Resume as independent agents")
                       (stopped "Use explicit Resume stopped conversation")
                       (t "Use explicit Reconnect or Resume after reconciling ownership")))
       'pilish-error-notice)
      (pilish--note-desktop-state))))

(defun pilish--runtime-terminal-receipt (runtime)
  "Read RUNTIME's exact terminal receipt without sending runtime control.
A missing, invalid or unreadable receipt is unknown, never stopped proof."
  (when (and (plist-get runtime :mux-id) (pilish-runtime-configured-p))
    (condition-case nil
        (let ((default-directory temporary-file-directory)
              (process-environment (pilish--runtime-environment nil)))
          (with-temp-buffer
            (when (eq 0 (process-file pilish-runtime-pimux-executable nil t nil
                                      "receipt" "--json" "--id" (plist-get runtime :mux-id)))
              (let ((receipt (json-parse-string (buffer-string) :object-type 'plist)))
                (when (and (listp receipt)
                           (equal (plist-get receipt :muxId) (plist-get runtime :mux-id))
                           (equal (plist-get receipt :state) "stopped"))
                  receipt)))))
      (error nil))))

(defun pilish-session-state-closed-p (state)
  "Return non-nil only when desktop STATE has authoritative terminal evidence.
An unavailable socket or absent discovery record is not terminal evidence.
The read-only receipt query never stops a runtime or launches Pi."
  (let* ((runtime (plist-get state :runtime))
         (id (plist-get runtime :mux-id)))
    (and id
         ;; An ended process does not close a service-restored root.
         ;; Only durable explicit root Close can bypass successor resolution.
         (or (not (pilish--runtime-service-root-p runtime))
             (let ((receipt (pilish--runtime-terminal-receipt runtime)))
               (and receipt (eq (plist-get receipt :rootClosed) t))))
         (if (equal (plist-get runtime :placement) "worker")
             (condition-case nil
                 (equal (plist-get (pilish--runtime-task-read runtime) :state) "complete")
               (error nil))
           (or (and (equal (plist-get runtime :state) "stopped")
                    (or (plist-get runtime :exit)
                        (let ((receipt (plist-get runtime :terminal-receipt)))
                          (and (equal (plist-get receipt :muxId) id)
                               (equal (plist-get receipt :state) "stopped")))))
               (pilish--runtime-terminal-receipt runtime))))))

(defun pilish-restore-session-state (state)
  "Restore desktop STATE as a background view, without replaying input.
Surviving runtimes and service-restored roots reconnect.  The service alone
reopens root conversations after restart; this frontend never launches them
as a restoration fallback.  Identity-free views require explicit Resume.
Workers and shell commands never restart.  Return nil for a view with
known terminal evidence."
  (if (pilish-session-state-closed-p state)
      (progn (pilish--runtime-retain-closed-state state) nil)
    (let* ((runtime (plist-get state :runtime))
           (existing (and (plist-get runtime :mux-id)
                          (pilish--runtime-find-view (plist-get runtime :mux-id))))
           (chat (or existing
                     (pilish--runtime-new-view (plist-get state :directory)
                                               (plist-get state :name)))))
      (unless existing
        (with-current-buffer chat
          (setq pilish--runtime (copy-tree runtime)
                pilish--state (list :session-file (plist-get state :session-file)
                                    :leaf-id (plist-get state :leaf-id)))
          (pilish--restore-local-desktop-state state)))
      (cond
       ((and runtime (plist-get runtime :mux-id))
        ;; Reconnect owns failure reconciliation and its recovery notice.
        (pilish-reconnect-runtime chat))
       (t (pilish--runtime-stopped-view chat "Saved conversation has no live runtime identity")))
      (and (buffer-live-p chat) chat))))

(defun pilish-resume-stopped-session (buffer &optional callback)
  "Explicitly start BUFFER's saved conversation without replaying input.
CALLBACK receives nil/error once.  Task-owned workers cannot become roots.
Claims enforce live/uncertain-owner refusal before Pi opens a saved file."
  (let ((callback (pilish--runtime-once callback)))
    (condition-case err
        (with-current-buffer buffer
          (unless (pilish-runtime-configured-p) (error "Configure managed runtime support first"))
          (when (or (process-live-p pilish--process)
                    (process-live-p pilish--runtime-launcher))
            (error "A connected or starting view must not spawn a replacement"))
          (when (equal (plist-get pilish--runtime :placement) "worker")
            (error "Resume this worker through its parent's task protocol"))
          (when-let* ((id (plist-get pilish--runtime :mux-id))
                      (current (seq-find (lambda (item) (equal id (plist-get item :mux-id)))
                                         (pilish-list-runtimes))))
            (unless (pilish--runtime-definitely-dead-p current)
              (error "The old runtime still has a live/uncertain owner; reconnect or reconcile it first")))
          (let ((file (plist-get pilish--state :session-file))
                (directory (pilish-session-directory buffer)))
            (unless (and (stringp file) (file-name-absolute-p file))
              (error "Stopped conversation requires an exact saved session path"))
            (setq pilish--launch-args (list "--session" file)
                  pilish--launch-environment (pilish--session-environment buffer directory))
            (pilish--runtime-start-view buffer directory pilish--launch-args
                                        pilish--launch-environment callback)))
      (error (funcall callback (error-message-string err))))))

(cl-defun pilish-stop-runtime (buffer &optional callback)
  "Explicitly stop BUFFER's agent everywhere using acknowledged identity control.
CALLBACK receives nil or an error string exactly once.  No raw PID is signalled.
Only confirmed root or interactive-fork placement permits Stop.
No confirmation is required.
Authoritative success retires the active view."
  (let ((callback (pilish--runtime-once callback)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'pilish--runtime-retiring buffer))
      (with-current-buffer buffer (push callback pilish--runtime-close-callbacks))
      (cl-return-from pilish-stop-runtime nil))
    (condition-case err
        (let* ((runtime (pilish-session-runtime buffer))
               (transport (pilish-session-process buffer))
               (id (plist-get runtime :mux-id)))
          (unless (and id (equal (plist-get runtime :protocol) 2))
            (error "View has no identity-bound stoppable runtime"))
          (when (equal (plist-get runtime :placement) "worker")
            (error "Cancel this worker through its parent's result protocol"))
          (unless (member (plist-get runtime :placement) '("root" "interactive-fork"))
            (error "Runtime placement is not confirmed root or interactive-fork; complete discovery before stopping"))
          (pilish--runtime-call
           (list "stop" "--json" "--id" id)
           (pilish-session-directory buffer) nil
           (lambda (receipt error)
             (if (or error (not (and (equal (plist-get receipt :muxId) id)
                                     (equal (plist-get receipt :state) "stopped"))))
                 (funcall callback (or error "Stop outcome uncertain; retain view and reconcile receipt"))
               (if (and (buffer-live-p buffer)
                        (not (equal id (plist-get (pilish-session-runtime buffer) :mux-id))))
                   (funcall callback "Original agent stopped; view now refers to another runtime")
                 (let ((failure
                        (if (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (setq pilish--runtime (plist-put pilish--runtime :state "stopped"))
                              (setq pilish--runtime (plist-put pilish--runtime :terminal-receipt receipt))
                              (pilish--runtime-retire-view buffer))
                          (and (processp transport)
                               (process-get transport 'pilish-retirement-error)))))
                   (funcall callback failure)))))))
      (error (funcall callback (error-message-string err))))))

(defun pilish--runtime-finish-close (chat error)
  "Settle CHAT's pending Close callbacks once with ERROR or nil."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (when pilish--runtime-close-timer
        (cancel-timer pilish--runtime-close-timer)
        (setq pilish--runtime-close-timer nil))
      (let ((callbacks pilish--runtime-close-callbacks)
            (state (list :runtime (copy-tree pilish--runtime))) failures)
        (setq pilish--runtime-close-callbacks nil)
        (dolist (callback callbacks)
          (condition-case failure
              (funcall callback error)
            ((error quit) (push (error-message-string failure) failures))))
        (when failures
          (setq failures (append (when error (list error)) (nreverse failures)))
          (condition-case failure
              (pilish--runtime-retain-closed-state (plist-put state :close-errors failures))
            ((error quit)
             (setq failures
                   (append failures (list (format "Diagnostic retention: %s"
                                                   (error-message-string failure)))))))
          (display-warning 'pilish (string-join failures "; ") :error))))))

(defun pilish--dispose-session-view (chat)
  "Dispose CHAT and its input without runtime control or confirmation.
Run every buffer cleanup hook once even when another fails, and report all
failures after both buffers are removed.  Frontend teardown uses this too."
  (when (buffer-live-p chat)
    (let* ((input (pilish-session-input-buffer chat))
           (transport (pilish-session-process chat))
           (windows (and (buffer-live-p input) (get-buffer-window-list input nil t)))
           (pilish-quit-without-confirmation t)
           failures)
      (cl-labels ((attempt (function)
                    (condition-case failure (funcall function)
                      ((error quit) (push (error-message-string failure) failures)))))
        ;; Prevent recursive pair killing: each buffer's hooks run exactly once.
        (with-current-buffer chat (pilish--set-input-buffer nil))
        (when (buffer-live-p input)
          (with-current-buffer input (pilish--set-chat-buffer nil)))
        (when (processp transport)
          (pilish--skip-process-kill-confirmation transport)
          (set-process-query-on-exit-flag transport nil))
        (dolist (buffer (list chat input))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (let* ((hooks kill-buffer-hook)
                     (kill-buffer-query-functions nil)
                     (kill-buffer-hook
                      (list (lambda ()
                              (let ((kill-buffer-hook hooks))
                                (run-hook-wrapped
                                 'kill-buffer-hook
                                 (lambda (function)
                                   (attempt function)
                                   nil)))))))
                (attempt (lambda () (kill-buffer buffer)))))))
        (dolist (window windows)
          (when (and (window-live-p window) (window-deletable-p window))
            (attempt (lambda () (delete-window window))))))
      (when failures (error "%s" (string-join (nreverse failures) "; "))))))

(defun pilish--runtime-retain-closed-state (state)
  "Retain STATE's unsent work and abnormal exit outside the active-agent list."
  (let* ((runtime (plist-get state :runtime))
         (exit (plist-get runtime :exit)))
    (when (or (plist-get state :close-errors)
              (cl-some (lambda (key) (plist-get state key))
                      '(:images :followups :quarantine :submitted :editor-notices))
              (not (string-empty-p (or (plist-get state :draft) "")))
              (stringp (plist-get exit :signal))
              (let ((code (plist-get exit :code)))
                (and (numberp code) (not (zerop code))))
              (not (string-empty-p (or (plist-get exit :stderrTail) ""))))
      (with-current-buffer (get-buffer-create "*Pilish closed agents*")
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format "Closed agent %s\n%s\n\n"
                          (plist-get runtime :mux-id) (pp-to-string state)))
          (special-mode))))))

(defun pilish--runtime-retire-view (chat &optional original)
  "Retire CHAT after authoritative termination, returning any error.
Observer failure cannot prevent remaining observers, disposal or callbacks.
Preserve ORIGINAL, an error that preceded retirement, and cleanup errors with
unsent work outside active views; callbacks and the result report both.
Only cleanup errors raise a warning: callers already report ORIGINAL."
  (when (and (buffer-live-p chat)
             (not (buffer-local-value 'pilish--runtime-retiring chat)))
    (with-current-buffer chat
      (let ((transport pilish--process)
            (callbacks pilish--runtime-close-callbacks)
            (ready pilish--runtime-ready-callback)
            (timer pilish--runtime-close-timer)
            (state (list :runtime (copy-tree pilish--runtime)))
            (failures (and original (list original))) result)
        (setq pilish--runtime-retiring t
              pilish--runtime-close-callbacks nil
              pilish--runtime-ready-callback nil
              pilish--runtime-close-timer nil)
        (cl-labels ((attempt (label function)
                      (condition-case failure (funcall function)
                        ((error quit)
                         (push (format "%s: %s" label (error-message-string failure)) failures)))))
          (attempt "Desktop recovery" (lambda () (setq state (pilish-session-desktop-state chat))))
          (attempt "Task polling cleanup" #'pilish--runtime-task-cancel-poll)
          (when timer (attempt "Close timer cleanup" (lambda () (cancel-timer timer))))
          (when ready
            (attempt "Readiness callback"
                     (lambda () (funcall ready "Agent terminated before readiness"))))
          (run-hook-wrapped
           'pilish-session-closed-functions
           (lambda (function &rest args)
             (attempt "Close observer" (lambda () (apply function args)))
             nil)
           chat)
          ;; An observer may request Close reentrantly, but cannot send another
          ;; control or strand its callback during the already-authoritative exit.
          (setq callbacks (append callbacks pilish--runtime-close-callbacks)
                pilish--runtime-close-callbacks nil)
          (attempt "View disposal" (lambda () (pilish--dispose-session-view chat)))
          (setq result (when failures (string-join (reverse failures) "; ")))
          (dolist (callback callbacks)
            (attempt "Close callback" (lambda () (funcall callback result))))
          (when failures (setq state (plist-put state :close-errors (reverse failures))))
          (attempt "Diagnostic retention" (lambda () (pilish--runtime-retain-closed-state state)))
          (setq result (when failures (string-join (reverse failures) "; ")))
          (when (processp transport)
            (process-put transport 'pilish-retirement-error result))
          (when (> (length failures) (if original 1 0))
            (display-warning 'pilish result :error))
          result)))))

(defun pilish--runtime-close-session (chat &optional callback)
  "Close CHAT without confirmation; CALLBACK settles after actual termination."
  (setq callback (pilish--runtime-once
                  (or callback (lambda (error) (when error (message "Pi: %s" error))))))
  (if (not (buffer-live-p chat))
      (funcall callback nil)
    (with-current-buffer chat
      (cond
       (pilish--runtime-retiring
        (push callback pilish--runtime-close-callbacks))
       ((null pilish--runtime)
        (pilish--dispose-session-view chat)
        (funcall callback nil))
       ;; An identity-free stopped view, or an unavailable one whose launch
       ;; settled without an identity, has no agent to stop.  Retire it like a
       ;; terminated one: closed observers run and unsent work is retained.
       ((and (member (plist-get pilish--runtime :state) '("stopped" "unavailable"))
             (not (plist-get pilish--runtime :mux-id))
             (not pilish--runtime-launcher))
        (funcall callback (pilish--runtime-retire-view chat)))
       (pilish--runtime-close-callbacks
        (push callback pilish--runtime-close-callbacks))
       (t
        (setq pilish--runtime-close-callbacks (list callback))
        (condition-case err
            (progn
              ;; Preserve unsent successors as explicit recovery before any
              ;; event can settle the run or release an automatic follow-up.
              ;; An already-submitted FIFO owner remains with its RPC callback.
              (pilish--suspend-close-followups)
              (if (equal (plist-get pilish--runtime :placement) "worker")
                  (pilish--runtime-close-worker chat callback)
                (pilish-stop-runtime
                 chat (lambda (error)
                        (if error (pilish--runtime-finish-close chat error)
                          (pilish--runtime-retire-view chat))))))
          (error (pilish--runtime-finish-close chat (error-message-string err)))))))))

(provide 'pilish-runtime)
;;; pilish-runtime.el ends here
