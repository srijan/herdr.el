;;; herdr-agents-test.el --- Tests for the agent surface -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-agents)

(defun herdr-agents-test--state (&rest specs)
  "Build a state from SPECS, each (ID AGENT STATUS)."
  (herdr-state-from-snapshot
   `((panes . ,(mapcar (lambda (spec)
                         `((pane_id . ,(nth 0 spec))
                           (agent . ,(nth 1 spec))
                           (agent_status . ,(nth 2 spec))
                           (workspace_id . "w1")))
                       specs)))))

(ert-deftest herdr-agents-segment-counts-noteworthy-statuses ()
  (should (equal "herdr:2\u23f81\u2713"
                 (herdr-agents--segment
                  (herdr-agents-test--state
                   '("w1:p1" "claude" "blocked")
                   '("w1:p2" "codex" "blocked")
                   '("w1:p3" "gemini" "done"))))))

(ert-deftest herdr-agents-segment-omits-idle ()
  "An always-on count stops being read; idle agents are not news."
  (should (equal "" (herdr-agents--segment
                     (herdr-agents-test--state '("w1:p1" "claude" "idle"))))))

(ert-deftest herdr-agents-segment-is-empty-without-agents ()
  (should (equal "" (herdr-agents--segment (herdr-state-empty))))
  (should (equal "" (herdr-agents--segment
                     (herdr-agents-test--state '("w1:p1" nil nil))))))

(ert-deftest herdr-agents-segment-shows-working ()
  (should (equal "herdr:1\u25b6"
                 (herdr-agents--segment
                  (herdr-agents-test--state '("w1:p1" "claude" "working"))))))

(ert-deftest herdr-agents-counts-ignore-non-agent-panes ()
  (let ((counts (herdr-agents--counts
                 (herdr-agents-test--state '("w1:p1" "claude" "blocked")
                                           '("w1:p2" nil "unknown")))))
    (should (equal 1 (alist-get "blocked" counts nil nil #'equal)))
    (should (null (alist-get "unknown" counts nil nil #'equal)))))

(ert-deftest herdr-agents-tree-tags-lines-with-their-pane ()
  "RET on a line needs to know which pane it names."
  (with-temp-buffer
    (herdr-agents--insert-tree
     (herdr-state-from-snapshot
      '((workspaces . (((workspace_id . "w1") (label . "web"))))
        (panes . (((pane_id . "w1:p1") (agent . "claude")
                   (agent_status . "blocked") (workspace_id . "w1")))))))
    (goto-char (point-min))
    (forward-line 1)
    (should (equal "w1:p1"
                   (get-text-property (line-beginning-position)
                                      'herdr-pane-id)))))

(ert-deftest herdr-agents-segment-ignores-adopted-shells ()
  "An adopted shell has a buffer but is not an agent; it must not count."
  (should (equal "herdr:1⏸"
                 (herdr-agents--segment
                  (herdr-agents-test--state
                   '("w1:p1" "claude" "blocked")
                   '("w1:p2" "shell" "blocked"))))))

(provide 'herdr-agents-test)
;;; herdr-agents-test.el ends here
