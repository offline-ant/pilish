;;; pilish-drafts-test.el --- Shared context and requester recovery tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Deterministic post-validation peer tests.  The runtime suite owns real socket
;; and hello validation; these tests pin snapshot and editor context semantics.

;;; Code:

(require 'ert)
(require 'pilish)
(require 'pilish-drafts)
(require 'pilish-test-common)

(defmacro pilish-drafts-test--session (&rest body)
  "Run BODY with a validated synthetic CHAT, INPUT, PROC and COMMANDS."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (pilish-test-with-rpc-session (chat input proc commands)
       (ignore chat input proc commands)
       (process-put proc 'pilish-detached t)
       (process-put proc 'pilish-mux '(:protocol 2 :muxId "draft-test" :piPid 42))
       (process-put proc 'pilish-input-context
                    '(:sessionFile "/synthetic/one.jsonl" :leafId "a" :contextId "fake-branch"))
       (process-put proc 'pilish-mux-generation 0)
       (process-put proc 'pilish-mux-live-generation 0)
       (process-put proc 'pilish-mux-applied-generation 0)
       (with-current-buffer chat
         (setq pilish--state (list :session-file "/synthetic/one.jsonl"))
         (setq pilish--draft-context '(:session-file "/synthetic/one.jsonl" :leaf-id "a")))
       (cl-letf (((symbol-function 'message) #'ignore)) ,@body))))

(defun pilish-drafts-test--image ()
  "Return one tiny materialized synthetic image."
  (pilish--make-prompt-image :name "test.png" :mime-type "image/png"
                             :byte-size 3 :data "YWJj"))

(defun pilish-drafts-test--entry (id parent &optional message)
  "Return flat synthetic entry ID with PARENT and optional MESSAGE."
  (append (list :id id :parentId (or parent :null) :type "message")
          (when message (list :message message))))

(cl-defun pilish-drafts-test--snapshot
    (&key (generation 1) (file "/synthetic/one.jsonl") (leaf "a")
          (reason "request") (entries [( :id "a" :parentId :null)]) (messages []))
  "Return a complete authoritative snapshot with the supplied identity."
  (list :type "pimux_snapshot" :generation generation :reason reason
        :session (list :file file :id "synthetic" :cwd default-directory :name :null)
        :leafId leaf :entries entries :messages messages :replay 0 :idle t
        :inputContext (list :sessionFile file :leafId leaf :contextId "fake-branch")
        :model '(:id "faux" :provider "faux") :thinkingLevel "high"
        :run '(:active :false :compacting :false :tailTruncated :false)))

(defun pilish-drafts-test--deliver (proc snapshot)
  "Deliver PROC's SNAPSHOT and matching live boundary."
  (pilish-test--stdout proc snapshot
                       (list :type "pimux_live" :generation (plist-get snapshot :generation))))

(ert-deftest pilish-drafts-test-file-move-suspends-text-image-and-followups ()
  "A new identity receives none of the old local work, including image data."
  (pilish-drafts-test--session
    (with-current-buffer input
      (insert "old draft")
      (pilish--set-prompt-image (pilish-drafts-test--image)))
    (with-current-buffer chat (pilish--push-followup "old follow-up"))
    (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot :file "/synthetic/two.jsonl"))
    (with-current-buffer input
      (should (equal (buffer-string) ""))
      (should-not (pilish--get-prompt-image)))
    (with-current-buffer chat
      (should-not pilish--followup-queue)
      (should (equal (plist-get pilish--state :session-file) "/synthetic/two.jsonl")))
    (let ((records (pilish-session-quarantine chat)))
      (should (= (length records) 2))
      (should (seq-every-p (lambda (record)
                            (equal (plist-get record :session-file) "/synthetic/one.jsonl"))
                          records))
      (should (seq-find (lambda (record)
                         (and (equal (plist-get record :draft) "old draft")
                              (equal (plist-get (car (plist-get record :images)) :data) "YWJj")))
                       records)))
    (should-not (seq-find (lambda (command) (equal (plist-get command :type) "prompt")) commands))))

(ert-deftest pilish-drafts-test-branch-move-is-not-linear-append ()
  "Only a true branch move suspends a same-file draft."
  (dolist (branch '(nil t))
    (pilish-drafts-test--session
      (with-current-buffer input (insert "context draft"))
      (with-current-buffer chat (pilish--push-followup "local next"))
      (pilish-drafts-test--deliver
       proc (pilish-drafts-test--snapshot
             :leaf "b" :entries (vector (pilish-drafts-test--entry "a" nil)
                                         (pilish-drafts-test--entry "b" (unless branch "a")))))
      (with-current-buffer input
        (should (equal (buffer-string) (if branch "" "context draft"))))
      (with-current-buffer chat
        (if branch
            (progn (should-not pilish--followup-queue)
                   (should (= (length (pilish-session-quarantine chat)) 2)))
          (should (equal pilish--followup-queue '("local next")))
          (should-not (pilish-session-quarantine chat)))))))

(ert-deftest pilish-drafts-test-missed-tree-move-after-unreported-live-leaf ()
  "A live appended message disambiguates a gap from append to a sibling branch."
  (pilish-drafts-test--session
    (let ((message '(:role "user" :content "observed live" :timestamp 17)))
      (with-current-buffer chat (setq pilish--canonical-messages (list message)))
      (with-current-buffer input (insert "draft based on observed live context"))
      (pilish-drafts-test--deliver
       proc (pilish-drafts-test--snapshot
             :reason "gap" :leaf "sibling"
             :entries (vector (pilish-drafts-test--entry "a" nil)
                               (pilish-drafts-test--entry "live-child" "a" message)
                               (pilish-drafts-test--entry "sibling" "a")))))
    (with-current-buffer input (should (equal (buffer-string) "")))
    (should (equal (plist-get (car (pilish-session-quarantine chat)) :origin) "branch-change"))))

(ert-deftest pilish-drafts-test-explicit-tree-navigation-suspends-even-descendant ()
  "An actual navigation request is a context move, not a message append."
  (pilish-drafts-test--session
    (with-current-buffer input (insert "old leaf"))
    (pilish-drafts-test--deliver
     proc (pilish-drafts-test--snapshot :reason "tree_changed" :leaf "b"
                                       :entries [(:id "a" :parentId :null)
                                                 (:id "b" :parentId "a")]))
    (should (pilish-session-quarantine chat))))

(ert-deftest pilish-drafts-test-ancestry-is-iterative-and-cycle-safe ()
  "Deep flat histories need no recursion; corrupt parent cycles refuse ancestry."
  (let ((entries (make-vector 5000 nil)))
    (dotimes (index 5000)
      (aset entries index (pilish-drafts-test--entry
                           (number-to-string index) (when (> index 0) (number-to-string (1- index))))))
    (should (pilish--snapshot-descends-from-p
             (pilish-drafts-test--snapshot :leaf "4999" :entries entries) "0")))
  (should-not
   (pilish--snapshot-descends-from-p
    (pilish-drafts-test--snapshot :leaf "a" :entries [(:id "a" :parentId "b")
                                                    (:id "b" :parentId "a")]) "missing")))

(ert-deftest pilish-drafts-test-uncertain-submission-late-response-cannot-restore ()
  "Pending acceptance/rejection belongs to the old context, never the new one."
  (dolist (success '(t :false))
    (pilish-drafts-test--session
      (with-current-buffer chat
        (pilish--send-prompt "possibly accepted" nil
                             (lambda () (pilish--restore-input-text "possibly accepted"))))
      (let ((prompt (car commands)))
        (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot :file "/synthetic/two.jsonl"))
        (pilish-test--stdout
         proc (list :type "response" :command "prompt" :id (plist-get prompt :id)
                    :success success :error "nope")))
      (with-current-buffer chat (should-not pilish--prompt-wait))
      (with-current-buffer input (should (equal (buffer-string) "")))
      (should (seq-find (lambda (record)
                         (and (equal (plist-get record :draft) "possibly accepted")
                              (plist-get record :uncertain)))
                       (pilish-session-quarantine chat))))))

(ert-deftest pilish-drafts-test-desktop-roundtrip-suspends-automatic-work ()
  "Restoring an editor is not permission to replay its queues or pending request."
  (pilish-drafts-test--session
    (with-current-buffer input
      (insert "saved draft")
      (pilish--set-prompt-image (pilish-drafts-test--image)))
    (with-current-buffer chat
      (pilish--push-followup "must not replay")
      (pilish--send-prompt "uncertain prior prompt")
      (let* ((state (append (list :session-file "/synthetic/one.jsonl")
                            (pilish--desktop-local-state)))
             (printed (prin1-to-string state)))
        (should-not (string-match-p "#<" printed))
        (pilish--invalidate-prompt-start-wait)
        (pilish--clear-followup-queue)
        (pilish--replace-input-draft input "")
        (pilish--restore-local-desktop-state (car (read-from-string printed)))
        (should-not pilish--followup-queue)
        (should-not pilish--prompt-wait)
        (should (= 2 (length (pilish-session-quarantine chat)))))
      (setq commands nil))
    (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot))
    (with-current-buffer input
      (should (equal (buffer-string) "saved draft"))
      (should (pilish--get-prompt-image)))
    (should-not (seq-find (lambda (command) (equal (plist-get command :type) "prompt")) commands))))

(ert-deftest pilish-drafts-test-desktop-foreign-context-retains-old-label ()
  "A restored draft compares its saved binding with the first authoritative view."
  (pilish-drafts-test--session
    (with-current-buffer chat
      (pilish--restore-local-desktop-state
       '(:session-file "/synthetic/old-desktop.jsonl" :leaf-id "old"
         :draft "saved for old desktop")))
    (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot))
    (with-current-buffer input (should (equal (buffer-string) "")))
    (should (equal (plist-get (car (pilish-session-quarantine chat)) :session-file)
                   "/synthetic/old-desktop.jsonl"))))

(ert-deftest pilish-drafts-test-reuse-requires-confirmation-and-never-sends ()
  "Even an explicit programmatic record selection must confirm cross-context reuse."
  (pilish-drafts-test--session
    (with-current-buffer chat
      (let* ((record (pilish--quarantine-input
                      "branch-change" (pilish--draft-context) :draft "old"))
             (identifier (plist-get record :id)))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
          (pilish-restore-quarantined-input identifier))
        (should (= 1 (length (pilish-session-quarantine chat))))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (pilish-restore-quarantined-input identifier))
        (should-not (pilish-session-quarantine chat))))
    (with-current-buffer input (should (equal (buffer-string) "old")))
    (should-not commands)))

(ert-deftest pilish-drafts-test-existing-image-is-not-silently-replaced ()
  "Image conflicts retain both recoverable payloads and the current draft."
  (pilish-drafts-test--session
    (with-current-buffer input (pilish--set-prompt-image (pilish-drafts-test--image)))
    (with-current-buffer chat
      (let ((record (pilish--quarantine-input
                     "old-image" (pilish--draft-context)
                     :images (list (pilish--image-desktop-state (pilish-drafts-test--image))))))
        (should-error (pilish-restore-quarantined-input (plist-get record :id)) :type 'user-error)))
    (should (= 1 (length (pilish-session-quarantine chat))))))

(ert-deftest pilish-drafts-test-notifications-without-text-change ()
  "Images, follow-ups and quarantine changes all notify desktop observers."
  (pilish-drafts-test--session
    (let* (notifications
           (pilish-session-desktop-state-functions
           (list (lambda (buffer) (push buffer notifications)))))
      (with-current-buffer input (pilish--set-prompt-image (pilish-drafts-test--image)))
      (with-current-buffer chat
        (pilish--push-followup "local")
        (pilish--quarantine-input "test" (pilish--draft-context) :draft "retained"))
      (should (= (length notifications) 3))
      (should (seq-every-p (lambda (buffer) (eq buffer chat)) notifications)))))

(ert-deftest pilish-drafts-test-editor-notice-is-recoverable-not-overwrite ()
  "Ambiguous replayed editor text is deduplicated, labelled and selectable."
  (pilish-drafts-test--session
    (with-current-buffer input (insert "local draft"))
    (let ((notice '(:type "pimux_editor_text" :noticeId 3 :text "ambiguous"
                   :sessionFile "/synthetic/old.jsonl" :truncated t)))
      (pilish-test--stdout proc notice notice))
    (with-current-buffer input (should (equal (buffer-string) "local draft")))
    (let ((records (pilish-session-quarantine chat)))
      (should (= 1 (length records)))
      (should (plist-get (car records) :truncated))
      (should (equal (plist-get (car records) :session-file) "/synthetic/old.jsonl")))
    (with-current-buffer chat
      (let* ((state (pilish--desktop-local-state))
             (record (car (pilish-session-quarantine chat))))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (pilish-restore-quarantined-input (plist-get record :id)))
        (setq pilish--input-quarantine nil)
        (pilish--replace-input-draft input "")
        (pilish--restore-local-desktop-state (plist-put state :quarantine nil))))
    (pilish-test--stdout proc '(:type "pimux_editor_text" :noticeId 3 :text "ambiguous"))
    (should-not (pilish-session-quarantine chat))))

(ert-deftest pilish-drafts-test-newer-gap-invalidates-partial-snapshot ()
  "Old live/generation records cannot enable input after a newer gap."
  (pilish-drafts-test--session
    (pilish-test--stdout proc (pilish-drafts-test--snapshot :generation 2))
    (should-not (pilish--shared-input-ready-p proc))
    (pilish-test--stdout proc '(:type "pimux_gap" :generation 4 :dropped 8)
                         '(:type "pimux_live" :generation 2)
                         (pilish-drafts-test--snapshot :generation 3))
    (should-not (pilish--shared-input-ready-p proc))
    (should (equal (process-get proc 'pilish-mux-generation) 2))
    (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot :generation 4))
    (should (pilish--shared-input-ready-p proc))))

(ert-deftest pilish-drafts-test-history-error-replaces-stale-transcript ()
  "An identity-only failure never presents another conversation's old history."
  (pilish-drafts-test--session
    (with-current-buffer chat (let ((inhibit-read-only t)) (insert "stale transcript")))
    (pilish-drafts-test--deliver
     proc (plist-put (pilish-drafts-test--snapshot :file "/synthetic/two.jsonl")
                     :historyError "too large"))
    (with-current-buffer chat
      (should-not (string-match-p "stale transcript" (buffer-string)))
      (should (string-match-p "History unavailable: too large" (buffer-string)))
      (should (equal (plist-get pilish--state :leaf-id) "a"))
      (should (equal (plist-get pilish--state :entries) [(:id "a" :parentId :null)])))))

(ert-deftest pilish-drafts-test-shared-clear-cancel-keeps-everything ()
  "Cancelling destructive shared clear sends nothing and changes no local queue."
  (pilish-drafts-test--session
    (with-current-buffer chat (pilish--push-followup "local"))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (with-current-buffer input (pilish-clear-queued-messages)))
    (should-not commands)
    (with-current-buffer chat (should (equal pilish--followup-queue '("local"))))
    (should-not (pilish-session-quarantine chat))))

(ert-deftest pilish-drafts-test-shared-clear-recovers-all-acknowledged-only ()
  "The requester receives all acknowledged text, not ownership-filtered guesses."
  (pilish-drafts-test--session
    (pilish-test--stdout proc '(:type "queue_update" :steering ["already delivered"] :followUp []))
    (with-current-buffer input (insert "current draft"))
    (with-current-buffer chat (pilish--push-followup "local"))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (with-current-buffer input (pilish-restore-queued-messages)))
    (should (equal (mapcar (lambda (command) (plist-get command :type)) commands) '("clear_queue")))
    (pilish-test--stdout
     proc (list :type "response" :command "clear_queue" :success t
                :id (plist-get (car commands) :id)
                :data '(:steering ["another frontend's steer"] :followUp ["all followups"])))
    (with-current-buffer input (should (equal (buffer-string) "current draft")))
    (let ((records (pilish-session-quarantine chat)))
      (should (= 2 (length records)))
      (should (seq-find
               (lambda (record)
                 (and (plist-get record :shared)
                      (equal (plist-get record :followups)
                             '("another frontend's steer" "all followups"))))
               records))
      (should-not (string-match-p "already delivered" (prin1-to-string records))))))

(ert-deftest pilish-drafts-test-shared-clear-uncertainty-never-fabricates-text ()
  "A failed or lost acknowledgment keeps local recovery and an uncertainty note."
  (pilish-drafts-test--session
    (with-current-buffer chat (pilish--push-followup "known local"))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (with-current-buffer input (pilish-clear-queued-messages)))
    (pilish-test--stdout
     proc (list :type "response" :command "clear_queue" :success :false
                :id (plist-get (car commands) :id) :error "connection lost"
                :data '(:steering ["not acknowledged"])))
    (let ((records (pilish-session-quarantine chat)))
      (should (= 2 (length records)))
      (should-not (string-match-p "not acknowledged" (prin1-to-string records)))
      (should (seq-find (lambda (record)
                         (equal (plist-get record :origin) "shared-queue-clear-uncertain"))
                       records)))
    (with-current-buffer input (should (equal (buffer-string) "")))))

(ert-deftest pilish-drafts-test-late-shared-clear-remembers-authorized-context ()
  "A delayed response is labelled with the context at clear, not at its arrival."
  (pilish-drafts-test--session
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (with-current-buffer input (pilish-clear-queued-messages)))
    (let ((request (car commands)))
      (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot :file "/synthetic/two.jsonl"))
      (pilish-test--stdout
       proc (list :type "response" :command "clear_queue" :success t
                  :id (plist-get request :id) :data '(:steering ["cleared from old"]))))
    (should (equal (plist-get (car (pilish-session-quarantine chat)) :session-file)
                   "/synthetic/one.jsonl"))
    (with-current-buffer input (should (equal (buffer-string) "")))))

(ert-deftest pilish-drafts-test-shared-abort-confirmation-and-recovery ()
  "Abort's shared helper confirms before clearing and never inserts global input."
  (pilish-drafts-test--session
    (with-current-buffer chat
      (pilish--push-followup "local")
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should-not (pilish--abort-shared-turn)))
      (should-not pilish--aborted)
      (should (equal pilish--followup-queue '("local")))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (should (pilish--abort-shared-turn))))
    (should (equal (reverse (mapcar (lambda (command) (plist-get command :type)) commands))
                   '("clear_queue" "abort")))
    (let ((request (cadr commands)))
      (pilish-test--stdout
       proc (list :type "response" :command "clear_queue" :success t
                  :id (plist-get request :id) :data '(:followUp ["shared pending"]))))
    (with-current-buffer input (should (equal (buffer-string) "")))
    (should (= 2 (length (pilish-session-quarantine chat))))))

(ert-deftest pilish-drafts-test-submitted-followup-has-one-recovery-owner ()
  "An uncertain FIFO owner is not also duplicated as an unsubmitted follow-up."
  (pilish-drafts-test--session
    (with-current-buffer chat
      (pilish--push-followup "submitted FIFO")
      (pilish--push-followup "not yet submitted")
      (pilish--process-followup-queue)
      (let ((state (pilish--desktop-local-state)))
        (should (equal (plist-get state :followups) '("not yet submitted")))
        (should (equal (plist-get (plist-get state :submitted) :text) "submitted FIFO"))))
    (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot :file "/synthetic/two.jsonl"))
    (let ((records (pilish-session-quarantine chat)))
      (should (= 2 (length records)))
      (should (= 1 (seq-count (lambda (record)
                               (equal (plist-get record :draft) "submitted FIFO"))
                             records))))))

(ert-deftest pilish-drafts-test-stale-boundary-does-not-disable-live-view ()
  "An old change, failure or live record cannot regress a newer live boundary."
  (pilish-drafts-test--session
    (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot :generation 7))
    (pilish-test--stdout proc '(:type "pimux_tree_changed" :generation 3)
                         '(:type "pimux_snapshot_failed" :generation 7 :error "obsolete")
                         '(:type "pimux_live" :generation 3))
    (should (pilish--shared-input-ready-p proc))))

(ert-deftest pilish-drafts-test-runtime-callbacks-see-authoritative-state ()
  "Readiness reaches the runtime only after identity, history and replay settle."
  (pilish-drafts-test--session
    (let (calls)
      (cl-letf (((symbol-function 'pilish--runtime-note-snapshot)
                 (lambda (_proc snapshot)
                   (should (equal (plist-get (plist-get snapshot :session) :file)
                                  "/synthetic/one.jsonl"))
                   (push 'snapshot calls)))
                ((symbol-function 'pilish--runtime-live)
                 (lambda (transport)
                   (should (pilish--shared-input-ready-p transport))
                   (should (equal (plist-get pilish--state :leaf-id) "a"))
                   (push 'live calls))))
        (pilish-drafts-test--deliver proc (pilish-drafts-test--snapshot)))
      (should (equal (reverse calls) '(snapshot live))))))

(provide 'pilish-drafts-test)
;;; pilish-drafts-test.el ends here
