# herdr.el — Design

Date: 2026-08-01
Status: Approved, not yet implemented

## Summary

An Emacs package that controls [herdr](https://herdr.dev) — a terminal workspace manager for AI
coding agents — through its local unix-socket JSON API. herdr's TUI runs inside a
[ghostel](https://github.com/dakra/ghostel) buffer, so Emacs is the only herdr client and the
whole loop closes inside Emacs. A [transient](https://github.com/magit/transient) menu drives the
session; a live event stream feeds a modeline segment and a status buffer.

Target environment: Emacs 30.2, herdr 0.7.5 (protocol 17), macOS.

## Goals

Four capabilities, all in v1. They are not four features — they are four thin layers over one
substrate (RPC + snapshot cache + event stream), so the marginal cost of each after the core is
small.

1. **Command surface.** Drive herdr from transient instead of its keybindings or CLI.
2. **Agent awareness.** Know which agents are blocked or done without looking.
3. **Output into Emacs.** Pane and agent output as real buffers — greppable, yankable.
4. **Navigation.** Jump to any pane, workspace, or agent by name via `completing-read`.

## Non-goals for v1

Reachable through the generic `herdr-call` escape hatch, but not given curated commands:
`plugin.*`, `pane.graphics.*`, `integration.*`, `server.stop`, remote sessions (`--remote`),
named sessions.

Excluded entirely:

- **Mirror model** (Emacs windows mirroring herdr panes 1:1). Spiked after v1 ships. See below.
- **Multi-session.** One global herdr session; herdr workspaces are the per-project unit.
- **herdr-plugin-pushes-into-Emacs.** herdr's plugin API could call into Emacs, and
  `ghostel-eval-cmds` already provides the hook. Interesting, but a separate package.

## Decisions and rationale

### Emacs is the only herdr client (not a second client alongside Ghostty)

herdr.el owns one ghostel buffer running the `herdr` client. Rejected alternatives:

- **Second client alongside a terminal herdr.** Focus is server-side state, so focusing a pane
  from Emacs would move focus in the other client too. Combines the problems of the other two
  options.
- **Pure socket controller, TUI stays in Ghostty.** Smallest v1, defers all terminal-embedding
  risk. Retained as the **fallback** if the phase-0 throughput spike fails: only phase 2 changes,
  phases 1 and 3-7 are identical.

### One global session; herdr workspaces are projects

herdr already names workspaces by cwd and persists them across restarts. A session-per-project
scheme would duplicate that concept one level up and split agents across servers, turning "which
agents are blocked" into N queries. `herdr-project` focuses or creates the workspace for
`(project-root)`.

### Curated transient plus a schema-driven escape hatch

herdr exposes 89 methods with a complete, typed JSON Schema. Three options were considered:

- **Thin CLI wrapper** (shell out to `herdr pane split …`). Rejected: ~50ms per spawn, and the
  CLI has no long-lived subscribe, so the event-driven half of the goals dies or degrades to
  polling.
- **Full codegen** of all 89 transient prefixes. Rejected: an 89-entry generated menu is a
  directory listing, not a UI. Generated infixes cannot know that `pane_id` should default to the
  focused pane or offer a labeled picker. Curation would end up layered on top anyway, leaving
  both to maintain.
- **Curated transient + runtime schema** (chosen). ~26 hand-written commands with real
  ergonomics, plus the schema loaded at runtime for two purposes:
  1. `M-x herdr-call` — `completing-read` over all 89 methods, params prompted generically from
     their schema. Full coverage, no generated menus, roughly 120 LOC.
  2. A drift test asserting every curated command's method and params still exist in the live
     schema, so herdr releases surface as a failing test rather than a runtime `not_found`.

## Protocol facts

Established by probing herdr 0.7.5 directly, not from documentation.

| Fact | Consequence for the design |
|---|---|
| **One request per connection.** Server writes the response, then EOF. | No id-correlation table, no multiplexing, no reconnect logic on the command path. Fresh socket per call; unix-socket connect cost is negligible, so no pooling. |
| `events.subscribe` holds the connection open. Acks with `{"id":…,"result":{"type":"subscription_started"}}`, then streams NDJSON event envelopes. | One dedicated long-lived connection, with reconnect-on-EOF. |
| Global subscriptions require no `pane_id`. `pane_created` and `pane_updated` carry full `PaneInfo`, including `agent_status`. | No per-pane subscription bookkeeping — subject to the open question below. |
| `pane.agent_status_changed` and `pane.scroll_changed` subscriptions **require** `pane_id`; `pane.output_matched` requires `pane_id`, `source`, and `match`. | Per-pane subscriptions are the fallback path, not the default. |
| `layout_updated` carries the full layout: pane rects (`x`, `y`, `width`, `height`) and splits. | The mirror model has a data source when we get to it. |
| `pane.current` works with no environment variables — returns the focused pane. | Emacs does not need to inherit herdr pane env. Transient scope can always default correctly. |
| Errors: `{"id":"…","error":{"code":"invalid_request","message":"…"}}`. | Structured; map `code` onto an Emacs condition. |
| `ping` returns `{"version","protocol","capabilities":{"live_handoff":true,"detached_server_daemon":true}}`. | Feature-detect via capabilities rather than version-sniffing. |
| Enums: `ReadSource` = `visible｜recent｜recent_unwrapped｜detection`; `ReadFormat` = `text｜ansi`; `SplitDirection` = `right｜down`; `AgentStatus` = `idle｜working｜blocked｜done｜unknown`. | Drive infix `:choices` from the schema. |
| 25 event kinds; 89 methods; 104 request param definitions. | Schema is complete enough for generic param prompting. |
| CLI's `herdr pane run` has no API method. | Implement as `pane.send_text` with a trailing newline. |

### Open question, to be settled by spike, not by assumption

Whether `pane_updated` fires on **agent status** transitions specifically. The probe pane held no
agent, so only `pane_agent_detected` was observed. If `pane_updated` does not cover status
changes, the fallback is per-pane `pane.agent_status_changed` subscriptions maintained against
`pane_created` and `pane_closed` — more bookkeeping, identical result. Resolved in phase 0,
before `herdr-agents.el` is written.

## Architecture

```
Emacs
├── *herdr* ghostel buffer ── PTY ── herdr client (renders TUI)
│                                         │
├── herdr-rpc  ── one-shot unix socket ───┤
└── herdr-state ── long-lived socket ─────┴── herdr server
                    (events.subscribe)
```

Two independent channels to the same server. Transient issues an RPC, the server mutates state,
the client repaints inside the ghostel buffer, and the event stream tells Emacs what changed.

### Modules

Each file has one purpose and a stated dependency direction. Nothing depends upward.

| File | Purpose | Depends on |
|---|---|---|
| `herdr-rpc.el` | Socket transport, NDJSON framing, one-shot call (sync + async), error mapping | — |
| `herdr-schema.el` | Load and cache `herdr api schema --json`; generic param prompting; drift-test support | `herdr-rpc` |
| `herdr-state.el` | Snapshot cache, event connection, reducer, change hook | `herdr-rpc` |
| `herdr.el` | Entry point, ghostel buffer and session lifecycle, autoloads | all |
| `herdr-cmd.el` | The ~26 curated command wrappers | `herdr-rpc`, `herdr-state` |
| `herdr-select.el` | `completing-read` pickers, marginalia annotators, embark keymaps, consult source | `herdr-state` |
| `herdr-transient.el` | Transient prefixes | `herdr-cmd`, `herdr-select` |
| `herdr-agents.el` | `*herdr-agents*` buffer and modeline segment | `herdr-state` |

### herdr-rpc

`herdr-rpc-call` opens `make-network-process :family 'local`, writes one JSON line, reads to EOF,
parses with `json-parse-string`. Because the protocol is one-shot, the synchronous path is honest
— there is no pending async reply that could interleave. An async variant takes a callback, used
for anything that blocks server-side: `agent.wait`, `pane.wait_for_output`.

### herdr-state

Holds one snapshot — workspaces, tabs, panes, agents, layouts — hydrated by `session.snapshot` at
connect and then mutated incrementally by the event stream. Exposes a single
`herdr-state-change-hook`, called with the event kind.

Everything downstream (modeline, agents buffer, pickers) reads the cache and never issues its own
RPC. `herdr-state-resync` forces a fresh snapshot; the event reader calls it automatically after
any reconnect, because events missed during a gap cannot be replayed and incremental state is
untrustworthy afterward.

The reducer is a pure function of (state, event) so it can be tested without a socket.

## Command surface

### Transient

Magit-style root prefix with sub-prefixes. The prefix carries a **scope** — the target pane —
shown in the header, defaulting to `pane.current`. `C-u` or an infix retargets via picker. This
defaulting and labeling is precisely what codegen cannot do, and is the justification for the
curated layer.

```
M-x herdr        [w1:p1  web/1  claude:idle]
 Navigate            Pane  (p)        Agent  (a)
  j pane              s split right    p prompt
  J agent             S split down     r read → buffer
  w workspace         k close          w wait until…
  t tab               z zoom           s start
                      = resize         e explain
 Session             Tab   (t)        Workspace (w)
  g resync            c create         c create
  a attach/detach     k close          k close
  ? status            r rename         r rename
                                       W worktree (W)
 x  any method…  (herdr-call, all 89)
```

Roughly 26 curated commands. Three worth calling out:

- **`worktree.*`** — herdr has native git-worktree support (`list`, `create`, `open`, `remove`).
  Creating a worktree and its herdr workspace in one command is expected to be the highest-value
  command in the package.
- **`pane.read` into a buffer** — `recent_unwrapped` is the source you want for grepping;
  `ansi-color-apply-on-region` when `format` is `ansi`.
- **`agent.wait`** — async and callback-driven, so it does not block Emacs. Notification fires on
  transition.

### Pickers

Plain `completing-read` over the state cache. Candidates are pane ids; a `marginalia` annotator
renders label, cwd, agent, and status, so `orderless` makes `web claude blocked` a valid query.
An `embark` keymap on the `herdr-pane` category makes `embark-act` open the pane transient scoped
to that candidate. A `consult-herdr` source is added to `consult-buffer-sources`.

No bespoke UI: roughly 80 lines of annotator and keymap over the user's existing
vertico/consult/embark/marginalia/orderless stack.

## ghostel integration

`M-x herdr` is idempotent and, in order: pings the socket; starts the server if dead; ensures a
`*herdr*` ghostel buffer is running the `herdr` client; connects the event stream; displays the
buffer.

**Window policy.** herdr renders a 26-column sidebar plus panes, so a narrow window leaves it
very little room. `herdr-display-action` defaults to `(display-buffer-full-frame)` and can be
rebound to a side window or dedicated frame. ghostel propagates resize to the PTY so herdr reflows, but the
sidebar width does not shrink.

**Detach** is killing the ghostel buffer. The server survives (`detached_server_daemon: true`).
Reattach with `M-x herdr`.

**Handoff is unresolved.** `live_handoff: true` is advertised, and both a `server.live_handoff`
method and `herdr agent attach --takeover` exist. What happens when Emacs attaches while another
client is already attached — takeover, coexistence, or refusal — is a phase-0 spike, deliberately
not specified here.

## Notifications

- **Modeline segment**, always on. `herdr:2⏸1✓` derived from the state cache, in
  `global-mode-string`. No RPC; updates on `herdr-state-change-hook`. Clicking opens the agents
  buffer.
- **`*herdr-agents*` buffer**, the thing you open. `magit-section` tree: workspaces → tabs →
  panes, with agent and status per row. `RET` focuses the pane, `p` prompts it, `r` reads it.
  Event-driven refresh, no timer.
- **Desktop banner**, opt-in via `herdr-notify-statuses`, default `nil`. Soft-depends on
  `alert.el` when present, otherwise a small `notifications-notify` fallback. No hard dependency.
- Echo-area messages and sound are off by default and configurable.

herdr's own `notification.show` renders inside herdr's UI and is treated as redundant with the
Emacs-side path.

## Error handling

A single condition, `herdr-error`, carries the server's `code` so callers branch on `not_found`
versus `invalid_request` rather than parsing message strings.

| Failure | Behavior |
|---|---|
| Socket missing or connection refused | Not an error for `M-x herdr` — it offers to start the server. Other commands signal "herdr not running". |
| Protocol version ≠ 17 | Warn once per session with both versions and continue. Refusing to run on a minor bump is worse than one broken command. |
| `{"error":{…}}` response | Signal `herdr-error` with code and message. |
| `not_found` on a cached pane id | Auto-resync once and retry. A stale cache is expected, not user-facing. |
| Event stream EOF | Reconnect with backoff (1s → 30s), then full resync. |
| ghostel buffer killed | Detached state, not an error. Reflected in the segment; server keeps running. |
| Schema cache stale | Keyed on the version reported by `ping`; a version change invalidates it. |

## Testing

**Hermetic unit tests, no herdr required.** Emacs acts as the server via
`make-network-process :server t :family 'local` on a temp socket, replaying canned NDJSON. This
covers RPC framing, one-shot EOF semantics, error mapping, event parsing, and state reduction.
Fixtures are real captures taken during design, including a genuine `invalid_request` error
response (missing required `pane_id` on a `pane.agent_status_changed` subscription) and the
`subscription_started` ack.

**Reducer regression test.** Feed the recorded event sequence captured during design (30 events
across a split/rename/send-text/close cycle) into the pure reducer and assert the resulting cache
equals the `session.snapshot` taken afterward.

**Live tests, tagged `:live`, skipped by default:**

- **Drift test** — every curated command's method and params still exist in
  `herdr api schema --json`. This is what keeps 26 hand-written wrappers honest across herdr
  releases.
- **Round-trip** — split, rename, send text, read it back, close; assert the session is left
  exactly as found.

## Phases

Phase 0 gates everything else.

| # | Phase | Gate |
|---|---|---|
| 0 | Spikes: VT throughput; handoff semantics; whether `pane_updated` carries agent-status transitions | Answers recorded before any code |
| 1 | `herdr-rpc`, `herdr-schema`, `herdr-state`, hermetic tests | Reducer test green |
| 2 | `herdr.el` entry point, ghostel buffer, lifecycle | `M-x herdr` attaches |
| 3 | `herdr-cmd`, `herdr-select` | Pickers work with marginalia and embark — goals 3 and 4 complete |
| 4 | `herdr-transient` | Daily-usable — goal 1 complete |
| 5 | `herdr-agents`, modeline segment | Goal 2 complete |
| 6 | `herdr-call`, drift test | All 89 methods reachable |
| 7 | README, package headers, autoloads | Publishable |

### Phase 0 spike detail

1. **VT throughput.** Dump a large build log into a herdr pane with herdr running inside ghostel.
   Two VT layers (herdr's VT → PTY → libghostty-vt) are on the critical path. Failure here means
   falling back to the socket-only controller; only phase 2 changes.
2. **Handoff.** Attach from Emacs while the Ghostty client is attached. Determine whether it takes
   over, coexists, or is refused, and what `server.live_handoff` and `--takeover` actually do.
3. **Agent status events.** Run a real agent, watch the global stream, determine whether
   `pane_updated` carries status transitions or whether per-pane subscriptions are required.

## Mirror model — deferred spike

Deferred until after phase 7. `herdr agent attach <TARGET> [--takeover]` exists, and
`layout_updated` publishes pane rects and splits, so the necessary inputs are present. The spike
must answer:

- Does `agent attach <target>` render a single pane standalone, or the whole session?
- Can N ghostel buffers attach simultaneously to one server?
- Does `--takeover` steal the pane or share it?
- Is driving Emacs window splits from `layout_updated` tolerable, or visually chaotic?

Design happens after those answers, not before.

## Packaging

Personal use first, published to GitHub when good. Structured for that from the start: proper
package headers, multi-file layout, ERT tests, README. No CI or MELPA recipe until publication.
Path: `~/src/herdr.el/`.

Runtime dependencies: Emacs 28.1+ (floor set by ghostel's dynamic-module requirement; `transient`
and `json-parse-string` are both available by then), `transient`, `ghostel`. Soft: `magit-section`, `marginalia`,
`embark`, `consult`, `alert`. No hard dependency on anything not already installed.
