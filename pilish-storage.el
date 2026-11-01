;;; pilish-storage.el --- Cooperative stopped-session mutations -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Managed browsers never write beside a live Pi writer.  This module invokes
;; a narrow Node helper from the same pinned Pilish source.  The helper imports
;; the configured compiled pimux's public claim library and holds a stopped-file
;; lease around the entire mutation.  It never opens a session with raw Pi.
;; Explicit unshared Pilish keeps its native storage policy in the browser.
;; Live managed name changes and exports use their existing owning RPC commands;
;; other active-file mutations refuse rather than bypass the runtime's claim.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function pilish-runtime-configured-p "pilish-runtime" ())
(defvar pilish-runtime-pimux-executable)

(defconst pilish--storage-helper
  (expand-file-name "scripts/pilish-storage.mjs"
                    (file-name-directory
                     (or load-file-name byte-compile-current-file buffer-file-name)))
  "Path to this pinned source's narrow stopped-session helper.")

(defun pilish-storage-managed-p ()
  "Return non-nil when the configured managed runtime owns storage policy."
  (and (fboundp 'pilish-runtime-configured-p)
       (pilish-runtime-configured-p)))

(defun pilish-storage-file-digest (file)
  "Return the SHA-256 of FILE's exact bytes, without opening it in Pi.
Call immediately before deriving a rewrite from that same source snapshot.
The helper refuses if those bytes change before its leased commit."
  (when (file-remote-p file)
    (user-error "Managed storage requires a local session pathname"))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun pilish-storage-call (request)
  "Perform narrow stopped-session mutation REQUEST and return its receipt.
REQUEST is a JSON-compatible plist.  Failures never retry or fall back to
raw writes.  The compiled pimux must be explicitly configured; neither
personal caches nor source-checkout relative package imports are consulted."
  (unless (and (pilish-storage-managed-p)
               (boundp 'pilish-runtime-pimux-executable)
               (stringp pilish-runtime-pimux-executable)
               (file-name-absolute-p pilish-runtime-pimux-executable)
               (not (file-remote-p pilish-runtime-pimux-executable)))
    (user-error "Configure an absolute release pimux before managed storage operations"))
  (dolist (key '(:file :output :piExecutable))
    (when-let* ((file (plist-get request key)))
      (unless (and (stringp file) (file-name-absolute-p file)
                   (not (file-remote-p file)))
        (user-error "Managed storage requires local absolute %s" key))))
  (unless (file-readable-p pilish--storage-helper)
    (user-error "Missing pinned Pilish storage helper; reinstall its complete source"))
  (let ((node (executable-find "node"))
        (stderr (make-temp-file "pilish-storage-error-")))
    (unless node
      (delete-file stderr)
      (user-error "Managed storage requires Node 24 in Emacs's executable path"))
    (unwind-protect
        (with-temp-buffer
          (let ((coding-system-for-write 'utf-8-unix)
                (coding-system-for-read 'utf-8-unix)
                (request-text (json-encode request)))
            (insert request-text)
            (let* ((exit (call-process-region
                          (point-min) (point-max) node t (list t stderr) nil
                          pilish--storage-helper pilish-runtime-pimux-executable))
                   (response
                    (condition-case nil
                        (json-parse-string (buffer-string)
                                           :object-type 'plist
                                           :null-object nil :false-object nil)
                      (error nil))))
              (unless (and (integerp exit) (= exit 0)
                           (eq (plist-get response :ok) t)
                           (eq (plist-get response :committed) t)
                           (stringp (plist-get response :operationId))
                           (not (string-empty-p (plist-get response :operationId))))
                (user-error
                 "Managed storage refused: %s"
                 (or (plist-get response :error)
                     "helper failed without a valid receipt; inspect ownership before repeating")))
              response)))
      (delete-file stderr))))

(defun pilish-storage-append-entry (file type payload &optional expected-canonical)
  "Append a stopped FILE entry of TYPE and PAYLOAD under a common lease.
EXPECTED-CANONICAL binds a prompted action to its selected identity.
Only session_info/name and label/targetId/optional-label are supported.
An absent label clears it.  Existing files are required and never created."
  (pilish-storage-call
   (append (list :action "append" :file (expand-file-name file)
                 :type type :payload payload)
           (when expected-canonical
             (list :expectedCanonical expected-canonical)))))

(defun pilish-storage-delete-session (file trash expected-canonical)
  "Delete stopped FILE under a lease, honoring explicit TRASH policy.
EXPECTED-CANONICAL binds the action to the identity confirmed by the user.
Managed trash uses gio's local filesystem backend; unavailable trash support
refuses without a permanent-delete fallback.  A selected symlink is removed,
not its target."
  (pilish-storage-call
   (list :action "delete" :file (expand-file-name file)
         :trash (if trash t :json-false)
         :expectedCanonical expected-canonical)))

(defun pilish-storage-rewrite-session (file lines expected-digest)
  "Replace stopped FILE with raw LINES under a common lease.
EXPECTED-DIGEST is the source SHA-256 taken before deriving LINES.  Missing
or changed source evidence refuses rather than overwriting a newer writer.
Only this stopped-file API rewrites; a live managed file is always refused."
  (unless (and (stringp expected-digest)
               (string-match-p "\\`[a-f0-9]\\{64\\}\\'" expected-digest))
    (user-error "Managed rewrite needs its original source digest"))
  (let ((contents (concat (mapconcat #'identity (append lines nil) "\n") "\n")))
    (pilish-storage-call
     (list :action "rewrite" :file (expand-file-name file)
           :expectedSha256 expected-digest
           :contents (base64-encode-string contents t)))))

(defun pilish-storage-export-session (file output pi-executable)
  "Export stopped FILE to new OUTPUT using the exact PI-EXECUTABLE.
The configured pimux managed launcher claims before Pi's repair-capable
open.  No raw helper Pi is started.  Live sessions use their owning
export_html RPC instead.  OUTPUT must be a new .html file."
  (pilish-storage-call
   (list :action "export" :file (expand-file-name file)
         :output (expand-file-name output) :piExecutable pi-executable)))

(provide 'pilish-storage)
;;; pilish-storage.el ends here
