;;; pilish-answer-gui-tests.el --- Focus positioning journeys -*- lexical-binding: t; -*-

;;; Commentary:

;; Fake-backed user actions through real buffers, window selection hooks and
;; the session-local toggle.  Completion has its existing separate GUI journey.

;;; Code:

(require 'ert)
(require 'pilish-gui-test-utils)

(declare-function pilish-gui-test--large-evidence "pilish-gui-tests" (name state))

(defun pilish-answer-gui-test--switch-buffer (buffer)
  "Switch to BUFFER with the ordinary buffer command and its command loop."
  (execute-kbd-macro
   (vconcat (kbd "C-x b") (string-to-vector (buffer-name buffer)) (kbd "RET")))
  (redisplay t))

(ert-deftest pilish-gui-test-answer-focus-respects-toggle ()
  "Returning to a session revisits its final answer only with jumping enabled."
  (let ((pilish-jump-to-answer t))
    (pilish-gui-test-with-fresh-session
      (:backend fake :fake-scenario "tool-long-answer")
      (pilish-gui-test-send "focus answer")
      (let* ((chat (plist-get pilish-gui-test--session :chat-buffer))
             (input (plist-get pilish-gui-test--session :input-buffer))
             (window (pilish-gui-test-chat-window))
             (input-window (pilish-gui-test-input-window))
             (elsewhere (generate-new-buffer " *pilish-focus-elsewhere*"))
             (answer (with-current-buffer chat
                       (save-excursion
                         (goto-char (point-max))
                         (re-search-backward "^Answer line 01$")
                         (point)))))
        (unwind-protect
            (progn
              (select-window input-window)
              (redisplay t)
              (dolist (enabled '(t nil))
                (unless enabled
                  (with-current-buffer input
                    (call-interactively #'pilish-toggle-jump-to-answer)))
                (with-selected-window window
                  (goto-char (point-min))
                  (set-window-start window (point-min)))
                (redisplay t)
                ;; A different selected buffer departs; returning to the input
                ;; enters the session without directly calling its jump hook.
                (pilish-answer-gui-test--switch-buffer elsewhere)
                (pilish-answer-gui-test--switch-buffer input)
                (should (eq (selected-window) input-window))
                (should (= (window-point window) (if enabled answer 1)))
                (should (= (window-start window) (if enabled answer 1)))
                (pilish-gui-test--large-evidence
                 (if enabled "answer-focus-on" "answer-focus-off")
                 (list :enabled enabled :answer-start answer
                       :window-point (window-point window)
                       :window-start (window-start window)))
                ;; Reading within the same session must not jump again.
                (select-window window)
                (goto-char 1)
                (set-window-start window 1)
                (redisplay t)
                (select-window input-window)
                (redisplay t)
                (should (= (window-point window) 1))))
          (kill-buffer elsewhere))))))

(ert-deftest pilish-gui-test-answer-focus-follows-active-output ()
  "Focusing accepted active work returns its scrolled-back view to the tail."
  (let ((pilish-jump-to-answer t)
        (pilish-jump-to-end-on-submit nil))
    (pilish-gui-test-with-fresh-session
      (:backend fake :fake-scenario "tool-long-answer")
      (pilish-gui-test-send "first answer")
      (let* ((input (plist-get pilish-gui-test--session :input-buffer))
             (window (pilish-gui-test-chat-window))
             (input-window (pilish-gui-test-input-window))
             (elsewhere (generate-new-buffer " *pilish-focus-active*")))
        (unwind-protect
            (progn
              (select-window input-window)
              (with-selected-window window
                (goto-char 1)
                (set-window-start window 1))
              (pilish-gui-test-send "active answer" t)
              (should (with-current-buffer (window-buffer window)
                        (pilish--session-busy-p)))
              (should (= (window-point window) 1))
              (pilish-answer-gui-test--switch-buffer elsewhere)
              (pilish-answer-gui-test--switch-buffer input)
              (should (pilish-gui-test-window-point-at-end-p))
              (should (eq (selected-window) input-window))
              (pilish-gui-test--large-evidence
               "answer-focus-active"
               (list :window-point (window-point window)
                     :point-max (with-current-buffer (window-buffer window)
                                  (point-max))))
              (should (pilish-gui-test-wait-for-idle)))
          (kill-buffer elsewhere))))))

(provide 'pilish-answer-gui-tests)
;;; pilish-answer-gui-tests.el ends here
