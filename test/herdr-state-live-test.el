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

(ert-deftest herdr-state-priming-suppresses-the-change-hook ()
  "Replayed events must fold into the cache without notifying listeners.
herdr replays history on subscribe — 54 events on an idle server here —
so an unsuppressed hook would fire once per replayed event."
  (let* ((events nil)
         (herdr-state--current (herdr-state-empty))
         (herdr-state--priming 'settle)
         (herdr-state--prime-timer nil)
         (herdr-state-change-hook
          (list (lambda (kind data) (push (cons kind data) events))))
         (proc (herdr-state-live-test--proc)))
    (unwind-protect
        (progn
          (herdr-state--filter
           proc (concat "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                        "{\"pane_id\":\"w1:p1\"}}}\n"
                        "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                        "{\"pane_id\":\"w1:p2\"}}}\n"))
          ;; Folded in...
          (should (= 2 (length (herdr-state-panes herdr-state--current))))
          ;; ...but silently.
          (should (null events)))
      (when herdr-state--prime-timer (cancel-timer herdr-state--prime-timer))
      (delete-process proc))))

(ert-deftest herdr-state-not-priming-notifies-per-event ()
  (let* ((events nil)
         (herdr-state--current (herdr-state-empty))
         (herdr-state--priming nil)
         (herdr-state-change-hook
          (list (lambda (kind data) (push (cons kind data) events))))
         (proc (herdr-state-live-test--proc)))
    (unwind-protect
        (progn
          (herdr-state--filter
           proc "{\"event\":\"pane_created\",\"data\":{\"pane\":{\"pane_id\":\"w1:p1\"}}}\n")
          (should (= 1 (length events))))
      (delete-process proc))))

(provide 'herdr-state-live-test)
;;; herdr-state-live-test.el ends here
