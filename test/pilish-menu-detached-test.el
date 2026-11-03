;;; pilish-menu-detached-test.el --- Detached menu contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Deterministic post-validation peers. Real socket/ownership validation belongs
;; to the owning runtime suite; these tests never invoke a provider or launcher.
;;; Code:
(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

(defvar pilish-runtime-pi-executable nil)

(defmacro pilish-menu-detached-test--with-view (&rest body)
  "Run BODY in a synthetic chat with a validated shared transport."
  (declare (indent 0) (debug t))
  `(let* ((chat (generate-new-buffer " *pilish-menu-shared-chat*"))
          (input (generate-new-buffer " *pilish-menu-shared-input*"))
          (proc (start-process "pilish-menu-peer" nil "cat"))
          (directory (file-name-as-directory temporary-file-directory))
          (pilish-quit-without-confirmation t))
     (set-process-query-on-exit-flag proc nil)
     (unwind-protect
         (with-current-buffer chat
           (pilish-chat-mode)
           (pilish--set-chat-session-identity directory "menu")
           (setq pilish--process proc pilish--input-buffer input
                 pilish--state (list :session-file "/tmp/menu-source.jsonl" :leaf-id "old"))
           (with-current-buffer input
             (pilish-input-mode)
             (setq pilish--chat-buffer chat)
             (insert "source draft"))
           (process-put proc 'pilish-chat-buffer chat)
           (process-put proc 'pilish-mux '(:protocol 2 :muxId "menu-owner"))
           (process-put proc 'pilish-detached t)
           (process-put proc 'pilish-mux-generation 4)
           (process-put proc 'pilish-mux-applied-generation 4)
           (process-put proc 'pilish-mux-live-generation 4)
           (process-put proc 'pilish-input-context
                        '(:sessionFile "/tmp/menu-source.jsonl" :leafId "old"
                          :contextId "menu-source-anchor"))
           ,@body)
       (process-put proc 'pilish-mux nil)
       (when (process-live-p proc) (delete-process proc))
       (dolist (buffer (list input chat))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (setq pilish--process nil))
           (kill-buffer buffer))))))

(ert-deftest pilish-menu-detached-test-reload-reconnects-without-replacing-or-touching-local-work ()
  "Shared reload reconnects the exact runtime rather than stopping its Pi."
  (pilish-menu-detached-test--with-view
    (let ((reconnected nil) (outcomes nil))
      (setq pilish--followup-queue '("local follow-up"))
      (cl-letf (((symbol-function 'pilish-session-runtime)
                 (lambda (_) '(:protocol 2 :mux-id "menu-owner")))
                ((symbol-function 'pilish-reconnect-runtime)
                 (lambda (buffer callback)
                   (setq reconnected buffer)
                   (funcall callback nil)
                   (funcall callback "late duplicate")))
                ((symbol-function 'pilish--start-process)
                 (lambda (&rest _) (ert-fail "Reload started another writer")))
                ((symbol-function 'pilish--terminate-process)
                 (lambda (&rest _) (ert-fail "Reload stopped a runtime"))))
        (pilish-reload (lambda (result) (push result outcomes))))
      (should (eq reconnected chat))
      (should (equal outcomes '(nil)))
      (should (equal pilish--followup-queue '("local follow-up")))
      (should (equal (with-current-buffer input (buffer-string)) "source draft")))))

(ert-deftest pilish-menu-detached-test-disconnected-reload-does-not-start-missing-runtime ()
  "A retained identity remains reconnect-only after the socket disappears."
  (pilish-menu-detached-test--with-view
    (let (outcomes)
      (setq pilish--process nil pilish--state nil)
      (cl-letf (((symbol-function 'pilish-session-runtime)
                 (lambda (_) '(:protocol 2 :mux-id "missing" :state "unavailable")))
                ((symbol-function 'pilish-reconnect-runtime)
                 (lambda (_ callback) (funcall callback "Runtime missing; Resume explicitly")))
                ((symbol-function 'pilish--start-process)
                 (lambda (&rest _) (ert-fail "Reload spawned missing runtime"))))
        (pilish-reload (lambda (result) (push result outcomes))))
      (should (equal outcomes '("Runtime missing; Resume explicitly"))))))

(ert-deftest pilish-menu-detached-test-managed-stopped-view-without-mux-does-not-resume ()
  "A migrated stopped view without a runtime ID still needs explicit Resume."
  (pilish-menu-detached-test--with-view
    (let (outcomes)
      (setq pilish--process nil)
      (cl-letf (((symbol-function 'pilish-storage-managed-p) (lambda () t))
                ((symbol-function 'pilish-session-runtime) (lambda (_) nil))
                ((symbol-function 'pilish-reconnect-runtime)
                 (lambda (_ callback) (funcall callback "No runtime identity; Resume explicitly")))
                ((symbol-function 'pilish--start-process)
                 (lambda (&rest _) (ert-fail "Reload silently resumed a stopped view"))))
        (pilish-reload (lambda (result) (push result outcomes))))
      (should (equal outcomes '("No runtime identity; Resume explicitly"))))))

(ert-deftest pilish-menu-detached-test-worker-refusal-retains-extension-reload ()
  "Worker refusal never replaces its actual Pi or transport."
  (pilish-menu-detached-test--with-view
    (let ((pilish-restart-refusal-functions (list (lambda (_) "Parent tracks actual Pi")))
          (pilish--commands '((:name "reload")))
          sent outcomes)
      (cl-letf (((symbol-function 'pilish-submit-prompt)
                 (lambda (buffer text callback)
                   (setq sent (list buffer text))
                   (funcall callback '(:success t))))
                ((symbol-function 'pilish--refresh-commands) #'ignore)
                ((symbol-function 'pilish-reconnect-runtime)
                 (lambda (&rest _) (ert-fail "Worker refusal was ignored"))))
        (pilish-reload (lambda (result) (push result outcomes))))
      (should (equal sent (list chat "/reload")))
      (should (equal outcomes '(nil))))))

(ert-deftest pilish-menu-detached-test-declined-new-conversation-is-inert ()
  "Shared replacement requires confirmation before any mutation or RPC."
  (pilish-menu-detached-test--with-view
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil))
              ((symbol-function 'pilish--rpc-async)
               (lambda (&rest _) (ert-fail "Declined replacement sent RPC"))))
      (pilish-new-session))
    (should (pilish--shared-input-ready-p proc))
    (should-not (pilish--session-transition-active-p))
    (should (equal (with-current-buffer input (buffer-string)) "source draft"))))

(ert-deftest pilish-menu-detached-test-new-conversation-does-not-mix-independent-history ()
  "Only snapshot/replay/live can finish rebuilding the shared view."
  (pilish-menu-detached-test--with-view
    (let (requests callbacks)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command callback)
                   (push command requests) (push callback callbacks)))
                ((symbol-function 'pilish--clear-chat-buffer)
                 (lambda () (ert-fail "Response cleared authoritative history"))))
        (pilish-new-session)
        (should (equal (plist-get (car requests) :type) "new_session"))
        (should-not (pilish--shared-input-ready-p proc))
        (funcall (car callbacks) '(:success t :data (:cancelled :false)))
        (should (equal (mapcar (lambda (command) (plist-get command :type)) requests)
                       '("pimux_bootstrap" "new_session")))
        (funcall (car callbacks) '(:success t :data (:generation 5)))
        (should-not (pilish--shared-input-ready-p proc))
        (should-not (pilish--session-transition-active-p))
        (should (equal (with-current-buffer input (buffer-string)) "source draft"))
        (pilish--shared-apply-snapshot
         proc (list :type "pimux_snapshot" :generation 5 :session
                    (list :file "/tmp/menu-new.jsonl" :id "new" :cwd directory)
                    :leafId "new" :entries [] :messages [] :idle t :run '(:active :false)
                    :inputContext '(:sessionFile "/tmp/menu-new.jsonl" :leafId "new"
                                    :contextId "menu-new-anchor")))
        (pilish--shared-finish-snapshot proc '(:generation 5))
        (should (pilish--shared-input-ready-p proc))
        (should (equal (plist-get pilish--state :session-file) "/tmp/menu-new.jsonl"))
        (should (equal (with-current-buffer input (buffer-string)) ""))
        (should (equal (plist-get (car (pilish-session-quarantine chat)) :draft)
                       "source draft"))))))

(ert-deftest pilish-menu-detached-test-shared-resume-does-not-read-destination ()
  "Only the owner's snapshot retargets the frontend after a switch."
  (pilish-menu-detached-test--with-view
    (let (requests callbacks)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'pilish--session-file-cwd-or-error)
                 (lambda (_) (ert-fail "Shared resume independently opened metadata")))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command callback) (push command requests) (push callback callbacks))))
        (pilish--resume-selected-session proc chat "/tmp/menu-destination.jsonl")
        (should (equal (car requests)
                       '(:type "switch_session" :sessionPath "/tmp/menu-destination.jsonl"
                         :pimuxContext (:sessionFile "/tmp/menu-source.jsonl" :leafId "old"
                                        :contextId "menu-source-anchor"))))
        (funcall (car callbacks) '(:success t :data (:cancelled :false)))
        (should (equal (plist-get (car requests) :type) "pimux_bootstrap"))
        (should (equal (plist-get pilish--state :session-file) "/tmp/menu-source.jsonl"))))))

(ert-deftest pilish-menu-detached-test-fork-text-is-recovery-not-overwrite ()
  "Fork RPC text never replaces a local draft composed for another context."
  (pilish-menu-detached-test--with-view
    (let (requests callbacks)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command callback) (push command requests) (push callback callbacks))))
        (pilish--execute-fork proc "entry")
        (funcall (car callbacks) '(:success t :data (:text "forked prompt")))
        (should (equal (with-current-buffer input (buffer-string)) "source draft"))
        (should (equal (plist-get (car (pilish-session-quarantine chat)) :draft) "forked prompt"))
        (should (equal (mapcar (lambda (command) (plist-get command :type)) requests)
                       '("pimux_bootstrap" "fork")))))))

(ert-deftest pilish-menu-detached-test-cancelled-transition-reconciles-without-discarding-input ()
  "Cancelled owner requests restore readiness only through a new snapshot."
  (pilish-menu-detached-test--with-view
    (let (requests callbacks)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command callback) (push command requests) (push callback callbacks))))
        (pilish-new-session)
        (funcall (car callbacks) '(:success t :data (:cancelled t)))
        (should (equal (plist-get (car requests) :type) "pimux_bootstrap"))
        (should-not (pilish--shared-input-ready-p proc))
        (should (equal (with-current-buffer input (buffer-string)) "source draft"))
        (should (equal (plist-get pilish--state :session-file) "/tmp/menu-source.jsonl"))))))

(ert-deftest pilish-menu-detached-test-uncertain-send-keeps-input-gated-and-never-retries ()
  "A failed send is not proof that a context replacement was unaccepted."
  (pilish-menu-detached-test--with-view
    (let ((sends 0))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (&rest _) (cl-incf sends) (error "Socket delivery uncertain"))))
        (should-error (pilish-new-session)))
      (should (= sends 1))
      (should-not (pilish--shared-input-ready-p proc))
      (should (equal (with-current-buffer input (buffer-string)) "source draft")))))

(ert-deftest pilish-menu-detached-test-initial-send-sees-the-validated-ready-boundary ()
  "A core readiness gate may guard management commands too."
  (pilish-menu-detached-test--with-view
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'pilish--rpc-async)
               (lambda (_ command _callback)
                 (should (equal (plist-get command :type) "new_session"))
                 (should (pilish--shared-input-ready-p proc)))))
      (pilish-new-session))
    (should-not (pilish--shared-input-ready-p proc))))

(ert-deftest pilish-menu-detached-test-shared-independent-history-paths-refuse ()
  "A forgotten caller cannot mix raw history reads with shared replay."
  (pilish-menu-detached-test--with-view
    (cl-letf (((symbol-function 'pilish--rpc-async)
               (lambda (&rest _) (ert-fail "Independent read reached shared Pi"))))
      (should-error (pilish--load-session-history proc nil chat) :type 'user-error)
      (should-error (pilish--refresh-transition-state-and-history proc chat 1)
                    :type 'user-error))))

(ert-deftest pilish-menu-detached-test-input-not-ready-cannot-replace-context ()
  "Commands do not race the first or an incomplete shared boundary."
  (pilish-menu-detached-test--with-view
    (process-put proc 'pilish-mux-awaiting-snapshot t)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (ert-fail "Not-ready command asked confirmation"))))
      (should-error (pilish-new-session) :type 'user-error))))

(ert-deftest pilish-menu-detached-test-close-never-confirms-and-preserves-failed-view ()
  "Close acts everywhere without a question; failure retains local input."
  (pilish-menu-detached-test--with-view
    (setq pilish--runtime '(:protocol 2 :mux-id "menu-owner" :state "live"))
    (let (called)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (_) (ert-fail "Close asked a confirmation question")))
                ((symbol-function 'y-or-n-p)
                 (lambda (_) (ert-fail "Close asked a confirmation question")))
                ((symbol-function 'pilish-stop-runtime)
                 (lambda (buffer callback)
                   (setq called buffer) (funcall callback "Exit is uncertain"))))
        (pilish-quit))
      (should (eq called chat))
      (should (buffer-live-p chat))
      (should (equal (with-current-buffer input (buffer-string)) "source draft")))))

(ert-deftest pilish-menu-detached-test-resume-is-explicit-public-operation ()
  "Only explicit Resume may intentionally create a fresh stopped-file agent."
  (pilish-menu-detached-test--with-view
    (let (called)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
                ((symbol-function 'pilish-resume-stopped-session)
                 (lambda (buffer callback) (setq called buffer) (funcall callback nil))))
        (pilish-resume-agent))
      (should (eq called chat)))))

(ert-deftest pilish-menu-detached-test-attach-uses-existing-runtime-only ()
  "Discovery selection delegates attachment and never invokes startup."
  (pilish-menu-detached-test--with-view
    (let* ((runtime '(:mux-id "existing" :session-file "/tmp/existing.jsonl" :state "idle"))
           selected displayed)
      (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime)))
                ((symbol-function 'completing-read) (lambda (_prompt choices &rest _arguments) (caar choices)))
                ((symbol-function 'pilish-attach-runtime)
                 (lambda (value &optional _) (setq selected value) chat))
                ((symbol-function 'pilish--display-buffers)
                 (lambda (buffer input-buffer &rest _) (setq displayed (list buffer input-buffer))))
                ((symbol-function 'pilish--start-process)
                 (lambda (&rest _) (ert-fail "Attachment started Pi"))))
        (pilish-attach-agent))
      (should (equal selected runtime))
      (should (equal displayed (list chat input))))))

(ert-deftest pilish-menu-detached-test-process-info-reports-real-runtime-identity ()
  "A network process is a transport, not the actual Pi process."
  (pilish-menu-detached-test--with-view
    (let (reported)
      (cl-letf (((symbol-function 'pilish-session-runtime)
                 (lambda (_) '(:mux-id "existing" :pid 123 :pi-pid 456 :pi-start-time "789" :state "idle")))
                ((symbol-function 'process-id) (lambda (_) (ert-fail "Transport PID used as Pi")))
                ((symbol-function 'message) (lambda (format-string &rest args)
                                              (setq reported (apply #'format format-string args)))))
        (pilish-process-info))
      (should (string-match-p "Pi PID 456/start 789, wrapper 123" reported)))))

(ert-deftest pilish-menu-detached-test-stopped-export-uses-exact-managed-helper ()
  "Stopped export never starts an independent raw Pi."
  (pilish-menu-detached-test--with-view
    (let ((pilish-runtime-pi-executable "/release/bin/pi") exported)
      (cl-letf (((symbol-function 'pilish--get-process) (lambda () nil))
                ((symbol-function 'pilish-storage-managed-p) (lambda () t))
                ((symbol-function 'pilish-storage-export-session)
                 (lambda (&rest arguments) (setq exported arguments)))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (&rest _) (ert-fail "Stopped export sent RPC"))))
        (pilish-export-html))
      (should (equal exported '("/tmp/menu-source.jsonl" "/tmp/menu-source.html" "/release/bin/pi"))))))

(ert-deftest pilish-menu-detached-test-live-export-uses-owner-rpc ()
  "A connected shared view exports through the actual owner only."
  (pilish-menu-detached-test--with-view
    (let (sent)
      (cl-letf (((symbol-function 'pilish-storage-managed-p) (lambda () t))
                ((symbol-function 'pilish-storage-export-session)
                 (lambda (&rest _) (ert-fail "Live export reopened a session")))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_process command _callback) (setq sent command))))
        (pilish-export-html "/tmp/export.html"))
      (should (equal sent
                     '(:type "export_html" :outputPath "/tmp/export.html"
                       :pimuxContext (:sessionFile "/tmp/menu-source.jsonl" :leafId "old"
                                      :contextId "menu-source-anchor")))))))

(provide 'pilish-menu-detached-test)
;;; pilish-menu-detached-test.el ends here
