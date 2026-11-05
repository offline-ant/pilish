;;; pilish-shared-input-test.el --- Prelive input and shared Abort controls -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Local acceptance must precede neither the authoritative live boundary nor a
;; destructive shared Abort confirmation.  These tests deliberately make the
;; wire accept everything, so refusal cannot accidentally rely on a core RPC gate.

;;; Code:

(require 'ert)
(require 'pilish)
(require 'pilish-drafts-test)

(ert-deftest pilish-shared-input-test-prelive-commands-preserve-text-images-history ()
  "Every input submission control refuses before consuming any draft state."
  (dolist (case '((pilish-send idle follow-up t)
                  (pilish-send streaming follow-up nil)
                  (pilish-send streaming steer nil)
                  (pilish-send compacting follow-up nil)
                  (pilish-queue-followup streaming steer nil)
                  (pilish-queue-steering streaming follow-up nil)))
    (pilish-drafts-test--session
      (pcase-let ((`(,command ,status ,behavior ,image) case))
        (process-put proc 'pilish-mux-awaiting-snapshot t)
        (with-current-buffer chat (setq pilish--status status))
        (with-current-buffer input
          (insert "not accepted yet")
          (when image (pilish--set-prompt-image (pilish-drafts-test--image)))
          (let ((saved-image (pilish--get-prompt-image))
                (saved-ring pilish--input-ring)
                (pilish-send-while-busy behavior))
            (cl-letf (((symbol-function 'pilish--prepare-and-send)
                       (lambda (&rest _) (ert-fail "Prelive input reached prompt preparation"))))
              (funcall command))
            (should (equal (buffer-string) "not accepted yet"))
            (should (eq saved-image (pilish--get-prompt-image)))
            (should (eq saved-ring pilish--input-ring))))
        (with-current-buffer chat
          (should-not pilish--followup-queue)
          (should-not pilish--prompt-wait))
        (should-not commands)))))

(ert-deftest pilish-shared-input-test-prehello-managed-view-is-not-unshared ()
  "A known detached view cannot consume input merely because hello is pending."
  (pilish-drafts-test--session
    (process-put proc 'pilish-mux nil)
    (with-current-buffer chat
      (setq-local pilish--runtime '(:protocol 2 :state "connecting")))
    (with-current-buffer input
      (insert "hello has not arrived")
      (pilish-send)
      (should (equal (buffer-string) "hello has not arrived")))
    (should-not commands)))

(ert-deftest pilish-shared-input-test-acceptance-primitives-guard-programmatic-use ()
  "Direct calls cannot bypass the gate to clear history, image or local queues."
  (pilish-drafts-test--session
    (process-put proc 'pilish-mux-awaiting-snapshot t)
    (with-current-buffer input
      (insert "programmatic draft")
      (pilish--set-prompt-image (pilish-drafts-test--image))
      (let ((image (pilish--get-prompt-image)) (history pilish--input-ring))
        (should-error (pilish--accept-input-text "programmatic draft" image) :type 'user-error)
        (should-error (pilish--queue-followup-text chat "programmatic draft") :type 'user-error)
        (should (eq image (pilish--get-prompt-image)))
        (should (eq history pilish--input-ring))
        (should (equal (buffer-string) "programmatic draft"))))
    (with-current-buffer chat
      (should-not (pilish--send-steer-message "direct programmatic steering"))
      (should-not pilish--followup-queue))
    (should-not commands)))

(ert-deftest pilish-shared-input-test-double-return-does-not-delete-before-refusal ()
  "The send gesture keeps the first newline when the view is not yet live."
  (pilish-drafts-test--session
    (process-put proc 'pilish-mux-awaiting-snapshot t)
    (with-current-buffer input
      (insert "pending draft\n")
      (let ((pilish-send-on-double-return 1)
            (last-command 'pilish-newline-or-send)
            (this-command 'pilish-newline-or-send))
        (setq pilish--last-return (cons (- (float-time) 0.05) (point)))
        (cl-letf (((symbol-function 'input-pending-p) (lambda () nil)))
          (pilish-newline-or-send)))
      (should (equal (buffer-string) "pending draft\n")))
    (should-not commands)))

(ert-deftest pilish-shared-input-test-cancelled-abort-changes-no-local-owner ()
  "Confirmation happens before queues, timers, drafts, images or stop intent."
  (pilish-drafts-test--session
    (with-current-buffer input
      (insert "current editor")
      (pilish--set-prompt-image (pilish-drafts-test--image)))
    (with-current-buffer chat
      (setq pilish--status 'streaming)
      (pilish--push-followup "local pending")
      (let ((wait (pilish--begin-prompt-start-wait))
            (before (pilish--desktop-local-state))
            (confirmations 0))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (cl-incf confirmations) nil))
                  ((symbol-function 'pilish--cancel-tool-times-state)
                   (lambda () (ert-fail "Abort cancellation changed duration owners"))))
          (pilish-abort))
        (should (= confirmations 1))
        (should (eq wait pilish--prompt-wait))
        (should-not pilish--aborted)
        (should (equal before (pilish--desktop-local-state)))
        (should (equal pilish--followup-queue '("local pending")))))
    (should-not commands)))

(ert-deftest pilish-shared-input-test-abort-clears-once-delayed-abort-never-clears ()
  "One user action confirms one global clear; delayed retries send Abort only."
  (pilish-drafts-test--session
    (with-current-buffer input (insert "current draft"))
    (with-current-buffer chat
      (setq pilish--status 'streaming)
      (pilish--push-followup "unsubmitted local")
      (let ((confirmations 0))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (cl-incf confirmations) t)))
          (pilish-abort)
          (should (= confirmations 1))
          (should (equal (reverse (mapcar (lambda (command) (plist-get command :type)) commands))
                         '("clear_queue" "abort")))
          (pilish--send-abort)
          (pilish--send-abort))
        (should (= confirmations 1))
        (should (equal (reverse (mapcar (lambda (command) (plist-get command :type)) commands))
                       '("clear_queue" "abort" "abort" "abort"))))
      (should pilish--aborted)
      (should-not pilish--followup-queue))
    (with-current-buffer input (should (equal (buffer-string) "current draft")))
    (should (equal (plist-get (car (pilish-session-quarantine chat)) :followups)
                   '("unsubmitted local")))))

(ert-deftest pilish-shared-input-test-ready-shared-input-still-submits ()
  "A complete live boundary permits normal shared input acceptance."
  (pilish-drafts-test--session
    (with-current-buffer input
      (insert "intentional prompt")
      (pilish-send)
      (should (equal (buffer-string) "")))
    (should (equal (plist-get (car commands) :message) "intentional prompt"))
    (should (equal (plist-get (car commands) :type) "prompt"))))

(provide 'pilish-shared-input-test)
;;; pilish-shared-input-test.el ends here
