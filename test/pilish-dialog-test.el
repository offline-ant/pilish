;;; pilish-dialog-test.el --- Dialog contracts -*- lexical-binding: t; -*-

(require 'pilish)
(require 'pilish-test-common)

(ert-deftest pilish-test-abort-clears-backend-before-aborting ()
  (let ((dir (pilish-test--make-temp-directory "pi-clear-queue-")))
    (unwind-protect
        (pilish-test-with-mock-session dir
          (let* ((chat (get-buffer (pilish-test--chat-buffer-name dir)))
                 (input (pilish-session-input-buffer chat))
                 (process (make-pipe-process :name "pilish-abort-test" :noquery t))
                 commands editor)
            (with-current-buffer chat
              (pilish--set-process process)
              (setq pilish--status 'streaming))
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'pilish--send-extension-ui-response)
                       (lambda (_ response)
                         (should (plist-get response :cancelled))
                         (push "editor-cancel" commands)))
                      ((symbol-function 'pilish--rpc-async)
                       (lambda (_ command callback)
                         (push (plist-get command :type) commands)
                         (funcall callback '(:success t))))
                      ((symbol-function 'message) #'ignore))
              (process-put process 'pilish-chat-buffer chat)
              (with-current-buffer chat
                (pilish--handle-extension-ui-request
                 '(:type "extension_ui_request" :id "cancel-with-abort"
                   :method "editor" :title "Edit")))
              (setq editor (plist-get (car (pilish-session-pending-dialogs chat))
                                      :pilish-editor))
              (should (buffer-live-p editor))
              (with-current-buffer input
                (insert "draft")
                (pilish-abort)
                (should-not (buffer-live-p editor))
                (should (equal (reverse commands) '("clear_queue" "editor-cancel" "abort")))
                ;; Aborting never rewrites the human draft.
                (should (equal (buffer-string) "draft"))))))
      (delete-directory dir t))))

(defun pilish-test--open-editor (process id &optional prefill)
  "Ask PROCESS's editor request ID with PREFILL; return the editor buffer."
  (pilish--handle-extension-dialog
   (list :type "extension_ui_request" :id id :method "editor" :title id
         :prefill prefill)
   process)
  (plist-get (pilish--extension-dialog-request process id) :pilish-editor))

(ert-deftest pilish-test-editor-separate-buffer-and-cancel-on-kill ()
  (let ((process (make-pipe-process :name "pilish-dialog-test" :noquery t))
        responses editor)
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'pilish--send-extension-ui-response)
                   (lambda (_ response) (push response responses))))
          (with-temp-buffer
            (insert "parent draft")
            (setq editor (pilish-test--open-editor process "editor-1" "line1\nline2"))
            (should (string-prefix-p "*pilish-editor: " (buffer-name editor)))
            (should (equal (buffer-string) "parent draft"))
            (with-current-buffer editor
              (should (equal (buffer-string) "line1\nline2"))
              (pilish-editor-submit))
            ;; Submitting closes the request, which kills its editor.
            (should-not (buffer-live-p editor))
            (should (= (length responses) 1))
            (should (equal (plist-get (car responses) :value) "line1\nline2"))
            (should-not (pilish--extension-dialog-pending process))
            (setq editor (pilish-test--open-editor process "editor-2"))
            (kill-buffer editor)
            (should (= (length responses) 2))
            (should (plist-get (car responses) :cancelled))
            (should-not (pilish--extension-dialog-pending process))))
      (when (buffer-live-p editor) (kill-buffer editor))
      (delete-process process))))

(ert-deftest pilish-test-editor-cleanup-is-process-owned ()
  (let ((one (make-pipe-process :name "pilish-editor-one" :noquery t
                                :sentinel #'pilish--process-sentinel))
        (two (make-pipe-process :name "pilish-editor-two" :noquery t))
        editor-one editor-two responses)
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'pilish--send-extension-ui-response)
                   (lambda (process response) (push (cons process response) responses))))
          (setq editor-one (pilish-test--open-editor one "one")
                editor-two (pilish-test--open-editor two "two"))
          ;; An exited process takes no answer: its editor just closes.
          (delete-process one)
          (should-not (buffer-live-p editor-one))
          (should (buffer-live-p editor-two))
          (should-not responses)
          (pilish--cancel-process-dialogs two)
          (should-not (buffer-live-p editor-two))
          (should (eq (caar responses) two))
          (should (plist-get (cdar responses) :cancelled))
          (should-not (pilish--extension-dialog-pending two))
          (should (process-live-p two)))
      (when (buffer-live-p editor-one) (kill-buffer editor-one))
      (when (buffer-live-p editor-two) (kill-buffer editor-two))
      (when (process-live-p one) (delete-process one))
      (delete-process two))))

;;;; Pending dialog registry

(defmacro pilish-test--with-dialog-session (bindings &rest body)
  "Run BODY with a chat buffer owning a pipe process, binding BINDINGS.
BINDINGS names (CHAT PROCESS EVENTS RESPONSES) variables; EVENTS records
dialog hook calls as (ID STATE) and RESPONSES records sent responses."
  (declare (indent 1))
  (let ((chat (nth 0 bindings)) (process (nth 1 bindings))
        (events (nth 2 bindings)) (responses (nth 3 bindings)))
    `(let* ((,chat (generate-new-buffer "*pilish-dialog-registry*"))
            (,process (make-pipe-process :name "pilish-dialog-registry" :noquery t
                                         :sentinel #'pilish--process-sentinel))
            (,events nil) (,responses nil)
            (pilish-extension-dialog-functions
             (list (lambda (buffer request state)
                     (should (eq buffer ,chat))
                     (push (list (plist-get request :id) state) ,events)))))
       (unwind-protect
           (cl-letf (((symbol-function 'pilish--send-extension-ui-response)
                      (lambda (_ response) (push response ,responses)))
                     ((symbol-function 'pop-to-buffer) #'ignore)
                     ((symbol-function 'message) #'ignore))
             (process-put ,process 'pilish-chat-buffer ,chat)
             (with-current-buffer ,chat
               (pilish-chat-mode)
               (setq pilish--process ,process))
             ,@body)
         (when (process-live-p ,process) (delete-process ,process))
         (kill-buffer ,chat)))))

(ert-deftest pilish-test-dialog-registry-reports-immediate-confirm ()
  (pilish-test--with-dialog-session (chat process events responses)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_prompt)
                 (should (equal (mapcar (lambda (r) (plist-get r :id))
                                        (pilish-session-pending-dialogs chat))
                                '("c1")))
                 t)))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "c1" :method "confirm"
           :title "Go?" :message "Sure"))))
    (should (equal (reverse events) '(("c1" open) ("c1" close))))
    (should (eq (plist-get (car responses) :confirmed) t))
    (should-not (pilish-session-pending-dialogs chat))))

(ert-deftest pilish-test-dialog-minibuffer-style-answers-and-quit-cancels ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'minibuffer) (answer "b"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (should (pilish-session-pending-dialogs chat))
                   (if (eq answer 'quit) (signal 'quit nil) answer))))
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "s1" :method "select"
             :title "Pick" :options ["a" "b"]))
          (should (equal (plist-get (car responses) :value) "b"))
          (should (equal (reverse events) '(("s1" open) ("s1" close))))
          ;; Quitting the prompt cancels the request (upstream's contract).
          (setq answer 'quit)
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "s2" :method "select"
             :title "Pick" :options ["a" "b"]))
          (should (equal (car responses)
                         '(:type "extension_ui_response" :id "s2" :cancelled t)))
          (should (equal (car events) '("s2" close)))
          (should-not (pilish-test--dialog-widget-p "s1"))))
      (should-not (pilish-session-pending-dialogs chat))
      (should-error (pilish-answer-dialog chat) :type 'user-error))))

(ert-deftest pilish-test-dialog-inline-editor-and-cancel ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline) displayed)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _) (push buffer displayed))))
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "e1" :method "editor"
             :title "Edit" :prefill "text"))
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "i1" :method "input" :title "Name")))
        (should-not displayed)
        (pilish-answer-dialog chat)
        (should (= (length displayed) 1))
        (with-current-buffer (car displayed)
          (should (equal (buffer-string) "text")))
        (pilish-cancel-dialog chat)
        (should (plist-get (car responses) :cancelled))
        (should-not (buffer-live-p (car displayed)))
        (with-current-buffer chat
          (should-not (pilish-test--dialog-widget-p "e1"))
          (should (pilish-test--dialog-widget-p "i1")))
        (should (equal (mapcar (lambda (r) (plist-get r :id))
                               (pilish-session-pending-dialogs chat))
                       '("i1")))))))

(ert-deftest pilish-test-dialog-process-exit-closes-pending ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "x1" :method "confirm"
           :title "Go?" :message "")))
      (delete-process process)
      (should (equal (car events) '("x1" close)))
      (should-not (pilish-session-pending-dialogs chat))
      (with-current-buffer chat
        (should (equal (buffer-string) "")))
      (should-not responses))))

;;;; Inline dialog widgets

(defun pilish-test--dialog-widget-p (id)
  "Return non-nil when the current buffer shows the widget of request ID."
  (let ((position (point-min)) found)
    (while (and (not found) position (< position (point-max)))
      (setq found (equal (get-text-property position 'pilish-dialog) id)
            position (next-single-property-change position 'pilish-dialog)))
    found))

(defun pilish-test--press (chat position)
  "Press the inline dialog button at POSITION in CHAT."
  (with-current-buffer chat (push-button position)))

(defun pilish-test--dialog-choice (chat label)
  "Return the start of the inline choice whose text contains LABEL in CHAT."
  (with-current-buffer chat
    (save-excursion
      (goto-char (point-min))
      (let (found)
        (while (and (not found) (search-forward label nil t))
          (when (get-text-property (match-beginning 0) 'pilish-dialog-choice)
            (setq found (button-start (button-at (match-beginning 0))))))
        found))))

(defun pilish-test--dialog-key (chat position key)
  "Run the command bound to KEY at POSITION in CHAT, as typed."
  (with-current-buffer chat
    (goto-char position)
    (let* ((event (aref (kbd key) 0))
           (last-command-event event)
           (command (key-binding (kbd key))))
      (call-interactively command))))

(ert-deftest pilish-test-dialog-inline-select-click-keeps-draft ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline)
          (input (generate-new-buffer "*pilish-dialog-input*")))
      (unwind-protect
          (progn
            (with-current-buffer input (insert "my draft"))
            (with-current-buffer chat
              (setq pilish--input-buffer input)
              (let ((inhibit-read-only t)) (insert "Earlier reply.\n"))
              (pilish--handle-extension-ui-request
               '(:type "extension_ui_request" :id "s1" :method "select"
                 :title "(1/2) Which option?" :options ["A — first" "B"]))
              (should (string-match-p "◉ Pi asks: (1/2) Which option?" (buffer-string)))
              (should (string-prefix-p "Earlier reply.\n\n" (buffer-string)))
              ;; Clicking is pressing the button: no minibuffer, no draft change.
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) (error "Inline answers never prompt"))))
                (push-button (pilish-test--dialog-choice chat "B")))
              (should (equal (plist-get (car responses) :value) "B"))
              (should (equal (buffer-string) "Earlier reply.\n"))
              (should (equal (car events) '("s1" close))))
            (with-current-buffer input (should (equal (buffer-string) "my draft"))))
        (kill-buffer input)))))

(ert-deftest pilish-test-dialog-inline-keys-confirm-and-cancel ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "s1" :method "select"
           :title "Pick" :options ["a" "b" "c"])))
      (let ((first (pilish-test--dialog-choice chat "a")))
        ;; TAB moves between choices and wraps through Cancel.
        (pilish-test--dialog-key chat first "TAB")
        (with-current-buffer chat
          (should (eq (get-text-property (point) 'pilish-dialog-choice) 1)))
        (pilish-test--dialog-key chat first "<backtab>")
        (with-current-buffer chat
          (should (eq (get-text-property (point) 'pilish-dialog-choice) 3)))
        ;; Digit keys work anywhere on the widget.
        (should-error (pilish-test--dialog-key chat first "4") :type 'user-error)
        (pilish-test--dialog-key chat first "3"))
      (should (equal (plist-get (car responses) :value) "c"))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "c1" :method "confirm"
           :title "Delete?" :message "It is gone afterwards.")))
      (should (string-match-p "It is gone afterwards." (with-current-buffer chat (buffer-string))))
      (pilish-test--dialog-key chat (pilish-test--dialog-choice chat "No") "y")
      (should (eq (plist-get (car responses) :confirmed) t))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "c2" :method "confirm" :title "Again?" :message "")))
      (pilish-test--dialog-key chat (pilish-test--dialog-choice chat "Yes") "RET")
      (should (eq (plist-get (car responses) :confirmed) t))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "c3" :method "confirm" :title "Third?" :message "")))
      (pilish-test--dialog-key chat (pilish-test--dialog-choice chat "Yes") "C-c C-k")
      (should (equal (car responses) '(:type "extension_ui_response" :id "c3" :cancelled t)))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "i1" :method "input" :title "Name"
           :placeholder "nick")))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &rest _)
                   (should (equal prompt "Name (nick) "))
                   "Ada")))
        (pilish-test--press chat (pilish-test--dialog-choice chat "Type an answer")))
      (should (equal (plist-get (car responses) :value) "Ada"))
      (with-current-buffer chat (should (equal (buffer-string) ""))))))

(ert-deftest pilish-test-dialog-inline-survives-fontification ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "s1" :method "select"
           :title "Use `code` or **bold**?" :options ["`a`" "*b*"]))
        (font-lock-ensure)
        (let ((choice (pilish-test--dialog-choice chat "`a`")))
          (should choice)
          (goto-char choice)
          (should (equal (buffer-substring-no-properties choice (line-end-position))
                         "1 `a`"))
          (should-not (text-property-not-all choice (line-end-position) 'invisible nil))
          (should (memq 'pilish-dialog-choice
                        (ensure-list (get-text-property (+ choice 2) 'face))))
          (should (eq (get-char-property choice 'keymap) pilish-dialog-widget-map)))))))

(ert-deftest pilish-test-dialog-inline-follow-up-takes-focus ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline) displayed)
      (set-window-buffer (selected-window) chat)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _) (push buffer displayed))))
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "q1" :method "select"
             :title "(1/2) First?" :options ["x" "Other (type your own)"])))
        (pilish-test--press chat (pilish-test--dialog-choice chat "Other"))
        ;; The editor that follows an answer is displayed immediately.
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "e1" :method "editor" :title "Enter your response")))
        (should (= (length displayed) 1))
        (with-current-buffer (car displayed)
          (insert "typed")
          (pilish--editor-respond nil))
        (should (equal (plist-get (car responses) :value) "typed"))
        ;; The next question takes point in the chat window.
        (with-current-buffer chat (goto-char (point-min)))
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "q2" :method "select"
             :title "(2/2) Second?" :options ["y"])))
        (should (eq (window-buffer (selected-window)) chat))
        (should (= (window-point) (pilish-test--dialog-choice chat "y")))
        ;; Asking the same question again keeps point on the chosen entry.
        (pilish-test--press chat (pilish-test--dialog-choice chat "y"))
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "m1" :method "select"
             :title "Toggle?" :options ["[ ] a" "[ ] b" "Done"])))
        (pilish-test--press chat (pilish-test--dialog-choice chat "[ ] b"))
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "m2" :method "select"
             :title "Toggle?" :options ["[ ] a" "[x] b" "Done"])))
        (should (= (window-point) (pilish-test--dialog-choice chat "[x] b")))
        ;; Without a recent answer a new dialog never moves point.
        (process-put process 'pilish-dialog-followup nil)
        (pilish-cancel-dialog chat)
        (with-current-buffer chat
          (let ((inhibit-read-only t)) (insert "Earlier reply.\n"))
          (goto-char (point-min)))
        (set-window-point (selected-window) (point-min))
        (with-current-buffer chat
          (pilish--handle-extension-ui-request
           '(:type "extension_ui_request" :id "q3" :method "select"
             :title "Later?" :options ["z"])))
        (should (= (window-point) (point-min)))))))

(ert-deftest pilish-test-dialog-inline-timeout-and-run-end ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "t1" :method "confirm"
           :title "Quick?" :message "" :timeout 50))
        (should (string-match-p "expires in 0s" (buffer-string))))
      (should (with-timeout (2 nil)
                (while (pilish-session-pending-dialogs chat) (accept-process-output nil 0.02))
                t))
      ;; Pi already resolved the expired request: nothing is sent.
      (should-not responses)
      (with-current-buffer chat
        (should (equal (buffer-string) ""))
        (setq pilish--status 'streaming)
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "run" :method "select" :title "Run?" :options ["a"]))
        (setq pilish--status 'idle))
      ;; A run ending does not settle a dialog; Stop cancels it.
      (should (equal (mapcar (lambda (r) (plist-get r :id)) (pilish-session-pending-dialogs chat))
                     '("run")))
      (pilish--cancel-process-dialogs process)
      (should (equal (car responses) '(:type "extension_ui_response" :id "run" :cancelled t)))
      (with-current-buffer chat
        (should-not (pilish-test--dialog-widget-p "run"))))))

(ert-deftest pilish-test-dialog-inline-stays-below-later-output ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (let ((inhibit-read-only t)) (insert "Reply.\n"))
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "s1" :method "select"
           :title "Pick" :options ["a" "b"]))
        (goto-char (pilish-test--dialog-choice chat "b"))
        (set-window-point (selected-window) (point))
        (pilish--append-to-chat "Later output.\n")
        (should pilish--dialog-reanchor-timer)
        (pilish--dialog-reanchor chat)
        (should-not pilish--dialog-reanchor-timer)
        ;; The question is last again, with point still on the chosen row.
        (should (string-match-p "Later output\\.\n\n◉ Pi asks: Pick" (buffer-string)))
        (should (string-suffix-p "C-c C-k cancels\n" (buffer-string)))
        (should (= (window-point) (pilish-test--dialog-choice chat "b")))
        (pilish-test--press chat (pilish-test--dialog-choice chat "a"))
        (should (equal (plist-get (car responses) :value) "a"))
        (should (equal (buffer-string) "Reply.\nLater output.\n"))))))

(ert-deftest pilish-test-dialog-header-shows-pending ()
  (pilish-test--with-dialog-session (chat process events responses)
    (let ((pilish-extension-dialog-style 'inline))
      (should-not (pilish--header-format-dialog chat))
      (with-current-buffer chat
        (pilish--handle-extension-ui-request
         '(:type "extension_ui_request" :id "s1" :method "select"
           :title "100% sure?\nmore" :options ["a"])))
      (let ((segment (pilish--header-format-dialog chat)))
        (should (string-match-p "◉ answer: 100%% sure\\?\\'" segment))
        (should (get-text-property 3 'local-map segment))))))

(ert-deftest pilish-test-dialog-commands-are-bound ()
  "Chat and input buffers reach the pending-dialog commands by key."
  (dolist (map (list pilish-chat-mode-map pilish-input-mode-map))
    (should (eq (lookup-key map (kbd "C-c C-a")) #'pilish-answer-dialog))
    (should (eq (lookup-key map (kbd "C-c C-x")) #'pilish-cancel-dialog))))

(provide 'pilish-dialog-test)
;;; pilish-dialog-test.el ends here
