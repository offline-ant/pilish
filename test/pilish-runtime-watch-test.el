;;; pilish-runtime-watch-test.el --- Live discovery subscription -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A private fake `pimux watch --json' script; no production discovery.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'pilish)

(defun pilish-runtime-watch-test--wait (predicate)
  "Wait up to five seconds for PREDICATE without arbitrary sleeps."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun pilish-runtime-watch-test--snapshot (&rest records)
  "Return one snapshot line of discovery RECORDS."
  (concat (json-serialize (list :type "agents" :agents (vconcat records))) "\n"))

(defun pilish-runtime-watch-test--record (id &rest overrides)
  "Return a raw discovery record for mux ID with OVERRIDES."
  (let ((record (list :protocol 2 :muxId id :socket (format "/tmp/%s.sock" id)
                      :pid (emacs-pid) :piPid (emacs-pid) :cwd "/tmp/project"
                      :placement "root" :parent :null :status "idle" :blocked :null
                      :startedAt "2026-11-12T20:00:00.000Z"
                      :session (list :file (format "/tmp/%s.jsonl" id) :name :null))))
    (while overrides
      (setq record (plist-put record (pop overrides) (pop overrides))))
    record))

(defmacro pilish-runtime-watch-test--with-fake (outputs &rest body)
  "Run BODY with a fake pimux printing OUTPUTS, one per invocation.
Each output is (TEXT . EXIT): EXIT nil keeps the watch running until it is
killed; a number exits with it after writing a stderr diagnostic.  The last
output repeats.  BODY sees the private directory as `directory'."
  (declare (indent 1))
  `(let* ((directory (make-temp-file "pilish-watch-" t))
          (program (expand-file-name "pimux" directory))
          (pilish-runtime-mode 'detached)
          (pilish-runtime-pimux-executable program)
          (pilish-runtime-watch-initial-delay 0.02)
          (pilish-runtime-watch-max-delay 0.08)
          (pilish-runtime-discovery-functions nil)
          (pilish-runtime-live nil))
     (unwind-protect
         (progn
           (cl-loop for (text . exit) in ,outputs for index from 1
                    do (with-temp-file (expand-file-name (format "out.%d" index) directory)
                         (insert text))
                    when exit
                    do (with-temp-file (expand-file-name (format "exit.%d" index) directory)
                         (insert (number-to-string exit))))
           (with-temp-file program
             (insert "#!/bin/sh\n"
                     "[ \"$*\" = \"watch --json\" ] || { echo \"bad arguments: $*\" >&2; exit 2; }\n"
                     (format "d=%s\n" (shell-quote-argument directory))
                     "n=$(cat \"$d/count\" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > \"$d/count\"\n"
                     (format "[ -e \"$d/out.$n\" ] || n=%d\n" (length ,outputs))
                     "cat \"$d/out.$n\"\n"
                     "if [ -e \"$d/exit.$n\" ]; then echo \"failure $n\" >&2; exit $(cat \"$d/exit.$n\"); fi\n"
                     "exec cat\n"))
           (set-file-modes program #o700)
           ,@body)
       (pilish-runtime-watch-stop)
       (delete-directory directory t))))

(defun pilish-runtime-watch-test--count (directory)
  "Return how often the fake pimux in DIRECTORY started."
  (let ((file (expand-file-name "count" directory)))
    (if (file-exists-p file)
        (string-to-number (with-temp-buffer (insert-file-contents file) (buffer-string)))
      0)))

(ert-deftest pilish-runtime-watch-test-notifies-normalized-snapshots ()
  (let ((first (pilish-runtime-watch-test--snapshot
                (pilish-runtime-watch-test--record
                 "one" :session (list :file "/tmp/one.jsonl" :name "thread")
                 :blocked (list :kind "select"))))
        (second (pilish-runtime-watch-test--snapshot
                 (pilish-runtime-watch-test--record "one")
                 (pilish-runtime-watch-test--record "two" :placement "worker"))))
    (pilish-runtime-watch-test--with-fake (list (cons (concat first second) nil))
      (let (seen)
        (add-hook 'pilish-runtime-discovery-functions
                  (lambda (runtimes failure) (should-not failure) (push runtimes seen)))
        (add-hook 'pilish-runtime-discovery-functions (lambda (_ _) (error "Observer bug")))
        (cl-letf (((symbol-function 'display-warning) #'ignore))
          (should (pilish-runtime-watch-start))
          ;; Idempotent: a second start keeps the one process.
          (should (pilish-runtime-watch-start))
          (pilish-runtime-watch-test--wait (lambda () (= (length seen) 2))))
        (let ((one (car (nth 1 seen))))
          (should (equal (plist-get one :mux-id) "one"))
          (should (equal (plist-get one :session-file) "/tmp/one.jsonl"))
          (should (equal (plist-get one :session-name) "thread"))
          (should (equal (plist-get one :started-at) "2026-11-12T20:00:00.000Z"))
          (should (equal (plist-get one :directory) "/tmp/project"))
          (should (equal (plist-get one :placement) "root"))
          (should (plist-get one :blocked)))
        (should (equal (mapcar (lambda (runtime) (plist-get runtime :placement)) (car seen))
                       '("root" "worker")))
        (should (null (plist-get (caar seen) :session-name)))
        (should (null (plist-get (caar seen) :blocked)))
        (should (eq pilish-runtime-live (car seen)))
        (should (= (pilish-runtime-watch-test--count directory) 1))))))

(ert-deftest pilish-runtime-watch-test-restarts-after-failure-and-reports-once ()
  (let ((first (pilish-runtime-watch-test--snapshot (pilish-runtime-watch-test--record "one")))
        (second (pilish-runtime-watch-test--snapshot (pilish-runtime-watch-test--record "two"))))
    (pilish-runtime-watch-test--with-fake
        (list (cons first 3) (cons "" 3) (cons "not json\n" nil) (cons second nil))
      (let (seen failures warnings)
        (add-hook 'pilish-runtime-discovery-functions
                  (lambda (runtimes failure)
                    (push runtimes seen)
                    (when failure (push failure failures))))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (pilish-runtime-watch-start)
          (pilish-runtime-watch-test--wait
           (lambda () (equal (plist-get (caar seen) :mux-id) "two"))))
        ;; One snapshot, three failed runs (the malformed line included), one snapshot.
        (should (= (pilish-runtime-watch-test--count directory) 4))
        (should (equal (mapcar (lambda (runtimes) (plist-get (car runtimes) :mux-id))
                               (reverse seen))
                       '("one" nil nil nil "two")))
        (should (= (length failures) 3))
        (should (cl-every #'stringp failures))
        (should (string-match-p "failure 2" (cadr failures)))
        ;; The first failure followed a snapshot; the next two continue its streak.
        (should (= (length warnings) 1))
        (should (string-match-p "failure 1" (car warnings)))
        (should (null pilish--runtime-watch-delay))
        (should (process-live-p pilish--runtime-watch-process))))))

(ert-deftest pilish-runtime-watch-test-backoff-doubles-to-its-bound ()
  (pilish-runtime-watch-test--with-fake (list (cons "" 3))
    (let (delays)
      (cl-letf (((symbol-function 'display-warning) #'ignore)
                ((symbol-function 'run-with-timer)
                 (let ((original (symbol-function 'run-with-timer)))
                   (lambda (delay repeat function &rest args)
                     (push delay delays)
                     (apply original 0 repeat function args)))))
        (pilish-runtime-watch-start)
        (pilish-runtime-watch-test--wait (lambda () (>= (length delays) 5))))
      (should (equal (cl-subseq (reverse delays) 0 5) '(0.02 0.04 0.08 0.08 0.08))))))

(ert-deftest pilish-runtime-watch-test-stop-ends-the-watch-without-restart ()
  (pilish-runtime-watch-test--with-fake
      (list (cons (pilish-runtime-watch-test--snapshot (pilish-runtime-watch-test--record "one")) nil))
    (let ((calls 0))
      (add-hook 'pilish-runtime-discovery-functions (lambda (_ _) (cl-incf calls)))
      (pilish-runtime-watch-start)
      (pilish-runtime-watch-test--wait (lambda () pilish-runtime-live))
      (let ((process pilish--runtime-watch-process))
        (pilish-runtime-watch-stop)
        (pilish-runtime-watch-test--wait (lambda () (not (process-live-p process)))))
      (accept-process-output nil 0.1)
      (should (null pilish-runtime-live))
      (should (null pilish--runtime-watch-timer))
      (should (= calls 1))
      (should (= (pilish-runtime-watch-test--count directory) 1)))))

(ert-deftest pilish-runtime-watch-test-requires-detached-configuration ()
  (let ((pilish-runtime-mode 'unshared))
    (should-error (pilish-runtime-watch-start) :type 'user-error)))

(provide 'pilish-runtime-watch-test)
;;; pilish-runtime-watch-test.el ends here
