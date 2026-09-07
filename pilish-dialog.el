;;; pilish-dialog.el --- Native RPC multiline editor -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A standard extension editor dialog owns a separate buffer, never the prompt
;; draft.  Completion is asynchronous: Emacs remains usable while it is open.

;;; Code:

(require 'pilish-core)

(defvar-local pilish--dialog-process nil
  "Pi process that owns this editor request.")
(defvar-local pilish--dialog-id nil
  "Unanswered RPC editor request ID, or nil after responding.")

(defun pilish--editor-respond (cancelled)
  "Answer the current editor, setting CANCELLED when it was dismissed."
  (when pilish--dialog-id
    (let ((id pilish--dialog-id)
          (text (buffer-substring-no-properties (point-min) (point-max))))
      (setq pilish--dialog-id nil)
      (when (processp pilish--dialog-process)
        (process-put pilish--dialog-process 'pilish-editor-buffers
                     (delq (current-buffer)
                           (process-get pilish--dialog-process 'pilish-editor-buffers))))
      (when (and (processp pilish--dialog-process)
                 (process-live-p pilish--dialog-process))
        (pilish--send-extension-ui-response
         pilish--dialog-process
         (append (list :type "extension_ui_response" :id id)
                 (if cancelled (list :cancelled t) (list :value text))))))))

(defun pilish-editor-submit ()
  "Submit the multiline editor without modifying the session draft."
  (interactive)
  (pilish--editor-respond nil)
  (quit-window t))

(defun pilish-editor-cancel ()
  "Cancel the multiline editor without modifying the session draft."
  (interactive)
  (pilish--editor-respond t)
  (quit-window t))

(defun pilish--editor-killed ()
  "Cancel the request if its editor buffer is killed before submission."
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

(defun pilish-open-editor-dialog (event process)
  "Open the standard editor request EVENT belonging to PROCESS.
Return the new buffer immediately; responding happens through its commands."
  (let ((buffer (generate-new-buffer
                 (format "*Pi editor: %s*" (plist-get event :title)))))
    (with-current-buffer buffer
      (pilish-editor-mode)
      (setq pilish--dialog-process process
            pilish--dialog-id (plist-get event :id))
      (insert (or (plist-get event :prefill) "")))
    (process-put process 'pilish-editor-buffers
                 (cons buffer (process-get process 'pilish-editor-buffers)))
    (pop-to-buffer buffer)
    buffer))

(provide 'pilish-dialog)
;;; pilish-dialog.el ends here
