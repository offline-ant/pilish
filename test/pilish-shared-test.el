;;; pilish-shared-test.el --- Processes shared through pimux -*- lexical-binding: t; -*-

(require 'pilish)
(require 'pilish-test-common)

(defun pilish-shared-test--hello (proc)
  "Deliver PROC's `pimux_hello' as primary."
  (pilish-test--stdout proc (list :type "pimux_hello" :protocol 1 :muxId "m1"
                                  :clientId "c0" :role "primary" :piPid 42
                                  :socket "/tmp/m1.sock")))

(defun pilish-shared-test--user (text)
  "Return a saved user message with TEXT."
  (list :role "user" :content text :timestamp 1784817120000))

(defun pilish-shared-test--assistant (text)
  "Return a saved assistant message with TEXT."
  (list :role "assistant" :timestamp 1784817121000 :stopReason "stop"
        :content (vector (list :type "text" :text text))))

(cl-defun pilish-shared-test--snapshot
    (generation reason messages &key (file "/tmp/s1.jsonl") (cwd default-directory)
                (name :null) (active :false) (replay 0) (truncated :false))
  "Return a `pimux_snapshot' record."
  (list :type "pimux_snapshot" :generation generation :reason reason
        :session (list :file file :id (format "id-%s" file) :name name :cwd cwd)
        :model (list :provider "faux" :id "two" :name "two")
        :thinkingLevel "high" :idle (if (eq active t) :false t) :leafId "l1"
        :messages (vconcat messages)
        :run (list :active active :compacting :false :tailTruncated truncated)
        :replay replay))

(defun pilish-shared-test--dialog (id title)
  "Return a select dialog request ID with TITLE."
  (list :type "extension_ui_request" :id id :method "select" :title title
        :options ["One" "Two"]))

(defun pilish-shared-test--widget-p (chat id)
  "Return the start of CHAT's inline widget of request ID, or nil."
  (with-current-buffer chat
    (let ((position (point-min)) found)
      (while (and (not found) position (< position (point-max)))
        (if (equal (get-text-property position 'pilish-dialog) id)
            (setq found position)
          (setq position (next-single-property-change position 'pilish-dialog))))
      found)))

(ert-deftest pilish-shared-test-hello-marks-process-shared ()
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (should-not (pilish-session-mux chat))
    (pilish-shared-test--hello proc)
    (should (pilish--process-shared-p proc))
    (should (equal (plist-get (pilish-session-mux chat) :muxId) "m1"))))

(ert-deftest pilish-shared-test-dialogs-close-on-record-not-on-run-start ()
  "A shared process's dialogs survive another run and close when reported."
  (pilish-test-with-rpc-session (chat _input proc commands)
    (let ((pilish-extension-dialog-style 'inline)
          events)
      (let ((pilish-extension-dialog-functions
             (list (lambda (_chat request state)
                     (push (list (plist-get request :id) state) events)))))
        (pilish-shared-test--hello proc)
        (pilish-test--stdout proc (pilish-shared-test--dialog "d1" "Pick"))
        (should (pilish-shared-test--widget-p chat "d1"))
        ;; Another frontend's run starts: the command's dialog still waits.
        (pilish-test--stdout proc '(:type "agent_start"))
        (should (equal (mapcar (lambda (r) (plist-get r :id))
                               (pilish-session-pending-dialogs chat))
                       '("d1")))
        ;; Answered elsewhere: closed without an answer from here.
        (pilish-test--stdout proc '(:type "pimux_dialog_closed" :id "d1"
                                    :reason "answered" :clientId "c1"))
        (should-not (pilish-session-pending-dialogs chat))
        (should-not (pilish-shared-test--widget-p chat "d1"))
        (should (equal (car events) '("d1" close)))
        (should-not (seq-find (lambda (c) (equal (plist-get c :type)
                                                 "extension_ui_response"))
                              commands))))))

(ert-deftest pilish-shared-test-unshared-run-start-still-cancels-dialogs ()
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (let ((pilish-extension-dialog-style 'inline))
      (cl-letf (((symbol-function 'pilish--send-extension-ui-response) #'ignore))
        (pilish-test--stdout proc (pilish-shared-test--dialog "d1" "Pick"))
        (pilish-test--stdout proc '(:type "agent_start"))
        (should-not (pilish-session-pending-dialogs chat))))))

(ert-deftest pilish-shared-test-snapshot-replays-open-dialogs-once ()
  "A snapshot keeps replayed dialogs, asks them once, and closes the others."
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (let ((pilish-extension-dialog-style 'inline))
      (pilish-shared-test--hello proc)
      (pilish-test--stdout proc (pilish-shared-test--dialog "d1" "Kept")
                           (pilish-shared-test--dialog "d2" "Gone"))
      (pilish-test--stdout
       proc
       (pilish-shared-test--snapshot 3 "gap" (list (pilish-shared-test--user "hi")
                                                   (pilish-shared-test--assistant "hello"))
                                     :replay 1)
       (pilish-shared-test--dialog "d1" "Kept")
       '(:type "pimux_live" :generation 3))
      (should (equal (mapcar (lambda (r) (plist-get r :id))
                             (pilish-session-pending-dialogs chat))
                     '("d1")))
      (with-current-buffer chat
        (should (string-match-p "hello" (buffer-string)))
        ;; The widget follows the rebuilt transcript, shown once.
        (should (= (how-many "Kept" (point-min) (point-max)) 1))
        (should (> (pilish-shared-test--widget-p chat "d1")
                   (save-excursion (goto-char (point-min))
                                   (search-forward "hello"))))))))

(ert-deftest pilish-shared-test-gap-rebuilds-and-replays-run-in-flight ()
  "After a gap the transcript is rebuilt and the run in flight continues."
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (pilish-shared-test--hello proc)
    (pilish-test--stdout proc '(:type "agent_start"))
    (pilish-test--stdout proc '(:type "pimux_gap" :generation 5 :dropped 12))
    (pilish-test--stdout
     proc
     (pilish-shared-test--snapshot 5 "gap" (list (pilish-shared-test--user "first")
                                                 (pilish-shared-test--assistant "answer one"))
                                   :active t :replay 3)
     '(:type "agent_start")
     (list :type "message_start"
           :message (list :role "assistant" :content [] :timestamp 1784817122000))
     (list :type "message_update"
           :assistantMessageEvent (list :type "text_delta" :contentIndex 0
                                        :delta "streamed part"))
     '(:type "pimux_live" :generation 5))
    (with-current-buffer chat
      (pilish--flush-stream-deltas)
      (should (eq pilish--status 'streaming))
      (should (string-match-p "answer one" (buffer-string)))
      (should (string-match-p "streamed part" (buffer-string)))
      (should (equal (plist-get pilish--state :thinking-level) "high")))
    ;; The run ended before the snapshot: only its settlement follows.
    (pilish-test--stdout proc '(:type "agent_settled"))
    (with-current-buffer chat
      (should (eq pilish--status 'idle)))))

(ert-deftest pilish-shared-test-session-change-adopted-in-place ()
  "A session change from another frontend keeps process, draft and queue."
  (let* ((dir (file-name-as-directory (pilish-test--make-temp-directory "pi-shared-")))
         identities)
    (unwind-protect
        (pilish-test-with-rpc-session (chat input proc commands)
          (let ((pilish-session-identity-functions
                 (list (lambda (buffer)
                         (push (pilish-session-file buffer) identities)))))
            (pilish-shared-test--hello proc)
            (with-current-buffer input (insert "my draft"))
            (with-current-buffer chat
              (setq pilish--followup-queue '("queued later"))
              (setq pilish--state (list :session-file "/tmp/old.jsonl"))
              (let ((inhibit-read-only t)) (insert "old transcript\n")))
            (pilish-test--stdout
             proc
             (list :type "pimux_session_changed" :generation 7 :reason "new"
                   :sessionFile "/tmp/new.jsonl" :previousSessionFile "/tmp/old.jsonl"
                   :sessionId "n" :sessionName :null :cwd dir)
             (pilish-shared-test--snapshot 7 "session_changed"
                                           (list (pilish-shared-test--user "new start"))
                                           :file "/tmp/new.jsonl" :cwd dir :name "Fresh")
             '(:type "pimux_live" :generation 7))
            (should (eq (pilish-session-process chat) proc))
            (should (equal (pilish-session-file chat) "/tmp/new.jsonl"))
            (should (equal (pilish-session-directory chat) dir))
            (should (equal (pilish-session-title chat) "Fresh"))
            (should (equal (car identities) "/tmp/new.jsonl"))
            (should (equal (plist-get (pilish-session-model chat) :id) "two"))
            (with-current-buffer chat
              (should-not (string-match-p "old transcript" (buffer-string)))
              (should (string-match-p "new start" (buffer-string)))
              (should (equal pilish--followup-queue '("queued later"))))
            (with-current-buffer input
              (should (equal (buffer-string) "my draft")))
            ;; Commands are refetched for the new session.
            (should (seq-find (lambda (c) (equal (plist-get c :type) "get_commands"))
                              commands))))
      (delete-directory dir t))))

(ert-deftest pilish-shared-test-gap-snapshot-adopts-a-session-it-missed ()
  "A client that lost the session change adopts it from the gap's snapshot."
  (let ((dir (file-name-as-directory (pilish-test--make-temp-directory "pi-shared-"))))
    (unwind-protect
        (pilish-test-with-rpc-session (chat _input proc _commands)
          (pilish-shared-test--hello proc)
          (with-current-buffer chat
            (setq pilish--state (list :session-file "/tmp/old.jsonl")))
          (pilish-test--stdout
           proc
           '(:type "pimux_gap" :generation 4 :dropped 3)
           (pilish-shared-test--snapshot 4 "gap" (list (pilish-shared-test--user "moved"))
                                         :file "/tmp/new.jsonl" :cwd dir)
           '(:type "pimux_live" :generation 4))
          (should (equal (pilish-session-file chat) "/tmp/new.jsonl"))
          (should (equal (pilish-session-directory chat) dir))
          (should (eq (pilish-session-process chat) proc)))
      (delete-directory dir t))))

(ert-deftest pilish-shared-test-adoption-takes-a-free-name-on-collision ()
  "A session moving where another chat has this one's name gets a free name."
  (let* ((dir (file-name-as-directory (pilish-test--make-temp-directory "pi-shared-")))
         (occupied (get-buffer-create (pilish--buffer-name :chat dir nil))))
    (unwind-protect
        (pilish-test-with-rpc-session (chat input proc _commands)
          (pilish-shared-test--hello proc)
          (with-current-buffer chat
            (pilish--set-chat-session-identity
             (file-name-as-directory temporary-file-directory)))
          (with-current-buffer occupied
            (pilish-chat-mode)
            (pilish--set-chat-session-identity dir))
          (pilish-test--stdout
           proc
           (pilish-shared-test--snapshot 7 "session_changed" nil
                                         :file "/tmp/new.jsonl" :cwd dir)
           '(:type "pimux_live" :generation 7))
          (should (equal (pilish-session-directory chat) dir))
          (should (equal (pilish-session-name chat) "2"))
          (should (equal (buffer-name chat) (pilish--buffer-name :chat dir "2")))
          (should (equal (buffer-name input) (pilish--buffer-name :input dir "2")))
          (with-current-buffer chat
            (should (equal default-directory dir))))
      (kill-buffer occupied)
      (delete-directory dir t))))

(ert-deftest pilish-shared-test-snapshot-clears-only-unreplayed-ui ()
  "A stale status clears through the hooks; one still set never flickers."
  (pilish-test-with-rpc-session (chat input proc _commands)
    (let* (changes
           (pilish-extension-status-functions
            (list (lambda (_chat key text) (push (cons key text) changes)))))
      (pilish-shared-test--hello proc)
      (pilish-test--stdout
       proc
       '(:type "extension_ui_request" :id "s1" :method "setStatus"
         :statusKey "worker-frame" :statusText "worker:waiting")
       '(:type "extension_ui_request" :id "s2" :method "setStatus"
         :statusKey "kept" :statusText "still here")
       '(:type "extension_ui_request" :id "w1" :method "setWidget"
         :widgetKey "old" :widgetLines ["old widget"])
       '(:type "extension_ui_request" :id "w2" :method "setWidget"
         :widgetKey "new" :widgetLines ["new widget"]))
      (setq changes nil)
      (pilish-test--stdout
       proc
       (pilish-shared-test--snapshot 3 "gap" nil :replay 2)
       '(:type "extension_ui_request" :id "s3" :method "setStatus"
         :statusKey "kept" :statusText "still here")
       '(:type "extension_ui_request" :id "w3" :method "setWidget"
         :widgetKey "new" :widgetLines ["new widget"])
       '(:type "pimux_live" :generation 3))
      (should-not (pilish-session-extension-status chat "worker-frame"))
      (should (equal (pilish-session-extension-status chat "kept") "still here"))
      (should (equal changes '(("worker-frame"))))
      (with-current-buffer chat
        (should (equal (mapcar #'car pilish--extension-widgets) '("new"))))
      (with-current-buffer input
        (should-not (string-match-p
                     "old widget"
                     (overlay-get pilish--extension-widget-overlay 'before-string)))))))

(ert-deftest pilish-shared-test-truncated-replay-marks-and-refreshes-after-the-run ()
  "A replay missing part of the run says so; settling brings the full text."
  (pilish-test-with-rpc-session (chat _input proc commands)
    (pilish-shared-test--hello proc)
    (pilish-test--stdout
     proc
     (pilish-shared-test--snapshot 5 "gap" (list (pilish-shared-test--user "first"))
                                   :active t :truncated t :replay 3)
     '(:type "agent_start")
     (list :type "message_start"
           :message (list :role "assistant" :content [] :timestamp 1784817122000))
     (list :type "message_update"
           :assistantMessageEvent (list :type "text_delta" :contentIndex 0
                                        :delta "tail of a long"))
     '(:type "pimux_live" :generation 5))
    (with-current-buffer chat
      (pilish--flush-stream-deltas)
      (should (string-match-p "output was lost" (buffer-string))))
    (should-not (seq-find (lambda (c) (equal (plist-get c :type) "pimux_bootstrap"))
                          commands))
    (pilish-test--stdout
     proc
     (list :type "message_end"
           :message (pilish-shared-test--assistant "head and tail of a long reply"))
     '(:type "agent_end" :messages [])
     '(:type "agent_settled"))
    (let ((request (seq-find (lambda (c) (equal (plist-get c :type) "pimux_bootstrap"))
                             commands)))
      (should request)
      (should (equal (plist-get request :include) ["messages"]))
      (pilish-test--stdout
       proc
       (list :type "response" :id (plist-get request :id) :command "pimux_bootstrap"
             :success t :data '(:generation 6))
       (pilish-shared-test--snapshot
        6 "request" (list (pilish-shared-test--user "first")
                          (pilish-shared-test--assistant "head and tail of a long reply")))
       '(:type "pimux_live" :generation 6)))
    (with-current-buffer chat
      (should (string-match-p "head and tail of a long reply" (buffer-string)))
      (should-not (string-match-p "output was lost" (buffer-string)))
      (should (eq pilish--status 'idle)))
    ;; One refresh per truncated snapshot.
    (pilish-test--stdout proc '(:type "agent_settled"))
    (should (= 1 (seq-count (lambda (c) (equal (plist-get c :type) "pimux_bootstrap"))
                            commands)))))

(ert-deftest pilish-shared-test-slash-command-dialog-needs-no-prompt-response ()
  "Pi answers a slash command's prompt only after the command's dialog closed.
The dialog has to work while that response is outstanding."
  (pilish-test-with-rpc-session (chat _input proc commands)
    (let ((pilish-extension-dialog-style 'inline))
      (pilish-shared-test--hello proc)
      (with-current-buffer chat
        (pilish--send-prompt "/pick"))
      (let ((prompt (seq-find (lambda (c) (equal (plist-get c :type) "prompt")) commands)))
        (pilish-test--stdout proc (pilish-shared-test--dialog "d1" "Pick"))
        (should (pilish-session-pending-dialogs chat))
        (pilish--extension-dialog-respond
         proc (pilish--extension-dialog-request proc "d1") '(:value "One"))
        (should (seq-find (lambda (c) (and (equal (plist-get c :type) "extension_ui_response")
                                           (equal (plist-get c :value) "One")))
                          commands))
        (pilish-test--stdout
         proc
         '(:type "pimux_dialog_closed" :id "d1" :reason "answered" :clientId "c0")
         (list :type "response" :id (plist-get prompt :id) :command "prompt"
               :success t :data '(:disposition "handled")))
        (should-not (pilish-session-pending-dialogs chat))
        (with-current-buffer chat
          (should (eq pilish--status 'idle)))))))

(defun pilish-shared-test--pi (seconds)
  "Start a stand-in for a shared Pi that lives SECONDS, returning the process."
  (make-process :name "pilish-shared-pi" :command (list "sleep" (number-to-string seconds))
                :connection-type 'pipe :noquery t))

(defun pilish-shared-test--wrapper ()
  "Start a stand-in for pimux: it exits on end of input."
  (make-process :name "pilish-shared-wrapper" :command '("cat")
                :connection-type 'pipe :noquery t))

(defun pilish-shared-test--share (wrapper agent)
  "Mark WRAPPER as the shared process of the stand-in AGENT."
  (process-put wrapper 'pilish-mux (list :muxId "m" :piPid (process-id agent)))
  (process-put wrapper 'pilish-mux-pi-start
               (alist-get 'start (process-attributes (process-id agent)))))

(defmacro pilish-shared-test--reloading (bindings outcome &rest body)
  "Run BODY reloading a shared chat; OUTCOME gets the reload's callback calls.
BINDINGS is (CHAT WRAPPER AGENT LIFE STARTS), LIFE the seconds the stand-in Pi
lives and STARTS a list with an entry for each new process."
  (declare (indent 2))
  (pcase-let ((`(,chat ,wrapper ,agent ,life ,starts) bindings))
    `(pilish-test-with-rpc-session (,chat _input ,wrapper commands)
       (ignore commands)
       (let* ((,agent (pilish-shared-test--pi ,life))
              (,starts nil)
              (,outcome nil)
              (new (start-process "pilish-shared-new" nil "cat")))
         (unwind-protect
             (progn
               (set-process-query-on-exit-flag new nil)
               (pilish-shared-test--share ,wrapper ,agent)
               (with-current-buffer ,chat
                 (setq pilish--state (list :session-file "/tmp/s1.jsonl")))
               (cl-letf (((symbol-function 'pilish--start-process)
                          (lambda (&rest _) (push (list :pi-running (process-live-p ,agent))
                                                  ,starts)
                            new))
                         ((symbol-function 'pilish--send-string)
                          (lambda (_process line)
                            (let ((command (pilish--parse-json-line line)))
                              (push command commands)
                              (when (equal (plist-get command :type) "switch_session")
                                (pilish--process-filter
                                 new (concat
                                      (json-serialize
                                       (list :type "response" :id (plist-get command :id)
                                             :command "switch_session" :success :false
                                             :error "stop here")
                                       :false-object :false :null-object :null)
                                      "\n")))))))
                 (with-current-buffer ,chat
                   (pilish-reload (lambda (reason) (push (list reason) ,outcome))))
                 ,@body))
           (dolist (process (list ,agent new))
             (when (process-live-p process) (delete-process process))))))))

(defun pilish-shared-test--wait (predicate)
  "Run timers until PREDICATE holds, for at most ten seconds."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(ert-deftest pilish-shared-test-reload-waits-for-the-old-pi-to-exit ()
  "The new process starts only when the shared Pi can no longer write."
  (pilish-shared-test--reloading (chat wrapper agent 0.4 starts) outcome
    ;; pimux has gone, but Pi still finishes.
    (pilish-shared-test--wait (lambda () (not (process-live-p wrapper))))
    (should-not starts)
    (should (process-live-p agent))
    (pilish-shared-test--wait (lambda () starts))
    (should (equal starts '((:pi-running nil))))
    (pilish-shared-test--wait (lambda () outcome))
    (should (equal outcome '(("Failed to reload - stop here"))))
    ;; The failure is reported in the chat: no process is left.
    (with-current-buffer chat
      (should-not pilish--process)
      (should (string-match-p "Reload failed" (buffer-string))))))

(ert-deftest pilish-shared-test-reload-kills-a-pi-that-stays-and-keeps-the-draft ()
  (let ((pilish--shared-close-seconds 0.1))
    (pilish-shared-test--reloading (chat _wrapper agent 30 starts) outcome
      (with-current-buffer (buffer-local-value 'pilish--input-buffer chat)
        (insert "unsent draft"))
      (pilish-shared-test--wait (lambda () starts))
      (should-not (process-live-p agent))
      (should (equal starts '((:pi-running nil))))
      (with-current-buffer (buffer-local-value 'pilish--input-buffer chat)
        (should (equal (buffer-string) "unsent draft"))))))

(ert-deftest pilish-shared-test-reload-after-the-wrapper-died-waits-for-pi ()
  "A killed wrapper leaves Pi running: the chat must not reopen its file yet."
  (pilish-test-with-rpc-session (chat _input wrapper _commands)
    (let ((agent (pilish-shared-test--pi 0.4))
          (new (start-process "pilish-shared-new" nil "cat"))
          starts)
      (unwind-protect
          (progn
            (set-process-query-on-exit-flag new nil)
            (pilish-shared-test--share wrapper agent)
            (with-current-buffer chat
              (setq pilish--state (list :session-file "/tmp/s1.jsonl")))
            (delete-process wrapper)
            (with-current-buffer chat
              (pilish--mark-process-exited wrapper '(:error "killed"))
              (should-not pilish--process))
            (cl-letf (((symbol-function 'pilish--start-process)
                       (lambda (&rest _) (push (process-live-p agent) starts) new)))
              (with-current-buffer chat (pilish-reload #'ignore))
              (should-not starts)
              (pilish-shared-test--wait (lambda () starts))
              (should (equal starts '(nil)))))
        (dolist (process (list agent new))
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest pilish-shared-test-replacement-records-its-own-pi ()
  "A reload's new process says hello before it is the chat's process."
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (let ((replacement (start-process "pilish-shared-new" nil "cat")))
      (unwind-protect
          (progn
            (set-process-query-on-exit-flag replacement nil)
            (pilish-shared-test--hello proc)
            (process-put replacement 'pilish-chat-buffer chat)
            (pilish-test--stdout
             replacement (list :type "pimux_hello" :protocol 1 :muxId "m2" :clientId "c0"
                               :role "primary" :piPid (emacs-pid) :socket "/tmp/m2.sock"))
            (should (process-get replacement 'pilish-mux-pi-start))
            (should (pilish--shared-pi-running-p replacement)))
        (delete-process replacement)))))

(ert-deftest pilish-shared-test-recycled-pid-is-not-pi ()
  (let ((wrapper (pilish-shared-test--wrapper))
        (agent (pilish-shared-test--pi 30)))
    (unwind-protect
        (progn
          (pilish-shared-test--share wrapper agent)
          (should (pilish--shared-pi-running-p wrapper))
          (process-put wrapper 'pilish-mux-pi-start (time-subtract nil 3600))
          (should-not (pilish--shared-pi-running-p wrapper)))
      (delete-process wrapper)
      (delete-process agent))))

(ert-deftest pilish-shared-test-unshared-reload-keeps-the-old-process-until-replaced ()
  "A process nothing else talks to stays while its replacement starts."
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (let ((new (start-process "pilish-unshared-new" nil "cat"))
          old-live outcome)
      (unwind-protect
          (cl-letf (((symbol-function 'pilish--start-process)
                     (lambda (&rest _) (setq old-live (process-live-p proc)) new)))
            (set-process-query-on-exit-flag new nil)
            (with-current-buffer chat
              (setq pilish--state (list :session-file "/tmp/s1.jsonl"))
              (pilish-reload (lambda (reason) (setq outcome reason))))
            (should old-live)
            (should (process-live-p proc))
            (should-not outcome))
        (delete-process new)))))

(ert-deftest pilish-shared-test-refused-reload-keeps-the-process ()
  "A session whose process a host tracks is never replaced."
  (pilish-test-with-rpc-session (chat _input proc commands)
    (let ((pilish-restart-refusal-functions (list (lambda (_chat) "Tracked by its parent")))
          outcomes)
      (cl-letf (((symbol-function 'pilish--start-process)
                 (lambda (&rest _) (error "Must not start a process"))))
        (with-current-buffer chat
          (setq pilish--state (list :session-file "/tmp/s1.jsonl"))
          ;; Without an extension command Pi cannot reload in place.
          (pilish-reload (lambda (reason) (push reason outcomes)))
          (should (equal outcomes '("Tracked by its parent")))
          (should-not commands)
          (setq pilish--commands '((:name "reload" :source "extension")))
          (pilish-reload (lambda (reason) (push reason outcomes))))
        (should (process-live-p proc))
        (let ((prompt (car commands)))
          (should (equal (plist-get prompt :message) "/reload"))
          (pilish-test--stdout
           proc (list :type "response" :id (plist-get prompt :id) :command "prompt"
                      :success t :data '(:disposition "handled"))))
        (should (equal outcomes '(nil "Tracked by its parent")))
        (should (equal (plist-get (car commands) :type) "get_commands"))))))

(ert-deftest pilish-shared-test-own-session-transition-is-not-rebuilt-twice ()
  "Pilish's own switch rebuilds itself; its snapshot only replays."
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (pilish-shared-test--hello proc)
    (with-current-buffer chat
      (let ((inhibit-read-only t)) (insert "own transcript\n"))
      (pilish--begin-session-transition proc))
    (pilish-test--stdout
     proc
     (pilish-shared-test--snapshot 2 "session_changed"
                                   (list (pilish-shared-test--user "elsewhere")))
     '(:type "pimux_live" :generation 2))
    (with-current-buffer chat
      (should (string-match-p "own transcript" (buffer-string))))))

(ert-deftest pilish-shared-test-model-thinking-and-name-changes ()
  (pilish-test-with-rpc-session (chat _input proc _commands)
    (pilish-shared-test--hello proc)
    (pilish-test--stdout
     proc
     '(:type "pimux_model_changed" :model (:provider "faux" :id "three")
       :previousModel (:provider "faux" :id "two") :source "set")
     '(:type "thinking_level_changed" :level "low")
     '(:type "session_info_changed" :name "Renamed"))
    (should (equal (plist-get (pilish-session-model chat) :id) "three"))
    (should (equal (pilish-session-title chat) "Renamed"))
    (with-current-buffer chat
      (should (equal (plist-get pilish--state :thinking-level) "low")))))

(ert-deftest pilish-shared-test-terminate-closes-input-of-shared-process ()
  "A shared process gets end of input instead of being killed."
  (let ((shared (make-process :name "pilish-shared-cat" :command '("cat")
                              :connection-type 'pipe :noquery t))
        (plain (make-process :name "pilish-plain-cat" :command '("cat")
                             :connection-type 'pipe :noquery t)))
    (unwind-protect
        (progn
          (process-put shared 'pilish-mux '(:muxId "m"))
          (pilish--terminate-process shared)
          (pilish--terminate-process plain)
          (should-not (process-live-p plain))
          (pilish-test-wait-for-process-exit shared 5)
          ;; cat ended on its own: end of input, not a signal.
          (should (eq (process-status shared) 'exit))
          (should (= (process-exit-status shared) 0)))
      (dolist (p (list shared plain))
        (when (process-live-p p) (delete-process p))))))

(provide 'pilish-shared-test)
;;; pilish-shared-test.el ends here
