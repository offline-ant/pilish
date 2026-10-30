;;; pilish-dialog.el --- Extension dialogs: pending requests, editors, inline widgets -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Pi extensions ask the user through confirm, select, input, and editor
;; requests.  This module owns them from request to answer:
;;
;; - Pending requests are tracked per process and reported to
;;   `pilish-extension-dialog-functions', so integrations can show which
;;   sessions are blocked on the user.
;; - Editor requests open a dedicated multiline buffer; the prompt draft is
;;   never reused.
;; - `pilish-extension-dialog-style' selects how the other requests ask:
;;   upstream's minibuffer prompts, or `inline' widgets at the end of the
;;   chat buffer whose choices are buttons (mouse clicks, RET and digit keys
;;   answer, C-c C-k cancels).
;;
;; Pi never reports requests it settles itself.  A request closes when it is
;; answered, cancelled, expires (its own timeout), its session is stopped
;; (`pilish-abort' cancels pending requests before aborting), a new run
;; starts (agent_start cancels older requests), or its process exits.

;;; Code:

(require 'pilish-ui)
(require 'button)

(declare-function pilish--render-safe-string "pilish-render" (value &optional nil-value))
(declare-function pilish--extension-ui-confirm "pilish-render" (event proc))
(declare-function pilish--extension-ui-select "pilish-render" (event proc))
(declare-function pilish--extension-ui-input "pilish-render" (event proc))

(defcustom pilish-extension-dialog-style 'minibuffer
  "How extension confirm, select, and input dialogs ask the user.
`minibuffer' prompts in the minibuffer as soon as Pi requests an answer.
`inline' never interrupts: the request waits as a widget at the end of its
chat buffer, answered by clicking a choice, RET, or a digit key there, or
reached with `pilish-answer-dialog'.  Editor requests open an editor buffer
in both styles; inline, it is displayed when reached from its widget.  The
next dialog of a multi-step flow answered from a widget takes focus in the
same window.  Pending requests are reported to
`pilish-extension-dialog-functions' in both styles."
  :type '(choice (const :tag "Prompt in the minibuffer" minibuffer)
                 (const :tag "Inline widget in the chat buffer" inline))
  :group 'pilish)

;;;; Pending requests

(defvar-local pilish--dialog-process nil
  "Pi process that owns this editor request.")
(defvar-local pilish--dialog-id nil
  "Unanswered RPC editor request ID, or nil after responding.")
(defvar-local pilish--editor-dying nil
  "Non-nil while this editor buffer is being killed.")

(defvar pilish-extension-dialog-functions nil
  "Functions called when an extension dialog starts or stops awaiting the user.
Each function receives CHAT-BUFFER, REQUEST, and STATE.  REQUEST is the
`extension_ui_request' event plist (with :id, :method, and :title) of a
confirm, select, input, or editor dialog.  STATE is `open' when Pi starts
waiting for the answer and `close' once the request was answered, cancelled,
expired, or abandoned because its process exited.  CHAT-BUFFER may be nil
or dead during teardown.  Errors are reported as warnings and never break
dispatch.")

(defun pilish--run-extension-dialog-functions (process request state)
  "Run `pilish-extension-dialog-functions' for PROCESS, REQUEST and STATE."
  (let ((chat-buffer (process-get process 'pilish-chat-buffer)))
    (dolist (function pilish-extension-dialog-functions)
      (condition-case-unless-debug err
          (funcall function chat-buffer request state)
        (error
         (display-warning
          'pilish
          (format "Extension dialog function %S failed: %s"
                  function (error-message-string err))
          :error))))))

(defun pilish--extension-dialog-pending (process)
  "Return the extension dialog requests of PROCESS awaiting the user, oldest first."
  (and (processp process) (process-get process 'pilish-pending-dialogs)))

(defun pilish-session-pending-dialogs (chat-buffer)
  "Return extension dialog requests awaiting the user in CHAT-BUFFER.
Each request is its `extension_ui_request' plist, oldest first.  See
`pilish-extension-dialog-functions' and `pilish-answer-dialog'."
  (when (buffer-live-p chat-buffer)
    (pilish--extension-dialog-pending
     (buffer-local-value 'pilish--process chat-buffer))))

(defun pilish--extension-dialog-request (process id)
  "Return the pending request ID of PROCESS, or nil."
  (cl-find id (pilish--extension-dialog-pending process)
           :key (lambda (request) (plist-get request :id))
           :test #'equal))

(defun pilish--extension-dialog-open (process event)
  "Record dialog EVENT of PROCESS as awaiting the user; return the request.
The request is EVENT plus Pilish's bookkeeping: the timer that forgets it
when its :timeout expires (Pi then settles it itself).  Without a process
object nobody can answer, so EVENT is returned unrecorded."
  (if (not (processp process))
      event
    (let* ((timeout (plist-get event :timeout))
           (request (append event
                            (when (and (numberp timeout) (> timeout 0))
                              (list :pilish-timer
                                    (run-at-time (/ timeout 1000.0) nil
                                                 #'pilish--extension-dialog-close
                                                 process (plist-get event :id)))))))
      (process-put process 'pilish-pending-dialogs
                   (append (pilish--extension-dialog-pending process) (list request)))
      (pilish--run-extension-dialog-functions process request 'open)
      request)))

(defun pilish--extension-dialog-set (process id property value)
  "Set PROPERTY of pending request ID of PROCESS to VALUE."
  (when-let* ((request (pilish--extension-dialog-request process id)))
    (process-put process 'pilish-pending-dialogs
                 (mapcar (lambda (entry)
                           (if (eq entry request)
                               (plist-put (copy-sequence entry) property value)
                             entry))
                         (pilish--extension-dialog-pending process)))))

(defun pilish--extension-dialog-close (process id)
  "Forget pending request ID of PROCESS, removing its widget and editor.
Sends nothing; responding is the caller's business."
  (when-let* ((request (pilish--extension-dialog-request process id)))
    (process-put process 'pilish-pending-dialogs
                 (delq request (pilish--extension-dialog-pending process)))
    (when-let* ((timer (plist-get request :pilish-timer)))
      (cancel-timer timer))
    (pilish--dialog-widget-remove process id)
    (when-let* ((editor (plist-get request :pilish-editor))
                ((buffer-live-p editor))
                ((not (buffer-local-value 'pilish--editor-dying editor))))
      (with-current-buffer editor
        (setq pilish--dialog-id nil))   ; already settled: no cancel on kill
      (dolist (window (get-buffer-window-list editor nil t))
        (quit-window nil window))
      (kill-buffer editor))
    (pilish--run-extension-dialog-functions process request 'close)))

(defun pilish--close-process-dialogs (process)
  "Forget every request of PROCESS, which exited and can take no answer."
  (dolist (request (pilish--extension-dialog-pending process))
    (pilish--extension-dialog-close process (plist-get request :id))))

(add-hook 'pilish--process-exit-functions #'pilish--close-process-dialogs)

(defun pilish--extension-dialog-respond (process request tail)
  "Close REQUEST of PROCESS and send response plist TAIL when PROCESS lives."
  (pilish--extension-dialog-close process (plist-get request :id))
  (when (process-live-p process)
    (pilish--send-extension-ui-response
     process (append (list :type "extension_ui_response" :id (plist-get request :id))
                     tail))))

(defun pilish--cancel-dialog-request (process request)
  "Cancel REQUEST of PROCESS."
  (pilish--extension-dialog-respond process request '(:cancelled t)))

(defun pilish--cancel-process-dialogs (process)
  "Cancel every request of PROCESS awaiting the user.
`pilish-abort' calls this before aborting: an editor request has no abort
signal in Pi, so only its cancellation lets the waiting tool settle."
  (dolist (request (pilish--extension-dialog-pending process))
    (pilish--cancel-dialog-request process request)))

;;;; Dispatch and commands

(defun pilish--handle-extension-dialog (event proc)
  "Register the dialog EVENT owned by PROC and ask the user.
Editor requests open an editor buffer; the others follow
`pilish-extension-dialog-style'."
  (let ((request (pilish--extension-dialog-open proc event)))
    (cond
     ((equal (plist-get event :method) "editor")
      (pilish--open-editor-dialog
       proc request
       (or (not (eq pilish-extension-dialog-style 'inline))
           (pilish--dialog-followup-window proc))))
     ((eq pilish-extension-dialog-style 'inline)
      (pilish--present-inline-dialog proc request))
     (t
      (unwind-protect
          (pcase (plist-get event :method)
            ("confirm" (pilish--extension-ui-confirm event proc))
            ("select"  (pilish--extension-ui-select event proc))
            ("input"   (pilish--extension-ui-input event proc)))
        (pilish--extension-dialog-close proc (plist-get event :id)))))))

(defun pilish--dialog-chat (chat-buffer)
  "Return CHAT-BUFFER or the current session's chat buffer."
  (or chat-buffer (pilish--get-chat-buffer) (user-error "Not in a Pi session")))

(defun pilish-answer-dialog (&optional chat-buffer)
  "Go to the oldest extension dialog awaiting the user in CHAT-BUFFER.
CHAT-BUFFER defaults to the current session.  An editor is displayed; an
inline widget is shown with point on its first choice."
  (interactive)
  (let* ((chat (pilish--dialog-chat chat-buffer))
         (proc (buffer-local-value 'pilish--process chat))
         (request (or (car (pilish--extension-dialog-pending proc))
                      (user-error "No Pi dialog awaits an answer")))
         (editor (plist-get request :pilish-editor)))
    (cond
     ((buffer-live-p editor) (pop-to-buffer editor))
     ((pilish--dialog-widget chat (plist-get request :id))
      (pilish--dialog-focus chat (plist-get request :id)))
     (t (user-error "The Pi dialog is asking in the minibuffer")))))

(defun pilish-cancel-dialog (&optional chat-buffer)
  "Cancel the oldest extension dialog awaiting the user in CHAT-BUFFER."
  (interactive)
  (let* ((chat (pilish--dialog-chat chat-buffer))
         (proc (buffer-local-value 'pilish--process chat)))
    (pilish--cancel-dialog-request
     proc (or (car (pilish--extension-dialog-pending proc))
              (user-error "No Pi dialog awaits an answer")))))

(dolist (map (list pilish-chat-mode-map pilish-input-mode-map))
  (define-key map (kbd "C-c C-a") #'pilish-answer-dialog)
  (define-key map (kbd "C-c C-x") #'pilish-cancel-dialog))

(defun pilish--header-format-dialog (chat-buf)
  "Format the oldest extension dialog awaiting the user in CHAT-BUF, if any.
Clicking it goes to the dialog."
  (when-let* ((process (and chat-buf (buffer-local-value 'pilish--process chat-buf)))
              (request (car (pilish--extension-dialog-pending process))))
    (concat
     "  "
     (propertize
      (pilish--header-escape-text
       (format "◉ answer: %s"
               (pilish--truncate-string
                (car (split-string (pilish--render-safe-string
                                    (plist-get request :title)
                                    (plist-get request :method))
                                   "\n"))
                40)))
      'face 'warning
      'mouse-face 'mode-line-highlight
      'help-echo "mouse-1: go to the Pi dialog awaiting an answer"
      'local-map (make-mode-line-mouse-map 'mouse-1 #'pilish-answer-dialog)))))

;;;; Multiline editor dialogs

(defun pilish--editor-respond (cancelled)
  "Answer the current editor, setting CANCELLED when it was dismissed.
Closing the request quits and kills the editor buffer.  Return non-nil
when the request was still pending."
  (when-let* ((process pilish--dialog-process)
              (id pilish--dialog-id)
              (request (pilish--extension-dialog-request process id)))
    (let ((text (buffer-substring-no-properties (point-min) (point-max)))
          (chat (process-get process 'pilish-chat-buffer)))
      (setq pilish--dialog-id nil)
      (pilish--extension-dialog-respond
       process request (if cancelled (list :cancelled t) (list :value text)))
      (unless cancelled
        (pilish--dialog-note-answer
         process request
         (if (eq (window-buffer) chat) (selected-window) (get-buffer-window chat))
         nil))
      t)))

(defun pilish-editor-submit ()
  "Submit the multiline editor without modifying the session draft."
  (interactive)
  (unless (pilish--editor-respond nil)
    (quit-window t)))

(defun pilish-editor-cancel ()
  "Cancel the multiline editor without modifying the session draft."
  (interactive)
  (unless (pilish--editor-respond t)
    (quit-window t)))

(defun pilish--editor-killed ()
  "Cancel the request if its editor buffer is killed before submission."
  (setq pilish--editor-dying t)
  (pilish--editor-respond t))

(defvar pilish-editor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'pilish-editor-submit)
    (define-key map (kbd "C-c C-k") #'pilish-editor-cancel)
    map)
  "Keymap for standard RPC multiline editor dialogs.")

(define-derived-mode pilish-editor-mode text-mode "Pi-Editor"
  "Edit a standard RPC multiline response in a dedicated buffer."
  (setq-local header-line-format "C-c C-c: submit   C-c C-k: cancel")
  (add-hook 'kill-buffer-hook #'pilish--editor-killed nil t))

(defun pilish--open-editor-dialog (process request display)
  "Open an editor buffer answering editor REQUEST of PROCESS.
Display it when DISPLAY is non-nil; a window means display it there.
The buffer is killed when the request closes."
  (let ((buffer (generate-new-buffer
                 (format "*pilish-editor: %s*"
                         (pilish--render-safe-string (plist-get request :title) "editor")))))
    (with-current-buffer buffer
      (pilish-editor-mode)
      (setq pilish--dialog-process process
            pilish--dialog-id (plist-get request :id))
      (insert (or (plist-get request :prefill) "")))
    (pilish--extension-dialog-set process (plist-get request :id) :pilish-editor buffer)
    (cond ((window-live-p display)
           (select-window display)
           (pop-to-buffer buffer))
          (display (pop-to-buffer buffer)))
    buffer))

;;;; Inline dialog widgets

(defface pilish-dialog-heading
  '((t :inherit (warning bold)))
  "Face for the first line of an inline extension dialog."
  :group 'pilish)

(defface pilish-dialog-message
  '((t :inherit italic))
  "Face for the message or placeholder of an inline extension dialog."
  :group 'pilish)

(defface pilish-dialog-choice
  '((t :inherit button))
  "Face for the clickable choices of an inline extension dialog."
  :group 'pilish)

(defface pilish-dialog-key
  '((t :inherit (shadow bold)))
  "Face for the digit key of an inline extension dialog choice."
  :group 'pilish)

(defface pilish-dialog-hint
  '((t :inherit shadow))
  "Face for the key hints of an inline extension dialog."
  :group 'pilish)

(defvar-local pilish--dialog-widgets nil
  "Inline dialog widgets of this chat buffer, newest first.
Each entry is (ID START END REQUEST): START and END delimit the widget text.")

(defvar-local pilish--dialog-reanchor-timer nil
  "Timer that moves widgets below chat output appended after them.")

(defvar-keymap pilish-dialog-widget-map
  :doc "Keymap active inside an inline extension dialog.
It takes precedence over major and Evil state maps while point is on the widget."
  :parent button-map
  "RET" #'pilish-dialog-choose
  "<return>" #'pilish-dialog-choose
  "TAB" #'pilish-dialog-next-choice
  "<tab>" #'pilish-dialog-next-choice
  "<backtab>" #'pilish-dialog-previous-choice
  "C-c C-c" #'pilish-dialog-choose
  "C-c C-k" #'pilish-dialog-cancel
  "1" #'pilish-dialog-choose-digit
  "2" #'pilish-dialog-choose-digit
  "3" #'pilish-dialog-choose-digit
  "4" #'pilish-dialog-choose-digit
  "5" #'pilish-dialog-choose-digit
  "6" #'pilish-dialog-choose-digit
  "7" #'pilish-dialog-choose-digit
  "8" #'pilish-dialog-choose-digit
  "9" #'pilish-dialog-choose-digit
  "0" #'pilish-dialog-choose-digit)

(defvar-keymap pilish-dialog-confirm-map
  :doc "Keymap active inside an inline yes-or-no dialog."
  :parent pilish-dialog-widget-map
  "y" #'pilish-dialog-confirm-yes
  "n" #'pilish-dialog-confirm-no)

(defun pilish--dialog-keymap (request)
  "Return the keymap of REQUEST's inline widget."
  (if (equal (plist-get request :method) "confirm")
      pilish-dialog-confirm-map
    pilish-dialog-widget-map))

(defun pilish--dialog-choices (request)
  "Return the choices of REQUEST as plists with :label and :answer.
:answer is a response plist tail, or `input' or `editor' when the answer
must be typed, or `cancel'.  The final choice always cancels."
  (append
   (pcase (plist-get request :method)
     ("select" (mapcar (lambda (option)
                         (list :label (pilish--render-safe-string option)
                               :answer (list :value option)))
                       (plist-get request :options)))
     ("confirm" (list (list :label "Yes" :answer '(:confirmed t))
                      (list :label "No" :answer '(:confirmed :json-false))))
     ("input" (list (list :label "Type an answer…" :answer 'input)))
     ("editor" (list (list :label "Edit the response…" :answer 'editor))))
   (list (list :label "Cancel" :answer 'cancel))))

(defun pilish--dialog-key-label (index)
  "Return the digit key that chooses INDEX (zero-based), or nil."
  (cond ((< index 9) (number-to-string (1+ index)))
        ((= index 9) "0")))

(defun pilish--dialog-widget-string (request)
  "Return the widget text for REQUEST."
  (let* ((id (plist-get request :id))
         (method (plist-get request :method))
         (title (string-trim (pilish--render-safe-string (plist-get request :title) method)))
         (detail (pilish--render-safe-string
                  (pcase method
                    ("confirm" (plist-get request :message))
                    ("input" (plist-get request :placeholder)))
                  ""))
         (choices (pilish--dialog-choices request))
         (answers (butlast choices))
         (timeout (plist-get request :timeout))
         (lines nil)
         (index 0))
    ;; The last title line is the question, directly above its choices;
    ;; earlier lines add context above it.
    (let ((title-lines (split-string title "\n")))
      (dolist (line (butlast title-lines))
        (push (propertize (concat "  " line) 'font-lock-face 'pilish-dialog-message) lines))
      (push (propertize (concat "◉ Pi asks: " (car (last title-lines)))
                        'font-lock-face 'pilish-dialog-heading)
            lines))
    (unless (string-empty-p (string-trim detail))
      (push (propertize detail 'font-lock-face 'pilish-dialog-message) lines))
    (dolist (choice answers)
      (let ((key (pilish--dialog-key-label index)))
        (push (concat "  "
                      (pilish--dialog-button
                       (concat (propertize (if key (format "%s " key) "  ")
                                           'font-lock-face 'pilish-dialog-key)
                               (propertize (plist-get choice :label)
                                           'font-lock-face 'pilish-dialog-choice))
                       index (plist-get choice :label) request))
              lines))
      (setq index (1+ index)))
    (push (concat "  "
                  (pilish--dialog-button
                   (propertize "Cancel" 'font-lock-face 'pilish-dialog-choice)
                   index "Cancel" request)
                  (propertize
                   (concat "   click or RET answers"
                           (if (equal method "confirm") " · y/n" " · digits choose")
                           " · TAB moves · C-c C-k cancels"
                           (when (numberp timeout)
                             (format " · expires in %ds" (round (/ timeout 1000.0)))))
                   'font-lock-face 'pilish-dialog-hint))
          lines)
    (let ((text (concat (mapconcat #'identity (nreverse lines) "\n") "\n")))
      (add-text-properties 0 (length text)
                           (list 'pilish-dialog id
                                 'keymap (pilish--dialog-keymap request)
                                 'wrap-prefix "     "
                                 'rear-nonsticky t)
                           text)
      text)))

(defun pilish--dialog-button (text index label request)
  "Return TEXT as the button choosing choice INDEX of REQUEST, described by LABEL."
  (make-text-button (copy-sequence text) nil
                    'action #'pilish--dialog-button-action
                    'pilish-dialog-choice index
                    'keymap (pilish--dialog-keymap request)
                    'follow-link t
                    'face nil
                    'mouse-face 'highlight
                    'help-echo (format "mouse-1, RET: %s" label)))

(defun pilish--dialog-widget (chat id)
  "Return the widget entry of request ID in CHAT, or nil."
  (and (buffer-live-p chat)
       (assoc id (buffer-local-value 'pilish--dialog-widgets chat))))

(defun pilish--dialog-insert-text (request)
  "Insert REQUEST's widget at the end of the current chat buffer.
Return (START . END) markers; START includes the separating blank line."
  (save-excursion
    (goto-char (point-max))
    (let ((start (copy-marker (point))))
      (insert (if (bolp) "\n" "\n\n") (pilish--dialog-widget-string request))
      (cons start (point-marker)))))

(defun pilish--dialog-insert-widget (chat request)
  "Append the widget answering REQUEST to the end of CHAT."
  (with-current-buffer chat
    (let ((inhibit-read-only t)
          bounds)
      (pilish--with-scroll-preservation
        (setq bounds (pilish--dialog-insert-text request)))
      (push (list (plist-get request :id) (car bounds) (cdr bounds) request)
            pilish--dialog-widgets)
      (add-hook 'after-change-functions #'pilish--dialog-schedule-reanchor nil t))))

(defun pilish--dialog-widget-delete (widget)
  "Delete WIDGET's text and markers in the current buffer."
  (pcase-let ((`(,_ ,start ,end . ,_) widget))
    (let ((inhibit-read-only t))
      (pilish--with-scroll-preservation
        (delete-region start end)))
    (set-marker start nil)
    (set-marker end nil)))

(defun pilish--dialog-widget-remove (process id)
  "Delete the inline widget of request ID owned by PROCESS, if any."
  (when-let* ((chat (process-get process 'pilish-chat-buffer))
              (widget (pilish--dialog-widget chat id)))
    (with-current-buffer chat
      (setq pilish--dialog-widgets (delq widget pilish--dialog-widgets))
      (pilish--dialog-widget-delete widget)
      (unless pilish--dialog-widgets
        (remove-hook 'after-change-functions #'pilish--dialog-schedule-reanchor t)))))

(defun pilish--dialog-schedule-reanchor (_beg _end _length)
  "Schedule moving widgets below chat output appended after them.
Runs from `after-change-functions' while widgets are shown."
  (when (and pilish--dialog-widgets
             (not pilish--dialog-reanchor-timer)
             (< (nth 2 (car pilish--dialog-widgets)) (point-max)))
    (setq pilish--dialog-reanchor-timer
          (run-at-time 0.1 nil #'pilish--dialog-reanchor (current-buffer)))))

(defun pilish--dialog-reanchor (chat)
  "Move CHAT's widgets back to its end, oldest first, keeping point on choices.
Pilish appends output at the end of the chat buffer, which is after a
waiting widget; moving the widget keeps the question last, as in Pi."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      ;; Not nil while moving: the moves themselves must not reschedule.
      (setq pilish--dialog-reanchor-timer 'moving)
      (let ((windows (mapcar (lambda (window)
                               (list window
                                     (get-text-property (window-point window) 'pilish-dialog)
                                     (get-text-property (window-point window)
                                                        'pilish-dialog-choice)))
                             (get-buffer-window-list chat nil t))))
        (dolist (widget (reverse pilish--dialog-widgets))
          (pcase-let ((`(,id ,_ ,_ ,request) widget))
            (pilish--dialog-widget-delete widget)
            (let ((inhibit-read-only t)
                  bounds)
              (pilish--with-scroll-preservation
                (setq bounds (pilish--dialog-insert-text request)))
              (setcdr widget (list (car bounds) (cdr bounds) request))
              (pcase-dolist (`(,window ,on-id ,index) windows)
                (when (and (equal on-id id) (window-live-p window))
                  (set-window-point
                   window (pilish--dialog-choice-position chat id index))))))))
      (setq pilish--dialog-reanchor-timer nil))))

(defun pilish--dialog-choice-position (chat id &optional index)
  "Return the position of choice INDEX (default 0) of request ID's widget in CHAT.
Fall back to the first choice when the widget has no choice INDEX."
  (when-let* ((widget (pilish--dialog-widget chat id)))
    (with-current-buffer chat
      (or (and index (text-property-any (nth 1 widget) (nth 2 widget)
                                        'pilish-dialog-choice index))
          (text-property-not-all (nth 1 widget) (nth 2 widget)
                                 'pilish-dialog-choice nil)))))

(defun pilish--dialog-focus (chat id &optional index window)
  "Select a window showing CHAT, with point on request ID's choice INDEX.
INDEX defaults to the first choice.  WINDOW, when it still shows CHAT, is
used first; display CHAT when no window of the selected frame shows it."
  (when-let* ((position (pilish--dialog-choice-position chat id index)))
    (let ((window (cond ((and (window-live-p window) (eq (window-buffer window) chat))
                         window)
                        ((eq (window-buffer) chat) (selected-window))
                        (t (get-buffer-window chat)))))
      (if window (select-window window) (pop-to-buffer chat))
      ;; Show the whole widget, then put point on its first choice.
      (goto-char (point-max))
      (recenter -1)
      (goto-char position))))

;;;; Follow-up questions

(defun pilish--dialog-note-answer (process request window index)
  "Remember that the user answered REQUEST of PROCESS from WINDOW with INDEX.
The next dialog of the same flow then takes focus in WINDOW: a flow is the
set of tools running at the answer (multi-question tools ask again while
they run) or, outside tool calls, the idle session's command."
  (let ((chat (process-get process 'pilish-chat-buffer)))
    (process-put process 'pilish-dialog-followup
                 (list :window window
                       :title (plist-get request :title)
                       :index index
                       :tools (when-let* (((buffer-live-p chat))
                                          (live (buffer-local-value
                                                 'pilish--live-tool-blocks chat)))
                                (let (ids)
                                  (maphash (lambda (id _) (push id ids)) live)
                                  ids))))))

(defun pilish--dialog-followup (process)
  "Return and consume the answer a new dialog of PROCESS follows, or nil.
The value is the plist recorded by `pilish--dialog-note-answer'."
  (let ((answer (process-get process 'pilish-dialog-followup))
        (chat (process-get process 'pilish-chat-buffer)))
    (process-put process 'pilish-dialog-followup nil)
    (when (and answer (buffer-live-p chat))
      (let ((tools (plist-get answer :tools))
            (live (buffer-local-value 'pilish--live-tool-blocks chat)))
        (when (if tools
                  (and live (cl-some (lambda (id) (gethash id live)) tools))
                (eq (buffer-local-value 'pilish--status chat) 'idle))
          answer)))))

(defun pilish--dialog-followup-window (process)
  "Return the window a new editor dialog of PROCESS follows an answer in, or nil.
Consumes the recorded answer."
  (when-let* ((answer (pilish--dialog-followup process)))
    (or (plist-get answer :window) t)))

(defun pilish--present-inline-dialog (process request)
  "Show REQUEST of PROCESS at the end of its chat buffer.
A dialog following an answer in the same flow takes focus."
  (let ((chat (process-get process 'pilish-chat-buffer))
        (followup (pilish--dialog-followup process)))
    (when (buffer-live-p chat)
      (pilish--dialog-insert-widget chat request)
      (when-let* ((window (plist-get followup :window))
                  ((window-live-p window))
                  ((eq (window-buffer window) chat)))
        (pilish--dialog-focus chat (plist-get request :id)
                              (and (equal (plist-get followup :title)
                                          (plist-get request :title))
                                   (plist-get followup :index))
                              window)))))

;;;; Widget commands

(defun pilish--dialog-at-point ()
  "Return (PROCESS REQUEST) of the inline dialog at point."
  (let* ((id (or (get-text-property (point) 'pilish-dialog)
                 (user-error "No Pi dialog at point")))
         (process pilish--process)
         (request (or (pilish--extension-dialog-request process id)
                      (user-error "This Pi dialog no longer awaits an answer"))))
    (list process request)))

(defun pilish--dialog-answer (process request index)
  "Answer REQUEST of PROCESS with its choice INDEX."
  (let ((answer (plist-get (nth index (pilish--dialog-choices request)) :answer))
        (window (selected-window)))
    (pcase answer
      ('nil (user-error "No choice %d" (1+ index)))
      ('cancel (pilish--cancel-dialog-request process request))
      ('editor (pop-to-buffer (or (plist-get request :pilish-editor)
                                  (user-error "Editor dialog buffer is gone"))))
      ('input
       (let* ((placeholder (plist-get request :placeholder))
              (value (read-string
                      (format "%s%s "
                              (plist-get request :title)
                              (if (and placeholder (not (string-empty-p placeholder)))
                                  (format " (%s)" placeholder)
                                "")))))
         (pilish--dialog-note-answer process request window index)
         (pilish--extension-dialog-respond process request (list :value value))))
      (_
       (pilish--dialog-note-answer process request window index)
       (pilish--extension-dialog-respond process request answer)))))

(defun pilish--dialog-button-action (button)
  "Answer the inline dialog choice of BUTTON."
  (save-excursion
    (goto-char button)
    (pcase-let ((`(,process ,request) (pilish--dialog-at-point)))
      (pilish--dialog-answer process request
                             (get-text-property (point) 'pilish-dialog-choice)))))

(defun pilish-dialog-choose ()
  "Answer the inline dialog with the choice at point."
  (interactive)
  (if-let* ((index (get-text-property (point) 'pilish-dialog-choice)))
      (pcase-let ((`(,process ,request) (pilish--dialog-at-point)))
        (pilish--dialog-answer process request index))
    (pilish-dialog-next-choice)
    (message "Pi: choose with RET or a click on a choice")))

(defun pilish-dialog-choose-digit ()
  "Answer the inline dialog with the choice numbered by the typed digit."
  (interactive)
  (let* ((digit (- (event-basic-type last-command-event) ?0))
         (index (if (zerop digit) 9 (1- digit))))
    (pcase-let ((`(,process ,request) (pilish--dialog-at-point)))
      (if (< index (1- (length (pilish--dialog-choices request))))
          (pilish--dialog-answer process request index)
        (user-error "No choice %d" (1+ index))))))

(defun pilish--dialog-confirm-key (index)
  "Answer the confirm dialog at point with choice INDEX."
  (pcase-let ((`(,process ,request) (pilish--dialog-at-point)))
    (unless (equal (plist-get request :method) "confirm")
      (user-error "Not a yes/no question"))
    (pilish--dialog-answer process request index)))

(defun pilish-dialog-confirm-yes ()
  "Answer yes to the confirm dialog at point."
  (interactive)
  (pilish--dialog-confirm-key 0))

(defun pilish-dialog-confirm-no ()
  "Answer no to the confirm dialog at point."
  (interactive)
  (pilish--dialog-confirm-key 1))

(defun pilish-dialog-cancel ()
  "Cancel the inline dialog at point."
  (interactive)
  (pcase-let ((`(,process ,request) (pilish--dialog-at-point)))
    (pilish--cancel-dialog-request process request)))

(defun pilish--dialog-move-choice (direction)
  "Move point to the next choice of the widget at point in DIRECTION (1 or -1)."
  (let* ((id (or (get-text-property (point) 'pilish-dialog)
                 (user-error "No Pi dialog at point")))
         (widget (or (pilish--dialog-widget (current-buffer) id)
                     (user-error "This Pi dialog no longer awaits an answer")))
         (start (nth 1 widget))
         (end (nth 2 widget))
         (choices nil)
         (position start))
    (while (setq position (text-property-not-all position end 'pilish-dialog-choice nil))
      (push position choices)
      (setq position (or (next-single-property-change position 'pilish-dialog-choice nil end)
                         end)))
    (setq choices (nreverse choices))
    (let* ((current (get-text-property (point) 'pilish-dialog-choice))
           (here (and current (cl-position-if
                               (lambda (p) (eq (get-text-property p 'pilish-dialog-choice)
                                               current))
                               choices)))
           (next (cond ((null here) (if (> direction 0) 0 (1- (length choices))))
                       (t (mod (+ here direction) (length choices))))))
      (goto-char (nth next choices)))))

(defun pilish-dialog-next-choice ()
  "Move to the next choice of the inline dialog at point."
  (interactive)
  (pilish--dialog-move-choice 1))

(defun pilish-dialog-previous-choice ()
  "Move to the previous choice of the inline dialog at point."
  (interactive)
  (pilish--dialog-move-choice -1))

(provide 'pilish-dialog)
;;; pilish-dialog.el ends here
