;;; pilish-submit-gui-tests.el --- Submission viewport journeys -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise submission from a scrolled-back chat through the input keymap,
;; using a real graphical frame and the deterministic fake Pi subprocess.

;;; Code:

(require 'ert)
(require 'pilish-gui-test-utils)

(declare-function pilish-gui-test--large-evidence "pilish-gui-tests")

(ert-deftest pilish-gui-test-submit-jump-to-end-option ()
  "Sending returns to live output by default; disabling it keeps the reader."
  (dolist (enabled '(t nil))
    (let ((pilish-jump-to-end-on-submit enabled)
          (pilish-jump-to-answer nil)
          (pilish-chat-style 'pi))
      (pilish-gui-test-with-fresh-session
        (:backend fake :fake-scenario "prompt-lifecycle")
        (pilish-gui-test-send
         (mapconcat (lambda (n) (format "Earlier line %d" n))
                    (number-sequence 1 70) "\n"))
        (let* ((chat (plist-get pilish-gui-test--session :chat-buffer))
               (chat-window (pilish-gui-test-chat-window))
               (input-window (pilish-gui-test-input-window)))
          (select-window chat-window)
          (goto-char (point-min))
          (recenter 0)
          (redisplay t)
          (let ((position (window-point chat-window))
                (start (window-start chat-window)))
            (select-window input-window)
            (insert "submitted from earlier text")
            (redisplay t)
            (should (= (window-point chat-window) position))
            (should (= (window-start chat-window) start))
            (execute-kbd-macro (kbd "C-c C-c"))
            (should (pilish-gui-test-wait-for-idle))
            (should (pilish-gui-test-wait-for-chat-settled))
            (redisplay t)
            (should (pilish-gui-test-chat-contains
                     "Fake reply for: submitted from earlier text"))
            (should (eq (selected-window) input-window))
            (should (string-empty-p (buffer-string)))
            (if enabled
                (progn
                  (should (= (window-point chat-window)
                             (with-current-buffer chat (point-max))))
                  (should (pos-visible-in-window-p
                           (with-current-buffer chat (point-max)) chat-window)))
              (should (= (window-point chat-window) position))
              (should (= (window-start chat-window) start)))
            (pilish-gui-test--large-evidence
             (if enabled "submit-jump-on" "submit-jump-off")
             (list :enabled enabled :point (window-point chat-window)
                   :start (window-start chat-window)
                   :input-selected (eq (selected-window) input-window)))))))))

(provide 'pilish-submit-gui-tests)
;;; pilish-submit-gui-tests.el ends here
