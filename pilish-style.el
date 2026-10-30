;;; pilish-style.el --- Chat styles for Pilish transcripts -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `pilish-chat-style' selects how chat and transcript buffers look.  The
;; `pi' style imitates Pi's terminal interface on top of the unchanged
;; buffer text: turn headings are hidden by overlays, user messages,
;; custom messages and summaries become background blocks, thinking is
;; muted, and tool block faces are remapped to Pi's state colours.  Input
;; buffers get the user message background, so a draft reads as one block
;; that ends where the next window starts.
;;
;; Decoration runs as a `jit-lock' function, so it follows every way text
;; reaches the buffer (streaming, history loads, rewrites) without hooks in
;; the renderer.  The only renderer contract is the buffer text itself: the
;; setext turn headings, the `pilish-thinking-block' and
;; `pilish-custom-message' text properties, and the tool block faces.
;;
;; Face defaults are the background and foreground colours of Pi's
;; built-in dark and light themes (packages/coding-agent/src/modes/
;; interactive/theme/{dark,light}.json), converted from okhsl to hex.

;;; Code:

(require 'jit-lock)
(require 'face-remap)
(require 'pilish-ui)

;;;; Options

(defcustom pilish-chat-style 'classic
  "Visual style of chat and transcript buffers.
`classic' shows `You' and `Assistant' headings with theme-derived tool
backgrounds.  `pi' follows Pi's terminal interface: turn headings are
hidden, assistant text is plain Markdown, user messages are padded
blocks with Pi's user message background, tool blocks are coloured by
their state (pending, success, error), thinking is muted italic, and
custom messages get Pi's custom message background.  The input buffer
has the user message background too.  The buffer text is the same in
both styles, so navigation is unchanged; copying omits the hidden
headings.  Setting this through Customize restyles open buffers."
  :type '(choice (const :tag "Classic Pilish headings" classic)
                 (const :tag "Pi's terminal interface" pi))
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (dolist (buffer (buffer-list))
           (with-current-buffer buffer
             (cond ((derived-mode-p 'pilish-transcript-mode)
                    (pilish--apply-chat-style))
                   ((derived-mode-p 'pilish-input-mode)
                    (pilish--apply-input-style))))))
  :group 'pilish)

;;;; Faces

(defgroup pilish-style nil
  "Chat styles for Pilish transcripts."
  :group 'pilish
  :prefix "pilish-pi-")

(defface pilish-pi-user-message
  '((((class color) (min-colors 256) (background light))
     :background "#dfe7ec" :extend t)
    (((class color) (min-colors 256))
     :background "#213b49" :extend t)
    (t :inherit highlight :extend t))
  "Face for user message blocks in the `pi' chat style (Pi's userMessageBg)."
  :group 'pilish-style)

(defface pilish-pi-custom-message
  '((((class color) (min-colors 256) (background light))
     :background "#e6e4ee" :extend t)
    (((class color) (min-colors 256))
     :background "#3a3055" :extend t)
    (t :inherit secondary-selection :extend t))
  "Face for custom messages and summaries in the `pi' style (customMessageBg)."
  :group 'pilish-style)

(defface pilish-pi-custom-message-label
  '((((class color) (min-colors 256) (background light))
     :foreground "#7459b4" :weight bold)
    (((class color) (min-colors 256))
     :foreground "#a798d7" :weight bold)
    (t :weight bold))
  "Face for summary labels in the `pi' style (Pi's customMessageLabel)."
  :group 'pilish-style)

(defface pilish-pi-tool-pending
  '((((class color) (min-colors 256) (background light))
     :background "#e4e5e6" :extend t)
    (((class color) (min-colors 256))
     :background "#34383a" :extend t)
    (t :extend t))
  "Face for running tool blocks in the `pi' style (Pi's toolPendingBg)."
  :group 'pilish-style)

(defface pilish-pi-tool-success
  '((((class color) (min-colors 256) (background light))
     :background "#dee9e1" :extend t)
    (((class color) (min-colors 256))
     :background "#254131" :extend t)
    (t :extend t))
  "Face for successful tool blocks in the `pi' style (Pi's toolSuccessBg)."
  :group 'pilish-style)

(defface pilish-pi-tool-error
  '((((class color) (min-colors 256) (background light))
     :background "#eee2e1" :extend t)
    (((class color) (min-colors 256))
     :background "#5b282a" :extend t)
    (t :inherit error :extend t))
  "Face for failed tool blocks in the `pi' style (Pi's toolErrorBg)."
  :group 'pilish-style)

(defface pilish-pi-tool-title
  '((t :weight bold))
  "Face for tool names and arguments in the `pi' style (Pi's toolTitle)."
  :group 'pilish-style)

(defface pilish-pi-tool-output
  '((((class color) (min-colors 256) (background light))
     :foreground "#677176")
    (((class color) (min-colors 256))
     :foreground "#9da5a9")
    (t :inherit shadow))
  "Face for tool output in the `pi' style (Pi's toolOutput)."
  :group 'pilish-style)

(defface pilish-pi-thinking
  '((((class color) (min-colors 256) (background light))
     :foreground "#7c868c" :slant italic)
    (((class color) (min-colors 256))
     :foreground "#96a0a4" :slant italic)
    (t :inherit shadow :slant italic))
  "Face for thinking in the `pi' style (Pi's thinkingText)."
  :group 'pilish-style)

(defconst pilish--pi-face-remappings
  '((pilish-tool-block . pilish-pi-tool-pending)
    (pilish-tool-block-success . pilish-pi-tool-success)
    (pilish-tool-block-error . pilish-pi-tool-error)
    (pilish-tool-name . pilish-pi-tool-title)
    (pilish-tool-command . pilish-pi-tool-title)
    (pilish-tool-output . pilish-pi-tool-output))
  "Faces the `pi' style remaps in its buffers, as (FACE . PI-FACE).")

;;;; Style activation

(defvar-local pilish--chat-style-applied nil
  "Chat style currently installed in this buffer, or nil for `classic'.")

(defun pilish--apply-chat-style ()
  "Install `pilish-chat-style' in the current transcript buffer.
Removes a previously installed style first, so this is also how buffers
follow a changed setting."
  (pilish--remove-chat-style)
  (when (eq pilish-chat-style 'pi)
    (setq pilish--chat-style-applied 'pi)
    (add-to-invisibility-spec 'pilish-style-heading)
    ;; Replace the faces' definitions in this buffer, so theme colours of
    ;; the classic faces (e.g. inherited function-name colours) don't leak.
    (pcase-dolist (`(,face . ,pi-face) pilish--pi-face-remappings)
      (face-remap-set-base face pi-face))
    ;; Like `jit-lock-register', but after font-lock in every chunk: the
    ;; padding depends on which lines Markdown fontification hides.
    (add-hook 'jit-lock-functions #'pilish--style-decorate 90 t)
    (jit-lock-mode t)
    (jit-lock-refontify)))

(defvar-local pilish--input-style-cookie nil
  "Face remapping cookie of the input background, or nil.")

(defun pilish--apply-input-style ()
  "Install `pilish-chat-style' in the current input buffer.
Removes a previously installed style first, so this is also how buffers
follow a changed setting."
  (when pilish--input-style-cookie
    (face-remap-remove-relative pilish--input-style-cookie)
    (setq pilish--input-style-cookie nil))
  (when (eq pilish-chat-style 'pi)
    (setq pilish--input-style-cookie
          (face-remap-add-relative 'default 'pilish-pi-user-message))))

(add-hook 'pilish-input-mode-hook #'pilish--apply-input-style)

(defun pilish--remove-chat-style ()
  "Remove the installed chat style from the current buffer."
  (when pilish--chat-style-applied
    (jit-lock-unregister #'pilish--style-decorate)
    (pcase-dolist (`(,face . ,_) pilish--pi-face-remappings)
      (face-remap-reset-base face))
    (remove-from-invisibility-spec 'pilish-style-heading)
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'pilish-style-overlay t))
    (setq pilish--chat-style-applied nil)
    (jit-lock-refontify)))

;;;; Decoration

(defconst pilish--style-summary-heading-re
  "^\\(?:Compaction\\|Branch Summary\\)\\(?: · .*\\)?$"
  "Regex matching the label line of a summary heading.
Turn headings use upstream's `pilish--turn-heading-re'.")

(defconst pilish--style-heading-line-re
  (concat pilish--turn-heading-re "\\|" pilish--style-summary-heading-re)
  "Regex matching the label line of any heading the `pi' style decorates.")

(defun pilish--style-heading-at-point ()
  "Return (LABEL START LABEL-END END) for a heading on point's line, or nil.
Turn headings are recognized by `pilish--at-turn-heading-p'; summary
headings share its setext form.  END is after the underline's newline."
  (save-excursion
    (forward-line 0)
    (when (or (pilish--at-turn-heading-p)
              (and (looking-at pilish--style-summary-heading-re)
                   (save-excursion
                     (forward-line 1)
                     (looking-at "^=\\{3,\\}$"))))
      (let ((start (point))
            (label-end (line-end-position)))
        (forward-line 1)
        (list (car (split-string (buffer-substring-no-properties start label-end)
                                 " · "))
              start label-end (min (1+ (line-end-position)) (point-max)))))))

(defun pilish--style-search-heading (backward)
  "Find the next heading from point, or the previous with BACKWARD.
Return its (LABEL START LABEL-END END) and leave point past its label
line start in the search direction, or return nil."
  (let (heading)
    (while (and (not heading)
                (if backward
                    (re-search-backward pilish--style-heading-line-re nil t)
                  (re-search-forward pilish--style-heading-line-re nil t)))
      (setq heading (save-excursion
                      (goto-char (match-beginning 0))
                      (pilish--style-heading-at-point))))
    heading))

(defun pilish--style-prefix (face)
  "Return a one-column line prefix drawn with FACE, like Pi's block padding."
  (propertize " " 'face face))

(defun pilish--style-pad (face)
  "Return a padding line drawn with FACE, for display before or after a block."
  (propertize "\n" 'face face))

(defun pilish--style-text-hidden-p (position)
  "Return non-nil when the text at POSITION is hidden by its own properties.
Markdown markup hidden by `md-ts-mode' and Pilish's empty `display'
guards count; overlays, including the style's own, do not."
  (or (invisible-p (get-text-property position 'invisible))
      (equal (get-text-property position 'display) "")))

(defun pilish--style-hidden-tail (start end)
  "Return the newline ending START..END when its whole last line is hidden.
A closing code fence is such a line.  Return nil otherwise."
  (when (and (< start end) (eq (char-before end) ?\n))
    (let ((pos (save-excursion
                 (goto-char (1- end))
                 (max start (line-beginning-position)))))
      (while (and (< pos end) (pilish--style-text-hidden-p pos))
        (setq pos (1+ pos)))
      (and (= pos end) (1- end)))))

(defun pilish--style-bottom-pad (kind start end face)
  "Return KIND decorations padding the bottom of block START..END with FACE.
The value is (PROPS . SPECS): PROPS for the block's own overlay and
SPECS for separate decorations.  When the block's last line is hidden,
its newline is shown instead and becomes the padding row, painted by
the block's extended face: an overlay string with a newline next to a
wholly hidden line stops `vertical-motion' and `line-move' moving up
past it, which would trap line motion and scrolling at the block.
Otherwise the padding is an `after-string'."
  (if-let* ((newline (pilish--style-hidden-tail start end)))
      ;; An `invisible' value outside the spec and a display spec that
      ;; replaces no text override the hiding text properties.
      (cons nil (list (list kind newline end
                            'invisible 'pilish-style-shown
                            'display '(raise 0))))
    (let ((pad (pilish--style-pad face)))
      (cons (list 'after-string (if (eq (char-before end) ?\n)
                                    pad
                                  (concat "\n" pad)))
            nil))))

(defun pilish--style-sync (beg end kinds wanted)
  "Make the KINDS decorations overlapping BEG..END exactly WANTED.
WANTED is a list of (KIND START END . PROPS).  Each spec reuses the
overlay of its KIND that starts at START, wherever that overlay ends,
else creates one.  Other overlays of KINDS overlapping BEG..END are
stale, left behind by rewritten text, and are deleted.  The cost
depends on the overlays near BEG..END and the specs, not on the
buffer or turn size."
  (let ((index (make-hash-table :test #'equal))
        (kept (make-hash-table :test #'eq))
        existing)
    (dolist (ov (overlays-in beg end))
      (when (memq (overlay-get ov 'pilish-style-kind) kinds)
        (push ov existing)))
    (pcase-dolist (`(,kind ,start . ,_) wanted)
      (dolist (ov (overlays-at start))
        (when (eq (overlay-get ov 'pilish-style-kind) kind)
          (push ov existing))))
    (dolist (ov existing)
      (let ((key (cons (overlay-get ov 'pilish-style-kind) (overlay-start ov))))
        (unless (memq ov (gethash key index))
          (push ov (gethash key index)))))
    (pcase-dolist (`(,kind ,start ,stop . ,props) wanted)
      (let* ((key (cons kind start))
             (overlay (pop (gethash key index))))
        (if overlay
            (move-overlay overlay start stop)
          (setq overlay (make-overlay start stop nil nil nil))
          (overlay-put overlay 'pilish-style-overlay t)
          (overlay-put overlay 'pilish-style-kind kind)
          (overlay-put overlay 'evaporate t))
        (puthash overlay t kept)
        (while props
          (overlay-put overlay (pop props) (pop props)))))
    (dolist (ov existing)
      (unless (gethash ov kept)
        (delete-overlay ov)))))

(defun pilish--style-headings (start end)
  "Return the turn headings that own or begin in START..END, and the limit.
The value is (HEADINGS . LIMIT).  HEADINGS lists (LABEL START LABEL-END
END) in buffer order, beginning with the heading whose block covers START.
LIMIT is the start of the first heading at or after END, or `point-max';
it closes the last block.  Only text near START..END and up to the
neighbouring headings is searched."
  (let (headings limit scan heading)
    (goto-char start)
    (forward-line 0)
    (setq scan (point))
    ;; A heading straddles the line start only when its label is on the
    ;; previous line; scan from there.  Otherwise the owner ends before it.
    (if (and (zerop (forward-line -1))
             (pilish--style-heading-at-point))
        (setq scan (point))
      (goto-char scan))
    (when (setq heading (pilish--style-search-heading t))
      (push heading headings))
    (goto-char scan)
    (while (and (not limit) (setq heading (pilish--style-search-heading nil)))
      (if (< (nth 1 heading) end)
          (push heading headings)
        (setq limit (nth 1 heading))))
    (cons (nreverse headings) (or limit (point-max)))))

(defun pilish--style-turn-decorations (headings limit)
  "Return decorations for HEADINGS, whose last block ends at LIMIT."
  (let (wanted)
    (while headings
      (pcase-let* ((`(,label ,start ,label-end ,end) (pop headings))
                   (block-end (if headings (nth 1 (car headings)) limit)))
        (pcase label
          ("You"
           (push (list 'heading start end 'invisible 'pilish-style-heading)
                 wanted)
           (when (< end block-end)
             (push (list 'block end block-end
                         'face 'pilish-pi-user-message
                         'line-prefix (pilish--style-prefix 'pilish-pi-user-message)
                         'wrap-prefix (pilish--style-prefix 'pilish-pi-user-message))
                   wanted)))
          ("Assistant"
           (push (list 'heading start end 'invisible 'pilish-style-heading)
                 wanted))
          (_
           ;; Summaries keep their label line, as Pi labels custom messages.
           (push (list 'heading (1+ label-end) end
                       'invisible 'pilish-style-heading)
                 wanted)
           (push (list 'label start label-end
                       'face 'pilish-pi-custom-message-label)
                 wanted)
           (when (< start block-end)
             (push (list 'block start block-end
                         'before-string (pilish--style-pad 'pilish-pi-custom-message)
                         'face 'pilish-pi-custom-message
                         'line-prefix (pilish--style-prefix 'pilish-pi-custom-message)
                         'wrap-prefix (pilish--style-prefix 'pilish-pi-custom-message))
                   wanted))))))
    wanted))

(defun pilish--style-property-decorations (beg end property kind props)
  "Return KIND decorations with PROPS for PROPERTY spans in BEG..END.
Adjacent spans with different PROPERTY values stay separate."
  (let ((pos beg) wanted)
    (while (< pos end)
      (let ((value (get-text-property pos property))
            (next (next-single-property-change pos property nil end)))
        (when value
          (push (append (list kind pos next) props) wanted))
        (setq pos next)))
    wanted))

(defun pilish--style-property-bounds (beg end property)
  "Return BEG..END widened to whole PROPERTY spans, as a cons."
  (cons (if (and (> beg (point-min)) (get-text-property (1- beg) property))
            (or (previous-single-property-change beg property) (point-min))
          beg)
        (if (and (< end (point-max)) (get-text-property end property))
            (or (next-single-property-change end property) (point-max))
          end)))

(defcustom pilish-pi-highlighted-output-tools '("read" "write" "edit")
  "Tools whose output the `pi' style leaves highlighted.
Pi shows file contents and diffs with syntax colours and every other
tool result in its muted toolOutput colour, which the `pi' style
applies to the bodies of all other tool blocks."
  :type '(repeat string)
  :group 'pilish-style)

(defun pilish--style-tool-decorations (from to)
  "Return padding and output decorations for the tool blocks in FROM..TO.
Like Pi's tool boxes, each block gets a padding line above and below in
its current state colour, which follows the tool overlay's face (see
`pilish--style-bottom-pad').  The renderer keeps tool block overlays
disjoint; nested calls are text inside their parent's block."
  (let (wanted)
    (dolist (tool (seq-filter (lambda (ov) (overlay-get ov 'pilish-tool-block))
                              (overlays-in from to)))
      (let* ((start (overlay-start tool))
             (end (overlay-end tool))
             (face (or (overlay-get tool 'face) 'pilish-tool-block)))
        (when (< start end)
          (pcase-let ((`(,props . ,specs)
                       (pilish--style-bottom-pad 'tool-tail start end face)))
            (push (append (list 'tool-pad start end
                                'before-string (pilish--style-pad face)
                                'after-string nil)
                          props)
                  wanted)
            (setq wanted (append specs wanted)))
          (when-let* (((not (member (overlay-get tool 'pilish-tool-name)
                                    pilish-pi-highlighted-output-tools)))
                      (header-end (overlay-get tool 'pilish-header-end))
                      (body (marker-position header-end))
                      ((< body end)))
            (push (list 'tool-output body end 'face 'pilish-pi-tool-output)
                  wanted)))))
    wanted))

(defun pilish--style-custom-decorations (beg end)
  "Return the decorations of the custom message spans in BEG..END.
Each span is a padded block in Pi's custom message colour (see
`pilish--style-bottom-pad')."
  (let* ((face 'pilish-pi-custom-message)
         (prefix (pilish--style-prefix face))
         wanted)
    (pcase-dolist (`(,kind ,start ,stop . ,props)
                   (pilish--style-property-decorations
                    beg end 'pilish-custom-message 'custom
                    (list 'face face 'line-prefix prefix 'wrap-prefix prefix
                          'before-string (pilish--style-pad face)
                          'after-string nil)))
      (pcase-let ((`(,pad-props . ,specs)
                   (pilish--style-bottom-pad 'custom-tail start stop face)))
        (push (append (list kind start stop) props pad-props) wanted)
        (setq wanted (append specs wanted))))
    wanted))

(defun pilish--style-decorate (start end)
  "Decorate START..END for the installed chat style.
A `jit-lock' function.  It touches only the blocks overlapping START..END
and the turn heading owning START, so blocks stay consistent however the
region was chunked and the cost does not grow with the turn."
  (when (eq pilish--chat-style-applied 'pi)
    (save-excursion
      (save-restriction
        (widen)
        (save-match-data
          (pcase-let ((`(,headings . ,limit) (pilish--style-headings start end)))
            (pilish--style-sync start end '(heading block label)
                                (pilish--style-turn-decorations headings limit)))
          (pilish--style-sync start end '(tool-pad tool-tail tool-output)
                              (pilish--style-tool-decorations start end))
          (pcase-let ((`(,beg . ,stop)
                       (pilish--style-property-bounds start end 'pilish-thinking-block)))
            (pilish--style-sync beg stop '(thinking)
                                (pilish--style-property-decorations
                                 beg stop 'pilish-thinking-block 'thinking
                                 '(face pilish-pi-thinking))))
          (pcase-let ((`(,beg . ,stop)
                       (pilish--style-property-bounds start end 'pilish-custom-message)))
            (pilish--style-sync beg stop '(custom custom-tail)
                                (pilish--style-custom-decorations beg stop))))))))

(provide 'pilish-style)
;;; pilish-style.el ends here
