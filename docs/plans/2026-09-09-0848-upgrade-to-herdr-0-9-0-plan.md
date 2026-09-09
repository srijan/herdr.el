---
title: Upgrade to herdr 0.9.0 - Plan
type: maintenance
date: 2026-09-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Upgrade to herdr 0.9.0 - Plan

## Goal Capsule

- **Objective:** A person upgrading their herdr to 0.9.0 keeps a dashboard that starts correct, closes a workspace group when they said to, and stops warning them about a protocol number.
- **Means:** Bump the protocol constant (KTD1), close the startup event gap the removed replay used to hide (KTD2), give `workspace.close` group intent (KTD3), and retire the replay from the documentation that describes it as present (KTD4).
- **Authority:** herdr 0.9.0's own schema and source win on what the server does. The Requirements win on behaviour. `docs/architecture.md` and `CONTRIBUTING.md` win on house style.
- **Execution profile:** Test-first, as `CONTRIBUTING.md` requires. Each unit lands as one commit. The suite must be green at every unit boundary, against a 0.9.0 server.
- **Stop conditions:** Stop and ask if a record this package reads turns out to differ from protocol 20 after all. Stop if the startup drain in U2 cannot be made to preserve arrival order.
- **Tail ownership:** This plan ends when herdr.el is correct against 0.9.0. The three ownership refactors follow it; connecting to several servers follows those.

---

## Product Contract

### Summary

herdr 0.9.0 raises the socket protocol from 20 to 22 and removes the event-ring replay that `events.subscribe` used to send every new subscriber. Every record this package reads is unchanged, so nothing here is a migration. Three things break quietly and one body of documentation becomes false. This plan fixes the three and corrects the documentation.

### Problem Frame

**The protocol constant is stale.** `herdr-protocol-version` is 20 and a 0.9.0 server answers `ping` with 22, so `herdr--check-protocol` warns once on every session. The warning is correct in form and useless in content: nothing this package calls actually changed. `test/herdr-drift-test.el` asserts the two match against a live server, so the suite fails until the constant moves.

**The startup snapshot now loses events.** `herdr-state-start` calls `session.snapshot`, announces it, and only then opens the event streams. Under 0.8.2 anything that happened in that window arrived anyway, because a fresh subscription replayed the server's whole 512-event ring. Under 0.9.0 a subscription starts at the sequence its request arrived on, so the window is a hole. What falls in it is not only panes: `herdr-state--settle` reconciles panes at startup and nothing reconciles workspaces there. `herdr-state-reconcile-workspaces` has exactly one caller in the package, the directory poll at `herdr-term.el:374`, so a workspace renamed, moved or closed inside the window stays wrong in the cache until that poll happens to run - and a user who set `herdr-term-track-directory` to nil has stopped it running at all. That is the same permanent-ghost failure `herdr-state-reconcile-workspaces` was written to end, arriving through a new door.

**Closing a workspace with worktrees now fails instead of closing.** 0.9.0 refuses a `workspace.close` that would take more than one workspace with it unless `close_group` is true: `src/app/api/workspaces.rs:323` returns the error `workspace_group_close_required` when `close_indices.len() >= 2`. `herdr-rpc-call` turns that into a `herdr-error`, so `herdr-workspace-close` signals out of `herdr-cmd.el:236` and never reaches its success message. The user is not lied to - an earlier reading of this plan said they were, and that was wrong - but they are stopped, with a message naming a CLI flag they did not type and an API parameter they cannot reach.

**Four documents describe a server that no longer exists.** `docs/protocol.md` devotes a section to the replay and calls it a fault whose correction is one line for each arm. 0.9.0 made that correction. `README.md` names the replay as the finding that bites first, `CONTRIBUTING.md` sends bug reporters to it, and roughly a dozen comments in `herdr-state.el` reason from it. The repository's stated convention is that a wrong finding stays visible beside its correction, because deleting one means the next reader derives it again. A finding that was right and then got fixed upstream deserves the same treatment for the same reason.

### Key Decisions

- **Upgrade lands before the ownership refactors, and both land before the multi-connection work.** (session-settled: user-directed.) The refactors and the connection work both reason about the event stream, so doing them against a server whose replay behaviour is about to change would bake in a stale premise. Governs R1, R7.
- **Correct the startup gap in this plan rather than waiting for the refactor's repair cadence.** The refactor's U1 makes a periodic repair that would eventually paper over the gap, but eventually is not the same as correctly, and this plan cannot depend on a plan that follows it. Governs R3.
- **Keep the replay findings visible with their correction, do not delete them.** `docs/protocol.md` says why in its own opening. Governs R6.

### Requirements

- R1. The protocol constant names 22, and the live drift test passes against a 0.9.0 server.
- R2. A protocol mismatch still warns once rather than refusing to run.
- R3. An event that happens between the startup subscribe and the startup snapshot reaches the cache.
- R4. Startup applies the snapshot and the events of that window in an order that leaves the cache matching the server, whichever arrived first.
- R5. Closing a workspace that has open worktree workspaces either closes the group or says it did not, and never reports a close that did not happen.
- R6. No document or comment in the package asserts that `events.subscribe` replays retained history, and each place that did records that 0.9.0 removed it.
- R7. The captured schema fixture matches the protocol the package targets.

### Scope Boundaries

- Behaviour changes only where a Requirement names it. R5 is the one visible change to what a user sees.
- No new herdr method is wrapped. The eleven methods 0.9.0 adds are all pane presentation, client shell, or announcements, and `herdr-call` reaches every one of them from the server's own schema already.
- The curated command table gains no entry. It gains one parameter.

#### Deferred to Follow-Up Work

- The three ownership refactors. They are their own plan and they follow this one.
- Connecting to several herdr servers. That plan follows the refactors.
- Reading herdr's saved-machine catalog. It belongs to the connection plan, which is the first thing that has a use for a list of servers.
- `--no-session` mode, which 0.9.0 removes. This package never used it.

#### Outside this plan's identity

- Any change to the herdr server.
- Any behaviour that protocol 20 and protocol 22 agree on.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The constant moves and the fixture is recaptured together.** `herdr-protocol-version` becomes 22 and `test/fixtures/schema-protocol-20.json` is recaptured from a 0.9.0 server and renamed for protocol 22. Three test files name the fixture and the drift test compares the constant to a live server, so leaving the fixture at 20 would leave the package targeting one protocol and testing against another. The recapture is not cosmetic even though the records are unchanged: it is what makes `herdr-cmd`'s drift test check the curated table against the schema the package claims to target. Governs R1, R7.
- KTD2. **The startup gap is closed by reconciling, not by re-ordering the startup.** Upstream tells clients to subscribe before snapshotting, and for this package that is the wrong shape twice over. First, connection B cannot be opened before the snapshot at all: `herdr-state--open-pane-stream` builds its subscription list from `herdr-state--watched-pane-ids`, which reads the agents out of the cache, so before the snapshot the list is empty, no socket is opened and `herdr-state--pane-stream-ids` is set to nil. Second, a subscription now starts at the sequence its request arrived on, which is before the snapshot is taken, so the queue would hold events the snapshot already reflects; folding them on top would re-apply `workspace_moved` and `workspace_reordered`, whose reducers shift indices and are not idempotent. That is the same double-apply the 0.8.2 replay caused and 0.9.0 removed, and reintroducing it in a smaller window is not an improvement. So the order stays as it is and `herdr-state--settle` gains one call: it reconciles workspaces after it reconciles panes. `pane.list` and `workspace.list` are both authoritative and take no parameters, so together they close the gap for the two things that persist, at startup and on reconnect alike, without a queue, a second filter mode or a rollback. Governs R3, R4.
- KTD2a. **What the reconcile does not close is named rather than hidden.** `herdr-state-reconcile-workspaces` removes stale workspaces and updates changed ones; it does not reorder, so a `workspace.reordered` lost in the window leaves the dashboard's order wrong until the next real reorder. Focus is the same: `focused_pane_id` and `focused_workspace_id` come from the snapshot and from focus events, and neither list call carries them. Both are cosmetic, both self-correct on the next event of their kind, and both are exactly the residue the disconnect path already lives with. Closing them needs an ordering fact the protocol does not give a client, so this plan states them and stops. Governs R4.
- KTD3. **The group close is driven by the server's refusal, not by a preflight.** The curated table gains `close_group` for `workspace.close`, and `herdr-workspace-close` sends the plain close first. If the server answers `workspace_group_close_required`, the command asks whether to close the group and retries with `close_group` set. Asking the server first - a `worktree.list` before the prompt - was the obvious design and is worse in three ways: `herdr-dispatch.el` requires `herdr-cmd.el` so the dispatcher's existing listing is unreachable from there, a preflight adds a synchronous call to every close including the ones that need nothing, a preflight that errors leaves the command guessing, and - worst - a preflight over `worktree.list` would misread the group itself, because a main checkout's entry carries an `open_workspace_id` naming the very workspace being closed (`herdr-tree.el:177`), so a workspace with no worktrees at all would look like a group. The refusal is authoritative, costs nothing when it does not happen, and already carries the reason. Governs R5.
- KTD4. **The replay section is corrected in place, not deleted.** `docs/protocol.md` keeps its section, keeps the source excerpt, and gains the 0.9.0 excerpt beside it with the version each belongs to. `README.md` and `CONTRIBUTING.md` lose their references, because both describe behaviour a user sees today and neither is a record of findings. The `herdr-state.el` comments are rewritten to describe what the code now defends against rather than what it used to. Governs R6.
- KTD5. **The subscription list stays unsorted, for a smaller reason.** `herdr-state-global-subscriptions` carries a comment saying order matters because replayed types drain in list order. The ring is gone, so that no longer governs hours of history. It is not fully gone: `ActiveEventSubscription::poll` still returns at most one matching event for each call and the server still walks subscriptions in list order, so a burst delivered across one tick can still put a `pane.created` ahead of its `pane.closed`. That is now a window of milliseconds rather than the whole ring. The list keeps its order and the comment shrinks to the window it now governs. Governs R6.

### Assumptions

- Protocol 22 leaves every record this package reads unchanged. Compared field-for-field between herdr 0.9.0's `docs/next/api/herdr-api.schema.json` and 0.8.2's: `WorkspaceInfo`, `WorkspaceWorktreeInfo`, `PaneInfo`, `AgentInfo` and `SessionSnapshot` are identical. `ServerCapabilities` gained `endpoint_protocol_generation`, `health_check` and `surface_interest`, none of which this package reads. If a record turns out to differ after all, U1 stops and the difference becomes its own unit.
- No method this package calls was removed. The 0.9.0 schema removes no method constant and adds eleven.
- `WorkspaceCloseParams` became a named definition in 0.9.0 and carries `workspace_id` and `close_group`. In 0.8.2 the parameters were inline and there was no `close_group`.
- The replay removal is unconditional for the eighteen subscriptions this package uses. In 0.8.2's `src/api/subscriptions.rs` twenty-four arms set `last_sequence: 0`; in 0.9.0 they are one helper taking `event_start_sequence`, which the caller sets to `event_hub.current_sequence()`.

### Sequencing

U1 lands first: the drift test fails against a 0.9.0 server until it does, so nothing else can be verified against one. U2 and U3 are independent of each other and either order works. U4 lands last, because it describes what U1 through U3 leave true.

---

## Implementation Units

### U1 - Target protocol 22

**Goal:** The package names the protocol it is tested against, and the captured schema is that protocol.

**Files:**

- `herdr.el` - the `herdr-protocol-version` default.
- `test/fixtures/schema-protocol-20.json` - recaptured and renamed.
- `test/herdr-call-test.el`, `test/herdr-schema-test.el`, `test/herdr-cmd-test.el` - the fixture path and the docstrings that name protocol 20.
- `docs/protocol.md`, `README.md` - the version the notes were measured against.

**Approach:**

1. Recapture the schema with `herdr api schema --json` against a 0.9.0 server, write it as `test/fixtures/schema-protocol-22.json`, and delete the protocol-20 fixture.
2. Point the three test files at the new fixture and correct the docstrings that name protocol 20.
3. Set `herdr-protocol-version` to 22. Leave `herdr--check-protocol` alone: warning once rather than refusing is a decision this plan does not revisit.
4. Correct the version each document names as the one it was measured against.

**Test scenarios:**

- The live drift test passes against a 0.9.0 server, and its failure message still names both numbers when it does not.
- The mismatch warning still fires exactly once for a server one ahead, and stays silent when the numbers agree. Both tests derive their number from the constant, so neither needed editing; confirm that is still true rather than assuming it.
- Every curated command's parameters are still present in the recaptured schema.

**Done when:** the suite is green against a 0.9.0 server and no test file names protocol 20.

### U2 - Close the startup event gap

**Goal:** A workspace changed while the cache is hydrating is right afterwards.

**Files:**

- `herdr-state.el` - `herdr-state--settle` (`herdr-state.el:504`).
- `test/herdr-state-live-test.el` - the settle's reconciliation.
- `herdr-state.el` docstrings - the startup ordering comment that explains itself by the replay.

**Approach:**

1. Add `herdr-state-reconcile-workspaces` to `herdr-state--settle`, immediately after `herdr-state-reconcile-panes`, inside the existing `herdr-rpc-background-timeout` binding. Panes first, because the pane set is what connection B is realigned against and that realignment already happens after it.
2. Leave the startup order alone. The snapshot still precedes the subscribe, and the docstring in `herdr-state--settle` that justifies this by the replay is rewritten to justify it by the reconcile.
3. Leave the `resync` branch alone. It already replaces the whole cache from `session.snapshot` on reconnect, and the added reconcile runs after it there too, which is harmless and keeps one code path.
4. Note the interaction the refactor plan inherits: its U1 adds a periodic repair whose callback reconciles panes then workspaces, which is this same pair. When both have landed there is one function doing this work and two callers, not two implementations.

**Test scenarios:**

- A workspace renamed on the server between the snapshot and the subscribe is correct in the cache after the settle, asserted on the label rather than on a count.
- A workspace closed in that window is gone after the settle.
- A workspace created in that window is present after the settle.
- The settle reconciles panes before workspaces, because connection B is realigned against the pane set.
- A `workspace.list` that errors leaves the cache untouched rather than emptying it, which is the behaviour `herdr-state-reconcile-workspaces` already has and which the settle must not defeat by treating nil as an answer.
- Reconnect still resyncs from the snapshot first and then reconciles.

**Done when:** the window is covered by a test that fails when the added call is removed.

### U3 - Give `workspace.close` group intent

**Goal:** A user closing a workspace that has worktrees is asked once and told what happened.

**Files:**

- `herdr-cmd.el` - the curated table and `herdr-workspace-close` (`herdr-cmd.el:37`, `herdr-cmd.el:228`).
- `test/herdr-cmd-test.el` - the retry and the parameters sent.
- `docs/commands.md` - what the command does now.

**Approach:**

1. Add `close_group` to the `workspace.close` row of `herdr-cmd-methods`.
2. Send the plain close as today. Catch `herdr-error` around it and branch on `herdr-error-code`: `workspace_group_close_required` is the one code this command handles, and every other error propagates unchanged.
3. On that code, ask whether to close the group and retry with `close_group` set. The question names the group, because the user has already answered a prompt about one workspace and is now being asked about more.
4. Report what happened. A plain close keeps today's message; a group close says a group closed; a declined group says nothing closed.
5. Do not preflight, per KTD3. A workspace with no worktrees sends exactly the request it sends today and pays nothing.

**Test scenarios:**

- A workspace with no worktrees prompts once and sends `workspace_id` alone, byte for byte the request sent today.
- A server answering `workspace_group_close_required` produces a second prompt, and answering yes sends the same `workspace_id` with `close_group` true.
- Declining the group question sends no second request and reports that nothing closed.
- An unrelated `herdr-error` from the first close propagates rather than being read as a group refusal.
- The drift test still finds every curated parameter in the schema, `close_group` included.

**Done when:** a group close is reachable from the command and no error code but the group one is swallowed.

### U4 - Retire the replay from the documentation

**Goal:** Nothing in the package tells a reader the server replays retained history.

**Files:**

- `docs/protocol.md` - the event stream section.
- `README.md:260` - the finding that bites first.
- `CONTRIBUTING.md:149` - item 5 of the bug report checklist.
- `docs/architecture.md:71` - the reconciliation contract's second numbered point.
- `docs/troubleshooting.md:10,17` - the stated cause of dead panes, and its link.
- `docs/configuration.md:101,103` - the same cause and link under the reconcile knob.
- `docs/getting-started.md:69` - the same link.
- `herdr-state.el` - the comments that reason from the replay, at the file header and around the subscriptions list, the settle delay, the settle, the reconnect and the resubscribe.
- `herdr-dispatch.el:48` - the redraw-per-event comment.
- `test/herdr-state-live-test.el:138,169,398,587` - four test docstrings that explain themselves by the replay. The tests keep their assertions; only the reasons change.

**Approach:**

1. In `docs/protocol.md`, keep the section and the 0.8.2 excerpt, and add the 0.9.0 correction beside it: the twenty-four arms became one helper taking a start sequence captured when the request arrived, and upstream's test for it is named `lifecycle_subscription_skips_history_but_keeps_setup_window_events`. Say which version each excerpt is from. The document's own opening explains why the old finding stays.
2. Remove the replay from `README.md`'s architecture notes. It described what a user sees a second after `M-x herdr`, and they no longer see it.
3. Rewrite item 5 of `CONTRIBUTING.md`'s checklist. Whether a fault survives a reconcile still separates a stale cache from a real fault; the reason is now the reconcile, not the replay.
3a. Correct the four user-facing documents that name the replay as the cause of dead panes and link to the protocol note: `docs/architecture.md`, `docs/troubleshooting.md`, `docs/configuration.md` and `docs/getting-started.md`. Dead panes at startup were the replay's most visible symptom and 0.9.0 removes them, so the remedy those documents offer no longer has a problem to solve. Each keeps its link only if the corrected protocol section still answers the question it was linked for.
4. Rewrite the `herdr-state.el` comments. `herdr-state-settle-delay`'s docstring, `herdr-state-global-subscriptions`'s ordering note per KTD5, `herdr-state--settle`'s reconciling paragraph, and the scattered mentions at the file header and around the reconnect and resubscribe paths. Each says what the code defends against now.

**Test scenarios:**

- None. This unit changes no behaviour. Its check is that the suite stays green and that a grep for the replay finds only `docs/protocol.md`.

**Done when:** the only surviving description of the replay is the corrected record.

---

## Verification Contract

- The suite is green against a live herdr 0.9.0 server, including the live tests the batch suite skips.
- `herdr-start` against a 0.9.0 server produces no protocol warning.
- Startup with a workspace renamed during hydration leaves the new label in the dashboard.
- Closing a primary workspace with an open worktree either removes both from the dashboard or reports that nothing closed.
- `grep -rn "repla[yi]" --include="*.el" --include="*.md" .` outside `docs/history` and `docs/plans` returns only `docs/protocol.md` and the modeline's unrelated burst comment at `herdr-modeline.el:81`.

## Definition of Done

| Requirement | Unit | Evidence |
|---|---|---|
| R1 | U1 | Live drift test passes against 0.9.0. |
| R2 | U1 | Warn-once and silent-when-equal tests still pass, unedited. |
| R3 | U2 | Window event is in the cache after startup. |
| R4 | U2 | Snapshot and window event resolve to the server's truth in both arrival orders. |
| R5 | U3 | No path reports a close the server did not perform. |
| R6 | U4 | Grep finds the replay only in the corrected record. |
| R7 | U1 | No test file names protocol 20. |

## Risks

- **The gap now closes in about 400ms rather than instantly.** `herdr-state-settle-delay` is what a user waits before a workspace changed during hydration is right. That is the same delay the pane set has always converged on, so nothing gets slower, but it is a convergence guarantee and not a correctness one, and the plan should not pretend otherwise. A reviewer who wants instant correctness should read KTD2 for why the alternative was rejected rather than assuming it was not considered.
- **The group-close retry branches on an error code string.** If upstream renames `workspace_group_close_required`, the command silently stops offering the group close and starts surfacing a raw error again. That is a visible, non-destructive degradation rather than a wrong close, which is the right way for it to fail, but it belongs in the drift test's remit rather than only in a `condition-case`.
- **Recapturing the fixture can hide a real difference.** If a record did change and the fixture is recaptured before the tests are read, the tests keep passing against the new shape and the change goes unnoticed. Diff the two fixtures before deleting the old one, rather than trusting the schema comparison in Assumptions.
- **U2 and the refactor plan's U1 build the same pair of calls.** This plan adds panes-then-workspaces to the settle; that plan adds panes-then-workspaces to a repeating timer. Landing both without noticing leaves two copies. Whichever lands second should extract the pair, and the refactor plan's U1 is the natural owner because it already introduces a repair entry point.

## Sources

- herdr 0.9.0 `docs/next/api/herdr-api.schema.json` against 0.8.2's - protocol 20 to 22, the unchanged records, the new `ServerCapabilities` fields, `WorkspaceCloseParams` and its `close_group`, and the eleven added methods.
- herdr 0.9.0 `src/api/subscriptions.rs` against 0.8.2's - twenty-four `last_sequence: 0` arms replaced by one helper taking `event_start_sequence`, and the upstream test that names the setup window.
- herdr 0.9.0 `CHANGELOG.md` - the subscription change (#1270), the `close_group` requirement (#2874), and the removal of `--no-session`.
- `docs/protocol.md` - the existing replay record, and the convention that a finding stays visible beside its correction.
- `herdr-state.el` - the startup order, the settle, and the comments that reason from the replay.
