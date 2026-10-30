;;; pilish-answer-test.el --- Tests for showing the final answer -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `pilish-jump-to-answer': landing on the final answer when a
;; turn ends or the reader arrives, once per answer, and following again
;; on the next turn.

;;; Code:

(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

(defmacro pilish-answer-test--with-chat (&rest body)
  "Run BODY in a chat buffer shown in the only window, `window'.
`pilish-jump-to-answer' is on."
  (declare (indent 0) (debug t))
  `(let ((buffer (generate-new-buffer "*pilish-answer-test*"))
         (pilish-jump-to-answer t))
     (save-window-excursion
       (unwind-protect
           (progn
             (delete-other-windows)
             (switch-to-buffer buffer)
             (pilish-chat-mode)
             (let ((window (selected-window)))
               (ignore window)
               ,@body))
         (kill-buffer buffer)))))

(defun pilish-answer-test--lines (prefix count)
  "Return COUNT lines of text, each starting with PREFIX."
  (mapconcat (lambda (n) (format "%s %d" prefix n))
             (number-sequence 1 count) "\n"))

(defun pilish-answer-test--message (text)
  "Stream one assistant message with TEXT."
  (let ((message `(:role "assistant"
                   :content [(:type "text" :text ,text)])))
    (pilish--handle-display-event `(:type "message_start" :message ,message))
    (pilish-test--send-assistant-message-update
     '(:type "text_start" :contentIndex 0))
    (pilish-test--send-assistant-message-update
     `(:type "text_delta" :contentIndex 0 :delta ,text))
    (pilish-test--send-assistant-message-update
     `(:type "text_end" :contentIndex 0 :content ,text))
    (pilish--handle-display-event `(:type "message_end" :message ,message))
    message))

(defun pilish-answer-test--scroll-back ()
  "Leave the current window at the start of the buffer, not following."
  (let ((inhibit-read-only t))
    (insert "Earlier\n"))
  (goto-char (point-min)))

(defun pilish-answer-test--turn (answer-lines)
  "Run a turn with a long first message and an answer of ANSWER-LINES lines.
Return the start of the answer's first line."
  (pilish--handle-display-event '(:type "agent_start"))
  (pilish-answer-test--message (pilish-answer-test--lines "Working" 60))
  (let ((answer (pilish-answer-test--message
                 (pilish-answer-test--lines "Answer" answer-lines))))
    (pilish--handle-display-event `(:type "agent_end" :messages [,answer])))
  (save-excursion
    (goto-char (point-max))
    (re-search-backward "^Answer 1$")
    (point)))

(ert-deftest pilish-answer-test-lands-following-window ()
  "A following window shows the long final answer from its start."
  (pilish-answer-test--with-chat
    (let ((start (pilish-answer-test--turn 100)))
      (should (= (window-point window) start))
      (should (= (window-start window) start)))))

(ert-deftest pilish-answer-test-short-answer-keeps-following ()
  "An answer visible with the tail does not move the window."
  (pilish-answer-test--with-chat
    (pilish-answer-test--turn 3)
    (should (pilish--window-following-p window))))

(ert-deftest pilish-answer-test-reader-window-stays ()
  "A window scrolled away from the tail is not moved."
  (pilish-answer-test--with-chat
    (pilish--append-to-chat (concat (pilish-answer-test--lines "Old" 50) "\n"))
    (goto-char (point-min))
    (forward-line 10)
    (let ((point (point)))
      (pilish-answer-test--turn 100)
      (should (= (window-point window) point)))))

(ert-deftest pilish-answer-test-off-aborted-or-queued-follow ()
  "Disabled, stopped and immediately continued turns keep following."
  (dolist (setup (list (lambda () (setq-local pilish-jump-to-answer nil))
                       (lambda () (pilish--set-aborted t))
                       (lambda () (pilish--push-followup "next"))))
    (pilish-answer-test--with-chat
      (cl-letf (((symbol-function 'pilish--send-abort) #'ignore))
        (funcall setup)
        (pilish-answer-test--turn 100)
        (should (pilish--window-following-p window))))))

(ert-deftest pilish-answer-test-next-turn-follows-again ()
  "An unmoved landed window follows the next turn; a moved one stays."
  (pilish-answer-test--with-chat
    (pilish-answer-test--turn 100)
    (pilish--handle-display-event '(:type "agent_start"))
    (should (pilish--window-following-p window))
    (should-not pilish--answer-windows))
  (pilish-answer-test--with-chat
    (let ((start (pilish-answer-test--turn 100)))
      (goto-char (+ start 3))
      (pilish--display-user-message "next")
      (should (= (window-point window) (+ start 3))))))

(ert-deftest pilish-answer-test-window-shown-later-lands ()
  "A window showing the chat after the turn ended lands when displayed."
  (pilish-answer-test--with-chat
    (should (memq #'pilish--answer-window-buffer-change
                  window-buffer-change-functions))
    (switch-to-buffer "*scratch*")
    (with-current-buffer buffer
      (let ((start (pilish-answer-test--turn 100)))
        (should-not (assq window pilish--answer-windows))
        (set-window-buffer window buffer)
        (set-window-point window (point-max))
        (pilish--answer-window-buffer-change window)
        (should (= (window-point window) start))))))

(ert-deftest pilish-answer-test-reader-above-moves-forward-on-arrival ()
  "A reader above the answer stays at turn end and lands on arrival, once."
  (pilish-answer-test--with-chat
    (pilish-answer-test--scroll-back)
    (let ((start (pilish-answer-test--turn 100)))
      (should (= (window-point window) 1))
      (pilish--answer-update-live-windows t)
      (should (= (window-point window) start))
      (should (= (window-start window) start))
      (goto-char (point-min))
      (pilish--answer-update-live-windows t)
      (should (= (window-point window) 1)))))

(ert-deftest pilish-answer-test-reader-inside-answer-stays-on-arrival ()
  "A reader inside the answer stays, and the answer does not land later."
  (pilish-answer-test--with-chat
    (pilish-answer-test--scroll-back)
    (let ((start (pilish-answer-test--turn 100)))
      (should (= (window-point window) 1))
      (goto-char (+ start 20))
      (pilish--answer-update-live-windows t)
      (should (= (window-point window) (+ start 20)))
      (goto-char (point-max))
      (pilish--answer-update-live-windows t)
      (should (pilish--window-following-p window)))))

(ert-deftest pilish-answer-test-landed-answer-stays-read ()
  "An answer read to the end does not land again in a new window."
  (pilish-answer-test--with-chat
    (pilish-answer-test--turn 100)
    (goto-char (point-max))
    (let ((other (split-window window)))
      (set-window-point other (point-max))
      (pilish--answer-window-buffer-change other)
      (should (pilish--window-following-p other))
      (should (pilish--window-following-p window)))))

(ert-deftest pilish-answer-test-short-answer-shows-at-end-on-arrival ()
  "A reader above an answer that fits arrives at the following tail."
  (pilish-answer-test--with-chat
    (pilish-answer-test--scroll-back)
    (pilish-answer-test--turn 2)
    (should (= (window-point window) 1))
    (pilish--answer-update-live-windows t)
    (should (pilish--window-following-p window))
    (should-not pilish--answer-windows)))

(ert-deftest pilish-answer-test-selecting-session-is-arrival ()
  "Entering a session lands its answer; the minibuffer is no departure."
  (pilish-answer-test--with-chat
    (pilish-answer-test--scroll-back)
    (let ((start (pilish-answer-test--turn 100))
          (pilish--answer-focused-chat buffer))
      ;; Within the session nothing happens.
      (pilish--answer-selection-change nil)
      (should (= (window-point window) 1))
      ;; Selecting another buffer leaves, coming back arrives.
      (let ((other (split-window window)))
        (set-window-buffer other "*scratch*")
        (select-window other)
        (pilish--answer-selection-change nil)
        (should-not pilish--answer-focused-chat)
        (should (= (window-point window) 1))
        (select-window window)
        (pilish--answer-selection-change nil)
        (should (eq pilish--answer-focused-chat buffer))
        (should (= (window-point window) start))))))

(ert-deftest pilish-answer-test-selection-ignores-minibuffer ()
  "The minibuffer keeps the session it was entered from."
  (pilish-answer-test--with-chat
    (let ((pilish--answer-focused-chat buffer))
      (cl-letf (((symbol-function 'minibufferp) (lambda (&rest _) t)))
        (pilish--answer-selection-change nil))
      (should (eq pilish--answer-focused-chat buffer)))))

(defun pilish-answer-test--history (stop-reason)
  "Replay a long history ending in an answer that stopped with STOP-REASON.
Return the start of the answer's first line."
  (pilish--replay-history
   (current-buffer)
   (vector
    (list :role "user" :content (pilish-answer-test--lines "Asked" 60))
    (list :role "assistant" :stopReason stop-reason
          :content (vector (list :type "text"
                                 :text (pilish-answer-test--lines "Answer" 100))))))
  (save-excursion
    (goto-char (point-max))
    (re-search-backward "^Answer 1$")
    (point)))

(ert-deftest pilish-answer-test-loaded-history-lands ()
  "A session loaded from history lands on its final answer."
  (pilish-answer-test--with-chat
    (let ((start (pilish-answer-test--history "stop")))
      (pilish--answer-history-loaded)
      (should (= (window-point window) start)))))

(ert-deftest pilish-answer-test-unfinished-history-does-not-land ()
  "History ending in a stopped or tool-calling message has no final answer."
  (dolist (stop-reason '("aborted" "error" "toolUse"))
    (pilish-answer-test--with-chat
      (pilish-answer-test--history stop-reason)
      (pilish--answer-history-loaded)
      (should-not pilish--answer-target))))

(ert-deftest pilish-answer-test-history-off-does-not-land ()
  "History loaded with the option off has no final answer to land on."
  (pilish-answer-test--with-chat
    (let ((pilish-jump-to-answer nil))
      (pilish-answer-test--history "stop")
      (pilish--answer-history-loaded)
      (should-not pilish--answer-target))))


(ert-deftest pilish-answer-test-revived-landing-follows-next-turn ()
  "A landed window revived after the next turn started follows the output."
  (pilish-answer-test--with-chat
    (let ((other (split-window window)))
      (pilish-answer-test--turn 100)
      (should (assq other pilish--answer-windows))
      (let ((config (current-window-configuration)))
        (delete-window other)
        (pilish--handle-display-event '(:type "agent_start"))
        (set-window-configuration config)
        (should (window-live-p other))
        (pilish--answer-window-buffer-change other)
        (should (pilish--window-following-p other))
        (should-not pilish--answer-windows)))))

(ert-deftest pilish-answer-test-toggle-off-keeps-landing ()
  "Turning jumping off leaves a landed window in place until the next turn."
  (pilish-answer-test--with-chat
    (let ((start (pilish-answer-test--turn 100)))
      (pilish-toggle-jump-to-answer)
      (should (= (window-point window) start))
      (pilish--handle-display-event '(:type "agent_start"))
      (should (pilish--window-following-p window)))))

(ert-deftest pilish-answer-test-toggle-is-session-local ()
  "Toggling from the input buffer changes only that session's chat."
  (pilish-answer-test--with-chat
    (let ((input (generate-new-buffer "*pilish-answer-input*")))
      (unwind-protect
          (progn
            (with-current-buffer input
              (pilish-input-mode)
              (setq pilish--chat-buffer buffer)
              (should-not (pilish-toggle-jump-to-answer)))
            (should (local-variable-p 'pilish-jump-to-answer buffer))
            (should-not (buffer-local-value 'pilish-jump-to-answer buffer))
            (should (default-value 'pilish-jump-to-answer)))
        (kill-buffer input)))))

(provide 'pilish-answer-test)
;;; pilish-answer-test.el ends here
