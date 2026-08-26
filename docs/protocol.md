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

### The server replays its full event ring

The server holds a ring of 512 events. It gives a new subscriber **all of them**. It drips them
out at one event for each subscribed type every 100 milliseconds.

Two earlier readings of this were wrong:

- ~~`events.subscribe` answers with the last retained event of each subscribed type, and nothing
  older.~~
- ~~A subscription to an idle server returned 54 past events. A real start produced about 150.~~

Both readings measured inside a window that was shorter than the replay. An earlier count of
"8 events in 4 milliseconds" was the first tick only.

The cause is in `src/api/subscriptions.rs` of herdr 0.8.2. Each plain event subscription starts
at sequence zero. Line 179 shows one of about two dozen identical arms:

```rust
Subscription::PaneCreated {} => Ok(Self::Event(ActiveEventSubscription {
    event_kind: EventKind::PaneCreated,
    last_sequence: 0,                       // replays the whole ring
})),
```

Line 259 shows the per-pane subscription, which is correct:

```rust
Subscription::PaneAgentStatusChanged { .. } => {
    let last_sequence = event_hub.current_sequence();   // starts at now
```

This is a fault in herdr, not a design choice. The correction is one line for each arm. It also
explains why connection B never makes ghost panes and connection A always does.

Measured against a live 0.8.2 server, with the 23 subscriptions that herdr.el uses: 253 events
in 5 seconds, and the stream had not stopped. The ring still held events from workspaces that
closed hours before. The `pane.created` events outlast the `pane.closed` events, so some
replayed panes get no closing event. Those panes stay until the next `pane.list` reconcile.

A client cannot remove the replay. Three facts block every method:

1. `EventEnvelope` serializes to `{event, data}`. It carries no sequence number and no
   timestamp. A replayed event therefore has the same shape as a live event.
2. `events.wait` uses the same constructor. It inherits the same fault, so it matches historical
   events.
3. `events.subscribe` accepts `subscriptions: [{type}]` only. There is no cursor.

The visible effect: for one or two seconds after `M-x herdr`, the dashboard shows dead panes with
the status `unknown`. The next reconcile removes them.

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

## Panes and agents

**`terminal attach` streams one pane at full screen.** It works next to a session client. It is
exclusive for each pane. ~~An older verb, `agent attach`, refused a pane that has no agent, and
returned `agent_not_found`. That refusal was the reason that adoption existed.~~ Since herdr
0.8.2, `terminal attach` takes any pane, agent or plain shell alike. There is no longer a class
of pane it refuses.

**The attach client needs a window.** The client dies if you delete its window. The client
survives if you only hide the window, so a buried terminal keeps its scrollback. A PTY of zero
size draws nothing.

**Detection outranks a reported agent.** ~~`pane.report_agent` takes lifecycle authority, so an
adopted pane keeps its label.~~ That was true of an older herdr. Reporting and detection now
operate independently, and detection wins. Measured: herdr relabelled a pane reported as `shell`
to `claude` about 3 seconds after Claude started in it.

~~**`pane.report_agent` makes a plain shell pane attachable.** That is the mechanism of
adoption.~~ Every pane is attachable since herdr 0.8.2, independent of `pane.report_agent`.
Reporting only gives a pane an entry in herdr's own agent list — the sidebar, and the events
`pane.agent_status_changed` subscribes to.

**Focus is shared.** The session has one focused pane, not one for each client. When you move
the focus in Emacs, the focus moves in every attached TUI.

**A workspace closes with its last pane.** A workspace with zero panes therefore cannot exist.
That fact is the reason that the `Inactive` section of the dashboard comes from `project.el` and
not from the server.

## Throughput and terminals

**Throughput is not a concern.** A pane dump of 12.2 MB reached Emacs as 17 KB under the
`session` backend. The same dump reached Emacs as 24 KB under the `agent-windows` backend.
Both finished in 0.2 seconds.
The VT of herdr emits the differences of the visible frame only.

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
curl -sSL -o herdr.tar.gz https://github.com/herdrdev/herdr/archive/refs/tags/v0.8.2.tar.gz
tar xzf herdr.tar.gz herdr-0.8.2/src/api
```

Three files answer most questions:

- `src/api/subscriptions.rs` holds the subscription types and the replay behaviour.
- `src/api/event_hub.rs` holds the 512-event ring.
- `src/api/server.rs` holds the connection loop and the 100 millisecond tick.

The source answers a protocol question faster than measurement does, and it answers without
ambiguity. The replay finding above came from twenty minutes there, after two wrong readings
from measurement.
