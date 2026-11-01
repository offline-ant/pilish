;;; pilish-grammars.el --- Tree-sitter grammar recipes  -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tree-sitter grammar recipes and installation helpers for Emacs 29+.
;;
;; All built-in `-ts-mode's (python-ts-mode, bash-ts-mode, etc.) are
;; available on Emacs 29, 30, and 31.  The modes are there; the
;; *grammars* (compiled .so files) are what users need to install.
;;
;; On Emacs 29/30, `treesit-language-source-alist' starts empty — users
;; have no way to install grammars without knowing Git URLs.  This file
;; registers version-pinned recipes so `treesit-install-language-grammar'
;; works out of the box.
;;
;; On Emacs 31, `treesit-ensure-installed' handles grammars natively for
;; modes that register recipes.  Our entries serve as fallbacks for modes
;; that don't (add-to-list with APPEND preserves user/mode entries).

;;; Code:

(require 'cl-lib)
(require 'treesit)
(require 'seq)

;; These queries exist in Emacs 30 and newer.  Declaring them keeps the
;; byte-compiler quiet on Emacs 29, where the `fboundp' guards make the
;; calls unreachable.
(declare-function treesit-library-abi-version "treesit.c"
                  (&optional min-compatible))
(declare-function treesit-language-abi-version "treesit.c" (language))

(defconst pilish--markdown-upstream-source
  '("https://github.com/tree-sitter-grammars/tree-sitter-markdown" "v0.5.4")
  "Upstream Markdown grammar source for tree-sitter ABI 15 and newer.")

(defconst pilish--markdown-backport-source
  '("https://github.com/dnouri/tree-sitter-markdown" "v0.4.1-pilish.2")
  "Backport of scanner fixes for tree-sitter ABI 14, based on v0.4.1.")

(defconst pilish--essential-grammar-source-commits
  (list (cons pilish--markdown-upstream-source
              "41ff24a6c775492c543b09228aeb98d1cd2b3a0f")
        (cons pilish--markdown-backport-source
              "04f1ba4cf3b0ce714feaa5099c313414d67d7d8d"))
  "Immutable commits for the versioned essential grammar sources.
The explicit essential-only installer uses these in addition to the
owning recipes' tags, so a moved tag cannot select different source.")

(defun pilish--treesit-abi-version ()
  "Return the newest language ABI this Emacs can load, or nil."
  (and (fboundp 'treesit-library-abi-version)
       (treesit-library-abi-version)))

(defun pilish--markdown-grammar-source ()
  "Return the (URL REVISION) pair of Markdown grammars for this Emacs.
Upstream v0.5.4 is used when this Emacs loads ABI 15.  Otherwise the
v0.4.1 backport is used, which carries the same overflow fix at ABI 14
and resets stale block state after the last block closes at end of input.
See `pilish-essential-grammar-recipes' for the failure modes."
  (let ((abi (pilish--treesit-abi-version)))
    (if (and (integerp abi) (>= abi 15))
        pilish--markdown-upstream-source
      pilish--markdown-backport-source)))

(defconst pilish-essential-grammar-recipes
  (let ((source (pilish--markdown-grammar-source)))
    (list (list 'markdown (nth 0 source) (nth 1 source)
                "tree-sitter-markdown/src")
          (list 'markdown-inline (nth 0 source) (nth 1 source)
                "tree-sitter-markdown-inline/src")))
  "Tree-sitter grammar recipes required for chat rendering.
Each entry is (LANG URL REVISION [SOURCE-DIR]).

The Markdown scanner in v0.4.1 wrote 5 + 4 bytes per open block into a
fixed 1024-byte serialization buffer without checking the bound, so
documents with 255 or more nested blocks overflowed the buffer and
corrupted the Emacs process.  Upstream fixed that in 2990e5a, released
in v0.5.4, which requires tree-sitter ABI 15.

Emacs 29 and 30 load at most ABI 14, so they cannot use that release.
They get a v0.4.1 backport instead, tag v0.4.1-pilish.2 on
https://github.com/dnouri/tree-sitter-markdown.  In addition to the
overflow fix, that build resets stale matching and close-block flags
when the last block closes at end of input.  Otherwise a later streamed
edit can restore an empty block stack with those flags set and underflow
it on the next close.  A build with ABI 15 or newer gets upstream v0.5.4
directly.  `treesit-install-language-grammar' clones with `git clone -b',
so the revisions are tags, not commit hashes.")

(defconst pilish-optional-grammar-recipes
  '((python      "https://github.com/tree-sitter/tree-sitter-python"       "v0.23.6")
    (javascript  "https://github.com/tree-sitter/tree-sitter-javascript"   "v0.23.1")
    (typescript  "https://github.com/tree-sitter/tree-sitter-typescript"   "v0.23.2" "typescript/src")
    (tsx         "https://github.com/tree-sitter/tree-sitter-typescript"   "v0.23.2" "tsx/src")
    (bash        "https://github.com/tree-sitter/tree-sitter-bash"         "v0.23.3")
    (json        "https://github.com/tree-sitter/tree-sitter-json"         "v0.24.8")
    (yaml        "https://github.com/tree-sitter-grammars/tree-sitter-yaml" "v0.7.0")
    (c           "https://github.com/tree-sitter/tree-sitter-c"            "v0.23.5")
    (cpp         "https://github.com/tree-sitter/tree-sitter-cpp"          "v0.23.4")
    (rust        "https://github.com/tree-sitter/tree-sitter-rust"         "v0.23.2")
    (go          "https://github.com/tree-sitter/tree-sitter-go"           "v0.23.4")
    (ruby        "https://github.com/tree-sitter/tree-sitter-ruby"         "v0.23.1")
    (css         "https://github.com/tree-sitter/tree-sitter-css"          "v0.23.2")
    (html        "https://github.com/tree-sitter/tree-sitter-html"         "v0.23.2")
    (java        "https://github.com/tree-sitter/tree-sitter-java"         "v0.23.5")
    (lua         "https://github.com/tree-sitter-grammars/tree-sitter-lua" "v0.3.0")
    (toml        "https://github.com/tree-sitter-grammars/tree-sitter-toml" "v0.7.0")
    (cmake       "https://github.com/uyha/tree-sitter-cmake"               "v0.5.0")
    (dockerfile  "https://github.com/camdencheek/tree-sitter-dockerfile"   "v0.2.0")
    (c-sharp     "https://github.com/tree-sitter/tree-sitter-c-sharp"      "v0.23.1")
    (clojure     "https://github.com/sogaiu/tree-sitter-clojure"           "unstable-20250526")
    (elixir      "https://github.com/elixir-lang/tree-sitter-elixir"       "v0.3.4")
    (haskell     "https://github.com/tree-sitter/tree-sitter-haskell"      "v0.23.1")
    (heex        "https://github.com/phoenixframework/tree-sitter-heex"    "v0.8.0")
    (kotlin      "https://github.com/fwcd/tree-sitter-kotlin"              "0.3.8")
    (gomod       "https://github.com/camdencheek/tree-sitter-go-mod"       "v1.1.0")
    (php         "https://github.com/tree-sitter/tree-sitter-php"          "v0.23.11" "php/src")
    (scala       "https://github.com/tree-sitter/tree-sitter-scala"        "v0.23.4"))
  "Tree-sitter grammar recipes used for optional embedded code highlighting.
Each entry is (LANG URL REVISION [SOURCE-DIR]).")

(defconst pilish-grammar-recipes
  (append pilish-essential-grammar-recipes
          pilish-optional-grammar-recipes)
  "All tree-sitter grammar recipes needed by Pilish.")

;; Register recipes so `M-x treesit-install-language-grammar' works
;; on Emacs 29/30 (which ship with zero recipes).  Use APPEND so user
;; entries and Emacs 31 mode-registered entries take precedence.
(dolist (recipe pilish-grammar-recipes)
  (add-to-list 'treesit-language-source-alist recipe t))

;;;; Detection

(defconst pilish--essential-grammars
  (mapcar #'car pilish-essential-grammar-recipes)
  "Grammars required for the chat buffer to render properly.")

(defconst pilish--optional-grammars
  (mapcar #'car pilish-optional-grammar-recipes)
  "Recipe grammars used only for optional embedded code highlighting.")

(defun pilish--missing-essential-grammars ()
  "Return list of essential grammars that are not installed."
  (seq-filter (lambda (lang)
                (not (treesit-language-available-p lang)))
              pilish--essential-grammars))

(defun pilish--missing-optional-grammars ()
  "Return optional recipe grammars that are not installed."
  (seq-filter (lambda (lang)
                (not (treesit-language-available-p lang)))
              pilish--optional-grammars))

(defun pilish--installed-optional-grammars ()
  "Return optional recipe grammars that are installed."
  (seq-filter #'treesit-language-available-p
              pilish--optional-grammars))

(defconst pilish--markdown-table-smoke-text
  "| a | b |\n| - | - |\n| 1 | 2 |\n"
  "Small table used to check Markdown grammar compatibility.")

(defconst pilish--markdown-table-smoke-query
  '((pipe_table) @table
    (pipe_table_cell) @cell
    (pipe_table_row) @row)
  "Markdown grammar query required by chat table rendering.")

(defun pilish--markdown-grammar-compatible-p ()
  "Return non-nil when the loaded Markdown grammar supports chat rendering."
  (condition-case nil
      (with-temp-buffer
        (insert pilish--markdown-table-smoke-text)
        (let* ((parser (treesit-parser-create 'markdown))
               (root (treesit-parser-root-node parser))
               (captures (treesit-query-capture
                          root pilish--markdown-table-smoke-query)))
          (and (assq 'table captures)
               (assq 'cell captures)
               (assq 'row captures)
               t)))
    (error nil)))

(defun pilish--markdown-grammar-incompatible-p ()
  "Return non-nil when an installed Markdown grammar is incompatible."
  (and (treesit-language-available-p 'markdown)
       (not (pilish--markdown-grammar-compatible-p))))

(defun pilish--incompatible-markdown-grammar-message ()
  "Return the user-facing Markdown grammar compatibility warning."
  (format "Incompatible Markdown tree-sitter grammar version loaded.  Remove\
 old/system libtree-sitter-markdown from `treesit-extra-load-path', %s, or\
 system packages, then restart Emacs or run M-x pilish-install-grammars."
          (abbreviate-file-name (locate-user-emacs-file "tree-sitter"))))

(defvar pilish--markdown-grammar-warning-done nil
  "Non-nil once the incompatible Markdown grammar warning was shown.")

(defun pilish--maybe-warn-incompatible-markdown-grammar ()
  "Warn once when the loaded Markdown tree-sitter grammar is incompatible."
  (unless (or noninteractive pilish--markdown-grammar-warning-done)
    (when (pilish--markdown-grammar-incompatible-p)
      (setq pilish--markdown-grammar-warning-done t)
      (display-warning
       'pilish
       (pilish--incompatible-markdown-grammar-message)
       :warning))))

;;;; Installation

(defun pilish--grammar-library-file-name (lang)
  "Return the compiled library file name for LANG."
  (concat "libtree-sitter-" (symbol-name lang)
          (or (car dynamic-library-suffixes) ".so")))

(defun pilish--grammar-library-files (lang)
  "Return installed compiled library files for LANG that Pilish may replace.
Looks in `treesit-extra-load-path' and the default user grammar
directory.  System-wide grammar files are never returned."
  (let ((name (pilish--grammar-library-file-name lang)))
    (delete-dups
     (seq-filter
      #'file-exists-p
      (mapcar (lambda (dir) (expand-file-name name dir))
              (append treesit-extra-load-path
                      (list (locate-user-emacs-file "tree-sitter"))))))))

(defun pilish--delete-grammar-libraries (grammars)
  "Delete compiled GRAMMARS libraries from user-managed directories.
Returns the number of files deleted.  Grammar files outside the user's
grammar directories, such as system packages, are left alone."
  (let ((deleted 0))
    (dolist (lang grammars)
      (dolist (file (pilish--grammar-library-files lang))
        (when (ignore-errors (delete-file file) t)
          (cl-incf deleted))))
    deleted))

(defconst pilish--markdown-grammar-abi-version
  (if (eq (pilish--markdown-grammar-source) pilish--markdown-upstream-source)
      15
    14)
  "Language ABI version of the pinned Markdown grammar build.")

(defun pilish--newer-markdown-grammar-installed-p (lang)
  "Return non-nil when LANG's grammar is newer than the pinned build.
Rebuilding such a grammar from the pinned backport would downgrade it."
  (and (fboundp 'treesit-language-abi-version)
       (let ((version (treesit-language-abi-version lang)))
         (and (integerp version)
              (> version pilish--markdown-grammar-abi-version)))))

(defun pilish--install-language-grammar (lang)
  "Install LANG from Pilish's own recipe.
Another recipe for LANG may come first in
`treesit-language-source-alist', for example the vulnerable v0.4.1 pin
that a newer Emacs ships for its built-in Markdown mode.  Put Pilish's
tested recipe first for this installation so the fixed build is what
gets installed."
  (let ((recipe (assq lang pilish-grammar-recipes)))
    (if recipe
        (let ((treesit-language-source-alist
               (cons recipe treesit-language-source-alist)))
          (treesit-install-language-grammar lang))
      (treesit-install-language-grammar lang))))

;;;###autoload
(defun pilish-install-essential-grammars (directory)
  "Build both essential grammars into an empty local DIRECTORY.
This explicit provisioning API requires Emacs 31.1 with tree-sitter,
Git and a C compiler.  It runs noninteractively, never consults existing
home libraries, installs no optional grammars and changes no settings.
Loading Pilish never calls it.

Use the recipes in `pilish-essential-grammar-recipes' and their audited
immutable commits.  Verify the resulting libraries in a fresh Emacs,
not against possibly cached grammars in this process.  Signal an error
if either build or verification fails; partial output stays in DIRECTORY
for inspection, and is never mistaken for a complete installation.

Return a plist with :api-version (1), :emacs-version, absolute :directory
and a :grammars vector.  Each grammar report gives :language, :url,
:version, :revision, :source-directory, absolute :library, :sha256 and :abi.
The caller owns retention of corresponding source and build evidence."
  (unless (and (not (version< emacs-version "31.1")) (treesit-available-p))
    (error "Essential-only provisioning requires Emacs 31.1 with tree-sitter"))
  (unless (and (stringp directory) (not (string-empty-p directory))
               (not (file-remote-p directory)))
    (error "Essential grammar destination must be a nonempty local directory"))
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (target (directory-file-name directory))
         (noninteractive t)
         reports)
    (when (or (file-symlink-p target)
              (and (file-exists-p target) (not (file-directory-p target))))
      (error "Essential grammar destination is not an ordinary directory: %s" target))
    (make-directory directory t)
    (unless (null (directory-files directory nil directory-files-no-dot-files-regexp))
      (error "Essential grammar destination must be empty: %s" target))
    ;; Built-in installer failures may only warn.  Require new nonempty
    ;; artifacts at this exact destination, never a cached/home grammar.
    (dolist (recipe pilish-essential-grammar-recipes)
      (let* ((language (car recipe))
             (commit (cdr (assoc (list (nth 1 recipe) (nth 2 recipe))
                                 pilish--essential-grammar-source-commits)))
             (library (expand-file-name (pilish--grammar-library-file-name language)
                                        directory))
             (treesit-language-source-alist
              (list (append (cl-subseq recipe 0 4) (list nil nil commit))))
             (treesit-extra-load-path (list directory))
             (treesit-load-name-override-list
              (list (list language (file-name-sans-extension library)
                          (concat "tree_sitter_"
                                  (subst-char-in-string ?- ?_ (symbol-name language)))))))
        (unless (and commit (string-match-p "\\`[a-f0-9]\\{40\\}\\'" commit))
          (error "No immutable source commit for essential recipe %s" language))
        (treesit-install-language-grammar language directory)
        (unless (and (not (file-symlink-p library)) (file-regular-p library)
                     (> (file-attribute-size (file-attributes library)) 0))
          (error "Essential grammar %s was not built in %s" language directory))
        (push (list :language (symbol-name language) :url (nth 1 recipe)
                    :version (nth 2 recipe) :revision commit
                    :source-directory (nth 3 recipe) :library library
                    :sha256 (with-temp-buffer
                              (insert-file-contents-literally library)
                              (secure-hash 'sha256 (current-buffer))))
              reports)))
    (setq reports (nreverse reports))
    ;; Absolute override basenames select these artifacts even if another
    ;; library exists in a system search path.  A subprocess cannot reuse
    ;; a grammar previously loaded by the invoking interactive Emacs.
    (let* ((scratch (make-temp-file "pilish-grammar-check-" t))
           (languages (mapcar #'car pilish-essential-grammar-recipes))
           (overrides (mapcar (lambda (report)
                                (list (intern (plist-get report :language))
                                      (file-name-sans-extension
                                       (plist-get report :library))
                                      (concat "tree_sitter_"
                                              (subst-char-in-string
                                               ?- ?_ (plist-get report :language)))))
                              reports))
           (form `(let ((user-emacs-directory ,(file-name-as-directory scratch))
                        (treesit-extra-load-path nil)
                        (treesit-load-name-override-list ',overrides))
                    (require 'treesit)
                    (prin1
                     (mapcar
                      (lambda (language)
                        (unless (treesit-language-available-p language)
                          (error "Essential grammar failed to load: %s" language))
                        (with-temp-buffer
                          (insert "| a | b |\n| - | - |\n| **one** | two |\n")
                          (let ((parser (treesit-parser-create language)))
                            (treesit-parser-root-node parser)))
                        (treesit-language-abi-version language))
                      ',languages))))
           (default-directory scratch))
      (unwind-protect
          (with-temp-buffer
            (let ((status (call-process (expand-file-name invocation-name
                                                         invocation-directory)
                                        nil t nil "-Q" "--batch" "--eval"
                                        (prin1-to-string form))))
              (unless (eql status 0)
                (error "Essential grammar validation failed: %s" (buffer-string)))
              (goto-char (point-min))
              (let ((abis (read (current-buffer))))
                (unless (and (listp abis) (= (length abis) (length reports))
                             (cl-every (lambda (abi)
                                         (eql abi pilish--markdown-grammar-abi-version))
                                       abis))
                  (error "Essential grammar ABI does not match the owning recipes"))
                (cl-mapc (lambda (report abi) (plist-put report :abi abi))
                         reports abis))))
        (delete-directory scratch t)))
    (list :api-version 1 :emacs-version emacs-version :directory directory
          :grammars (vconcat reports))))

(defun pilish--install-grammars (grammars)
  "Install tree-sitter GRAMMARS, showing progress.
Returns the number of successfully installed grammars."
  (let ((total (length grammars))
        (idx 0))
    (condition-case err
        (dolist (lang grammars)
          (cl-incf idx)
          (message "[pilish] Installing grammar %d/%d: %s..."
                   idx total lang)
          (pilish--install-language-grammar lang)
          ;; The installer only warns on failure, so confirm the library
          ;; exists before reporting the grammar as installed.
          (unless (pilish--grammar-library-files lang)
            (error "No grammar library found after installing `%s'" lang)))
      (error
       (display-warning
        'pilish
        (format "Failed to install grammar `%s': %s\n\
A C compiler (gcc or cc) is required.\n\
%d/%d grammars installed before failure."
                (nth (1- idx) grammars)
                (error-message-string err)
                (1- idx) total)
        :error)
       (setq idx (1- idx))))
    (when (> idx 0)
      (message "[pilish] Installed %d/%d grammars." idx total))
    (setq pilish--markdown-grammar-warning-done nil)
    idx))

(defcustom pilish-essential-grammar-action 'prompt
  "What to do when essential tree-sitter grammars are missing.
Essential grammars (markdown, markdown-inline) are required for the
chat buffer to render properly.

`prompt' — ask the user before installing (default).
`auto'   — install without prompting.
`warn'   — warn only; never install.  For users who manage
           tree-sitter grammars via a system package manager."
  :type '(choice (const :tag "Install automatically" auto)
                 (const :tag "Ask before installing" prompt)
                 (const :tag "Warn only (never install)" warn))
  :group 'pilish)

(defun pilish--maybe-install-essential-grammars ()
  "Handle missing essential grammars.
Behavior comes from `pilish-essential-grammar-action'.
Respects `noninteractive' (batch mode always skips)."
  (unless noninteractive
    (let ((missing (pilish--missing-essential-grammars)))
      (when missing
        (let* ((names (mapconcat #'symbol-name missing ", "))
               (should-install
                (pcase pilish-essential-grammar-action
                  ('auto t)
                  ('prompt
                   (y-or-n-p
                    (format "Essential grammars (%s) missing — install now? "
                            names)))
                  ('warn nil))))
          (if should-install
              (progn
                (message "[pilish] Installing essential grammars: %s"
                         names)
                (let ((installed (pilish--install-grammars missing)))
                  (when (< installed (length missing))
                    (display-warning
                     'pilish
                     "Essential tree-sitter grammars (markdown, markdown-inline) \
could not be installed.\nThe chat buffer will not render properly.\n\
A C compiler is required.  Install gcc and restart Emacs."
                     :error))))
            (display-warning
             'pilish
             (format "Essential tree-sitter grammars (%s) are not installed.\n\
The chat buffer will not render properly.\n\
Install them manually, run M-x `pilish-install-grammars',\n\
or set `pilish-essential-grammar-action' to `auto'."
                     names)
             :warning)))))))

(defcustom pilish-grammar-declined-set nil
  "Grammars that were missing when the user declined installation.
When non-nil, the optional grammar prompt is suppressed unless new
grammars appear that are not in this set.  Managed automatically;
reset by setting to nil."
  :type '(repeat symbol)
  :group 'pilish)

(defvar pilish--grammar-prompt-done nil
  "Non-nil when the optional grammar prompt has been shown this session.")

(defun pilish--new-missing-grammars ()
  "Return missing grammars not covered by a previous decline.
If the user never declined, all missing grammars are \"new\".
If they declined, only grammars not in the declined set are new."
  (let ((missing (pilish--missing-optional-grammars)))
    (if pilish-grammar-declined-set
        (seq-remove (lambda (g) (memq g pilish-grammar-declined-set))
                    missing)
      missing)))

(defun pilish--maybe-install-optional-grammars ()
  "Offer to install optional grammars for code highlighting.
Prompts at most once per Emacs session.  A decline is persisted: the
set of missing grammars is saved so the prompt does not reappear.
The prompt returns when new grammars are added to the recipe list
or the declined set is cleared."
  (unless (or noninteractive
              pilish--grammar-prompt-done)
    (setq pilish--grammar-prompt-done t)
    (let ((missing (pilish--missing-optional-grammars))
          (new (pilish--new-missing-grammars)))
      (when new
        (if (y-or-n-p
             (format "%d tree-sitter grammars missing; install for code\
 highlighting (M-x `pilish-install-grammars' to do later)? "
                     (length missing)))
            (pilish--install-grammars missing)
          (customize-save-variable 'pilish-grammar-declined-set missing)
          (message "[pilish] Skipped.  \
Run M-x pilish-install-grammars anytime."))))))

;;;; Interactive Command

;;;###autoload
(defun pilish-install-grammars (&optional reinstall)
  "Show grammar status and install missing tree-sitter grammars.
Displays which grammars are installed and which are missing,
then offers to install the missing ones.

With prefix argument REINSTALL, delete and rebuild the essential
Markdown grammars.  Installed grammars are not rebuilt otherwise, so
use this after upgrading Pilish to pick up grammar fixes.  Restart
Emacs afterwards so the rebuilt grammar replaces the one already
loaded in this session."
  (interactive "P")
  (if reinstall
      (let ((kept nil)
            (deleted 0)
            (rebuilt 0))
        (dolist (lang pilish--essential-grammars)
          (if (pilish--newer-markdown-grammar-installed-p lang)
              (push lang kept)
            (cl-incf deleted (pilish--delete-grammar-libraries (list lang)))
            (cl-incf rebuilt (pilish--install-grammars (list lang)))))
        (when (> deleted 0)
          (message "[pilish] Removed %d installed Markdown grammar %s."
                   deleted (if (= deleted 1) "library" "libraries")))
        (when kept
          (message "[pilish] Keeping newer %s grammar; the pinned build is ABI %d."
                   (mapconcat #'symbol-name kept ", ")
                   pilish--markdown-grammar-abi-version))
        (when (= rebuilt (- (length pilish--essential-grammars) (length kept)))
          (message "[pilish] Markdown grammars rebuilt.  Restart Emacs to load them."))
        (setq pilish--markdown-grammar-warning-done nil))
    (let ((installed (pilish--installed-optional-grammars))
          (missing (pilish--missing-optional-grammars))
          (essential-missing (pilish--missing-essential-grammars))
          (markdown-incompatible
           (pilish--markdown-grammar-incompatible-p)))
      (cond
     (markdown-incompatible
      (display-warning
       'pilish
       (pilish--incompatible-markdown-grammar-message)
       :warning))
     ((and (null missing) (null essential-missing))
      (message "All %d tree-sitter grammars are installed. ✓"
               (length installed)))
     (t
      (let ((buf (get-buffer-create "*pilish-grammars*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Pilish Tree-sitter Grammars\n\
====================================\n\n"))
            (when essential-missing
              (insert (format "⚠ ESSENTIAL (required for chat rendering):\n"))
              (dolist (g essential-missing)
                (insert (format "  ✗ %s\n" g)))
              (insert "\n"))
            (when missing
              (insert (format "Missing (%d):\n" (length missing)))
              (dolist (g missing)
                (insert (format "  ✗ %s\n" g)))
              (insert "\n"))
            (when installed
              (insert (format "Installed (%d):\n" (length installed)))
              (dolist (g installed)
                (insert (format "  ✓ %s\n" g)))
              (insert "\n"))
            (insert "Press `i' to install missing grammars, `q' to close.\n"))
          (special-mode)
          (local-set-key "i" (lambda ()
                               (interactive)
                               (let ((to-install (append essential-missing missing)))
                                 (when to-install
                                   (pilish--install-grammars to-install)
                                   (pilish-install-grammars)))))
          (local-set-key "q" #'quit-window)
          (goto-char (point-min)))
        (pop-to-buffer buf)))))))

(provide 'pilish-grammars)
;;; pilish-grammars.el ends here
