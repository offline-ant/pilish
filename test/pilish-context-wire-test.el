;;; pilish-context-wire-test.el --- Owning contextual RPC boundary -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; These use the real core helpers and synthetic post-validation transports.
;; The owning router separately proves atomic comparison before forwarding.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'pilish)

(defconst pilish-context-wire-test--a
  '(:sessionFile "/synthetic/one.jsonl" :leafId "branch-a" :contextId "context-a"))
(defconst pilish-context-wire-test--b
  '(:sessionFile "/synthetic/two.jsonl" :leafId :null :contextId "context-b"))

(defmacro pilish-context-wire-test--peer (&rest body)
  "Run BODY with detached PROC, CHAT and recorded SENT commands."
  (declare (indent 0) (debug t))
  `(let* ((proc (make-pipe-process :name "context-wire-test" :noquery t))
          (chat (generate-new-buffer " *context-wire-test*"))
          sent)
     (unwind-protect
         (progn
           (process-put proc 'pilish-detached t)
           (process-put proc 'pilish-mux '(:protocol 2 :muxId "synthetic"))
           (process-put proc 'pilish-mux-generation 3)
           (process-put proc 'pilish-mux-applied-generation 3)
           (process-put proc 'pilish-mux-live-generation 3)
           (process-put proc 'pilish-input-context (copy-tree pilish-context-wire-test--a))
           (process-put proc 'pilish-chat-buffer chat)
           (with-current-buffer chat
             (setq-local pilish--process proc
                         pilish--state '(:session-file "/synthetic/one.jsonl" :leaf-id "branch-a")
                         pilish--draft-context nil))
           (cl-letf (((symbol-function 'pilish--send-string)
                      (lambda (_proc string)
                        (push (json-parse-string string :object-type 'plist) sent))))
             ,@body))
       (when (process-live-p proc) (delete-process proc))
       (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pilish-context-wire-test-validate-exact-context ()
  (should (pilish--valid-input-context-p pilish-context-wire-test--a))
  (should (pilish--valid-input-context-p pilish-context-wire-test--b))
  (should (pilish--valid-input-context-p '(:sessionFile nil :leafId nil :contextId "memory")))
  (dolist (bad '(nil (:sessionFile "x" :contextId "missing-leaf")
                    (:sessionFile "x" :leafId nil :contextId "")
                    (:sessionFile 3 :leafId nil :contextId "bad-file")
                    (:sessionFile "x" :leafId [] :contextId "bad-leaf")))
    (should-not (pilish--valid-input-context-p bad))))

(ert-deftest pilish-context-wire-test-capture-is-a-copy-not-a-rebinding ()
  (pilish-context-wire-test--peer
    (let ((captured (pilish--capture-input-context proc)))
      (process-put proc 'pilish-input-context (copy-tree pilish-context-wire-test--b))
      (should (equal captured pilish-context-wire-test--a))
      (setf (plist-get captured :contextId) "changed-local-copy")
      (should (equal (process-get proc 'pilish-input-context) pilish-context-wire-test--b)))))

(ert-deftest pilish-context-wire-test-all-mutations-carry-the-owning-binding ()
  (pilish-context-wire-test--peer
    (dolist (type '("prompt" "steer" "follow_up" "clear_queue" "abort" "abort_bash"
                    "new_session" "switch_session" "fork" "clone" "set_model"
                    "cycle_thinking_level" "compact" "bash" "export_html"))
      (pilish--rpc-async proc (list :type type) #'ignore)
      (should (equal (plist-get (car sent) :pimuxContext) pilish-context-wire-test--a)))))

(ert-deftest pilish-context-wire-test-captured-stale-metadata-is-never-replaced ()
  (pilish-context-wire-test--peer
    (let ((captured (pilish--capture-input-context proc)))
      (process-put proc 'pilish-input-context (copy-tree pilish-context-wire-test--b))
      (pilish--rpc-async
       proc (pilish--bind-input-context '(:type "prompt" :message "for A") captured) #'ignore)
      (should (equal (plist-get (car sent) :pimuxContext) pilish-context-wire-test--a)))))

(ert-deftest pilish-context-wire-test-root-leaf-encodes-json-null-not-string-null ()
  (pilish-context-wire-test--peer
    (process-put proc 'pilish-input-context (copy-tree pilish-context-wire-test--b))
    (pilish--rpc-async proc '(:type "prompt" :message "first prompt") #'ignore)
    (should (eq (plist-get (plist-get (car sent) :pimuxContext) :leafId) :null))
    (should (eq (plist-get (process-get proc 'pilish-input-context) :leafId) :null))))

(ert-deftest pilish-context-wire-test-explicit-invalid-metadata-does-not-use-current ()
  (pilish-context-wire-test--peer
    (should-error (pilish--rpc-async proc '(:type "prompt" :pimuxContext :null) #'ignore)
                  :type 'user-error)
    (should-not sent)))

(ert-deftest pilish-context-wire-test-pending-boundary-refuses-abort-and-dialog-answer ()
  (pilish-context-wire-test--peer
    (process-put proc 'pilish-mux-awaiting-snapshot t)
    (dolist (type '("prompt" "abort" "abort_bash" "clear_queue"))
      (should-error (pilish--rpc-async proc (list :type type) #'ignore) :type 'user-error))
    (should-error (pilish--send-extension-ui-response
                   proc '(:type "extension_ui_response" :id "d" :confirmed t))
                  :type 'user-error)
    (should-not sent)))

(ert-deftest pilish-context-wire-test-safe-reads-and-bootstrap-do-not-need-context ()
  (pilish-context-wire-test--peer
    (process-put proc 'pilish-mux-awaiting-snapshot t)
    (process-put proc 'pilish-input-context nil)
    (dolist (type (append pilish--readonly-rpc-commands '("pimux_bootstrap" "pimux_stop")))
      (pilish--rpc-async proc (list :type type) #'ignore)
      (should-not (plist-member (car sent) :pimuxContext)))))

(ert-deftest pilish-context-wire-test-unshared-rpc-keeps-native-wire-shape ()
  (pilish-context-wire-test--peer
    (process-put proc 'pilish-detached nil)
    (process-put proc 'pilish-input-context nil)
    (pilish--rpc-async proc '(:type "prompt" :message "native") #'ignore)
    (should-not (plist-member (car sent) :pimuxContext))))

(ert-deftest pilish-context-wire-test-dialog-retains-request-context-after-adoption ()
  (pilish-context-wire-test--peer
    (let ((request (pilish--extension-dialog-open
                    proc '(:id "d" :method "confirm" :title "A?"))))
      (process-put proc 'pilish-input-context (copy-tree pilish-context-wire-test--b))
      (pilish--extension-dialog-respond proc request '(:confirmed t))
      (should (equal (plist-get (car sent) :pimuxContext) pilish-context-wire-test--a)))))

(ert-deftest pilish-context-wire-test-old-dialog-cannot-close-reused-id ()
  (pilish-context-wire-test--peer
    (let ((old (pilish--extension-dialog-open proc '(:id "same" :method "confirm"))))
      (pilish--extension-dialog-close proc "same")
      (process-put proc 'pilish-input-context (copy-tree pilish-context-wire-test--b))
      (pilish--extension-dialog-open proc '(:id "same" :method "confirm"))
      (should-error (pilish--extension-dialog-respond proc old '(:confirmed t)) :type 'user-error)
      (should (pilish--extension-dialog-request proc "same"))
      (should-not sent))))

(ert-deftest pilish-context-wire-test-minibuffer-response-keeps-captured-dialog-context ()
  (pilish-context-wire-test--peer
    (let ((pilish-extension-dialog-style 'minibuffer))
      (cl-letf (((symbol-function 'pilish--extension-ui-confirm)
                 (lambda (_event process)
                   (process-put process 'pilish-input-context
                                (copy-tree pilish-context-wire-test--b))
                   (pilish--send-extension-ui-response
                    process '(:type "extension_ui_response" :id "d" :confirmed t)))))
        (pilish--ask-extension-dialog '(:id "d" :method "confirm") proc)))
    (should (equal (plist-get (car sent) :pimuxContext) pilish-context-wire-test--a))))

(ert-deftest pilish-context-wire-test-queue-confirmation-cannot-retarget ()
  (pilish-context-wire-test--peer
    (with-current-buffer chat
      (setq pilish--followup-queue '("belongs to A"))
      (cl-letf (((symbol-function 'pilish--get-chat-buffer) (lambda () chat))
                ((symbol-function 'pilish--get-process) (lambda () proc))
                ((symbol-function 'pilish--confirm-shared-queue-clear)
                 (lambda ()
                   (process-put proc 'pilish-input-context (copy-tree pilish-context-wire-test--b))
                   t)))
        (should-error (pilish--remove-shared-queued-messages) :type 'user-error))
      (should (equal pilish--followup-queue '("belongs to A")))
      (should-not sent))))

(ert-deftest pilish-context-wire-test-clear-and-abort-carry-original-authorization ()
  (pilish-context-wire-test--peer
    (with-current-buffer chat
      (cl-letf (((symbol-function 'pilish--get-chat-buffer) (lambda () chat))
                ((symbol-function 'pilish--get-process) (lambda () proc))
                ((symbol-function 'pilish--confirm-shared-queue-clear) (lambda () t))
                ((symbol-function 'pilish--cancel-tool-times-state) #'ignore)
                ((symbol-function 'pilish--paint-retired-tool-times) #'ignore))
        (pilish--abort-shared-turn))
      (should (equal (mapcar (lambda (command) (plist-get command :type)) (reverse sent))
                     '("clear_queue" "abort")))
      (should (equal pilish--abort-input-context pilish-context-wire-test--a))
      (dolist (command sent)
        (should (equal (plist-get command :pimuxContext) pilish-context-wire-test--a))))))

(ert-deftest pilish-context-wire-test-replay-renderer-error-cannot-commit-live ()
  (pilish-context-wire-test--peer
    (process-put proc 'pilish-mux-snapshot '(:generation 3))
    (process-put proc 'pilish-display-handler
                 (lambda (record)
                   (with-current-buffer chat
                     (if (equal (plist-get record :type) "pimux_live")
                         (pilish--shared-finish-snapshot proc record)
                       (error "synthetic replay renderer failure")))))
    (cl-letf (((symbol-function 'pilish--quarantine-local-work) #'ignore)
              ((symbol-function 'pilish--add-chat-notice) #'ignore)
              ((symbol-function 'pilish--runtime-snapshot-failed) #'ignore))
      (pilish--process-filter proc "{\"type\":\"message_start\"}\n")
      (pilish--process-filter proc "{\"type\":\"pimux_live\",\"generation\":3}\n"))
    (should-not (pilish--shared-input-ready-p proc))
    (should-not (process-get proc 'pilish-input-context))
    (should (process-get proc 'pilish-mux-awaiting-snapshot))))

(ert-deftest pilish-context-wire-test-public-context-copy-requires-successful-live ()
  (pilish-context-wire-test--peer
    (let ((context (pilish-session-input-context chat)))
      (should (equal context pilish-context-wire-test--a))
      (setf (plist-get context :contextId) "caller-copy")
      (should (equal (process-get proc 'pilish-input-context) pilish-context-wire-test--a)))
    (process-put proc 'pilish-mux-applied-generation nil)
    (should-not (pilish-session-input-context chat))))

(ert-deftest pilish-context-wire-test-new-branch-token-quarantines-even-the-same-leaf ()
  (pilish-context-wire-test--peer
    (with-current-buffer chat
      (setq pilish--draft-context
            (list :session-file "/synthetic/one.jsonl" :leaf-id "branch-a"
                  :runtime-context (copy-tree pilish-context-wire-test--a)))
      (let (quarantined)
        (cl-letf (((symbol-function 'pilish--quarantine-local-work)
                   (lambda (reason context) (setq quarantined (list reason context)))))
          (pilish--draft-adopt-context
           (list :session '(:file "/synthetic/one.jsonl" :cwd "/synthetic/")
                 :leafId "branch-a" :entries []
                 :inputContext '(:sessionFile "/synthetic/one.jsonl" :leafId "branch-a"
                                 :contextId "explicit-new-branch"))))
        (should (equal (car quarantined) "branch-change"))
        (should (equal (plist-get (cadr quarantined) :runtime-context)
                       pilish-context-wire-test--a))))))

(provide 'pilish-context-wire-test)
;;; pilish-context-wire-test.el ends here
