;;; pilish-pair-test.el --- Tests for chat and input window pairs -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `pilish-window-pairing-mode': atomic chat and input pairs,
;; several pairs in one frame, and the repair pass.

;;; Code:

(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

(defmacro pilish-pair-test--with-sessions (&rest body)
  "Run BODY with pairing on and two sessions, `chat-a' and `chat-b'.
`input-a' and `input-b' are their input buffers."
  (declare (indent 0) (debug t))
  `(let ((root-a "/tmp/pilish-pair-test-a/")
         (root-b "/tmp/pilish-pair-test-b/")
         (pilish-input-window-height 4)
         (pilish-input-window-display 'always)
         (enabled pilish-window-pairing-mode))
     (make-directory root-a t)
     (make-directory root-b t)
     (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
               ((symbol-function 'pilish--start-process)
                (lambda (_ &optional _args _environment) nil)))
       (unwind-protect
           (let* ((chat-a (pilish--setup-session root-a nil))
                  (chat-b (pilish--setup-session root-b nil))
                  (input-a (buffer-local-value 'pilish--input-buffer chat-a))
                  (input-b (buffer-local-value 'pilish--input-buffer chat-b)))
             (ignore input-a input-b)
             (pilish-window-pairing-mode 1)
             (delete-other-windows)
             (switch-to-buffer "*scratch*")
             ,@body)
         (pilish-window-pairing-mode (if enabled 1 -1))
         (delete-other-windows)
         (pilish-test--kill-session-buffers root-a)
         (pilish-test--kill-session-buffers root-b)
         (delete-other-windows)))))

(defun pilish-pair-test--show (chat window)
  "Show CHAT in WINDOW with its input below; return the input window."
  (set-window-buffer window chat)
  (pilish-split-input-window window (buffer-local-value 'pilish--input-buffer chat)))

(defun pilish-pair-test--side-by-side (chat-a chat-b)
  "Show CHAT-A and CHAT-B as pairs side by side; return their chat windows."
  (delete-other-windows)
  (let* ((left (selected-window))
         (right (split-window left nil 'right)))
    (pilish-pair-test--show chat-a left)
    (pilish-pair-test--show chat-b right)
    (list left right)))

(defun pilish-pair-test--consistent-p ()
  "Return non-nil when every chat and input window is in a matching pair."
  (cl-every
   (lambda (window)
     (let ((buffer (window-buffer window)))
       (or (not (memq (buffer-local-value 'major-mode buffer)
                      '(pilish-chat-mode pilish-input-mode)))
           (when-let* ((pair (pilish-window-pair window)))
             (let ((chat (window-buffer (car pair))))
               (and (eq (buffer-local-value 'major-mode chat) 'pilish-chat-mode)
                    (eq (window-buffer (cdr pair))
                        (buffer-local-value 'pilish--input-buffer chat))
                    (eq (window-dedicated-p (car pair)) 'side)
                    (eq (window-dedicated-p (cdr pair)) 'side)))))))
   (window-list nil 'no-mini)))

(defun pilish-pair-test--repair ()
  "Run the repair pass on the selected frame."
  (pilish-repair-window-pairs (selected-frame)))

(ert-deftest pilish-pair-test-split-makes-atomic-pair ()
  "With pairing, the input split forms one atomic, dedicated pair."
  (pilish-pair-test--with-sessions
    (let* ((chat-win (selected-window))
           (input-win (pilish-pair-test--show chat-a chat-win)))
      (should (equal (pilish-window-pair chat-win) (cons chat-win input-win)))
      (should (equal (pilish-window-pair input-win) (cons chat-win input-win)))
      (should (window-parameter (window-parent chat-win) 'window-atom))
      (should (= (window-total-height input-win) 4))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-two-pairs-survive-delete-other-windows ()
  "`delete-other-windows' in either half keeps that whole pair."
  (pilish-pair-test--with-sessions
    (pcase-let ((`(,left ,_right) (pilish-pair-test--side-by-side chat-a chat-b)))
      (should (= (length (window-list)) 4))
      (should (pilish-pair-test--consistent-p))
      (delete-other-windows (get-buffer-window input-a))
      (should (= (length (window-list)) 2))
      (should (eq (window-buffer left) chat-a))
      (should (get-buffer-window input-a))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-frame-filling-pair-ignores-delete-other-windows ()
  "`delete-other-windows' in a pair that fills its frame changes nothing."
  (pilish-pair-test--with-sessions
    (let* ((chat-win (selected-window))
           (input-win (pilish-pair-test--show chat-a chat-win)))
      (delete-other-windows input-win)
      (delete-other-windows chat-win)
      (should (window-live-p chat-win))
      (should (window-live-p input-win))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-delete-window-on-chat-closes-whole-pair ()
  "`delete-window' on a chat removes its pair, leaving the other pair."
  (pilish-pair-test--with-sessions
    (pilish-pair-test--side-by-side chat-a chat-b)
    (delete-window (get-buffer-window chat-a))
    (should-not (get-buffer-window chat-a))
    (should-not (get-buffer-window input-a))
    (should (= (length (window-list)) 2))
    (should (pilish-pair-test--consistent-p))))

(ert-deftest pilish-pair-test-delete-window-on-input-closes-input ()
  "`delete-window' on an input closes only it, and it stays closed."
  (pilish-pair-test--with-sessions
    (pcase-let ((`(,_left ,right) (pilish-pair-test--side-by-side chat-a chat-b)))
      (delete-window (get-buffer-window input-b))
      (should (eq (window-buffer right) chat-b))
      (should-not (get-buffer-window input-b))
      (should-not (window-dedicated-p right))
      (pilish-pair-test--repair)
      (should-not (get-buffer-window input-b))
      (should (pilish-window-pair (get-buffer-window chat-a))))))

(ert-deftest pilish-pair-test-split-goes-beside-pair ()
  "Splitting either half splits beside the pair, never inside it."
  (pilish-pair-test--with-sessions
    (let* ((chat-win (selected-window))
           (input-win (pilish-pair-test--show chat-a chat-win))
           (pair-root (window-parent chat-win))
           (new (split-window input-win nil 'below)))
      (should (eq (window-parent chat-win) pair-root))
      (should (= (window-child-count pair-root) 2))
      (should-not (eq (window-parent new) pair-root))
      (set-window-buffer new "*scratch*")
      (should (pilish-pair-test--consistent-p))
      (split-window chat-win nil 'right)
      (pilish-pair-test--repair)
      (should (pilish-pair-test--consistent-p))
      (should (= (window-child-count pair-root) 2)))))

(ert-deftest pilish-pair-test-chat-switch-moves-input-along ()
  "Switching a pair's chat window to another chat switches its input."
  (pilish-pair-test--with-sessions
    (pcase-let ((`(,left ,right) (pilish-pair-test--side-by-side chat-a chat-b)))
      (with-selected-window left (switch-to-buffer chat-b))
      (pilish-pair-test--repair)
      (should (eq (window-buffer (cdr (pilish-window-pair left))) input-b))
      (should (eq (window-buffer right) chat-b))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-input-switch-moves-chat-along ()
  "Switching a pair's input window to another input switches its chat."
  (pilish-pair-test--with-sessions
    (pcase-let ((`(,left ,_right) (pilish-pair-test--side-by-side chat-a chat-b)))
      (with-selected-window (get-buffer-window input-a)
        (switch-to-buffer input-b))
      (pilish-pair-test--repair)
      (should (eq (window-buffer left) chat-b))
      (should-not (get-buffer-window chat-a))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-switching-half-to-session-buffer ()
  "A chat window switched to an input buffer shows that session's pair."
  (pilish-pair-test--with-sessions
    (let ((chat-win (selected-window)))
      (pilish-pair-test--show chat-a chat-win)
      (switch-to-buffer input-b)
      (pilish-pair-test--repair)
      (should (eq (window-buffer chat-win) chat-b))
      (should (eq (window-buffer (cdr (pilish-window-pair chat-win))) input-b)))))

(ert-deftest pilish-pair-test-switch-to-session-buffer-obeying-display-actions ()
  "Same-window display of a session buffer switches the selected pair."
  (pilish-pair-test--with-sessions
    (let ((switch-to-buffer-obey-display-actions t)
          (chat-win (selected-window)))
      (pilish-pair-test--show chat-a chat-win)
      (switch-to-buffer chat-b)
      (should (eq (selected-window) chat-win))
      (should (eq (window-buffer (cdr (pilish-window-pair chat-win))) input-b))
      (select-window (cdr (pilish-window-pair chat-win)))
      (switch-to-buffer input-a)
      (should (eq (window-buffer chat-win) chat-a))
      (should (eq (window-buffer) input-a))
      (should (= (length (window-list)) 2))
      ;; Other buffers go beside the pair.
      (switch-to-buffer "*scratch*")
      (should (= (length (window-list)) 3))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-other-buffer-takes-pair-place ()
  "Another buffer in either half replaces the whole pair."
  (pilish-pair-test--with-sessions
    (let* ((chat-win (selected-window))
           (input-win (pilish-pair-test--show chat-a chat-win)))
      (select-window input-win)
      (switch-to-buffer "*scratch*")
      (pilish-pair-test--repair)
      (should (= (length (window-list)) 1))
      (should (eq (window-buffer) (get-buffer "*scratch*")))
      (should-not (window-dedicated-p))
      (should-not (window-parameter (selected-window) 'window-atom))
      (pilish-pair-test--show chat-a (selected-window))
      (switch-to-buffer "*scratch*")
      (pilish-pair-test--repair)
      (should (= (length (window-list)) 1))
      (should (eq (window-buffer) (get-buffer "*scratch*"))))))

(ert-deftest pilish-pair-test-display-buffer-avoids-pairs ()
  "`display-buffer' never shows other buffers in a pair's halves."
  (pilish-pair-test--with-sessions
    (pilish-pair-test--show chat-a (selected-window))
    (let* ((other (get-buffer-create " *pilish-pair-other*"))
           (window (display-buffer other '(display-buffer-use-some-window))))
      (unwind-protect
          (progn
            (should-not (memq window (list (get-buffer-window chat-a)
                                           (get-buffer-window input-a))))
            (should (pilish-pair-test--consistent-p)))
        (kill-buffer other)))))

(ert-deftest pilish-pair-test-lone-chat-gets-input ()
  "A chat window without its input gets one below it."
  (pilish-pair-test--with-sessions
    (let ((right (split-window nil nil 'right)))
      (set-window-buffer right chat-b)
      (pilish-pair-test--repair)
      (should (eq (window-buffer (cdr (pilish-window-pair right))) input-b))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-stacked-chats-each-get-input ()
  "Two chats stacked in plain windows become two pairs, not one."
  (pilish-pair-test--with-sessions
    (let ((below (split-window nil nil 'below)))
      (set-window-buffer (selected-window) chat-a)
      (set-window-buffer below chat-b)
      (pilish-pair-test--repair)
      (should (get-buffer-window input-a))
      (should (get-buffer-window input-b))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-lone-input-gets-chat ()
  "An input window without its chat gets the chat above it."
  (pilish-pair-test--with-sessions
    (let ((window (selected-window)))
      (switch-to-buffer input-a)
      (pilish-pair-test--repair)
      (let ((pair (pilish-window-pair window)))
        (should (eq (cdr pair) window))
        (should (eq (window-buffer (car pair)) chat-a))
        (should (= (window-total-height window) 4)))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-stale-input-half-is-replaced ()
  "A lone chat absorbs its lone input window instead of duplicating it."
  (pilish-pair-test--with-sessions
    (let ((right (split-window nil nil 'right)))
      (set-window-buffer (selected-window) chat-a)
      (set-window-buffer right input-a)
      (pilish-pair-test--repair)
      (should (= (length (get-buffer-window-list chat-a)) 1))
      (should (= (length (get-buffer-window-list input-a)) 1))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-closed-input-stays-closed ()
  "An input closed with `delete-window' keeps the chat alone across repairs."
  (pilish-pair-test--with-sessions
    (let* ((chat-win (selected-window))
           (input-win (pilish-pair-test--show chat-a chat-win)))
      (delete-window input-win)
      (should (window-live-p chat-win))
      (should-not (get-buffer-window input-a))
      (pilish-pair-test--repair)
      (should-not (get-buffer-window input-a))
      (pilish-repair-window-pairs nil t)
      (should (eq (window-buffer (cdr (pilish-window-pair chat-win))) input-a))
      (should (pilish-pair-test--consistent-p))
      ;; The mark ends when the window shows another buffer.
      (delete-window (get-buffer-window input-a))
      (set-window-buffer chat-win chat-b)
      (pilish-pair-test--repair)
      (set-window-buffer (car (pilish-window-pair chat-win)) chat-a)
      (pilish-pair-test--repair)
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-dissolved-pair-gets-input-again ()
  "`pilish-dissolve-window-pair' returns a plain chat window the repair re-pairs."
  (pilish-pair-test--with-sessions
    (let* ((chat-win (selected-window))
           (input-win (pilish-pair-test--show chat-a chat-win)))
      (should (eq (pilish-dissolve-window-pair input-win) chat-win))
      (should-not (window-live-p input-win))
      (should-not (window-dedicated-p chat-win))
      (should (eq (pilish-dissolve-window-pair chat-win) chat-win))
      (pilish-pair-test--repair)
      (should (eq (window-buffer (cdr (pilish-window-pair chat-win))) input-a)))))

(ert-deftest pilish-pair-test-on-demand-input-not-reopened ()
  "On-demand input display leaves chat windows alone."
  (pilish-pair-test--with-sessions
    (let ((pilish-input-window-display 'on-demand))
      (switch-to-buffer chat-a)
      (pilish-pair-test--repair)
      (should-not (get-buffer-window input-a)))))

(ert-deftest pilish-pair-test-restored-layout-becomes-atomic-again ()
  "Pairs restored by `window-state-put' become atomic pairs again."
  (pilish-pair-test--with-sessions
    (pilish-pair-test--side-by-side chat-a chat-b)
    (let ((state (window-state-get (frame-root-window) t)))
      (delete-other-windows)
      (switch-to-buffer "*scratch*")
      (window-state-put state (frame-root-window) 'safe)
      (pilish-pair-test--repair)
      (should (= (length (window-list)) 4))
      (should (pilish-pair-test--consistent-p))
      (delete-other-windows (get-buffer-window chat-b))
      (should (= (length (window-list)) 2)))))

(ert-deftest pilish-pair-test-window-configuration-keeps-pairs ()
  "Restoring a window configuration (winner, tabs) keeps pairs intact."
  (pilish-pair-test--with-sessions
    (pilish-pair-test--side-by-side chat-a chat-b)
    (let ((config (current-window-configuration)))
      (delete-other-windows (get-buffer-window chat-a))
      (set-window-configuration config)
      (should (= (length (window-list)) 4))
      (should (pilish-pair-test--consistent-p)))))

(ert-deftest pilish-pair-test-repair-is-idempotent ()
  "A second repair pass changes nothing, and nested passes do nothing."
  (pilish-pair-test--with-sessions
    (let ((right (split-window nil nil 'right)))
      (set-window-buffer right chat-b)
      (switch-to-buffer input-a)
      (pilish-pair-test--repair)
      (let ((windows (window-list))
            (buffers (mapcar #'window-buffer (window-list))))
        (pilish-pair-test--repair)
        (should (equal (window-list) windows))
        (should (equal (mapcar #'window-buffer (window-list)) buffers)))
      (let ((pilish--repairing-pairs t))
        (switch-to-buffer chat-b)
        (pilish-repair-window-pairs (selected-frame))
        (should (eq (window-buffer (car (pilish-window-pair (selected-window))))
                    chat-a))))))

(ert-deftest pilish-pair-test-mode-installs-repair-hook ()
  "The mode adds and removes its global window change function."
  (pilish-pair-test--with-sessions
    (should (memq #'pilish-repair-window-pairs
                  (default-value 'window-buffer-change-functions)))
    (should (member pilish--pair-display-entry display-buffer-alist))
    (pilish-window-pairing-mode -1)
    (should-not (memq #'pilish-repair-window-pairs
                      (default-value 'window-buffer-change-functions)))
    (should-not (member pilish--pair-display-entry display-buffer-alist))))

(ert-deftest pilish-pair-test-fit-input-resizes-inside-pair ()
  "`fit' input windows grow and shrink inside their pair."
  (pilish-pair-test--with-sessions
    (let* ((pilish-input-window-height 'fit)
           (pilish-input-window-min-height 3)
           (chat-win (selected-window))
           (input-win (pilish-pair-test--show chat-a chat-win))
           (total (window-total-height (window-parent chat-win))))
      (should (= (window-total-height input-win) 3))
      (with-current-buffer input-a (insert "one\ntwo\nthree"))
      (pilish-fit-input-window input-win)
      (should (> (window-total-height input-win) 3))
      (should (= (window-total-height (window-parent chat-win)) total))
      (should (window-preserved-size input-win nil))
      (with-current-buffer input-a (erase-buffer))
      (pilish-fit-input-window input-win)
      (should (= (window-total-height input-win) 3)))))

(ert-deftest pilish-pair-test-hide-session-dissolves-pairs ()
  "Hiding a session leaves no half-open pair behind."
  (pilish-pair-test--with-sessions
    (pilish-pair-test--side-by-side chat-a chat-b)
    (with-current-buffer chat-a (pilish--hide-session-windows))
    (should-not (get-buffer-window input-a))
    (should-not (get-buffer-window chat-a))
    (pilish-pair-test--repair)
    (should (pilish-pair-test--consistent-p))
    (should (get-buffer-window input-b))))

(ert-deftest pilish-pair-test-evil-rotate-keeps-pairs ()
  "Pairs stay consistent when `evil-window-rotate-downwards' mixes halves.
Rotation moves window states one by one, so each column briefly shows one
session's input above another's chat; every chat keeps a pair."
  (skip-unless (require 'evil nil t))
  (pilish-pair-test--with-sessions
    (pilish-pair-test--side-by-side chat-a chat-b)
    (evil-window-rotate-downwards)
    (pilish-pair-test--repair)
    (should (pilish-pair-test--consistent-p))
    (should (= (length (window-list)) 4))
    (should (= (length (get-buffer-window-list chat-a)) 1))
    (should (= (length (get-buffer-window-list chat-b)) 1))))

(provide 'pilish-pair-test)
;;; pilish-pair-test.el ends here
