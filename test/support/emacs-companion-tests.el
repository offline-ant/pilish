;;; emacs-companion-tests.el --- ERT in a disposable native server -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The native runner owns this -Q editor, Xvfb display and endpoint. Do not bind
;; noninteractive: real server filters need initialized Emacs frame operations.
;;; Code:
(require 'ert)
(require 'pilish-runtime-native-test)

(run-at-time
 0 nil
 (lambda ()
   (condition-case failure
       (let ((stats
              (ert-run-tests
               (getenv "PILISH_NATIVE_SELECTOR")
               (lambda (event &rest arguments)
                 (when (eq event 'test-ended)
                   (let ((test (nth 1 arguments)) (result (nth 2 arguments)))
                     (princ (format "%s: %s\n" (ert-test-name test) (type-of result))
                            #'external-debugging-output)
                     (when (ert-test-result-with-condition-p result)
                       (princ (format "%S\n%S\n"
                                      (ert-test-result-with-condition-condition result)
                                      (ert-test-result-with-condition-backtrace result))
                              #'external-debugging-output))))))))
         (princ (format "Native companion: %s expected, %s unexpected\n"
                        (ert-stats-completed-expected stats) (ert-stats-completed-unexpected stats))
                #'external-debugging-output)
         (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))
     (error
      (princ (format "Native companion runner: %S\n" failure) #'external-debugging-output)
      (kill-emacs 2)))))

;;; emacs-companion-tests.el ends here
