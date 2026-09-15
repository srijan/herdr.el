;;; herdr-two-servers-test.el --- Two servers, colliding ids -*- lexical-binding: t; -*-

;;; Commentary:

;; The done-condition for making the connection a value: two servers
;; with deliberately colliding ids, different records and separately
;; recorded requests, behaving as two servers throughout.
;;
;; Two connections to one server is the tempting cheap version and it
;; tests nothing here.  Both would see the same records and the same
;; focus, so identical data would hide mis-routing entirely, and
;; attaching twice to one pane would hit herdr's own exclusivity rather
;; than anything this package built.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-connection)
(require 'herdr-state)
(require 'herdr-term)
(require 'herdr-dispatch)
(require 'herdr-test-helper)

(defun herdr-two-servers-test--responder (label requests)
  "Return a responder for the server called LABEL, recording into REQUESTS.

Every record it answers with carries LABEL, and every id it uses
collides with the other server's on purpose: `w1', `w1:p1'.  A reply
that reaches the wrong cache is then visible as a label, not as an
absence."
  (lambda (request)
    (let ((method (alist-get 'method request)))
      (push method (symbol-value requests))
      (pcase method
        ("session.snapshot"
         (cons (herdr-test-ok
                request
                `((snapshot . ((focused_pane_id . "w1:p1")
                               (panes . [((pane_id . "w1:p1")
                                          (workspace_id . "w1")
                                          (agent . ,label)
                                          (agent_status . "working")
                                          (terminal_id . ,(concat "t-" label))
                                          (cwd . ,(concat "/tmp/" label)))])
                               (workspaces . [((workspace_id . "w1")
                                               (label . ,label))])))))
               nil))
        ("pane.list"
         (cons (herdr-test-ok
                request
                `((panes . [((pane_id . "w1:p1") (workspace_id . "w1")
                             (agent . ,label)
                             (terminal_id . ,(concat "t-" label))
                             (cwd . ,(concat "/tmp/" label)))])))
               nil))
        ("workspace.list"
         (cons (herdr-test-ok
                request
                `((workspaces . [((workspace_id . "w1") (label . ,label))])))
               nil))
        ("worktree.list"
         (cons (herdr-test-ok
                request
                `((worktrees . [((path . "/tmp/repo/")
                                 (branch . ,label)
                                 (is_linked_worktree . t))])))
               nil))
        ("events.subscribe"
         (cons (herdr-test-ok request '((type . "subscription_started"))) t))
        (_ (cons (herdr-test-ok request '((type . "ok"))) nil))))))

(defvar herdr-two-servers-test--one-requests nil)
(defvar herdr-two-servers-test--two-requests nil)

(defmacro herdr-two-servers-test--with (&rest body)
  "Run BODY with two fake servers and a connection to each.
Binds ONE and TWO to the connections, and ONE-REQUESTS and TWO-REQUESTS
to the methods each server was actually asked."
  (declare (indent 0) (debug t))
  `(let* ((one-path (herdr-test-socket-path))
          (two-path (herdr-test-socket-path))
          (herdr-two-servers-test--one-requests nil)
          (herdr-two-servers-test--two-requests nil)
          (herdr-state-change-functions nil)
          (herdr-term--buffers nil)
          (herdr-state-repair-interval nil)
          (one-server nil) (two-server nil)
          (one (herdr-connection--make :name "one" :socket-path one-path))
          (two (herdr-connection--make :name "two" :socket-path two-path))
          (herdr-connections (list (cons "one" one) (cons "two" two))))
     (unwind-protect
         (progn
           (setq one-server
                 (herdr-test-start-server
                  one-path (herdr-two-servers-test--responder
                            "one" 'herdr-two-servers-test--one-requests))
                 two-server
                 (herdr-test-start-server
                  two-path (herdr-two-servers-test--responder
                            "two" 'herdr-two-servers-test--two-requests)))
           (cl-flet ((one-requests ()
                       (reverse herdr-two-servers-test--one-requests))
                     (two-requests ()
                       (reverse herdr-two-servers-test--two-requests)))
             (ignore #'one-requests #'two-requests)
             ,@body))
       (dolist (connection (list one two))
         (ignore-errors (herdr-state-stop connection)))
       (dolist (server (list one-server two-server))
         (when server (ignore-errors (delete-process server))))
       (dolist (path (list one-path two-path))
         (ignore-errors (delete-file path))))))

(ert-deftest herdr-two-servers-hydrate-into-separate-caches ()
  "Both servers answer for `w1' and `w1:p1'.  One cache would hold
whichever replied second, and nothing about the ids would say so."
  (herdr-two-servers-test--with
    (herdr-state-start one)
    (herdr-state-start two)
    (should (equal '("w1:p1") (herdr-state-pane-ids (herdr-state-current one))))
    (should (equal '("w1:p1") (herdr-state-pane-ids (herdr-state-current two))))
    ;; The ids collide; the records do not.
    (should (equal "one" (herdr-pane-agent
                          (herdr-state-pane (herdr-state-current one) "w1:p1"))))
    (should (equal "two" (herdr-pane-agent
                          (herdr-state-pane (herdr-state-current two) "w1:p1"))))
    (should (equal "one" (herdr-workspace-label
                          (herdr-state-workspace (herdr-state-current one) "w1"))))
    (should (equal "two" (herdr-workspace-label
                          (herdr-state-workspace (herdr-state-current two) "w1"))))))

(ert-deftest herdr-two-servers-are-asked-separately ()
  "Each server sees only the requests meant for it.  A single recorded
list would pass whatever the routing did."
  (herdr-two-servers-test--with
    (herdr-state-start one)
    (should (member "session.snapshot" (one-requests)))
    (should-not (two-requests))
    (herdr-state-repair one)
    (should (herdr-test-wait-for
             (lambda () (member "workspace.list" (one-requests)))))
    (should-not (two-requests))
    (herdr-state-start two)
    (should (member "session.snapshot" (two-requests)))))

(ert-deftest herdr-two-servers-repair-into-their-own-caches ()
  "The repair is asynchronous and both are in flight at once, which is
where a shared cache or a resolved-late connection would show."
  (herdr-two-servers-test--with
    (herdr-state-start one)
    (herdr-state-start two)
    ;; Something else wrote into both caches; the repair has to correct
    ;; each from its own server.
    (dolist (connection (list one two))
      (setf (herdr-connection-cache connection)
            (herdr-state-from-snapshot
             '((panes . (((pane_id . "w1:p1") (agent . "wrong"))
                         ((pane_id . "w1:ghost") (agent . "wrong"))))))))
    (should (herdr-state-repair one))
    (should (herdr-state-repair two))
    (should (herdr-test-wait-for
             (lambda ()
               (and (equal "one" (herdr-pane-agent
                                  (herdr-state-pane
                                   (herdr-state-current one) "w1:p1")))
                    (equal "two" (herdr-pane-agent
                                  (herdr-state-pane
                                   (herdr-state-current two) "w1:p1")))))))
    ;; And the ghost is gone from both, each by its own answer.
    (should (equal '("w1:p1") (herdr-state-pane-ids (herdr-state-current one))))
    (should (equal '("w1:p1") (herdr-state-pane-ids (herdr-state-current two))))))

(ert-deftest herdr-two-servers-keep-separate-worktree-listings ()
  "Both listings are keyed `w1' and both describe `/tmp/repo/'.  One
cache would resolve a row on either server to the same record."
  (herdr-two-servers-test--with
    (herdr-state-start one)
    (herdr-state-start two)
    (herdr-dispatch--fetch-worktrees one "w1" "/tmp/one")
    (herdr-dispatch--fetch-worktrees two "w1" "/tmp/two")
    (should (herdr-test-wait-for
             (lambda ()
               (and (herdr-dispatch--worktrees-answered-p one "w1")
                    (herdr-dispatch--worktrees-answered-p two "w1")))))
    (should (equal "one" (herdr-worktree-branch
                          (herdr-dispatch--worktree-record one "/tmp/repo/"))))
    (should (equal "two" (herdr-worktree-branch
                          (herdr-dispatch--worktree-record two "/tmp/repo/"))))))

(ert-deftest herdr-two-servers-stopping-one-leaves-the-other-whole ()
  "Stopping a connection empties its cache, cancels its timers and reaps
its buffers.  Every one of those used to be package-wide."
  (herdr-two-servers-test--with
    (herdr-state-start one)
    (herdr-state-start two)
    (let ((mine (generate-new-buffer " *one*"))
          (theirs (generate-new-buffer " *two*")))
      (unwind-protect
          (progn
            (setq herdr-term--buffers
                  (list (cons (herdr-term--key one "w1:p1") mine)
                        (cons (herdr-term--key two "w1:p1") theirs)))
            (add-hook 'herdr-state-change-functions
                      #'herdr-term--on-state-change)
            (herdr-state-stop one)
            (herdr-term-teardown one)
            (should-not (herdr-connection-running one))
            (should-not (herdr-state-pane-ids (herdr-state-current one)))
            (should-not (buffer-live-p mine))
            ;; The other is untouched: stream, cache and buffer.
            (should (herdr-connection-running two))
            (should (equal '("w1:p1")
                           (herdr-state-pane-ids (herdr-state-current two))))
            (should (buffer-live-p theirs))
            (should (eq theirs (herdr-term-buffer-for-pane two "w1:p1"))))
        (dolist (buffer (list mine theirs))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest herdr-two-servers-a-command-reaches-the-one-it-was-given ()
  "The whole point of the resolver: an action carries its connection from
the point it started, and a buffer belonging to one server answers for
that server however the registry is ordered."
  (herdr-two-servers-test--with
    (let ((buffer (generate-new-buffer " *pane*")))
      (unwind-protect
          (progn
            (setq herdr-term--buffers
                  (list (cons (herdr-term--key two "w1:p1") buffer)))
            (with-current-buffer buffer
              (setq herdr-buffer-connection two)
              ;; `one' is first in the registry, so this is not the
              ;; default answer.
              (should (eq two (herdr-current-connection)))
              (herdr-rpc-call (herdr-current-connection) "ping"))
            (should (member "ping" (two-requests)))
            (should-not (member "ping" (one-requests))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'herdr-two-servers-test)
;;; herdr-two-servers-test.el ends here
