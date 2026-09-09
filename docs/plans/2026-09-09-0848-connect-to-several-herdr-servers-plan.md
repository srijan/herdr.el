---
title: Connect to Several herdr Servers - Plan
type: feature
date: 2026-09-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Connect to Several herdr Servers - Plan

## Goal Capsule

- **Objective:** A person running herdr.el connects to a herdr server on another machine when they ask for it, sees its workspaces beside their local ones in one dashboard, opens a terminal into a remote pane, and keeps working on the machines that are still reachable when one is not.
- **Means:** Make a connection a value the package passes around (KTD1), give every id a server (KTD2), forward each remote control socket over SSH to a local one (KTD3), reach remote terminals through TRAMP rather than the tunnel (KTD4), and connect only when asked (KTD5).
- **Authority:** The Requirements win on behaviour. The Key Technical Decisions win on mechanism. `jsonrpc.el` and `eglot.el` win on how Emacs packages carry a connection. `docs/architecture.md` and `CONTRIBUTING.md` win on house style.
- **Execution profile:** Test-first, as `CONTRIBUTING.md` requires. Each unit lands as one commit. The suite must be green at every unit boundary, and the local-only path must keep working at every one of them.
- **Stop conditions:** Stop and ask if a unit cannot keep the single-server path working unchanged. Stop if SSH socket forwarding turns out not to carry the herdr protocol.
- **Tail ownership:** This plan ends when several servers can be followed at once. It does not make herdr.el a herdr client in the sense the terminal UI is one.

---

## Product Contract

### Summary

herdr.el assumes one server throughout. One socket path, one event stream pair, one worktree cache, and structures keyed by ids that are only unique within a server. This plan makes the connection an explicit value, gives each id the server it came from, and adds a way to reach a server on another machine over SSH. Connections are made on request and then kept, never at startup.

### Problem Frame

**One socket is assumed everywhere.** `herdr-socket-path` is a single `defcustom` that `herdr-rpc-connect` expands and connects to. Every call in the package reaches the server through it, so there is no place to say which server a call is for.

**Ids are per-server counters.** A workspace id reads `w2F`, a pane id `w2F:p2`, a tab id `w2F:t2`. herdr 0.9.0's own multi-machine guide states the consequence: ids and agent names are scoped to one server, and two machines may each hold a `w1:p1`. Every structure in this package keyed by a bare id becomes ambiguous the moment a second connection exists — the pane-to-buffer alist, the worktree cache, the dashboard's nesting walk, and every picker.

**herdr's own multi-machine feature does not help a socket client.** 0.9.0 added `herdr machine`, which lets its terminal UI show several machines at once. It is a client and CLI feature: the socket API has no `machine` method, and each machine keeps its own server, its own session and its own socket. A socket client that wants several servers still has to open several sockets. What the feature does give this package is a catalog worth reading rather than a configuration format worth inventing.

**A remote control socket cannot be reached the way a remote terminal can.** `make-process` honours file handlers, so a TRAMP `default-directory` is enough to run a process on another machine — which is how the terminal side already works, through ghostel. `make-network-process` has no file-handler support at all, so the control plane cannot follow. The two halves of a remote server therefore need different mechanisms, and only the control plane needs a tunnel.

**Startup must not wait on the network.** Connecting to every configured server when Emacs starts makes a laptop opening in a cafe slow to a stack of SSH timeouts, and makes `herdr-start` fail for reasons that have nothing to do with the local server.

### Key Decisions

- **Several servers at once, in one dashboard.** (session-settled: user-directed - chosen over switching between servers one at a time and over a single permanent remote: the point is seeing where work is running, which a switch hides.) Governs R1, R6.
- **Remote means a herdr server on another machine, reached over SSH.** (session-settled: user-directed - chosen over herdr's named local sessions, and over staging local-multi first.) Governs R2, R3.
- **herdr.el manages the SSH tunnel itself.** (session-settled: user-directed - chosen over requiring the user to set up forwarding and over proxying each call through an `ssh` process: a per-call proxy pays process startup on every request, and user-managed forwarding makes the failure a support question rather than something the package can report.) Governs R3, R9.
- **No connection is made at startup. A connection is made when asked for and then kept.** (session-settled: user-directed.) Governs R4, R5.
- **This plan follows the 0.9.0 upgrade and the ownership refactors.** (session-settled: user-directed.) Both are prerequisites rather than conveniences: the refactors reshape the id-keyed structures this plan would otherwise widen twice. Governs R7.

### Requirements

- R1. A user sees the workspaces of every connected server in one dashboard, each attributable to its server.
- R2. A user adds a remote server by naming an SSH target, and reaches its panes as terminals.
- R3. A remote server's control socket is reachable without the user configuring SSH forwarding.
- R4. No connection is attempted until the user asks for one.
- R5. A connection that drops is retried while the user still wants it, and stops being retried when they disconnect it.
- R6. A server that is unreachable degrades only itself. Every other server stays usable, the local one included.
- R7. Every structure keyed by an id distinguishes two servers that issued the same id.
- R8. A command acts on the server the object at point came from, not on a global current server.
- R9. A failure to connect says which server, and says what failed, in terms a user can act on.
- R10. A user who has one local server sees no new configuration and no behaviour change.

### Scope Boundaries

- The local server keeps working with no configuration. It becomes one connection in a registry whose default holds exactly it.
- Reading herdr's saved-machine catalog is a source of server definitions, not a dependency. A user who does not use `herdr machine` names a target directly.
- The dashboard groups by server. It does not gain a machine-switching mode, because showing several at once is the point.

#### Deferred to Follow-Up Work

- Writing to the machine catalog. This plan reads it; `herdr machine add` remains the way to create one.
- Anything the 0.9.0 upgrade left the terminal UI doing that a socket client cannot: surface interest, health probes, and the client-shell methods.

#### Outside this plan's identity

- Any change to the herdr server or to the socket protocol.
- Making herdr.el render panes. Terminals stay ghostel buffers holding a `herdr terminal attach`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **A connection is an explicit argument at the transport layer and a resolver at the top.** This is the shape `jsonrpc.el` and `eglot.el` settled on and it is the one this package should copy rather than reinvent. `jsonrpc-request` takes its connection as the first argument, with no ambient default anywhere in the transport. `eglot` keeps a hash of servers by project, caches one per buffer, exposes `eglot-current-server` as a function rather than a variable, and dynamically rebinds the cached server only at async dispatch, where the buffer that started a request may be gone by the time its reply lands. Applied here: `herdr-rpc-call` and `herdr-rpc-call-async` gain a connection argument, the resolver answers from the object at point or the buffer, and the dynamic rebind exists only around async callbacks. The resolver has to arrive with the argument, not after it: interactive commands are invoked from `M-x` and keybindings with no connection in hand, and timer callbacks run in an empty dynamic extent, so a transport that demands an argument no caller can supply is a package that does not run. U2 therefore ships a resolver that answers the sole connection, and U3 widens the same function rather than introducing one. An ambient special variable read by the transport was considered and rejected: it makes every call site correct by default and every bug invisible. Governs R8, R10.
- KTD2. **A connection is a struct, and an id is qualified by pairing it with one.** `cl-defstruct` rather than EIEIO, because nothing here dispatches generically on connection type; the local and remote cases differ in how the socket is obtained, not in how it is spoken to. The struct holds a name, a socket path, the SSH target when there is one, the tunnel process when there is one, the two event stream processes, the state cache, and the liveness the reconnect logic reads. Ids are not rewritten into composite strings: a qualified reference is the pair of a connection and the server's own id, so nothing has to parse a separator out of an id whose shape the server owns. The struct is mutable, so it is never itself part of a key: it carries an immutable token, allocated once at construction and never written again, and that token is what a composite key holds. The package already keys an `equal` hash table by bare pane id (`herdr-modeline.el:133`), and `equal` on a struct compares fields, so a key holding the struct would compare two freshly built connections equal and would stop finding an entry the moment a process or a cache slot changed under it. Governs R7.
- KTD3. **The tunnel forwards the remote unix socket to a local unix socket.** OpenSSH supports `-L local_socket:remote_socket` directly, so `make-network-process :family 'local` connects to a forwarded path exactly as it connects to the real one, and no TCP port has to be allocated, guessed, or defended. One `ssh -N` process per remote connection, its local socket under a short directory this package owns, torn down with the connection. Two consequences follow from how OpenSSH actually behaves. It binds the local socket as soon as the tunnel is set up and only dials the remote socket when something connects to the local one, so the socket appearing proves nothing about the remote server; a connection is up when a `ping` answers through it, not before. And `sun_path` is 104 bytes on macOS, so the local socket lives under a short base directory with a name derived from the connection rather than under a descriptive path that a long connection name can push past the limit. The alternative of forwarding to a local TCP port was rejected: it adds port selection and a listening socket on the loopback interface that anything on the machine can reach. Governs R3, R9.
- KTD4. **Remote terminals go through TRAMP and never through the tunnel.** ghostel already spawns with `make-process :file-handler` when `default-directory` is remote, which is what makes a remote shell work today. A remote pane's terminal buffer therefore gets a TRAMP `default-directory` for its server's host and runs `herdr terminal attach` there. The tunnel carries the control plane only, which is also why it can stay one small socket rather than a data path. Governs R2.
- KTD5. **Connect on request, then keep it. Never at startup.** A connection is created by an explicit command, and from then on the existing reconnect machinery keeps it. Disconnecting is what stops the retries; a dropped connection is not a disconnect. `herdr-start` touches the local connection only, so a laptop with no network starts exactly as fast as it does today. Governs R4, R5, R6.
- KTD6. **Each connection owns its own cache and its own streams; the dashboard merges, and nothing else does.** The session cache, the worktree cache and the two event connections all become per-connection. The merge happens once, in the dashboard's tree build, which is the only place that has ever wanted every server at once. Governs R1, R6.
- KTD7. **Isolation is a scheduling property, not a data-ownership one, so periodic repair goes asynchronous.** Separate caches stop one server corrupting another's data; they do nothing about time. Emacs runs one thread, and the repair the refactor plan introduces makes two sequential synchronous calls each bounded by `herdr-rpc-background-timeout`, so a remote that accepts connections and never answers costs about four seconds of frozen editor on every repair cycle - and that is per connection, so it multiplies. Per-connection repair therefore uses `herdr-rpc-call-async` with an in-flight guard and the generation check the worktree cache already models, and the synchronous form survives only where a user is waiting for the answer they asked for. A wedged remote must cost its own subtree's freshness and nothing else. Governs R6.

### Assumptions

- herdr ids are per-server counters, and 0.9.0 documents the scoping rather than leaving it to be measured: its multi-machine guide states that workspace, tab and pane ids and agent names are scoped to one server and that two machines may each contain a `w1:p1`. This is the plan's load-bearing fact.
- `ssh -L local_socket:remote_socket` carries the herdr protocol unchanged. The forwarding is byte-transparent and the protocol is one request per connection over NDJSON, so nothing in it depends on the peer's address. **Unverified against a live remote herdr; the first unit measures it before anything is built on it.**
- `herdr machine list --json` prints the saved profiles with their opaque id, label, SSH target, remote session and enabled state, which is what 0.9.0's guide says the catalog holds. **The exact JSON shape is unverified: the local herdr is 0.8.2 and has no `machine` subcommand.**
- Protocol 22 is what the package targets, and the upgrade plan has landed. Every record read here is the one that plan verified unchanged.
- The ownership refactors have landed, so the worktree cache has an interface whose key constructor is the single place a server has to be added, and the workspace record has a module whose accessors are the single place a qualified reference has to be understood.

### Sequencing

U1 measures the tunnel before anything depends on it, because KTD3 is the one decision here with an unverified premise. U2 makes the connection a value and keeps exactly one of them, which is the largest change and the one that must leave behaviour identical. U3 adds the registry and the resolver. U4 adds the remote connection and its tunnel. U5 makes the dashboard and the pickers show several servers. U6 adds the catalog reader, last, because it is the only unit a user can do without.

---

## Implementation Units

### U1 - Measure the tunnel

**Goal:** Know that a forwarded unix socket carries the herdr protocol before any code assumes it.

**Approach:**

1. Bring up a herdr 0.9.0 server on a second machine.
2. Forward its socket: `ssh -N -L /tmp/herdr-probe.sock:$HOME/.config/herdr/herdr.sock <target>`.
3. Drive `ping`, `session.snapshot` and a long-lived `events.subscribe` through the forwarded path, and hold the subscription open across an idle period longer than the SSH keepalive interval.
4. Record what happens when the remote server stops, when the SSH connection drops, and when the local socket file is left behind by a killed `ssh`. Record separately what a connection through a tunnel whose *remote* socket does not exist looks like from `herdr-rpc-call`, because that is the case R9 has to tell apart from an authentication failure and OpenSSH does not surface it at forward-setup time.
5. Confirm how the remote socket path is discovered for a named session, and how that session is named to `herdr terminal attach`.

**Done when:** `docs/protocol.md` records what a forwarded socket does, including the failure shapes, and this plan's Assumptions no longer say unverified. If the subscription cannot be held open, stop: KTD3 is wrong and the tunnel decision has to be reopened.

### U2 - Make the connection a value

**Goal:** Every call names the connection it is for, with exactly one connection in existence and no behaviour change.

**Files:**

- `herdr-rpc.el` - the struct, the connect and call functions.
- `herdr-state.el` - the cache and the two event streams become per-connection.
- `herdr-cmd.el` (15), `herdr-state.el` (8), `herdr-dispatch.el` (3), `herdr-schema.el` (2), `herdr-term.el` (2), `herdr-call.el` (1), `herdr-select.el` (1), `herdr.el` (1) - the thirty-three `herdr-rpc-call` sites outside the tests.
- `herdr-modeline.el` and `herdr-tree.el` - no RPC call sites, but both read the session cache, which moves into the struct.
- The corresponding test files.

**Approach:**

1. Define the connection struct per KTD2. Give it a constructor for the local server that reads `herdr-socket-path`, so the default is the configuration that exists today.
2. Give `herdr-rpc-connect`, `herdr-rpc-call` and `herdr-rpc-call-async` a connection argument. Take it first, as `jsonrpc.el` does, so a forgotten argument is a wrong-type error rather than a call against the wrong server.
3. Move the module-level state in `herdr-state.el` into the struct: the cache, both processes, the reconnect and settle and resubscribe timers, the generation, and the running flag.
4. Move the four worktree globals in `herdr-dispatch.el` into the struct, through the interface the refactor plan gave them.
4a. Give the schema cache a provenance. `herdr-schema.el` runs the *local* `herdr` binary to fetch a schema and then labels that cache with the version a socket `ping` returned. Threading a connection into the ping alone would label the local schema with a remote server's version. Either fetch through the connection's own host or key the cache by the connection it describes; do not leave the two halves disagreeing.
5. Add `herdr-current-connection` in this unit, answering the sole connection, and let interactive commands and timer callbacks resolve through it. This is the function U3 widens; it is not a temporary shim and it is not an ambient variable the transport reads.
6. Thread the connection through every call site. This unit adds no way to make a second one.

**Test scenarios:**

- Every existing test passes with the single connection threaded through, unedited except for the argument.
- Two connection values constructed in one test do not share a cache: reducing an event into one leaves the other empty.
- A call with no connection argument fails loudly rather than defaulting.
- An interactive command invoked with no arguments and a timer callback firing in an empty extent both reach the server, because both resolve through `herdr-current-connection`.

**Done when:** the package behaves exactly as it does today and nothing reads a global socket path except the local constructor.

### U3 - The registry and the resolver

**Goal:** More than one connection can exist, and every command knows which one it is acting on.

**Files:**

- A new `herdr-connection.el` - the registry, the resolver, and the lifecycle commands.
- `herdr-dispatch.el`, `herdr-cmd.el` - resolve at the point of action.
- `herdr-term.el` - the pane-to-buffer alist becomes qualified.

**Approach:**

1. Hold connections in one place, keyed by name, following `eglot--servers-by-project` in shape.
2. Widen `herdr-state-change-functions` to `(CONNECTION EVENT-KIND DATA)`. It is `(EVENT-KIND DATA)` today with nine call sites in `herdr-state.el`, and every listener - the modeline, the dashboard, the terminal directory sync - reaps or redraws against one cache. Startup, the synchronous refresh and stop all notify, so a dynamic binding around async dispatch cannot carry this: the connection has to be in the payload. Scope terminal reaping and worktree invalidation to the connection that notified, so stopping one connection leaves the other's buffers and cache alone.
3. Expose the resolver as a function, not a variable, following `eglot-current-server`. It answers from the object at point in the dashboard, from the buffer's own connection in a terminal buffer, and from the sole connection when there is only one.
4. Dynamically rebind the resolved connection around async dispatch only, following `eglot`'s rebind at its dispatch site. Nothing else in the package may read it ambiently.
5. Qualify the pane-to-buffer alist, and every other structure the refactor plan left keyed by a bare id, by pairing the id with its connection per KTD2.
6. Give the `WorktreeInfo` record the ownership the refactor plan deliberately exempted it from. It carries `open_workspace_id`, a bare workspace id read raw in `herdr-tree.el` and `herdr-dispatch.el`, and that field is exactly what U5's path-lookup guard has to disambiguate. The refactor plan named this as an untouched prerequisite this work inherits; this is where it is paid.
7. Add `herdr-connect` and `herdr-disconnect`. Disconnecting stops the retries; a drop does not.

**Test scenarios:**

- Two connections whose servers both issued `w1` resolve to different workspaces from the dashboard.
- A pane id present on two connections attaches two distinct buffers, and closing one leaves the other.
- A command run from a terminal buffer acts on that buffer's connection, not on whichever connection was resolved last.
- An async reply that lands after its originating buffer is killed is still attributed to the right connection.
- Disconnecting stops the reconnect timer; a dropped stream does not.
- Stopping one connection leaves the other's terminal buffers alive and its cache intact, because the change hook named which connection stopped.
- A composite key survives a reconnect and a cache mutation on the connection it names, because the key holds the immutable token and not the struct.

**Done when:** two fake servers with deliberately colliding ids, different records and separately recorded requests behave as two servers throughout. Two connections to the same real server is the tempting cheap version and it is not a test of this: both see the same records and the same focus, identical data hides mis-routing, and attaching twice to one pane hits herdr's own exclusivity rather than anything this unit built.

### U4 - The remote connection and its tunnel

**Goal:** A user names an SSH target and gets a connection.

**Files:**

- `herdr-connection.el` - the remote constructor and the tunnel.
- `herdr-term.el` - the remote `default-directory`.
- `docs/configuration.md`, `docs/getting-started.md`.

**Approach:**

1. Add a remote constructor taking an SSH target and an optional remote session name. It resolves the remote socket path on the remote host rather than expanding `herdr-socket-path` locally: the default contains `~`, and a macOS client expanding it locally would forward to `/Users/...` on a Linux server. The named session selects that path, and the same session must reach `herdr terminal attach` in the terminal buffers, which take no session argument today. It then starts `ssh -N -L <local>:<remote>`, waits for the local socket to appear, then declares the connection up only once a `ping` answers through it under a short timeout. The socket appearing is necessary and not sufficient: OpenSSH binds it before it has spoken to the remote host at all.
2. Put the local socket under a short directory this package owns, named from the connection so two remotes cannot collide, and remove a stale socket left by a killed `ssh` before binding. Keep the whole path well under 104 bytes, which is macOS's `sun_path` limit and the tighter of the two platforms; a long connection name is hashed rather than spelled out.
3. Tie the tunnel's lifetime to the connection: the sentinel that notices the tunnel died is what triggers the same reconnect path a dropped stream triggers, so there is one retry mechanism rather than two.
4. Give a remote connection's terminal buffers a TRAMP `default-directory` for the target per KTD4, and let ghostel do the rest. Two existing paths translate paths the wrong way once a connection can be remote, and both are this unit's to fix. `herdr-term.el:409` points a buffer's `default-directory` at the pane's reported working directory, which for a remote pane is a path on the remote host: assigning it verbatim strips the buffer's remoteness and silently retargets it at a local path that usually does not exist. And `herdr-cmd.el:223`, `:267` and `:307` send `expand-file-name` of a local directory as `cwd`, which from a TRAMP buffer produces `/ssh:host:/path` and hands the server a filename it cannot use. One direction needs the remote prefix added, the other needs it removed; `file-remote-p` and `file-local-name` are the two halves.
5. Report failures per R9 by pairing the handshake's outcome with the `ssh` process's own exit and stderr. The three cases arrive differently: authentication fails with `ssh` exiting non-zero and saying so, a remote without herdr leaves the tunnel up and the `ping` unanswered, and a wrong socket path closes the connection on first use so the `ping` returns the transport's `empty_response` rather than a timeout. Distinguishing them needs both signals, which is why the handshake is part of bringing the connection up rather than a check bolted on after.

**Test scenarios:**

- The tunnel command is built correctly for a bare host, a `user@host`, and an SSH config alias.
- A connection whose `ssh` exits immediately reports the SSH failure and does not leave a half-open connection in the registry.
- A stale local socket file does not stop a reconnect.
- A remote pane's terminal buffer has a remote `default-directory` and a local pane's does not, and syncing a remote pane's reported directory keeps the buffer remote rather than pointing it at a local path of the same name.
- Creating a workspace from a TRAMP buffer sends the remote-local path as `cwd`, not the `/ssh:host:` filename.
- The connection is not reported up until a `ping` answers, and a tunnel whose remote socket does not exist reports a distinct failure from one whose SSH did not authenticate.
- Disconnecting kills the `ssh` process and removes the local socket.

**Done when:** a remote server's workspaces appear and one of its panes opens as a terminal.

### U5 - Show several servers

**Goal:** One dashboard, every connection, each attributable.

**Files:**

- `herdr-tree.el` - the tree gains a server level.
- `herdr-dispatch.el` - the refresh merges.
- `herdr-select.el` - the pickers qualify.
- `herdr-modeline.el` - the summary spans connections.

**Approach:**

1. Build the tree from every connection, with the server as the outermost level. A single connection renders without that level, so R10 holds and nobody with one server sees a new row.
2. Merge in the dashboard's refresh and nowhere else, per KTD6.
3. Qualify picker candidates by server when more than one is connected, following whatever the refactor plan settled for how identity is printed, and not duplicating what the row already shows.
4. Show a connection that is down as itself, dimmed and labelled, rather than as an absence. An empty dashboard and an unreachable server are different facts.
5. Make the modeline summarise across connections without letting one wedged server stall the summary.

**Test scenarios:**

- Two connections with colliding workspace ids render as two subtrees and navigate to the right one.
- One connection down leaves the other's subtree fully navigable.
- A single connection renders with no server level at all.
- A worktree path reported by two servers resolves to the connection it came from. This is the harder of the two collision guards the refactor plan deferred here, because the path lookup searches every listing flattened together and has no tiebreak; it gets its own test.

**Done when:** the two collision guards the refactor plan deferred to this work are both written and both pass.

### U6 - Read the machine catalog

**Goal:** A user who already saved machines with `herdr machine` does not describe them again.

**Files:**

- `herdr-connection.el` - the catalog reader.
- `docs/configuration.md`.

**Approach:**

1. Read `herdr machine list --json` and offer its enabled profiles as connection candidates.
2. Treat the catalog as a source of suggestions, not as state. This package does not write it, does not sync to it, and works with it absent.
3. Key a connection by the profile's opaque id when it came from the catalog, since 0.9.0's guide says to read ids from the list rather than deriving them from labels or hostnames.

**Test scenarios:**

- A catalog with two enabled and one disabled profile offers two.
- No `machine` subcommand, an unreadable catalog, and an empty one all degrade to naming a target directly.
- A renamed profile keeps its connection, because the id did not change.

**Done when:** a saved machine can be connected without retyping its target.

---

## Verification Contract

- The suite is green with one connection at every unit boundary, and the single-server path is byte-identical in the requests it sends.
- Two connections to the same local server behave as two servers throughout the dashboard, the pickers and the terminals.
- A remote server over SSH shows its workspaces and opens a pane as a terminal.
- Killing the remote server leaves the local dashboard fully usable and the remote subtree labelled as down.
- Emacs starts with a configured remote that is unreachable, in the time it starts today, because nothing connected.

## Definition of Done

| Requirement | Unit | Evidence |
|---|---|---|
| R1 | U5 | Two servers render in one dashboard, each attributable. |
| R2 | U4 | A remote pane opens as a terminal over TRAMP. |
| R3 | U1, U4 | The forwarded socket carries the protocol, measured in U1. |
| R4 | U3 | Startup opens no connection but the local one. |
| R5 | U3, U4 | A drop retries; a disconnect does not. |
| R6 | U5 | One connection down leaves the others navigable. |
| R7 | U3, U5 | Both collision guards pass. |
| R8 | U3 | A command acts on the connection of the object at point. |
| R9 | U4 | Three distinct failures produce three distinct messages. |
| R10 | U2, U5 | One connection renders and behaves as it does today. |

## Risks

- **U2 is a wide, behaviour-preserving change with no user-visible result.** It touches every module and every test and delivers nothing a user can see, which is exactly the shape of change that gets rushed. It is also the unit that decides whether the rest is cheap. Land it alone and let the suite be the whole argument.
- **The tunnel's failure modes are the ones users will actually hit.** Authentication, a remote without herdr, a laptop that slept, a stale socket. R9 names three messages; U1 is what turns them from guesses into observed shapes. The trap to avoid is the one that reads best: a local socket that exists is not a connection, because OpenSSH binds it before dialling anything.
- **Path translation is a second, quieter class of bug than the tunnel.** The control plane and the terminal plane disagree about what a path means the moment a connection is remote, and both existing directions are currently wrong for that case. It is quieter because a wrong `default-directory` looks like an empty directory rather than an error.
- **Two servers holding the same id is easy to get right in the tree and easy to get wrong everywhere else.** The pane-to-buffer alist, the modeline, the pickers and the worktree path lookup are four separate places with the same hazard. U5's path-lookup scenario is the one with no tiebreak and the one most likely to be wrong.
- **The catalog's shape is unverified.** U6 is last partly for this reason: if `herdr machine list --json` does not print what 0.9.0's guide implies, only U6 changes.
- **Nothing here makes Emacs concurrent.** KTD7 moves repair off the synchronous path, which is necessary and not sufficient: every connection still shares one thread, and any synchronous call a user triggers against a wedged remote still blocks the editor for its timeout. The honest claim is that a wedged remote costs its own freshness and the commands aimed at it, not that it costs nothing.
- **This plan assumes two prior plans landed.** If the ownership refactors are skipped or partially landed, U2 and U3 grow: the id-keyed structures would each need widening at their own call sites rather than behind one interface.

## Sources

- herdr 0.9.0 `connecting-machines.mdx` - the machine catalog and its CLI, and the statement that ids are scoped to one server.
- herdr 0.9.0 `docs/next/api/herdr-api.schema.json` - the absence of any `machine` method in the socket API.
- `jsonrpc.el` - the connection as an explicit first argument, with no ambient default in the transport.
- `eglot.el` - the servers-by-project hash, the buffer-local cache, the current-server resolver as a function, and the dynamic rebind at async dispatch.
- `ghostel.el` - `make-process :file-handler` driven by a remote `default-directory`, which is what already makes a remote terminal work.
- `ssh(1)` - `-L local_socket:remote_socket`, supported since OpenSSH 6.7.
- `docs/plans/2026-09-09-0848-upgrade-to-herdr-0-9-0-plan.md` and `docs/plans/2026-09-08-1757-refactor-cache-and-record-ownership-plan.md` - the two plans this one follows.
