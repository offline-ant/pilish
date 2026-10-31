;;; pilish-queue-test.el --- Tests for queued messages above the draft -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers the queue panel and taking queued messages back through
;; `clear_queue', the local follow-up queue and Stop.

;;; Code:

(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

(defmacro pilish-queue-test--with-session (&rest body)
  "Run BODY with an RPC session of CHAT, INPUT, PROC and COMMANDS."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (pilish-test-with-rpc-session (chat input proc commands)
       (ignore chat input proc commands)
       (cl-letf (((symbol-function 'message) #'ignore))
         ,@body))))

(defun pilish-queue-test--panel (input)
  "Return the text above INPUT's draft, or nil."
  (with-current-buffer input
    (when-let* ((overlay pilish--input-preamble-overlay))
      (overlay-get overlay 'before-string))))

(defun pilish-queue-test--snapshot (proc steering followups)
  "Deliver a `queue_update' of STEERING and FOLLOWUPS through PROC."
  (pilish-test--stdout proc (list :type "queue_update"
                                  :steering (vconcat steering)
                                  :followUp (vconcat followups))))

(defun pilish-queue-test--answer (proc commands steering followups)
  "Answer the newest of COMMANDS through PROC with STEERING and FOLLOWUPS."
  (should (equal (plist-get (car commands) :type) "clear_queue"))
  (pilish-test--stdout proc (list :type "response" :command "clear_queue"
                                  :id (plist-get (car commands) :id) :success t
                                  :data (list :steering (vconcat steering)
                                              :followUp (vconcat followups)))))

(defun pilish-queue-test--types (commands)
  "Return the types of COMMANDS, oldest first."
  (reverse (mapcar (lambda (command) (plist-get command :type)) commands)))

;;;; Panel

(ert-deftest pilish-queue-test-panel-follows-both-queues ()
  "Steering and follow-ups show above the draft until they leave."
  (pilish-queue-test--with-session
    (should-not (pilish-queue-test--panel input))
    (pilish-queue-test--snapshot proc ["check Firefox"] ["backend next"])
    (with-current-buffer chat (pilish--push-followup "local next"))
    (with-current-buffer input (insert "my draft"))
    (let ((panel (pilish-queue-test--panel input)))
      (should (string-prefix-p
               "Steering: check Firefox\nFollow-up: backend next\nFollow-up: local next\n↳ "
               panel))
      (should (string-match-p "\\[Restore M-<up>\\] \\[Clear C-c C-u\\]\n\\'" panel)))
    (with-current-buffer input
      (should (equal (buffer-string) "my draft")))
    (with-current-buffer chat (should (equal (pilish--dequeue-followup) "local next")))
    (should-not (string-match-p "local next" (pilish-queue-test--panel input)))
    (pilish-queue-test--snapshot proc [] [])
    (should-not (pilish-queue-test--panel input))))

(ert-deftest pilish-queue-test-panel-is-bounded ()
  "Long and many messages take a bounded number of single lines."
  (pilish-queue-test--with-session
    (pilish-queue-test--snapshot
     proc (vconcat (make-list 6 (concat "two\nlines " (make-string 500 ?x)))) [])
    (let* ((lines (split-string (pilish-queue-test--panel input) "\n" t)))
      (should (= (length lines) (+ pilish--queue-panel-rows 2)))
      (should (equal (nth pilish--queue-panel-rows lines) "+2 more"))
      (should (string-prefix-p "Steering: two lines x" (car lines)))
      (should (<= (length (car lines)) 130)))))

(ert-deftest pilish-queue-test-process-change-and-widgets ()
  "The panel follows the session's process and sits below extension widgets."
  (pilish-queue-test--with-session
    (pilish-queue-test--snapshot proc ["queued"] [])
    (with-current-buffer chat
      (pilish--set-extension-widget "w" '("widget"))
      (should (string-prefix-p "widget\nSteering: queued\n"
                               (pilish-queue-test--panel input)))
      (pilish--set-process nil))
    (should (equal (pilish-queue-test--panel input) "widget\n"))))

(ert-deftest pilish-queue-test-fit-counts-panel ()
  "A `fit' input window makes room for the panel and gives it back."
  (let ((pilish-input-window-height 'fit)
        (pilish-input-window-min-height 3)
        (pilish-input-window-max-height 0.8))
    (pilish-queue-test--with-session
      (delete-other-windows)
      (set-window-buffer (selected-window) chat)
      (let ((input-win (pilish-split-input-window (selected-window) input)))
        (pilish-fit-input-window input-win)
        (let ((height (window-total-height input-win)))
          (pilish-queue-test--snapshot proc ["one"] ["two"])
          (pilish-fit-input-window input-win)
          (should (= (window-total-height input-win) (+ height 3)))
          (pilish-queue-test--snapshot proc [] [])
          (pilish-fit-input-window input-win)
          (should (= (window-total-height input-win) height)))))))

(ert-deftest pilish-queue-test-input-has-no-scroll-margin ()
  "A margin makes text terminals scroll the panel out of a fitted window."
  (let ((scroll-margin 2))
    (with-temp-buffer
      (pilish-input-mode)
      (should (local-variable-p 'scroll-margin))
      (should (zerop scroll-margin)))))

(ert-deftest pilish-queue-test-controls-run-their-commands ()
  "Clicking a control acts on the clicked window's session and keeps point."
  (pilish-queue-test--with-session
    (pilish-queue-test--snapshot proc ["queued"] [])
    (let ((panel (pilish-queue-test--panel input)))
      (dolist (case '(("Restore" . pilish-restore-queued-messages)
                      ("Clear" . pilish-clear-queued-messages)))
        (let ((map (get-text-property (string-search (car case) panel) 'keymap panel)))
          (should (eq (lookup-key map [mouse-1]) (cdr case)))
          (should (eq (lookup-key map [down-mouse-1]) #'ignore)))))
    (delete-other-windows)
    (set-window-buffer (selected-window) input)
    (with-temp-buffer
      (pilish-clear-queued-messages
       (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
    (should (equal (pilish-queue-test--types commands) '("clear_queue")))))

(ert-deftest pilish-queue-test-keys ()
  "Both session buffers bind the commands, like Alt+Up in Pi."
  (dolist (map (list pilish-input-mode-map pilish-chat-mode-map))
    (should (eq (lookup-key map (kbd "M-<up>")) #'pilish-restore-queued-messages))
    (should (eq (lookup-key map (kbd "C-c C-u")) #'pilish-clear-queued-messages))))

;;;; Taking messages back

(ert-deftest pilish-queue-test-restore-orders-text-and-keeps-running ()
  "Restore puts steering, follow-ups and local text before the draft, no abort."
  (pilish-queue-test--with-session
    (with-current-buffer chat
      (setq pilish--status 'streaming)
      (pilish--push-followup "local one")
      (pilish--push-followup "local two"))
    (with-current-buffer input
      (insert "draft")
      (pilish-restore-queued-messages))
    ;; Local text cannot start while Pi answers.
    (with-current-buffer chat (should-not pilish--followup-queue))
    (pilish-queue-test--answer proc commands ["steer"] ["backend"])
    (should (equal (pilish-queue-test--types commands) '("clear_queue")))
    (with-current-buffer input
      (should (equal (buffer-string)
                     "steer\n\nbackend\n\nlocal one\n\nlocal two\n\ndraft"))
      (should (eobp)))
    (with-current-buffer chat (should (eq pilish--status 'streaming)))))

(ert-deftest pilish-queue-test-pi-decides-what-was-removed ()
  "Only text Pi returns is taken: a shown message may have been delivered."
  (pilish-queue-test--with-session
    (pilish-queue-test--snapshot proc ["delivered" "still queued"] [])
    (with-current-buffer input (pilish-restore-queued-messages))
    (pilish-queue-test--answer proc commands ["still queued"] [])
    (with-current-buffer input
      (should (equal (buffer-string) "still queued")))))

(ert-deftest pilish-queue-test-clear-keeps-draft-and-kill-ring ()
  "Clear leaves the draft alone and keeps the discarded text in the kill ring."
  (pilish-queue-test--with-session
    (with-current-buffer chat (pilish--push-followup "local"))
    (with-current-buffer input
      (insert "draft")
      (let ((kill-ring nil))
        (pilish-clear-queued-messages)
        (pilish-queue-test--answer proc commands ["steer"] [])
        (should (equal (car kill-ring) "steer\n\nlocal"))
        (should (equal (buffer-string) "draft"))))
    (should (equal (pilish-queue-test--types commands) '("clear_queue")))
    (with-current-buffer chat (should-not pilish--followup-queue))))

(ert-deftest pilish-queue-test-submitted-followup-stays ()
  "A follow-up submitted as a prompt stays; those behind it are taken."
  (dolist (outcome '(accept reject))
    (pilish-queue-test--with-session
      (with-current-buffer chat
        (pilish--push-followup "submitted")
        (pilish--push-followup "behind")
        (pilish--process-followup-queue))
      (let ((prompt (car commands)))
        (with-current-buffer input (pilish-restore-queued-messages))
        (pilish-queue-test--answer proc commands [] [])
        (with-current-buffer input (should (equal (buffer-string) "behind")))
        (with-current-buffer chat
          (should (equal pilish--followup-queue '("submitted"))))
        (pilish-test--stdout
         proc (list :type "response" :command "prompt" :id (plist-get prompt :id)
                    :success (if (eq outcome 'accept) t :false) :error "rejected")))
      (with-current-buffer chat (should-not pilish--followup-queue))
      (with-current-buffer input
        (should (equal (buffer-string)
                       (if (eq outcome 'accept) "behind" "submitted\n\nbehind")))))))

(ert-deftest pilish-queue-test-accepted-followup-frees-the-next ()
  "After acceptance the new oldest follow-up can be taken."
  (pilish-queue-test--with-session
    (with-current-buffer chat
      (pilish--push-followup "submitted")
      (pilish--push-followup "behind")
      (pilish--process-followup-queue))
    (pilish-test--stdout
     proc (list :type "response" :command "prompt"
                :id (plist-get (car commands) :id) :success t))
    (with-current-buffer chat
      (should (equal (pilish--take-unsubmitted-followups) '("behind")))
      (should-not pilish--followup-queue))))

(ert-deftest pilish-queue-test-rejected-clear-keeps-pi-queue ()
  "A failed `clear_queue' reports it and keeps the local text safe."
  (pilish-queue-test--with-session
    (with-current-buffer chat (pilish--push-followup "local"))
    (let (notices)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) notices))))
        (with-current-buffer input (pilish-restore-queued-messages))
        (pilish-test--stdout
         proc (list :type "response" :command "clear_queue" :success :false
                    :id (plist-get (car commands) :id) :error "nope")))
      (should (equal (car notices) "Pi: Pi kept its queued messages: nope")))
    (with-current-buffer input (should (equal (buffer-string) "local")))))

(ert-deftest pilish-queue-test-without-process-takes-local-text ()
  "Without a live process the local queue is still taken back."
  (pilish-queue-test--with-session
    (with-current-buffer chat
      (pilish--push-followup "local")
      (setq pilish--process nil))
    (with-current-buffer input (pilish-restore-queued-messages))
    (should-not commands)
    (with-current-buffer input (should (equal (buffer-string) "local")))))

(ert-deftest pilish-queue-test-refuses-during-session-switch ()
  "A session switch keeps queues as they are."
  (pilish-queue-test--with-session
    (with-current-buffer chat
      (pilish--push-followup "local")
      (setq pilish--session-transition-active t))
    (with-current-buffer input (pilish-restore-queued-messages))
    (should-not commands)
    (with-current-buffer chat
      (should (equal pilish--followup-queue '("local")))
      (setq pilish--session-transition-active nil))))

(ert-deftest pilish-queue-test-nothing-queued ()
  "An empty queue says so and leaves the draft."
  (let (notices)
    (pilish-queue-test--with-session
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) notices))))
        (with-current-buffer input
          (insert "draft")
          (pilish-restore-queued-messages))
        (pilish-queue-test--answer proc commands [] []))
      (with-current-buffer input (should (equal (buffer-string) "draft"))))
    (should (equal (car notices) "Pi: No queued messages"))))

(ert-deftest pilish-queue-test-stop-restores-queued-text ()
  "Stop returns queued text to the draft, like Escape in Pi."
  (pilish-queue-test--with-session
    (with-current-buffer chat
      (setq pilish--status 'streaming)
      (pilish--push-followup "local"))
    (with-current-buffer input
      (insert "draft")
      (pilish-abort))
    (should (equal (pilish-queue-test--types commands) '("clear_queue" "abort")))
    (let ((commands (cdr commands)))
      (pilish-queue-test--answer proc commands ["steer"] ["backend"]))
    (with-current-buffer input
      (should (equal (buffer-string) "steer\n\nbackend\n\nlocal\n\ndraft")))
    (with-current-buffer chat (should-not pilish--followup-queue))))

(provide 'pilish-queue-test)
;;; pilish-queue-test.el ends here
