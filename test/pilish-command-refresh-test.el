;;; pilish-command-refresh-test.el --- Read-only catalog refresh -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Exercise real core framing and callbacks while a shared snapshot has not yet
;; installed its input capability.  A catalog read must not require mutation
;; permission, and a reply must not repaint a superseded runtime/session boundary.
;;; Code:
(require 'ert)
(require 'pilish)

(defmacro pilish-command-refresh-test--with-peer (&rest body)
  "Run BODY with a synthetic detached peer using the actual core RPC helpers."
  (declare (indent 0) (debug t))
  `(let* ((proc (make-pipe-process :name "pilish-command-refresh-peer" :noquery t))
          (context '(:sessionFile "/tmp/catalog.jsonl" :leafId "branch" :contextId "catalog-context"))
          sent)
     (unwind-protect
         (progn
           (process-put proc 'pilish-detached t)
           (process-put proc 'pilish-mux '(:protocol 2 :muxId "catalog-runtime"))
           (process-put proc 'pilish-mux-generation 7)
           (process-put proc 'pilish-mux-awaiting-snapshot t)
           (cl-letf (((symbol-function 'process-send-string)
                      (lambda (_ string)
                        (setq sent (json-parse-string string :object-type 'plist)))))
             ,@body))
       (when (process-live-p proc) (delete-process proc)))))

(ert-deftest pilish-command-refresh-test-pending-snapshot-read-completes-with-installed-token ()
  (pilish-command-refresh-test--with-peer
    (let (catalog)
      (should-error (pilish--capture-input-context proc) :type 'user-error)
      (pilish--fetch-commands proc (lambda (commands) (setq catalog commands)))
      (should (equal (plist-get sent :type) "get_commands"))
      (should-not (plist-member sent :pimuxContext))
      (process-put proc 'pilish-input-context context)
      (process-put proc 'pilish-mux-applied-generation 7)
      (process-put proc 'pilish-mux-live-generation 7)
      (process-put proc 'pilish-mux-awaiting-snapshot nil)
      (pilish--dispatch-response
       proc (list :type "response" :command "get_commands" :id (plist-get sent :id)
                  :success t :data '(:commands [(:name "current-command")])))
      (should (equal (plist-get (car catalog) :name) "current-command"))
      (should (pilish--shared-input-ready-p proc)))))

(ert-deftest pilish-command-refresh-test-pending-read-does-not-repaint-new-generation ()
  (pilish-command-refresh-test--with-peer
    (let (called)
      (pilish--fetch-commands proc (lambda (_) (setq called t)))
      (process-put proc 'pilish-mux-generation 8)
      (process-put proc 'pilish-input-context context)
      (pilish--dispatch-response
       proc (list :type "response" :command "get_commands" :id (plist-get sent :id)
                  :success t :data '(:commands [(:name "old-command")])))
      (should-not called))))

(ert-deftest pilish-command-refresh-test-pending-read-does-not-repaint-new-runtime ()
  (pilish-command-refresh-test--with-peer
    (let (called)
      (pilish--fetch-commands proc (lambda (_) (setq called t)))
      (process-put proc 'pilish-mux '(:protocol 2 :muxId "replacement-runtime"))
      (process-put proc 'pilish-input-context context)
      (pilish--dispatch-response
       proc (list :type "response" :command "get_commands" :id (plist-get sent :id)
                  :success t :data '(:commands [(:name "old-command")])))
      (should-not called))))

(ert-deftest pilish-command-refresh-test-unavailable-token-does-not-authorize-built-menu-actions ()
  (pilish-command-refresh-test--with-peer
    (cl-letf (((symbol-function 'pilish--get-process) (lambda () proc)))
      (let* ((section (pilish--build-command-section
                       "Extensions" '((:name "example")) 1 3 "E" 'ignore))
             (action (nth 2 (aref section 2))))
        (should (functionp action))
        (process-put proc 'pilish-input-context context)
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "arguments"))
                  ((symbol-function 'pilish--command-chat-buffer-or-error) #'current-buffer)
                  ((symbol-function 'pilish--prepare-and-send)
                   (lambda (&rest _) (ert-fail "Unavailable menu capability rebound at activation"))))
          (should-error (funcall action) :type 'user-error)
          (should-not sent))))))

(provide 'pilish-command-refresh-test)
;;; pilish-command-refresh-test.el ends here
