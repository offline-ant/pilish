;;; pilish-prompt-context-test.el --- Request-owned prompt contexts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Prompt ownership survives asynchronous acknowledgements and fallback probes.
;; These tests exercise that ownership independently of the router's rejection.
;;; Code:
(require 'ert)
(require 'pilish-ui)

(defconst pilish-prompt-context-test--a
  '(:sessionFile "/tmp/prompt-a.jsonl" :leafId "branch-a" :contextId "context-a"))
(defconst pilish-prompt-context-test--b
  '(:sessionFile "/tmp/prompt-b.jsonl" :leafId "branch-b" :contextId "context-b"))

(defmacro pilish-prompt-context-test--with-view (&rest body)
  "Run BODY with a synthetic detached transport and explicit core doubles."
  (declare (indent 0) (debug t))
  `(let* ((chat (generate-new-buffer " *pilish-prompt-context-chat*"))
          (input (generate-new-buffer " *pilish-prompt-context-input*"))
          (proc (make-pipe-process :name "pilish-prompt-context-peer" :noquery t)))
     (unwind-protect
         (with-current-buffer chat
           (setq major-mode 'pilish-chat-mode
                 pilish--process proc pilish--input-buffer input)
           (with-current-buffer input (insert "new draft"))
           (process-put proc 'pilish-detached t)
           (process-put proc 'pilish-mux '(:protocol 2 :muxId "prompt-owner"))
           (process-put proc 'pilish-input-context (copy-tree pilish-prompt-context-test--a))
           (cl-letf (((symbol-function 'pilish--capture-input-context)
                      (lambda (process)
                        (when (process-get process 'pilish-detached)
                          (or (copy-tree (process-get process 'pilish-input-context))
                              (user-error "No authoritative context")))))
                     ((symbol-function 'pilish--bind-input-context)
                      (lambda (command context)
                        (if context
                            (plist-put (copy-sequence command) :pimuxContext (copy-tree context))
                          (copy-sequence command))))
                     ((symbol-function 'pilish--refresh-input-preamble) #'ignore)
                     ((symbol-function 'pilish--draft-submission-noted) #'ignore)
                     ((symbol-function 'pilish--draft-submission-ended) #'ignore)
                     ((symbol-function 'pilish--cancel-process-dialogs) #'ignore)
                     ((symbol-function 'pilish--process-followup-queue) #'ignore))
             ,@body))
       (when (process-live-p proc) (delete-process proc))
       (dolist (buffer (list input chat))
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pilish-prompt-context-test-send-retains-request-owned-metadata ()
  (pilish-prompt-context-test--with-view
    (let (sent)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish--send-prompt "original instruction"))
      (should (equal (plist-get sent :pimuxContext) pilish-prompt-context-test--a))
      (should (equal (pilish--prompt-wait-input-context pilish--prompt-wait)
                     pilish-prompt-context-test--a))
      (should (equal (plist-get sent :message) "original instruction")))))

(ert-deftest pilish-prompt-context-test-submit-preserves-explicit-earlier-action ()
  (pilish-prompt-context-test--with-view
    (let (sent)
      (process-put proc 'pilish-input-context pilish-prompt-context-test--b)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish-submit-prompt chat "delayed instruction" #'ignore "steer"
                              pilish-prompt-context-test--a))
      (should (equal (plist-get sent :pimuxContext) pilish-prompt-context-test--a))
      (should (equal (plist-get sent :streamingBehavior) "steer"))
      (should (equal (with-current-buffer input (buffer-string)) "new draft")))))

(ert-deftest pilish-prompt-context-test-late-acceptance-cannot-release-new-context-work ()
  (pilish-prompt-context-test--with-view
    (let (reply succeeded followed)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ _command callback) (setq reply callback)))
                ((symbol-function 'pilish--process-followup-queue)
                 (lambda () (setq followed t))))
        (pilish--send-prompt "old instruction" (lambda () (setq succeeded t)))
        (process-put proc 'pilish-input-context pilish-prompt-context-test--b)
        (funcall reply '(:success t :data (:disposition "handled"))))
      (should-not succeeded)
      (should-not followed)
      (should (equal (with-current-buffer input (buffer-string)) "new draft")))))

(ert-deftest pilish-prompt-context-test-late-rejection-cannot-restore-into-new-draft ()
  (pilish-prompt-context-test--with-view
    (let (reply restored)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ _command callback) (setq reply callback))))
        (pilish--send-prompt "old instruction" nil (lambda () (setq restored t)))
        (process-put proc 'pilish-input-context pilish-prompt-context-test--b)
        (funcall reply '(:success :false :delivery "rejected" :error "stale")))
      (should-not restored)
      (should (equal (with-current-buffer input (buffer-string)) "new draft")))))

(ert-deftest pilish-prompt-context-test-same-context-refresh-keeps-correlated-acceptance ()
  (pilish-prompt-context-test--with-view
    (let (reply succeeded)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ _command callback) (setq reply callback))))
        (pilish--send-prompt "same branch" (lambda () (setq succeeded t)))
        (process-put proc 'pilish-input-context (copy-tree pilish-prompt-context-test--a))
        (process-put proc 'pilish-mux-generation 300)
        (funcall reply '(:success t :data (:disposition "handled"))))
      (should succeeded))))

(ert-deftest pilish-prompt-context-test-fallback-probe-cannot-complete-another-context ()
  (pilish-prompt-context-test--with-view
    (let ((wait (pilish--begin-prompt-start-wait)) reply completed scheduled)
      (setf (pilish--prompt-wait-accepted wait) t)
      (setq pilish--status 'sending)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ _command callback) (setq reply callback)))
                ((symbol-function 'pilish--schedule-prompt-start-fallback)
                 (lambda (&rest _) (setq scheduled t))))
        (pilish--probe-prompt-start-state chat wait (lambda () (setq completed t)))
        (process-put proc 'pilish-input-context pilish-prompt-context-test--b)
        (funcall reply '(:success t :data (:isStreaming :false :isCompacting :false))))
      (should-not completed)
      (should-not scheduled)
      (should (eq pilish--status 'sending)))))

(ert-deftest pilish-prompt-context-test-delayed-abort-is-bound-to-original-action ()
  (pilish-prompt-context-test--with-view
    (let (sent cancelled)
      (pilish--set-aborted t)
      (process-put proc 'pilish-input-context pilish-prompt-context-test--b)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (&rest _) (setq sent t)))
                ((symbol-function 'pilish--cancel-process-dialogs)
                 (lambda (_) (setq cancelled t))))
        (should-error (pilish--send-abort) :type 'user-error))
      (should-not sent)
      (should-not cancelled))))

(ert-deftest pilish-prompt-context-test-abort-context-can-precede-confirmation ()
  (pilish-prompt-context-test--with-view
    (let (sent)
      (process-put proc 'pilish-input-context pilish-prompt-context-test--b)
      (pilish--set-aborted t pilish-prompt-context-test--a)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (&rest _) (setq sent t))))
        (should-error (pilish--send-abort) :type 'user-error))
      (should (equal pilish--abort-input-context pilish-prompt-context-test--a))
      (should-not sent))))

(ert-deftest pilish-prompt-context-test-matching-delayed-abort-never-clears-again ()
  (pilish-prompt-context-test--with-view
    (let (sent)
      (pilish--set-aborted t)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (push command sent))))
        (pilish--send-abort))
      (should (= (length sent) 1))
      (should (equal (plist-get (car sent) :type) "abort"))
      (should (equal (plist-get (car sent) :pimuxContext) pilish-prompt-context-test--a)))))

(ert-deftest pilish-prompt-context-test-clearing-stop-intent-clears-captured-context ()
  (pilish-prompt-context-test--with-view
    (pilish--set-aborted t)
    (pilish--set-aborted nil)
    (should-not pilish--aborted)
    (should-not pilish--abort-input-context)))

(ert-deftest pilish-prompt-context-test-unavailable-context-recovers-reservation-failure ()
  (pilish-prompt-context-test--with-view
    (let (sent restored)
      (process-put proc 'pilish-input-context nil)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (&rest _) (setq sent t))))
        (pilish--send-prompt "original instruction" nil (lambda () (setq restored t))))
      (should restored)
      (should-not sent)
      (should-not pilish--prompt-wait)
      (should (eq pilish--status 'idle)))))

(ert-deftest pilish-prompt-context-test-unshared-submission-has-native-wire-shape ()
  (pilish-prompt-context-test--with-view
    (let (sent)
      (process-put proc 'pilish-detached nil)
      (process-put proc 'pilish-mux nil)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish-submit-prompt chat "native instruction" #'ignore))
      (should-not (plist-member sent :pimuxContext))
      (should (equal (plist-get sent :message) "native instruction")))))

(provide 'pilish-prompt-context-test)
;;; pilish-prompt-context-test.el ends here
