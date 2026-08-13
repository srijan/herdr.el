;;; herdr-state-live-test.el --- Tests for herdr event stream handling -*- lexical-binding: t; -*-

;;; Commentary:

;; NDJSON framing is where a stream client usually breaks: TCP does not
;; respect message boundaries, so a chunk may hold several events, half
;; an event, or both.  These drive the filter directly with hostile
;; chunking.

;;; Code:

(require 'ert)
(require 'herdr-test-helper)
(require 'herdr-state)

(defun herdr-state-live-test--proc ()
  "Return a throwaway process that can carry filter state."
  (make-pipe-process :name "herdr-test-pipe" :noquery t))

(defmacro herdr-state-live-test-with-capture (&rest body)
  "Run BODY capturing dispatched events into the list `events'."
  (declare (indent 0) (debug t))
  `(let* ((events nil)
          (herdr-state--current (herdr-state-empty))
          (herdr-state-change-hook
           (list (lambda (kind data) (push (cons kind data) events))))
          (proc (herdr-state-live-test--proc)))
     (unwind-protect (progn ,@body (setq events (nreverse events)))
       (delete-process proc))))

(ert-deftest herdr-state-filter-ignores-the-subscription-ack ()
  "The ack is a response, not an event; reducing against it is meaningless."
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter
                   proc "{\"id\":\"1\",\"result\":{\"type\":\"subscription_started\"}}\n"))))
    (should (null events))))

(ert-deftest herdr-state-filter-splits-two-events-in-one-chunk ()
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter
                   proc
                   (concat
                    "{\"event\":\"pane_focused\",\"data\":{\"pane_id\":\"w1:p1\"}}\n"
                    "{\"event\":\"pane_focused\",\"data\":{\"pane_id\":\"w1:p2\"}}\n")))))
    (should (= 2 (length events)))
    (should (equal "w1:p1" (alist-get 'pane_id (cdr (nth 0 events)))))
    (should (equal "w1:p2" (alist-get 'pane_id (cdr (nth 1 events)))))))

(ert-deftest herdr-state-filter-buffers-a-partial-line ()
  "A chunk that ends mid-event must produce nothing until its newline."
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter proc "{\"event\":\"pane_focu")
                  (should (null events))
                  (herdr-state--filter
                   proc "sed\",\"data\":{\"pane_id\":\"w1:p9\"}}\n"))))
    (should (= 1 (length events)))
    (should (equal "w1:p9" (alist-get 'pane_id (cdr (car events)))))))

(ert-deftest herdr-state-filter-handles-a-split-across-three-chunks ()
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter proc "{\"event\":\"pane_f")
                  (herdr-state--filter proc "ocused\",\"data\":{\"pane")
                  (herdr-state--filter proc "_id\":\"w1:p3\"}}\n"))))
    (should (= 1 (length events)))
    (should (equal "w1:p3" (alist-get 'pane_id (cdr (car events)))))))

(ert-deftest herdr-state-filter-survives-a-malformed-line ()
  "One bad line must not take down the stream."
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter
                   proc (concat "not json at all\n"
                                "{\"event\":\"pane_focused\",\"data\":{\"pane_id\":\"w1:p4\"}}\n")))))
    (should (= 1 (length events)))
    (should (equal "w1:p4" (alist-get 'pane_id (cdr (car events)))))))

(ert-deftest herdr-state-filter-updates-the-cache-as-it-dispatches ()
  (herdr-state-live-test-with-capture
    (herdr-state--filter
     proc (concat "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                  "{\"pane_id\":\"w1:p7\",\"agent\":\"codex\","
                  "\"agent_status\":\"working\"}}}\n"))
    (should (herdr-state-pane herdr-state--current "w1:p7"))
    (should (= 1 (length (herdr-state-agents herdr-state--current))))))

(ert-deftest herdr-state-pane-subscriptions-cover-every-pane ()
  "Connection B must name every pane, since these subscriptions are per-pane."
  (let ((herdr-state--current
         (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1")) ((pane_id . "w1:p2"))))))))
    (let ((subs (herdr-state--pane-subscriptions)))
      ;; A vector, so it serializes as a JSON array rather than an object.
      (should (vectorp subs))
      (should (= 2 (length subs)))
      (should (equal "pane.agent_status_changed" (alist-get 'type (aref subs 0))))
      (should (equal '("w1:p1" "w1:p2")
                     (mapcar (lambda (s) (alist-get 'pane_id s)) subs))))))

(ert-deftest herdr-state-start-signals-when-no-server ()
  "Starting without a server must fail cleanly and leave nothing running."
  (let ((herdr-socket-path "/tmp/herdr-test-definitely-absent.sock"))
    (herdr-state-stop)
    (should-error (herdr-state-start) :type 'herdr-error)
    (should-not (herdr-state-running-p))))

(ert-deftest herdr-state-start-hydrates-from-a-fake-server ()
  (herdr-test-with-server
      (lambda (req)
        (if (equal (alist-get 'method req) "session.snapshot")
            (cons (herdr-test-ok
                   req '((snapshot . ((focused_pane_id . "w1:p1")
                                      (panes . [((pane_id . "w1:p1")
                                                 (agent . "claude")
                                                 (agent_status . "idle"))])))))
                  nil)
          ;; events.subscribe: ack and hold the connection open.
          (cons (herdr-test-ok req '((type . "subscription_started"))) t)))
    (unwind-protect
        (progn
          (herdr-state-start)
          (should (herdr-state-running-p))
          (should (equal "w1:p1"
                         (herdr-state-focused-pane-id (herdr-state-current))))
          (should (= 1 (length (herdr-state-agents (herdr-state-current))))))
      (herdr-state-stop))))

(ert-deftest herdr-state-every-event-notifies-listeners ()
  "No event is swallowed, replayed ones included.

The hook used to be suppressed until the stream fell silent for 0.4s,
to absorb a replay believed to be about 150 events of history.  The
replay is one retained event per subscribed type — 8 in 4 ms across all
24 — while the live stream's median gap is 0.105s, so on a real
timeline that window held the hook for 54.3 seconds and swallowed 533
events.  Anything that reintroduces a suppression window fails here."
  (let* ((events nil)
         (herdr-state--current (herdr-state-empty))
         (herdr-state-change-hook
          (list (lambda (kind data) (push (cons kind data) events))))
         (proc (herdr-state-live-test--proc)))
    (unwind-protect
        (progn
          (herdr-state--filter
           proc (concat "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                        "{\"pane_id\":\"w1:p1\"}}}\n"
                        "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                        "{\"pane_id\":\"w1:p2\"}}}\n"
                        "{\"event\":\"pane_focused\",\"data\":"
                        "{\"pane_id\":\"w1:p2\"}}\n"))
          (should (= 2 (length (herdr-state-panes herdr-state--current))))
          (should (equal '("pane_created" "pane_created" "pane_focused")
                         (mapcar #'car (reverse events)))))
      (delete-process proc))))

(ert-deftest herdr-state-settle-reconciles-ghost-panes-away ()
  "Connecting must end with the pane set the server actually has.

`events.subscribe\\=' retains the last event of each subscribed type, so a
fresh subscription replays a `pane_created\\=' for whatever pane was made
last — a ghost, when that pane closed minutes ago.  The retained
`pane_closed\\=' folds it away only because `pane.created\\=' happens to be
listed before `pane.closed\\=' in `herdr-state-global-subscriptions\\=';
nothing in the protocol guarantees it.  So the settle after connecting
reconciles, and rebuilds connection B afterwards so its per-pane
subscriptions name the reconciled set rather than the ghost."
  (let (subscribed)
    (herdr-test-with-server
        (lambda (req)
          (pcase (alist-get 'method req)
            ("pane.list"
             (cons (herdr-test-ok req '((type . "pane_list")
                                        (panes . [((pane_id . "w1:p1")
                                                   (cwd . "/tmp"))])))
                   nil))
            ("events.subscribe"
             (setq subscribed (alist-get 'subscriptions (alist-get 'params req)))
             (cons (herdr-test-ok req '((type . "subscription_started"))) t))
            (_ (cons (herdr-test-ok req '((type . "ok"))) nil))))
      (let ((herdr-state--running t)
            (herdr-state--pane-process nil)
            (herdr-state--resubscribe-timer nil)
            (herdr-state--settle-timer nil)
            (herdr-state--current
             (herdr-state-from-snapshot
              '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))
                          ((pane_id . "w1:ghost"))))))))
        (unwind-protect
            (progn
              (herdr-state--settle)
              (should (equal '("w1:p1")
                             (herdr-state-pane-ids herdr-state--current)))
              (let ((deadline (+ (float-time) 5)))
                (while (and (null subscribed) (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (should (equal '("w1:p1")
                             (mapcar (lambda (s) (alist-get 'pane_id s))
                                     subscribed))))
          (herdr-state--close herdr-state--pane-process))))))

;;; What counts as a change to the pane set

(defun herdr-state-live-test--rebuilds-p (kind)
  "Return non-nil when KIND schedules a rebuild of connection B."
  (let ((herdr-state--resubscribe-timer nil))
    (unwind-protect
        (progn (herdr-state--note-pane-set-change kind nil)
               (and herdr-state--resubscribe-timer t))
      (when herdr-state--resubscribe-timer
        (cancel-timer herdr-state--resubscribe-timer)))))

(ert-deftest herdr-state-only-pane-lifecycle-rebuilds-connection-b ()
  "B subscribes per pane, so only adding or removing a pane can change it.

`pane_agent_detected' was on this list for a long time even though
`herdr-state--pane-subscriptions' names every pane rather than every
pane with an agent — so it could never alter the result, while every
agent start and stop paid for a teardown, a reopen and a
`session.snapshot'.  A rebuild has a gap in it; this one bought
nothing."
  (dolist (kind '("pane_created" "pane_closed" "pane_exited"))
    (should (equal (list kind t)
                   (list kind (herdr-state-live-test--rebuilds-p kind)))))
  (dolist (kind '("pane_agent_detected" "pane_updated" "pane_focused"
                  "resync"))
    (should (equal (list kind nil)
                   (list kind (herdr-state-live-test--rebuilds-p kind))))))

;;; Reconnecting after a dropped stream

(defun herdr-state-live-test--reconnect-server (record)
  "Return a responder for the reconnect tests, calling RECORD per method.

Answers `session.snapshot\\=' with a session whose labels all read
\"fresh\", so anything the cache still reports as \"stale\" was never
refreshed from it.  `pane.list\\=' agrees about the pane set, so a
reconcile alone cannot account for a fresh label."
  (lambda (req)
    (let ((method (alist-get 'method req)))
      (funcall record method)
      (pcase method
        ("session.snapshot"
         (cons (herdr-test-ok
                req '((snapshot . ((focused_pane_id . "w1:p1")
                                   (panes . [((pane_id . "w1:p1")
                                              (cwd . "/tmp"))])
                                   (tabs . [((tab_id . "w1:t1")
                                             (workspace_id . "w1")
                                             (label . "fresh"))])
                                   (workspaces . [((workspace_id . "w1")
                                                   (label . "fresh"))])))))
               nil))
        ("pane.list"
         (cons (herdr-test-ok req '((type . "pane_list")
                                    (panes . [((pane_id . "w1:p1")
                                               (cwd . "/tmp"))])))
               nil))
        ("events.subscribe"
         (cons (herdr-test-ok req '((type . "subscription_started"))) t))
        (_ (cons (herdr-test-ok req '((type . "ok"))) nil))))))

(defun herdr-state-live-test--stale-cache ()
  "Return a cache whose every label says \"stale\"."
  (herdr-state-from-snapshot
   '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))
     (tabs . (((tab_id . "w1:t1") (workspace_id . "w1") (label . "stale"))))
     (workspaces . (((workspace_id . "w1") (label . "stale")))))))

(defun herdr-state-live-test--label (accessor id-key id)
  "Return the label of the entry ACCESSOR holds whose ID-KEY is ID."
  (alist-get 'label
             (seq-find (lambda (item) (equal id (alist-get id-key item)))
                       (funcall accessor herdr-state--current))))

(ert-deftest herdr-state-reconnect-resyncs-tabs-and-workspaces-too ()
  "A reconnect must replace the whole cache, not just the panes.

Events missed during a disconnect cannot be replayed, and they are not
only pane events: a workspace renamed or a tab closed while the socket
was down is announced once and never again.  Reconciling repairs panes
alone — it is one `pane.list\\=' — so a reconnect that only reconciled
left the workspace and tab halves of the cache wrong for the rest of the
session, which is the never-converging cache this whole branch exists to
remove."
  (let (methods)
    (herdr-test-with-server
        (herdr-state-live-test--reconnect-server
         (lambda (method) (push method methods)))
      (let ((herdr-state--running t)
            (herdr-state-settle-delay 0.01)
            (herdr-state--global-process nil)
            (herdr-state--pane-process nil)
            (herdr-state--resubscribe-timer nil)
            (herdr-state--settle-timer nil)
            (herdr-state--reconnect-timer nil)
            (herdr-state--reconnect-delay nil)
            (herdr-state--current (herdr-state-live-test--stale-cache)))
        (unwind-protect
            (progn
              (herdr-state--reconnect)
              (let ((deadline (+ (float-time) 5)))
                (while (and herdr-state--settle-timer
                            (< (float-time) deadline))
                  (sit-for 0.02)))
              (should-not herdr-state--settle-timer)
              (should (member "session.snapshot" methods))
              (should (equal "fresh" (herdr-state-live-test--label
                                      #'herdr-state-workspaces
                                      'workspace_id "w1")))
              (should (equal "fresh" (herdr-state-live-test--label
                                      #'herdr-state-tabs 'tab_id "w1:t1"))))
          (herdr-state--close herdr-state--global-process)
          (herdr-state--close herdr-state--pane-process)
          (when herdr-state--settle-timer
            (cancel-timer herdr-state--settle-timer)))))))

(ert-deftest herdr-state-reconnect-announces-the-resync-once ()
  "Listeners hold their own view, so a wholesale cache replacement they
are not told about is the same bug one level up."
  (let (methods kinds)
    (herdr-test-with-server
        (herdr-state-live-test--reconnect-server
         (lambda (method) (push method methods)))
      (let* ((herdr-state--running t)
             (herdr-state--pane-process nil)
             (herdr-state--resubscribe-timer nil)
             (herdr-state--settle-timer nil)
             (herdr-state--current (herdr-state-live-test--stale-cache))
             (herdr-state-change-hook
              (list (lambda (kind _data) (push kind kinds)))))
        (unwind-protect
            (progn
              (herdr-state--settle t)
              (should (member "resync" kinds)))
          (herdr-state--close herdr-state--pane-process))))))

(ert-deftest herdr-state-settle-without-resync-does-not-snapshot ()
  "The start path snapshots immediately before subscribing, so its
settle has nothing to re-fetch — one `pane.list\\=' and no more."
  (let (methods)
    (herdr-test-with-server
        (herdr-state-live-test--reconnect-server
         (lambda (method) (push method methods)))
      (let ((herdr-state--running t)
            (herdr-state--pane-process nil)
            (herdr-state--resubscribe-timer nil)
            (herdr-state--settle-timer nil)
            (herdr-state--current (herdr-state-live-test--stale-cache)))
        (unwind-protect
            (progn
              (herdr-state--settle)
              (should-not (member "session.snapshot" methods))
              (should (member "pane.list" methods)))
          (herdr-state--close herdr-state--pane-process))))))

;;; Reconciling the pane set against the server

(defun herdr-state-live-test--pane-list-server (panes)
  "Return a responder answering `pane.list' with PANES."
  (lambda (req)
    (cons (herdr-test-ok req `((type . "pane_list") (panes . ,panes))) nil)))

(ert-deftest herdr-state-reconcile-drops-panes-the-server-no-longer-has ()
  "Ghost panes are the visible symptom of the replay race: a bursty
replay can end priming early, letting pane_created events for
long-closed panes land after the settling snapshot.  They then appear in
every picker and cannot be navigated to."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))
                        ((pane_id . "w1:ghost1"))
                        ((pane_id . "w1:ghost2"))))))))
      (should (herdr-state-reconcile-panes))
      (should (equal '("w1:p1") (herdr-state-pane-ids herdr-state--current))))))

(ert-deftest herdr-state-reconcile-adds-panes-the-cache-missed ()
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp"))
        ((pane_id . "w1:p2") (cwd . "/tmp") (agent . "claude"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))))))
      (should (herdr-state-reconcile-panes))
      (should (equal '("w1:p1" "w1:p2")
                     (herdr-state-pane-ids herdr-state--current)))
      (should (= 1 (length (herdr-state-agents herdr-state--current)))))))

(ert-deftest herdr-state-reconcile-picks-up-directory-changes ()
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/usr/local"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))))))
      (should (herdr-state-reconcile-panes))
      (should (equal "/usr/local"
                     (alist-get 'cwd (herdr-state-pane herdr-state--current
                                                       "w1:p1")))))))

(ert-deftest herdr-state-reconcile-reports-no-change-when-in-sync ()
  "The poll runs every few seconds; it must not fire the change hook
for nothing."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))))))
      (should-not (herdr-state-reconcile-panes)))))

(ert-deftest herdr-state-reconcile-leaves-the-cache-alone-when-unreachable ()
  "A failed poll must not empty the cache."
  (let ((herdr-socket-path "/tmp/herdr-test-definitely-absent.sock")
        (herdr-state--current
         (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1"))))))))
    (should-not (herdr-state-reconcile-panes))
    (should (equal '("w1:p1") (herdr-state-pane-ids herdr-state--current)))))

(ert-deftest herdr-state-reconcile-refreshes-a-changed-agent-label ()
  "An adopted shell herdr has relabelled must not keep its old label.
Detection runs independently of the reported agent and takes the pane
over a few seconds after a real agent starts in it, so the label moves
without any event we act on.  Refreshing only cwd left the cache
reporting `shell' indefinitely."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (agent . "claude") (agent_status . "working")
         (cwd . "/tmp"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (agent . "shell")
                         (agent_status . "idle") (cwd . "/tmp"))))))))
      (should (herdr-state-reconcile-panes))
      (let ((pane (herdr-state-pane herdr-state--current "w1:p1")))
        (should (equal "claude" (alist-get 'agent pane)))
        (should (equal "working" (alist-get 'agent_status pane))))
      (should (= 1 (length (herdr-state-agents herdr-state--current)))))))

(ert-deftest herdr-state-reconcile-ignores-a-title-only-change ()
  "The terminal title is the most volatile field a pane has.
Claude animates a spinner and a second counter inside it, so it differs
on essentially every poll while an agent works — 662 of 662
`pane_updated' events in one measured window.  Treating that as
significant made every poll replace every pane record and re-run the
directory sync.  Titles arrive on the event stream regardless."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp")
         (terminal_title_stripped . "* Herding (12s)"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp")
                         (terminal_title_stripped . "- Herding (11s)"))))))))
      (should-not (herdr-state-reconcile-panes)))))

(ert-deftest herdr-state-pane-updated-still-carries-the-title-in ()
  "The other half of leaving the title out of the reconcile poll: the
event stream carries the whole PaneInfo, so the dashboard still sees a
new title as soon as herdr publishes one."
  (let ((next (herdr-state-reduce
               (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (cwd . "/tmp")
                             (terminal_title_stripped . "old"))))))
               "pane_updated"
               '((pane . ((pane_id . "w1:p1") (cwd . "/tmp")
                          (terminal_title_stripped . "new")))))))
    (should (equal "new" (alist-get 'terminal_title_stripped
                                    (herdr-state-pane next "w1:p1"))))))

(ert-deftest herdr-state-reconcile-ignores-volatile-fields ()
  "Revision and scroll churn constantly; reacting to them would make
every poll report a change and refresh every consumer."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp") (revision . 99)
         (scroll . ((offset_from_bottom . 5))))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp") (revision . 1))))))))
      (should-not (herdr-state-reconcile-panes)))))

(provide 'herdr-state-live-test)
;;; herdr-state-live-test.el ends here
