;;; pilish-runtime.el --- Public detached runtime and desktop API -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A view is not an agent.  Start is explicit; attach/reconnect/desktop restore
;; never start a missing runtime or resend input.  The identity below survives
;; transport loss and identifies the actual owned Pi, not a network pseudo PID.
;; Ordinary unshared Pi remains an explicit supported mode.

;;; Code:

(require 'pilish-runtime-process)
(require 'pilish-grammars)

(declare-function pilish--session-environment "pilish" (chat-buf dir))
(declare-function pilish-session-file "pilish" (chat-buffer))
(declare-function pilish-session-name "pilish" (chat-buffer))
(declare-function pilish-session-directory "pilish" (chat-buffer))
(declare-function pilish-session-process "pilish" (chat-buffer))
(declare-function pilish-session-input-buffer "pilish" (chat-buffer))

(defun pilish-integration-capabilities ()
  "Return this fork's versioned, implemented integration capabilities."
  '(:api-version 1 :pimux-protocol 2 :symmetric-socket-client t
    :runtime-identity t :desktop-state t :stopped-view t
    :context-bound-input t :essential-grammar-installer 1 :managed-storage t))

(cl-defun pilish-configure-runtime
    (&key pi-executable pimux-executable (protocol 2) (mode 'detached)
          (pi-version "1.4.0") pi-sha256)
  "Configure immutable PI-EXECUTABLE and PIMUX-EXECUTABLE without starting Pi.
PROTOCOL must be 2.  MODE is `detached' or explicit `unshared'.  PI-VERSION
and optional PI-SHA256 are validated by the owning compiled launcher."
  (unless (memq mode '(detached unshared)) (error "Unsupported Pilish runtime mode"))
  (unless (equal protocol 2) (error "Pilish requires pimux protocol 2; no lifetime shim is supported"))
  (when (eq mode 'detached)
    (unless (and (eq system-type 'gnu/linux) (version<= "31.1" emacs-version))
      (error "Detached Pilish requires Linux and Emacs 31.1 or newer"))
    (dolist (file (list pi-executable pimux-executable))
      (unless (and (stringp file) (file-name-absolute-p file)
                   (not (file-remote-p file)) (file-executable-p file))
        (error "Configure absolute executable paths from one complete release: %S" file)))
    (unless (and (stringp pi-version) (not (string-empty-p pi-version)))
      (error "An exact release Pi version is required"))
    (when (and pi-sha256 (not (string-match-p "\\`[a-f0-9]\\{64\\}\\'" pi-sha256)))
      (error "Invalid release Pi entry-point SHA-256")))
  (setq pilish-runtime-mode mode
        pilish-runtime-pi-executable pi-executable
        pilish-runtime-pimux-executable pimux-executable
        pilish-runtime-pi-version pi-version
        pilish-runtime-pi-sha256 pi-sha256)
  (pilish-integration-capabilities))

(defun pilish--runtime-definitely-dead-p (runtime)
  "Return non-nil only when RUNTIME's wrapper and actual Pi are known dead."
  (cl-every
   (lambda (keys)
     (let* ((pid (plist-get runtime (nth 0 keys)))
            (start (plist-get runtime (nth 1 keys)))
            (boot (plist-get runtime (nth 2 keys)))
            (current (pilish--runtime-process-identity pid)))
       (and (integerp pid)
            (or (not (file-exists-p (format "/proc/%d" pid)))
                (and current start boot
                     (not (and (equal start (plist-get current :start-time))
                               (equal boot (plist-get current :boot-id)))))))))
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

(defun pilish-reconnect-runtime (buffer &optional callback)
  "Reconnect BUFFER to its retained runtime only, then call CALLBACK.
CALLBACK receives nil after live, or an error string exactly once.  A missing
or unsupported runtime stays unavailable and is never started implicitly."
  (let ((callback (pilish--runtime-once callback)))
    (condition-case err
        (let ((runtime (pilish-session-runtime buffer)))
          (unless runtime (error "This is not a detached runtime view"))
          (unless (plist-get runtime :mux-id)
            (error "This saved view has no runtime to reconnect; use Resume stopped conversation"))
          (pilish--runtime-connect buffer (pilish--runtime-discovered runtime) callback))
      (error
       (when (and (buffer-live-p buffer) (pilish-session-runtime buffer))
         (pilish--runtime-stopped-view buffer (error-message-string err)))
       (funcall callback (error-message-string err))))))

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
               reason (if stopped "Use explicit Resume stopped conversation"
                        "Use explicit Reconnect or Resume after reconciling ownership"))
       'pilish-error-notice)
      (pilish--note-desktop-state))))

(defun pilish-restore-session-state (state)
  "Restore desktop STATE as an attach-only background view.
Identity-free conversations are stopped/resumable; missing retained runtimes
remain unavailable.  No saved shell, prompt,
queue, worker or Pi process is restarted by desktop restoration."
  (let* ((runtime (plist-get state :runtime))
         (existing (and (plist-get runtime :mux-id)
                        (pilish--runtime-find-view (plist-get runtime :mux-id))))
         (chat (or existing
                   (pilish--runtime-new-view (plist-get state :directory) (plist-get state :name)))))
    (unless existing
      (with-current-buffer chat
        (setq pilish--runtime (copy-tree runtime)
              pilish--state (list :session-file (plist-get state :session-file)
                                  :leaf-id (plist-get state :leaf-id)))
        (pilish--restore-local-desktop-state state)))
    (if (and runtime (plist-get runtime :mux-id))
        (pilish-reconnect-runtime
         chat (lambda (error)
                (when error (pilish--runtime-stopped-view chat error))))
      (pilish--runtime-stopped-view chat "Saved conversation has no live runtime identity"))
    chat))

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

(defun pilish-stop-runtime (buffer &optional callback)
  "Explicitly stop BUFFER's agent everywhere using acknowledged identity control.
CALLBACK receives nil or an error string exactly once.  No raw PID is signalled.
Callers own the every-frontend confirmation, including idle agents."
  (let ((callback (pilish--runtime-once callback)))
    (condition-case err
        (let* ((runtime (pilish-session-runtime buffer))
               (id (plist-get runtime :mux-id)))
          (unless (and id (equal (plist-get runtime :protocol) 2))
            (error "View has no identity-bound stoppable runtime"))
          (when (equal (plist-get runtime :placement) "worker")
            (error "Cancel this worker through its parent's result protocol"))
          (pilish--runtime-call
           (list "stop" "--json" "--id" id)
           (pilish-session-directory buffer) nil
           (lambda (receipt error)
             (if (or error (not (and (equal (plist-get receipt :muxId) id)
                                     (equal (plist-get receipt :state) "stopped"))))
                 (funcall callback (or error "Stop outcome uncertain; retain view and reconcile receipt"))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq pilish--runtime (plist-put pilish--runtime :state "stopped"))
                   (setq pilish--runtime (plist-put pilish--runtime :terminal-receipt receipt))
                   (when (process-live-p pilish--process) (delete-process pilish--process))
                   (pilish--note-desktop-state)))
               (funcall callback nil)))))
      (error (funcall callback (error-message-string err))))))

(provide 'pilish-runtime)
;;; pilish-runtime.el ends here
