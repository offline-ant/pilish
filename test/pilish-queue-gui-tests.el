;;; pilish-queue-gui-tests.el --- Queued message journeys -*- lexical-binding: t; -*-

;;; Commentary:
;; Queue real steering and a local follow-up during a run, then take them
;; back by clicking the controls in a graphical frame or through Stop,
;; against the deterministic fake Pi subprocess.

;;; Code:

(require 'ert)
(require 'pilish-gui-test-utils)

(declare-function pilish-gui-test--large-evidence "pilish-gui-tests")

(defun pilish-queue-gui--control (window command)
  "Return the mouse position of the control running COMMAND in WINDOW."
  (redisplay t)
  (cl-loop
   for y from 0 below (window-body-height window)
   thereis
   (cl-loop
    for x from 0 below (window-body-width window)
    for position = (posn-at-x-y (* x (frame-char-width)) (* y (frame-char-height))
                                window)
    for string = (posn-string position)
    for map = (and string (get-text-property (cdr string) 'keymap (car string)))
    when (and map (eq (lookup-key map [mouse-1]) command))
    return position)))

(defun pilish-queue-gui--queue-messages (chat)
  "Start a run in CHAT and queue steering and a follow-up from the input."
  (let ((process (plist-get pilish-gui-test--session :process)))
    (pilish-gui-test-send "long run" t)
    (should (pilish-test-wait-until
             (lambda () (eq (buffer-local-value 'pilish--status chat) 'streaming))
             pilish-test-rpc-timeout pilish-test-poll-interval process))
    (select-window (pilish-gui-test-input-window))
    (insert "steer later")
    (execute-kbd-macro (kbd "C-c C-s"))
    (should (pilish-test-wait-until
             (lambda ()
               (with-current-buffer chat (pilish--queued-steering)))
             pilish-test-rpc-timeout pilish-test-poll-interval process))
    (insert "follow later")
    (execute-kbd-macro (kbd "M-RET"))
    (insert "my draft")
    (with-current-buffer chat
      (should (equal (pilish--queued-followups) '("follow later"))))))

(defun pilish-queue-gui--click (window command)
  "Press and release the mouse on the control running COMMAND in WINDOW."
  (let ((position (pilish-queue-gui--control window command)))
    (should position)
    (should (eq (key-binding [mouse-1] nil nil position) command))
    (execute-kbd-macro (vector (list 'down-mouse-1 position)
                               (list 'mouse-1 position)))))

(ert-deftest pilish-gui-test-queue-restore-clear-and-stop ()
  "Clicked controls and Stop take queued messages back; only Stop ends the run."
  (dolist (action '(restore clear stop))
    (let ((pilish-chat-style 'pi)
          (pilish-input-window-height 'fit)
          (pilish-jump-to-answer nil)
          (kill-ring nil))
      (pilish-gui-test-with-fresh-session
        (:backend fake :fake-scenario "queue-lifecycle")
        (let* ((chat (plist-get pilish-gui-test--session :chat-buffer))
               (input (plist-get pilish-gui-test--session :input-buffer))
               (process (plist-get pilish-gui-test--session :process))
               (restored "steer later\n\nfollow later\n\nmy draft"))
          (pilish-queue-gui--queue-messages chat)
          (when (eq action 'restore)
            (pilish-gui-test--large-evidence "queue-panel" (buffer-string)))
          (pcase action
            ('restore
             (pilish-queue-gui--click (pilish-gui-test-input-window)
                                      'pilish-restore-queued-messages))
            ('clear
             (pilish-queue-gui--click (pilish-gui-test-input-window)
                                      'pilish-clear-queued-messages))
            ('stop (execute-kbd-macro (kbd "C-c C-k"))))
          (should (pilish-test-wait-until
                   (lambda ()
                     (with-current-buffer chat
                       (not (or (pilish--queued-steering)
                                (pilish--queued-followups)))))
                   pilish-test-rpc-timeout pilish-test-poll-interval process))
          (should (pilish-test-wait-until
                   (lambda ()
                     (equal (with-current-buffer input (buffer-string))
                            (if (eq action 'clear) "my draft" restored)))
                   pilish-test-rpc-timeout pilish-test-poll-interval process))
          (should (eq (selected-window) (pilish-gui-test-input-window)))
          (should-not (pilish-queue-gui--control
                       (pilish-gui-test-input-window)
                       'pilish-restore-queued-messages))
          (when (eq action 'clear)
            (should (equal (car kill-ring) "steer later\n\nfollow later")))
          (unless (eq action 'stop)
            (should (eq (buffer-local-value 'pilish--status chat) 'streaming)))
          (pilish-gui-test--large-evidence (format "queue-%s" action)
                                           (with-current-buffer input (buffer-string)))
          (should (pilish-gui-test-wait-for-idle))
          (should (pilish-gui-test-wait-for-chat-settled))
          (should-not (pilish-gui-test-chat-contains "Steered fake reply"))
          (should (eq (and (pilish-gui-test-chat-contains "Fake reply for: long run") t)
                      (not (eq action 'stop)))))))))

(provide 'pilish-queue-gui-tests)
;;; pilish-queue-gui-tests.el ends here
