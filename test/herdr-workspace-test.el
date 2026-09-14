;;; herdr-workspace-test.el --- Tests for the workspace record -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-workspace)

(defconst herdr-workspace-test--source-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "The package root, found from this file rather than from `default-directory'.
`make test' and a test run from inside Emacs do not agree about the
latter.")

;;; Fields

(ert-deftest herdr-workspace-fields-read-the-record ()
  (let ((workspace '((workspace_id . "w1")
                     (label . "web")
                     (pane_count . 3)
                     (agent_status . "working"))))
    (should (equal "w1" (herdr-workspace-id workspace)))
    (should (equal "web" (herdr-workspace-label workspace)))
    (should (equal 3 (herdr-workspace-pane-count workspace)))
    (should (equal "working" (herdr-workspace-status workspace)))))

(ert-deftest herdr-workspace-fields-are-nil-when-the-record-omits-them ()
  "Every field but the id may be absent from a record a test constructs,
and from one the server sends for a workspace with nothing in it."
  (let ((workspace '((workspace_id . "w1"))))
    (should (equal "w1" (herdr-workspace-id workspace)))
    (should-not (herdr-workspace-label workspace))
    (should-not (herdr-workspace-pane-count workspace))
    (should-not (herdr-workspace-status workspace))))

(ert-deftest herdr-workspace-an-id-alone-answers-every-accessor ()
  "Tests across the suite construct workspaces this minimal, and a
picker built from one must not signal."
  (let ((workspace '((workspace_id . "w9"))))
    (should (equal "w9" (herdr-workspace-identity workspace)))
    (should-not (herdr-workspace-label workspace))))

;;; An empty label is no label

(ert-deftest herdr-workspace-an-empty-label-reads-as-absent ()
  "The defect this module exists to remove.  The server sends an empty
label for a workspace nobody has named, and an empty string is truthy in
Emacs Lisp, so a plain `or' fallback never fires and the dashboard drew
the workspace with no name at all."
  (should-not (herdr-workspace-label '((workspace_id . "w1") (label . "")))))

(ert-deftest herdr-workspace-identity-falls-back-to-the-id ()
  (should (equal "w1" (herdr-workspace-identity
                       '((workspace_id . "w1") (label . "")))))
  (should (equal "w1" (herdr-workspace-identity '((workspace_id . "w1"))))))

(ert-deftest herdr-workspace-identity-is-never-empty ()
  "Identity is what a caller prints when it must print something."
  (dolist (workspace '(((workspace_id . "w1"))
                       ((workspace_id . "w1") (label . ""))
                       ((workspace_id . "w1") (label . "web"))))
    (let ((identity (herdr-workspace-identity workspace)))
      (should (stringp identity))
      (should-not (string-empty-p identity)))))

;;; One reader

(defun herdr-workspace-test--sources ()
  "Return the package's own source files, `herdr-workspace.el' excluded."
  (seq-remove (lambda (file)
                (equal "herdr-workspace.el" (file-name-nondirectory file)))
              (directory-files herdr-workspace-test--source-directory t
                               "\\`herdr.*\\.el\\'")))

(ert-deftest herdr-workspace-is-the-only-file-that-reads-a-workspace-record ()
  "The wire lives in one file, and this is what keeps it there.

The rule is narrow on purpose: a variable called `workspace' holds a
workspace record, and only `herdr-workspace.el' may read a field off
one.  It cannot catch a record bound to some other name, so it is a
floor, not a proof."
  (let (offenders)
    (dolist (file (herdr-workspace-test--sources))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        ;; `workspace)' and `workspace nil)' and a line break between
        ;; them: the three-argument form and a wrapped call are the two
        ;; ways the pane version of this regexp was walked past.
        (while (re-search-forward
                "(alist-get[ \t\n]+'[a-z_]+[ \t\n]+workspace[ \t\n)]" nil t)
          (push (format "%s:%d" (file-name-nondirectory file)
                        (line-number-at-pos))
                offenders))))
    (should-not offenders)))

;;; A leaf

(ert-deftest herdr-workspace-requires-no-herdr-module ()
  "A leaf, like `herdr-pane'.  `herdr-state' requires this file, so a
`require' pointing back would be a cycle, and a workspace's directory is
derived from its panes and therefore stays in the cache."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "herdr-workspace.el" herdr-workspace-test--source-directory))
    (goto-char (point-min))
    ;; Not anchored to column zero: `eval-when-compile' and `with-eval-
    ;; after-load' both indent a `require' out of a column-zero match.
    (should-not (re-search-forward "(require 'herdr" nil t))))

(provide 'herdr-workspace-test)
;;; herdr-workspace-test.el ends here
