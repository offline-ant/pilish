;;; pilish-runtime-task-test.el --- Worker task completion boundaries -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'pilish-runtime-test)

(defmacro pilish-runtime-task-test--with-view (&rest body)
  "Run BODY in a live worker view, with mutable final task evidence."
  (declare (indent 0))
  `(pilish-runtime-test--with-worker '(:commands [(:name "worker-cancel" :source "extension")])
     (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime)))
               ((symbol-function 'pilish-stop-runtime)
                (lambda (&rest _) (ert-fail "Worker Close used root Stop"))))
       (setq pilish-runtime-test--chat (pilish-attach-runtime runtime "task-boundary"))
       (pilish-runtime-test--wait
        (lambda () (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :state) "live")))
       ;; Going live fetches the runtime's commands once; BODY counts only its own traffic.
       (pilish-runtime-test--wait
        (lambda () (buffer-local-value 'pilish--commands pilish-runtime-test--chat)))
       (setq pilish-runtime-test--received nil)
       (let ((chat pilish-runtime-test--chat)) ,@body))))

(ert-deftest pilish-runtime-task-test-explicit-cli-and-captured-namespace ()
  (pilish-runtime-task-test--with-view
    (let ((process-environment (copy-sequence process-environment)) (queries 0))
      (setenv "PIMUX_DIR" "/unrelated/frontend")
      (cl-letf (((symbol-function 'process-file)
                 (lambda (program _input _destination _display &rest args)
                   (should (equal program pilish-runtime-task-status-executable))
                   (should (equal args '("--id" "test-runtime" "--json")))
                   (should (equal (getenv "PIMUX_DIR") directory))
                   (cl-incf queries) (insert (json-serialize task-record)) 0)))
        (should (equal (plist-get (pilish--runtime-task-read runtime) :state) "pending")))
      (should (= queries 1))
      (should (equal (getenv "PIMUX_DIR") "/unrelated/frontend")))
    (let ((pilish-runtime-task-status-executable nil) outcome)
      (cl-letf (((symbol-function 'pilish-submit-prompt)
                 (lambda (&rest _) (ert-fail "Unconfigured task evidence submitted input"))))
        (pilish-close-session chat (lambda (error) (setq outcome error))))
      (should (string-match-p "task-status executable" outcome))
      (should (buffer-live-p chat)))))

(ert-deftest pilish-runtime-task-test-missing-failed-or-wrong-pending-binding-never-sends-input ()
  (dolist (change '(missing failed mux worker task parent malformed))
    (pilish-runtime-task-test--with-view
      (pcase change
        ('missing (setq task-record :null))
        ('failed (setq task-record (plist-put task-record :state "failed")
                       task-record (plist-put task-record :error "name release failed")))
        ('mux (setq task-record (plist-put task-record :muxId "wrong-mux")))
        ('worker (setq task-record (plist-put task-record :worker
                                             (plist-put (copy-tree json-identity) :startTime "wrong-start"))))
        ('task (setq task-record (plist-put task-record :parent (list :process json-identity :taskId ""))))
        ('parent (setq task-record (plist-put task-record :parent
                                             '(:process (:pid 0 :startTime "x" :bootId "y") :taskId "test-task"))))
        ('malformed (setq task-record (plist-put task-record :state "not-a-state"))))
      (pilish-runtime-test--write-task task-file task-record)
      (let (outcomes)
        (with-current-buffer (pilish-session-input-buffer chat) (insert "retained admission draft"))
        (cl-letf (((symbol-function 'pilish-submit-prompt)
                   (lambda (&rest _) (ert-fail "Invalid pending binding submitted inference")))
                  ((symbol-function 'pilish--rpc-async)
                   (lambda (&rest _) (ert-fail "Invalid initial task binding passed admission"))))
          (pilish-close-session chat (lambda (error) (push error outcomes))))
        (should (= (length outcomes) 1))
        (should (stringp (car outcomes)))
        (should (buffer-live-p chat))
        (should (equal (plist-get (pilish-session-desktop-state chat) :draft) "retained admission draft"))))))

(ert-deftest pilish-runtime-task-test-final-binding-is-pinned-and-late-completion-is-once ()
  (dolist (change '(missing mux worker task parent lease unsafe))
    (pilish-runtime-task-test--with-view
      (let ((original (copy-tree task-record)) outcomes sent)
        (cl-letf (((symbol-function 'pilish-submit-prompt)
                   (lambda (_buffer text callback &optional behavior context)
                     (should (equal text "/worker-cancel"))
                     (should-not behavior) (should context)
                     (setq sent t) (funcall callback '(:success t)))))
          (pilish-close-session chat (lambda (error) (push error outcomes)))
          (pilish-runtime-test--wait (lambda () sent))
          (setq task-record (plist-put task-record :state "complete"))
          (pcase change
            ('missing (setq task-record :null))
            ('mux (setq task-record (plist-put task-record :muxId "wrong-mux")))
            ('worker (setq task-record (plist-put task-record :worker
                                                 (plist-put (copy-tree json-identity) :bootId "other-boot"))))
            ('task (setq task-record (plist-put task-record :parent
                                               (list :process json-identity :taskId "other-task"))))
            ('parent (setq task-record (plist-put task-record :parent
                                                 (list :process (plist-put (copy-tree json-identity) :startTime "other-start")
                                                       :taskId "test-task"))))
            ('lease (setq task-record (plist-put task-record :leaseFile "/different/lease.json"))))
          (pilish-runtime-test--write-task task-file task-record)
          (if (eq change 'unsafe)
              (cl-letf (((symbol-function 'process-file) (lambda (&rest _) (insert "unsafe file") 1)))
                (pilish--runtime-task-refresh chat runtime))
            (pilish--runtime-task-refresh chat runtime))
          (should (buffer-live-p chat))
          (should (= (length outcomes) 1))
          (should (stringp (car outcomes)))
          (setq task-record (plist-put original :state "complete"))
          (pilish-runtime-test--write-task task-file task-record)
          (pilish--runtime-task-refresh chat runtime)
          (should-not (buffer-live-p chat))
          (should (= (length outcomes) 1)))))))

(ert-deftest pilish-runtime-task-test-failed-remote-worker-retains-recovery-without-close-success ()
  (pilish-runtime-task-test--with-view
    (let ((notices 0)
          (pilish-session-closed-functions (list (lambda (_) (ert-fail "Failed worker retired as successful closure")))))
      (with-current-buffer (pilish-session-input-buffer chat) (insert "failed worker recovery"))
      (setq task-record (plist-put task-record :state "failed")
            task-record (plist-put task-record :error "host cleanup failed"))
      (pilish-runtime-test--write-task task-file task-record)
      (pilish--runtime-note-exit (pilish-session-process chat) '(:type "pimux_exit" :code 0))
      (should (buffer-live-p chat))
      (should (string-match-p "host cleanup failed" (plist-get (pilish-session-runtime chat) :task-error)))
      (should (equal (plist-get (pilish-session-runtime chat) :state) "stopped"))
      (should (equal (plist-get (pilish-session-desktop-state chat) :draft) "failed worker recovery"))
      (should-not (pilish-session-state-closed-p (pilish-session-desktop-state chat)))
      (pilish-close-session chat (lambda (error)
                                   (cl-incf notices) (should (string-match-p "host cleanup failed" error))))
      (should (= notices 1))
      (should-not (buffer-local-value 'pilish--runtime-task-timer chat)))))

(ert-deftest pilish-runtime-task-test-timeout-retry-never-replays-and-late-final-settles-only-new-waiter ()
  (pilish-runtime-task-test--with-view
    (let ((sent 0) first second timer)
      (cl-letf (((symbol-function 'pilish-submit-prompt)
                 (lambda (_buffer _text callback &optional _behavior _context)
                   (cl-incf sent) (funcall callback '(:success t)))))
        (pilish-close-session chat (lambda (error) (push error first)))
        (pilish-runtime-test--wait (lambda () (= sent 1)))
        (setq timer (buffer-local-value 'pilish--runtime-close-timer chat))
        (apply (timer--function timer) (timer--args timer))
        (should (= (length first) 1))
        (should (string-match-p "timed out" (car first)))
        (should (buffer-live-p chat))
        (pilish-close-session chat (lambda (error) (push error second)))
        (should (= sent 1))
        (should-not second)
        (setq task-record (plist-put task-record :state "complete"))
        (pilish-runtime-test--write-task task-file task-record)
        (pilish--runtime-task-refresh chat runtime)
        (should-not (buffer-live-p chat))
        (should (= (length first) 1))
        (should (equal second '(nil)))
        (should (= sent 1))))))

(ert-deftest pilish-runtime-task-test-restore-complete-worker-skips-view-and-keeps-recovery ()
  (pilish-runtime-test--with-worker nil
    (setq runtime (plist-put runtime :state "stopped")
          runtime (plist-put runtime :exit '(:code 0))
          task-record (plist-put task-record :state "complete"))
    (pilish-runtime-test--write-task task-file task-record)
    (cl-letf (((symbol-function 'pilish--runtime-new-view)
               (lambda (&rest _) (ert-fail "Completed task allocated an active view")))
              ((symbol-function 'pilish-list-runtimes)
               (lambda () (ert-fail "Completed task attempted attachment")))
              ((symbol-function 'pilish--runtime-call)
               (lambda (&rest _) (ert-fail "Desktop restore sent runtime control"))))
      (should-not
       (pilish-restore-session-state
        (list :directory directory :name "complete-worker" :session-file file
              :runtime runtime :draft "completed worker desktop recovery"
              :followups '("never replay completed work")))))
    (with-current-buffer "*Pilish closed agents*"
      (should (string-search "completed worker desktop recovery" (buffer-string)))
      (should (string-search "never replay completed work" (buffer-string))))))

(ert-deftest pilish-runtime-task-test-restore-retains-unknown-task-despite-runtime-receipt ()
  (dolist (change '(pending failed missing binding))
    (pilish-runtime-test--with-worker nil
      (setq runtime (plist-put runtime :task-binding (copy-tree task-record))
            runtime (plist-put runtime :state "stopped")
            runtime (plist-put runtime :exit '(:code 0))
            runtime (plist-put runtime :terminal-receipt
                               '(:muxId "test-runtime" :state "stopped" :code 0)))
      (pcase change
        ('failed (setq task-record (plist-put task-record :state "failed")
                       task-record (plist-put task-record :error "retained owning cleanup failure")))
        ('missing (setq task-record :null))
        ('binding (setq task-record (plist-put task-record :state "complete")
                        task-record (plist-put task-record :parent
                                               (list :process json-identity :taskId "replacement-task")))))
      (pilish-runtime-test--write-task task-file task-record)
      (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () nil))
                ((symbol-function 'pilish--runtime-terminal-receipt)
                 (lambda (&rest _) (ert-fail "Worker restore trusted a root receipt")))
                ((symbol-function 'pilish--runtime-call)
                 (lambda (&rest _) (ert-fail "Worker restore launched or stopped an agent")))
                ((symbol-function 'pilish-submit-prompt)
                 (lambda (&rest _) (ert-fail "Worker restore replayed input"))))
        (setq pilish-runtime-test--chat
              (pilish-restore-session-state
               (list :directory directory :name "uncertain-worker" :session-file file
                     :runtime runtime :draft "uncertain worker recovery"))))
      (should (buffer-live-p pilish-runtime-test--chat))
      (should-not (pilish-session-process pilish-runtime-test--chat))
      (should (equal (plist-get (pilish-session-desktop-state pilish-runtime-test--chat) :draft)
                     "uncertain worker recovery"))
      (with-current-buffer pilish-runtime-test--chat
        (should (string-search "Reconcile the owning parent task" (buffer-string)))
        (should (= (how-many "No agent was started" (point-min) (point-max)) 1)))
      (if (eq change 'pending)
          (should (timerp (buffer-local-value 'pilish--runtime-task-timer pilish-runtime-test--chat)))
        (should-not (buffer-local-value 'pilish--runtime-task-timer pilish-runtime-test--chat))
        ;; Neither restoration nor a later start request can poll uncertainty.
        (pilish--runtime-task-start-poll pilish-runtime-test--chat)
        (should-not (buffer-local-value 'pilish--runtime-task-timer pilish-runtime-test--chat))))))

(ert-deftest pilish-runtime-task-test-restore-reconciles-completion-during-failed-attachment ()
  (pilish-runtime-test--with-worker nil
    (let* ((closed 0)
           (pilish-session-closed-functions (list (lambda (_) (cl-incf closed)))))
      ;; The preflight sees pending. Discovery races final publication and an
      ;; already removed socket, so connect reports failure through its callback.
      (cl-letf (((symbol-function 'pilish-list-runtimes)
                 (lambda ()
                   (setq task-record (plist-put task-record :state "complete"))
                   (pilish-runtime-test--write-task task-file task-record)
                   (delete-file socket)
                   (list runtime)))
                ((symbol-function 'pilish--runtime-call)
                 (lambda (&rest _) (ert-fail "Restore race sent runtime control"))))
        (setq pilish-runtime-test--chat
              (pilish-restore-session-state
               (list :directory directory :name "racing-worker" :session-file file
                     :runtime runtime :draft "attachment race recovery")))
        (should-not pilish-runtime-test--chat))
      (should (= closed 1))
      (should-not (pilish--runtime-find-view "test-runtime"))
      (with-current-buffer "*Pilish closed agents*"
        (should (string-search "attachment race recovery" (buffer-string)))))))

(ert-deftest pilish-runtime-task-test-restore-reconciles-completion-before-async-readiness-failure ()
  (pilish-runtime-test--with-worker '(:silent t)
    (let* ((closed 0)
           (pilish-session-closed-functions (list (lambda (_) (cl-incf closed)))))
      (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime)))
                ((symbol-function 'pilish--runtime-call)
                 (lambda (&rest _) (ert-fail "Restore readiness failure sent runtime control"))))
        (setq pilish-runtime-test--chat
              (pilish-restore-session-state
               (list :directory directory :name "prelive-worker" :session-file file
                     :runtime runtime :draft "prelive worker recovery")))
        (pilish-runtime-test--wait (lambda () pilish-runtime-test--clients))
        (setq task-record (plist-put task-record :state "complete"))
        (pilish-runtime-test--write-task task-file task-record)
        (delete-process (car pilish-runtime-test--clients))
        (pilish-runtime-test--wait (lambda () (not (buffer-live-p pilish-runtime-test--chat))))
        (should (= closed 1))
        (should-not pilish-runtime-test--received)
        (with-current-buffer "*Pilish closed agents*"
          (should (string-search "prelive worker recovery" (buffer-string))))))))

(ert-deftest pilish-runtime-task-test-restore-failed-readiness-retains-pending-until-late-completion ()
  (pilish-runtime-test--with-worker '(:silent t)
    (cl-letf (((symbol-function 'pilish-list-runtimes) (lambda () (list runtime)))
              ((symbol-function 'pilish--runtime-call)
               (lambda (&rest _) (ert-fail "Late restore completion sent runtime control")))
              ((symbol-function 'pilish-submit-prompt)
               (lambda (&rest _) (ert-fail "Late restore completion submitted input"))))
      (setq pilish-runtime-test--chat
            (pilish-restore-session-state
             (list :directory directory :name "pending-prelive-worker" :session-file file
                   :runtime runtime :draft "late restore completion recovery")))
      (pilish-runtime-test--wait (lambda () pilish-runtime-test--clients))
      (delete-process (car pilish-runtime-test--clients))
      (pilish-runtime-test--wait
       (lambda () (buffer-local-value 'pilish--runtime-task-timer pilish-runtime-test--chat)))
      (should (buffer-live-p pilish-runtime-test--chat))
      (should (equal (plist-get (pilish-session-runtime pilish-runtime-test--chat) :task-binding)
                     task-record))
      (setq task-record (plist-put task-record :state "complete"))
      (pilish-runtime-test--write-task task-file task-record)
      (pilish-runtime-test--wait (lambda () (not (buffer-live-p pilish-runtime-test--chat))))
      (should-not pilish-runtime-test--received)
      (with-current-buffer "*Pilish closed agents*"
        (should (string-search "late restore completion recovery" (buffer-string)))))))

(ert-deftest pilish-runtime-task-test-disconnect-cancels-owned-polling-only ()
  (pilish-runtime-task-test--with-view
    (pilish--runtime-note-exit (pilish-session-process chat) '(:type "pimux_exit" :code 0))
    (let ((timer (buffer-local-value 'pilish--runtime-task-timer chat)))
      (should (timerp timer))
      (pilish-disconnect-session chat)
      (should-not (memq timer timer-list))
      (should (process-live-p server)))))

(ert-deftest pilish-runtime-task-test-poll-stops-on-missing-invalid-or-failed-evidence ()
  (dolist (change '(missing malformed binding failed))
    (pilish-runtime-task-test--with-view
      (let ((binding (copy-tree task-record)))
        (with-current-buffer (pilish-session-input-buffer chat) (insert "retained after polling failure"))
        (pilish--runtime-worker-terminated chat)
        (let ((timer (buffer-local-value 'pilish--runtime-task-timer chat)))
          (should (memq timer timer-list))
          (pcase change
            ('missing (setq task-record :null))
            ('malformed (setq task-record (plist-put task-record :state "invalid")))
            ('binding (setq task-record (plist-put task-record :parent
                                                   (list :process json-identity :taskId "replacement-task"))))
            ('failed (setq task-record (plist-put task-record :state "failed")
                           task-record (plist-put task-record :error "final cleanup failure"))))
          (pilish-runtime-test--write-task task-file task-record)
          ;; Run the owned timer callback directly instead of waiting a period.
          (apply (timer--function timer) (timer--args timer))
          (pilish-runtime-test--wait
           (lambda () (not (buffer-local-value 'pilish--runtime-task-query chat))))
          (should-not (memq timer timer-list))
          (should-not (buffer-local-value 'pilish--runtime-task-timer chat))
          (should (buffer-live-p chat))
          (should (equal (plist-get (pilish-session-runtime chat) :task-binding) binding))
          (should (stringp (plist-get (pilish-session-runtime chat) :task-error)))
          (should (equal (plist-get (pilish-session-desktop-state chat) :draft)
                         "retained after polling failure"))
          (pilish--runtime-task-start-poll chat)
          (should-not (buffer-local-value 'pilish--runtime-task-timer chat))
          (pilish--runtime-worker-terminated chat)
          (should-not (buffer-local-value 'pilish--runtime-task-timer chat)))))))

(ert-deftest pilish-runtime-task-test-poll-reads-asynchronously-and-reschedules-after-settling ()
  (pilish-runtime-task-test--with-view
    (pilish--runtime-worker-terminated chat)
    (let ((timer (buffer-local-value 'pilish--runtime-task-timer chat)) query)
      (should (timerp timer))
      (cl-letf (((symbol-function 'process-file)
                 (lambda (&rest _) (ert-fail "Polling blocked Emacs on task evidence"))))
        (apply (timer--function timer) (timer--args timer))
        (setq query (buffer-local-value 'pilish--runtime-task-query chat))
        (should (processp query))
        (should-not (buffer-local-value 'pilish--runtime-task-timer chat))
        ;; Still pending: the next read starts only after this one settled.
        (pilish-runtime-test--wait
         (lambda () (timerp (buffer-local-value 'pilish--runtime-task-timer chat))))
        (should-not (buffer-local-value 'pilish--runtime-task-query chat))
        (should-not (process-live-p query))
        (setq task-record (plist-put task-record :state "complete"))
        (pilish-runtime-test--write-task task-file task-record)
        (setq timer (buffer-local-value 'pilish--runtime-task-timer chat))
        (apply (timer--function timer) (timer--args timer))
        (should (buffer-live-p chat))
        (pilish-runtime-test--wait (lambda () (not (buffer-live-p chat))))))))

(ert-deftest pilish-runtime-task-test-cancelled-read-never-applies-its-evidence ()
  (pilish-runtime-task-test--with-view
    (pilish--runtime-worker-terminated chat)
    (let ((timer (buffer-local-value 'pilish--runtime-task-timer chat)) query)
      (setq task-record (plist-put task-record :state "complete"))
      (pilish-runtime-test--write-task task-file task-record)
      (apply (timer--function timer) (timer--args timer))
      (setq query (buffer-local-value 'pilish--runtime-task-query chat))
      (with-current-buffer chat (pilish--runtime-task-cancel-poll))
      (should-not (process-live-p query))
      (should-not (buffer-live-p (process-buffer query)))
      (pilish-runtime-test--wait (lambda () (memq (process-status query) '(exit signal))))
      (accept-process-output nil 0.05)
      (should (buffer-live-p chat))
      (should-not (buffer-local-value 'pilish--runtime-task-timer chat)))))

(defun pilish-runtime-task-test--orphan (record)
  "Return pending RECORD owned by a dead parent: Emacs's PID with another start."
  (let ((owner (copy-tree (plist-get (plist-get record :parent) :process))))
    (plist-put (copy-tree record) :parent
               (list :process (plist-put owner :startTime "1") :taskId "test-task"))))

(ert-deftest pilish-runtime-task-test-dead-owner-stops-polling-and-retains-uncertainty ()
  (pilish-runtime-task-test--with-view
    (setq task-record (pilish-runtime-task-test--orphan task-record))
    (pilish-runtime-test--write-task task-file task-record)
    (with-current-buffer (pilish-session-input-buffer chat) (insert "orphaned worker draft"))
    (let ((captured (pilish-runtime-task-test--captured-runtime runtime)))
      (pilish--runtime-worker-terminated chat)
      (should-not (buffer-local-value 'pilish--runtime-task-timer chat))
      (should-not (buffer-local-value 'pilish--runtime-task-query chat))
      (should (buffer-live-p chat))
      (should (equal (plist-get (pilish-session-runtime chat) :task-binding) task-record))
      (should (string-match-p "owner exited before cleanup"
                              (plist-get (pilish-session-runtime chat) :task-error)))
      (should (equal (plist-get (pilish-session-desktop-state chat) :draft) "orphaned worker draft"))
      (pilish--runtime-task-start-poll chat)
      (should-not (buffer-local-value 'pilish--runtime-task-timer chat))
      (let ((failure (should-error (pilish-reconcile-worker-task chat captured))))
        (should (string-match-p "owner exited before cleanup" (error-message-string failure))))
      (should (buffer-live-p chat))
      (should-not pilish-runtime-test--received))))

(ert-deftest pilish-runtime-task-test-reconnect-preserves-binding-and-never-rearms-cancellation ()
  (pilish-runtime-task-test--with-view
    (let ((sent 0) first second ready)
      (cl-letf (((symbol-function 'pilish-submit-prompt)
                 (lambda (_buffer _text callback &optional _behavior _context)
                   (cl-incf sent) (funcall callback '(:success t)))))
        (pilish-close-session chat (lambda (error) (push error first)))
        (pilish-runtime-test--wait (lambda () (= sent 1)))
        (delete-process (pilish-session-process chat))
        (pilish-reconnect-runtime chat (lambda (error) (setq ready (or error 'success))))
        (pilish-runtime-test--wait (lambda () ready))
        (should (eq ready 'success))
        (should (equal (plist-get (pilish-session-runtime chat) :task-binding) task-record))
        (should (plist-get (pilish-session-runtime chat) :task-cancel-requested))
        (let ((timer (buffer-local-value 'pilish--runtime-close-timer chat)))
          (apply (timer--function timer) (timer--args timer)))
        (pilish-close-session chat (lambda (error) (push error second)))
        (should (= sent 1))
        (let ((wrong (copy-tree task-record)))
          (setq wrong (plist-put wrong :state "complete")
                wrong (plist-put wrong :parent (list :process json-identity :taskId "replacement-task")))
          (pilish-runtime-test--write-task task-file wrong))
        (pilish--runtime-task-refresh chat runtime)
        (should (buffer-live-p chat))
        (should (= (length first) 1))
        (should (= (length second) 1))
        (should (stringp (car second)))
        (setq task-record (plist-put task-record :state "complete"))
        (pilish-runtime-test--write-task task-file task-record)
        (pilish--runtime-task-refresh chat runtime)
        (should-not (buffer-live-p chat))
        (should (= (length first) 1))
        (should (= (length second) 1))))))

(ert-deftest pilish-runtime-task-test-input-context-changes-during-final-admission-read ()
  (pilish-runtime-task-test--with-view
    (let ((queries 0) outcomes)
      (cl-letf (((symbol-function 'process-file)
                 (lambda (&rest _)
                   (cl-incf queries)
                   (insert (json-serialize task-record))
                   (when (= queries 2)
                     (process-put (pilish-session-process chat) 'pilish-input-context
                                  (list :sessionFile file :leafId :null :contextId "changed-during-query")))
                   0))
                ((symbol-function 'pilish-submit-prompt)
                 (lambda (&rest _) (ert-fail "Changed admission context sent slash input"))))
        (pilish-close-session chat (lambda (error) (push error outcomes)))
        (pilish-runtime-test--wait (lambda () outcomes)))
      (should (= queries 2))
      (should (string-match-p "changed while reading" (car outcomes)))
      (should (buffer-live-p chat))
      (should-not (plist-get (pilish-session-runtime chat) :task-cancel-requested)))))

(ert-deftest pilish-runtime-task-test-replacement-during-query-cannot-retire ()
  (pilish-runtime-task-test--with-view
    (setq task-record (plist-put task-record :state "complete"))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _)
                 (insert (json-serialize task-record))
                 (with-current-buffer chat
                   (setq pilish--runtime '(:protocol 2 :mux-id "replacement" :state "live")))
                 0)))
      (pilish--runtime-task-refresh chat runtime))
    (should (buffer-live-p chat))
    (should (equal (plist-get (pilish-session-runtime chat) :state) "live"))
    (should-not (plist-get (pilish-session-runtime chat) :task-binding))))

(ert-deftest pilish-runtime-task-test-worker-reconnect-never-falls-back-to-runtime-receipt ()
  (pilish-runtime-task-test--with-view
    (let (outcome)
      (cl-letf (((symbol-function 'pilish-list-runtimes)
                 (lambda ()
                   (with-current-buffer chat
                     (setq pilish--runtime (plist-put pilish--runtime :pi-start-time "replacement")))
                   (error "Discovery unavailable")))
                ((symbol-function 'pilish--runtime-terminal-receipt)
                 (lambda (&rest _) (ert-fail "Worker reconnect used root terminal evidence"))))
        (pilish-reconnect-runtime chat (lambda (error) (setq outcome error))))
      (should (string-match-p "identity changed" outcome))
      (should (buffer-live-p chat))
      (should (equal (plist-get (pilish-session-runtime chat) :state) "live")))))

(ert-deftest pilish-runtime-task-test-notification-error-cannot-strand-close-waiters ()
  (pilish-runtime-task-test--with-view
    (let (outcomes)
      (with-current-buffer chat
        (setq pilish--runtime-close-callbacks (list (lambda (error) (push error outcomes)))))
      (cl-letf (((symbol-function 'pilish--note-desktop-state)
                 (lambda () (error "Desktop notification failed"))))
        (pilish--runtime-task-error chat "Original cleanup uncertainty"))
      (should (= (length outcomes) 1))
      (should (string-match-p "Original cleanup uncertainty" (car outcomes)))
      (should (string-match-p "Desktop notification failed" (car outcomes)))
      (should (buffer-live-p chat))
      (should-not (buffer-local-value 'pilish--runtime-close-callbacks chat)))))

(defun pilish-runtime-task-test--commands (&optional type)
  "Return actual peer commands, optionally restricted to TYPE."
  (seq-filter (lambda (command) (or (null type) (equal (plist-get command :type) type)))
              (mapcar #'pilish--parse-json-line
                      (split-string (apply #'concat (reverse pilish-runtime-test--received)) "\n" t))))

(defun pilish-runtime-task-test--reply (command &rest fields)
  "Send a real RPC response for COMMAND, with response FIELDS."
  (process-send-string
   (car pilish-runtime-test--clients)
   (concat (json-serialize
            (append (list :type "response" :command (plist-get command :type) :id (plist-get command :id)) fields))
           "\n")))

(ert-deftest pilish-runtime-task-test-pending-close-suspends-input-and-recovers-unsent-followups ()
  (pilish-runtime-task-test--with-view
    (let* ((input (pilish-session-input-buffer chat))
           (image (pilish--make-prompt-image :name "kept.png" :mime-type "image/png"
                                           :byte-size 3 :data "YWJj"))
           outcomes)
      (with-current-buffer input (insert "unsent draft") (pilish--set-prompt-image image))
      (with-current-buffer chat (pilish--push-followup "first unsent") (pilish--push-followup "second unsent"))
      (pilish-close-session chat (lambda (error) (push error outcomes)))
      ;; Input is suspended before the asynchronous command catalog arrives.
      (should-not (pilish--input-ready-p chat))
      (with-current-buffer input (pilish-send))
      (dolist (command '((:type "prompt" :message "normal public input")
                         (:type "steer" :message "normal steering")
                         (:type "follow_up" :message "normal follow-up")))
        (should-error (pilish--rpc-async (pilish-session-process chat) command #'ignore) :type 'user-error))
      (should-error (pilish-submit-prompt chat "normal public API input" #'ignore) :type 'user-error)
      (let ((recovered (car (pilish-session-quarantine chat))))
        (should (equal (plist-get recovered :followups) '("first unsent" "second unsent"))))
      (with-current-buffer chat
        (should-not pilish--followup-queue)
        ;; A late local queue owner must not release work on an idle event.
        (pilish--push-followup "late unsent")
        (setq pilish--status 'idle)
        (pilish--process-followup-queue)
        (should (equal (pilish--followups-in-fifo-order) '("late unsent")))
        (should-not (pilish--prompt-start-wait-active-p)))
      ;; The admitted cancellation control still crosses the actual RPC gate.
      (pilish-runtime-test--wait (lambda () (pilish-runtime-task-test--commands "prompt")))
      (let ((prompts (pilish-runtime-task-test--commands "prompt")))
        (should (= (length prompts) 1))
        (should (equal (plist-get (car prompts) :message) "/worker-cancel"))
        (pilish-runtime-task-test--reply (car prompts) :success t))
      (should-not outcomes)
      (with-current-buffer input
        (should (equal (buffer-string) "unsent draft"))
        (should (equal (pilish--get-prompt-image input) image)))
      (setq task-record (plist-put task-record :state "complete"))
      (pilish-runtime-test--write-task task-file task-record)
      (pilish--runtime-task-refresh chat runtime)
      (should (equal outcomes '(nil)))
      (should-not (buffer-live-p chat)))))

(ert-deftest pilish-runtime-task-test-close-notification-failure-cannot-rearm-recovered-followups ()
  (pilish-runtime-task-test--with-view
    (let (outcomes)
      (with-current-buffer chat (pilish--push-followup "suspended despite UI failure"))
      (cl-letf (((symbol-function 'pilish--refresh-input-preamble)
                 (lambda () (error "Injected preamble failure"))))
        (pilish-close-session chat (lambda (error) (push error outcomes))))
      (should (= (length outcomes) 1))
      (should (string-match-p "Injected preamble failure" (car outcomes)))
      (should (equal (plist-get (car (pilish-session-quarantine chat)) :followups)
                     '("suspended despite UI failure")))
      (with-current-buffer chat
        (should-not pilish--followup-queue)
        (pilish--process-followup-queue))
      (should (pilish--rpc-sync (pilish-session-process chat) '(:type "get_commands") 1))
      (should-not (pilish-runtime-task-test--commands "prompt"))
      (should (buffer-live-p chat)))))

(ert-deftest pilish-runtime-task-test-close-preserves-in-flight-fifo-owner-and-quarantines-successors ()
  (pilish-runtime-task-test--with-view
    (with-current-buffer chat
      (pilish--push-followup "already submitted")
      (pilish--push-followup "not submitted")
      (pilish--process-followup-queue))
    (pilish-runtime-test--wait (lambda () (pilish-runtime-task-test--commands "prompt")))
    (let ((owner (car (pilish-runtime-task-test--commands "prompt"))) outcomes)
      (should (equal (plist-get owner :message) "already submitted"))
      (pilish-close-session chat (lambda (error) (push error outcomes)))
      (with-current-buffer chat
        (should (equal (pilish--followups-in-fifo-order) '("already submitted")))
        (should (pilish--followup-submitted-p)))
      (should (equal (plist-get (car (pilish-session-quarantine chat)) :followups) '("not submitted")))
      (pilish-runtime-task-test--reply owner :success t :data '(:disposition "handled"))
      (pilish-runtime-test--wait (lambda () (= (length (pilish-runtime-task-test--commands "prompt")) 2)))
      (with-current-buffer chat
        (should-not pilish--followup-queue)
        (should-not (pilish--prompt-start-wait-active-p)))
      (should (equal (mapcar (lambda (command) (plist-get command :message))
                            (pilish-runtime-task-test--commands "prompt"))
                     '("already submitted" "/worker-cancel")))
      (setq task-record (plist-put task-record :state "complete"))
      (pilish-runtime-test--write-task task-file task-record)
      (pilish--runtime-task-refresh chat runtime)
      (should (equal outcomes '(nil))))))

(ert-deftest pilish-runtime-task-test-definitive-rejection-rearms-only-an-explicit-close-retry ()
  (dolist (delivery '(nil "rejected"))
    (pilish-runtime-task-test--with-view
      (let (first second)
        (pilish-close-session chat (lambda (error) (push error first)))
        (pilish-runtime-test--wait (lambda () (pilish-runtime-task-test--commands "prompt")))
        (apply #'pilish-runtime-task-test--reply (car (pilish-runtime-task-test--commands "prompt"))
               :success :false :error "explicit rejection"
               (when delivery (list :delivery delivery)))
        (pilish-runtime-test--wait (lambda () first))
        (should (string-match-p "explicit rejection" (car first)))
        (should (pilish--input-ready-p chat))
        (should-not (plist-get (plist-get (pilish-session-desktop-state chat) :runtime) :task-cancel-requested))
        (should-not (buffer-local-value 'pilish--runtime-task-timer chat))
        (should (= (length (pilish-runtime-task-test--commands "prompt")) 1))
        (pilish-close-session chat (lambda (error) (push error second)))
        (pilish-runtime-test--wait (lambda () (= (length (pilish-runtime-task-test--commands "prompt")) 2)))
        (should (= (length (pilish-runtime-task-test--commands "get_commands")) 2))
        (pilish-runtime-task-test--reply (cadr (pilish-runtime-task-test--commands "prompt")) :success t)
        (setq task-record (plist-put task-record :state "complete"))
        (pilish-runtime-test--write-task task-file task-record)
        (pilish--runtime-task-refresh chat runtime)
        (should (equal second '(nil)))
        (should (= (length first) 1))))))

(ert-deftest pilish-runtime-task-test-uncertain-reply-retains-input-suspension-and-never-resends ()
  (dolist (extra '((:delivery "uncertain") (:processExit t) (:delivery "unknown")))
    (pilish-runtime-task-test--with-view
      (let (first second)
        (pilish-close-session chat (lambda (error) (push error first)))
        (pilish-runtime-test--wait (lambda () (pilish-runtime-task-test--commands "prompt")))
        (apply #'pilish-runtime-task-test--reply (car (pilish-runtime-task-test--commands "prompt"))
               :success :false :error "delivery uncertain" extra)
        (pilish-runtime-test--wait (lambda () first))
        (should-not (pilish--input-ready-p chat))
        (should-error (pilish-submit-prompt chat "do not infer after uncertainty" #'ignore) :type 'user-error)
        (should (plist-get (pilish-session-runtime chat) :task-cancel-requested))
        (should (timerp (buffer-local-value 'pilish--runtime-task-timer chat)))
        (pilish-close-session chat (lambda (error) (push error second)))
        (should-not second)
        (should (= (length (pilish-runtime-task-test--commands "prompt")) 1))
        (should (= (length (pilish-runtime-task-test--commands "get_commands")) 1))
        (setq task-record (plist-put task-record :state "complete"))
        (pilish-runtime-test--write-task task-file task-record)
        (pilish--runtime-task-refresh chat runtime)
        (should (equal second '(nil)))
        (should (= (length first) 1))))))

(ert-deftest pilish-runtime-task-test-final-cleanup-error-wins-over-late-cancellation-rejection ()
  (pilish-runtime-task-test--with-view
    (let (outcomes)
      (pilish-close-session chat (lambda (error) (push error outcomes)))
      (pilish-runtime-test--wait (lambda () (pilish-runtime-task-test--commands "prompt")))
      (setq task-record (plist-put task-record :state "failed")
            task-record (plist-put task-record :error "owning cleanup failed"))
      (pilish-runtime-test--write-task task-file task-record)
      (pilish--runtime-task-refresh chat runtime)
      (should (string-match-p "owning cleanup failed" (car outcomes)))
      (pilish-runtime-task-test--reply (car (pilish-runtime-task-test--commands "prompt"))
                                      :success :false :delivery "rejected" :error "late cancellation rejection")
      (should (pilish--rpc-sync (pilish-session-process chat) '(:type "get_commands") 1))
      (should (= (length outcomes) 1))
      (should (string-match-p "owning cleanup failed" (plist-get (pilish-session-runtime chat) :task-error)))
      (should (plist-get (pilish-session-runtime chat) :task-cancel-requested))
      (should-not (pilish--input-ready-p chat)))))

(ert-deftest pilish-runtime-task-test-late-rejection-after-timeout-rearms-without-recalling-settled-waiter ()
  (pilish-runtime-task-test--with-view
    (let (first second third)
      (pilish-close-session chat (lambda (error) (push error first)))
      (pilish-runtime-test--wait (lambda () (pilish-runtime-task-test--commands "prompt")))
      (let ((timer (buffer-local-value 'pilish--runtime-close-timer chat)))
        (apply (timer--function timer) (timer--args timer)))
      (should (string-match-p "timed out" (car first)))
      (should-not (pilish--input-ready-p chat))
      (pilish-close-session chat (lambda (error) (push error second)))
      (pilish-runtime-task-test--reply (car (pilish-runtime-task-test--commands "prompt"))
                                      :success :false :delivery "rejected" :error "late rejection")
      (pilish-runtime-test--wait (lambda () second))
      (should (equal second '("late rejection")))
      (should (= (length first) 1))
      (should (pilish--input-ready-p chat))
      (pilish-close-session chat (lambda (error) (push error third)))
      (pilish-runtime-test--wait (lambda () (= (length (pilish-runtime-task-test--commands "prompt")) 2)))
      (setq task-record (plist-put task-record :state "complete"))
      (pilish-runtime-test--write-task task-file task-record)
      (pilish--runtime-task-refresh chat runtime)
      (should (equal third '(nil)))
      (should (= (length first) 1))
      (should (= (length second) 1)))))

(defun pilish-runtime-task-test--captured-runtime (runtime)
  "Copy only the identity keys supplied by the companion from RUNTIME."
  (cl-loop for key in '(:mux-id :socket :pi-pid :pi-start-time :pi-boot-id)
           append (list key (plist-get runtime key))))

(ert-deftest pilish-runtime-task-test-public-reconcile-disconnected-natural-completion ()
  (pilish-runtime-task-test--with-view
    (let ((captured (pilish-runtime-task-test--captured-runtime runtime))
          (input (pilish-session-input-buffer chat)) (closed 0))
      (with-current-buffer input (insert "offline natural-completion draft"))
      (delete-process (pilish-session-process chat))
      (pilish-runtime-test--wait
       (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "disconnected")))
      (should-not (buffer-local-value 'pilish--runtime-task-timer chat))
      (setq task-record (plist-put task-record :state "complete"))
      (pilish-runtime-test--write-task task-file task-record)
      (let ((pilish-session-closed-functions
             (list (lambda (buffer)
                     (cl-incf closed)
                     (should (eq buffer chat))
                     (should (buffer-live-p input))
                     (should (equal (plist-get (pilish-session-runtime buffer) :state) "stopped"))))))
        (cl-letf (((symbol-function 'pilish-submit-prompt)
                   (lambda (&rest _) (ert-fail "Reconciliation submitted input")))
                  ((symbol-function 'pilish-reconnect-runtime)
                   (lambda (&rest _) (ert-fail "Reconciliation reconnected"))))
          (should-not (pilish-reconcile-worker-task chat captured)))
        (should (= closed 1))
        (should-not (buffer-live-p chat))
        (should-not (buffer-live-p input))
        (should-not (pilish-reconcile-worker-task chat captured))
        (should (= closed 1)))
      (should-not pilish-runtime-test--received)
      (with-current-buffer "*Pilish closed agents*"
        (should (string-search "offline natural-completion draft" (buffer-string)))))))

(ert-deftest pilish-runtime-task-test-public-reconcile-retains-unknown-or-noncomplete-evidence ()
  (dolist (change '(missing pending failed mux worker task parent lease unsafe))
    (pilish-runtime-task-test--with-view
      (let ((captured (pilish-runtime-task-test--captured-runtime runtime))
            (input (pilish-session-input-buffer chat)))
        ;; A pending read captures the parent/task/lease binding without control.
        (should-error (pilish-reconcile-worker-task chat captured))
        (should (equal (plist-get (pilish-session-runtime chat) :task-binding) task-record))
        (with-current-buffer input (insert "retained uncertain completion"))
        (unless (eq change 'pending) (setq task-record (plist-put task-record :state "complete")))
        (pcase change
          ('missing (setq task-record :null))
          ('failed (setq task-record (plist-put task-record :state "failed")
                         task-record (plist-put task-record :error "owning cleanup failed")))
          ('mux (setq task-record (plist-put task-record :muxId "other-mux")))
          ('worker (setq task-record (plist-put task-record :worker
                                               (plist-put (copy-tree json-identity) :startTime "other-start"))))
          ('task (setq task-record (plist-put task-record :parent
                                             (list :process json-identity :taskId "other-task"))))
          ('parent (setq task-record (plist-put task-record :parent
                                               (list :process (plist-put (copy-tree json-identity) :bootId "other-boot")
                                                     :taskId "test-task"))))
          ('lease (setq task-record (plist-put task-record :leaseFile "/other/lease.json"))))
        (pilish-runtime-test--write-task task-file task-record)
        (if (eq change 'unsafe)
            (cl-letf (((symbol-function 'process-file) (lambda (&rest _) (insert "unsafe evidence") 1)))
              (should-error (pilish-reconcile-worker-task chat captured)))
          (should-error (pilish-reconcile-worker-task chat captured)))
        (should (buffer-live-p chat))
        (should (buffer-live-p input))
        (should (equal (plist-get (pilish-session-desktop-state chat) :draft) "retained uncertain completion"))
        (should-not pilish-runtime-test--received)))))

(ert-deftest pilish-runtime-task-test-public-reconcile-pins-captured-identity-and-worker-placement ()
  (dolist (key '(:mux-id :socket :pi-pid :pi-start-time :pi-boot-id :placement))
    (pilish-runtime-task-test--with-view
      (let ((captured (pilish-runtime-task-test--captured-runtime runtime)))
        (if (eq key :placement)
            (with-current-buffer chat (setq pilish--runtime (plist-put pilish--runtime :placement "root")))
          (setq captured (plist-put captured key (if (eq key :pi-pid) (1+ (emacs-pid)) "replacement"))))
        (cl-letf (((symbol-function 'process-file)
                   (lambda (&rest _) (ert-fail "Mismatched identity queried task evidence"))))
          (should-error (pilish-reconcile-worker-task chat captured)))
        (should (buffer-live-p chat))
        (should-not (plist-get (pilish-session-runtime chat) :task-binding))
        (should-not pilish-runtime-test--received)))))

(ert-deftest pilish-runtime-task-test-public-reconcile-rechecks-view-after-evidence-read ()
  (pilish-runtime-task-test--with-view
    (let ((captured (pilish-runtime-task-test--captured-runtime runtime)))
      (setq task-record (plist-put task-record :state "complete"))
      (cl-letf (((symbol-function 'process-file)
                 (lambda (&rest _)
                   (insert (json-serialize task-record))
                   (with-current-buffer chat
                     (setq pilish--runtime (plist-put pilish--runtime :pi-boot-id "replacement-boot")))
                   0)))
        (should-error (pilish-reconcile-worker-task chat captured)))
      (should (buffer-live-p chat))
      (should (equal (plist-get (pilish-session-runtime chat) :state) "live"))
      (should-not (plist-get (pilish-session-runtime chat) :task-binding)))))

(ert-deftest pilish-runtime-task-test-public-reconcile-reports-retirement-errors-and-settles-once ()
  (pilish-runtime-task-test--with-view
    (let ((captured (pilish-runtime-task-test--captured-runtime runtime))
          (input (pilish-session-input-buffer chat)) outcomes (closed 0))
      (with-current-buffer input (insert "retirement failure recovery"))
      (with-current-buffer chat
        (setq pilish--runtime-close-callbacks (list (lambda (failure) (push failure outcomes)))))
      (setq task-record (plist-put task-record :state "complete"))
      (pilish-runtime-test--write-task task-file task-record)
      (let ((pilish-session-closed-functions
             (list (lambda (_) (error "Injected retirement observer failure"))
                   (lambda (_) (cl-incf closed)))))
        (let ((failure (should-error (pilish-reconcile-worker-task chat captured))))
          (should (string-match-p "Injected retirement observer failure" (error-message-string failure))))
        (should (= closed 1)))
      (should-not (buffer-live-p chat))
      (should-not (buffer-live-p input))
      (should (= (length outcomes) 1))
      (should (string-match-p "Injected retirement observer failure" (car outcomes)))
      (should-not (pilish-reconcile-worker-task chat captured))
      (should (= (length outcomes) 1))
      (with-current-buffer "*Pilish closed agents*"
        (should (string-search "retirement failure recovery" (buffer-string)))
        (should (string-search "Injected retirement observer failure" (buffer-string)))))))

(defmacro pilish-runtime-task-test--with-ended-worker (dead receipt &rest body)
  "Run BODY with failed task evidence, DEAD processes and terminal RECEIPT."
  (declare (indent 2))
  `(pilish-runtime-task-test--with-view
     (with-current-buffer chat
       (setq pilish--runtime (plist-put pilish--runtime :operation-id "test-operation")))
     (setq task-record (plist-put task-record :state "failed")
           task-record (plist-put task-record :error "Emacs view close timed out"))
     (pilish-runtime-test--write-task task-file task-record)
     (cl-letf (((symbol-function 'pilish--runtime-definitely-dead-p)
                (lambda (checked)
                  (should (equal (plist-get checked :pi-pid) (emacs-pid)))
                  ,dead))
               ((symbol-function 'pilish--runtime-terminal-receipt)
                (lambda (checked)
                  (should (equal (plist-get checked :mux-id) "test-runtime"))
                  ,receipt))
               ((symbol-function 'pilish-submit-prompt)
                (lambda (&rest _) (ert-fail "Ended worker Close submitted input")))
               ((symbol-function 'pilish--rpc-async)
                (lambda (&rest _) (ert-fail "Ended worker Close sent a command"))))
       ,@body)))

(ert-deftest pilish-runtime-task-test-close-retires-failed-worker-pimux-proves-ended ()
  "Failed evidence plus pimux's exact terminal receipt lets Close remove the view."
  (pilish-runtime-task-test--with-ended-worker t
      '(:muxId "test-runtime" :operationId "test-operation" :state "stopped")
    (let ((input (pilish-session-input-buffer chat)) outcomes (closed 0))
      (with-current-buffer input (insert "ended worker draft"))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest _) (ert-fail "Reported task failure raised a cleanup warning"))))
        (let ((pilish-session-closed-functions (list (lambda (_) (cl-incf closed)))))
          (pilish-close-session chat (lambda (error) (push error outcomes)))))
      (should (= closed 1))
      (should-not (buffer-live-p chat))
      (should-not (buffer-live-p input))
      (should (= (length outcomes) 1))
      (should (string-match-p "Worker task cleanup failed: Emacs view close timed out" (car outcomes)))
      (with-current-buffer "*Pilish closed agents*"
        (should (string-search "ended worker draft" (buffer-string)))
        (should (string-search "Emacs view close timed out" (buffer-string)))))))

(ert-deftest pilish-runtime-task-test-close-retires-orphaned-worker-pimux-proves-ended ()
  "Pending evidence of a dead owner plus pimux's exact receipt lets Close remove the view."
  (pilish-runtime-task-test--with-ended-worker t
      '(:muxId "test-runtime" :operationId "test-operation" :state "stopped")
    (setq task-record (pilish-runtime-task-test--orphan (plist-put task-record :state "pending"))
          task-record (cl-loop for (key value) on task-record by #'cddr
                               unless (eq key :error) append (list key value)))
    (pilish-runtime-test--write-task task-file task-record)
    (let (outcomes (closed 0))
      (let ((pilish-session-closed-functions (list (lambda (_) (cl-incf closed)))))
        (pilish-close-session chat (lambda (error) (push error outcomes))))
      (should (= closed 1))
      (should-not (buffer-live-p chat))
      (should (= (length outcomes) 1))
      (should (string-match-p "owner exited before cleanup" (car outcomes))))))

(ert-deftest pilish-runtime-task-test-close-retires-orphaned-worker-of-dead-service-without-receipt ()
  "A dead owning pimux service replaces the expired receipt; a live one does not."
  (dolist (service-dead '(t nil))
    (pilish-runtime-task-test--with-ended-worker t nil
      (setq task-record (pilish-runtime-task-test--orphan (plist-put task-record :state "pending"))
            task-record (cl-loop for (key value) on task-record by #'cddr
                                 unless (eq key :error) append (list key value)))
      (pilish-runtime-test--write-task task-file task-record)
      (with-current-buffer chat
        (setq pilish--runtime
              (plist-put pilish--runtime :service
                         (if service-dead (plist-put (copy-tree json-identity) :startTime "1")
                           json-identity))))
      (let (outcomes)
        (pilish-close-session chat (lambda (error) (push error outcomes)))
        (should (eq (buffer-live-p chat) (not service-dead)))
        (should (= (length outcomes) 1))
        (should (string-match-p "owner exited before cleanup" (car outcomes)))))))

(ert-deftest pilish-runtime-task-test-close-retains-orphaned-worker-without-termination-proof ()
  (pilish-runtime-task-test--with-ended-worker nil
      '(:muxId "test-runtime" :operationId "test-operation" :state "stopped")
    (setq task-record (pilish-runtime-task-test--orphan (plist-put task-record :state "pending"))
          task-record (cl-loop for (key value) on task-record by #'cddr
                               unless (eq key :error) append (list key value)))
    (pilish-runtime-test--write-task task-file task-record)
    (let (outcomes
          (pilish-session-closed-functions
           (list (lambda (_) (ert-fail "Unproven orphaned worker termination retired the view")))))
      (pilish-close-session chat (lambda (error) (push error outcomes)))
      (should (buffer-live-p chat))
      (should (= (length outcomes) 1))
      (should (string-match-p "owner exited before cleanup" (car outcomes)))
      (should-not (buffer-local-value 'pilish--runtime-close-timer chat)))))

(ert-deftest pilish-runtime-task-test-close-retains-failed-worker-without-termination-proof ()
  "Missing evidence, live processes or a foreign or absent receipt keep the refusal."
  (dolist (change '(alive no-receipt other-operation no-operation missing-evidence))
    (pilish-runtime-task-test--with-ended-worker (not (eq change 'alive))
        (unless (eq change 'no-receipt)
          (list :muxId "test-runtime" :state "stopped"
                :operationId (if (eq change 'other-operation) "other-operation" "test-operation")))
      (pcase change
        ('no-operation
         (with-current-buffer chat
           (setq pilish--runtime (plist-put pilish--runtime :operation-id nil))))
        ('missing-evidence (pilish-runtime-test--write-task task-file :null)))
      (let (outcomes
            (pilish-session-closed-functions
             (list (lambda (_) (ert-fail "Unproven worker termination retired the view")))))
        (pilish-close-session chat (lambda (error) (push error outcomes)))
        (should (buffer-live-p chat))
        (should (= (length outcomes) 1))
        (should (stringp (car outcomes)))))))

(provide 'pilish-runtime-task-test)
;;; pilish-runtime-task-test.el ends here
