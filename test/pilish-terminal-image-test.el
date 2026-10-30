;;; pilish-terminal-image-test.el --- Tests for terminal images -*- lexical-binding: t; -*-

;;; Commentary:

;; Terminal image logic without a terminal.  The real path through Ghostty
;; needs a display and is covered by the verification notes in AGENTS.md.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pilish-test-common)
(require 'pilish-terminal-image)

(defconst pilish-test--terminal-png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0eNT6AAAADklEQVR4nGP4z8DwHwAFAAH/yVgdOQAAAABJRU5ErkJggg==")
  "A two-by-one PNG.")

(defmacro pilish-test--with-terminal-window (&rest body)
  "Run BODY in a chat where the selected window counts as a capable terminal."
  (declare (indent 0) (debug t))
  `(let (sent (inhibit-read-only t))
     (with-temp-buffer
       (pilish-chat-mode)
       (cl-letf (((symbol-function 'pilish--terminal-image-frame-p) (lambda (_) t))
                 ((symbol-function 'pilish--terminal-image-windows)
                  (lambda () (list (selected-window))))
                 ((symbol-function 'window-body-width) (lambda (&rest _) 80))
                 ((symbol-function 'window-body-height) (lambda (&rest _) 24))
                 ((symbol-function 'send-string-to-terminal)
                  (lambda (string &rest _) (push string sent)))
                 ((symbol-function 'terminal-parameter)
                  (let ((table (make-hash-table)))
                    (lambda (&rest _) table)))
                 ((symbol-function 'pilish--terminal-image-range)
                  (lambda (_) (cons (point-min) (point-max)))))
         ,@body))))

(defun pilish-test--insert-terminal-preview ()
  "Insert an image preview for the test PNG at point."
  (insert (pilish--image-preview-string
           "Image: image/png, 71 B"
           (list 'image :type 'png :data pilish-test--terminal-png))
          "\n"))

(ert-deftest pilish-test-terminal-image-frame-needs-type-and-truecolor ()
  "Only exact terminal types with 24-bit color qualify."
  (let ((frame (selected-frame)) (type "xterm-ghostty") (cells 16777216))
    (cl-letf (((symbol-function 'framep) (lambda (_) t))
              ((symbol-function 'frame-parameter) (lambda (&rest _) type))
              ((symbol-function 'display-color-cells) (lambda (&rest _) cells)))
      (dolist (good '("xterm-ghostty" "xterm-ghostty-truecolor" "xterm-kitty"))
        (setq type good)
        (should (pilish--terminal-image-frame-p frame)))
      ;; mosh, tmux and unknown terminals keep the label.
      (dolist (bad '("xterm-256color" "tmux-256color" "xterm-ghostty2" nil))
        (setq type bad)
        (should-not (pilish--terminal-image-frame-p frame)))
      (setq type "xterm-ghostty" cells 256)
      (should-not (pilish--terminal-image-frame-p frame))
      (setq cells 16777216)
      (let ((pilish-terminal-image-types nil))
        (should-not (pilish--terminal-image-frame-p frame))))))

(ert-deftest pilish-test-terminal-image-png-size ()
  "PNG dimensions come from the header; short data has none."
  (should (equal '(2 . 1) (pilish--terminal-image-png-size pilish-test--terminal-png)))
  (should-not (pilish--terminal-image-png-size "short")))

(ert-deftest pilish-test-terminal-image-sequences-chunk-and-silence ()
  "Sequences keep the size limit, and every chunk suppresses replies."
  (let* ((png (make-string 10000 ?a))
         (sequences (pilish--terminal-image-sequences 7 png))
         (chunks (split-string sequences "\e\\\\" t)))
    (should (> (length chunks) 1))
    (should (string-prefix-p "\e_Ga=t,f=100,i=7,q=2,m=1;" (car chunks)))
    (should (string-prefix-p "\e_Gq=2,m=0;" (car (last chunks))))
    (dolist (chunk chunks)
      (should (string-match-p "q=2" chunk))
      (should (<= (length (cadr (split-string chunk ";")))
                  pilish--terminal-image-chunk-size)))
    (should (equal (base64-encode-string png t)
                   (mapconcat (lambda (chunk) (cadr (split-string chunk ";")))
                              chunks "")))))

(ert-deftest pilish-test-terminal-image-grid-uses-composed-cells ()
  "Grid cells carry row and column marks as compositions, and the id as color."
  (let* ((grid (pilish--terminal-image-grid #x000102 '(2 . 2)))
         (lines (split-string grid "\n")))
    (should (= 2 (length lines)))
    (should (= (string-to-char (substring grid 0 1))
               pilish--terminal-image-placeholder))
    (should (equal (substring-no-properties grid 0 3)
                   (string #x10EEEE #x0305 #x0305)))
    ;; Without a composition Emacs gives each mark a column of its own.
    (should (get-text-property 0 'composition grid))
    (should (equal "#000102" (plist-get (get-text-property 0 'face grid) :foreground)))))

(ert-deftest pilish-test-terminal-image-size-keeps-shape-within-windows ()
  "Size follows the image and shrinks to the window and configured width."
  (let ((pilish-image-preview-max-width 900))
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 100))
              ((symbol-function 'window-body-height) (lambda (&rest _) 40)))
      (cl-flet ((size (width height)
                  (pilish--terminal-image-size
                   (pilish--timage-create 1 "" width height) '(window))))
        ;; An icon stays small.
        (should (equal '(2 . 1) (size 16 16)))
        ;; Width follows the window until the height limit shapes the box.
        (should (equal '(98 . 10) (size 2000 400)))
        (should (equal '(80 . 20) (size 2000 1000)))
        ;; A tall image is limited to half the window height.
        (should (equal '(20 . 20) (size 1000 2000)))))))

(ert-deftest pilish-test-terminal-image-update-overlays-only-the-window ()
  "A preview gets a window-scoped overlay and keeps its image for GUI frames."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (pilish--terminal-image-update)
    (should (= 1 (length pilish--terminal-image-overlays)))
    (let ((overlay (car pilish--terminal-image-overlays)))
      (should (eq (selected-window) (overlay-get overlay 'window)))
      (should (string-prefix-p (string pilish--terminal-image-placeholder)
                               (overlay-get overlay 'display))))
    (should (eq 'image (car (get-text-property (point-min) 'display))))))

(ert-deftest pilish-test-terminal-image-overlay-takes-in-closing-fence ()
  "The overlay covers a hidden fence, which would otherwise trap upward motion."
  (pilish-test--with-terminal-window
    (insert "```text\nRead image file\n```\n")
    (let ((fence (line-beginning-position 0)))
      (pilish-test--insert-terminal-preview)
      (pilish--terminal-image-update)
      (should (= fence (overlay-start (car pilish--terminal-image-overlays))))
      (pilish--terminal-image-update)
      (should (= 1 (length pilish--terminal-image-overlays))))))

(ert-deftest pilish-test-terminal-image-update-sends-once-per-terminal ()
  "Repeated updates reuse the terminal's copy and the overlay."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (pilish--terminal-image-update)
    (let ((overlay (car pilish--terminal-image-overlays)))
      (should (= 2 (length sent)))
      (pilish--terminal-image-update)
      (should (= 2 (length sent)))
      (should (equal (list overlay) pilish--terminal-image-overlays)))))

(ert-deftest pilish-test-terminal-image-update-places-again-on-resize ()
  "A new size repeats the placement but not the image data."
  (pilish-test--with-terminal-window
    (let ((image (list 'image :type 'png :data (make-string 40 ?x))))
      (cl-letf (((symbol-function 'pilish--terminal-image-for-spec)
                 (lambda (_) (pilish--timage-create 1 "png" 800 400)))
                ((symbol-function 'window-body-width) (lambda (&rest _) 40)))
        (insert (pilish--image-preview-string "Image" image) "\n")
        (pilish--terminal-image-update)
        (should (= 2 (length sent)))
        (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 30)))
          (pilish--terminal-image-update))
        (should (= 3 (length sent)))
        (should (string-match-p "c=28" (car sent)))
        (should (= 1 (length pilish--terminal-image-overlays)))))))

(ert-deftest pilish-test-terminal-image-unsupported-keeps-label ()
  "An image without a PNG form stays the text label."
  (pilish-test--with-terminal-window
    (cl-letf (((symbol-function 'pilish--terminal-image-converter) #'ignore))
      (insert (pilish--image-preview-string
               "Image: image/jpeg"
               (list 'image :type 'jpeg :data (make-string 40 ?j)))
              "\n")
      (pilish--terminal-image-update)
      (should-not pilish--terminal-image-overlays)
      (should-not sent))))

(ert-deftest pilish-test-terminal-image-svg-never-reaches-converter ()
  "SVG stays out of ImageMagick, which could follow its references."
  (cl-letf (((symbol-function 'pilish--terminal-image-converter)
             (lambda () (ert-fail "Converter consulted for SVG")))
            ((symbol-function 'call-process-region)
             (lambda (&rest _) (ert-fail "Process started for SVG"))))
    (should-not (pilish--terminal-image-as-png "<svg/>" 'svg))))

(ert-deftest pilish-test-terminal-image-update-drops-overlays-of-gone-windows ()
  "Overlays of windows no longer showing the chat are removed."
  (pilish-test--with-terminal-window
    (pilish-test--insert-terminal-preview)
    (pilish--terminal-image-update)
    (let ((overlay (car pilish--terminal-image-overlays)))
      (cl-letf (((symbol-function 'pilish--terminal-image-windows) #'ignore))
        (pilish--terminal-image-update))
      (should-not pilish--terminal-image-overlays)
      (should-not (overlay-buffer overlay)))))

(ert-deftest pilish-test-terminal-image-preview-insertion-schedules-update ()
  "Inserting a preview while a terminal window shows the chat updates it."
  (pilish-test--with-terminal-window
    (let (scheduled)
      (pilish--terminal-image-update)
      (cl-letf (((symbol-function 'pilish--terminal-image-schedule)
                 (lambda () (setq scheduled t))))
        (insert "ordinary text")
        (should-not scheduled)
        (pilish-test--insert-terminal-preview)
        (should scheduled)))))

(ert-deftest pilish-test-terminal-image-graphical-windows-schedule-nothing ()
  "Windows without capable terminals cost no updates."
  (with-temp-buffer
    (pilish-chat-mode)
    (cl-letf (((symbol-function 'pilish--terminal-image-frame-p) #'ignore))
      (pilish--terminal-image-window-changed (selected-window))
      (should-not pilish--terminal-image-timer))))

(provide 'pilish-terminal-image-test)
;;; pilish-terminal-image-test.el ends here
