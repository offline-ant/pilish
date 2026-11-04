;;; pilish-runtime-native-test.el --- Real Pi faux socket integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Explicit opt-in with a marked synthetic ownership root and exact candidate
;; executables.  No production discovery, personal caches or paid inference.

;;; Code:
(require 'ert)
(require 'pilish)
(require 'pilish-runtime-test)
(require 'server)

(defvar ghostel-module-directory)
(defvar pi-orchestration--targets)
(defvar pi-orchestration-target-functions)
(defvar pilish-runtime-native-test--emacs-endpoint nil
  "Disposable server endpoint for real companion parent operations, or nil.")

(defconst pilish-runtime-native-test--source
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defun pilish-runtime-native-test--wait (predicate)
  "Wait up to forty seconds for PREDICATE using process events."
  (let ((deadline (+ (float-time) 40)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defun pilish-runtime-native-test--peer (runtime command &optional run)
  "Ask an independent Node frontend to send COMMAND to RUNTIME, optionally RUN."
  (with-temp-buffer
    (let ((status (process-file
                   "node" nil t nil
                   (expand-file-name "test/support/pimux-peer.mjs" pilish-runtime-native-test--source)
                   (plist-get runtime :socket) (json-encode command) (if run "run" ""))))
      (unless (and (integerp status) (zerop status))
        (error "Independent peer failed: %s" (buffer-string)))
      (json-parse-string (buffer-string) :object-type 'plist))))

(defmacro pilish-runtime-native-test--with-host (&rest body)
  "Run BODY with explicitly selected candidate/faux host and synthetic namespace."
  (declare (indent 0))
  `(progn
     (skip-unless (getenv "PHIMACS_NATIVE_PILISH"))
     (should (string-prefix-p "/tmp/phimacs-test-" (or (getenv "PHIMACS_TEST_ROOT") "")))
     (let* ((root (getenv "PHIMACS_TEST_ROOT"))
            (default-directory (file-name-as-directory (expand-file-name "sessions" root)))
            (process-environment (copy-sequence process-environment))
            (pilish-runtime-mode 'detached)
            (pilish-executable (list (getenv "PHIMACS_PI_EXECUTABLE")))
            (pilish-runtime-pi-executable (getenv "PHIMACS_PI_EXECUTABLE"))
            (pilish-runtime-pimux-executable (getenv "PHIMACS_PIMUX_EXECUTABLE"))
            (pilish-runtime-task-status-executable (getenv "PHIMACS_TASK_STATUS_EXECUTABLE"))
            (pilish-extra-args
             (list "--no-extensions" "--no-skills" "--no-prompt-templates"
                   "--no-context-files" "--extension" (getenv "PHIMACS_FAUX_EXTENSION")
                   "--provider" "pimux-fx" "--model" "one" "--thinking" "off"))
            chat runtime)
       (setq process-environment
             (seq-remove (lambda (entry)
                           (string-match-p "\\`\\(?:PI_ORCHESTRATION_\\|PI_WORKER_\\|PHIMACS_PARENT_\\|PHIMACS_MANAGED_CLAIM=\\|PI_REMOTE=\\)" entry))
                         process-environment))
       (setenv "PI_CODING_AGENT_DIR" (expand-file-name "agent" root))
       (setenv "PI_CODING_AGENT_SESSION_DIR" default-directory)
       (setenv "PIMUX_DIR" (expand-file-name "mux" root))
       (pilish-configure-runtime :pi-executable pilish-runtime-pi-executable
                                 :pimux-executable pilish-runtime-pimux-executable
                                 :task-status-executable pilish-runtime-task-status-executable)
       (unwind-protect (progn ,@body)
         (setq runtime (or runtime (and (buffer-live-p chat) (pilish-session-runtime chat))))
         (when (and (plist-get runtime :mux-id)
                    (not (equal (plist-get runtime :state) "stopped")))
           (ignore-errors
             (process-file pilish-runtime-pimux-executable nil nil nil
                           "stop" "--json" "--id" (plist-get runtime :mux-id))))
         (when (buffer-live-p chat)
           (let ((input (pilish-session-input-buffer chat))
                 (pilish-quit-without-confirmation t))
             (kill-buffer chat)
             (when (buffer-live-p input) (kill-buffer input))))))))

(ert-deftest pilish-runtime-native-test-creates-detaches-restores-and-stops ()
  (pilish-runtime-native-test--with-host
    (let (ready response)
      (setq chat (pilish-start-session default-directory "native-owner"
                                       :on-ready (lambda (result) (setq ready result))))
      (pilish-runtime-native-test--wait (lambda () ready))
      (unless (eq (plist-get ready :success) t)
        (ert-fail (format "Managed view did not start: %S" ready)))
      (setq runtime (pilish-session-runtime chat))
      (should (equal (plist-get runtime :state) "live"))
      (should (eq (process-type (pilish-session-process chat)) 'network))
      (should-not (integerp (process-id (pilish-session-process chat))))
      (should (pilish--runtime-process-identity (plist-get runtime :pi-pid)))
      (pilish-submit-prompt chat "native once" (lambda (result) (setq response result)))
      (pilish-runtime-native-test--wait
       (lambda () (and response (not (pilish-session-busy-p chat)))))
      (should (eq (plist-get response :success) t))
      (with-current-buffer (pilish-session-input-buffer chat) (insert "context-specific draft"))
      (let* ((state (pilish-session-desktop-state chat))
             (identity (pilish-session-process-identity chat)))
        (pilish-disconnect-session chat)
        (should (equal identity (pilish--runtime-process-identity (plist-get runtime :pi-pid))))
        (setq chat (pilish-restore-session-state state))
        (pilish-runtime-native-test--wait
         (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
        (should (equal identity (pilish-session-process-identity chat)))
        (should (equal (plist-get (pilish-session-desktop-state chat) :draft) "context-specific draft")))
      ;; A different frontend changes session and prompts, while this view adopts
      ;; the authoritative boundary and quarantines old-context input.
      (let ((old-file (pilish-session-file chat)))
        (should (eq (plist-get (plist-get
                               (pilish-runtime-native-test--peer runtime '(:type "new_session"))
                               :response) :success) t))
        (pilish-runtime-native-test--wait (lambda () (not (equal old-file (pilish-session-file chat)))))
        (should (pilish-session-quarantine chat)))
      (should (eq (plist-get (plist-get
                             (pilish-runtime-native-test--peer
                              runtime '(:type "prompt" :message "other frontend once") t)
                             :response) :success) t))
      (pilish-runtime-native-test--wait (lambda () (not (pilish-session-busy-p chat))))
      (let ((messages (plist-get (plist-get
                                 (pilish-runtime-native-test--peer runtime '(:type "get_messages"))
                                 :response) :data)))
        (should (= (length (seq-filter (lambda (message) (equal (plist-get message :role) "user"))
                                       (append (plist-get messages :messages) nil))) 1)))
      (let ((state (pilish-session-desktop-state chat)) stopped)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (ert-fail "Close asked"))))
          (pilish-close-session chat (lambda (error) (setq stopped (or error 'success))))
          (pilish-runtime-native-test--wait (lambda () stopped)))
        (should (eq stopped 'success))
        (should-not (buffer-live-p chat))
        (should-not (pilish--runtime-process-identity (plist-get runtime :pi-pid)))
        (should-not (pilish-restore-session-state state))
        (setq runtime (plist-put runtime :state "stopped"))))))

(ert-deftest pilish-runtime-native-test-independent-creator-and-zero-clients ()
  (pilish-runtime-native-test--with-host
    (with-temp-buffer
      (let ((status (apply #'process-file pilish-runtime-pimux-executable nil t nil
                           (append (list "start" "--json" "--" pilish-runtime-pi-executable
                                         "--mode" "rpc") pilish-extra-args))))
        (unless (and (integerp status) (zerop status))
          (error "Independent launch failed: %s" (buffer-string)))
        (setq runtime (pilish--runtime-normalize
                       (json-parse-string (buffer-string) :object-type 'plist)))))
    ;; The creating frontend has already exited.  Attachment makes no new Pi.
    (should (pilish--runtime-process-identity (plist-get runtime :pi-pid)))
    (setq chat (pilish-attach-runtime runtime "external-created"))
    (pilish-runtime-native-test--wait
     (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
    (let ((identity (pilish-session-process-identity chat)))
      (pilish--terminate-process (pilish-session-process chat))
      (should (equal identity (pilish--runtime-process-identity (plist-get runtime :pi-pid))))
      (let (ready)
        (pilish-reconnect-runtime chat (lambda (error) (setq ready (or error 'success))))
        (pilish-runtime-native-test--wait (lambda () ready))
        (should (eq ready 'success)))
      (should (equal identity (pilish-session-process-identity chat))))))

(ert-deftest pilish-runtime-native-test-public-open-selects-existing-file-before-start ()
  "The asynchronous public entry point opens exactly the user's saved file."
  (pilish-runtime-native-test--with-host
    (let ((file (expand-file-name "public-selected.jsonl" default-directory))
          (timestamp (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
          response)
      (with-temp-file file
        (insert (json-encode
                 (list :type "session" :version 3 :id "selected-native"
                       :timestamp timestamp :cwd default-directory)) "\n"
                (json-encode
                 (list :type "message" :id "selected-entry" :parentId nil
                       :timestamp timestamp
                       :message '(:role "user" :content "persisted selected conversation" :timestamp 1)))
                "\n"))
      (set-file-modes file #o600)
      ;; No synthetic callback or process is installed: this exercises the real
      ;; compiled launcher, asynchronous socket setup and public function.
      (setq chat (pilish-open-session-file file))
      (should (buffer-live-p chat))
      (pilish-runtime-native-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
      (setq runtime (pilish-session-runtime chat))
      (should (equal (pilish-session-file chat) file))
      (should (equal (plist-get runtime :session-file) file))
      (let* ((reply (pilish-runtime-native-test--peer runtime '(:type "get_messages")))
             (messages (plist-get (plist-get (plist-get reply :response) :data) :messages)))
        (should (= (length messages) 1))
        (should (string-match-p "persisted selected conversation" (prin1-to-string messages))))
      (pilish-submit-prompt chat "selected file once" (lambda (result) (setq response result)))
      (pilish-runtime-native-test--wait
       (lambda () (and response (not (pilish-session-busy-p chat)))))
      (should (eq (plist-get response :success) t))
      (should (equal (pilish-session-file chat) file))
      (let* ((reply (pilish-runtime-native-test--peer runtime '(:type "get_messages")))
             (messages (plist-get (plist-get (plist-get reply :response) :data) :messages)))
        (should (= (seq-count (lambda (message) (equal (plist-get message :role) "user"))
                              (append messages nil)) 2))))))

(ert-deftest pilish-runtime-native-test-resumes-identity-free-migrated-file-without-prompt ()
  "Migration restores stopped views; explicit Resume opens only their history."
  (pilish-runtime-native-test--with-host
    (let ((file (expand-file-name "migrated-stopped.jsonl" default-directory))
          (timestamp (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
          ready)
      (with-temp-file file
        (insert (json-encode
                 (list :type "session" :version 3 :id "migrated-native"
                       :timestamp timestamp :cwd default-directory)) "\n"
                (json-encode
                 (list :type "message" :id "migrated-entry" :parentId nil
                       :timestamp timestamp
                       :message '(:role "user" :content "persisted migration history" :timestamp 1)))
                "\n"))
      (set-file-modes file #o600)
      (setq chat (pilish-restore-session-state
                  (list :directory default-directory :name "migrated-stopped"
                        :session-file file :runtime nil :draft "not a prompt")))
      (should (equal (plist-get (pilish-session-runtime chat) :state) "stopped"))
      (should-not (pilish-session-process chat))
      (pilish-resume-stopped-session chat (lambda (error) (setq ready (or error 'success))))
      (pilish-runtime-native-test--wait (lambda () ready))
      (should (eq ready 'success))
      (setq runtime (pilish-session-runtime chat))
      (should (equal (plist-get runtime :state) "live"))
      (should (equal (pilish-session-file chat) file))
      (should (equal (plist-get runtime :session-file) file))
      (should-not (pilish-session-busy-p chat))
      (let* ((reply (pilish-runtime-native-test--peer runtime '(:type "get_messages")))
             (messages (plist-get (plist-get (plist-get reply :response) :data) :messages)))
        (should (= (length messages) 1))
        (should (string-match-p "persisted migration history" (prin1-to-string messages)))
        (should-not (string-match-p "not a prompt" (prin1-to-string messages))))
      (let ((desktop (pilish-session-desktop-state chat)))
        (should (or (equal (plist-get desktop :draft) "not a prompt")
                    (seq-find (lambda (record) (equal (plist-get record :draft) "not a prompt"))
                              (plist-get desktop :quarantine))))))))

(ert-deftest pilish-runtime-native-test-previous-boot-restores-idle-history-without-replay ()
  "A proven reboot reopens saved roots; existing ownership still wins atomically."
  (pilish-runtime-native-test--with-host
    (let* ((file (expand-file-name "before-reboot.jsonl" default-directory))
           (timestamp (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
           (identity (pilish--runtime-process-identity (emacs-pid)))
           (previous
            (pilish-runtime-test--previous-boot
             (list :protocol 2 :placement "root" :state "live" :socket (expand-file-name "old.sock" root)
                   :pid (emacs-pid) :owner-start-time (plist-get identity :start-time)
                   :pi-pid (emacs-pid) :pi-start-time (plist-get identity :start-time))))
           (saved (list :directory default-directory :name "after-reboot" :runtime previous
                        :session-file file :draft "reboot draft not submitted"
                        :followups '("reboot follow-up not submitted"))))
      (should-not (equal (plist-get previous :pi-boot-id) (plist-get identity :boot-id)))
      (with-temp-file file
        (insert (json-encode
                 (list :type "session" :version 3 :id "before-reboot"
                       :timestamp timestamp :cwd default-directory)) "\n"
                (json-encode
                 (list :type "message" :id "saved-before-reboot" :parentId nil
                       :timestamp timestamp
                       :message '(:role "user" :content "persisted reboot history" :timestamp 1))) "\n"))
      (set-file-modes file #o600)
      (setq chat (pilish-restore-session-state saved))
      (pilish-runtime-native-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
      (setq runtime (pilish-session-runtime chat))
      (should (equal (pilish-session-file chat) file))
      (should-not (pilish-session-busy-p chat))
      (should-not (pilish-session-queued-prompts chat))
      (with-current-buffer chat (should (string-match-p "persisted reboot history" (buffer-string))))
      (let ((desktop (prin1-to-string (pilish-session-desktop-state chat)))
            (current (pilish-session-process-identity chat)))
        (should (string-match-p "reboot draft not submitted" desktop))
        (should (string-match-p "reboot follow-up not submitted" desktop))
        (should (equal (plist-get current :boot-id) (plist-get identity :boot-id)))
        (let ((state (pilish-session-desktop-state chat)))
          (pilish-disconnect-session chat)
          (setq chat (pilish-restore-session-state state)))
        (pilish-runtime-native-test--wait
         (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
        (should (equal current (pilish-session-process-identity chat)))
        ;; A second frontend may already have reopened the file after boot.
        ;; Restoring the old record must attach that writer, not start another.
        (pilish-disconnect-session chat)
        (setq chat (pilish-restore-session-state saved))
        (pilish-runtime-native-test--wait
         (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
        (should (equal current (pilish-session-process-identity chat)))
        (should (= (length (pilish-list-runtimes)) 1)))
      (let* ((reply (pilish-runtime-native-test--peer runtime '(:type "get_messages")))
             (messages (plist-get (plist-get (plist-get reply :response) :data) :messages)))
        (should (= (length messages) 1))
        (should (equal (plist-get (aref messages 0) :role) "user"))
        (should (string-match-p "persisted reboot history" (prin1-to-string messages)))))))

(ert-deftest pilish-runtime-native-test-failed-render-live-stays-gated-until-reconnect ()
  "A real full boundary and live marker cannot repair a failed renderer."
  (pilish-runtime-native-test--with-host
    (let (ready)
      (setq chat (pilish-start-session default-directory "native-render-failure"
                                       :on-ready (lambda (result) (setq ready result))))
      (pilish-runtime-native-test--wait (lambda () ready))
      (should (eq (plist-get ready :success) t))
      (setq runtime (pilish-session-runtime chat))
      (let ((identity (pilish-session-process-identity chat))
            (context (pilish-session-input-context chat))
            (proc (pilish-session-process chat))
            (finish-snapshot (symbol-function 'pilish--shared-finish-snapshot))
            live-seen acknowledged)
        (with-current-buffer (pilish-session-input-buffer chat)
          (insert "retain after native render failure"))
        (cl-letf (((symbol-function 'pilish--display-session-history)
                   (lambda (&rest _) (error "Native snapshot renderer failure")))
                  ((symbol-function 'pilish--shared-finish-snapshot)
                   (lambda (process record)
                     (funcall finish-snapshot process record)
                     (setq live-seen (plist-get record :generation)))))
          (pilish--rpc-async proc '(:type "pimux_bootstrap" :include ["entries" "messages"])
                             (lambda (response) (setq acknowledged response)))
          (pilish-runtime-native-test--wait (lambda () (and live-seen acknowledged)))
          (should (eq (plist-get acknowledged :success) t))
          (should (string-match-p "Native snapshot renderer failure"
                                  (process-get proc 'pilish-mux-application-error)))
          (should-not (pilish--shared-input-ready-p proc))
          (should-not (pilish-session-input-context chat))
          (should-error (pilish-submit-prompt chat "must never be submitted" #'ignore)
                        :type 'user-error))
        (should (equal identity (pilish-session-process-identity chat)))
        (should (equal identity (pilish--runtime-process-identity (plist-get runtime :pi-pid))))
        (should (seq-find
                 (lambda (record)
                   (equal (plist-get record :draft) "retain after native render failure"))
                 (pilish-session-quarantine chat)))
        (let (reconnected)
          (pilish-reconnect-runtime chat (lambda (error) (setq reconnected (or error 'success))))
          (pilish-runtime-native-test--wait (lambda () reconnected))
          (should (eq reconnected 'success)))
        (should (pilish-session-input-context chat))
        (should (equal context (pilish-session-input-context chat)))
        (should (equal identity (pilish-session-process-identity chat)))
        (let* ((reply (pilish-runtime-native-test--peer runtime '(:type "get_messages")))
               (messages (plist-get (plist-get (plist-get reply :response) :data) :messages)))
          ;; Neither failed input nor explicit synchronization authorizes work.
          (should (= (length messages) 0)))))))

(ert-deftest pilish-runtime-native-test-remote-close-removes-active-view ()
  "Another frontend's authoritative stop retires Pilish without a second stop."
  (pilish-runtime-native-test--with-host
    (let (ready)
      (setq chat (pilish-start-session default-directory "native-remote-close"
                                       :on-ready (lambda (result) (setq ready result))))
      (pilish-runtime-native-test--wait (lambda () ready))
      (should (eq (plist-get ready :success) t))
      (setq runtime (pilish-session-runtime chat))
      (let ((input (pilish-session-input-buffer chat))
            (state (pilish-session-desktop-state chat)))
        (should (eq 0 (process-file pilish-runtime-pimux-executable nil nil nil
                                    "stop" "--json" "--id" (plist-get runtime :mux-id))))
        (cl-letf (((symbol-function 'pilish-stop-runtime)
                   (lambda (&rest _) (ert-fail "Remote exit triggered another stop"))))
          (pilish-runtime-native-test--wait (lambda () (not (buffer-live-p chat)))))
        (should-not (buffer-live-p input))
        (should-not (pilish-restore-session-state state))
        (setq runtime (plist-put runtime :state "stopped"))))))

(ert-deftest pilish-runtime-native-test-reconnect-retires-agent-closed-while-disconnected ()
  "A missing discovery entry needs read-only terminal proof, not another stop."
  (pilish-runtime-native-test--with-host
    (let (ready)
      (setq chat (pilish-start-session default-directory "native-offline-close"
                                       :on-ready (lambda (result) (setq ready result))))
      (pilish-runtime-native-test--wait (lambda () ready))
      (should (eq (plist-get ready :success) t))
      (setq runtime (pilish-session-runtime chat))
      (let ((input (pilish-session-input-buffer chat)) outcome)
        (pilish--terminate-process (pilish-session-process chat))
        (should (buffer-live-p chat))
        (should (eq 0 (process-file pilish-runtime-pimux-executable nil nil nil
                                    "stop" "--json" "--id" (plist-get runtime :mux-id))))
        (cl-letf (((symbol-function 'pilish-stop-runtime)
                   (lambda (&rest _) (ert-fail "Reconnect sent a destructive status query"))))
          (pilish-reconnect-runtime chat (lambda (error) (setq outcome error))))
        (should (string-match-p "closed view removed" outcome))
        (should-not (buffer-live-p chat))
        (should-not (buffer-live-p input))
        (setq runtime (plist-put runtime :state "stopped"))))))

(defun pilish-runtime-native-test--parent-event (parent event)
  "Wait for PARENT's EVENT marker, preserving its complete diagnostic output."
  (let (result)
    (condition-case failure
        (pilish-runtime-native-test--wait
         (lambda ()
           ;; Process exit can be observed before its final pipe bytes reach the
           ;; filter (especially during synchronous task-status CLI queries).
           (unless (process-live-p parent)
             (while (accept-process-output parent 0.05)))
           (setq result
                 (seq-find (lambda (record) (equal (plist-get record :event) event))
                           (process-get parent 'pilish-native-events)))
           (when-let* ((fatal (seq-find (lambda (record) (equal (plist-get record :event) "fatal"))
                                       (process-get parent 'pilish-native-events))))
             (ert-fail (format "Managed parent failed: %S" fatal)))
           (unless (or result (process-live-p parent))
             (ert-fail (format "Managed parent exited before %s" event)))
           result))
      (error
       (ert-fail (format "%s awaiting %s\nstdout: %s\nstderr: %s"
                         (error-message-string failure) event
                         (with-current-buffer (process-buffer parent) (buffer-string))
                         (with-current-buffer (process-get parent 'pilish-native-stderr) (buffer-string))))))
    result))

(defmacro pilish-runtime-native-test--with-managed-parent (outcome &rest body)
  "Run BODY with a real Workers parent whose native cleanup pauses until released.
OUTCOME selects complete or failed native cleanup; no user daemon is contacted."
  (declare (indent 1))
  `(pilish-runtime-native-test--with-host
     (let* ((parent-directory (make-temp-file (expand-file-name "managed-" root) t))
            (parent-output (generate-new-buffer " *pilish-managed-parent*"))
            (parent-error (generate-new-buffer " *pilish-managed-parent-errors*"))
            (parent
             (make-process
              :name "pilish-managed-parent" :buffer parent-output :stderr parent-error
              :noquery t :connection-type 'pipe :coding 'utf-8-unix
              :command (list "node" (expand-file-name "test/support/managed-parent.mjs"
                                                       pilish-runtime-native-test--source)
                             parent-directory ,outcome
                             (or pilish-runtime-native-test--emacs-endpoint ""))
              :filter
              (lambda (process chunk)
                (when (buffer-live-p (process-buffer process))
                  (with-current-buffer (process-buffer process) (goto-char (point-max)) (insert chunk)))
                (let ((framed (pilish--accumulate-line-chunks
                               (process-get process 'pilish-native-partial) chunk)))
                  (process-put process 'pilish-native-partial (cdr framed))
                  (dolist (line (car framed))
                    (process-put process 'pilish-native-events
                                 (cons (json-parse-string line :object-type 'plist)
                                       (process-get process 'pilish-native-events)))))))))
       (process-put parent 'pilish-native-stderr parent-error)
       (unwind-protect
           (let* ((ready (pilish-runtime-native-test--parent-event parent "ready"))
                  (task (plist-get ready :task))
                  (worker-socket (plist-get (plist-get ready :runtime) :socket)))
             (should (equal (plist-get task :state) "pending"))
             (setenv "PIMUX_DIR" (directory-file-name (file-name-directory worker-socket)))
             (setq runtime
                   (seq-find (lambda (item) (equal (plist-get item :mux-id) (plist-get task :muxId)))
                             (pilish-list-runtimes)))
             (should (equal (plist-get runtime :placement) "worker"))
             (setq chat (pilish-attach-runtime runtime "managed-native"))
             (pilish-runtime-native-test--wait
              (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
             ;; Discovery was captured above. Task reads must now use the socket's
             ;; namespace, not this unrelated frontend default.
             (let ((unrelated (expand-file-name "unrelated-mux" parent-directory)))
               (make-directory unrelated) (set-file-modes unrelated #o700)
               (setenv "PIMUX_DIR" unrelated))
             ,@body)
         (when (process-live-p parent)
           (process-send-string parent "stop\n")
           (pilish-runtime-native-test--wait (lambda () (not (process-live-p parent)))))
         (unless (eq (process-exit-status parent) 0)
           (ert-fail (format "Managed parent exit %s\n%s\n%s"
                             (process-exit-status parent)
                             (with-current-buffer parent-output (buffer-string))
                             (with-current-buffer parent-error (buffer-string)))))
         (kill-buffer parent-output)
         (kill-buffer parent-error)))))

(defun pilish-runtime-native-test--task-file (runtime)
  "Return retained task evidence for RUNTIME in its captured namespace."
  (expand-file-name (concat "task-receipts/" (plist-get runtime :mux-id) ".json")
                    (file-name-directory (plist-get runtime :socket))))

(defun pilish-runtime-native-test--replace-task-evidence (runtime bytes)
  "Atomically replace RUNTIME's synthetic task evidence with private BYTES.
This adversarial fixture never uses the owning writer to fabricate success."
  (let* ((file (pilish-runtime-native-test--task-file runtime))
         (directory (file-name-directory file)))
    (should (file-in-directory-p file (getenv "PHIMACS_TEST_ROOT")))
    (let ((temporary (make-temp-file (expand-file-name ".native-evidence-" directory))))
      (unwind-protect
          (progn
            (with-temp-file temporary (insert bytes))
            (set-file-modes temporary #o600)
            (rename-file temporary file t)
            (should (= (file-modes file) #o600)))
        (when (file-exists-p temporary) (delete-file temporary))))))

(defun pilish-runtime-native-test--trace (parent-directory)
  "Read PARENT-DIRECTORY's actual faux provider trace."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lifecycle-trace.jsonl" parent-directory))
    (mapcar (lambda (line) (json-parse-string line :object-type 'plist))
            (split-string (buffer-string) "\n" t))))

(ert-deftest pilish-runtime-native-test-managed-close-awaits-parent-cleanup-after-mux-exit ()
  "Runtime exit and an ended lease do not acknowledge a worker's owning task."
  (pilish-runtime-native-test--with-managed-parent "complete"
    (let ((input (pilish-session-input-buffer chat)) outcomes)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (ert-fail "Worker Close asked")))
                ((symbol-function 'pilish-stop-runtime) (lambda (&rest _) (ert-fail "Worker Close used root Stop"))))
        (pilish-close-session chat (lambda (error) (push (or error 'success) outcomes)))
        (pilish-runtime-native-test--wait
         (lambda () (or outcomes
                        (seq-find (lambda (record) (equal (plist-get record :event) "cleanup-blocked"))
                                  (process-get parent 'pilish-native-events)))))
        (when outcomes
          (ert-fail (format "Worker Close settled before native cleanup: %S\nruntime: %S\ntask: %S"
                            outcomes (pilish-session-runtime chat) task)))
        (let ((blocked (pilish-runtime-native-test--parent-event parent "cleanup-blocked")))
          (should (equal (plist-get blocked :workerState) "dead"))
          (should (equal (plist-get blocked :leaseState) "ended"))
          (should (equal (plist-get (plist-get blocked :task) :state) "pending"))
          (should (eq (plist-get blocked :nameClaimHeld) t))
          (should (eq (plist-get blocked :registered) t)))
        ;; The real socket has emitted pimux_exit and then closed. Give Emacs a
        ;; process event barrier, not a sleep or a synthetic callback.
        (pilish-runtime-native-test--wait
         (lambda () (not (process-live-p (pilish-session-process chat)))))
        (should (buffer-live-p chat))
        (should (buffer-live-p input))
        (should-not outcomes)
        (process-send-string parent "release-cleanup\n")
        (let ((finished (pilish-runtime-native-test--parent-event parent "task-finished")))
          (should (equal (plist-get (plist-get finished :task) :state) "complete"))
          (should (eq (plist-get finished :nameClaimHeld) :false))
          (should (eq (plist-get finished :registered) :false))
          (should (eq (plist-get finished :sessionClaimHeld) :false)))
        (pilish-runtime-native-test--wait (lambda () outcomes))
        (should (equal outcomes '(success)))
        (should-not (buffer-live-p chat))
        (should-not (buffer-live-p input)))
      (let ((requests (seq-filter (lambda (event) (equal (plist-get event :event) "request"))
                                   (pilish-runtime-native-test--trace parent-directory))))
        (should (= (length requests) 1))
        (should (eq (plist-get (car requests) :retrospective) :false))))))

(ert-deftest pilish-runtime-native-test-managed-close-retains-failed-parent-cleanup ()
  "A real final failed record reports its owning cleanup error, retaining recovery."
  (pilish-runtime-native-test--with-managed-parent "failed"
    (let (outcomes)
      (with-current-buffer (pilish-session-input-buffer chat) (insert "retain failed task draft"))
      (pilish-close-session chat (lambda (error) (push (or error 'success) outcomes)))
      (pilish-runtime-native-test--parent-event parent "cleanup-blocked")
      (should (buffer-live-p chat))
      (should-not outcomes)
      (process-send-string parent "release-cleanup\n")
      (let ((finished (pilish-runtime-native-test--parent-event parent "task-finished")))
        (should (equal (plist-get (plist-get finished :task) :state) "failed"))
        (should (eq (plist-get finished :nameClaimHeld) :false)))
      (pilish-runtime-native-test--wait (lambda () outcomes))
      (should (= (length outcomes) 1))
      (should (string-match-p "native fixture host cleanup failed" (car outcomes)))
      (should (buffer-live-p chat))
      (should (buffer-live-p (pilish-session-input-buffer chat)))
      (should (string-match-p "retain failed task draft" (prin1-to-string (pilish-session-desktop-state chat)))))))

(ert-deftest pilish-runtime-native-test-managed-close-missing-binding-sends-no-cancellation ()
  "Missing initial task evidence cannot authorize worker input or root Stop."
  (pilish-runtime-native-test--with-managed-parent "complete"
    (delete-file (pilish-runtime-native-test--task-file runtime))
    (let (outcomes)
      (cl-letf (((symbol-function 'pilish-stop-runtime) (lambda (&rest _) (ert-fail "Missing evidence used root Stop"))))
        (pilish-close-session chat (lambda (error) (push (or error 'success) outcomes)))
        (pilish-runtime-native-test--wait (lambda () outcomes)))
      (should (= (length outcomes) 1))
      (should (stringp (car outcomes)))
      (should (buffer-live-p chat))
      (should (pilish--runtime-process-identity (plist-get runtime :pi-pid)))
      (should (pilish-session-busy-p chat))
      (let ((requests (seq-filter (lambda (event) (equal (plist-get event :event) "request"))
                                   (pilish-runtime-native-test--trace parent-directory))))
        (should (= (length requests) 1)))
      (process-send-string parent "cancel\n")
      (pilish-runtime-native-test--parent-event parent "cleanup-blocked")
      (process-send-string parent "release-cleanup\n")
      (pilish-runtime-native-test--parent-event parent "settled"))))

(ert-deftest pilish-runtime-native-test-managed-close-rejects-wrong-final-binding ()
  "A valid-shaped foreign final record cannot finish the captured owning task."
  (pilish-runtime-native-test--with-managed-parent "complete"
    (let ((input (pilish-session-input-buffer chat)) outcomes)
      (with-current-buffer input (insert "retain wrong binding draft"))
      (cl-letf (((symbol-function 'pilish-stop-runtime)
                 (lambda (&rest _) (ert-fail "Worker Close used root Stop"))))
        (pilish-close-session chat (lambda (error) (push (or error 'success) outcomes)))
        (let* ((blocked (pilish-runtime-native-test--parent-event parent "cleanup-blocked"))
               (original (with-temp-buffer
                           (insert-file-contents (pilish-runtime-native-test--task-file runtime))
                           (buffer-string)))
               (pending (json-parse-string original :object-type 'plist))
               (foreign (copy-tree pending)))
          (should-not outcomes)
          (should (equal pending (plist-get blocked :task)))
          (should (equal pending (plist-get (pilish-session-runtime chat) :task-binding)))
          (setq foreign (plist-put foreign :state "complete"))
          (setq foreign (plist-put foreign :leaseFile (concat (plist-get pending :leaseFile) ".wrong")))
          (setq foreign (plist-put foreign :parent
                                   (plist-put (copy-tree (plist-get pending :parent)) :taskId
                                              (concat (plist-get (plist-get pending :parent) :taskId) "-wrong"))))
          (unwind-protect
              (progn
                (pilish-runtime-native-test--replace-task-evidence runtime (json-encode foreign))
                ;; This is the actual periodic poll and release CLI reader, not
                ;; a mocked read result or a direct call to a settlement helper.
                (pilish-runtime-native-test--wait (lambda () outcomes))
                (should (= (length outcomes) 1))
                (should (string-match-p "identity/binding changed" (car outcomes)))
                (should (buffer-live-p chat))
                (should (buffer-live-p input))
                (should (equal pending (plist-get (pilish-session-runtime chat) :task-binding)))
                (should (equal (plist-get (plist-get (pilish-session-runtime chat) :task-status) :state)
                               "pending"))
                (should (string-match-p "retain wrong binding draft"
                                        (prin1-to-string (pilish-session-desktop-state chat)))))
            ;; The real owning parent must see its original pending record when
            ;; it resumes cleanup, even if any assertion above fails.
            (pilish-runtime-native-test--replace-task-evidence runtime original)))
        (let ((settled (copy-sequence outcomes)))
          (process-send-string parent "release-cleanup\n")
          (let ((finished (pilish-runtime-native-test--parent-event parent "task-finished")))
            (should (equal (plist-get (plist-get finished :task) :state) "complete"))
            (should (eq (plist-get finished :nameClaimHeld) :false)))
          (pilish-runtime-native-test--wait (lambda () (not (buffer-live-p chat))))
          (should-not (buffer-live-p input))
          (should (equal outcomes settled)))
        (let ((requests (seq-filter (lambda (event) (equal (plist-get event :event) "request"))
                                   (pilish-runtime-native-test--trace parent-directory))))
          (should (= (length requests) 1))
          (should (eq (plist-get (car requests) :retrospective) :false)))))))

(ert-deftest pilish-runtime-native-test-managed-close-timeout-retains-recovery-until-late-complete ()
  "Fire the real waiter timer without waiting; late completion never recalls it."
  (pilish-runtime-native-test--with-managed-parent "complete"
    (let ((input (pilish-session-input-buffer chat)) outcomes)
      (with-current-buffer input (insert "retain timed out task draft"))
      (cl-letf (((symbol-function 'pilish-stop-runtime)
                 (lambda (&rest _) (ert-fail "Timed-out worker Close used root Stop"))))
        (pilish-close-session chat (lambda (error) (push (or error 'success) outcomes)))
        (let ((blocked (pilish-runtime-native-test--parent-event parent "cleanup-blocked")))
          (should (equal (plist-get (plist-get blocked :task) :state) "pending"))
          (should (equal (plist-get blocked :workerState) "dead")))
        (pilish-runtime-native-test--wait
         (lambda () (not (process-live-p (pilish-session-process chat)))))
        (should-not outcomes)
        (let ((timer (buffer-local-value 'pilish--runtime-close-timer chat)))
          (should (timerp timer))
          (should (memq timer timer-list))
          ;; Invoke exactly the registered 45-second waiter callback. It owns
          ;; cancellation of its timer; no deadline delay or fake clock is needed.
          (apply (timer--function timer) (timer--args timer)))
        (should (= (length outcomes) 1))
        (should (string-match-p "timed out" (car outcomes)))
        (should (buffer-live-p chat))
        (should (buffer-live-p input))
        (should-not (buffer-local-value 'pilish--runtime-close-timer chat))
        (should (timerp (buffer-local-value 'pilish--runtime-task-timer chat)))
        (should (string-match-p "retain timed out task draft"
                                (prin1-to-string (pilish-session-desktop-state chat))))
        (let ((settled (copy-sequence outcomes)))
          (process-send-string parent "release-cleanup\n")
          (let ((finished (pilish-runtime-native-test--parent-event parent "task-finished")))
            (should (equal (plist-get (plist-get finished :task) :state) "complete"))
            (should (eq (plist-get finished :nameClaimHeld) :false)))
          (pilish-runtime-native-test--wait (lambda () (not (buffer-live-p chat))))
          (should-not (buffer-live-p input))
          (should (equal outcomes settled)))
        (with-current-buffer "*Pilish closed agents*"
          (should (string-match-p "retain timed out task draft" (buffer-string))))
        (let ((requests (seq-filter (lambda (event) (equal (plist-get event :event) "request"))
                                   (pilish-runtime-native-test--trace parent-directory))))
          (should (= (length requests) 1))
          (should (eq (plist-get (car requests) :retrospective) :false)))))))

(ert-deftest pilish-runtime-native-test-emacs-companion-direct-close-awaits-task-publication ()
  "A real Emacs host must not disconnect public Close before final publication."
  (skip-unless (getenv "PHIMACS_NATIVE_PILISH"))
  (skip-unless (getenv "PHIMACS_NATIVE_EMACS_ENDPOINT"))
  (should (string-prefix-p "/tmp/phimacs-test-" (or (getenv "PHIMACS_TEST_ROOT") "")))
  ;; The runner owns this -Q editor and Xvfb display, with explicit immutable
  ;; Lisp/grammar assets and worktree sources. A live frame avoids the installed
  ;; PGTK headless-daemon defect; no user daemon or display is touched.
  (should-not (bound-and-true-p server-process))
  (let* ((pilish-runtime-native-test--emacs-endpoint (getenv "PHIMACS_NATIVE_EMACS_ENDPOINT"))
         (server-name pilish-runtime-native-test--emacs-endpoint)
         (server-socket-dir (file-name-directory server-name))
         (server-process nil)
         (ghostel-module-directory (expand-file-name "ghostel" (getenv "PILISH_TEST_ASSETS"))))
    (should (file-in-directory-p pilish-runtime-native-test--emacs-endpoint (getenv "PHIMACS_TEST_ROOT")))
    (require 'pi-orchestration
             (expand-file-name "packages/orchestration/emacs/pi-orchestration.el"
                               (getenv "PHIMACS_ORCHESTRATION_ROOT")))
    (unwind-protect
        (progn
          (server-start)
          (pilish-runtime-native-test--with-managed-parent "complete"
            (let* ((id (seq-find (lambda (id)
                                   (eq (plist-get (gethash id pi-orchestration--targets) :buffer) chat))
                                 (hash-table-keys pi-orchestration--targets)))
                   (target (gethash id pi-orchestration--targets))
                   (input (pilish-session-input-buffer chat))
                   outcomes retired close-events
                   (pi-orchestration-target-functions
                    (cons (lambda (closed-id event)
                            (when (and (equal closed-id id) (eq event 'close))
                              (push event close-events)))
                          pi-orchestration-target-functions))
                   (pilish-session-closed-functions
                    (cons (lambda (closed)
                            (when (eq closed chat)
                              (push (pilish-session-runtime closed) retired)))
                          pilish-session-closed-functions)))
              (should target)
              (should (plist-get target :owns-view))
              (should (equal (plist-get target :placement) "worker"))
              (should-not (plist-get target :stop-pending))
              (with-current-buffer input (insert "direct companion Close unsent draft"))
              ;; Deliberately NOT pi-orchestration-stop-target: public Pilish
              ;; Close has no orchestration waiter/stop-pending flag.
              (pilish-close-session chat (lambda (error) (push (or error 'success) outcomes)))
              (pilish-runtime-native-test--parent-event parent "cleanup-blocked")
              ;; The helper emits this marker only after the actual emacsclient
              ;; close returned. Runtime exit is real; final cleanup is gated.
              (should (buffer-live-p chat))
              (should (buffer-live-p input))
              (should-not (plist-get target :stop-pending))
              (should (eq (gethash id pi-orchestration--targets) target))
              (should (plist-get target :exit-cleaned))
              (should-not outcomes)
              (should-not retired)
              (should-not close-events)
              (should (equal (plist-get (pilish-session-runtime chat) :task-binding) task))
              (should (equal (plist-get (pilish--runtime-task-read runtime) :state) "pending"))
              (should (string-match-p "direct companion Close unsent draft"
                                      (prin1-to-string (pilish-session-desktop-state chat))))
              (process-send-string parent "release-cleanup\n")
              (let ((finished (pilish-runtime-native-test--parent-event parent "task-finished")))
                (should (equal (plist-get (plist-get finished :task) :state) "complete"))
                (should (eq (plist-get finished :nameClaimHeld) :false))
                (should (eq (plist-get finished :registered) :false)))
              (pilish-runtime-native-test--wait (lambda () outcomes))
              (pilish-runtime-native-test--parent-event parent "settled")
              (should (equal outcomes '(success)))
              (should (= (length retired) 1))
              (should (equal (plist-get (car retired) :task-binding) task))
              (should (equal (plist-get (plist-get (car retired) :task-status) :state) "complete"))
              (should (equal close-events '(close)))
              (should-not (gethash id pi-orchestration--targets))
              (should-not (buffer-live-p chat))
              (should-not (buffer-live-p input))
              (with-current-buffer "*Pilish closed agents*"
                (should (string-match-p "direct companion Close unsent draft" (buffer-string)))))))
      (server-force-delete))))

(provide 'pilish-runtime-native-test)
;;; pilish-runtime-native-test.el ends here
