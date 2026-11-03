;;; pilish-drafts.el --- Context-bound local input recovery -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Local text, materialized images and unsent follow-ups belong to a file and
;; branch, not to a socket.  Authoritative snapshots compare that context before
;; replay can release follow-ups.  Replacement suspends input in recoverable,
;; serializable records.  Recovery always requires explicit selection and reuse;
;; it never sends a prompt or restores an automatic queue.

;;; Code:

(require 'pilish-ui)

(declare-function pilish--shared-session-file "pilish-shared" (session))
(declare-function pilish--add-chat-notice "pilish-render" (text face))
(declare-function pilish--followup-submitted-p "pilish-queue" ())
(declare-function pilish--take-unsubmitted-followups "pilish-queue" ())

(defvar-local pilish--draft-context nil
  "Last authoritative local input context, with file and leaf identity.")
(defvar-local pilish--input-quarantine nil
  "Recoverable input records, newest first; never an automatic send queue.")
(defvar-local pilish--submitted-input nil
  "Text/image ownership of the current unacknowledged prompt, or nil.")
(defvar-local pilish--editor-notice-watermarks nil
  "Alist of mux identities and latest editor notice IDs already observed.")
(defvar pilish--quarantine-counter 0
  "Monotonic local discriminator for recovery record labels.")

(defun pilish--context-message-digest (message)
  "Return a compact stable identity for persisted MESSAGE's context content."
  (when message
    (secure-hash 'sha256
                 (prin1-to-string
                  (list (plist-get message :role) (plist-get message :timestamp)
                        (plist-get message :content) (plist-get message :customType)
                        (plist-get message :toolCallId))))))

(defun pilish--draft-context ()
  "Return the current file/branch binding for local work.
Remember the latest authoritative message too: Pi does not emit leaf IDs for
ordinary live appends, so a missed later tree move must not look like append."
  (let ((context (copy-tree
                  (or pilish--draft-context
                      (list :session-file (plist-get pilish--state :session-file)
                            :leaf-id (plist-get pilish--state :leaf-id)))))
        (tail (car (last (append pilish--canonical-messages nil)))))
    (when (and (not (plist-get context :runtime-context))
               (processp pilish--process)
               (pilish--valid-input-context-p
                (process-get pilish--process 'pilish-input-context)))
      (setq context (plist-put context :runtime-context
                               (copy-tree (process-get pilish--process 'pilish-input-context)))))
    (if tail (plist-put context :tail-digest (pilish--context-message-digest tail))
      context)))

(defun pilish--image-desktop-state (image)
  "Return plain serializable data for materialized IMAGE, or nil."
  (when image
    (list :name (substring-no-properties (pilish--prompt-image-name image))
          :mime-type (pilish--prompt-image-mime-type image)
          :byte-size (pilish--prompt-image-byte-size image)
          :data (substring-no-properties (pilish--prompt-image-data image)))))

(defun pilish--image-from-desktop-state (image)
  "Validate and materialize saved IMAGE without reading any file."
  (unless (and (listp image) (stringp (plist-get image :name))
               (member (plist-get image :mime-type)
                       '("image/png" "image/jpeg" "image/gif" "image/webp"))
               (natnump (plist-get image :byte-size))
               (<= (plist-get image :byte-size) pilish-prompt-image-max-bytes)
               (stringp (plist-get image :data)))
    (error "Invalid saved prompt image; original desktop state is retained"))
  (pilish--make-prompt-image
   :name (plist-get image :name) :mime-type (plist-get image :mime-type)
   :byte-size (plist-get image :byte-size) :data (plist-get image :data)))

(defun pilish--draft-text ()
  "Return the whole linked input buffer as plain text."
  (if (not (buffer-live-p pilish--input-buffer)) ""
    (with-current-buffer pilish--input-buffer
      (save-restriction
        (widen)
        (buffer-substring-no-properties (point-min) (point-max))))))

(defun pilish--draft-images ()
  "Return the current input image as a plain list, or nil."
  (when-let* ((image (pilish--get-prompt-image pilish--input-buffer)))
    (list (pilish--image-desktop-state image))))

(defun pilish-session-quarantine (buffer)
  "Return a plain copy of BUFFER's recoverable input, newest first.
Records contain :id, :origin, :session-file, :leaf-id, :draft, :images,
:followups and :uncertain.  They contain no process, marker or live queue."
  (when (buffer-live-p buffer)
    (copy-tree (buffer-local-value 'pilish--input-quarantine buffer))))

(defun pilish--quarantine-record (origin context payload)
  "Build an ORIGIN recovery record bound to CONTEXT with PAYLOAD."
  (append (list :id (format "%s-%d" (format-time-string "%s%N")
                           (cl-incf pilish--quarantine-counter))
                :origin origin
                :session-file (plist-get context :session-file)
                :leaf-id (plist-get context :leaf-id))
          (copy-tree payload)))

(defun pilish--quarantine-input (origin context &rest payload)
  "Retain PAYLOAD as an ORIGIN recovery record bound to CONTEXT.
PAYLOAD is a plist of :draft, :images, :followups, :uncertain and optional
:notice-key/:truncated metadata.  Return the new record."
  (let ((record (pilish--quarantine-record origin context payload)))
    (push record pilish--input-quarantine)
    (pilish--note-desktop-local-state)
    (pilish--refresh-input-preamble)
    record))

(defun pilish--suspend-close-followups ()
  "Retain unsent follow-ups for explicit recovery before any Close observer.
The in-flight FIFO owner keeps its existing acknowledgement callback."
  (let* ((followups (pilish--followups-in-fifo-order))
         (unsent (if (pilish--followup-submitted-p) (cdr followups) followups)))
    (when unsent
      (push (pilish--quarantine-record "Agent Close" (pilish--draft-context) (list :followups unsent))
            pilish--input-quarantine)
      ;; Both recovery and queue state are committed before UI notifications.
      (pilish--take-unsubmitted-followups))))

(defun pilish--recovery-followups ()
  "Return genuinely unsubmitted follow-ups, excluding a pending FIFO owner."
  (let ((followups (pilish--followups-in-fifo-order)))
    (if (and pilish--submitted-input
             (pilish--prompt-start-wait-active-p)
             (pilish--prompt-wait-followup pilish--prompt-wait)
             (not (pilish--prompt-wait-accepted pilish--prompt-wait)))
        (cdr followups)
      followups)))

(defun pilish--quarantine-local-work (reason context)
  "Suspend the current draft, image and local submissions for REASON.
Bind all recovered work to CONTEXT.  No Pi-owned queue is inferred or cleared."
  (let ((draft (pilish--draft-text))
        (images (pilish--draft-images))
        (followups (pilish--recovery-followups))
        (submitted pilish--submitted-input))
    (when (or images (not (string-empty-p draft)))
      (pilish--quarantine-input reason context :draft draft :images images)
      (pilish--replace-input-draft pilish--input-buffer ""))
    (when followups
      (pilish--quarantine-input
       (concat reason "-followups") context :followups followups
       :uncertain (and (pilish--prompt-start-wait-active-p) t)))
    (when submitted
      (pilish--quarantine-input
       (concat reason "-submission") context
       :draft (plist-get submitted :text) :images (plist-get submitted :images)
       :uncertain t))
    ;; Invalidate correlated callbacks before snapshot replay can settle a run.
    ;; An old acceptance/rejection must not return its input to a new branch.
    (pilish--invalidate-prompt-start-wait)
    (setq pilish--submitted-input nil)
    (pilish--clear-followup-queue)
    (when (or images (not (string-empty-p draft)) followups submitted)
      (message "Pi: Previous-context input suspended; M-x pilish-restore-quarantined-input recovers it explicitly"))))

(defun pilish--snapshot-descends-from-p (snapshot ancestor)
  "Return non-nil if SNAPSHOT's leaf descends from ANCESTOR.
Use its flat :entries only, iteratively; never read a conversation file.
A missing path is uncertainty, not evidence that a branch stayed unchanged."
  (let ((leaf (pilish--normalize-string-or-null (plist-get snapshot :leafId)))
        (parents (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal)))
    (dolist (entry (append (plist-get snapshot :entries) nil))
      (when (stringp (plist-get entry :id))
        (puthash (plist-get entry :id)
                 (pilish--normalize-string-or-null (plist-get entry :parentId))
                 parents)))
    (or (null ancestor)
        (catch 'found
          (while (and leaf (not (gethash leaf seen)))
            (when (equal leaf ancestor) (throw 'found t))
            (puthash leaf t seen)
            (setq leaf (gethash leaf parents)))
          nil))))

(defun pilish--draft-adopt-context (snapshot)
  "Bind local work to SNAPSHOT, suspending it before an actual context move.
An ordinary append keeps a draft.  A file replacement, explicit tree move or
non-descendant leaf quarantines it, including after a missed change/gap."
  (let* ((old (pilish--draft-context))
         (file (pilish--shared-session-file (plist-get snapshot :session)))
         (leaf (pilish--normalize-string-or-null (plist-get snapshot :leafId)))
         (old-file (plist-get old :session-file))
         (old-leaf (plist-get old :leaf-id))
         (tail (plist-get old :tail-digest))
         (tail-entry
          (when tail
            (seq-find (lambda (entry)
                        (equal tail (pilish--context-message-digest
                                     (plist-get entry :message))))
                      (reverse (append (plist-get snapshot :entries) nil)))))
         (changed
          (or (and old-file (not (equal old-file file)))
              (and (plist-get old :runtime-context)
                   (pilish--valid-input-context-p (plist-get snapshot :inputContext))
                   (not (equal (plist-get (plist-get old :runtime-context) :contextId)
                               (plist-get (plist-get snapshot :inputContext) :contextId))))
              (and (equal old-file file) (not (equal old-leaf leaf))
                   (or (equal (plist-get snapshot :reason) "tree_changed")
                       (not (pilish--snapshot-descends-from-p snapshot old-leaf))))
              (and old-file (equal old-file file) tail
                   (or (null tail-entry)
                       (not (pilish--snapshot-descends-from-p
                             snapshot (plist-get tail-entry :id))))))))
    (when changed
      (pilish--quarantine-local-work
       (if (equal old-file file) "branch-change" "session-change") old))
    (setq pilish--draft-context
          (list :session-file file :leaf-id leaf
                :runtime-context (copy-tree (plist-get snapshot :inputContext))))
    (pilish--note-desktop-local-state)))

(defun pilish--draft-submission-noted (text image wait)
  "Bind submitted TEXT and IMAGE to opaque request WAIT.
This is recovery evidence, not permission to repeat an uncertain request."
  (setq pilish--submitted-input
        (list :text (substring-no-properties text)
              :images (when image (list (pilish--image-desktop-state image)))
              :wait wait))
  (pilish--note-desktop-local-state))

(defun pilish--draft-submission-ended (wait)
  "Forget submission evidence only when WAIT is still its owner."
  (when (eq (plist-get pilish--submitted-input :wait) wait)
    (setq pilish--submitted-input nil)
    (pilish--note-desktop-local-state)))

(defun pilish--desktop-local-state ()
  "Return serializable local input state for the desktop owner.
In-flight requests are marked uncertain; no process/marker is serialized."
  (let ((context (pilish--draft-context)))
    (list :draft (pilish--draft-text) :images (pilish--draft-images)
          :followups (copy-sequence (pilish--recovery-followups))
          :quarantine (copy-tree pilish--input-quarantine)
          :leaf-id (plist-get context :leaf-id)
          :context (copy-tree context)
          :editor-notices (copy-tree pilish--editor-notice-watermarks)
          :submitted (when pilish--submitted-input
                       (list :text (plist-get pilish--submitted-input :text)
                             :images (copy-tree
                                      (plist-get pilish--submitted-input :images))
                             :uncertain t)))))

(defun pilish--restore-local-desktop-state (state)
  "Restore STATE's local editor without arming any saved automatic work.
Keep its original context until the first authoritative snapshot compares it.
Saved follow-ups and uncertain submissions become explicit recovery records."
  (let* ((images (plist-get state :images))
         (image (when images (pilish--image-from-desktop-state (car images))))
         (context (or (plist-get state :context)
                      (list :session-file (plist-get state :session-file)
                            :leaf-id (plist-get state :leaf-id)))))
    (when (cdr images) (error "A saved draft has more than one image"))
    (when (or (not (string-empty-p (pilish--draft-text))) (pilish--draft-images)
              pilish--followup-queue pilish--submitted-input)
      (pilish--quarantine-local-work "desktop-replacement" (pilish--draft-context)))
    (setq pilish--input-quarantine
          (append (copy-tree (plist-get state :quarantine)) pilish--input-quarantine)
          pilish--draft-context (copy-tree context)
          pilish--editor-notice-watermarks (copy-tree (plist-get state :editor-notices)))
    (pilish--replace-input-draft pilish--input-buffer (or (plist-get state :draft) ""))
    (when image (pilish--set-prompt-image image pilish--input-buffer))
    (when-let* ((followups (plist-get state :followups)))
      (pilish--quarantine-input "desktop-followups" context :followups followups))
    (when-let* ((submitted (plist-get state :submitted)))
      (pilish--quarantine-input "desktop-submission" context
                               :draft (plist-get submitted :text)
                               :images (plist-get submitted :images) :uncertain t))
    (pilish--note-desktop-local-state)
    (pilish--refresh-input-preamble)))

(defun pilish--recover-editor-notice (proc notice)
  "Retain PROC's ambiguous editor NOTICE instead of overwriting a draft."
  (let* ((mux (plist-get (pilish--process-shared-p proc) :muxId))
         (number (plist-get notice :noticeId))
         (seen (assoc mux pilish--editor-notice-watermarks)))
    (when (and (stringp mux) (integerp number)
               (> number (or (cdr seen) 0)))
      (if seen (setcdr seen number)
        (push (cons mux number) pilish--editor-notice-watermarks))
      (pilish--quarantine-input
       "ambiguous-editor-text"
       (list :session-file (pilish--normalize-string-or-null
                            (plist-get notice :sessionFile)))
       :draft (or (plist-get notice :text) "")
       :notice-key (cons mux number) :uncertain t
       :truncated (eq (plist-get notice :truncated) t))
      (pilish--add-chat-notice
       (concat "Pi offered editor text with ambiguous origin; recover it explicitly."
               (when (eq (plist-get notice :truncated) t)
                 " The recovery text is truncated, not complete."))
       'pilish-retry-notice))))

;;;###autoload
(defun pilish-restore-quarantined-input (&optional identifier)
  "Explicitly select suspended input and reuse it in the current draft.
IDENTIFIER optionally selects a record ID, but never bypasses confirmation.
Recovered automatic follow-ups become ordinary draft text, never a queue."
  (interactive)
  (let ((chat (pilish--get-chat-buffer)))
    (unless (buffer-live-p chat) (user-error "No Pi session for this buffer"))
    (with-current-buffer chat
      (unless pilish--input-quarantine (user-error "No suspended input"))
      (let* ((choices
              (mapcar
               (lambda (record)
                 (cons (format "%s | %s | leaf %s%s%s | %s"
                               (plist-get record :id) (plist-get record :origin)
                               (or (plist-get record :leaf-id) "root/unknown")
                               (if (plist-get record :uncertain) " | delivery/origin uncertain" "")
                               (if (plist-get record :truncated) " | TRUNCATED" "")
                               (or (plist-get record :session-file) "unknown file"))
                       record))
               pilish--input-quarantine))
             (record (if identifier
                         (seq-find (lambda (item) (equal (plist-get item :id) identifier))
                                   pilish--input-quarantine)
                       (cdr (assoc (completing-read "Recover input: " choices nil t)
                                   choices)))))
        (unless record (user-error "Recovery record not found"))
        (unless (or (plist-get record :draft) (plist-get record :images)
                    (plist-get record :followups))
          (user-error "No acknowledged input to recover: %s"
                      (or (plist-get record :diagnostic) "Operation outcome uncertain")))
        (when (and (plist-get record :images) (pilish--draft-images))
          (user-error "The current draft already has an image; retain/remove it before recovering another"))
        (unless (buffer-live-p pilish--input-buffer) (user-error "No input buffer"))
        (when (yes-or-no-p
               (format "Reuse input from %s (leaf %s) in this context%s?  Nothing will be sent.  Confirm reuse? "
                       (or (plist-get record :session-file) "unknown context")
                       (or (plist-get record :leaf-id) "root/unknown")
                       (if (plist-get record :uncertain)
                           "; it may already have been accepted elsewhere" "")))
          (let* ((texts (append (when-let* ((text (plist-get record :draft))
                                           ((not (string-empty-p text))))
                                  (list text))
                               (plist-get record :followups)))
                 (images (plist-get record :images))
                 (image (when images (pilish--image-from-desktop-state (car images)))))
            (when (cdr images) (user-error "Recovery record has more than one image"))
            (pilish--restore-input-text (string-join texts "\n\n") image)
            (setq pilish--input-quarantine (delq record pilish--input-quarantine))
            (pilish--note-desktop-local-state)
            (pilish--refresh-input-preamble)
            (message "Pi: Recovered input into the draft; nothing was submitted")))))))

(provide 'pilish-drafts)
;;; pilish-drafts.el ends here
