# Protocol notes

This document records the behaviour of the herdr server. Most of it is not written down
anywhere else.

Two sources give the facts here. The first source is measurement against a live server. The
second source is the herdr source code at
[herdrdev/herdr](https://github.com/herdrdev/herdr), which Homebrew names in its formula.

Some early findings were wrong. This document keeps a wrong finding visible with a strikethrough
and puts the correction next to it. If you delete a wrong finding, the next reader derives it
again from the same weak evidence. Four wrong findings survived here for that reason.

## Identifiers

**herdr ids are per-server counters.** Measured against a herdr 0.8.2 server with `herdr api
snapshot`: workspace ids read `w2F`, tab ids `w2F:t2`, pane ids `w2F:p2`. One server was
measured, so the measurement alone would not carry the next point.

**They are scoped to one server.** herdr 0.9.0's multi-machine guide states that workspace, tab
and pane ids and agent names are scoped to a single server, and that two machines may each hold
a `w1:p1`. So a structure keyed by a bare id is ambiguous the moment a client follows more than
one server, and the key has to carry the server with it.

## Transport

**One request for each connection.** The server writes one response, then closes the socket.
Do not send a second request on the same connection. There is no multiplexing and no correlation
by identifier.

**A request identifier must be a string.** An integer gives you this error:

```
invalid request: invalid type: integer `1`, expected a string
```

The error arrives on the same connection that a subscription acknowledgement uses. It is
therefore easy to read an error as an empty replay.

**Array parameters must be vectors.** The Emacs function `json-serialize` cannot tell a list of
alists from one alist. A list gives you a rejected `events.subscribe`.

## A forwarded socket

Measured on 2026-09-14: a macOS client against a Fedora server running herdr 0.9.0, forwarded
with `ssh -N -L /tmp/herdr-probe.sock:<remote socket> <target>`.

**The forward carries the protocol unchanged.** `ping` answered `protocol 22`,
`session.snapshot` returned the remote's panes and workspaces, and `herdr-rpc-call` needed no
change to speak through it. Ask the remote for the path rather than composing one: `ssh <target>
herdr session list --json` names `socket_path` per session. A path written with `$HOME` is
expanded by the local shell, so a macOS client forwards `/Users/...` to a Linux server and the
probe fails for a reason that has nothing to do with the tunnel.

**A subscription survives an idle period.** `events.subscribe` was held for 180 seconds with no
traffic, the process stayed open, and a `workspace.rename` made afterwards arrived on the same
subscription. Neither side sets `ServerAliveInterval` or `ClientAliveInterval`, so nothing at the
SSH layer tears an idle channel down. The subscription also began with no history at all, the
same as a local one on 0.9.0.

**SELinux blocks the forward before it blocks anything else.** On a Fedora server the socket under
`~/.config/herdr` is labelled `config_home_t`, and `sshd-session` may not write it, so every
connection through the tunnel fails. The audit log names it; the SSH client only says
`channel N: open failed: connect failed: open failed`. A socket under `/tmp` is labelled
`user_tmp_t` and forwards without complaint, and `chcon -t user_tmp_t <socket>` needs no
privilege. The label does not survive a server restart, because the socket is recreated.

### What a failure looks like from the client

`ExitOnForwardFailure` does not help. OpenSSH binds the local socket when the tunnel is set up
and only dials the remote socket when something connects to the local one, so a forward to a
socket that cannot be reached still looks like a healthy start.

| Situation | Local socket | `herdr-rpc-call` | SSH client says |
|---|---|---|---|
| Healthy | bound | the answer | nothing |
| Remote socket missing, server stopped, or SELinux denying | bound | `empty_response` | `channel N: open failed: connect failed: open failed` |
| Tunnel died, socket file left behind | present, stale | `no_server`, `Connection refused` | nothing, the process is gone |
| Authentication or host failure | **absent** | `no_server` | `Permission denied`, exit 255 |

The first two rows are what a client can act on. `empty_response` means the tunnel is up and the
far end is not answering, which is a retry. `no_server` means nothing is listening locally, which
is a tunnel to rebuild. An authentication failure is the one case that leaves no socket at all,
so it is distinguishable from both, which is what makes an unreachable remote worth telling apart
from a misconfigured one.

A server that stops removes its own socket file, so a stopped server and a wrong path are the
same row. They need the same response, so nothing is lost by not telling them apart.

**A dropped tunnel reaches the client as an ordinary disconnect.** Killing the SSH process while a
subscription was open fired the process sentinel with `connection broken by remote peer` and
status `closed` - the same signal a local server dropping produces, which is what the reconnect
logic already handles.

## The event stream

`events.subscribe` is the one long-lived call. It acknowledges with
`{"result":{"type":"subscription_started"}}` and then streams.

### The server replayed its full event ring, until 0.9.0

**Since herdr 0.9.0 there is no replay.** A subscription starts at the sequence its request
arrived on, so it sees what happens from then and nothing older. Events emitted while the
subscription is still being set up are kept, which upstream pins with a test named
`lifecycle_subscription_skips_history_but_keeps_setup_window_events`.

The rest of this section is what 0.8.2 did. It stays because the client still carries defences
built for it, and because deleting a finding only means the next reader derives it again.

Through 0.8.2 the server held a ring of 512 events and gave a new subscriber **all of them**,
dripped out at one event for each subscribed type every 100 milliseconds.

Two earlier readings of that were wrong:

- ~~`events.subscribe` answers with the last retained event of each subscribed type, and nothing
  older.~~
- ~~A subscription to an idle server returned 54 past events. A real start produced about 150.~~

Both readings measured inside a window that was shorter than the replay. An earlier count of
"8 events in 4 milliseconds" was the first tick only.

The cause was in `src/api/subscriptions.rs`. In 0.8.2 each plain event subscription started at
sequence zero, in about two dozen identical arms:

```rust
// herdr 0.8.2
Subscription::PaneCreated {} => Ok(Self::Event(ActiveEventSubscription {
    event_kind: EventKind::PaneCreated,
    last_sequence: 0,                       // replays the whole ring
})),
```

The per-pane subscription was already correct, which is why connection B never made ghost panes
and connection A always did:

```rust
Subscription::PaneAgentStatusChanged { .. } => {
    let last_sequence = event_hub.current_sequence();   // starts at now
```

This document called that a fault rather than a design choice, and said the correction was one
line for each arm. 0.9.0 made it. The two dozen arms became one helper taking a start sequence
the caller captures when the request arrives:

```rust
// herdr 0.9.0
let event_subscription = |event_kind| {
    Self::Event(ActiveEventSubscription {
        event_kind,
        last_sequence: event_start_sequence,   // captured at request arrival
    })
};
```

Measured against a live 0.8.2 server, with the 18 subscriptions that herdr.el uses: 253 events
in 5 seconds, and the stream had not stopped. The ring still held events from workspaces that
closed hours before. The `pane.created` events outlasted the `pane.closed` events, so some
replayed panes got no closing event and stayed until the next `pane.list` reconcile. For one or
two seconds after `M-x herdr`, the dashboard showed dead panes with the status `unknown`.

A client could not remove the replay, which is why herdr.el reconciles rather than filters.
`EventEnvelope` serializes to `{event, data}` and carries no sequence number and no timestamp,
so a replayed event has the same shape as a live one; `events.wait` used the same constructor
and inherited the same fault; and `events.subscribe` accepts `subscriptions: [{type}]` only,
with no cursor. None of that changed in 0.9.0. What changed is that there is no history to tell
apart.

**What the removal cost the client.** The replay used to cover the window between
`session.snapshot` and the subscribe in `herdr-state-start`. Nothing covers it now, so the
settle reconciles workspaces as well as panes. Order and focus are not restored by either list
call; see `herdr-state--settle`.

### `pane_updated` is coupled to output

~~Three per-pane events produced one `pane_updated` event, so the events coalesce.~~ They do not
coalesce. `pane_updated` fires about 7.5 times each second and carries a full `PaneInfo` record,
with `agent_status` inside it.

The event is tied to the title and to the output. It therefore stops exactly when an agent
becomes idle, and that is the transition that matters. The measured lag from the per-pane event
to the global stream was 6.18 seconds and 31.79 seconds.

herdr.el does not subscribe to `pane_updated`. Connection B carries the statuses. The function
`herdr-state-reconcile-panes` carries the rest.

### Rename and move events are flat

These events carry no nested record. Read the fields directly.

| Event | Fields |
|---|---|
| `workspace_renamed` | `{workspace_id, label}` |
| `tab_renamed` | `{workspace_id, tab_id, label}` |
| `workspace_moved`, `tab_moved` | `{id, insert_index, <array of fresh records>}` |
| `pane_agent_detected` | `{pane_id, workspace_id, agent?, final_status?, released?}` |

herdr.el read a `workspace`, `tab` or `pane` object out of these events. The events were
therefore dropped without an error.

The `tab_*` rows are the server's behaviour. herdr.el subscribes to no `tab.*` event and models
no tab; the rows stay because this document records the server, not the client.

## Panes and agents

**`terminal attach` streams one pane at full screen.** It works next to a session client. It is
exclusive for each pane. ~~An older verb, `agent attach`, refused a pane that has no agent, and
returned `agent_not_found`. That refusal was the reason a pane had to be reported first.~~ Since herdr
0.8.2, `terminal attach` takes any pane, agent or plain shell alike. There is no longer a class
of pane it refuses.

**The attach client needs a window.** The client dies if you delete its window. The client
survives if you only hide the window, so a buried terminal keeps its scrollback. A PTY of zero
size draws nothing.

**Detection relabels on a transition, not on demand.** ~~`pane.report_agent` takes lifecycle
authority, so a reported pane keeps its label.~~ ~~Reporting and detection operate
independently, and detection wins.~~ Two measurements, both reproduced, and neither generalises
to the other:

- Start Claude in a pane already reported as `shell`, and herdr relabels it `claude` about 3
  seconds later.
- Report `shell` on a pane where Claude is *already* running, and the label stays `shell`
  indefinitely. `agent.explain` answers `claude`, with a matched rule and a live session id,
  while the pane record goes on carrying the report. Two panes, hours apart.

One reading fits both. A relabel rides on the agent starting, not on the state being wrong, so a
report applied after the fact is never revisited. That is a hypothesis. What is certain is that
the second case does not correct itself and cannot be made to.

Releasing the report does not help. The pane then has no agent at all, watched for 25 seconds,
and `agent.explain` refuses it with `agent_not_found`. That method runs only against panes herdr
already counts as agents. Killing the pane is the cure.

This matters less than it reads. Nothing in herdr.el reports an agent on its own, so the first
case is the one that happens. Open a pane, start an agent in it, get the right label. The second
case is a stale report, and
[Troubleshooting](troubleshooting.md#a-pane-is-labelled-shell-but-is-running-an-agent) says what
to do about it.

Every pane also carries `agent_session`, which named `claude` correctly on both stale panes.
Nothing in herdr.el reads it.

~~**`pane.report_agent` makes a plain shell pane attachable.**~~ Every pane is attachable since
herdr 0.8.2, independent of `pane.report_agent`.
Reporting only gives a pane an entry in herdr's own agent list: the sidebar, and the events
`pane.agent_status_changed` subscribes to.

**Focus is shared.** The session has one focused pane, not one for each client. When you move
the focus in Emacs, the focus moves in every attached TUI.

**`done` does cross the socket API.** The `AgentStatus` enum lists it and the server sends it.
Measured against a live protocol 22 server by driving a real agent: the pane went
`idle` → `working` → `done` on `session.snapshot`, and focusing it put it back to `idle`. The
workspace rollup carries the same value. Re-measure before trusting this: it was the opposite on
0.9.0, where `agent.list`, `agent.get` and `pane.agent_status_changed` reported only `idle`,
`working`, `blocked` and `unknown`, and herdr expected each client to derive `done` from its own
seen state.

So the seen state is herdr's now, not the client's. `idle` and `done` still both mean ready for
input, and what tells them apart — whether anybody has looked — is tracked server-side and shared
by every attached client. The schema exposes `seen` as an agent-view field for the same reason.

herdr.el therefore stores what it is sent. It used to derive `done` in
`herdr-state--track-seen`, promoting a `working` → `idle` transition and clearing it on
`pane_focused`. That code was removed once the server's own arc was measured, and it had already
stopped firing: the server goes `working` → `done` directly and never passes through the `idle`
that the promotion waited for.

**There is no `agent_renamed` event.** The event schema carries `workspace_renamed` and
`tab_renamed` and nothing for an agent, so `agent.rename` is announced only in its own reply, which
returns the whole `AgentInfo`. A client caching names has to fold that in or wait for the next
`session.snapshot` — and `agents`, the only array carrying a name, comes from the snapshot alone.

**An absent `name` clears one.** `agent.rename` with only a target leaves the agent unnamed in the
next snapshot, which is what the CLI's `--clear` does; an empty string is refused as
`invalid_agent_name`. Names must start with a lowercase letter and hold only lowercase letters,
digits, `-` or `_`, are 1-32 long, and are unique per server — a second agent taking one answers
`agent_name_taken`. A cleared name stops resolving: the old name then answers `agent_not_found`.
All measured on 0.9.0.

**A blocked agent cannot be prompted.** `agent.prompt` answers `agent_blocked` — "agent NAME is
blocked and requires interactive input" — and sends nothing. Measured on 0.9.0, and the check runs
before the one below, so it is what a blocked agent answers whatever else is true of the pane.
A question waiting on screen is therefore never answered by accident; `agent.send_keys` is the
verb for that.

**`agent.prompt` and `agent.send_keys` need a live agent, not a reported one.** A plain shell that
`pane.report_agent` has labelled is enough for the agent list, the sidebar and
`pane.agent_status_changed`, and not enough for these two: they answer `agent_not_ready`, with
"no longer the pane foreground process" and "is not an active named agent" respectively.

**`agent.wait` on `done` can only ever time out.** `--until` accepts every `AgentStatus`, and the
server never enters `done` (see above), so `agent.wait --until done` waits out its deadline and
returns `timeout`. Measured. Without `--until`, herdr matches idle, done or blocked — which is
why the default works: `idle` is in it. herdr also documents that `--wait` on a prompt does not
track turns, so prompting an agent that is already working may match that earlier turn finishing.

**herdr tells a pane what it is.** Every pane it starts carries `HERDR_ENV=1`, `HERDR_PANE_ID`,
`HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_SOCKET_PATH` and `HERDR_BIN_PATH`. Read out of a live
pane on 0.9.0, so a process inside a pane can name itself without asking the server anything, and
an Emacs started from one can find the session it belongs to rather than assuming the default.

**A workspace closes with its last pane.** A workspace with zero panes therefore cannot exist.
That fact is the reason `herdr-new-terminal` offers `project.el` roots beside the open
workspaces: the server knows nothing about a project you are not working in right now.

## Throughput and terminals

**Throughput is not a concern.** A pane dump of 12.2 MB reached Emacs as 24 KB, and finished in
0.2 seconds. The VT of herdr emits the differences of the visible frame only.

**OSC sequences do not pass through.** The VT of herdr consumes OSC 7 and OSC 133. Beware of a
false positive here: when you send the escapes inline, the shell echoes the command text, and
that text holds the same characters.

**herdr tracks the working directory itself.** The field `pane.cwd` follows a `cd` within about
one second. But the server sends no event for the change. A `cd` emits `layout_updated` only, so
a client must poll.

**Terminal titles animate.** Claude puts a spinner glyph and a second counter in the title.
The field `terminal_title_stripped` therefore changes several times each second: 662 of 662
`pane_updated` events differed in it, against 11 that differed in `agent_status`. Treat the
field as volatile. Do not treat it as a label when you compare two panes.

**`pane.read` nests its text.** The text is under a `read` object. It is not a top-level field.

**Attachment is exclusive, and the exit status will not tell you why it ended.** Measured against
0.9.0 with two clients on one terminal. A second `herdr terminal attach` is refused while another
client holds the terminal; `--takeover` takes it and the client that held it is stopped, not asked.
All three endings — refused, taken over, and the pane closing under a healthy attach — exit **1**,
so the status separates none of them. The text does:

| Ending | Written to the terminal |
|---|---|
| Refused | `terminal attach failed: terminal <id> already has an attached client; retry with --takeover` |
| Taken over | `herdr: server shut down: terminal attach taken over` |
| Pane closed | nothing from herdr — only whatever the program last printed |

`--takeover` goes after the terminal id; before it, the id is rejected as an unknown option. And
nothing in the socket API reports which terminals have a client: `attach`, `client` and `takeover`
appear in no method or field, so a client cannot ask first and can only read what it is told on
the way out.

**An attach needs a sized PTY.** With no controlling terminal it fails `Inappropriate ioctl for
device`, and with a terminal of zero size it fails `terminal reported a zero-sized grid`. This is
why a buffer has to be displayed before its client starts.

## How to read the herdr source

```bash
curl -sSL -o herdr.tar.gz https://github.com/herdrdev/herdr/archive/refs/tags/v0.9.0.tar.gz
tar xzf herdr.tar.gz herdr-0.9.0/src/api
```

Three files answer most questions:

- `src/api/subscriptions.rs` holds the subscription types and the replay behaviour.
- `src/api/event_hub.rs` holds the 512-event ring.
- `src/api/server.rs` holds the connection loop and the 100 millisecond tick.

The source answers a protocol question faster than measurement does, and it answers without
ambiguity. The replay finding above came from twenty minutes there, after two wrong readings
from measurement.
