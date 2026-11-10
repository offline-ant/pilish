;;; pilish-runtime-test.el --- Direct socket runtime contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Deterministic equal-peer socket tests; no production discovery or paid models.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'pilish)

(defvar pilish-runtime-test--clients nil)
(defvar pilish-runtime-test--received nil)
(defvar pilish-runtime-test--chat nil)

(defun pilish-runtime-test--discovery (runtime)
  "Return a raw discovery record for the normalized test RUNTIME."
  (list :protocol (plist-get runtime :protocol)
        :muxId (plist-get runtime :mux-id) :socket (plist-get runtime :socket)
        :pid (plist-get runtime :pid) :piPid (plist-get runtime :pi-pid)
        :piIdentity (list :startTime (plist-get runtime :pi-start-time)
                          :bootId (plist-get runtime :pi-boot-id))
        :sessionFile (plist-get runtime :session-file) :cwd (plist-get runtime :directory)
        :service (plist-get runtime :service)
        :placement (plist-get runtime :placement) :parent (plist-get runtime :parent)
        :orchestration (plist-get runtime :orchestration)))

(defun pilish-runtime-test--previous-boot (runtime)
  "Copy RUNTIME with complete owner identities from a synthetic previous boot."
  (let ((previous (copy-tree runtime))
        (boot "00000000-0000-4000-8000-000000000001"))
    (setq previous (plist-put previous :mux-id "previous-boot")
          previous (plist-put previous :owner-boot-id boot)
          previous (plist-put previous :pi-boot-id boot))
    previous))

(defun pilish-runtime-test--wait (predicate)
  "Wait up to three seconds for PREDICATE without arbitrary sleeps."
  (let ((deadline (+ (float-time) 3)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro pilish-runtime-test--with-peer (options &rest body)
  "Run BODY with a private fake peer, configured by OPTIONS."
  (declare (indent 1))
  `(let* ((directory (make-temp-file "pilish-peer-" t))
          (socket (expand-file-name "agent.sock" directory))
          (file (expand-file-name "one.jsonl" directory))
          (identity (pilish--runtime-process-identity (emacs-pid)))
          (runtime (list :protocol 2 :mux-id "test-runtime" :socket socket
                         :pid (emacs-pid) :pi-pid (emacs-pid)
                         :owner-start-time (plist-get identity :start-time)
                         :owner-boot-id (plist-get identity :boot-id)
                         :pi-start-time (plist-get identity :start-time)
                         :pi-boot-id (plist-get identity :boot-id)
                         :session-file file :directory directory :placement "root"))
          (pilish-runtime-mode 'detached)
          (pilish-runtime-test--clients nil)
          (pilish-runtime-test--received nil)
          (pilish-runtime-test--chat nil)
          (options ,options)
          (server
           (make-network-process
            :name "pilish-fake-owner" :family 'local :server t :service socket :noquery t
            :filter (lambda (client chunk)
                      (push chunk pilish-runtime-test--received)
                      (let ((framed (pilish--accumulate-line-chunks
                                     (process-get client 'pilish-test-partial) chunk)))
                        (process-put client 'pilish-test-partial (cdr framed))
                        (dolist (line (car framed))
                          (let ((command (pilish--parse-json-line line)))
                            (when (equal (plist-get command :type) "get_commands")
                              (process-send-string
                               client (pilish--encode-command
                                       (list :type "response" :command "get_commands"
                                             :id (plist-get command :id) :success t
                                             :data (list :commands (or (plist-get options :commands) []))))))))))
            :log
            (lambda (_server client _message)
              (push client pilish-runtime-test--clients)
              (set-process-query-on-exit-flag client nil)
              (unless (plist-get options :silent)
                (dolist
                    (record
                     (list
                      (list :type "pimux_hello" :protocol (or (plist-get options :protocol) 2)
                            :muxId "test-runtime" :clientId 1 :piPid (emacs-pid)
                            :socket socket :capabilities
                            (if (plist-get options :no-context-capability)
                                ["snapshot" "stop" "detached"]
                              ["snapshot" "stop" "detached" "contextual-input"]))
                      (list :type "pimux_snapshot" :generation 1 :reason "attach" :replay 0
                            :session (list :file file :id "s1" :name :null :cwd directory)
                            :model (list :provider "faux" :id "faux")
                            :thinkingLevel "off" :idle t :leafId :null
                            :inputContext (list :sessionFile file :leafId :null
                                                :contextId "fake-branch-one")
                            :entries [] :messages [] :run (list :active :false))))
                  (process-send-string client (pilish--encode-command record)))
                (unless (plist-get options :no-live)
                  (process-send-string client
                                       (pilish--encode-command
                                        '(:type "pimux_live" :generation 1)))))))))
     (set-file-modes directory #o700)
     (set-file-modes socket #o600)
     (unwind-protect (progn ,@body)
       (when (buffer-live-p pilish-runtime-test--chat)
         (let ((input (pilish-session-input-buffer pilish-runtime-test--chat))
               (pilish-quit-without-confirmation t))
           (kill-buffer pilish-runtime-test--chat)
           (when (buffer-live-p input) (kill-buffer input))))
       (dolist (client pilish-runtime-test--clients)
         (when (process-live-p client) (delete-process client)))
       (when (process-live-p server) (delete-process server))
       (delete-directory directory t))))

(defun pilish-runtime-test--write-task (file record)
  "Publish test task RECORD in FILE for the read-only CLI fixture."
  (with-temp-file file (insert (json-serialize record))))

(defmacro pilish-runtime-test--with-worker (options &rest body)
  "Run BODY with an attachable worker and mutable task evidence, using OPTIONS."
  (declare (indent 1))
  `(pilish-runtime-test--with-peer ,options
     (let* ((task-file (expand-file-name "task.json" directory))
            (pilish-runtime-task-status-executable (expand-file-name "task-status" directory))
            (json-identity (list :pid (emacs-pid)
                                 :startTime (plist-get identity :start-time)
                                 :bootId (plist-get identity :boot-id)))
            (parent (list :process json-identity :taskId "test-task"))
            (task-record (list :schema 1 :muxId "test-runtime" :worker json-identity
                               :parent parent :leaseFile (expand-file-name "lease.json" directory)
                               :state "pending")))
       (setq runtime (plist-put runtime :placement "worker")
             runtime (plist-put runtime :parent '(:host "emacs" :endpoint "test" :id "parent")))
       (with-temp-file pilish-runtime-task-status-executable
         (insert "#!/bin/sh\nexec cat " (shell-quote-argument task-file) "\n"))
       (set-file-modes pilish-runtime-task-status-executable #o700)
       (pilish-runtime-test--write-task task-file task-record)
       ,@body)))

(ert-deftest pilish-runtime-test-prompt-refused-before-live ()
  (pilish-runtime-test--with-peer '(:no-live t)
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "prelive"))
    (pilish--runtime-connect pilish-runtime-test--chat runtime #'ignore)
    (pilish-runtime-test--wait
     (lambda () (process-get (pilish-session-process pilish-runtime-test--chat) 'pilish-mux-snapshot)))
    (should-error
     (pilish--rpc-async (pilish-session-process pilish-runtime-test--chat)
                       '(:type "prompt" :message "never send") #'ignore)
     :type 'user-error)
    (should-not pilish-runtime-test--received)))

(ert-deftest pilish-runtime-test-protocol-one-refuses-not-relaunches ()
  (pilish-runtime-test--with-peer '(:protocol 1)
    (let (called)
      (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "old-peer"))
      (pilish--runtime-connect pilish-runtime-test--chat runtime
                               (lambda (error) (push error called)))
      (pilish-runtime-test--wait (lambda () called))
      (should (= (length called) 1))
      (should (stringp (car called)))
      (should-not (process-live-p (pilish-session-process pilish-runtime-test--chat))))))

(ert-deftest pilish-runtime-test-uncontextual-protocol-two-refuses-not-downgrades ()
  (pilish-runtime-test--with-peer '(:no-context-capability t)
    (let (called)
      (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "unguarded-owner"))
      (pilish--runtime-connect pilish-runtime-test--chat runtime
                               (lambda (error) (push error called)))
      (pilish-runtime-test--wait (lambda () called))
      (should (stringp (car called)))
      (should-not (process-live-p (pilish-session-process pilish-runtime-test--chat)))
      (should-not pilish-runtime-test--received))))

(ert-deftest pilish-runtime-test-exact-pi-start-identity-required ()
  (pilish-runtime-test--with-peer nil
    (let (called)
      (setq runtime (plist-put runtime :pi-start-time "not-the-recorded-process"))
      (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "wrong-owner"))
      (pilish--runtime-connect pilish-runtime-test--chat runtime
                               (lambda (error) (push error called)))
      (pilish-runtime-test--wait (lambda () called))
      (should (stringp (car called)))
      (should-not pilish-runtime-test--received))))

(ert-deftest pilish-runtime-test-unprivate-socket-refused ()
  (pilish-runtime-test--with-peer nil
    (let (outcomes)
      (set-file-modes directory #o755)
      (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "unsafe-owner"))
      (pilish--runtime-connect pilish-runtime-test--chat runtime
                               (lambda (error) (push error outcomes)))
      (should (= (length outcomes) 1))
      (should (stringp (car outcomes)))
      (should-not (pilish-session-process pilish-runtime-test--chat))
      (should-not pilish-runtime-test--clients)
      (should-not pilish-runtime-test--received))))

(ert-deftest pilish-runtime-test-restore-adopts-authoritative-file ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat
            (pilish-restore-session-state
             (list :directory directory :name "restore" :session-file "/old/s.jsonl"
                   :runtime runtime :draft "old context" :leaf-id "old-branch"
                   :context '(:session-file "/old/s.jsonl" :leaf-id "old-branch"))))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (should (equal (pilish-session-file pilish-runtime-test--chat) file))
      (should (equal (plist-get (car (pilish-session-quarantine pilish-runtime-test--chat)) :draft)
                     "old context"))
      (should-not (string-match-p "\\\"type\\\":\\\"prompt\\\""
                                  (mapconcat #'identity pilish-runtime-test--received ""))))))

(ert-deftest pilish-runtime-test-identity-free-desktop-is-stopped-and-resumable ()
  (pilish-runtime-test--with-peer '(:silent t)
    (cl-letf (((symbol-function 'pilish-list-runtimes)
               (lambda () (ert-fail "Identity-free restoration needs no discovery")))
              ((symbol-function 'pilish--runtime-call)
               (lambda (&rest _) (ert-fail "Restoration must not start Pi"))))
      (setq pilish-runtime-test--chat
            (pilish-restore-session-state
             (list :directory directory :name "legacy" :session-file file
                   :leaf-id "saved-leaf" :runtime nil :draft "kept legacy draft")))
      (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "stopped"))
      (should-not (plist-get (pilish-session-runtime pilish-runtime-test--chat) :mux-id))
      (should (equal (pilish-session-file pilish-runtime-test--chat) file))
      (should (equal (plist-get (pilish-session-desktop-state pilish-runtime-test--chat) :leaf-id) "saved-leaf"))
      (should (equal (plist-get (pilish-session-desktop-state pilish-runtime-test--chat) :draft) "kept legacy draft"))
      (should-not (pilish-session-process pilish-runtime-test--chat)))))

(ert-deftest pilish-runtime-test-reconcile-identity-free-unavailable-view-in-place ()
  (pilish-runtime-test--with-peer '(:silent t)
    (setq pilish-runtime-test--chat
          (pilish-restore-session-state
           (list :directory directory :name "legacy-repair" :session-file file
                 :runtime nil :draft "preserve in place")))
    (with-current-buffer pilish-runtime-test--chat
      (setq pilish--runtime '(:protocol 2 :state "unavailable")))
    (let ((before (pilish-session-desktop-state pilish-runtime-test--chat)) called)
      (cl-letf (((symbol-function 'pilish-list-runtimes)
                 (lambda () (ert-fail "No owner identity to discover")))
                ((symbol-function 'pilish--runtime-call)
                 (lambda (&rest _) (ert-fail "No implicit launch"))))
        (pilish-reconnect-runtime pilish-runtime-test--chat (lambda (error) (push error called))))
      (should (= (length called) 1))
      (should (string-match-p "Resume stopped conversation" (car called)))
      (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "stopped"))
      (should (equal (pilish-session-file pilish-runtime-test--chat) (plist-get before :session-file)))
      (should (equal (plist-get (pilish-session-desktop-state pilish-runtime-test--chat) :draft)
                     (plist-get before :draft)))
      (should-not (pilish-session-process pilish-runtime-test--chat)))))

(ert-deftest pilish-runtime-test-identity-free-close-retires-view-and-retains-draft ()
  "Stopped and failed-launch (unavailable) views without identity retire."
  (dolist (state '("stopped" "unavailable"))
    (pilish-runtime-test--with-peer '(:silent t)
      (cl-letf (((symbol-function 'pilish-list-runtimes)
                 (lambda () (ert-fail "Identity-free Close needs no discovery")))
                ((symbol-function 'pilish--runtime-call)
                 (lambda (&rest _) (ert-fail "Identity-free Close has no runtime to control"))))
        (setq pilish-runtime-test--chat
              (pilish-restore-session-state
               (list :directory directory :name "identity-free-close" :session-file nil
                     :runtime '(:protocol 2 :state "stopped" :session-file nil)
                     :draft "identity-free close keeps this draft")))
        ;; A launch refused before commitment leaves exactly this state.
        (with-current-buffer pilish-runtime-test--chat
          (setq pilish--runtime (plist-put pilish--runtime :state state)))
        (let* ((chat pilish-runtime-test--chat)
               (input (pilish-session-input-buffer chat))
               observed outcomes
               (pilish-session-closed-functions
                (list (lambda (buffer)
                        (should (buffer-live-p input))
                        (push buffer observed)))))
          (should (equal (plist-get (pilish-session-runtime chat) :state) state))
          (pilish-close-session chat (lambda (error) (push error outcomes)))
          (should (equal outcomes '(nil)))
          (should (equal observed (list chat)))
          (should-not (buffer-live-p chat))
          (should-not (buffer-live-p input))
          (with-current-buffer "*Pilish closed agents*"
            (should (string-match-p "identity-free close keeps this draft" (buffer-string)))))))))

(ert-deftest pilish-runtime-test-missing-restore-retains-draft-never-spawns ()
  (pilish-runtime-test--with-peer '(:silent t)
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () nil))
              ((symbol-function 'pilish--runtime-call) (lambda (&rest _) (ert-fail "Unexpected launch"))))
      (setq pilish-runtime-test--chat
            (pilish-restore-session-state
             (list :directory directory :name "missing" :runtime runtime :session-file file
                   :draft "kept" :followups '("suspended not sent"))))
      (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "unavailable"))
      (should-not (pilish-session-process pilish-runtime-test--chat))
      (should (equal (plist-get (pilish-session-desktop-state pilish-runtime-test--chat) :draft) "kept"))
      (should (pilish-session-quarantine pilish-runtime-test--chat)))))

(ert-deftest pilish-runtime-test-service-restoration-resolves-successor-without-launch-or-input ()
  (pilish-runtime-test--with-peer nil
    (setq runtime (plist-put runtime :service
                             (list :pid (emacs-pid) :startTime "service-start" :bootId "service-boot")))
    (let ((previous (pilish-runtime-test--previous-boot runtime)) calls)
      (cl-letf (((symbol-function 'pilish--runtime-call)
                 (lambda (args _cwd _environment callback)
                   (push (car args) calls)
                   (pcase (car args)
                     ("resolve"
                      (should (equal args '("resolve" "--json" "--id" "previous-boot")))
                      (funcall callback
                               (list :protocol 2 :state "committed" :outcome "attached"
                                     :muxId "test-runtime" :pid (emacs-pid) :piPid (emacs-pid)
                                     :service (plist-get runtime :service) :socket socket :sessionFile file) nil))
                     ("list" (funcall callback (vector (pilish-runtime-test--discovery runtime)) nil))
                     (_ (ert-fail "Frontend attempted a restoration launch")))
                   nil)))
        (setq pilish-runtime-test--chat
              (pilish-restore-session-state
               (list :directory directory :name "service-recovery" :runtime previous
                     :session-file file :draft "retained draft" :followups '("suspended follow-up")))))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (should (equal (reverse calls) '("resolve" "list")))
      (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :mux-id) "test-runtime"))
      (should-not (pilish-session-queued-prompts pilish-runtime-test--chat))
      (should (string-match-p "retained draft"
                              (prin1-to-string (pilish-session-desktop-state pilish-runtime-test--chat))))
      (should-not (string-match-p "\\\"type\\\":\\\"prompt\\\""
                                  (mapconcat #'identity pilish-runtime-test--received ""))))))

(ert-deftest pilish-runtime-test-service-unavailable-keeps-view-despite-old-terminal-receipt ()
  (pilish-runtime-test--with-peer '(:silent t)
    (setq runtime (plist-put runtime :service '(:pid 1 :startTime "service" :bootId "boot"))
          runtime (plist-put runtime :exit '(:code 0)))
    (cl-letf (((symbol-function 'pilish--runtime-call)
               (lambda (args _cwd _environment callback)
                 (should (equal (car args) "resolve"))
                 (funcall callback nil "pimux unavailable; run `sv up pimux` and retry") nil))
              ((symbol-function 'pilish--runtime-terminal-receipt)
               (lambda (_) '(:muxId "test-runtime" :state "stopped" :rootClosed :false))))
      (setq pilish-runtime-test--chat
            (pilish-restore-session-state
             (list :directory directory :runtime runtime :session-file file :draft "keep work"))))
    (should (buffer-live-p pilish-runtime-test--chat))
    (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "unavailable"))
    (should (equal (plist-get (pilish-session-desktop-state pilish-runtime-test--chat) :draft) "keep work"))))

(ert-deftest pilish-runtime-test-service-close-retires-only-after-no-successor-and-terminal-evidence ()
  (pilish-runtime-test--with-peer '(:silent t)
    (setq runtime (plist-put runtime :service '(:pid 1 :startTime "service" :bootId "boot")))
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "closed-service"))
    (with-current-buffer pilish-runtime-test--chat (setq pilish--runtime runtime))
    (let (outcomes)
      (cl-letf (((symbol-function 'pilish--runtime-call)
                 (lambda (args _cwd _environment callback)
                   (should (equal (car args) "resolve"))
                   (funcall callback :null nil) nil))
                ((symbol-function 'pilish--runtime-terminal-receipt)
                 (lambda (_) '(:muxId "test-runtime" :state "stopped"))))
        (pilish-reconnect-runtime pilish-runtime-test--chat (lambda (error) (push error outcomes))))
      (should (= (length outcomes) 1))
      (should (string-match-p "closed view removed" (car outcomes)))
      (should-not (buffer-live-p pilish-runtime-test--chat)))))

(ert-deftest pilish-runtime-test-prior-boot-unmanaged-root-is-not-launched-by-desktop ()
  (pilish-runtime-test--with-peer '(:silent t)
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () nil))
              ((symbol-function 'pilish--runtime-call)
               (lambda (&rest _) (ert-fail "Desktop must not launch an unmanaged root"))))
      (setq pilish-runtime-test--chat
            (pilish-restore-session-state
             (list :directory directory :runtime (pilish-runtime-test--previous-boot runtime)
                   :session-file file :draft "keep unmanaged history"))))
    (should (equal (pilish-session-file pilish-runtime-test--chat) file))
    (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "unavailable"))))

(ert-deftest pilish-runtime-test-discovery-reuses-one-local-view ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "one"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (should (eq pilish-runtime-test--chat (pilish-attach-runtime runtime "another-name")))
      (should (= (length pilish-runtime-test--clients) 1)))))

(ert-deftest pilish-runtime-test-start-discovers-asynchronously-and-keeps-worker-placement ()
  (pilish-runtime-test--with-peer nil
    (setq runtime (plist-put runtime :placement "worker")
          runtime (plist-put runtime :parent '(:host "emacs" :id "parent"))
          runtime (plist-put runtime :orchestration '(:taskId "task-one")))
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "task-view"))
    (let* (launch discovery outcomes calls desktop
           (pilish-session-desktop-state-functions
            (list (lambda (chat) (setq desktop (pilish-session-desktop-state chat))))))
      (cl-letf (((symbol-function 'pilish-list-runtimes)
                 (lambda () (ert-fail "Launch blocked on synchronous discovery")))
                ((symbol-function 'pilish--runtime-call)
                 (lambda (args cwd environment callback)
                   (should (equal cwd directory))
                   (should (equal environment '(("PIMUX_DIR" . "/fixture/mux"))))
                   (push (car args) calls)
                   (if (equal args '("list" "--json"))
                       (progn
                         (should (equal (plist-get (plist-get desktop :runtime) :mux-id)
                                        "test-runtime"))
                         (setq discovery callback))
                     (setq launch callback))
                   nil)))
        (pilish--runtime-start-view pilish-runtime-test--chat directory nil
                                    '(("PIMUX_DIR" . "/fixture/mux"))
                                    (lambda (error) (push error outcomes)))
        (should-not discovery)
        (funcall launch
                 (list :protocol 2 :state "committed" :outcome "started"
                       :muxId "test-runtime" :pid (emacs-pid) :piPid (emacs-pid)
                       :socket socket :sessionFile file) nil)
        (should discovery)
        (should-not outcomes)
        (should-not (pilish-session-process pilish-runtime-test--chat))
        (let ((pending (pilish-session-runtime pilish-runtime-test--chat)))
          (should (equal pending (plist-get desktop :runtime)))
          (should (equal (plist-get pending :state) "starting"))
          (should (equal (plist-get pending :placement) "unknown"))
          (dolist (key '(:mux-id :socket :pid :pi-pid :pi-start-time :pi-boot-id :session-file))
            (should (equal (plist-get pending key) (plist-get runtime key)))))
        (funcall discovery (vector (pilish-runtime-test--discovery runtime)) nil)
        (pilish-runtime-test--wait (lambda () outcomes))
        (should (equal outcomes '(nil)))
        (should (equal calls '("list" "start")))
        (let ((adopted (pilish-session-runtime pilish-runtime-test--chat)))
          (should (equal (plist-get adopted :state) "live"))
          (dolist (key '(:placement :parent :orchestration))
            (should (equal (plist-get adopted key) (plist-get runtime key)))))
        (let (failure)
          (pilish-stop-runtime pilish-runtime-test--chat (lambda (error) (setq failure error)))
          (should (string-match-p "parent" failure)))))))

(ert-deftest pilish-runtime-test-start-discovery-failure-retains-committed-identity-once ()
  (dolist (failure '(transport malformed missing mux pid socket dispatch))
    (pilish-runtime-test--with-peer nil
      (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "failed-discovery"))
      (let (launch discovery outcomes)
        (cl-letf (((symbol-function 'pilish-list-runtimes)
                   (lambda () (ert-fail "Unexpected synchronous discovery")))
                  ((symbol-function 'pilish--runtime-call)
                   (lambda (args _directory _environment callback)
                     (if (equal args '("list" "--json"))
                         (if (eq failure 'dispatch) (error "Cannot dispatch discovery")
                           (setq discovery callback))
                       (setq launch callback))
                     nil)))
          (pilish--runtime-start-view pilish-runtime-test--chat directory nil nil
                                      (lambda (error) (push error outcomes)))
          (funcall launch
                   (list :protocol 2 :state "committed" :outcome "started"
                         :muxId "test-runtime" :pid (emacs-pid) :piPid (emacs-pid)
                         :socket socket :sessionFile file) nil)
          (unless (eq failure 'dispatch)
            (let* ((record (pilish-runtime-test--discovery runtime))
                   (records
                    (pcase failure
                      ('malformed '(:not "an array"))
                      ('missing [])
                      ('mux (vector (plist-put record :muxId "another-runtime")))
                      ('pid (vector (plist-put record :piPid 1)))
                      ('socket (vector (plist-put record :socket "/another.sock")))
                      (_ (vector record)))))
              (funcall discovery records (and (eq failure 'transport) "Discovery failed"))
              (funcall discovery records (and (eq failure 'transport) "Discovery failed"))))
          (should (= (length outcomes) 1))
          (should (stringp (car outcomes)))
          (should-not (pilish-session-process pilish-runtime-test--chat))
          (let ((retained (pilish-session-runtime pilish-runtime-test--chat)))
            (should (equal (plist-get retained :state) "unavailable"))
            (should (equal (plist-get retained :placement) "unknown"))
            (should (equal (plist-get retained :mux-id) "test-runtime"))
            (should (equal (plist-get retained :socket) socket))))))))

(ert-deftest pilish-runtime-test-stop-and-close-refuse-unconfirmed-placement ()
  (pilish-runtime-test--with-peer nil
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "pending-stop"))
    (let (launch discovery calls startup-outcomes)
      (cl-letf (((symbol-function 'pilish--runtime-call)
                 (lambda (args _directory _environment callback)
                   (push (car args) calls)
                   (pcase (car args)
                     ("start" (setq launch callback))
                     ("list" (setq discovery callback))
                     (_ (ert-fail "Unconfirmed placement dispatched runtime control")))
                   nil)))
        (pilish--runtime-start-view pilish-runtime-test--chat directory nil nil
                                    (lambda (error) (push error startup-outcomes)))
        (funcall launch
                 (list :protocol 2 :state "committed" :outcome "started"
                       :muxId "test-runtime" :pid (emacs-pid) :piPid (emacs-pid)
                       :socket socket :sessionFile file) nil)
        (dolist (stage '(pending failed))
          (when (eq stage 'failed) (funcall discovery nil "Discovery failed"))
          (let ((retained (pilish-session-runtime pilish-runtime-test--chat)))
            (dolist (action '(pilish-stop-runtime pilish-close-session))
              (let (outcomes)
                (funcall action pilish-runtime-test--chat (lambda (error) (push error outcomes)))
                (should (= (length outcomes) 1))
                (should (string-match-p "not confirmed root" (car outcomes)))
                (should (buffer-live-p pilish-runtime-test--chat))
                (should (equal retained (pilish-session-runtime pilish-runtime-test--chat))))))
          (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :mux-id)
                         "test-runtime"))
          (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :placement)
                         "unknown")))
        (should (equal startup-outcomes '("Discovery failed")))
        (should (equal calls '("list" "start")))))))

(ert-deftest pilish-runtime-test-disconnect-cancels-pending-post-commit-discovery ()
  (pilish-runtime-test--with-peer nil
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "cancel-discovery"))
    (let (launch discovery-process outcomes)
      (cl-letf (((symbol-function 'pilish--runtime-call)
                 (lambda (args _directory _environment callback)
                   (if (equal args '("list" "--json"))
                       (setq discovery-process
                             (make-pipe-process
                              :name "pilish-discovery-fixture" :noquery t
                              :sentinel (lambda (_process _event)
                                          (funcall callback nil "Discovery cancelled"))))
                     (setq launch callback)
                     nil))))
        (pilish--runtime-start-view pilish-runtime-test--chat directory nil nil
                                    (lambda (error) (push error outcomes)))
        (funcall launch
                 (list :protocol 2 :state "committed" :outcome "started"
                       :muxId "test-runtime" :pid (emacs-pid) :piPid (emacs-pid)
                       :socket socket :sessionFile file) nil)
        (should (process-live-p discovery-process))
        (with-current-buffer pilish-runtime-test--chat
          (should (eq pilish--runtime-launcher discovery-process))
          (pilish--runtime-kill-view))
        (should-not (process-live-p discovery-process))
        (should (equal outcomes '("Discovery cancelled")))
        (should-not (pilish-session-process pilish-runtime-test--chat))
        (should (process-live-p server))))))

(ert-deftest pilish-runtime-test-unavailable-view-is-never-implicitly-started ()
  (pilish-runtime-test--with-peer '(:silent t)
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "unavailable"))
    (with-current-buffer pilish-runtime-test--chat
      (setq pilish--runtime (plist-put runtime :state "unavailable")))
    (cl-letf (((symbol-function 'pilish--runtime-start-view)
               (lambda (&rest _) (ert-fail "Implicit runtime replacement"))))
      (should (eq pilish-runtime-test--chat
                  (pilish--setup-session (file-name-as-directory directory) "unavailable"))))))

(ert-deftest pilish-runtime-test-configuration-rejects-unsafe-runtime-inputs ()
  (should-error (pilish-configure-runtime :protocol 1))
  (should-error (pilish-configure-runtime :pi-executable "pi" :pimux-executable "pimux"))
  (let ((program (executable-find "true")))
    (should-error (pilish-configure-runtime :pi-executable program :pimux-executable program
                                            :task-status-executable "relative-cli"))))

(ert-deftest pilish-runtime-test-native-mode-does-not-acquire-network-gate ()
  (let ((process (make-pipe-process :name "native-fixture" :noquery t)) sent)
    (unwind-protect
        (cl-letf (((symbol-function 'pilish--send-string) (lambda (_process string) (setq sent string))))
          (pilish--rpc-async process '(:type "prompt" :message "ordinary") #'ignore)
          (should (string-match-p "ordinary" sent)))
      (delete-process process))))

(ert-deftest pilish-runtime-test-independent-stop-and-close-await-receipt-before-disposal ()
  (dolist (placement '("root" "interactive-fork"))
    (dolist (action '(pilish-stop-runtime pilish-close-session))
      (pilish-runtime-test--with-peer nil
        (setq runtime (plist-put runtime :placement placement)
              pilish-runtime-test--chat (pilish--runtime-new-view directory "close"))
        (let* ((chat pilish-runtime-test--chat)
               (input (pilish-session-input-buffer chat))
               (pilish-session-closed-functions
                (list (lambda (buffer)
                        (should (eq buffer chat))
                        (should (buffer-live-p input))
                        (should (equal (plist-get (pilish-session-runtime buffer) :state) "stopped")))))
               control outcomes)
          (with-current-buffer chat (setq pilish--runtime runtime))
          (cl-letf (((symbol-function 'pilish--runtime-call)
                     (lambda (args _directory _env callback)
                       (should (equal args '("stop" "--json" "--id" "test-runtime")))
                       (setq control callback)))
                    ((symbol-function 'yes-or-no-p) (lambda (_) (ert-fail "Stop/Close asked"))))
            (funcall action
                     chat (lambda (error)
                            (should-not (buffer-live-p chat))
                            (push error outcomes)))
            (should control)
            (should (buffer-live-p chat))
            (should-not outcomes)
            (funcall control '(:muxId "test-runtime" :state "stopped") nil)
            (should-not (buffer-live-p chat))
            (should-not (buffer-live-p input))
            (should (equal outcomes '(nil)))))))))

(ert-deftest pilish-runtime-test-peer-termination-retires-view-without-stop ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime)))
              ((symbol-function 'pilish--runtime-call)
               (lambda (&rest _) (ert-fail "Remote termination issued another control"))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "remote-close"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (let ((input (pilish-session-input-buffer pilish-runtime-test--chat))
            (pilish-session-closed-functions nil))
        (with-current-buffer input (insert "recover this draft"))
        (process-send-string
         (car pilish-runtime-test--clients)
         (pilish--encode-command '(:type "pimux_exit" :code 1 :signal :null :stderrTail "faux crash")))
        (pilish-runtime-test--wait (lambda () (not (buffer-live-p pilish-runtime-test--chat))))
        (should-not (buffer-live-p input))
        (with-current-buffer "*Pilish closed agents*"
          (should buffer-read-only)
          (should (string-match-p "recover this draft" (buffer-string)))
          (should (string-match-p "faux crash" (buffer-string))))))))

(ert-deftest pilish-runtime-test-worker-close-waits-for-final-task-not-runtime-exit ()
  (pilish-runtime-test--with-worker '(:commands [(:name "worker-cancel" :source "extension")])
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "worker-close"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (let ((chat pilish-runtime-test--chat) outcomes sent)
        (cl-letf (((symbol-function 'pilish-submit-prompt)
                   (lambda (buffer text callback &optional behavior context)
                     (should-not behavior)
                     (should (eq buffer chat))
                     (should (equal text "/worker-cancel"))
                     (should context)
                     (setq sent t)
                     (funcall callback '(:success t))))
                  ((symbol-function 'pilish-stop-runtime)
                   (lambda (&rest _) (ert-fail "Worker was stopped as a root"))))
          (pilish-close-session chat (lambda (error) (push error outcomes)))
          (pilish-runtime-test--wait (lambda () sent))
          (should (buffer-live-p chat))
          (should-not outcomes)
          (pilish--runtime-note-exit (pilish-session-process chat) '(:type "pimux_exit" :code 0))
          (should (buffer-live-p chat))
          (should-not outcomes)
          (setq task-record (plist-put task-record :state "complete"))
          (pilish-runtime-test--write-task task-file task-record)
          (pilish-runtime-test--wait (lambda () outcomes))
          (should-not (buffer-live-p chat))
          (should (equal outcomes '(nil))))))))

(ert-deftest pilish-runtime-test-local-disconnect-is-not-agent-close ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime)))
              ((symbol-function 'pilish-stop-runtime)
               (lambda (&rest _) (ert-fail "Disconnect stopped the agent"))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "local-disconnect"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (let ((notified nil)
            (pilish-session-closed-functions (list (lambda (_) (setq notified t)))))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (ert-fail "Disconnect asked"))))
          (should (pilish--session-kill-emacs-query))
          (pilish-disconnect-session pilish-runtime-test--chat))
        (should-not (buffer-live-p pilish-runtime-test--chat))
        (should (process-live-p server))
        (should-not notified)))))

(ert-deftest pilish-runtime-test-offline-close-reconciles-read-only-receipt ()
  (let ((pilish-runtime-mode 'detached)
        (pilish-runtime-pimux-executable "/fake/pimux")
        (state '(:directory "/tmp/" :runtime (:protocol 2 :mux-id "offline" :state "live"))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (program _input _destination _display &rest args)
                 (should (equal program "/fake/pimux"))
                 (should (equal args '("receipt" "--json" "--id" "offline")))
                 (insert "{\"muxId\":\"offline\",\"state\":\"stopped\"}")
                 0))
              ((symbol-function 'pilish--runtime-new-view)
               (lambda (&rest _) (ert-fail "Restored an offline-closed identity"))))
      (should-not (pilish-restore-session-state state)))))

(ert-deftest pilish-runtime-test-simultaneous-close-coalesces-and-failure-is-recoverable ()
  (pilish-runtime-test--with-peer nil
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "coalesced-close"))
    (let ((chat pilish-runtime-test--chat) control (calls 0) outcomes)
      (with-current-buffer chat (setq pilish--runtime runtime))
      (cl-letf (((symbol-function 'pilish--runtime-call)
                 (lambda (_args _directory _env callback)
                   (cl-incf calls) (setq control callback))))
        (pilish-close-session chat (lambda (error) (push error outcomes)))
        (pilish-close-session chat (lambda (error) (push error outcomes)))
        (should (= calls 1))
        (funcall control nil "Exit uncertain")
        (should (equal outcomes '("Exit uncertain" "Exit uncertain")))
        (should (buffer-live-p chat))
        (setq outcomes nil)
        (pilish-close-session chat (lambda (error) (push error outcomes)))
        (should (= calls 2))
        (funcall control '(:muxId "test-runtime" :state "stopped") nil)
        (should (equal outcomes '(nil)))
        (should-not (buffer-live-p chat))))))

(ert-deftest pilish-runtime-test-old-receipt-never-retires-replacement-view ()
  (pilish-runtime-test--with-peer nil
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "replacement-close"))
    (let ((chat pilish-runtime-test--chat) control outcome)
      (with-current-buffer chat (setq pilish--runtime runtime))
      (cl-letf (((symbol-function 'pilish--runtime-call)
                 (lambda (_args _directory _env callback) (setq control callback))))
        (pilish-close-session chat (lambda (error) (setq outcome error)))
        (with-current-buffer chat
          (setq pilish--runtime '(:protocol 2 :mux-id "replacement" :state "live")))
        (funcall control '(:muxId "test-runtime" :state "stopped") nil)
        (should (string-match-p "another runtime" outcome))
        (should (buffer-live-p chat))
        (should (equal (plist-get (pilish-session-runtime chat) :state) "live"))))))

(ert-deftest pilish-runtime-test-worker-disconnect-retains-uncertain-close-and-draft ()
  (pilish-runtime-test--with-worker '(:commands [(:name "worker-cancel" :source "extension")])
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "worker-loss"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (let ((chat pilish-runtime-test--chat) outcomes sent)
        (with-current-buffer (pilish-session-input-buffer chat) (insert "keep uncertain draft"))
        (cl-letf (((symbol-function 'pilish-submit-prompt)
                   (lambda (_buffer _text callback &optional _behavior _context)
                     (setq sent t)
                     (funcall callback '(:success t)))))
          (pilish-close-session chat (lambda (error) (push error outcomes)))
          (pilish-runtime-test--wait (lambda () sent))
          (delete-process (pilish-session-process chat))
          (should (buffer-live-p chat))
          (should-not outcomes)
          (pilish--runtime-task-error chat "Worker task cleanup timed out; outcome uncertain, view retained")
          (should (= (length outcomes) 1))
          (should (string-match-p "uncertain" (car outcomes)))
          (should (equal (plist-get (pilish-session-runtime chat) :state) "disconnected"))
          (should (string-match-p "keep uncertain draft"
                                  (prin1-to-string (pilish-session-desktop-state chat)))))))))

(ert-deftest pilish-runtime-test-authoritative-retirement-settles-through-observer-and-cleanup-errors ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "retire-errors"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (let* ((chat pilish-runtime-test--chat)
             (input (pilish-session-input-buffer chat))
             (transport (pilish-session-process chat))
             (timer (run-at-time 100 nil #'ignore))
             (ready-count 0) (observer-count 0) (chat-kills 0) (input-kills 0)
             (callback-count 0) (dispatch-count 0) outcomes warnings control
             (pilish-session-closed-functions
              (list (lambda (buffer)
                      (should (eq buffer chat))
                      (should (buffer-live-p (pilish-session-input-buffer buffer)))
                      (should (equal (plist-get (pilish-session-desktop-state buffer) :directory)
                                     (file-name-as-directory directory)))
                      (cl-incf observer-count)
                      (pilish-stop-runtime buffer (lambda (error) (push error outcomes)))
                      (error "observer exploded"))
                    (lambda (_buffer) (cl-incf observer-count)))))
        (with-current-buffer chat
          (setq pilish--runtime-close-timer timer
                pilish--runtime-ready-callback
                (lambda (_error) (cl-incf ready-count) (error "readiness exploded")))
          (add-hook 'kill-buffer-hook
                    (lambda () (cl-incf chat-kills) (error "chat cleanup exploded")) nil t))
        (with-current-buffer input
          (insert "retirement recovery draft")
          (add-hook 'kill-buffer-hook
                    (lambda () (cl-incf input-kills) (error "input cleanup exploded")) nil t))
        (cl-letf (((symbol-function 'pilish--runtime-call)
                   (lambda (_args _directory _env callback)
                     (cl-incf dispatch-count) (setq control callback)))
                  ((symbol-function 'display-warning)
                   (lambda (_type text &rest _) (push text warnings))))
          (pilish-close-session chat (lambda (error) (push error outcomes)))
          (pilish-close-session chat (lambda (_error)
                                       (cl-incf callback-count) (error "callback exploded")))
          (pilish--runtime-note-exit transport '(:type "pimux_exit" :code 0))
          (funcall control '(:muxId "test-runtime" :state "stopped") nil)
          (pilish--runtime-note-exit transport '(:type "pimux_exit" :code 0)))
        (should (= dispatch-count 1))
        (should (= observer-count 2))
        (should (= ready-count 1))
        (should (= callback-count 1))
        (should (= chat-kills 1))
        (should (= input-kills 1))
        (should (= (length outcomes) 2))
        (dolist (error outcomes)
          (should (string-match-p "observer exploded" error))
          (should (string-match-p "chat cleanup exploded" error))
          (should (string-match-p "input cleanup exploded" error)))
        (should-not (buffer-live-p chat))
        (should-not (buffer-live-p input))
        (should-not (process-live-p transport))
        (should-not (memq timer timer-list))
        (dolist (text '("observer exploded" "readiness exploded" "chat cleanup exploded"
                        "input cleanup exploded" "callback exploded"))
          (should (string-match-p text (car warnings)))
          (with-current-buffer "*Pilish closed agents*"
            (should (string-match-p text (buffer-string)))))
        (with-current-buffer "*Pilish closed agents*"
          (should (string-match-p "retirement recovery draft" (buffer-string))))))))

(ert-deftest pilish-runtime-test-late-stop-receipt-preserves-remote-retirement-error ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "late-close-error"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (let ((chat pilish-runtime-test--chat)
            (pilish-session-closed-functions (list (lambda (_) (error "remote observer failure"))))
            control outcomes)
        (cl-letf (((symbol-function 'pilish--runtime-call)
                   (lambda (_args _directory _env callback) (setq control callback)))
                  ((symbol-function 'display-warning) #'ignore))
          (pilish-stop-runtime chat (lambda (error) (push error outcomes)))
          (pilish--runtime-note-exit (pilish-session-process chat) '(:type "pimux_exit" :code 0))
          (should-not (buffer-live-p chat))
          (funcall control '(:muxId "test-runtime" :state "stopped") nil)
          (funcall control '(:muxId "test-runtime" :state "stopped") nil))
        (should (= (length outcomes) 1))
        (should (string-match-p "remote observer failure" (car outcomes)))))))

(ert-deftest pilish-runtime-test-uncertain-stop-settles-all-callbacks-without-disposal ()
  (pilish-runtime-test--with-peer nil
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "uncertain-errors"))
    (let ((chat pilish-runtime-test--chat) control outcomes warnings)
      (with-current-buffer chat (setq pilish--runtime runtime))
      (cl-letf (((symbol-function 'pilish--runtime-call)
                 (lambda (_args _directory _env callback) (setq control callback)))
                ((symbol-function 'display-warning)
                 (lambda (_type text &rest _) (push text warnings))))
        (pilish-close-session chat (lambda (error) (push error outcomes)))
        (pilish-close-session chat (lambda (_) (error "failure callback exploded")))
        (funcall control nil "Stop delivery uncertain"))
      (should (equal outcomes '("Stop delivery uncertain")))
      (should (buffer-live-p chat))
      (should (buffer-live-p (pilish-session-input-buffer chat)))
      (should (string-match-p "Stop delivery uncertain" (car warnings)))
      (should (string-match-p "failure callback exploded" (car warnings))))))

(ert-deftest pilish-runtime-test-worker-close-refuses-missing-or-nonextension-command ()
  (dolist (commands (list [] [(:name "worker-cancel" :source "prompt")]
                         [(:name "worker-cancel" :source "skill")]))
    (pilish-runtime-test--with-worker (list :commands commands)
      (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
        (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "missing-cancel"))
        (pilish-runtime-test--wait
         (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
        (let ((chat pilish-runtime-test--chat) outcomes)
          (with-current-buffer (pilish-session-input-buffer chat) (insert "never infer from close"))
          (cl-letf (((symbol-function 'pilish-submit-prompt)
                     (lambda (&rest _) (ert-fail "Unadvertised slash text reached inference"))))
            (pilish-close-session chat (lambda (error) (push error outcomes)))
            (pilish-runtime-test--wait (lambda () outcomes)))
          (should (= (length outcomes) 1))
          (should (string-match-p "does not advertise" (car outcomes)))
          (should (buffer-live-p chat))
          (should (equal (plist-get (pilish-session-desktop-state chat) :draft) "never infer from close"))
          (should-not (string-match-p "worker-cancel"
                                      (mapconcat #'identity pilish-runtime-test--received ""))))))))

(ert-deftest pilish-runtime-test-worker-command-discovery-cannot-dispatch-after-context-change-or-timeout ()
  (dolist (change '(context timeout))
    (pilish-runtime-test--with-worker nil
      (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
        (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "late-cancel"))
        (pilish-runtime-test--wait
         (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
        (let ((chat pilish-runtime-test--chat) catalog outcomes)
          (cl-letf (((symbol-function 'pilish--rpc-async)
                     (lambda (_transport command callback)
                       (should (equal command '(:type "get_commands")))
                       (setq catalog callback)))
                    ((symbol-function 'pilish-submit-prompt)
                     (lambda (&rest _) (ert-fail "Stale admission submitted a prompt"))))
            (pilish-close-session chat (lambda (error) (push error outcomes)))
            (if (eq change 'timeout)
                (pilish--runtime-finish-close chat "Close timed out")
              (process-put (pilish-session-process chat) 'pilish-input-context
                           (list :sessionFile file :leafId :null :contextId "changed")))
            (funcall catalog '(:success t :data (:commands [(:name "worker-cancel" :source "extension")])))
            (should (= (length outcomes) 1))
            (should (stringp (car outcomes)))
            (should (buffer-live-p chat))))))))

(ert-deftest pilish-runtime-test-reconnect-reconciles-only-exact-terminal-receipt ()
  (dolist (json '("null" "{\"muxId\":\"different-runtime\",\"state\":\"stopped\"}"
                  "{\"muxId\":\"test-runtime\",\"state\":\"stopped\"}"))
    (pilish-runtime-test--with-peer '(:silent t)
      (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "reconcile-close"))
      (let ((chat pilish-runtime-test--chat) outcomes (queries 0))
        (with-current-buffer chat (setq pilish--runtime (plist-put runtime :state "disconnected")))
        (with-current-buffer (pilish-session-input-buffer chat) (insert "offline recovery"))
        (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () nil))
                  ((symbol-function 'pilish--runtime-call)
                   (lambda (&rest _) (ert-fail "Read-only reconciliation sent control")))
                  ((symbol-function 'process-file)
                   (lambda (_program _input _destination _display &rest args)
                     (should (equal args '("receipt" "--json" "--id" "test-runtime")))
                     (cl-incf queries) (insert json) 0)))
          (pilish-reconnect-runtime chat (lambda (error) (push error outcomes))))
        (should (= queries 1))
        (should (= (length outcomes) 1))
        (if (string-match-p "different-runtime\\|null" json)
            (progn
              (should (buffer-live-p chat))
              (should (equal (plist-get (pilish-session-runtime chat) :state) "unavailable")))
          (should-not (buffer-live-p chat))
          (should (string-match-p "closed view removed" (car outcomes)))
          (with-current-buffer "*Pilish closed agents*"
            (should (string-match-p "offline recovery" (buffer-string)))))))))

(ert-deftest pilish-runtime-test-reconnect-does-not-retire-a-replacement-during-receipt-query ()
  (pilish-runtime-test--with-peer '(:silent t)
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "receipt-replacement"))
    (let ((chat pilish-runtime-test--chat) outcome)
      (with-current-buffer chat (setq pilish--runtime (plist-put runtime :state "disconnected")))
      (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () nil))
                ((symbol-function 'process-file)
                 (lambda (&rest _)
                   (with-current-buffer chat
                     (setq pilish--runtime '(:protocol 2 :mux-id "replacement" :state "live")))
                   (insert "{\"muxId\":\"test-runtime\",\"state\":\"stopped\"}") 0)))
        (pilish-reconnect-runtime chat (lambda (error) (setq outcome error))))
      (should (stringp outcome))
      (should (buffer-live-p chat))
      (should (equal (plist-get (pilish-session-runtime chat) :state) "live")))))

(provide 'pilish-runtime-test)
;;; pilish-runtime-test.el ends here
