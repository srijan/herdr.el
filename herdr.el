;;; herdr.el --- Control the herdr terminal workspace manager -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; URL: https://github.com/ejesinsky/herdr.el
;; Version: 0.1.0
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (magit-section "3.3") (ghostel "0"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Drive herdr (https://herdr.dev), a terminal workspace manager for AI
;; coding agents, from Emacs.
;;
;; herdr's terminals live inside Emacs via ghostel, so there is no
;; second terminal application in the loop.  Commands go over herdr's
;; unix socket; a live event stream keeps a cache of the session, which
;; feeds the modeline segment, the `*herdr-agents*' buffer, and the
;; completion pickers.
;;
;; Start with `M-x herdr'.

;;; Code:

(require 'herdr-rpc)
(require 'herdr-state)
(require 'herdr-term)
(require 'herdr-cmd)
(require 'herdr-modeline)
;; Required rather than left to its autoload cookie.  `herdr-call' is the
;; escape hatch every deleted command now relies on — twenty-eight of
;; them, reachable only through it — so "is it loaded?" must not depend
;; on a package manager having generated an autoload file.  It used to
;; arrive with `herdr-transient', which put it on `:'; nothing pulls it
;; in since that file went, and `M-x herdr-call' answered
;; `void-function' in a session that had only required this one.
(require 'herdr-call)

(declare-function project-root "project" (project))
(declare-function project-current "project" (&optional maybe-prompt directory))

(defcustom herdr-protocol-version 20
  "Protocol version this package was written against.
A mismatch warns once rather than refusing to run: declining to work
because herdr bumped a minor is worse than one command misbehaving."
  :type 'integer
  :group 'herdr)

(defvar herdr--protocol-warned nil)

(defun herdr--check-protocol ()
  "Warn once if the server speaks a protocol this package does not know."
  (unless herdr--protocol-warned
    (when-let* ((pong (ignore-errors (herdr-rpc-call "ping")))
                (protocol (alist-get 'protocol pong)))
      (unless (equal protocol herdr-protocol-version)
        (setq herdr--protocol-warned t)
        (message
         "herdr.el: server speaks protocol %s, this package targets %s; \
some commands may misbehave"
         protocol herdr-protocol-version)))))

;;;###autoload
(defun herdr-start ()
  "Bring up herdr inside Emacs: server, terminals, and the event stream."
  (interactive)
  (herdr-term-ensure)
  (herdr--check-protocol)
  (unless (herdr-state-running-p)
    (herdr-state-start))
  ;; agent-windows needs the cache before it can decide what to attach.
  (when (eq herdr-terminal-backend 'agent-windows)
    (herdr-term-ensure)))

;;;###autoload
(defun herdr-stop ()
  "Stop following herdr and kill its Emacs-side buffers.
The herdr server keeps running; agents are unaffected."
  (interactive)
  (herdr-term-teardown)
  (herdr-state-stop))

;;;###autoload
(defun herdr-project ()
  "Focus the herdr workspace for the current project, creating it if absent."
  (interactive)
  (herdr-start)
  (let ((root (or (when (fboundp 'project-current)
                    (when-let* ((project (project-current nil)))
                      (expand-file-name (project-root project))))
                  default-directory)))
    (herdr-cmd-open-workspace-for
     root (file-name-nondirectory (directory-file-name root)))))

;;;###autoload
(defun herdr ()
  "Start herdr if needed and open the dispatcher.

The one entry point that guarantees the start sequence has run:
`herdr-start\\=' brings up the server, the terminals and the event
stream, so the dashboard is drawn from a cache with something in it
rather than from a cold one.  `herdr-agents\\=' on its own does not,
which is why `s\\=' in `herdr-command-map\\=' is bound here rather than
there."
  (interactive)
  (herdr-start)
  (herdr-term-display)
  (herdr-agents))

(defvar herdr-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "s" #'herdr)
    (define-key map "f" #'herdr-pane-focus)
    (define-key map "n" #'herdr-new-terminal)
    (define-key map "k" #'herdr-pane-close)
    (define-key map "w" #'herdr-workspace-focus)
    (define-key map "p" #'herdr-project)
    (define-key map "%" #'herdr-worktree-create)
    (define-key map "g" #'herdr-state-resync)
    map)
  "Prefix keymap for herdr, meant to be bound to one key of your own.

    (define-key global-map (kbd \"C-c H\") herdr-command-map)

Bound by you rather than by this package, the way `project-prefix-map\\='
is: a package that seizes a `C-c' binding takes it from the user, and
which key is spare is the user\\='s question.

The letters are the dashboard\\='s letters.  `n\\=' opens a terminal and
`k\\=' closes one here, exactly as they do on a row in `*herdr-agents*\\=';
the difference is only where the target comes from, a picker here and
point there.  `s\\=' is the status buffer, the one entry point that
guarantees the start sequence has run — see `herdr\\='.

There is no help key.  `C-h\\=' after the prefix lists these bindings,
and `C-h m\\=' in `*herdr-agents*\\=' describes that buffer\\='s own.  Emacs
answers both questions already; a third way to ask was one more thing to
remember.

`%\\=' creates a worktree rather than opening a menu of four worktree
commands.  Listing them needed no command — the dashboard draws every
worktree it knows about — opening one is `RET\\=' on its row, and removing
one is `k\\=' there.  Creating is the only one of the four with nowhere
else to be.")

(provide 'herdr)
;;; herdr.el ends here
