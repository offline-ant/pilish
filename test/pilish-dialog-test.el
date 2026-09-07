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
              (setq editor (pilish-open-editor-dialog '(:id "cancel-with-abort" :title "Edit") process))
              (with-current-buffer input
                (insert "draft")
                (pilish-abort)
                (should-not (buffer-live-p editor))
                (should (equal (reverse commands) '("clear_queue" "editor-cancel" "abort")))
                ;; Aborting never rewrites the human draft.
                (should (equal (buffer-string) "draft"))))))
      (delete-directory dir t))))

(ert-deftest pilish-test-editor-separate-buffer-and-cancel-on-kill ()
  (let ((process (make-pipe-process :name "pilish-dialog-test" :noquery t))
        responses editor)
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'pilish--send-extension-ui-response)
                   (lambda (_ response) (push response responses))))
          (with-temp-buffer
            (insert "parent draft")
            (setq editor (pilish-open-editor-dialog
                          '(:id "editor-1" :title "Discuss" :prefill "line1\nline2") process))
            (should (equal (buffer-string) "parent draft"))
            (with-current-buffer editor
              (should (equal (buffer-string) "line1\nline2"))
              (pilish--editor-respond nil))
            (kill-buffer editor)
            (should (= (length responses) 1))
            (should (equal (plist-get (car responses) :value) "line1\nline2"))
            (setq editor (pilish-open-editor-dialog '(:id "editor-2" :title "Cancel") process))
            (kill-buffer editor)
            (should (plist-get (car responses) :cancelled))))
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
          (setq editor-one (pilish-open-editor-dialog '(:id "one" :title "One") one)
                editor-two (pilish-open-editor-dialog '(:id "two" :title "Two") two))
          (delete-process one)
          (should-not (buffer-live-p editor-one))
          (should (buffer-live-p editor-two))
          (should-not responses)
          (pilish--close-process-editors two)
          (should-not (buffer-live-p editor-two))
          (should (eq (caar responses) two))
          (should (plist-get (cdar responses) :cancelled))
          (should-not (process-get two 'pilish-editor-buffers))
          (should (process-live-p two)))
      (when (buffer-live-p editor-one) (kill-buffer editor-one))
      (when (buffer-live-p editor-two) (kill-buffer editor-two))
      (when (process-live-p one) (delete-process one))
      (delete-process two))))

(provide 'pilish-dialog-test)
;;; pilish-dialog-test.el ends here
