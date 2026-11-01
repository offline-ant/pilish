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
            :filter (lambda (_process chunk) (push chunk pilish-runtime-test--received))
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
                            :socket socket :capabilities ["snapshot" "stop" "detached"])
                      (list :type "pimux_snapshot" :generation 1 :reason "attach" :replay 0
                            :session (list :file file :id "s1" :name :null :cwd directory)
                            :model (list :provider "faux" :id "faux")
                            :thinkingLevel "off" :idle t :leafId :null
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

(ert-deftest pilish-runtime-test-valid-peer-is-a-network-client ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "runtime-test"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (let ((process (pilish-session-process pilish-runtime-test--chat)))
        (should (eq (process-type process) 'network))
        (should-not (integerp (process-id process)))
        (should (= (plist-get (pilish-session-process-identity pilish-runtime-test--chat) :pid)
                   (emacs-pid)))
        (should (equal (pilish-session-file pilish-runtime-test--chat) file))
        (should-not pilish-runtime-test--received)))))

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
    (should (equal (plist-get runtime :socket) socket))
    (set-file-modes directory #o755)
    (should-not (pilish--runtime-private-socket-p socket))))

(ert-deftest pilish-runtime-test-disconnect-never-stops-owner ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "disconnect"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (pilish--terminate-process (pilish-session-process pilish-runtime-test--chat))
      (should (process-live-p server))
      (should-not (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "stopped"))
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

(ert-deftest pilish-runtime-test-discovery-reuses-one-local-view ()
  (pilish-runtime-test--with-peer nil
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime))))
      (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "one"))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (should (eq pilish-runtime-test--chat (pilish-attach-runtime runtime "another-name")))
      (should (= (length pilish-runtime-test--clients) 1)))))

(ert-deftest pilish-runtime-test-callback-is-once-even-when-it-errors ()
  (let ((count 0))
    (let ((callback (pilish--runtime-once (lambda (_error) (cl-incf count) (error "callback failed")))))
      (should-error (funcall callback nil))
      (funcall callback "second")
      (should (= count 1)))))

(ert-deftest pilish-runtime-test-start-keeps-authoritative-worker-placement ()
  (pilish-runtime-test--with-peer nil
    (setq runtime (plist-put runtime :placement "worker"))
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "task-view"))
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime)))
              ((symbol-function 'pilish--runtime-call)
               (lambda (_args _directory _environment callback)
                 (funcall callback
                          (list :protocol 2 :state "committed" :outcome "started"
                                :muxId "test-runtime" :pid (emacs-pid) :piPid (emacs-pid)
                                :socket socket :sessionFile file) nil)
                 nil)))
      (pilish--runtime-start-view pilish-runtime-test--chat directory nil nil #'ignore)
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
      (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :placement) "worker"))
      (let (failure)
        (pilish-stop-runtime pilish-runtime-test--chat (lambda (error) (setq failure error)))
        (should (string-match-p "parent" failure))))))

(ert-deftest pilish-runtime-test-unavailable-view-is-never-implicitly-started ()
  (pilish-runtime-test--with-peer '(:silent t)
    (setq pilish-runtime-test--chat (pilish--runtime-new-view directory "unavailable"))
    (with-current-buffer pilish-runtime-test--chat
      (setq pilish--runtime (plist-put runtime :state "unavailable")))
    (cl-letf (((symbol-function 'pilish--runtime-start-view)
               (lambda (&rest _) (ert-fail "Implicit runtime replacement"))))
      (should (eq pilish-runtime-test--chat
                  (pilish--setup-session (file-name-as-directory directory) "unavailable"))))))

(ert-deftest pilish-runtime-test-configuration-is-explicit-and-versioned ()
  (should (= (plist-get (pilish-integration-capabilities) :pimux-protocol) 2))
  (should-error (pilish-configure-runtime :protocol 1))
  (should-error (pilish-configure-runtime :pi-executable "pi" :pimux-executable "pimux"))
  (let ((pilish-runtime-mode 'detached))
    (pilish-configure-runtime :mode 'unshared)
    (should-not (pilish-runtime-configured-p))))

(ert-deftest pilish-runtime-test-native-mode-does-not-acquire-network-gate ()
  (let ((process (make-pipe-process :name "native-fixture" :noquery t)) sent)
    (unwind-protect
        (cl-letf (((symbol-function 'pilish--send-string) (lambda (_process string) (setq sent string))))
          (pilish--rpc-async process '(:type "prompt" :message "ordinary") #'ignore)
          (should (string-match-p "ordinary" sent)))
      (delete-process process))))

(provide 'pilish-runtime-test)
;;; pilish-runtime-test.el ends here
