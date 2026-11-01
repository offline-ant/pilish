;;; pilish-grammars-test.el --- Explicit grammar provisioning tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The essential-only provisioning API is independently loadable with Emacs
;; builtins.  Deterministic tests build synthetic files, never home grammars;
;; real compilation is a separate explicit provisioning check.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pilish-grammars)

(defvar native-comp-enable-subr-trampolines)

(defmacro pilish-grammar-test--with-destination (&rest body)
  "Run BODY with fresh `root' and empty `destination', then remove them."
  (declare (indent 0) (debug t))
  `(let* ((_supported (skip-unless (and (not (version< emacs-version "31.1"))
                                       (treesit-available-p))))
          (root (make-temp-file "pilish-grammar-test-" t))
          (destination (expand-file-name "artifacts" root))
          (user-emacs-directory (expand-file-name "home/" root))
          ;; Subr mocking is a deterministic fixture, not native compilation.
          ;; Do not spawn trampoline compilers through a mocked call-process.
          (native-comp-enable-subr-trampolines nil))
     (unwind-protect
         (progn ,@body)
       (delete-directory root t))))

(defun pilish-grammar-test--build (language directory)
  "Write a synthetic grammar for LANGUAGE to explicit DIRECTORY."
  (should noninteractive)
  (should (equal (mapcar #'car treesit-language-source-alist) (list language)))
  (let ((recipe (assq language treesit-language-source-alist)))
    (should (equal (nth 2 recipe) (nth 2 (assq language pilish-essential-grammar-recipes))))
    (should (string-match-p "\\`[a-f0-9]\\{40\\}\\'" (nth 6 recipe))))
  (with-temp-file (expand-file-name (pilish--grammar-library-file-name language) directory)
    (insert (format "synthetic %s" language))))

(defun pilish-grammar-test--validate (_program _infile destination _display &rest args)
  "Model the fresh verifier, writing its report to DESTINATION with ARGS."
  (should (equal (seq-take args 3) '("-Q" "--batch" "--eval")))
  (should (eq destination t))
  (should (string-match-p "treesit-load-name-override-list" (nth 3 args)))
  (should (string-match-p "libtree-sitter-markdown-inline" (nth 3 args)))
  (let* ((form (car (read-from-string (nth 3 args))))
         (overrides (cadr (cadr (assq 'treesit-load-name-override-list (cadr form))))))
    (should (equal (mapcar #'caddr overrides)
                   '("tree_sitter_markdown" "tree_sitter_markdown_inline")))
    (should (cl-every (lambda (entry) (file-name-absolute-p (cadr entry))) overrides)))
  (insert (prin1-to-string (list pilish--markdown-grammar-abi-version
                                pilish--markdown-grammar-abi-version)))
  0)

(ert-deftest pilish-test-grammar-explicit-installer-uses-only-owned-pins-and-destination ()
  "Build both owned recipes even when home or user recipes claim readiness."
  (pilish-grammar-test--with-destination
    (let* ((user-emacs-directory (expand-file-name "unused-home" root))
           (treesit-extra-load-path (list user-emacs-directory))
           (treesit-language-source-alist '((markdown "https://invalid.example" "wrong")))
           (original-recipes (copy-tree treesit-language-source-alist))
           (noninteractive nil)
           calls)
      (make-directory user-emacs-directory)
      (with-temp-file (expand-file-name "libtree-sitter-markdown.so" user-emacs-directory)
        (insert "cached grammar must not count"))
      (cl-letf (((symbol-function 'treesit-install-language-grammar)
                 (lambda (language directory)
                   (push (list language directory) calls)
                   (pilish-grammar-test--build language directory)))
                ((symbol-function 'treesit-language-available-p)
                 (lambda (&rest _) (error "Must not inspect cached parent libraries")))
                ((symbol-function 'call-process) #'pilish-grammar-test--validate)
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "No prompting"))))
        (let* ((report (pilish-install-essential-grammars destination))
               (grammars (plist-get report :grammars)))
          (should (= 1 (plist-get report :api-version)))
          (should (equal (plist-get report :directory) (file-name-as-directory destination)))
          (should (equal (mapcar #'car (reverse calls)) '(markdown markdown-inline)))
          (should (cl-every (lambda (call) (equal (cadr call) (file-name-as-directory destination))) calls))
          (should (vectorp grammars))
          (should (= 2 (length grammars)))
          (dotimes (index 2)
            (let* ((grammar (aref grammars index))
                   (recipe (nth index pilish-essential-grammar-recipes)))
              (should (equal (plist-get grammar :language) (symbol-name (car recipe))))
              (should (equal (plist-get grammar :url) (nth 1 recipe)))
              (should (equal (plist-get grammar :version) (nth 2 recipe)))
              (should (equal (plist-get grammar :source-directory) (nth 3 recipe)))
              (should (equal (plist-get grammar :revision)
                             (cdr (assoc (list (nth 1 recipe) (nth 2 recipe))
                                         pilish--essential-grammar-source-commits))))
              (should (eql (plist-get grammar :abi) pilish--markdown-grammar-abi-version))
              (should (equal (plist-get grammar :sha256)
                             (with-temp-buffer
                               (insert-file-contents-literally (plist-get grammar :library))
                               (secure-hash 'sha256 (current-buffer)))))))))
      (should (equal treesit-language-source-alist original-recipes))
      (should (equal (directory-files user-emacs-directory nil directory-files-no-dot-files-regexp)
                     '("libtree-sitter-markdown.so"))))))

(ert-deftest pilish-test-grammar-explicit-installer-rejects-existing-output ()
  "Provisioning must never overwrite existing libraries or arbitrary files."
  (pilish-grammar-test--with-destination
    (make-directory destination)
    (with-temp-file (expand-file-name "keep" destination) (insert "keep"))
    (cl-letf (((symbol-function 'treesit-install-language-grammar)
               (lambda (&rest _) (ert-fail "No build before destination validation"))))
      (should-error (pilish-install-essential-grammars destination)))
    (should (equal (directory-files destination nil directory-files-no-dot-files-regexp) '("keep")))))

(ert-deftest pilish-test-grammar-explicit-installer-rejects-symlink-destination ()
  "A destination symlink is not permission to write into another directory."
  (pilish-grammar-test--with-destination
    (let ((other (expand-file-name "other" root)))
      (make-directory other)
      (make-symbolic-link other destination)
      (should-error (pilish-install-essential-grammars destination))
      (should (null (directory-files other nil directory-files-no-dot-files-regexp))))))

(ert-deftest pilish-test-grammar-explicit-installer-detects-warning-only-build-failure ()
  "A successful home lookup must not hide a missing destination artifact."
  (pilish-grammar-test--with-destination
    (cl-letf (((symbol-function 'treesit-install-language-grammar) (lambda (&rest _) nil))
              ((symbol-function 'treesit-language-available-p) (lambda (&rest _) t))
              ((symbol-function 'call-process) (lambda (&rest _) (ert-fail "No verifier without artifacts"))))
      (should-error (pilish-install-essential-grammars destination)))))

(ert-deftest pilish-test-grammar-explicit-installer-requires-both-artifacts ()
  "A second-grammar build failure cannot return a partial success report."
  (pilish-grammar-test--with-destination
    (cl-letf (((symbol-function 'treesit-install-language-grammar)
               (lambda (language directory)
                 (when (eq language 'markdown)
                   (pilish-grammar-test--build language directory)))))
      (should-error (pilish-install-essential-grammars destination)))
    (should (file-exists-p (expand-file-name "libtree-sitter-markdown.so" destination)))
    (should-not (file-exists-p (expand-file-name "libtree-sitter-markdown-inline.so" destination)))))

(ert-deftest pilish-test-grammar-explicit-installer-rejects-unpinned-source ()
  "An unknown or moved source recipe cannot quietly select a registry version."
  (pilish-grammar-test--with-destination
    (let ((pilish--essential-grammar-source-commits nil))
      (cl-letf (((symbol-function 'treesit-install-language-grammar)
                 (lambda (&rest _) (ert-fail "No build without immutable commit"))))
        (should-error (pilish-install-essential-grammars destination))))))

(ert-deftest pilish-test-grammar-explicit-installer-rejects-invalid-built-library ()
  "A new nonempty file is not enough; the isolated loader must succeed."
  (pilish-grammar-test--with-destination
    (cl-letf (((symbol-function 'treesit-install-language-grammar) #'pilish-grammar-test--build)
              ((symbol-function 'call-process)
               (lambda (&rest _) (insert "unloadable artifact") 1)))
      (should-error (pilish-install-essential-grammars destination)))))

(ert-deftest pilish-test-grammar-explicit-installer-rejects-wrong-abi ()
  "Require the ABI promised by the selected owning source recipes."
  (pilish-grammar-test--with-destination
    (cl-letf (((symbol-function 'treesit-install-language-grammar) #'pilish-grammar-test--build)
              ((symbol-function 'call-process) (lambda (&rest _) (insert "(0 0)") 0)))
      (should-error (pilish-install-essential-grammars destination)))))

(ert-deftest pilish-test-grammar-explicit-installer-refuses-unsupported-emacs ()
  "Older Emacs keeps its interactive API without losing immutable pin checks."
  (let* ((root (make-temp-file "pilish-grammar-version-test-" t))
         (destination (expand-file-name "must-not-exist" root))
         (emacs-version "30.2"))
    (unwind-protect
        (progn
          (should-error (pilish-install-essential-grammars destination))
          (should-not (file-exists-p destination)))
      (delete-directory root t))))

(ert-deftest pilish-test-grammar-loading-never-builds ()
  "Requiring the owning recipe file never installs grammars implicitly."
  (cl-letf (((symbol-function 'treesit-install-language-grammar)
             (lambda (&rest _) (ert-fail "No downloads while loading"))))
    (load (locate-library "pilish-grammars.el") nil t t)))

(provide 'pilish-grammars-test)
;;; pilish-grammars-test.el ends here
