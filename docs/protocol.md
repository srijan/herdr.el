# Protocol notes

This document records the behaviour of the herdr server. Most of it is not written down
anywhere else.

Two sources give the facts here. The first source is measurement against a live server. The
second source is the herdr source code at
[herdrdev/herdr](https://github.com/herdrdev/herdr), which Homebrew names in its formula.

Some early findings were wrong. This document keeps a wrong finding visible with a strikethrough
and puts the correction next to it. If you delete a wrong finding, the next reader derives it
again from the same weak evidence. Four wrong findings survived here for that reason.

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

**A workspace closes with its last pane.** A workspace with zero panes therefore cannot exist.
That fact is the reason that the `Inactive` section of the dashboard comes from `project.el` and
not from the server.

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
