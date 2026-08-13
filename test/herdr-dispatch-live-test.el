;;; herdr-dispatch-live-test.el --- Live dispatcher round trip -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-rpc)
(require 'herdr-state)
;; Unconditionally, for the reason given at the top of
;; herdr-dispatch-test.el: `test/herdr-deps.el' has already put
;; magit-section on the load path, so a `(require 'magit-section nil t)'
;; here would only turn a broken dependency back into a silent skip.
(require 'herdr-dispatch)

(defun herdr-dispatch-live-test--server-p ()
  "Return non-nil when a herdr server is reachable."
  (condition-case nil (progn (herdr-rpc-call "ping") t) (herdr-error nil)))

(ert-deftest herdr-dispatch-create-round-trip-leaves-the-session-unchanged ()
  "Create a workspace against the real server, then close it again.
Asserts the session holds exactly the workspaces it started with, so a
create path that leaks is caught here rather than in the user\\='s session."
  :tags '(:live)
  (skip-unless (herdr-dispatch-live-test--server-p))
  (let* ((before (mapcar (lambda (w) (alist-get 'workspace_id w))
                         (alist-get 'workspaces
                                    (alist-get 'snapshot
                                               (herdr-rpc-call
                                                "session.snapshot")))))
         (workspace (alist-get 'workspace_id
                               (alist-get 'workspace
                                          (herdr-rpc-call
                                           "workspace.create"
                                           `((cwd . ,(expand-file-name
                                                      temporary-file-directory))
                                             (label . "herdr-el-dispatch")
                                             (focus . t)))))))
    (unwind-protect
        (progn
          (herdr-state-resync)
          (should (herdr-state-workspace-directory (herdr-state-current)
                                                   workspace)))
      (herdr-rpc-call "workspace.close" `((workspace_id . ,workspace))))
    (sleep-for 1)
    (let ((after (mapcar (lambda (w) (alist-get 'workspace_id w))
                         (alist-get 'workspaces
                                    (alist-get 'snapshot
                                               (herdr-rpc-call
                                                "session.snapshot"))))))
      (should (equal before after)))))

(provide 'herdr-dispatch-live-test)
;;; herdr-dispatch-live-test.el ends here
