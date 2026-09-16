;;; herdr-select.el --- Completion over herdr's session -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Maintainer: Srijan Choudhary
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Pickers for panes, agents and workspaces, on plain `completing-read'
;; over the state cache.
;;
;; A pane or workspace candidate is the whole readable row - id, then
;; what you know it by - rather than an id with the rest hung off an
;; annotation.  `completing-read' matches the candidate and never the
;; annotation, so a name that lives only in an annotation is a name you
;; cannot type to find what it names.  With the row itself as the
;; candidate, "web claude blocked" is a working query under `orderless'.
;;
;; `embark' and `consult' integration registers only when those packages
;; are present.  Neither is a dependency.

;;; Code:

(require 'subr-x)
(require 'herdr-state)
(require 'herdr-rpc)
(require 'herdr-connection)
(require 'herdr-term)
(require 'herdr-pane)
(require 'herdr-workspace)
(require 'herdr-tree)

;; The embark map below binds commands from `herdr-cmd', which requires
;; this file, so they are declared rather than required.
(declare-function herdr-pane-focus "herdr-cmd" (&optional pane-id))
(declare-function herdr-pane-read "herdr-cmd"
                  (&optional pane-id source lines))
(declare-function herdr-pane-close "herdr-cmd" (&optional pane-id))
(declare-function herdr-agent-prompt "herdr-cmd" (text &optional target))

(declare-function project-known-project-roots "project" ())

(defun herdr-select--annotate-pane (pane-id &optional connection)
  "Return the annotation string for PANE-ID on CONNECTION."
  (let* ((state (herdr-state-current connection))
         (pane (herdr-state-pane state pane-id)))
    (if (not pane)
        ""
      ;; `herdr-pane-name' rather than the terminal title alone, so a
      ;; pane somebody renamed — or a plugin pane seated with its
      ;; manifest title — is findable here by the name it is known by
      ;; as well as by what it is doing.  Shared with the dispatcher
      ;; row and the confirmations, so no two surfaces can disagree
      ;; about what a pane is called.
      (let ((agent (herdr-pane-agent pane))
            (status (herdr-state-pane-status state pane))
            (title (herdr-pane-name pane))
            (cwd (herdr-pane-cwd pane)))
        (concat "  "
                (if agent
                    (format "%s %-8s" (herdr-tree-glyph status) agent)
                  (format "%-10s" "shell"))
                " " (or title "")
                (if cwd (format "  %s" (abbreviate-file-name cwd)) ""))))))

(defun herdr-select--annotate-workspace (workspace-id &optional connection)
  "Return the annotation string for WORKSPACE-ID on CONNECTION."
  (let ((workspace (herdr-state-workspace (herdr-state-current connection)
                                          workspace-id)))
    (if workspace
        (format "  %-16s %s panes"
                (or (herdr-workspace-label workspace) "")
                (or (herdr-workspace-pane-count workspace) 0))
      "")))

(defun herdr-select--read (prompt candidates category)
  "Read one of CANDIDATES with PROMPT, tagged CATEGORY."
  (unless candidates
    (user-error "herdr: nothing to choose from"))
  (let ((table
         (lambda (string predicate action)
           (if (eq action 'metadata)
               `(metadata (category . ,category))
             (complete-with-action action candidates string predicate)))))
    (completing-read prompt table nil t)))

(defun herdr-select--pane-candidate (pane-id &optional connection)
  "Return the completion candidate for PANE-ID on CONNECTION.

The id leads, so it stays as searchable as it was and two panes sharing
a name stay two candidates.  What follows is the annotation, moved into
the candidate so it can be matched against."
  (concat pane-id (herdr-select--annotate-pane pane-id connection)))

(defun herdr-select-row-id (candidate)
  "Return the id CANDIDATE names, pane or workspace.
A picker row leads with the id; the consult source, embark and the
dispatcher hand over a bare id.  Both reduce here."
  (car (split-string candidate)))

(defvar herdr-select--rows nil
  "The rows the last picker offered, as (ROW CONNECTION . ID).

A completion candidate is a string, and a string cannot carry which
server it came from.  This is where the answer is looked back up, which
is also what lets a row hold a path with a space in it: the id comes
from here rather than from splitting the row.")

(defun herdr-select--connections ()
  "Return the connections a picker offers, in registration order.
Every connection being followed, not only the one a command would
otherwise resolve to: choosing is the one moment a user says which
server, so this is the surface that must show all of them."
  (or (herdr-connection-list) (list (herdr-current-connection))))

(defun herdr-select--refresh (connections)
  "Refresh each of CONNECTIONS, forgiving the ones that do not answer.

Refreshing at all is the old reasoning: a picker listing panes that no
longer exist is worse than one extra round trip.

Every connection is asked, running or not: a registered connection that
is not being followed holds the empty cache `herdr-state-stop' left, so
skipping it offered no rows at all and the picker refused a list that
worked before.  Failure is swallowed instead, which costs an
unreachable server nothing but its own freshness.

One deadline covers them all, not one each.  Waiting the background
bound per connection made N quiet servers cost N times it, which is the
compounding freeze R6 exists to forbid."
  (let ((deadline (+ (float-time) herdr-rpc-background-timeout)))
    (dolist (connection connections)
      (let ((herdr-rpc-timeout (min herdr-rpc-timeout
                                    (max 0.05 (- deadline (float-time))))))
        (ignore-errors (herdr-state-refresh connection))))))

(defun herdr-select--offer (connections ids candidate)
  "Return the rows CONNECTIONS offer, remembering which one each is on.

IDS returns the ids one connection offers; CANDIDATE renders one of
them.  The server name is appended when there are several connections,
and only then: it is part of the candidate so it can be typed, and it
comes last so the id stays the first token every row reduces through."
  (setq herdr-select--rows
        (seq-mapcat
         (lambda (connection)
           (mapcar
            (lambda (id)
              (let ((row (funcall candidate id connection)))
                (cons (if (cdr connections)
                          (format "%s  @%s" row
                                  (herdr-connection-name connection))
                        row)
                      (cons connection id))))
            (funcall ids connection)))
         connections))
  (mapcar #'car herdr-select--rows))

(defun herdr-select--read-row (prompt connections ids candidate category)
  "Read one row over CONNECTIONS with PROMPT and return the id it names.
IDS, CANDIDATE and CATEGORY are as `herdr-select--offer' takes them.
Choosing a row also makes its connection the answer for this command.
Nil for a row nothing offered, which is what empty input reduces to."
  (when-let* ((row (herdr-select--read
                    prompt (herdr-select--offer connections ids candidate)
                    category))
              (pick (alist-get row herdr-select--rows nil nil #'equal)))
    (herdr-connection-choose (car pick))
    (cdr pick)))

(defun herdr-select-pane (&optional prompt)
  "Read a pane id, defaulting the prompt to PROMPT."
  (let ((connections (herdr-select--connections)))
    (herdr-select--refresh connections)
    (herdr-select--read-row
     (or prompt "Pane: ") connections
     (lambda (connection)
       (herdr-state-pane-ids (herdr-state-current connection)))
     #'herdr-select--pane-candidate 'herdr-pane)))

(defun herdr-select-agent (&optional prompt)
  "Read the pane id of an agent, defaulting the prompt to PROMPT."
  (let ((connections (herdr-select--connections)))
    (herdr-select--refresh connections)
    (herdr-select--read-row
     (or prompt "Agent: ") connections
     (lambda (connection)
       (mapcar #'herdr-pane-id
               (herdr-state-agents (herdr-state-current connection))))
     #'herdr-select--pane-candidate 'herdr-pane)))

(defun herdr-select--place-annotation (place &optional connection)
  "Return the annotation string for PLACE on CONNECTION."
  (let* ((state (herdr-state-current connection))
         (workspace (or (herdr-state-workspace state place)
                        (herdr-state-workspace-for-directory state place))))
    (if workspace
        (herdr-select--annotate-workspace
         (herdr-workspace-id workspace) connection)
      "  not open yet")))

(defun herdr-select--place-candidate (place &optional connection)
  "Return the completion candidate for PLACE on CONNECTION.
A workspace id says nothing about what it is a workspace of, so the
annotation joins the candidate here too."
  (concat place (herdr-select--place-annotation place connection)))

(defun herdr-select--places-for (connection)
  "Return the places CONNECTION offers: its open workspaces, then its roots.

A root is a path on a machine, so only the connection whose host it is
on is asked about it.  Known projects stay in the list when open so
completion can match their paths instead of only their opaque workspace
ids."
  (append (mapcar #'herdr-workspace-id
                  (herdr-state-workspaces (herdr-state-current connection)))
          (herdr-connection-roots-for
           connection
           (when (fboundp 'project-known-project-roots)
             (project-known-project-roots)))))

(defun herdr-select-place (&optional prompt)
  "Read where to open a terminal: an open workspace id, or a project directory.
PROMPT overrides the default."
  (let ((connections (herdr-select--connections)))
    (herdr-select--refresh connections)
    (or (herdr-select--read-row (or prompt "New terminal in: ") connections
                                #'herdr-select--places-for
                                #'herdr-select--place-candidate
                                'herdr-place)
        ;; `completing-read' answers with the empty string on empty input
        ;; whatever REQUIRE-MATCH says, and no row is empty.  The pane
        ;; picker reduces that to nil, which `herdr-call' reads as an
        ;; optional parameter left out; a place is not optional.
        (user-error "herdr: no place chosen"))))

(defun herdr-select--workspace-candidate (workspace-id &optional connection)
  "Return the completion candidate for WORKSPACE-ID on CONNECTION.
Built like a pane row, for the same reason: the label and the pane count
are what you know a workspace by, and completion matches only what is in
the candidate."
  (concat workspace-id
          (herdr-select--annotate-workspace workspace-id connection)))

(defun herdr-select-workspace (&optional prompt)
  "Read a workspace id, defaulting the prompt to PROMPT."
  (let ((connections (herdr-select--connections)))
    (herdr-select--refresh connections)
    (herdr-select--read-row
     (or prompt "Workspace: ") connections
     (lambda (connection)
       (mapcar #'herdr-workspace-id
               (herdr-state-workspaces (herdr-state-current connection))))
     #'herdr-select--workspace-candidate 'herdr-workspace)))

(defun herdr-select-current-target (&optional buffer)
  "Return the pane a command would act on from BUFFER, or nil.
Never prompts, so it is safe to call while rendering a menu."
  (or (herdr-term-pane-for-buffer (or buffer (current-buffer)))
      (herdr-state-focused-pane-id (herdr-state-current))))

(defun herdr-select-target-pane (&optional prompt)
  "Return the pane to act on, preferring the one you are looking at.
PROMPT is passed through to `herdr-select-pane' on the paths that prompt.

In order: a prefix argument always prompts, then the pane of the current
buffer if it is a herdr terminal, then the pane herdr has focused, then
a prompt.  The buffer comes first because herdr\\='s focus is server-side
and moves only when something moves it."
  (cond
   (current-prefix-arg (herdr-select-pane prompt))
   ((herdr-select-current-target))
   (t (herdr-select-pane prompt))))

;;; Optional integrations, registered only when the package is loaded
;; Every hook is `boundp'-guarded: these are third-party variables that
;; get renamed, and a convenience must never break startup.

(defvar herdr-select-pane-embark-map
  (let ((map (make-sparse-keymap)))
    (define-key map "f" #'herdr-pane-focus)
    (define-key map "r" #'herdr-pane-read)
    (define-key map "p" #'herdr-agent-prompt)
    (define-key map "k" #'herdr-pane-close)
    map)
  "Embark actions offered on a herdr pane candidate.")

(defun herdr-select--embark-pane-target (type target)
  "Reduce embark TARGET of TYPE to the pane id it names.
Every action on `herdr-select-pane-embark-map' takes an id, and a picker
candidate is a whole row.

The row\\='s server is chosen on the way past.  An id alone cannot say
which server it belongs to, so an action reduced to one used to reach
whichever connection resolved next."
  (when-let* ((connection (car (alist-get target herdr-select--rows
                                          nil nil #'equal))))
    (herdr-connection-choose connection))
  (cons type (herdr-select-row-id target)))

(with-eval-after-load 'embark
  (when (boundp 'embark-keymap-alist)
    (add-to-list 'embark-keymap-alist
                 '(herdr-pane . herdr-select-pane-embark-map)))
  (when (boundp 'embark-transformer-alist)
    (add-to-list 'embark-transformer-alist
                 '(herdr-pane . herdr-select--embark-pane-target))))

(defun herdr-select-panes-with-buffers (&optional connection)
  "Return CONNECTION's pane ids that currently have an Emacs buffer.

Every pane is attachable, but attaching is lazy, so a pane you have not
visited has no buffer and a buffer switcher cannot switch to it."
  (let ((connection (or connection (herdr-current-connection))))
    (seq-filter (lambda (id)
                  (buffer-live-p (herdr-term-buffer-for-pane connection id)))
                (herdr-state-pane-ids (herdr-state-current connection)))))

(defun herdr-select--row-connection (row)
  "Return the connection ROW came from, or the one a command would mean.
The fallback is for a caller handing over a bare id — embark, or the
dispatcher — rather than a row this file built."
  (or (car (alist-get row herdr-select--rows nil nil #'equal))
      (herdr-current-connection)))

(defun herdr-select--annotate-row (row)
  "Annotate ROW for `consult-buffer', on the server the row came from."
  (herdr-select--annotate-pane (herdr-select-row-id row)
                               (herdr-select--row-connection row)))

(defun herdr-select--consult-visit (row)
  "Switch to the buffer of the pane ROW names and focus that pane in herdr."
  (let ((connection (herdr-select--row-connection row))
        (pane-id (herdr-select-row-id row)))
    (when-let* ((buffer (herdr-term-buffer-for-pane connection pane-id)))
      (herdr-term--show buffer))
    (ignore-errors (herdr-rpc-call connection
                                   "pane.focus" `((pane_id . ,pane-id))))))

(defun herdr-select--consult-source ()
  "Return a `consult-buffer' source listing herdr panes that have buffers.

Listing panes with no buffer would put entries in a buffer switcher
that cannot switch to them: they appear, and selecting one leaves you
where you were.  Those panes stay reachable from the dashboard and from
`herdr-pane-focus', which attach on the way."
  `(:name "herdr pane"
    :narrow ?h
    :category herdr-pane
    :annotate ,#'herdr-select--annotate-row
    :action ,#'herdr-select--consult-visit
    ;; Reconcile at the call site, so the query stays a pure function of
    ;; the cache and testable without a server.  Bound to the background
    ;; timeout: this runs on every `consult-buffer', which nobody
    ;; attributes to herdr, so a wedged server must forfeit a refresh
    ;; rather than freeze buffer switching — and with several servers a
    ;; quiet one must forfeit its own rows rather than the whole list.
    :items ,(lambda ()
              (let ((connections (herdr-select--connections)))
                (let ((herdr-rpc-timeout (min herdr-rpc-timeout
                                              herdr-rpc-background-timeout)))
                  (dolist (connection connections)
                    (ignore-errors
                      (herdr-state-reconcile-panes connection))))
                ;; Bare ids until there are two servers: a row consult
                ;; already annotates gains nothing from repeating what
                ;; the annotation says, and the single-server list is
                ;; then exactly what it was.
                (herdr-select--offer connections
                                     #'herdr-select-panes-with-buffers
                                     (lambda (id &optional _connection) id))))))

(with-eval-after-load 'consult
  (when (boundp 'consult-buffer-sources)
    (defvar herdr-select-consult-source (herdr-select--consult-source)
      "herdr pane source for `consult-buffer'.")
    (add-to-list 'consult-buffer-sources 'herdr-select-consult-source t)))

(provide 'herdr-select)
;;; herdr-select.el ends here
