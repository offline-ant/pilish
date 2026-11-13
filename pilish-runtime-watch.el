;;; pilish-runtime-watch.el --- Live runtime discovery subscription -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One long-lived `pimux watch --json' process streams discovery snapshots:
;; each line is the complete set of live runtimes, so the latest line wins and
;; a restarted watch resynchronizes from its first line.  Pilish normalizes
;; each record as `pilish-list-runtimes' does and notifies
;; `pilish-runtime-discovery-functions'.  The watch only observes: it never
;; starts, attaches or stops a runtime.  A failed watch restarts with bounded
;; backoff and reports its failure once until a snapshot arrives again.

;;; Code:

(require 'pilish-runtime-process)

(defvar pilish-runtime-live nil
  "Latest live runtime snapshot as normalized plists.
Nil before the first snapshot and while the watch is stopped or failing.")

(defvar pilish-runtime-discovery-functions nil
  "Functions called with RUNTIMES and FAILURE after each discovery change.
After a snapshot RUNTIMES lists `pilish-list-runtimes' plists plus
`:started-at', `:session-name' and `:blocked', and FAILURE is nil.  When
the watch fails RUNTIMES is nil and FAILURE its diagnostic string.
A failing function is reported as a warning; the others still run.")

(defvar pilish-runtime-watch-initial-delay 1
  "Seconds before the first restart of a failed watch.")

(defvar pilish-runtime-watch-max-delay 30
  "Upper bound in seconds of the doubling restart delay.")

(defconst pilish--runtime-watch-line-limit (* 4 1024 1024)
  "Largest accepted snapshot line in bytes.")

(defvar pilish--runtime-watch-process nil "The running watch process, if any.")
(defvar pilish--runtime-watch-timer nil "Pending restart of a failed watch.")
(defvar pilish--runtime-watch-delay nil "Delay before the next restart.")
(defvar pilish--runtime-watch-reported nil
  "Non-nil once the current failure streak was reported.")
(defvar pilish--runtime-watch-pending ""
  "Output after the last complete snapshot line.")

(defun pilish--runtime-watch-normalize (record)
  "Return discovery RECORD as a runtime plist with its watch metadata."
  (let ((session (plist-get record :session))
        (blocked (plist-get record :blocked)))
    (append (pilish--runtime-normalize record)
            (list :started-at (plist-get record :startedAt)
                  :session-name (let ((name (and (listp session) (plist-get session :name))))
                                  (and (stringp name) (not (string-empty-p name)) name))
                  :blocked (and blocked (not (eq blocked :null)) t)))))

(defun pilish--runtime-watch-notify (runtimes &optional failure)
  "Set `pilish-runtime-live' to RUNTIMES and notify observers of it or FAILURE."
  (setq pilish-runtime-live runtimes)
  (dolist (function pilish-runtime-discovery-functions)
    (condition-case err
        (funcall function runtimes failure)
      (error (display-warning 'pilish (format "Runtime discovery observer %S failed: %s"
                                              function (error-message-string err)))))))

(defun pilish--runtime-watch-line (line)
  "Apply snapshot LINE, or signal an error for a malformed one."
  (let ((snapshot (json-parse-string line :object-type 'plist :null-object :null)))
    (unless (and (listp snapshot) (equal (plist-get snapshot :type) "agents")
                 (vectorp (plist-get snapshot :agents)))
      (error "Invalid runtime watch snapshot"))
    (setq pilish--runtime-watch-delay nil
          pilish--runtime-watch-reported nil)
    (pilish--runtime-watch-notify
     (mapcar #'pilish--runtime-watch-normalize (append (plist-get snapshot :agents) nil)))))

(defun pilish--runtime-watch-filter (process chunk)
  "Apply each complete snapshot line of PROCESS's output CHUNK."
  (when (eq process pilish--runtime-watch-process)
    (setq pilish--runtime-watch-pending (concat pilish--runtime-watch-pending chunk))
    (condition-case err
        (let (newline)
          (while (and (eq process pilish--runtime-watch-process)
                      (setq newline (string-search "\n" pilish--runtime-watch-pending)))
            (let ((line (substring pilish--runtime-watch-pending 0 newline)))
              (setq pilish--runtime-watch-pending
                    (substring pilish--runtime-watch-pending (1+ newline)))
              (unless (string-blank-p line) (pilish--runtime-watch-line line))))
          (when (> (string-bytes pilish--runtime-watch-pending) pilish--runtime-watch-line-limit)
            (error "Runtime watch snapshot exceeds its bound")))
      (error
       (process-put process 'pilish-watch-error (error-message-string err))
       (delete-process process)))))

(defun pilish--runtime-watch-diagnostic (process)
  "Return PROCESS's failure description, with the tail of its stderr."
  (let* ((stderr (process-get process 'pilish-watch-stderr))
         (tail (when (buffer-live-p stderr)
                 (with-current-buffer stderr
                   (string-trim (buffer-substring-no-properties
                                 (max (point-min) (- (point-max) 4096)) (point-max)))))))
    (concat (or (process-get process 'pilish-watch-error)
                (format "pimux watch exited with status %d" (process-exit-status process)))
            (if (and tail (not (string-empty-p tail))) (concat ": " tail) ""))))

(defun pilish--runtime-watch-sentinel (process _event)
  "Restart the watch after PROCESS ended without being stopped."
  (unless (process-live-p process)
    (when-let* ((stderr (process-get process 'pilish-watch-stderr)))
      (unwind-protect
          (when (eq process pilish--runtime-watch-process)
            (pilish--runtime-watch-failed (pilish--runtime-watch-diagnostic process)))
        (when (buffer-live-p stderr) (kill-buffer stderr))))))

(defun pilish--runtime-watch-failed (diagnostic)
  "Report DIAGNOSTIC once per failure streak and schedule a bounded restart."
  (setq pilish--runtime-watch-process nil
        pilish--runtime-watch-pending "")
  (unless pilish--runtime-watch-reported
    (setq pilish--runtime-watch-reported t)
    (display-warning 'pilish (format "Runtime discovery watch failed; retrying: %s" diagnostic)))
  (pilish--runtime-watch-notify nil diagnostic)
  (let ((delay (or pilish--runtime-watch-delay pilish-runtime-watch-initial-delay)))
    (setq pilish--runtime-watch-delay (min pilish-runtime-watch-max-delay (* 2 delay))
          pilish--runtime-watch-timer
          (run-with-timer delay nil #'pilish--runtime-watch-restart))))

(defun pilish--runtime-watch-restart ()
  "Start the watch again after a failure."
  (setq pilish--runtime-watch-timer nil)
  (condition-case err
      (pilish--runtime-watch-spawn)
    (error (pilish--runtime-watch-failed (error-message-string err)))))

(defun pilish--runtime-watch-spawn ()
  "Start the `pimux watch --json' process."
  (unless (and (stringp pilish-runtime-pimux-executable)
               (file-name-absolute-p pilish-runtime-pimux-executable)
               (file-executable-p pilish-runtime-pimux-executable))
    (error "Configure an absolute compiled pimux executable first"))
  (let ((default-directory temporary-file-directory)
        (process-environment (pilish--runtime-environment nil))
        (stderr (generate-new-buffer " *pilish-runtime-watch-stderr*")))
    (condition-case err
        (let ((process (make-process
                        :name "pilish-runtime-watch" :noquery t :connection-type 'pipe
                        :coding 'utf-8 :stderr stderr
                        :command (list pilish-runtime-pimux-executable "watch" "--json")
                        :filter #'pilish--runtime-watch-filter
                        :sentinel #'pilish--runtime-watch-sentinel)))
          (process-put process 'pilish-watch-stderr stderr)
          (setq pilish--runtime-watch-pending ""
                pilish--runtime-watch-process process))
      (error (kill-buffer stderr) (signal (car err) (cdr err))))))

(defun pilish-runtime-watch-start ()
  "Start following live runtime discovery; return non-nil when it runs.
Idempotent.  Requires the detached runtime configuration."
  (unless (pilish-runtime-configured-p) (user-error "Configure detached runtime support first"))
  (unless (or (process-live-p pilish--runtime-watch-process) pilish--runtime-watch-timer)
    (setq pilish--runtime-watch-delay nil
          pilish--runtime-watch-reported nil)
    (pilish--runtime-watch-spawn))
  t)

(defun pilish-runtime-watch-stop ()
  "Stop following runtime discovery and forget the latest snapshot.
Observers are not called; their owner stops listening itself."
  (when (timerp pilish--runtime-watch-timer) (cancel-timer pilish--runtime-watch-timer))
  (let ((process pilish--runtime-watch-process))
    (setq pilish--runtime-watch-timer nil
          pilish--runtime-watch-process nil
          pilish--runtime-watch-delay nil
          pilish--runtime-watch-reported nil
          pilish--runtime-watch-pending ""
          pilish-runtime-live nil)
    (when (process-live-p process) (delete-process process))))

(provide 'pilish-runtime-watch)
;;; pilish-runtime-watch.el ends here
