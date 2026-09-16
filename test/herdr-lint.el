;;; herdr-lint.el --- Documentation checks for `make lint' -*- lexical-binding: t; -*-

;;; Commentary:

;; Not a test file: `make test' globs test/*-test.el and skips this one.
;; Run by `make lint', which exits non-zero on any finding.
;;
;; Two checkdoc classes are deliberate house style and are filtered out
;; rather than fixed, because fixing them would make the docstrings
;; worse:
;;
;; - "Argument `connection' should appear".  Nearly every function in
;;   the package takes a connection first.  Naming it in every docstring
;;   is boilerplate that buries the sentence actually worth reading.
;;
;; - "Messages should start with a capital letter".  Every message this
;;   package prints is prefixed `herdr: ', which is the convention that
;;   makes them findable in *Messages* and is worth more than the capital.
;;
;; The second check is not checkdoc's.  `\=' in a Lisp string is not an
;; escape, so a docstring written `foo\='s' renders as "foo='s": the
;; idiom needs two backslashes in the source.  It went unnoticed in 49
;; docstrings, so it is checked rather than remembered.

;;; Code:

(require 'checkdoc)
(require 'cl-lib)

(defconst herdr-lint-ignored
  (rx (or "Argument ‘connection’ should appear"
          "Messages should start with a capital letter"))
  "Findings that are house style, documented above.")

(defun herdr-lint--checkdoc (files)
  "Return checkdoc findings for FILES, minus `herdr-lint-ignored'."
  (let ((found nil))
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (emacs-lisp-mode)
        (let (;; Pinned, every one of them.  These default differently
              ;; across Emacs versions - the verb check is t on 28.1 and
              ;; 30.1 and nil on 31.1 - so an unpinned target is as
              ;; strict as whatever Emacs the author happens to run, and
              ;; CI disagrees with the laptop that said it was clean.
              (checkdoc-arguments-in-order-flag nil)
              (checkdoc-force-docstrings-flag t)
              (checkdoc-force-history-flag nil)
              (checkdoc-permit-comma-termination-flag nil)
              (checkdoc-spellcheck-documentation-flag nil)
              ;; Off, and not for quiet.  All 13 it found here were
              ;; false: it reads a verb anywhere in the first sentence,
              ;; not the one the sentence opens with, so "Return the
              ;; branch WORKTREE holds" is asked to say "hold" and
              ;; "Return STATE with CHANGES merged" is asked to rename
              ;; its own argument.  Emacs 31 turned it off by default.
              (checkdoc-verb-check-experimental-flag nil)
              (buffer-file-name (expand-file-name file))
              (checkdoc-diagnostic-buffer " *herdr-lint*")
              (checkdoc-create-error-function
               (lambda (text start _end &optional _unfixable)
                 (unless (string-match-p herdr-lint-ignored text)
                   (push (format "%s:%d: %s" (file-name-nondirectory file)
                                 (line-number-at-pos (or start (point-min)))
                                 text)
                         found))
                 nil)))
          (checkdoc-current-buffer t))))
    (nreverse found)))

(defun herdr-lint--stray-equals (files)
  "Return FILES\\=' docstrings that render a stray `=\\=' or a literal `\\=\\='."
  (let ((found nil))
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (emacs-lisp-mode)
        (goto-char (point-min))
        (while (search-forward "\\='" nil t)
          (let ((start (- (point) 3)))
            (when (and (save-excursion (nth 3 (syntax-ppss start)))
                       (not (eq (char-before start) ?\\)))
              (push (format "%s:%d: \\=' in a string needs two backslashes"
                            (file-name-nondirectory file)
                            (line-number-at-pos start))
                    found))))))
    (nreverse found)))

(defun herdr-lint-batch ()
  "Run every check over the package sources, then exit."
  (let* ((files (seq-remove (lambda (f) (string-suffix-p "-autoloads.el" f))
                           (file-expand-wildcards "herdr*.el")))
         (findings (append (herdr-lint--stray-equals files)
                           (herdr-lint--checkdoc files))))
    (dolist (finding findings) (princ (concat finding "\n")))
    (princ (format "herdr-lint: %d finding(s) in %d files\n"
                   (length findings) (length files)))
    (kill-emacs (if findings 1 0))))

(provide 'herdr-lint)
;;; herdr-lint.el ends here
