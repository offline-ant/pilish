;;; pilish-style-test.el --- Tests for chat styles and fitted input windows -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers `pilish-chat-style' (classic and pi) on live and history
;; rendering, and `fit' input window sizing.

;;; Code:

(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

(defun pilish-style-test--overlays (kind &optional beg end)
  "Return style overlays of KIND between BEG and END, by start."
  (sort (seq-filter (lambda (ov) (eq (overlay-get ov 'pilish-style-kind) kind))
                    (overlays-in (or beg (point-min)) (or end (point-max))))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun pilish-style-test--pos (text)
  "Return the start of the first occurrence of TEXT."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (match-beginning 0)))

(defun pilish-style-test--overlay-at (kind text)
  "Return the style overlay of KIND covering the first TEXT."
  (let ((pos (pilish-style-test--pos text)))
    (seq-find (lambda (ov) (eq (overlay-get ov 'pilish-style-kind) kind))
              (overlays-at pos))))

(defun pilish-style-test--tool-overlay (text)
  "Return the tool block overlay covering the first TEXT."
  (seq-find (lambda (ov) (overlay-get ov 'pilish-tool-block))
            (overlays-at (pilish-style-test--pos text))))

(defun pilish-style-test--decorate ()
  "Run the style's jit-lock function over the whole buffer."
  (pilish--style-decorate (point-min) (point-max)))

(defconst pilish-style-test--history
  (vector
   '(:role "user" :content "Hello Pi" :timestamp 1784817120000)
   '(:role "assistant" :timestamp 1784817121000
     :content [(:type "thinking" :thinking "Pondering the request")
               (:type "text" :text "Plain *assistant* text.")
               (:type "toolCall" :id "ok" :name "bash" :arguments (:command "echo fine"))
               (:type "toolCall" :id "bad" :name "bash" :arguments (:command "false"))])
   '(:role "toolResult" :toolCallId "ok" :toolName "bash" :isError :false
     :content [(:type "text" :text "fine output")] :timestamp 1784817122000)
   '(:role "toolResult" :toolCallId "bad" :toolName "bash" :isError t
     :content [(:type "text" :text "broken output")] :timestamp 1784817123000)
   '(:role "custom" :customType "note" :content "Custom note" :display t
     :timestamp 1784817124000))
  "History with every block kind the styles decorate.")

(defmacro pilish-style-test--with-chat (style &rest body)
  "Run BODY in a chat buffer created with `pilish-chat-style' STYLE."
  (declare (indent 1) (debug t))
  `(let ((pilish-chat-style ,style))
     (with-temp-buffer
       (pilish-chat-mode)
       ,@body)))

;;;; Classic style

(ert-deftest pilish-style-test-classic-keeps-headings-and-tool-faces ()
  "Classic style adds no decorations; success blocks look like running ones."
  (pilish-style-test--with-chat 'classic
    (pilish--display-history-messages pilish-style-test--history)
    (should-not (memq #'pilish--style-decorate jit-lock-functions))
    (should-not (seq-some (lambda (ov) (overlay-get ov 'pilish-style-overlay))
                          (overlays-in (point-min) (point-max))))
    (should-not (assq 'pilish-tool-block face-remapping-alist))
    (should (string-match-p "^You · .*\n=+\n" (buffer-string)))
    (should (eq (overlay-get (pilish-style-test--tool-overlay "fine output") 'face)
                'pilish-tool-block-success))
    (should (eq (face-attribute 'pilish-tool-block-success :inherit)
                'pilish-tool-block))
    (should (eq (overlay-get (pilish-style-test--tool-overlay "broken output") 'face)
                'pilish-tool-block-error))))

;;;; Pi style

(ert-deftest pilish-style-test-pi-history-decorations ()
  "Pi style hides headings and decorates user, thinking, tool and custom blocks."
  (pilish-style-test--with-chat 'pi
    (should (memq #'pilish--style-decorate jit-lock-functions))
    (should (memq 'pilish-style-heading buffer-invisibility-spec))
    (pilish--display-history-messages pilish-style-test--history)
    (pilish-style-test--decorate)
    ;; Both turn headings, label and underline, are invisible.
    (let ((headings (pilish-style-test--overlays 'heading)))
      (should (= (length headings) 2))
      (dolist (ov headings)
        (should (eq (overlay-get ov 'invisible) 'pilish-style-heading))
        (should (string-match-p "\\`\\(You · [^\n]*\\|Assistant\\)\n=+\n\\'"
                                (buffer-substring-no-properties
                                 (overlay-start ov) (overlay-end ov))))))
    ;; The user block runs from below its heading to the Assistant heading,
    ;; its blank lines acting as Pi's vertical padding.
    (let ((user (pilish-style-test--overlay-at 'block "Hello Pi")))
      (should (eq (overlay-get user 'face) 'pilish-pi-user-message))
      (should (equal (buffer-substring-no-properties (overlay-start user)
                                                     (overlay-end user))
                     "\nHello Pi\n\n"))
      (should (equal (get-text-property 0 'face (overlay-get user 'line-prefix))
                     'pilish-pi-user-message)))
    (should-not (pilish-style-test--overlay-at 'block "Plain"))
    (should (eq (overlay-get (pilish-style-test--overlay-at 'thinking "Pondering") 'face)
                'pilish-pi-thinking))
    (should-not (pilish-style-test--overlay-at 'thinking "Plain"))
    ;; Tool blocks carry padding in their state colour and muted output.
    (let ((ok (pilish-style-test--overlay-at 'tool-pad "fine output"))
          (bad (pilish-style-test--overlay-at 'tool-pad "broken output")))
      (should (eq (get-text-property 0 'face (overlay-get ok 'before-string))
                  'pilish-tool-block-success))
      (should (eq (get-text-property 0 'face (overlay-get bad 'after-string))
                  'pilish-tool-block-error)))
    (should (eq (overlay-get (pilish-style-test--overlay-at 'tool-output "fine output") 'face)
                'pilish-pi-tool-output))
    (should-not (pilish-style-test--overlay-at 'tool-output "echo fine"))
    (should (eq (overlay-get (pilish-style-test--overlay-at 'custom "Custom note") 'face)
                'pilish-pi-custom-message))
    ;; Tool faces show Pi's state colours in this buffer only.
    (should (equal (alist-get 'pilish-tool-block-success face-remapping-alist)
                   '(pilish-pi-tool-success)))
    (should (equal (alist-get 'pilish-tool-block-error face-remapping-alist)
                   '(pilish-pi-tool-error)))))

(ert-deftest pilish-style-test-pi-hidden-tail-becomes-bottom-padding ()
  "A block ending in a hidden line shows that line as its bottom padding.
An overlay string with a newline next to a wholly hidden line stops line
motion and scrolling from moving up past it, so such blocks get no
`after-string'; blocks with a visible last line keep one."
  (pilish-style-test--with-chat 'pi
    (pilish--display-history-messages pilish-style-test--history)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "Between\n"
              (propertize "Custom tail\n```\ncode\n```\n" 'pilish-custom-message t)
              "After\n"))
    (font-lock-ensure)
    (pilish-style-test--decorate)
    (let* ((tool (pilish-style-test--tool-overlay "fine output"))
           (newline (1- (overlay-end tool)))
           (tail (seq-find (lambda (ov) (= (overlay-start ov) newline))
                           (pilish-style-test--overlays 'tool-tail))))
      ;; The closing fence is hidden by Markdown fontification.
      (should (pilish--style-hidden-tail (overlay-start tool) (overlay-end tool)))
      (should (= (overlay-end tail) (overlay-end tool)))
      (should-not (invisible-p newline))
      (should (equal (overlay-get tail 'display) '(raise 0)))
      (should-not (overlay-get (pilish-style-test--overlay-at 'tool-pad "fine output")
                               'after-string)))
    (let ((custom (pilish-style-test--overlay-at 'custom "Custom tail")))
      (should-not (overlay-get custom 'after-string))
      (should (= (length (pilish-style-test--overlays 'custom-tail)) 1))
      (should-not (invisible-p (1- (overlay-end custom)))))
    (should (overlay-get (pilish-style-test--overlay-at 'custom "Custom note")
                         'after-string))
    ;; A visible last line keeps the padding string and loses the tail.
    (let ((inhibit-read-only t)
          (newline (1- (overlay-end (pilish-style-test--tool-overlay "fine output")))))
      (remove-text-properties (- newline 3) (1+ newline) '(invisible nil)))
    (pilish-style-test--decorate)
    (should (overlay-get (pilish-style-test--overlay-at 'tool-pad "fine output")
                         'after-string))
    (should-not (seq-some (lambda (ov)
                            (= (overlay-end ov)
                               (overlay-end (pilish-style-test--tool-overlay "fine output"))))
                          (pilish-style-test--overlays 'tool-tail)))))

(ert-deftest pilish-style-test-pi-decoration-is-idempotent-per-chunk ()
  "Decorating arbitrary chunks gives the same overlays as one full pass."
  (pilish-style-test--with-chat 'pi
    (pilish--display-history-messages pilish-style-test--history)
    (pilish-style-test--decorate)
    (let ((full (mapcar (lambda (ov) (list (overlay-get ov 'pilish-style-kind)
                                           (overlay-start ov) (overlay-end ov)))
                        (pilish-style-test--overlays-all))))
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (pilish--style-decorate pos (min (point-max) (+ pos 7)))
          (setq pos (+ pos 7))))
      (should (equal full
                     (mapcar (lambda (ov) (list (overlay-get ov 'pilish-style-kind)
                                                (overlay-start ov) (overlay-end ov)))
                             (pilish-style-test--overlays-all)))))))

(defun pilish-style-test--overlays-all ()
  "Return all style overlays sorted by kind name and start."
  (sort (seq-filter (lambda (ov) (overlay-get ov 'pilish-style-overlay))
                    (overlays-in (point-min) (point-max)))
        (lambda (a b)
          (let ((ka (symbol-name (overlay-get a 'pilish-style-kind)))
                (kb (symbol-name (overlay-get b 'pilish-style-kind))))
            (if (string= ka kb)
                (< (overlay-start a) (overlay-start b))
              (string< ka kb))))))

(ert-deftest pilish-style-test-pi-live-turn-and-tool-state ()
  "A streamed turn ends the user block at the new heading; tool pads follow state."
  (pilish-style-test--with-chat 'pi
    (pilish--display-user-message "Live question" nil)
    (pilish-style-test--decorate)
    ;; Before the reply, the user block reaches the end of the buffer.
    (should (= (overlay-end (pilish-style-test--overlay-at 'block "Live question"))
               (point-max)))
    (pilish--handle-display-event '(:type "agent_start"))
    (pilish--handle-display-event
     '(:type "tool_execution_start" :toolCallId "t" :toolName "bash"
       :args (:command "sleep 1")))
    ;; jit-lock decorates the inserted text starting at the new heading.
    (pilish--style-decorate (pilish-style-test--pos "Assistant") (point-max))
    (let ((user (pilish-style-test--overlay-at 'block "Live question")))
      (should (= (overlay-end user) (pilish-style-test--pos "Assistant"))))
    (should (eq (get-text-property
                 0 'face (overlay-get (pilish-style-test--overlay-at 'tool-pad "sleep 1")
                                      'before-string))
                'pilish-tool-block))
    (pilish--handle-display-event
     '(:type "tool_execution_end" :toolCallId "t" :toolName "bash" :isError t
       :result (:content [(:type "text" :text "interrupted")])))
    (pilish-style-test--decorate)
    (should (eq (get-text-property
                 0 'face (overlay-get (pilish-style-test--overlay-at 'tool-pad "sleep 1")
                                      'before-string))
                'pilish-tool-block-error))
    ;; One padding overlay per tool block, however often it is decorated.
    (should (= (length (pilish-style-test--overlays 'tool-pad)) 1))))

(ert-deftest pilish-style-test-pi-summary-keeps-label ()
  "Compaction summaries keep their label line inside a custom block."
  (pilish-style-test--with-chat 'pi
    (pilish--display-compaction-result 1200 "Summary text" nil)
    (pilish-style-test--decorate)
    (should (eq (overlay-get (pilish-style-test--overlay-at 'label "Compaction") 'face)
                'pilish-pi-custom-message-label))
    (should-not (invisible-p (pilish-style-test--pos "Compaction")))
    (should (invisible-p (pilish-style-test--pos "====")))
    (should (eq (overlay-get (pilish-style-test--overlay-at 'block "Summary text") 'face)
                'pilish-pi-custom-message))))

(ert-deftest pilish-style-test-pi-copy-omits-hidden-headings ()
  "Copying a region in the pi style leaves out the hidden turn headings.
The classic style shows the headings, so it copies them."
  (dolist (case '((pi . nil) (classic . t)))
    (pilish-style-test--with-chat (car case)
      (pilish--display-history-messages pilish-style-test--history)
      (pilish-style-test--decorate)
      (let ((text (filter-buffer-substring (point-min) (point-max))))
        (should (string-match-p "Hello Pi" text))
        (should (string-match-p "Plain assistant text\\." text))
        (should (eq (cdr case) (and (string-match-p "^You · " text) t)))
        (should (eq (cdr case) (and (string-match-p "^Assistant$" text) t)))
        (should (eq (cdr case) (and (string-match-p "^===" text) t))))
      (let ((kill-ring nil))
        (kill-ring-save (point-min) (point-max))
        (should (eq (cdr case) (and (string-match-p "^Assistant$" (car kill-ring)) t)))))))

(ert-deftest pilish-style-test-pi-line-motion-skips-hidden-headings ()
  "Line motion never leaves point strictly inside a hidden heading.
Its start is a visible boundary: the cursor shows on the following text."
  (pilish-style-test--with-chat 'pi
    (pilish--display-history-messages pilish-style-test--history)
    (pilish-style-test--decorate)
    (let ((line-move-ignore-invisible t))
      (goto-char (point-min))
      (while (not (eobp))
        (should-not (and (invisible-p (point)) (invisible-p (1- (point)))))
        (let ((before (point)))
          (forward-line 0)
          (line-move 1 t)
          (when (= before (point)) (goto-char (point-max)))))
      (while (not (bobp))
        (should-not (and (invisible-p (point)) (invisible-p (1- (point)))))
        (let ((before (point)))
          (line-move -1 t)
          (when (= before (point)) (goto-char (point-min))))))))

(ert-deftest pilish-style-test-pi-heading-text-without-underline-stays ()
  "Lines reading like headings without a setext underline are not hidden."
  (pilish-style-test--with-chat 'pi
    (let ((inhibit-read-only t))
      (insert "You\nplain text\nCompaction\n---\n"))
    (pilish-style-test--decorate)
    (should-not (pilish-style-test--overlays 'heading))
    (should (equal (filter-buffer-substring (point-min) (point-max))
                   "You\nplain text\nCompaction\n---\n"))))

(ert-deftest pilish-style-test-switching-style-restyles-open-buffers ()
  "Customizing the style installs and removes decorations in open buffers.
The setter changes the current binding, so a `let' scopes the change."
  (let ((toplevel (default-toplevel-value 'pilish-chat-style)))
    (let ((pilish-chat-style 'classic))
      (with-temp-buffer
        (pilish-chat-mode)
        (pilish--display-history-messages pilish-style-test--history)
        (customize-set-variable 'pilish-chat-style 'pi)
        (should (eq pilish-chat-style 'pi))
        (pilish-style-test--decorate)
        (should (pilish-style-test--overlays 'heading))
        (should (assq 'pilish-tool-block face-remapping-alist))
        (customize-set-variable 'pilish-chat-style 'classic)
        (should-not (pilish-style-test--overlays-all))
        (should-not (assq 'pilish-tool-block face-remapping-alist))
        (should-not (memq 'pilish-style-heading
                          (and (listp buffer-invisibility-spec)
                               buffer-invisibility-spec)))
        (should-not (memq #'pilish--style-decorate jit-lock-functions))))
    (should (eq (default-toplevel-value 'pilish-chat-style) toplevel))))

(ert-deftest pilish-style-test-face-defaults-are-pi-colours ()
  "Face specs carry Pi's dark and light theme colours."
  (dolist (case '((pilish-pi-user-message "#213b49" "#dfe7ec")
                  (pilish-pi-custom-message "#3a3055" "#e6e4ee")
                  (pilish-pi-tool-pending "#34383a" "#e4e5e6")
                  (pilish-pi-tool-success "#254131" "#dee9e1")
                  (pilish-pi-tool-error "#5b282a" "#eee2e1")
                  (pilish-pi-thinking "#96a0a4" "#7c868c")))
    (let ((spec (format "%S" (face-default-spec (car case)))))
      (should (string-search (nth 1 case) spec))
      (should (string-search (nth 2 case) spec)))))

;;;; Fitted input windows

(defmacro pilish-style-test--with-fit-layout (&rest body)
  "Run BODY with `chat-win' over `input-win' and `fit' input heights."
  (declare (indent 0) (debug t))
  `(let ((pilish-input-window-height 'fit)
         (pilish-input-window-min-height 3)
         (pilish-input-window-max-height 0.33)
         (input-buf (generate-new-buffer " *test-fit-input*")))
     (unwind-protect
         (progn
           (with-current-buffer input-buf
             (setq-local header-line-format "header"))
           (delete-other-windows)
           (let* ((chat-win (selected-window))
                  (input-win (pilish-split-input-window chat-win input-buf)))
             ,@body))
       (kill-buffer input-buf))))

(ert-deftest pilish-style-test-fit-input-grows-and-shrinks ()
  "A `fit' input window starts small, grows with the draft to its cap, shrinks."
  (pilish-style-test--with-fit-layout
    (should (window-live-p input-win))
    (let ((total (window-total-height (window-parent input-win))))
      (should (= (window-total-height input-win) 3))
      (with-current-buffer input-buf (insert "one\ntwo\nthree"))
      (pilish-fit-input-window input-win)
      (should (= (window-total-height input-win) 5))
      (with-current-buffer input-buf
        (insert (mapconcat #'number-to-string (number-sequence 1 40) "\n")))
      (pilish-fit-input-window input-win)
      (should (= (window-total-height input-win) (round (* 0.33 total))))
      (should (= (window-total-height (window-parent input-win)) total))
      (with-current-buffer input-buf (erase-buffer))
      (pilish-fit-input-window input-win)
      (should (= (window-total-height input-win) 3)))))

(ert-deftest pilish-style-test-fit-input-keeps-preserved-size-current ()
  "Fitting updates a preserved height so balancing keeps the new size."
  (pilish-style-test--with-fit-layout
    (window-preserve-size input-win nil t)
    (with-current-buffer input-buf (insert "a\nb\nc\nd"))
    (pilish-fit-input-window input-win)
    (should (= (window-total-height input-win) 6))
    (should (window-preserved-size input-win nil))))

(ert-deftest pilish-style-test-fit-input-scheduled-after-changes ()
  "Input edits schedule one fit for the whole batch of changes."
  (let ((pilish-input-window-height 'fit)
        timers)
    (with-temp-buffer
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest args) (push args timers) (timer-create))))
        (pilish--schedule-fit-input-windows)
        (pilish--schedule-fit-input-windows)
        (should (= (length timers) 1))))))

(ert-deftest pilish-style-test-fixed-heights-ignore-fit ()
  "Integer and float heights never resize windows through fitting."
  (let ((pilish-input-window-height 10)
        (input-buf (generate-new-buffer " *test-fixed-input*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (let ((input-win (pilish-split-input-window (selected-window) input-buf)))
            (should (= (window-total-height input-win) 10))
            (with-current-buffer input-buf (insert "x"))
            (pilish-fit-input-window input-win)
            (should (= (window-total-height input-win) 10))))
      (kill-buffer input-buf))))

(provide 'pilish-style-test)
;;; pilish-style-test.el ends here
