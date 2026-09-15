;;; herdr-dispatch-live-test.el --- Live dispatcher round trip -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-rpc)
(require 'herdr-state)
;; Unconditionally, for the reason given at the top of herdr-dispatch-test.el.
(require 'herdr-dispatch)

(defun herdr-dispatch-live-test--server-p ()
  "Return non-nil when a herdr server is reachable."
  (condition-case nil (progn (herdr-rpc-call (herdr-current-connection) "ping") t) (herdr-error nil)))

(ert-deftest herdr-dispatch-create-round-trip-leaves-the-session-unchanged ()
  "Create a workspace against the real server, then close it again.
Asserts the session holds exactly the workspaces it started with, so a
create path that leaks is caught here rather than in the user\\='s session."
  :tags '(:live)
  (skip-unless (herdr-dispatch-live-test--server-p))
  (let* ((before (mapcar (lambda (w) (herdr-workspace-id w))
                         (alist-get 'workspaces
                                    (alist-get 'snapshot
                                               (herdr-rpc-call (herdr-current-connection)
                                                "session.snapshot")))))
         (workspace (alist-get 'workspace_id
                               (alist-get 'workspace
                                          (herdr-rpc-call (herdr-current-connection)
                                           "workspace.create"
                                           `((cwd . ,(expand-file-name
                                                      temporary-file-directory))
                                             (label . "herdr-el-dispatch")
                                             (focus . t)))))))
    (unwind-protect
        (progn
          (herdr-state-resync (herdr-current-connection))
          (should (herdr-state-workspace-directory (herdr-state-current)
                                                   workspace)))
      (herdr-rpc-call (herdr-current-connection) "workspace.close" `((workspace_id . ,workspace))))
    (sleep-for 1)
    (let ((after (mapcar (lambda (w) (herdr-workspace-id w))
                         (alist-get 'workspaces
                                    (alist-get 'snapshot
                                               (herdr-rpc-call (herdr-current-connection)
                                                "session.snapshot"))))))
      (should (equal before after)))))

(provide 'herdr-dispatch-live-test)
;;; herdr-dispatch-live-test.el ends here
