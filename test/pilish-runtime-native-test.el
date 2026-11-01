;;; pilish-runtime-native-test.el --- Real Pi faux socket integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Explicit opt-in with a marked synthetic ownership root and exact candidate
;; executables.  No production discovery, personal caches or paid inference.

;;; Code:
(require 'ert)
(require 'pilish)
(require 'pilish-runtime-test)

(defconst pilish-runtime-native-test--source
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defun pilish-runtime-native-test--wait (predicate)
  "Wait up to forty seconds for PREDICATE using process events."
  (let ((deadline (+ (float-time) 40)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defun pilish-runtime-native-test--peer (runtime command &optional run)
  "Ask an independent Node frontend to send COMMAND to RUNTIME, optionally RUN."
  (with-temp-buffer
    (let ((status (process-file
                   "node" nil t nil
                   (expand-file-name "test/support/pimux-peer.mjs" pilish-runtime-native-test--source)
                   (plist-get runtime :socket) (json-encode command) (if run "run" ""))))
      (unless (and (integerp status) (zerop status))
        (error "Independent peer failed: %s" (buffer-string)))
      (json-parse-string (buffer-string) :object-type 'plist))))

(defmacro pilish-runtime-native-test--with-host (&rest body)
  "Run BODY with explicitly selected candidate/faux host and synthetic namespace."
  (declare (indent 0))
  `(progn
     (skip-unless (getenv "PHIMACS_NATIVE_PILISH"))
     (should (string-prefix-p "/tmp/phimacs-test-" (or (getenv "PHIMACS_TEST_ROOT") "")))
     (let* ((root (getenv "PHIMACS_TEST_ROOT"))
            (default-directory (file-name-as-directory (expand-file-name "sessions" root)))
            (process-environment (copy-sequence process-environment))
            (pilish-runtime-mode 'detached)
            (pilish-runtime-pi-executable (getenv "PHIMACS_PI_EXECUTABLE"))
            (pilish-runtime-pimux-executable (getenv "PHIMACS_PIMUX_EXECUTABLE"))
            (pilish-extra-args
             (list "--no-extensions" "--no-skills" "--no-prompt-templates"
                   "--no-context-files" "--extension" (getenv "PHIMACS_FAUX_EXTENSION")
                   "--provider" "pimux-fx" "--model" "one" "--thinking" "off"))
            chat runtime)
       (setq process-environment
             (seq-remove (lambda (entry)
                           (string-match-p "\\`\\(?:PI_ORCHESTRATION_\\|PI_WORKER_\\|PHIMACS_PARENT_TASK=\\)" entry))
                         process-environment))
       (setenv "PI_CODING_AGENT_DIR" (expand-file-name "agent" root))
       (setenv "PI_CODING_AGENT_SESSION_DIR" default-directory)
       (setenv "PIMUX_DIR" (expand-file-name "mux" root))
       (pilish-configure-runtime :pi-executable pilish-runtime-pi-executable
                                 :pimux-executable pilish-runtime-pimux-executable)
       (unwind-protect (progn ,@body)
         (setq runtime (or runtime (and (buffer-live-p chat) (pilish-session-runtime chat))))
         (when (and (plist-get runtime :mux-id)
                    (not (equal (plist-get runtime :state) "stopped")))
           (ignore-errors
             (process-file pilish-runtime-pimux-executable nil nil nil
                           "stop" "--json" "--id" (plist-get runtime :mux-id))))
         (when (buffer-live-p chat)
           (let ((input (pilish-session-input-buffer chat))
                 (pilish-quit-without-confirmation t))
             (kill-buffer chat)
             (when (buffer-live-p input) (kill-buffer input))))))))

(ert-deftest pilish-runtime-native-test-creates-detaches-restores-and-stops ()
  (pilish-runtime-native-test--with-host
    (let (ready response)
      (setq chat (pilish-start-session default-directory "native-owner"
                                       :on-ready (lambda (result) (setq ready result))))
      (pilish-runtime-native-test--wait (lambda () ready))
      (unless (eq (plist-get ready :success) t)
        (ert-fail (format "Managed view did not start: %S" ready)))
      (setq runtime (pilish-session-runtime chat))
      (should (equal (plist-get runtime :state) "live"))
      (should (eq (process-type (pilish-session-process chat)) 'network))
      (should-not (integerp (process-id (pilish-session-process chat))))
      (should (pilish--runtime-process-identity (plist-get runtime :pi-pid)))
      (pilish-submit-prompt chat "native once" (lambda (result) (setq response result)))
      (pilish-runtime-native-test--wait
       (lambda () (and response (not (pilish-session-busy-p chat)))))
      (should (eq (plist-get response :success) t))
      (with-current-buffer (pilish-session-input-buffer chat) (insert "context-specific draft"))
      (let* ((state (pilish-session-desktop-state chat))
             (identity (pilish-session-process-identity chat)))
        (pilish-close-session chat)
        (should (equal identity (pilish--runtime-process-identity (plist-get runtime :pi-pid))))
        (setq chat (pilish-restore-session-state state))
        (pilish-runtime-native-test--wait
         (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
        (should (equal identity (pilish-session-process-identity chat)))
        (should (equal (plist-get (pilish-session-desktop-state chat) :draft) "context-specific draft")))
      ;; A different frontend changes session and prompts, while this view adopts
      ;; the authoritative boundary and quarantines old-context input.
      (let ((old-file (pilish-session-file chat)))
        (should (eq (plist-get (plist-get
                               (pilish-runtime-native-test--peer runtime '(:type "new_session"))
                               :response) :success) t))
        (pilish-runtime-native-test--wait (lambda () (not (equal old-file (pilish-session-file chat)))))
        (should (pilish-session-quarantine chat)))
      (should (eq (plist-get (plist-get
                             (pilish-runtime-native-test--peer
                              runtime '(:type "prompt" :message "other frontend once") t)
                             :response) :success) t))
      (pilish-runtime-native-test--wait (lambda () (not (pilish-session-busy-p chat))))
      (let ((messages (plist-get (plist-get
                                 (pilish-runtime-native-test--peer runtime '(:type "get_messages"))
                                 :response) :data)))
        (should (= (length (seq-filter (lambda (message) (equal (plist-get message :role) "user"))
                                       (append (plist-get messages :messages) nil))) 1)))
      (let (stopped)
        (pilish-stop-runtime chat (lambda (error) (setq stopped (or error 'success))))
        (pilish-runtime-native-test--wait (lambda () stopped))
        (should (eq stopped 'success))
        (should (equal (plist-get (pilish-session-runtime chat) :state) "stopped"))
        (should-not (pilish--runtime-process-identity (plist-get runtime :pi-pid)))
        (setq runtime (pilish-session-runtime chat))))))

(ert-deftest pilish-runtime-native-test-independent-creator-and-zero-clients ()
  (pilish-runtime-native-test--with-host
    (with-temp-buffer
      (let ((status (apply #'process-file pilish-runtime-pimux-executable nil t nil
                           (append (list "start" "--json" "--" pilish-runtime-pi-executable
                                         "--mode" "rpc") pilish-extra-args))))
        (unless (and (integerp status) (zerop status))
          (error "Independent launch failed: %s" (buffer-string)))
        (setq runtime (pilish--runtime-normalize
                       (json-parse-string (buffer-string) :object-type 'plist)))))
    ;; The creating frontend has already exited.  Attachment makes no new Pi.
    (should (pilish--runtime-process-identity (plist-get runtime :pi-pid)))
    (setq chat (pilish-attach-runtime runtime "external-created"))
    (pilish-runtime-native-test--wait
     (lambda () (equal (plist-get (pilish-session-runtime chat) :state) "live")))
    (let ((identity (pilish-session-process-identity chat)))
      (pilish--terminate-process (pilish-session-process chat))
      (should (equal identity (pilish--runtime-process-identity (plist-get runtime :pi-pid))))
      (let (ready)
        (pilish-reconnect-runtime chat (lambda (error) (setq ready (or error 'success))))
        (pilish-runtime-native-test--wait (lambda () ready))
        (should (eq ready 'success)))
      (should (equal identity (pilish-session-process-identity chat))))))

(provide 'pilish-runtime-native-test)
;;; pilish-runtime-native-test.el ends here
