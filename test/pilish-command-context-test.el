;;; pilish-command-context-test.el --- Delayed action contexts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Menu/input/browser actions must keep the snapshot token captured before
;; yielding.  The owning mux, not a client-side identity guess, accepts or rejects
;; the resulting RPC.  The core helpers are explicit test doubles here: core's
;; validation and wire contract have their own suite.
;;; Code:
(require 'ert)
(require 'pilish)
(require 'pilish-test-common)

(defconst pilish-command-context-test--a
  '(:sessionFile "/tmp/command-a.jsonl" :leafId "branch-a" :contextId "context-a"))
(defconst pilish-command-context-test--b
  '(:sessionFile "/tmp/command-b.jsonl" :leafId "branch-b" :contextId "context-b"))

(defmacro pilish-command-context-test--with-view (&rest body)
  "Evaluate BODY with a synthetic ready shared view and explicit core doubles."
  (declare (indent 0) (debug t))
  `(let* ((chat (generate-new-buffer " *pilish-command-context-chat*"))
          (input (generate-new-buffer " *pilish-command-context-input*"))
          (proc (make-pipe-process :name "pilish-command-context-peer" :noquery t))
          (pilish-input-markdown-highlighting nil)
          (pilish-quit-without-confirmation t))
     (unwind-protect
         (with-current-buffer chat
           (pilish-chat-mode)
           (pilish--set-chat-session-identity temporary-file-directory "context")
           (setq pilish--process proc pilish--input-buffer input
                 pilish--status 'idle pilish--state
                 '(:session-file "/tmp/command-a.jsonl" :leaf-id "branch-a"))
           (with-current-buffer input
             (pilish-input-mode)
             (setq pilish--chat-buffer chat)
             (insert "original draft"))
           (process-put proc 'pilish-chat-buffer chat)
           (process-put proc 'pilish-mux '(:protocol 2 :muxId "context-owner"))
           (process-put proc 'pilish-input-context (copy-tree pilish-command-context-test--a))
           (cl-letf (((symbol-function 'pilish--capture-input-context)
                      (lambda (process)
                        (when (pilish--process-shared-p process)
                          (copy-tree (process-get process 'pilish-input-context)))))
                     ((symbol-function 'pilish--bind-input-context)
                      (lambda (command context)
                        (if context
                            (plist-put (copy-sequence command) :pimuxContext (copy-tree context))
                          (copy-sequence command))))
                     ((symbol-function 'pilish--shared-input-ready-p) (lambda (_) t)))
             ,@body))
       (when (process-live-p proc) (delete-process proc))
       (dolist (buffer (list input chat))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (setq pilish--process nil))
           (kill-buffer buffer))))))

(ert-deftest pilish-command-context-test-transition-captures-before-confirmation ()
  (pilish-command-context-test--with-view
    (let (sent)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b) t))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish-new-session))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a))
      (should (equal (plist-get sent :type) "new_session")))))

(ert-deftest pilish-command-context-test-model-picker-retains-pre-getter-context ()
  (pilish-command-context-test--with-view
    (let (sent)
      (cl-letf (((symbol-function 'pilish--rpc-sync)
                 (lambda (&rest _)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b)
                   '(:success t :data (:models [(:id "model" :name "Model" :provider "fake")]))))
                ((symbol-function 'completing-read) (lambda (&rest _) "Model [fake]"))
                ((symbol-function 'pilish--begin-model-change) (lambda (&rest _) 'request))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish-select-model))
      (should (equal (plist-get sent :type) "set_model"))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a)))))

(ert-deftest pilish-command-context-test-thinking-picker-retains-pre-getter-context ()
  (pilish-command-context-test--with-view
    (let (sent)
      (cl-letf (((symbol-function 'pilish--get-available-thinking-levels)
                 (lambda (&rest _)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b)
                   '("off" "high")))
                ((symbol-function 'completing-read) (lambda (&rest _) "high"))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish-select-thinking))
      (should (equal (plist-get sent :type) "set_thinking_level"))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a)))))

(ert-deftest pilish-command-context-test-name-prompt-retains-origin-and-does-not-relabel-new-context ()
  (pilish-command-context-test--with-view
    (let (sent)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b)
                   (setq pilish--session-name "new context name") "old context name"))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command callback)
                   (setq sent command) (funcall callback '(:success t)))))
        (call-interactively #'pilish-set-session-name))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a))
      (should (equal pilish--session-name "new context name")))))

(ert-deftest pilish-command-context-test-fork-binds-before-asynchronous-getter ()
  (pilish-command-context-test--with-view
    (let (getter sent)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ command callback)
                   (if (equal (plist-get command :type) "get_fork_messages")
                       (setq getter callback)
                     (setq sent command))))
                ((symbol-function 'completing-read)
                 (lambda (_ choices &rest _) (car (all-completions "" choices))))
                ((symbol-function 'y-or-n-p) (lambda (_) t)))
        (pilish-fork)
        (process-put proc 'pilish-input-context pilish-command-context-test--b)
        (funcall getter '(:success t :data (:messages [(:entryId "old-entry" :text "old turn")]))))
      (should (equal (plist-get sent :type) "fork"))
      (should (equal (plist-get sent :entryId) "old-entry"))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a)))))

(ert-deftest pilish-command-context-test-resume-preserves-explicit-selection-context ()
  (pilish-command-context-test--with-view
    (let (sent)
      (process-put proc 'pilish-input-context pilish-command-context-test--b)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish--resume-selected-session proc chat "/tmp/selected.jsonl"
                                         pilish-command-context-test--a))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a)))))

(ert-deftest pilish-command-context-test-custom-arguments-do-not-send-to-adopted-conversation ()
  (pilish-command-context-test--with-view
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (process-put proc 'pilish-input-context pilish-command-context-test--b)
                 "old arguments"))
              ((symbol-function 'pilish--prepare-and-send)
               (lambda (&rest _) (ert-fail "Stale slash command reached submission"))))
      (should-error (pilish--run-custom-command '(:name "custom")) :type 'user-error))
    (should (equal (with-current-buffer input (buffer-string)) "original draft"))))

(ert-deftest pilish-command-context-test-custom-picker-does-not-rebind-before-arguments ()
  (pilish-command-context-test--with-view
    (let ((pilish--commands '((:name "custom" :description "test"))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_ choices &rest _)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b)
                   (caar choices)))
                ((symbol-function 'read-string) (lambda (&rest _) "old arguments"))
                ((symbol-function 'pilish--prepare-and-send)
                 (lambda (&rest _) (ert-fail "Picker rebound an old command"))))
        (should-error (pilish-run-custom-command) :type 'user-error)))))

(ert-deftest pilish-command-context-test-runtime-confirmation-cannot-stop-a-replacement ()
  (pilish-command-context-test--with-view
    (let ((identity "old-runtime"))
      (cl-letf (((symbol-function 'pilish-session-runtime)
                 (lambda (_) (list :mux-id identity)))
                ((symbol-function 'yes-or-no-p) (lambda (_) (setq identity "new-runtime") t))
                ((symbol-function 'pilish-stop-runtime)
                 (lambda (&rest _) (ert-fail "Confirmation stopped a replacement runtime"))))
        (should-error (pilish-stop-agent) :type 'user-error)))))

(ert-deftest pilish-command-context-test-browser-rename-does-not-change-dispatch-after-prompt ()
  (pilish-command-context-test--with-view
    (let ((browser (generate-new-buffer " *pilish-command-context-browser*")) sent)
      (unwind-protect
          (with-current-buffer browser
            (setq pilish--chat-buffer chat)
            (cl-letf (((symbol-function 'pilish--session-browser-path-at-point)
                       (lambda () "/tmp/command-a.jsonl"))
                      ((symbol-function 'pilish--browse-session-file-matches-p) (lambda (&rest _) t))
                      ((symbol-function 'pilish-storage-managed-p) (lambda () t))
                      ((symbol-function 'read-string)
                       (lambda (&rest _)
                         (process-put proc 'pilish-input-context pilish-command-context-test--b)
                         (with-current-buffer chat
                           (setq pilish--state '(:session-file "/tmp/command-b.jsonl")))
                         "old name"))
                      ((symbol-function 'pilish--session-browser-fetch-and-render) #'ignore)
                      ((symbol-function 'pilish-storage-append-entry)
                       (lambda (&rest _) (ert-fail "Live rename fell back to disk")))
                      ((symbol-function 'pilish--rpc-async)
                       (lambda (_ command callback)
                         (setq sent command) (funcall callback '(:success :false :error "stale")))))
              (pilish-session-browser-rename)))
        (kill-buffer browser))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a)))))

(ert-deftest pilish-command-context-test-browser-switch-binds-before-yielding-guard ()
  (pilish-command-context-test--with-view
    (let ((pilish--chat-buffer chat) sent)
      (cl-letf (((symbol-function 'pilish--browse-transition-refused-p)
                 (lambda (&rest _)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b) nil))
                ((symbol-function 'pilish--browse-quit-when-settled) #'ignore)
                ((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (pilish--browse-switch-session "/tmp/selected.jsonl"))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a)))))

(ert-deftest pilish-command-context-test-selected-image-does-not-attach-to-an-adopted-draft ()
  (pilish-command-context-test--with-view
    (with-current-buffer input
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b)
                   "/synthetic/image.png"))
                ((symbol-function 'pilish--read-prompt-image) (lambda (_) 'selected-image))
                ((symbol-function 'pilish--set-prompt-image)
                 (lambda (&rest _) (ert-fail "Old-context image attached to new draft"))))
        (should-error (pilish-attach-image) :type 'user-error)))))

(ert-deftest pilish-command-context-test-steering-rejection-recovers-only-to-origin ()
  (pilish-command-context-test--with-view
    (let (sent reply recovery)
      (setq pilish--status 'streaming)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ command callback) (setq sent command reply callback)))
                ((symbol-function 'pilish--quarantine-input)
                 (lambda (reason context &rest payload) (setq recovery (list reason context payload)))))
        (should (pilish--send-steer-message "old instruction"))
        (process-put proc 'pilish-input-context pilish-command-context-test--b)
        (funcall reply '(:success :false :delivery "rejected" :error "stale context")))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a))
      (should (equal (plist-get (cadr recovery) :session-file) "/tmp/command-a.jsonl"))
      (should (equal (plist-get (caddr recovery) :draft) "old instruction"))
      (should-not (plist-get (caddr recovery) :uncertain)))))

(ert-deftest pilish-command-context-test-live-export-retains-pre-prompt-token ()
  (pilish-command-context-test--with-view
    (let (sent)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _)
                   (process-put proc 'pilish-input-context pilish-command-context-test--b)
                   "/tmp/old-export.html"))
                ((symbol-function 'pilish--rpc-async)
                 (lambda (_ command _callback) (setq sent command))))
        (call-interactively #'pilish-export-html))
      (should (equal (plist-get sent :pimuxContext) pilish-command-context-test--a)))))

(ert-deftest pilish-command-context-test-stopped-export-does-not-retarget-after-prompt ()
  (pilish-command-context-test--with-view
    (setq pilish--process nil)
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (setq pilish--state '(:session-file "/tmp/replacement.jsonl")) ""))
              ((symbol-function 'pilish-storage-export-session)
               (lambda (&rest _) (ert-fail "Export silently selected replacement file"))))
      (should-error (call-interactively #'pilish-export-html) :type 'user-error))))

(ert-deftest pilish-command-context-test-tree-label-refuses-replaced-projection ()
  (let ((section (pilish-tree-node-section :type 'tree-node))
        (pilish--tree-browser-loaded-file "/tmp/old-tree.jsonl")
        (pilish--tree-browser-fetch-token 1))
    (oset section value "shared-id")
    (cl-letf (((symbol-function 'magit-current-section) (lambda () section))
              ((symbol-function 'read-string)
               (lambda (&rest _)
                 (setq pilish--tree-browser-loaded-file "/tmp/new-tree.jsonl"
                       pilish--tree-browser-fetch-token 2)
                 "old label"))
              ((symbol-function 'pilish--browse-set-label)
               (lambda (&rest _) (ert-fail "Stale label reached another tree"))))
      (should-error (pilish-tree-browser-set-label) :type 'user-error))))

(ert-deftest pilish-command-context-test-generated-menu-action-retains-menu-origin ()
  (pilish-command-context-test--with-view
    (let* ((section (pilish--build-command-section
                     "Test" '((:name "old-custom")) 1 3 "E" 'ignore))
           (action (nth 2 (aref section 2))))
      (process-put proc 'pilish-input-context pilish-command-context-test--b)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "old arguments"))
                ((symbol-function 'pilish--prepare-and-send)
                 (lambda (&rest _) (ert-fail "Transient action rebound its context"))))
        (should-error (funcall action) :type 'user-error)))))

(ert-deftest pilish-command-context-test-late-command-catalog-does-not-rebuild-for-new-context ()
  (pilish-command-context-test--with-view
    (let (reply applied)
      (cl-letf (((symbol-function 'pilish--rpc-async)
                 (lambda (_ _command callback) (setq reply callback))))
        (pilish--fetch-commands proc (lambda (_) (setq applied t))))
      (process-put proc 'pilish-input-context pilish-command-context-test--b)
      (funcall reply '(:success t :data (:commands [(:name "old-catalog-command")])))
      (should-not applied))))

(ert-deftest pilish-command-context-test-unshared-command-keeps-native-behavior ()
  (pilish-command-context-test--with-view
    (let (sent)
      (process-put proc 'pilish-mux nil)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "native args"))
                ((symbol-function 'pilish--prepare-and-send) (lambda (text) (setq sent text))))
        (pilish--run-custom-command '(:name "native")))
      (should (equal sent "/native native args")))))

(provide 'pilish-command-context-test)
;;; pilish-command-context-test.el ends here
