;;; herdr-worktree-test.el --- Tests for the worktree record -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-worktree)
(require 'herdr-test-helper)

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

(ert-deftest herdr-worktree-open-workspace-names-its-server ()
  "The id is a per-server counter, so the answer is only meaningful
paired with the connection whose listing it came from."
  (let ((one (herdr-test-connection))
        (two (herdr-test-connection)))
    (should (equal (cons (herdr-connection-token one) "w1")
                   (herdr-worktree-open-workspace
                    one herdr-worktree-test--record)))
    (should-not (equal (herdr-worktree-open-workspace
                        one herdr-worktree-test--record)
                       (herdr-worktree-open-workspace
                        two herdr-worktree-test--record)))
    (should-not (herdr-worktree-open-workspace one '((path . "/tmp/x"))))))

(ert-deftest herdr-worktree-open-as-p-does-not-confuse-two-servers ()
  "Two servers can each issue a `w1'.  Comparing bare ids would have a
worktree on one server read as open as the other server's workspace —
and the verb that follows would close it."
  (let ((one (herdr-test-connection))
        (two (herdr-test-connection)))
    (should (herdr-worktree-open-as-p
             one herdr-worktree-test--record
             (herdr-workspace-qualified one "w1")))
    ;; The same bare id, the other server: not the same workspace.
    (should-not (herdr-worktree-open-as-p
                 one herdr-worktree-test--record
                 (herdr-workspace-qualified two "w1")))
    ;; Not "both nil, therefore the same thing".
    (should-not (herdr-worktree-open-as-p
                 one '((path . "/tmp/x"))
                 (herdr-workspace-qualified one nil)))))

(ert-deftest herdr-worktree-a-qualified-id-survives-a-cache-mutation ()
  "The pair holds the token, not the struct, so it goes on matching
across a reconnect."
  (let* ((connection (herdr-test-connection))
         (before (herdr-workspace-qualified connection "w1")))
    (setf (herdr-connection-cache connection) 'replaced
          (herdr-connection-generation connection) 7)
    (should (equal before (herdr-workspace-qualified connection "w1")))
    (should (herdr-worktree-open-as-p
             connection herdr-worktree-test--record before))))

(provide 'herdr-worktree-test)
;;; herdr-worktree-test.el ends here
