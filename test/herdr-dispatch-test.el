;;; herdr-dispatch-test.el --- Tests for the dispatcher buffer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-tree)

;; magit-section is a hard dependency of herdr-dispatch and is not on the
;; load path under `emacs -Q -L .', which is what `make test' uses.  The
;; tree model is covered hermetically in herdr-tree-test; these tests
;; cover the renderer and only run where the dependency exists.
(when (require 'magit-section nil t)
  (require 'herdr-dispatch))

(defmacro herdr-dispatch-test-with-buffer (nodes &rest body)
  "Render NODES into a temporary dispatcher buffer and run BODY there."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (featurep 'magit-section))
     (with-temp-buffer
       (herdr-dispatch-mode)
       (let ((inhibit-read-only t))
         (magit-insert-section (herdr-root)
           (herdr-dispatch--insert-nodes ,nodes)))
       (goto-char (point-min))
       ,@body)))

(defconst herdr-dispatch-test--nodes
  '((herdr-workspace "w1" "herdr.el  /tmp/herdr.el  2 panes"
     ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
      (herdr-pane "w1:p2" "| codex blocked w1:p2" nil))))
  "A two-pane workspace, already in tree form.")

(ert-deftest herdr-dispatch-renders-every-line ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (string-match-p "herdr.el" (buffer-string)))
    (should (string-match-p "w1:p1" (buffer-string)))
    (should (string-match-p "w1:p2" (buffer-string)))))

(ert-deftest herdr-dispatch-tags-sections-with-type-and-value ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p1")
    (let ((section (magit-current-section)))
      (should (eq 'herdr-pane (oref section type)))
      (should (equal "w1:p1" (oref section value))))))

(ert-deftest herdr-dispatch-nests-panes-under-their-workspace ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p1")
    (should (eq 'herdr-workspace
                (oref (oref (magit-current-section) parent) type)))))

(provide 'herdr-dispatch-test)
;;; herdr-dispatch-test.el ends here
