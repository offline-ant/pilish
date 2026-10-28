;;; pilish-pair.el --- Keep chat and input windows together -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `pilish-window-pairing-mode' ties every chat window to the input
;; window below it.  The two form one atomic window (Info node `(elisp)
;; Atomic Windows'): `delete-window' in the chat closes both,
;; `delete-other-windows' in either keeps both, and splitting either
;; splits beside the pair.  `delete-window' in the input closes only the
;; input, as Pilish's own commands that close input windows expect; the
;; chat then stays alone until it shows another buffer.  Both halves are
;; soft-dedicated, so `display-buffer' shows other buffers elsewhere.
;;
;; A repair pass on `window-buffer-change-functions' keeps pairs
;; consistent when commands rearrange windows anyway:
;;
;; - `switch-to-buffer' (and other same-window displays) of a chat or
;;   input buffer in either half shows that session in the pair, also
;;   with `switch-to-buffer-obey-display-actions'.
;;
;; - A half that shows another session's chat or input buffer anyway
;;   switches the whole pair to that session.
;; - A half that shows any other buffer turns the pair's place over to
;;   that buffer: the other half closes.  (With
;;   `switch-to-buffer-obey-display-actions', `switch-to-buffer' shows
;;   such buffers beside the pair instead, like `display-buffer'.)
;; - A chat window without its input gets one below it (when
;;   `pilish-input-window-display' is `always'), unless its input was
;;   closed explicitly.  An input window without its chat gets the chat
;;   above it.
;; - Layouts restored with `window-state-put' (such as tabs copied to
;;   other frames) lose their atoms: their chat windows count as lone and
;;   get a fresh input window, replacing the restored one.
;;
;; Several pairs can share a frame, side by side or stacked.  The pass
;; only touches windows showing Pilish chat or input buffers and skips
;; side windows and child frames.

;;; Code:

(require 'cl-lib)
(require 'pilish-ui)

(defvar pilish--repairing-pairs nil
  "Non-nil while the pair repair pass changes windows.")

;;;; Pairs

(defun pilish-window-pair (window)
  "Return (CHAT-WINDOW . INPUT-WINDOW) for the pair holding WINDOW, or nil.
A pair is an atomic window with exactly two live children stacked
vertically, made by `pilish-split-input-window' while
`pilish-window-pairing-mode' is on.  The halves may show other buffers
until the next repair pass."
  (when-let* (((window-live-p window))
              (parent (window-parent window))
              ((window-parameter parent 'window-atom))
              ((window-combined-p window))
              ((= (window-child-count parent) 2))
              (top (window-child parent))
              (bottom (window-next-sibling top))
              ((window-live-p top))
              ((window-live-p bottom))
              ((window-parameter bottom 'pilish-pair-chat)))
    (cons top bottom)))

(defun pilish--pair-windows (chat-win input-win)
  "Make CHAT-WIN and INPUT-WIN below it one atomic pair.
They must be the only children of their parent window."
  (let ((chat (window-buffer chat-win)))
    (window-make-atom (window-parent chat-win))
    (set-window-parameter input-win 'pilish-pair-chat chat)
    (set-window-parameter input-win 'delete-window #'pilish--pair-delete-input)
    (set-window-parameter chat-win 'pilish-lone-chat nil)
    (dolist (window (list chat-win input-win))
      (set-window-dedicated-p window 'side)
      (set-window-parameter window 'delete-other-windows
                            #'pilish--pair-delete-other-windows))
    (window-preserve-size input-win nil t)))

(defun pilish--pair-delete-other-windows (window)
  "Make WINDOW's pair the only pair in its frame.
The `delete-other-windows' parameter of both halves: a pair that already
fills its frame stays as it is instead of signaling an error."
  (let ((root (window-atom-root window)))
    (unless (or (null root)
                (eq root (frame-root-window (window-frame window))))
      (delete-other-windows root))))

(defun pilish--pair-delete-input (window)
  "Delete input WINDOW alone; its chat window stays without an input.
The `delete-window' parameter of a pair's input half.  The chat window is
marked so the repair does not reopen the input while it shows the same
chat."
  (if-let* ((pair (pilish-window-pair window)))
      (let ((chat-win (pilish-dissolve-window-pair window)))
        (set-window-parameter chat-win 'pilish-lone-chat (window-buffer chat-win)))
    (let ((ignore-window-parameters t))
      (delete-window window))))

(defun pilish--unpair (pair)
  "Dissolve PAIR, a cons (CHAT-WINDOW . INPUT-WINDOW), into plain windows."
  (let ((parent (window-parent (car pair))))
    (when parent
      (set-window-parameter parent 'window-atom nil))
    (dolist (window (list (car pair) (cdr pair)))
      (when (window-live-p window)
        (set-window-parameter window 'window-atom nil)
        (set-window-parameter window 'pilish-pair-chat nil)
        (set-window-parameter window 'delete-window nil)
        (set-window-parameter window 'delete-other-windows nil)
        (when (eq (window-dedicated-p window) 'side)
          (set-window-dedicated-p window nil))))
    (when (window-live-p (cdr pair))
      (window-preserve-size (cdr pair) nil nil))))

(defun pilish--pair-show (pair chat input)
  "Show CHAT and its INPUT in PAIR, a cons of chat and input windows."
  (unless (eq (window-buffer (car pair)) chat)
    (set-window-buffer (car pair) chat))
  (unless (eq (window-buffer (cdr pair)) input)
    (set-window-buffer (cdr pair) input))
  (pilish--pair-windows (car pair) (cdr pair)))

(defun pilish--pair-split-chat (chat-win input-buf)
  "Split an INPUT-BUF window off CHAT-WIN as a new pair; return it.
Return nil when CHAT-WIN is too small."
  (when (pilish--window-can-split-for-input-p chat-win)
    ;; A new parent for exactly these two windows, never redirected to
    ;; an atom CHAT-WIN may already belong to.
    (let* ((window-combination-limit t)
           (ignore-window-parameters t)
           (input-win (split-window
                       chat-win (- (pilish--input-height-for-window chat-win))
                       'below)))
      (set-window-buffer input-win input-buf)
      (pilish--pair-windows chat-win input-win)
      input-win)))

(defun pilish--pair-input-window (chat-win input-buf)
  "Show INPUT-BUF below CHAT-WIN as a pair and return the input window.
When CHAT-WIN already belongs to a pair, that pair switches to CHAT-WIN's
chat buffer and INPUT-BUF.  Return nil when CHAT-WIN is too small.
`pilish-split-input-window' calls this while the mode is on."
  (if-let* ((pair (pilish-window-pair chat-win)))
      (progn
        (pilish--pair-show pair (window-buffer chat-win) input-buf)
        (cdr pair))
    (pilish--pair-split-chat chat-win input-buf)))

(defun pilish-dissolve-window-pair (window)
  "Turn WINDOW's chat and input pair into its chat window alone.
Delete the pair's input window and return the chat window, now an
ordinary window.  The pair repair adds an input below it again while it
shows a chat; `delete-window' on the input keeps the input closed
instead.  Return WINDOW when it belongs to no pair."
  (if-let* ((pair (pilish-window-pair window)))
      (progn
        (pilish--unpair pair)
        (when (window-deletable-p (cdr pair))
          (let ((ignore-window-parameters t))
            (delete-window (cdr pair))))
        (car pair))
    window))

(defun pilish--pair-chat-buffer-p (buffer)
  "Return non-nil when BUFFER is a live Pilish chat buffer."
  (and (buffer-live-p buffer)
       (eq (buffer-local-value 'major-mode buffer) 'pilish-chat-mode)))

(defun pilish--pair-input-buffer-p (buffer)
  "Return non-nil when BUFFER is a live Pilish input buffer."
  (and (buffer-live-p buffer)
       (eq (buffer-local-value 'major-mode buffer) 'pilish-input-mode)))

(defun pilish--pair-input-of (chat)
  "Return CHAT's live input buffer, or nil."
  (let ((input (buffer-local-value 'pilish--input-buffer chat)))
    (and (pilish--pair-input-buffer-p input) input)))

(defun pilish--pair-chat-of (input)
  "Return INPUT's live chat buffer, or nil."
  (let ((chat (buffer-local-value 'pilish--chat-buffer input)))
    (and (pilish--pair-chat-buffer-p chat) chat)))

(defun pilish--pair-eligible-window-p (window)
  "Return non-nil when the repair pass may change WINDOW."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side))
       (not (eq (window-dedicated-p window) t))))

(defun pilish--pair-split-input (input-win chat-buf)
  "Split a CHAT-BUF window above INPUT-WIN as a new pair; return it.
Return nil when INPUT-WIN is too small."
  (when (pilish--window-can-split-for-input-p input-win)
    (let* ((window-combination-limit t)
           (ignore-window-parameters t)
           (height (pilish--input-height-for-window input-win))
           (chat-win (split-window input-win height 'above)))
      (set-window-buffer chat-win chat-buf)
      (pilish--pair-windows chat-win input-win)
      chat-win)))


;;;; Repair

(defun pilish--repair-pair (pair)
  "Make PAIR show one session's chat and input, or dissolve it.
The half whose buffer changed since pairing decides (the top half when
both did): a chat or input buffer selects
that session for both halves, any other buffer takes the pair's place
alone."
  (pcase-let* ((`(,top . ,bottom) pair)
               (paired-chat (window-parameter bottom 'pilish-pair-chat))
               (paired-input (and (pilish--pair-chat-buffer-p paired-chat)
                                  (pilish--pair-input-of paired-chat)))
               (top-buffer (window-buffer top))
               (bottom-buffer (window-buffer bottom))
               (bottom-changed (and (not (eq bottom-buffer paired-input))
                                    (eq top-buffer paired-chat)))
               (window (if bottom-changed bottom top))
               (other (if bottom-changed top bottom))
               (buffer (window-buffer window))
               (chat (cond ((pilish--pair-chat-buffer-p buffer) buffer)
                           ((pilish--pair-input-buffer-p buffer)
                            (pilish--pair-chat-of buffer))))
               (input (and chat (pilish--pair-input-of chat))))
    (cond
     ((and (eq top-buffer chat) (eq bottom-buffer input))
      ;; Consistent; refresh the atom and dedication after restores.
      (unless (and (eq (window-dedicated-p top) 'side)
                   (eq (window-dedicated-p bottom) 'side)
                   (eq paired-chat chat))
        (pilish--pair-windows top bottom)))
     (input (pilish--pair-show pair chat input))
     (t
      (pilish--unpair pair)
      (when (and (window-live-p other) (window-deletable-p other))
        (let ((ignore-window-parameters t))
          (delete-window other)))))))

(defun pilish--frame-pilish-windows (frame)
  "Return FRAME's eligible windows showing chat or input buffers."
  (cl-remove-if-not
   (lambda (window)
     (and (pilish--pair-eligible-window-p window)
          (let ((buffer (window-buffer window)))
            (or (pilish--pair-chat-buffer-p buffer)
                (pilish--pair-input-buffer-p buffer)
                (window-parameter window 'pilish-pair-chat)))))
   (window-list frame 'no-mini (frame-first-window frame))))

(defun pilish--repair-frame-pairs (frame)
  "Repair the chat and input pairs of FRAME's windows."
  ;; Pairs first, so lone windows are only those outside every pair.
  (let (seen)
    (dolist (window (pilish--frame-pilish-windows frame))
      (when (window-live-p window)
        (let ((parent (window-parent window)))
          (unless (memq parent seen)
            (when-let* ((pair (pilish-window-pair window)))
              (push parent seen)
              (pilish--repair-pair pair)))))))
  ;; Lone chat windows get their input below them.  A lone window showing
  ;; the same input elsewhere is the pair's old half: it goes, before any
  ;; split, so deleting it never reshapes a pair made in this pass.
  (when (eq pilish-input-window-display 'always)
    (let ((lone (cl-remove-if-not
                 (lambda (window)
                   (let ((chat (window-buffer window)))
                     (and (pilish--pair-chat-buffer-p chat)
                          (pilish--pair-input-of chat)
                          (not (pilish-window-pair window))
                          (not (eq (window-parameter window 'pilish-lone-chat) chat)))))
                 (pilish--frame-pilish-windows frame))))
      (dolist (window lone)
        (dolist (other (get-buffer-window-list
                        (pilish--pair-input-of (window-buffer window)) 'no-mini frame))
          (when (and (pilish--pair-eligible-window-p other)
                     (not (pilish-window-pair other))
                     (window-deletable-p other))
            (let ((ignore-window-parameters t))
              (delete-window other)))))
      (dolist (window lone)
        (when (window-live-p window)
          (pilish--pair-split-chat window (pilish--pair-input-of (window-buffer window)))))))
  ;; Lone input windows get their chat above them.
  (dolist (window (pilish--frame-pilish-windows frame))
    (let ((input (window-buffer window)))
      (when (and (window-live-p window)
                 (pilish--pair-input-buffer-p input)
                 (not (pilish-window-pair window)))
        (when-let* ((chat (pilish--pair-chat-of input)))
          (pilish--pair-split-input window chat)
          (pilish-fit-input-window window))))))

(defun pilish-repair-window-pairs (&optional frame reopen)
  "Repair the chat and input window pairs of FRAME (default selected).
With REOPEN (interactively, a prefix argument), also reopen input windows
closed with `pilish-delete-input-window'.  Runs from
`window-buffer-change-functions' while `pilish-window-pairing-mode' is
on."
  (interactive (list nil current-prefix-arg))
  (let ((frame (or frame (selected-frame))))
    (when (and (not pilish--repairing-pairs)
               (frame-live-p frame)
               (not (frame-parent frame))
               (not (eq (frame-root-window frame) (minibuffer-window frame))))
      (let ((pilish--repairing-pairs t))
        (dolist (window (window-list frame 'no-mini))
          ;; A closed input applies to the chat it was closed for only.
          (when-let* ((chat (window-parameter window 'pilish-lone-chat)))
            (when (or reopen (not (eq chat (window-buffer window))))
              (set-window-parameter window 'pilish-lone-chat nil))))
        (with-demoted-errors "pilish: window pair repair: %S"
          (pilish--repair-frame-pairs frame))))))

;;;; Display

(defun pilish--display-in-pair-p (buffer-name action)
  "Return non-nil to show BUFFER-NAME in the selected pair.
That is when BUFFER-NAME is a chat or input buffer, ACTION asks for the
selected window (as `switch-to-buffer' does), and the selected window
belongs to a pair.  A `display-buffer-alist' condition."
  (let ((buffer (get-buffer buffer-name)))
    (and (or (pilish--pair-chat-buffer-p buffer)
             (pilish--pair-input-buffer-p buffer))
         (memq 'display-buffer-same-window (ensure-list (car-safe action)))
         (not (cdr (assq 'inhibit-same-window (cdr-safe action))))
         (pilish-window-pair (selected-window)))))

(defun pilish--display-buffer-in-pair (buffer _alist)
  "Show BUFFER's session in the selected pair; return BUFFER's window.
A `display-buffer' action function: the pair's halves are dedicated, so
`display-buffer-same-window' would show BUFFER elsewhere."
  (when-let* ((pair (pilish-window-pair (selected-window)))
              (chat (if (pilish--pair-chat-buffer-p buffer)
                        buffer
                      (pilish--pair-chat-of buffer)))
              (input (pilish--pair-input-of chat)))
    (pilish--pair-show pair chat input)
    (if (eq buffer chat) (car pair) (cdr pair))))

(defconst pilish--pair-display-entry
  '(pilish--display-in-pair-p pilish--display-buffer-in-pair)
  "The `display-buffer-alist' entry of `pilish-window-pairing-mode'.")

;;;###autoload
(define-minor-mode pilish-window-pairing-mode
  "Keep each Pilish chat window and its input window together.
Chat and input form one atomic window: deleting, maximizing, or
splitting either acts on both.  Switching either window to another
session's buffer switches both; switching it to any other buffer
replaces the pair.  Pairs broken by other commands are repaired when
windows change, and several pairs can share one frame.  Turning the
mode off leaves the windows in place as ordinary windows."
  :global t
  :group 'pilish
  (if pilish-window-pairing-mode
      (progn
        (add-hook 'window-buffer-change-functions #'pilish-repair-window-pairs)
        (add-to-list 'display-buffer-alist pilish--pair-display-entry)
        (dolist (frame (frame-list))
          (pilish-repair-window-pairs frame)))
    (remove-hook 'window-buffer-change-functions #'pilish-repair-window-pairs)
    (setq display-buffer-alist (delete pilish--pair-display-entry display-buffer-alist))
    (dolist (frame (frame-list))
      (dolist (window (window-list frame 'no-mini))
        (when-let* ((pair (pilish-window-pair window)))
          (pilish--unpair pair))))))

(provide 'pilish-pair)
;;; pilish-pair.el ends here
