;;; herdr-worktree-test.el --- Tests for the worktree record -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-worktree)

(defconst herdr-worktree-test--record
  '((path . "/tmp/repo-feat/")
    (branch . "feat/x")
    (label . "feature x")
    (is_linked_worktree . t)
    (open_workspace_id . "w1"))
  "A linked worktree herdr has opened as a workspace.")

(ert-deftest herdr-worktree-reads-its-fields ()
  (let ((worktree herdr-worktree-test--record))
    (should (equal "/tmp/repo-feat/" (herdr-worktree-path worktree)))
    (should (equal "feat/x" (herdr-worktree-branch worktree)))
    (should (equal "feature x" (herdr-worktree-label worktree)))
    (should (herdr-worktree-linked-p worktree))
    (should (equal "w1" (herdr-worktree-open-workspace-id worktree)))))

(ert-deftest herdr-worktree-name-falls-back-rather-than-answering-empty ()
  "It is a column, so it cannot be nil."
  (should (equal "feat/x" (herdr-worktree-name herdr-worktree-test--record)))
  (should (equal "feature x"
                 (herdr-worktree-name '((label . "feature x")))))
  (should (equal "?" (herdr-worktree-name '((path . "/tmp/x"))))))

(ert-deftest herdr-worktree-absent-linked-flag-reads-as-not-linked ()
  "The field is required, so its absence is a reply the schema does not
describe.  Treating it as the main checkout costs a row; treating it as
linked costs whatever a verb on that row would do to the repository."
  (should-not (herdr-worktree-linked-p '((path . "/tmp/x"))))
  (should-not (herdr-worktree-linked-p '((is_linked_worktree . nil)))))

(ert-deftest herdr-worktree-listing-repo-root-is-read-not-inferred ()
  "MEASURED: `worktree.list' answers with a `source' object naming the
repository the listing was taken from, so the main checkout is read
rather than found by scanning for the entry that is not a linked
worktree.  The scan agreed whenever such an entry was present and
answered nil when it was not; `repo_root' is required."
  (let ((listing '((source . ((repo_key . "/tmp/repo/.git")
                              (repo_name . "repo")
                              (repo_root . "/tmp/repo")))
                   (worktrees . (((path . "/tmp/repo-worktrees/feature")
                                  (is_linked_worktree . t)))))))
    (should (equal "/tmp/repo" (herdr-worktree-listing-repo-root listing)))
    (should (equal 1 (length (herdr-worktree-listing-worktrees listing))))
    ;; A listing that never landed answers nil rather than signalling.
    (should-not (herdr-worktree-listing-repo-root nil))
    (should-not (herdr-worktree-listing-worktrees nil))))

(provide 'herdr-worktree-test)
;;; herdr-worktree-test.el ends here
