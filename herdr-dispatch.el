;;; herdr-dispatch.el --- The herdr dispatcher buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (transient "0.4.0") (magit-section "3.3"))

;;; Commentary:

;; `*herdr-agents*': one buffer showing the whole session as a foldable
;; workspace/tab/pane tree, and the place every command is reachable
;; from.
;;
;; The tree itself is data, built by `herdr-tree'.  This file only
;; renders it, resolves the object under point, and hands that object to
;; the commands in `herdr-cmd' — which already take explicit ids, so no
;; command logic is duplicated here.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'transient)
(require 'magit-section)
(require 'herdr-tree)
(require 'herdr-state)
(require 'herdr-rpc)
(require 'herdr-cmd)

;; `herdr-transient' lives in herdr-transient.el, which autoloads
;; `herdr-agents' (defined below).  Requiring it here rather than
;; autoloading would close that into a load cycle, so `?' reaches it the
;; same way `herdr-agents' reaches back.
(declare-function herdr-transient "herdr-transient" ())
(autoload 'herdr-transient "herdr-transient" nil t)

(defcustom herdr-dispatch-buffer-name "*herdr-agents*"
  "Name of the dispatcher buffer."
  :type 'string
  :group 'herdr)

(defcustom herdr-dispatch-refresh-debounce 0.2
  "Seconds to coalesce dispatcher redraws triggered by events.
Events arrive in bursts — a reconcile folds many pane changes back to
back, and a subscribe replays ring history — so redrawing per event
meant erasing and rebuilding the buffer many times for one visible
change.  (When `pane.updated\\=' was still subscribed, a single working
agent kept that up at ten redraws a second indefinitely.)  Short enough
that the dashboard still reads as live.  Only the hook is debounced:
\\[herdr-dispatch-refresh] redraws immediately."
  :type 'number
  :group 'herdr)

(defvar herdr-dispatch--worktrees nil
  "Alist of (WORKSPACE-ID . LIST-OF-WORKTREEINFO) for answered workspaces.

Presence of the entry, not the truth of its value, is what records that a
workspace has been answered: a repository with no worktrees at all caches
as (WORKSPACE-ID . nil) and must not be asked again.  Every guard over
this alist therefore uses `assoc\\=', never `alist-get\\='.

Filled asynchronously as the dashboard renders; see
`herdr-dispatch--request-worktrees\\='.")

(defvar herdr-dispatch--worktrees-pending nil
  "Workspace ids whose `worktree.list\\=' request has not been answered yet.

Nothing reaches `herdr-dispatch--worktrees\\=' until a reply lands, so the
cache alone cannot stop the next refresh — and the dashboard refreshes
several times a second under load — from asking the same question again.
This is the guard that does.")

(defvar herdr-dispatch--worktrees-unanswered nil
  "Alist of (WORKSPACE-ID . REASON) for entries cached without an answer.

A request that came back an error, and a workspace with no directory to
address a request to, both cache as (WORKSPACE-ID . nil) so that neither
is retried on every single redraw.  Remembering which entries are
placeholders rather than answers is what lets \\[herdr-dispatch-refresh]
retry exactly those, and REASON — `error\\=' or `no-directory\\=' — is what
lets one of them retry sooner: see
`herdr-dispatch--request-worktrees\\='.")

(defvar herdr-dispatch--worktrees-generation 0
  "Counter bumped every time the worktree cache is invalidated.
Requests carry the generation they were issued under; see
`herdr-dispatch--worktrees-received\\=' for what that is worth.")

(defvar herdr-dispatch--refresh-timer nil
  "Timer for the pending debounced redraw, or nil when none is pending.")

(defvar-local herdr-dispatch--rendered-tree nil
  "The tree last drawn into this buffer, as `herdr-tree-build' returned it.")

(defvar-local herdr-dispatch--rendered-header nil
  "The header line last drawn into this buffer.
Nil means the buffer has never been drawn, which is how a first refresh
tells itself apart from a redraw of an empty session.")

(defvar herdr-dispatch-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map "g" #'herdr-dispatch-refresh)
    (define-key map "q" #'quit-window)
    (define-key map (kbd "RET") #'herdr-dispatch-visit)
    (define-key map "p" #'herdr-dispatch-prompt)
    (define-key map "r" #'herdr-dispatch-read)
    (define-key map "f" #'herdr-dispatch-focus)
    (define-key map "R" #'herdr-dispatch-rename)
    (define-key map "k" #'herdr-dispatch-close)
    ;; TAB is `magit-section-toggle' itself.  It was a command of ours
    ;; for as long as unfolding a workspace was what fetched its
    ;; worktrees, and that arrangement was wrong twice over: it put a
    ;; blocking `worktree.list' on a keystroke, and the toggle collapsed
    ;; the workspace before the fetch drew into it, so TAB on a workspace
    ;; line hid the very worktrees it had just fetched.  They appeared
    ;; only when TAB was pressed on an agent line, where a leaf section
    ;; makes the toggle a no-op — which is how the bug was reported.
    ;; `herdr-dispatch--request-worktrees' fetches on render now, leaving
    ;; the toggle nothing of ours to do.
    ;;
    ;; If folding misbehaves here again, the cause is not this binding.
    ;; The reported "cannot fold after unfolding" was
    ;; `herdr-dispatch--refresh-hook' redrawing synchronously out of the
    ;; event stream's process filter, landing an `erase-buffer' in the
    ;; middle of a command roughly ten times a second; the debounce and
    ;; the unchanged-tree skip in `herdr-dispatch-refresh' are what
    ;; address that.  Reach for those first.
    (define-key map (kbd "TAB") #'magit-section-toggle)
    (define-key map "c" #'herdr-dispatch-create)
    (define-key map "w" #'herdr-dispatch-create-workspace)
    (define-key map "n" #'herdr-dispatch-create-pane)
    (define-key map "%" #'herdr-dispatch-create-worktree)
    (define-key map "?" #'herdr-transient)
    map)
  "Keymap for `herdr-dispatch-mode'.
Lowercase letters are the read-only verbs; each acts on whatever the
line under point names, so no key needs a target of its own.")

(defcustom herdr-dispatch-fold-indicators nil
  "Value `magit-section-visibility-indicators\\=' takes in the dispatcher.
Nil, the default, picks a pair per frame; see
`herdr-dispatch--fold-indicators\\='.

The same margin characters for graphical and terminal frames, which is
neither half of the magit default.  That default is
`(magit-fringe-bitmap> . magit-fringe-bitmapv)\\=' in a graphical frame —
an arrow in the left fringe, which several themes render at such low
contrast that it reads as nothing at all, and which is off past the
window edge rather than beside the text it describes — and an ellipsis
appended to collapsed headings in a terminal frame, which marks the
collapsed sections and leaves the expandable ones unmarked.  So on the
default the two frame types disagree about what a foldable line even
looks like, and neither answer is legible.

A character indicator is drawn in the left margin instead, which
terminal frames have and fringes they do not, so both frame types show
the same `▸\\=' beside a collapsed heading and `▾\\=' beside an expanded
one.  The margin has to be wide enough to hold it: see
`herdr-dispatch-mode\\='.  Car before cdr because that is the order
`magit-section-maybe-update-visibility-indicator\\=' reads them in —
the car is what a hidden section gets."
  :type '(choice (const :tag "Choose a pair for the frame" nil)
                 (repeat (cons character character)))
  :group 'herdr)

(defun herdr-dispatch--fold-indicators ()
  "Return the fold indicators to use, honouring the user\\='s setting.

Falls back to arrows, or to ASCII where the arrows cannot be drawn.
That question is asked here, from `herdr-dispatch-mode\\=', rather than
once at load: under `emacs --daemon\\=' the library is loaded before any
frame exists, so a load-time `char-displayable-p\\=' is answered against
no display at all and the ASCII fallback is then frozen for the life of
the session.  Asking on mode entry answers against a frame the user
actually has.  A daemon serving a graphical and a terminal frame at once
still gets one answer per dashboard buffer, which is the best a
buffer-local value can do."
  (or herdr-dispatch-fold-indicators
      (let ((pair (if (char-displayable-p ?▾) '(?▸ . ?▾) '(?> . ?v))))
        (list pair pair))))

(define-derived-mode herdr-dispatch-mode magit-section-mode "herdr"
  "Major mode for the herdr dispatcher."
  (setq-local revert-buffer-function
              (lambda (&rest _) (herdr-dispatch-refresh t)))
  (setq-local magit-section-visibility-indicators
              (herdr-dispatch--fold-indicators))
  ;; Two columns: one for the indicator, one of air between it and the
  ;; text.  A margin of zero width silently drops margin overlays, which
  ;; would leave the indicators configured and invisible.
  (setq-local left-margin-width 2)
  ;; `set-window-buffer' picks the width up when the buffer is next
  ;; displayed, which covers opening the dashboard.  Windows already
  ;; showing this buffer — the mode being re-run, or reverted — keep the
  ;; margins they were given, so they are told directly.  The right margin
  ;; is passed through at whatever the buffer already had, since this mode
  ;; has no use for one and setting it to nil would discard the user's.
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-margins window left-margin-width right-margin-width)))

(defun herdr-dispatch--heading (line)
  "Return LINE with `magit-section-heading\\=' on its unfaced characters.

`magit-insert-heading\\=' faces the whole string it is given, but only
when no part of it is faced already: hand it a line carrying one
propertised field and it inserts every character unchanged, so a single
dimmed directory would cost the heading its heading face entirely.
Filling in the gaps first makes the two compose — the fields herdr-tree
faced keep their faces, and everything else reads as a heading.

Both `face\\=' and `font-lock-face\\=', for the reason given in
`herdr-tree--faced\\=': `face\\=' does not survive the first fontification
of the line, and `font-lock-face\\=' renders as nothing while
`font-lock-mode\\=' is off.  Writing only one of them made the whole
restyle invisible, once each way round.

The gaps are found by scanning `font-lock-face\\=' alone, and that is
safe only because the two properties are written together everywhere:
`herdr-tree--faced\\=' sets both or neither, so the boundaries either
property reports are the same boundaries.  Scanning the wrong one used
to matter — over a line faced with `font-lock-face\\=' only, a scan for
`face\\=' finds no fields at all and paints the heading face straight
over every one of them.  If a field ever carries just one property, this
scan is where that shows up."
  (let ((line (copy-sequence line))
        (start 0)
        (length (length line)))
    (while (< start length)
      (let ((end (or (next-single-property-change start 'font-lock-face line)
                     length)))
        (unless (get-text-property start 'font-lock-face line)
          (put-text-property start end
                             'font-lock-face 'magit-section-heading line)
          (put-text-property start end 'face 'magit-section-heading line))
        (setq start end)))
    line))

(defun herdr-dispatch--indent (line depth)
  "Return LINE indented two columns per DEPTH."
  (concat (make-string (* 2 depth) ?\s) line))

(defun herdr-dispatch--insert-container (line depth)
  "Insert LINE at DEPTH as the heading of the section being inserted.

Containers — workspaces, tabs, the worktrees group — are the only nodes
that get a heading.  A heading is what magit-section makes foldable and
what carries the `magit-section-heading\\=' face, so making every node one
spent both on nothing: the face said \"heading\" on every line in the
buffer and therefore said nothing, and the fold indicator appeared
beside leaves that have nothing to fold."
  (magit-insert-heading (herdr-dispatch--heading
                         (herdr-dispatch--indent line depth))))

(defun herdr-dispatch--insert-leaf (line depth)
  "Insert LINE at DEPTH as the body of the section being inserted.

Plainly, without `magit-insert-heading\\=': a pane row and a worktree row
are the content of the section above them, and it is the contrast with
that section\\='s heading that makes the tree read as a tree.  The section
itself is still created around this line, with its own type and value,
because every verb resolves the object under point by walking up from
`magit-current-section\\=' — a leaf folded into its parent\\='s section would
answer `RET\\=', `k\\=' and `R\\=' with its parent."
  (insert (herdr-dispatch--indent line depth) ?\n))

(defun herdr-dispatch--apply-fold (section)
  "Give SECTION the appearance its `hidden\\=' slot already claims.
Returns SECTION, so that it can wrap the `magit-insert-section\\=' that
produced it.

`magit-insert-section\\=' restores that slot from
`magit-section-visibility-cache\\=', but nothing acts on it: the
invisibility overlay and the fold indicator are written by
`magit-section-hide\\=' and `magit-section-show\\=', and a redraw calls
neither.  So a folded workspace came back from every redraw with its
panes on screen and its slot still claiming it was folded, which made
the next \\[magit-section-toggle] on it appear to do nothing — it hid a
section the buffer had already forgotten was open.  Adding the fold
indicator without this would have made that visible rather than fixed:
a `▸\\=' beside a heading whose children are plainly listed under it.

Magit itself does not need this because its inserters defer hidden
bodies through `magit-insert-section-body\\='.  That is not available
here: a body that is never inserted has no sections in it, and
`herdr-dispatch--position-restore\\=' has to find the section point was in
whether or not its parent is folded."
  (if (oref section hidden)
      (magit-section-hide section)
    (magit-section-maybe-update-visibility-indicator section))
  section)

(defun herdr-dispatch--insert-nodes (nodes &optional depth)
  "Insert NODES, each (TYPE VALUE LINE CHILDREN), as magit sections.

DEPTH is the nesting level, defaulting to 0.  Each line is prefixed with
two spaces per DEPTH, so the hierarchy is visible on screen instead of
every line beginning at column 0 regardless of nesting — every pane
indents exactly one level under its workspace, with no tab level to add
a second.

Top-level nodes are separated by a blank line, the way magit separates
the sections of a status buffer.  It goes between them rather than after
each, so the buffer does not end in one, and outside the sections rather
than inside, so folding a workspace does not swallow the gap that sets
it apart from the next.

`magit-insert-section\\=' takes its type as an unevaluated symbol, so the
six types are spelled out rather than passed through.  A runtime `eval\\='
would collapse these into one branch; six explicit branches byte-compile
and do not need defending."
  (let ((depth (or depth 0))
        (separate nil))
    (dolist (node nodes)
      (let ((value (nth 1 node))
            (line (nth 2 node))
            (children (nth 3 node)))
        (when (and separate (= depth 0)) (insert ?\n))
        (setq separate t)
        (pcase (nth 0 node)
          ('herdr-workspace
           (herdr-dispatch--apply-fold
            (magit-insert-section (herdr-workspace value)
              (herdr-dispatch--insert-container line depth)
              (herdr-dispatch--insert-nodes children (1+ depth)))))
          ('herdr-pane
           (magit-insert-section (herdr-pane value)
             (herdr-dispatch--insert-leaf line depth)
             (herdr-dispatch--insert-nodes children (1+ depth))))
          ('herdr-panes
           (herdr-dispatch--apply-fold
            (magit-insert-section (herdr-panes value)
              (herdr-dispatch--insert-container line depth)
              (herdr-dispatch--insert-nodes children (1+ depth)))))
          ('herdr-worktree
           (magit-insert-section (herdr-worktree value)
             (herdr-dispatch--insert-leaf line depth)
             (herdr-dispatch--insert-nodes children (1+ depth))))
          ('herdr-known-project
           ;; A heading when it owns rows, a leaf when it owns none.
           ;; The rows used to hang under a `worktrees (N)' heading,
           ;; which was the foldable thing; hanging them off the project
           ;; row directly left a repository of sixteen checkouts as
           ;; sixteen rows with nothing to collapse them.  Still a leaf
           ;; when it has no children, because a fold indicator beside
           ;; something with nothing to fold is what
           ;; `herdr-dispatch--insert-container' exists to avoid.
           (herdr-dispatch--apply-fold
            (magit-insert-section (herdr-known-project value)
              (if children
                  (herdr-dispatch--insert-container line depth)
                (herdr-dispatch--insert-leaf line depth))
              (herdr-dispatch--insert-nodes children (1+ depth)))))
          ('herdr-known-projects
           (herdr-dispatch--apply-fold
            (magit-insert-section (herdr-known-projects value)
              (herdr-dispatch--insert-container line depth)
              (herdr-dispatch--insert-nodes children (1+ depth))))))))))

;;; The object at point

(defun herdr-dispatch--value-at-point (type)
  "Return the value of the nearest enclosing section of TYPE, or nil.
Walks up rather than down: a verb invoked on a pane line inside a
workspace should reach the workspace too."
  (let ((section (magit-current-section))
        (found nil))
    (while (and section (not found))
      (when (eq type (oref section type))
        (setq found (oref section value)))
      (setq section (oref section parent)))
    found))

(defun herdr-dispatch--type-at-point (type)
  "Return the value of the section at point when it is of TYPE, or nil.

Deliberately does not walk up, and that is the whole difference from
`herdr-dispatch--value-at-point\\='.  A heading is acted on only when
point is on the heading itself; an ancestor heading is something the row
under point sits inside, not the thing the verb was aimed at.

Every heading in this buffer is an ancestor of the rows a verb is
normally aimed at, and the heading arms sit above the pane and workspace
arms in each `cond\\='.  Walking up therefore made a heading swallow its
own children: \\[herdr-dispatch-close] on an agent answered \"a
workspace\\='s main group cannot be closed\" and touched nothing, and each
of the other three verbs refused the same rows in its own words.

The action arms still walk up, and should: a verb on a pane row reaching
the workspace that pane belongs to is what `herdr-dispatch--value-at-point\\='
exists for.  Only the refusals are aimed at point itself, which is what
they meant all along."
  (when-let* ((section (magit-current-section))
              ((eq type (oref section type))))
    (oref section value)))

(defun herdr-dispatch--require (type what)
  "Return the nearest enclosing TYPE value, or signal that WHAT is needed."
  (or (herdr-dispatch--value-at-point type)
      (user-error "herdr: point is not on %s" what)))

(defun herdr-dispatch--protect (fn)
  "Call FN, reporting a `herdr-error\\=' rather than letting it escape.

A stale cache is the usual cause — the pane closed while you were
looking at it — so `not_found\\=' reconciles and redraws before reporting.
Seeing a correct tree alongside the message is the difference between
\"that pane is gone\" and an opaque failure."
  (condition-case err
      (funcall fn)
    (herdr-error
     (let ((code (herdr-error-code err)))
       (when (equal code "not_found")
         (herdr-state-reconcile-panes)
         (herdr-dispatch-refresh))
       (message "herdr: %s%s" (herdr-error-message err)
                (if (equal code "no_server")
                    " (M-x herdr-start)"
                  (format " [%s]" code)))))))

(defmacro herdr-dispatch-defverb (name args docstring &rest body)
  "Define NAME as an interactive command taking ARGS, running BODY.
BODY is wrapped in `herdr-dispatch--protect\\=', so a server error is
reported rather than raised.  DOCSTRING documents the command."
  (declare (indent 3) (doc-string 3))
  `(defun ,name ,args
     ,docstring
     (interactive)
     (herdr-dispatch--protect (lambda () ,@body))))

;;; Worktrees

(defun herdr-dispatch--forget-worktrees ()
  "Drop everything known about worktrees, replies still in flight included.

Bumping the generation is what abandons those replies, and it is the
half that is easy to leave out.  There are two ways to leave it out and
they fail differently.  Clearing `herdr-dispatch--worktrees-pending\\='
without a generation at all lets a listing that was already on the wire
land afterwards and write back the very cache entry the invalidation had
just removed — the dashboard then shows a listing the server has already
said is stale, and stops asking.  Guarding only the cache write, while
clearing the pending marker unconditionally, trades that for the
opposite failure: by then the marker belongs to the refetch that
replaced this request, so clearing it leaves the refetch unguarded and
the next refresh issues a third request for the same workspace.  Dropping
the reply whole is what avoids both."
  (setq herdr-dispatch--worktrees nil
        herdr-dispatch--worktrees-pending nil
        herdr-dispatch--worktrees-unanswered nil
        herdr-dispatch--worktrees-generation
        (1+ herdr-dispatch--worktrees-generation)))

(defun herdr-dispatch--forget-one-worktrees (workspace-id)
  "Drop what is cached for WORKSPACE-ID, so that it is asked again.
Only the placeholders are ever dropped this way; an answer stands until
the whole cache is invalidated."
  (setq herdr-dispatch--worktrees
        (assoc-delete-all workspace-id herdr-dispatch--worktrees)
        herdr-dispatch--worktrees-unanswered
        (assoc-delete-all workspace-id herdr-dispatch--worktrees-unanswered)))

(defun herdr-dispatch--worktrees-received (workspace-id generation found error)
  "Cache FOUND as WORKSPACE-ID\\='s worktrees and ask for a redraw.

GENERATION is what `herdr-dispatch--worktrees-generation\\=' held when the
request went out.  A reply from an older generation was invalidated while
it was in flight, so it is dropped whole: it neither writes the cache nor
touches the pending set, which by then describes the refetch that
replaced it rather than this request.

A non-nil ERROR caches nil rather than nothing at all.  The ordinary
cause is a workspace directory that is not a git repository, which will
fail identically forever, and asking again on every redraw is a request
per workspace several times a second for as long as the dashboard is
open.  The workspace is remembered in
`herdr-dispatch--worktrees-unanswered\\=' instead, which
\\[herdr-dispatch-refresh] retries — so the entry costs nothing to
correct and is not permanent.  It is not retried any sooner than that,
because nothing the dashboard can observe says the answer would differ:
the directory it named is the same directory, and no event announces
that one has become a git repository.

Called from a process sentinel, where a signal would be unhandled and
land in the event stream\\='s filter, so nothing here may signal: the
server\\='s error arrives as data rather than as a `herdr-error\\=', and a
dashboard killed since the request went out is a redraw not scheduled
rather than a buffer written to."
  (when (equal generation herdr-dispatch--worktrees-generation)
    (setq herdr-dispatch--worktrees-pending
          (delete workspace-id herdr-dispatch--worktrees-pending))
    (when error
      (setf (alist-get workspace-id herdr-dispatch--worktrees-unanswered
                       nil nil #'equal)
            'error))
    (setf (alist-get workspace-id herdr-dispatch--worktrees nil nil #'equal)
          found)
    (when (get-buffer herdr-dispatch-buffer-name)
      (herdr-dispatch--schedule-refresh))))

(defun herdr-dispatch--fetch-worktrees (workspace-id directory)
  "Ask for WORKSPACE-ID\\='s worktrees, which live in DIRECTORY.

A nil DIRECTORY has no question to ask — `herdr-state-workspace-directory\\='
derives one from the workspace\\='s panes, and a workspace with no panes
still renders — so it caches empty at once rather than being reconsidered
on every redraw for as long as it stays empty.  That it caches as
`no-directory\\=' rather than as a failure is what lets
`herdr-dispatch--request-worktrees\\=' ask again the moment a pane gives
the workspace a directory.

Asynchronous because there is one request per workspace and this runs in
the refresh path, which is driven by the event stream: a blocking round
trip there is felt as the whole dashboard stalling.  `herdr-rpc-call-async\\='
hands a server error to the callback as data, but getting the request out
at all can signal here and now, so that is turned into the same failure
the callback already handles rather than being allowed to escape into a
redraw.

Passes `herdr-rpc-timeout\\=' as the client-side TIMEOUT, unlike the
callers in herdr-cmd.el: those block server-side on purpose and bind
themselves there, but nothing here is willing to wait out a server that
accepted the connection and never answers.  A timeout arrives at
`herdr-dispatch--worktrees-received\\=' as an ordinary error, which is
what lets `herdr-dispatch--retry-unanswered-worktrees\\=' cure it the same
way it cures any other failed listing.

`error\\=' rather than `herdr-error\\=', because two different signals are
reachable: an unreachable socket is a `herdr-error\\=' with code
\"no_server\", while a peer that closed between connecting and sending
makes `process-send-string\\=' signal a plain `error\\='.  Both leave the
pending marker set, and the callers of `herdr-dispatch-refresh\\=' — the
debounce timer and \\[herdr-dispatch-refresh] — are not wrapped in
`herdr-dispatch--protect\\=', so an escaping signal is a backtrace out of
a timer and a workspace wedged behind a marker nothing will clear.  The
width is affordable because the guarded form is one call: the callback
is invoked from a sentinel later, not from inside it, so a bug in our own
callback cannot hide in here."
  (if (null directory)
      (progn
        (setf (alist-get workspace-id herdr-dispatch--worktrees-unanswered
                         nil nil #'equal)
              'no-directory)
        (setf (alist-get workspace-id herdr-dispatch--worktrees nil nil #'equal)
              nil))
    (push workspace-id herdr-dispatch--worktrees-pending)
    (let ((generation herdr-dispatch--worktrees-generation))
      (condition-case err
          (herdr-rpc-call-async
           "worktree.list" `((cwd . ,directory))
           (lambda (result error)
             (herdr-dispatch--worktrees-received
              workspace-id generation (alist-get 'worktrees result) error))
           herdr-rpc-timeout)
        (error
         (herdr-dispatch--worktrees-received
          workspace-id generation nil
          (if (eq (car err) 'herdr-error)
              `((code . ,(herdr-error-code err))
                (message . ,(herdr-error-message err)))
            `((code . "call_failed")
              (message . ,(error-message-string err))))))))))

(defun herdr-dispatch--request-worktrees (state)
  "Ask for the worktrees of every workspace in STATE that has none cached.

Worktrees are the one thing in the tree the session snapshot does not
carry, so they are fetched as the dashboard renders rather than on a
keystroke: they appear a moment after the buffer opens, with nothing
blocking and nothing to press.

Runs on every refresh, including the ones that skip the redraw.  A
skipped redraw means the tree just built equals the tree on screen, and a
tree built while no worktrees are known goes on equalling itself — so
keying the fetch to the redraw would leave a workspace unasked forever.
A workspace is still only asked once: `assoc\\=' covers the ones already
answered and `herdr-dispatch--worktrees-pending\\=' the ones being answered
now.

The exception is a workspace that was cached empty only because no
directory could be derived for it, which is the state a workspace is in
between the event announcing it and the event giving it its first pane.
Waiting for \\[herdr-dispatch-refresh] there would be the reported bug in
another costume — worktrees that appear only when a key is pressed — so
such an entry is dropped as soon as a directory exists.  This costs a
`herdr-state-workspace-directory\\=' per redraw, which is a walk of the
pane list rather than a round trip, and it cannot loop: the entry that
replaces it is either an answer or a failure, and neither is retried
here."
  (dolist (workspace (herdr-state-workspaces state))
    (let* ((id (alist-get 'workspace_id workspace))
           (directory (herdr-state-workspace-directory state id)))
      (when (and directory
                 (eq 'no-directory
                     (alist-get id herdr-dispatch--worktrees-unanswered
                                nil nil #'equal)))
        (herdr-dispatch--forget-one-worktrees id))
      (unless (or (assoc id herdr-dispatch--worktrees)
                  (member id herdr-dispatch--worktrees-pending))
        (herdr-dispatch--fetch-worktrees id directory)))))

(defun herdr-dispatch--request-known-project-worktrees (known-project-roots)
  "Ask for the worktrees of every root in KNOWN-PROJECT-ROOTS with none cached.

The known-project sibling of `herdr-dispatch--request-worktrees\\=', reusing
the same cache and the same `herdr-dispatch--fetch-worktrees\\=' — a root
here is both the id the reply is cached under and the directory the
request is made about, since a known project always has a directory to
ask about.  That is the one case `herdr-dispatch--request-worktrees\\='
handles specially for a workspace with no panes yet — no-directory,
retried once a directory exists — and it cannot arise here, so there is
nothing to mirror from it."
  (dolist (root known-project-roots)
    (unless (or (assoc root herdr-dispatch--worktrees)
                (member root herdr-dispatch--worktrees-pending))
      (herdr-dispatch--fetch-worktrees
       root (file-name-as-directory (expand-file-name root))))))

(defun herdr-dispatch--retry-unanswered-worktrees ()
  "Forget every workspace that has no answer, and ask again.
The next `herdr-dispatch--request-worktrees\\=' asks them.  Only those: a
repository that genuinely has no worktrees keeps its entry, so
\\[herdr-dispatch-refresh] does not re-ask the whole session.

A request still in flight counts as unanswered, and this is the only
thing that can rescue one before its own timeout would.
`herdr-dispatch--fetch-worktrees\\=' passes `herdr-rpc-timeout\\=', so a
server that accepts the connection and never replies now surfaces on its
own as a timeout error a few seconds later — but until it does, the
pending marker is exactly what stops the workspace being asked again, and
a user who presses \\[herdr-dispatch-refresh] should not have to wait out
that window.  Clearing it here is what makes the keystroke an immediate
cure rather than a no-op until the timeout catches up.

The generation must move with it.  Clearing the marker while a reply is
still on the wire is the same race `herdr-dispatch--forget-worktrees\\='
describes: the reply would land after the refetch had claimed a new
marker, clear a marker it no longer owns, and leave the refetch
unguarded for a third request.  Bumping the generation drops that reply
whole instead."
  (dolist (id (mapcar #'car herdr-dispatch--worktrees-unanswered))
    (setq herdr-dispatch--worktrees
          (assoc-delete-all id herdr-dispatch--worktrees)))
  (setq herdr-dispatch--worktrees-unanswered nil
        herdr-dispatch--worktrees-pending nil
        herdr-dispatch--worktrees-generation
        (1+ herdr-dispatch--worktrees-generation)))

(defun herdr-dispatch--invalidate-worktrees (kind _data)
  "Drop the worktree cache when KIND changed the set of worktrees.
Also unhooks from `herdr-state-change-functions\\=' once the dispatcher's buffer
is gone, matching `herdr-dispatch--refresh-hook\\='.

`workspace_closed\\=' belongs on this list even though it announces no
worktree.  A cached listing outlived the workspace it described for the
rest of the session, and `herdr-dispatch--worktree-at-point\\=' flattens
every cached listing together before searching it, so a dead
workspace\\='s entry could still supply the record a worktree row
resolved to.

Whole-cache rather than the closing workspace\\='s entry alone, which is
the arrangement the worktree events already have and for one more
reason besides theirs.  Theirs: the events carry a worktree, not the
workspace whose listing it belongs to.  This one\\='s: every OTHER
workspace\\='s listing carries `open_workspace_id\\=', so when a worktree
workspace closes, its parent repository\\='s cached listing goes on
saying \"open as wX\" for a workspace that no longer exists — and
dropping only the closing workspace\\='s own entry would leave exactly
that stale claim in place, on the row a user would then press RET on.

The cost is one asynchronous `worktree.list\\=' per remaining workspace,
on an event that fires when a workspace closes and at no other time."
  (when (member kind '("worktree_created" "worktree_opened"
                       "worktree_removed" "workspace_closed"))
    (herdr-dispatch--forget-worktrees))
  (unless (get-buffer herdr-dispatch-buffer-name)
    (remove-hook 'herdr-state-change-functions #'herdr-dispatch--invalidate-worktrees)))

(defun herdr-dispatch--worktree-at-point ()
  "Return the cached WorktreeInfo for the worktree line at point.

A worktree section carries only its path as its value; the branch, and
whether herdr has already opened it as a workspace, live in the cached
record.  Every worktree verb therefore has to resolve the row back to
that record, and resolving it in one place is what stops two verbs on the
same row from disagreeing about which worktree it names."
  (let ((path (herdr-dispatch--require 'herdr-worktree "a worktree")))
    (seq-find (lambda (candidate)
                (equal path (alist-get 'path candidate)))
              (apply #'append (mapcar #'cdr herdr-dispatch--worktrees)))))

(defun herdr-dispatch--checked-worktree-at-point ()
  "Return the cached WorktreeInfo at point, or refuse the row.

The backstop for the renderer\\='s filter, and the one place every worktree
verb — `RET\\=', `f\\=' and `k\\=' alike — resolves a row through.  It refuses
exactly what `herdr-tree--worktrees-node\\=' declines to draw, so a row that
the renderer would not have produced cannot be acted on if one is reached
anyway: from a cache entry drawn before the filter existed, or a listing
whose required field the server omitted.

Three refusals, in the order the answers become available.

A row with no cached record at all comes first.  Checking anything else
first would read fields off nil and announce, confidently and wrongly,
that a row whose record simply could not be found is the repository\\='s
own checkout.

Then the two the renderer applies: `herdr-tree-linked-worktree-p\\=', for a
row that is not a worktree, and `herdr-tree-own-workspace-p\\=' against the
enclosing `herdr-workspace\\=' section, for a row that IS that workspace.
The second is what makes this a guard rather than a formality: `k\\=' on
such a row resolves to the workspace the row is nested inside, which is
the destruction the whole worktree fix is about.

`RET\\=' goes through here too, which it did not before.  That mattered:
`herdr-dispatch-open-worktree\\=' read `open_workspace_id\\=' straight off
the record, so on a stale main-checkout row it focused the enclosing
workspace — and where that field was nil it fell through to a MUTATING
`worktree.open\\=' against the enclosing workspace\\='s own directory.  The
one verb that reached the server unguarded was the one that skipped the
guard."
  (let ((worktree (herdr-dispatch--worktree-at-point)))
    (unless worktree
      (user-error
       "herdr: no worktree listing is cached for the row at point (g refetches)"))
    (let ((name (or (alist-get 'branch worktree)
                    (alist-get 'path worktree)
                    "the row at point")))
      (unless (herdr-tree-linked-worktree-p worktree)
        (user-error
         "herdr: %s is the repository's own checkout, not one of its worktrees"
         name))
      (when (herdr-tree-own-workspace-p
             worktree (herdr-dispatch--value-at-point 'herdr-workspace))
        (user-error
         "herdr: %s is the workspace this list belongs to, not one of its worktrees"
         name))
      worktree)))

(defun herdr-dispatch--worktree-workspace ()
  "Return the id of the workspace the worktree at point is open as.

`worktree.remove\\=' and `workspace.focus\\=' both address a workspace, and a
worktree that herdr has not opened as one has no such id.  The enclosing
workspace is not a substitute: it is the repository whose worktree list
this row was expanded from, a different object entirely — reaching for it
is how `k\\=' came to remove the very workspace point was standing in.  So
this refuses rather than guesses.

Whether the row may be acted on at all is settled first, by
`herdr-dispatch--checked-worktree-at-point\\='.  Only the question this
function\\='s own name asks is left here."
  (let ((worktree (herdr-dispatch--checked-worktree-at-point)))
    (or (alist-get 'open_workspace_id worktree)
        (user-error "herdr: worktree %s is not open as a workspace (RET opens it)"
                    (or (alist-get 'branch worktree)
                        (alist-get 'path worktree)
                        "at point")))))

(defun herdr-dispatch--refuse-heading (complaint)
  "Refuse a verb on a grouping heading, COMPLAINT saying which.
Covers both group headings this buffer draws: a `worktrees (N)\\=' list
and the `Inactive (N)\\=' known-projects group.

The heading names a list, not a herdr object.  Every verb in this buffer
acts on something with an id — a pane, a tab, a workspace, the workspace
a worktree is open as, or a known project's root — and a heading has
none: it is a container this file draws around a cached reply (a
`worktree.list\\=' answer, or the filtered known-project list), and its
value either names the id the reply was fetched for or is a stable
placeholder, neither of which is the same claim as a herdr object.

Refusing rather than doing nothing is the point.
`herdr-dispatch--value-at-point\\=' walks up from point, so a verb with no
arm for this type does not fail — it silently finds the enclosing
workspace and acts on that.  Verified before this existed: `k\\=', `R\\='
and `f\\=' on a `worktrees (N)\\=' heading reached `workspace.close\\=',
`workspace.rename\\=' and `workspace.focus\\=', each naming the repository
whose worktrees the heading was counting.  That is the same defect shape
as the one `herdr-tree-linked-worktree-p\\=' describes, one line above
these arms in the same `cond\\='.  The `Inactive (N)\\=' heading has no
enclosing workspace to fall through to — it sits at the top level — so
for it this is a belt rather than the braces, but the same explicit
refusal keeps both headings consistent under every verb.

`RET\\=' and `f\\=' refuse for that reason too, rather than approximating.
Sending them to the enclosing workspace would be the fall-through
dressed up as a decision, and there is no other server-side object here
to go to.  Each heading's one useful action is folding, which
\\[magit-section-toggle] already does — hence the hint."
  (user-error "herdr: %s; TAB folds it" complaint))

(herdr-dispatch-defverb herdr-dispatch-open-worktree ()
  "Open the worktree at point as a workspace.

Calls `worktree.open\\=' directly rather than through `herdr-worktree-open\\=',
which derives its `cwd\\=' from the calling buffer's `default-directory\\=' —
here that would be `*herdr-agents*\\=', not the worktree's own workspace,
so the request would resolve against whatever directory the dispatcher
buffer happened to hold rather than the workspace at point.

Resolves through `herdr-dispatch--checked-worktree-at-point\\=' like every
other worktree verb.  It cannot use `herdr-dispatch--worktree-workspace\\='
itself, which refuses a worktree that is not open as a workspace —
opening exactly that is what this command is for — but the checks that
say whether the row may be acted on at all are the same ones, and
reading the record directly is what let this command act on rows the
others refuse."
  (let* ((worktree (herdr-dispatch--checked-worktree-at-point))
         (workspace (herdr-dispatch--require 'herdr-workspace "a workspace")))
    (if-let* ((open (alist-get 'open_workspace_id worktree)))
        (herdr-workspace-focus open)
      (let ((dir (herdr-state-workspace-directory (herdr-state-current)
                                                   workspace)))
        (herdr-rpc-call "worktree.open"
                        `((branch . ,(alist-get 'branch worktree))
                          (cwd . ,dir)
                          (focus . t)))))))

(herdr-dispatch-defverb herdr-dispatch-open-known-project ()
  "Open the known project at point as a new workspace.

Reached only from a `herdr-known-project\\=' row, which
`herdr-tree--known-project-nodes\\=' builds only for a root with no
workspace currently open — so this always creates one.  The check for
an existing workspace stays anyway: the row was built from a state that
could be one poll tick behind by the time RET lands, and creating a
second workspace for a directory that already has one is the exact bug
`herdr-state-workspace-for-directory\\=' exists to prevent — the same
guard `herdr-project\\=' makes before it creates.  Both share
`herdr-cmd-open-workspace-for\\=', which makes that guard, focuses what
it creates, and goes there under either terminal backend."
  (let ((root (herdr-dispatch--require 'herdr-known-project
                                       "a known project")))
    (herdr-cmd-open-workspace-for
     root (file-name-nondirectory (directory-file-name root)))))

;;; The read-only verbs

(herdr-dispatch-defverb herdr-dispatch-visit ()
  "Go to the thing at point.
A pane is focused and its buffer shown; a workspace is focused and then
followed to whichever pane herdr lands on, which is the server\\='s
choice rather than ours.  A known project with no workspace
open yet is created and focused instead — see
`herdr-dispatch-open-known-project\\='.  The worktrees heading has
nowhere to go; see `herdr-dispatch--refuse-heading\\='."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-focus (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    (herdr-dispatch-open-worktree))
   ((herdr-dispatch--type-at-point 'herdr-panes)
    (herdr-dispatch--refuse-heading
     "a workspace's main group is not somewhere to go"))
   ((herdr-dispatch--value-at-point 'herdr-known-project)
    (herdr-dispatch-open-known-project))
   ((herdr-dispatch--type-at-point 'herdr-known-projects)
    (herdr-dispatch--refuse-heading
     "the inactive-projects group is not somewhere to go"))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-focus (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point"))))

(herdr-dispatch-defverb herdr-dispatch-prompt ()
  "Prompt the agent at point."
  (let ((pane (herdr-dispatch--require 'herdr-pane "an agent")))
    (herdr-agent-prompt (read-string "Prompt: ") pane)))

(herdr-dispatch-defverb herdr-dispatch-read ()
  "Read the pane at point into a buffer."
  (herdr-pane-read (herdr-dispatch--require 'herdr-pane "a pane")
                   "recent_unwrapped"))

(herdr-dispatch-defverb herdr-dispatch-focus ()
  "Focus the thing at point server-side, without moving Emacs.
A worktree is focused as the workspace herdr has opened it as; a worktree
that is not open as one has nothing to focus and says so, and neither
does a known project with no workspace open — RET creates one instead
of merely focusing, so this refuses rather than doing that on the wrong
key.  Neither has the worktrees heading; see
`herdr-dispatch--refuse-heading\\='."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    (herdr-rpc-call "workspace.focus"
                    `((workspace_id . ,(herdr-dispatch--worktree-workspace)))))
   ((herdr-dispatch--type-at-point 'herdr-panes)
    (herdr-dispatch--refuse-heading
     "a workspace's main group cannot be focused"))
   ((herdr-dispatch--value-at-point 'herdr-known-project)
    (user-error "herdr: %s has no workspace open yet (RET opens it)"
                (herdr-dispatch--value-at-point 'herdr-known-project)))
   ((herdr-dispatch--type-at-point 'herdr-known-projects)
    (herdr-dispatch--refuse-heading
     "the inactive-projects group cannot be focused"))
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-rpc-call "pane.focus"
                    `((pane_id . ,(herdr-dispatch--value-at-point 'herdr-pane)))))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-rpc-call "workspace.focus"
                    `((workspace_id . ,(herdr-dispatch--value-at-point
                                        'herdr-workspace)))))
   (t (user-error "herdr: nothing at point"))))

;;; The mutating verbs

(herdr-dispatch-defverb herdr-dispatch-rename ()
  "Rename the thing at point.
Most specific section wins: a pane line inside a workspace renames the
pane, which is the thing you are looking at, rather than its
workspace.  A worktree has no rename operation at all, so it is refused
rather than allowed to fall through to the repository workspace whose
list it was expanded from — and neither has the heading that groups
them; see `herdr-dispatch--refuse-heading\\='."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    (user-error
     "herdr: a worktree cannot be renamed; rename its branch with git"))
   ((herdr-dispatch--type-at-point 'herdr-panes)
    (herdr-dispatch--refuse-heading
     "a workspace's main group cannot be renamed"))
   ((herdr-dispatch--value-at-point 'herdr-known-project)
    (user-error "herdr: a known project has no label of its own to rename"))
   ((herdr-dispatch--type-at-point 'herdr-known-projects)
    (herdr-dispatch--refuse-heading
     "the inactive-projects group cannot be renamed"))
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-rename (read-string "Pane label: ")
                       (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-rename (read-string "Workspace label: ")
                            (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point to rename"))))

(herdr-dispatch-defverb herdr-dispatch-close ()
  "Close or remove the thing at point.
The underlying commands — `herdr-pane-close\\=', `herdr-workspace-close\\='
and `herdr-worktree-remove\\=' — all prompt for confirmation, so this adds
no second prompt.

A worktree is removed as the workspace herdr has opened it as, which is
the only handle `worktree.remove\\=' has on it.  Not the enclosing
workspace: that is the repository whose worktree list this row was
expanded from, and removing it would destroy something other than the row
under point.  The heading that groups the rows is refused outright, for
the same reason and with more at stake; see
`herdr-dispatch--refuse-heading\\='."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    (herdr-worktree-remove (herdr-dispatch--worktree-workspace)))
   ((herdr-dispatch--type-at-point 'herdr-panes)
    (herdr-dispatch--refuse-heading
     "a workspace's main group cannot be closed"))
   ((herdr-dispatch--value-at-point 'herdr-known-project)
    (user-error "herdr: a known project with no workspace open has nothing to close"))
   ((herdr-dispatch--type-at-point 'herdr-known-projects)
    (herdr-dispatch--refuse-heading
     "the inactive-projects group cannot be closed"))
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-close (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-close (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point to close"))))

;;; The create transient

(defun herdr-dispatch--arg (args flag)
  "Return the value of FLAG in transient ARGS, or nil."
  (when-let* ((hit (seq-find (lambda (arg)
                               (string-prefix-p (concat flag "=") arg))
                             args)))
    (substring hit (1+ (length flag)))))

(defun herdr-dispatch--args ()
  "Return the create transient\\='s arguments, or nil outside it."
  (when (and (boundp 'transient-current-command)
             (eq transient-current-command 'herdr-dispatch-create))
    (transient-args 'herdr-dispatch-create)))

(herdr-dispatch-defverb herdr-dispatch-create-workspace ()
  "Create a workspace.
A workspace has no parent section to inherit from, so the directory
comes from --directory when set, and otherwise from a prompt defaulting
to the directory of the workspace at point."
  (let* ((args (herdr-dispatch--args))
         (default (or (herdr-dispatch--arg args "--directory")
                      (when-let* ((id (herdr-dispatch--value-at-point
                                       'herdr-workspace)))
                        (herdr-state-workspace-directory
                         (herdr-state-current) id))
                      default-directory))
         (dir (or (herdr-dispatch--arg args "--directory")
                  (read-directory-name "Workspace directory: " default))))
    (herdr-workspace-create dir (herdr-dispatch--arg args "--label"))))

(defun herdr-dispatch--pane-for-directory-at-point ()
  "Return a pane for a new terminal in the directory the row at point names.

A `herdr-worktree\\=' row — a worktree, or the `main\\=' row standing for a
repository\\='s own checkout — and a `herdr-known-project\\=' row both name
a directory rather than a workspace.
\\[herdr-dispatch-create-pane] had no answer for either:
`herdr-dispatch--workspace-target\\=' resolves a workspace or nothing, and
nothing means `tab.create\\=' falls back to whatever workspace the SERVER
has focused.  So `n\\=' on an inactive project quietly opened a terminal
somewhere else entirely — the one outcome worse than refusing, because
nothing on screen said where it went.

The directory row wins over any enclosing workspace, and that ordering
is the point rather than an accident: a worktree row inside an open
repository has that repository as its enclosing workspace, and a
terminal opened there would land in the repository the user was pointing
past.

What the directory then means is `herdr-cmd-pane-in-directory\\='\\='s
answer, shared with \\[herdr-new-terminal] so the two cannot disagree
about whether a directory needs a workspace opening first."
  (when-let* ((directory (or (herdr-dispatch--value-at-point 'herdr-worktree)
                             (herdr-dispatch--value-at-point 'herdr-known-project))))
    (herdr-cmd-pane-in-directory directory)))

(defun herdr-dispatch--workspace-target ()
  "Return the workspace id point resolves to, or nil.
A pane row resolves through its own record; a workspace heading is
itself; anywhere else answers nil.

Nil used to be handed to `tab.create', which reads it as \"whichever
workspace the server has focused\" — so a verb aimed at a heading acted
somewhere else entirely.  `herdr-dispatch--workspace-target-pane' is
where that nil is now refused, and this stays a plain question with a
plain answer."
  (or (herdr-dispatch--value-at-point 'herdr-workspace)
      (when-let* ((pane-id (herdr-dispatch--value-at-point 'herdr-pane))
                  (pane (herdr-state-pane (herdr-state-current) pane-id)))
        (alist-get 'workspace_id pane))))

(defun herdr-dispatch--workspace-target-pane ()
  "Return a fresh tab\\='s pane in the workspace at point, or refuse.
Split from `herdr-dispatch-create-pane\\=' so the refusal sits next to
the nil it is refusing: `herdr-cmd--new-tab-pane\\=' treats a nil
workspace as \"whichever the server has focused\", which is the one
answer this buffer must never give silently."
  (let ((workspace (herdr-dispatch--workspace-target)))
    (unless workspace
      (user-error "herdr: nothing at point names a workspace to open a terminal in"))
    (herdr-cmd--new-tab-pane workspace)))

(herdr-dispatch-defverb herdr-dispatch-create-pane ()
  "Open a terminal, taking its place from point.

Most specific first.  A row naming a directory rather than
a workspace — a worktree, the `main\\=' row, an inactive project —
resolves through `herdr-dispatch--pane-for-directory-at-point\\=', which
opens that directory as a workspace if nothing is open there yet.
Anywhere else a fresh tab is created in the workspace at point, so `n\\='
has an answer everywhere in the buffer.

A row that resolves to neither is refused rather than sent to the
server\\='s focused workspace.  The `Inactive (N)\\=' heading and the
dashboard\\='s own header line name no place at all, and a nil
`workspace_id\\=' makes `tab.create\\=' pick one for you — so the terminal
opened somewhere the user was not pointing, with nothing on screen
saying where.  Every other verb already refuses both headings; see
`herdr-dispatch--refuse-heading\\='.

This is the only create verb for a place to run something.  There was a
second, `a\\=', which asked for an agent kind and a name and then called
`agent.start\\=' — a door herdr\\='s own TUI does not have, where a new tab
opens a shell and the agent is whatever you run in it.  herdr names that
agent by detection a few seconds later, so the two doors differed in
what they demanded up front and in nothing else."
  (when (herdr-dispatch--type-at-point 'herdr-known-projects)
    (herdr-dispatch--refuse-heading
     "the inactive-projects group is not a place to open a terminal"))
  (herdr-cmd--follow-new-pane
   (or (herdr-dispatch--pane-for-directory-at-point)
       (herdr-dispatch--workspace-target-pane))))

(herdr-dispatch-defverb herdr-dispatch-create-worktree ()
  "Create a git worktree from the workspace at point.

Calls `herdr-rpc-call\\=' directly rather than through
`herdr-worktree-create\\=', which derives its `cwd\\=' from the calling
buffer's `default-directory\\=' — here that would be `*herdr-agents*\\=',
not the workspace at point, matching the treatment already given to
`herdr-dispatch-open-worktree\\='."
  (let* ((args (herdr-dispatch--args))
         (workspace (herdr-dispatch--require 'herdr-workspace "a workspace"))
         (branch (read-string "New worktree branch: "))
         (base (herdr-dispatch--arg args "--base"))
         (dir (herdr-state-workspace-directory (herdr-state-current) workspace)))
    (herdr-rpc-call "worktree.create"
                    `((branch . ,branch)
                      (base . ,(unless (string-empty-p (or base "")) base))
                      (cwd . ,dir)
                      (focus . t)))
    (herdr-dispatch--forget-worktrees)
    (herdr-dispatch-refresh)))

(defun herdr-dispatch--create-heading ()
  "Return the create menu heading, naming what point resolves to."
  (format "Create   [%s]"
          (or (herdr-dispatch--value-at-point 'herdr-pane)
              (herdr-dispatch--value-at-point 'herdr-workspace)
              "nothing at point")))

(transient-define-prefix herdr-dispatch-create ()
  "Create a herdr object, taking its parent from point."
  [:description herdr-dispatch--create-heading
   ["Create"
    ("w" "workspace" herdr-dispatch-create-workspace)
    ("n" "terminal"  herdr-dispatch-create-pane)
    ("%" "worktree"  herdr-dispatch-create-worktree)]
   ["Arguments"
    ("-b" "base ref"  "--base=")
    ("-l" "label"     "--label=")
    ("-d" "directory" "--directory=")]])

(defun herdr-dispatch--live-project-root-p (root)
  "Return non-nil when ROOT is a directory that still exists.

project.el remembers a project until it is told to forget one, and
nothing tells it when a directory is deleted.  A worktree removed with
`herdr-worktree-remove\\=', or any project directory deleted outside
Emacs, therefore stays in `project-known-project-roots\\=' and
kept drawing an `Inactive\\=' row for a path that is not there — a row
`RET\\=' could only fail on, and one that no longer even appeared under
the repository it came from, since the repository had stopped listing it
as a worktree.

A remote root is taken on trust.  `file-directory-p\\=' over TRAMP is a
round trip to another machine, and this runs on every redraw; a row for
a directory that has since gone from a remote host is a far smaller cost
than a dashboard that blocks on an unreachable host every time an event
arrives.

This hides such a row; it does not forget the project.  Removing it from
project.el is `project-forget-zombie-projects\\=', which is project.el's
own command for exactly this and which writes to the user's
`project-list-file\\=' — not something a dashboard redraw should do on
its own."
  (or (file-remote-p root)
      (file-directory-p root)))

(defun herdr-dispatch--known-project-roots ()
  "Return the still-existing `project-known-project-roots\\=', or nil.
Nil without project.el; guarded rather than required, since
`herdr-project\\=' checks the same way \(`fboundp\\=' \\='project-current\\='\),
so the dispatcher asks nothing of project.el that the rest of the
package does not already ask.

Roots whose directory has been deleted are dropped here rather than in
`herdr-tree.el\\=', which is a pure function of its arguments and stays
that way: this is already the boundary where project.el's own answer
enters the dashboard, and the only place that touches the filesystem to
find out what that answer is worth.  See
`herdr-dispatch--live-project-root-p\\='.

Dropping them here also spares each one a `worktree.list\\=' round trip,
since `herdr-dispatch--request-known-project-worktrees\\=' is given this
filtered list."
  (when (fboundp 'project-known-project-roots)
    (seq-filter #'herdr-dispatch--live-project-root-p
                (project-known-project-roots))))

(defun herdr-dispatch--header (state)
  "Return the header line summarising STATE.
Ends with `herdr-tree-status-summary\\=' rather than an agent count: a
count that is always true stops being read, the same reasoning that
already keeps idle out of the modeline segment."
  (let ((summary (herdr-tree-status-summary state)))
    (format "herdr   %d workspaces  %d panes%s"
            (length (herdr-state-workspaces state))
            (length (herdr-state-panes state))
            (if (string-empty-p summary) "" (concat "  " summary)))))

(defun herdr-dispatch--position-at (position)
  "Return (IDENT . COLUMN) naming the section and column at POSITION, or nil.
Section identity rather than a line number: a pane closing above point
used to move you to a different agent than the one you were reading.

Columns are counted as if nothing were folded; see
`herdr-dispatch--position-restore\\=' for why."
  (save-excursion
    (let ((buffer-invisibility-spec nil))
      (goto-char position)
      (when-let* ((section (magit-current-section)))
        (cons (magit-section-ident section) (current-column))))))

(defun herdr-dispatch--position-restore (position)
  "Return where POSITION now lands, or nil when its section is gone.
POSITION is a (IDENT . COLUMN) pair from `herdr-dispatch--position-at'.
The column is restored within the section\\='s heading line and clamped to
that line\\='s end, so a redraw keeps the horizontal place as well as the
vertical one — going to the section start alone jumps you to column 0.

Both halves count columns with `buffer-invisibility-spec\\=' unbound,
because a line inside a folded section has no width at all while the
fold is in force: `current-column\\=' there answers for the visible line
the fold collapsed it into, and `move-to-column\\=' walks straight past
the whole hidden region into the next visible line.  Point would come
back from a redraw somewhere else entirely — which is the failure this
whole pair exists to prevent, and which only became reachable once
`herdr-dispatch--apply-fold\\=' made folds survive a redraw."
  (when-let* ((section (magit-get-section (car position))))
    (save-excursion
      (let ((buffer-invisibility-spec nil))
        (goto-char (oref section start))
        (move-to-column (cdr position))
        (point)))))

(defun herdr-dispatch-refresh (&optional force)
  "Redraw the dispatcher from the cache, keeping point and fold state.

Does nothing when the tree and header are already what is on screen.
Many events change nothing the dashboard renders — status refreshes
that confirm the same status, reconciles that touched only volatile
fields — and erasing the buffer to lay down the same characters is what
reset the cursor and left folds acting on dead sections.  Non-nil FORCE
redraws regardless, which is what \\[herdr-dispatch-refresh] does.

Also where worktrees are fetched, since this is the one place that knows
a workspace is being drawn — and, the same way, the one place that knows
which known-but-unopened projects are being drawn under `Inactive\\='; see
`herdr-dispatch--request-worktrees\\=' and its sibling
`herdr-dispatch--request-known-project-worktrees\\='.  Both requests go
out whether or not this call redraws, and each reply schedules its own
redraw rather than forcing one.  FORCE additionally retries the
workspaces whose last fetch could not be answered, which is the manual
cure for a `worktree.list\\=' that failed.

A redraw that does happen restores the section highlight as well as
point and folds; see the comment where it does.  The skip is the other
half of keeping that highlight, and `herdr-tree--steady-title\\=' is what
lets the skip engage at all while an agent is working."
  (interactive (list t))
  (when-let* ((buffer (get-buffer herdr-dispatch-buffer-name)))
    (with-current-buffer buffer
      (when force (herdr-dispatch--retry-unanswered-worktrees))
      (let* ((state (herdr-state-current))
             (known-roots (herdr-dispatch--known-project-roots))
             (header (herdr-dispatch--header state))
             (tree (herdr-tree-build state herdr-dispatch--worktrees
                                     known-roots)))
        (when (or force
                  (not (equal header herdr-dispatch--rendered-header))
                  (not (equal tree herdr-dispatch--rendered-tree)))
          ;; Point is saved per window as well as for the buffer.  When
          ;; the hook fires from the event-stream process filter the
          ;; dashboard is usually not the selected window, and for a
          ;; window that is not selected `window-point' is what governs —
          ;; `erase-buffer' collapses it and a buffer-point restore never
          ;; reaches it.
          ;;
          ;; Fold state needs no saving here.  `magit-section-hide' and
          ;; `magit-section-show' write to `magit-section-visibility-cache'
          ;; as they go, and `magit-section-set-visibility-hook' reads it
          ;; back when each section is recreated below.
          (let* ((inhibit-read-only t)
                 (saved (mapcar (lambda (window)
                                  (cons window
                                        (herdr-dispatch--position-at
                                         (window-point window))))
                                (get-buffer-window-list buffer nil t)))
                 (here (herdr-dispatch--position-at (point))))
            (erase-buffer)
            (magit-insert-section (herdr-root)
              (magit-insert-heading (herdr-dispatch--heading header))
              (insert ?\n)
              (herdr-dispatch--insert-nodes tree))
            (when-let* ((position (and here
                                       (herdr-dispatch--position-restore here))))
              (goto-char position))
            (dolist (entry saved)
              (when-let* ((position
                           (and (cdr entry)
                                (herdr-dispatch--position-restore (cdr entry)))))
                (set-window-point (car entry) position)))
            ;; The highlight is an overlay on the text `erase-buffer'
            ;; just took away, and nothing recreates it: magit refreshes
            ;; it from `magit-section-post-command-hook', and a redraw
            ;; driven by the event stream is not a command.  Verified,
            ;; one overlay before a redraw and none after — so the line
            ;; you were reading stopped being marked as such the moment
            ;; anything in the session moved.
            ;;
            ;; After the point restores rather than before, because this
            ;; highlights whatever `magit-current-section' answers, and
            ;; that is read off point.
            ;;
            ;; Unforced, and that is not a near miss.  The unforced path
            ;; updates when `magit-section-pre-command-section' is not
            ;; `eq' to the section now at point, and every section object
            ;; in this buffer was just replaced — `erase-buffer' and the
            ;; insert below make new ones — so that test cannot be false
            ;; here.  This call carried a FORCE argument justified by the
            ;; claim that the unforced path would do nothing, which is
            ;; untrue, and which no test could be written to defend: the
            ;; two spellings behave identically at this call site.  What
            ;; protects the behaviour either way is
            ;; `herdr-dispatch-a-redraw-restores-the-section-highlight',
            ;; which asserts the overlay rather than the mechanism, and
            ;; so would fail if magit ever changed that branch.
            (magit-section-update-highlight))
          (setq herdr-dispatch--rendered-header header
                herdr-dispatch--rendered-tree tree))
        ;; After the draw rather than before it: a reply must reach the
        ;; screen through the scheduled redraw, so that a callback which
        ;; caches without asking for one is a visible failure rather than
        ;; something this call papers over.
        (herdr-dispatch--request-worktrees state)
        (herdr-dispatch--request-known-project-worktrees known-roots)))))

(defun herdr-dispatch--cancel-refresh ()
  "Cancel the pending debounced redraw, if there is one."
  (when herdr-dispatch--refresh-timer
    (cancel-timer herdr-dispatch--refresh-timer)
    (setq herdr-dispatch--refresh-timer nil)))

(defun herdr-dispatch--schedule-refresh ()
  "Redraw the dispatcher shortly, coalescing a burst of events into one.

A pending timer is KEPT, not cancelled and re-armed.  The re-arm shape
\(which `herdr-term--schedule-directory-poll\\=' still uses, correctly —
its backstop timer covers what the deferral misses\) starved this redraw
outright: the stream's median event gap is 0.105s and the debounce
0.2s, so while an agent produced output every reschedule pushed the
redraw past the next event and the dashboard stayed stale for exactly
as long as something was happening on it.  A kept timer fires one
debounce after the first event of a burst, bounding staleness at
`herdr-dispatch-refresh-debounce\\=' instead of at the length of the
burst."
  (unless herdr-dispatch--refresh-timer
    (setq herdr-dispatch--refresh-timer
          (run-at-time herdr-dispatch-refresh-debounce nil
                       (lambda ()
                         (setq herdr-dispatch--refresh-timer nil)
                         (herdr-dispatch-refresh))))))

(defun herdr-dispatch--refresh-hook (&rest _)
  "Schedule a dispatcher redraw, or unhook when its buffer is gone."
  (if (get-buffer herdr-dispatch-buffer-name)
      (herdr-dispatch--schedule-refresh)
    (herdr-dispatch--cancel-refresh)
    (remove-hook 'herdr-state-change-functions #'herdr-dispatch--refresh-hook)))

;;;###autoload
(defun herdr-agents ()
  "Show the herdr dispatcher: workspaces, tabs, panes and agents.

Worktree knowledge belongs to an open dashboard, so opening one starts
from none.  While the dashboard is up, `herdr-dispatch--invalidate-worktrees\\='
is on `herdr-state-change-functions\\=' and keeps the listings honest; when the
buffer dies that hook takes itself off, so a worktree created between
closing the dashboard and reopening it is one nothing here ever hears
about.  \\[herdr-dispatch-refresh] is no cure — it re-asks the workspaces
that could not be answered, not the ones that were — so the answers would
otherwise outlive their truth with nothing able to correct them.
Forgetting on open costs one asynchronous request per workspace, which is
what opening the dashboard already costs."
  (interactive)
  (let ((buffer (get-buffer herdr-dispatch-buffer-name)))
    (unless buffer
      (herdr-dispatch--forget-worktrees)
      (setq buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-dispatch-mode) (herdr-dispatch-mode))
      (add-hook 'herdr-state-change-functions #'herdr-dispatch--refresh-hook)
      (add-hook 'herdr-state-change-functions #'herdr-dispatch--invalidate-worktrees))
    (herdr-dispatch-refresh t)
    (pop-to-buffer buffer)))

(provide 'herdr-dispatch)
;;; herdr-dispatch.el ends here
