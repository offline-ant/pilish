# Detached menu contracts

Protocol-2 views reconnect; they do not replace their owning Pi process. The
menu keeps explicit unshared/plain-Pi behavior separate.

## Actions

- `pilish-reload` reconnects a retained shared runtime identity, including a
  disconnected view. A migrated managed stopped view without an identity also
  refuses implicit startup. Worker restart-refusal hooks retain their optional
  extension-command reload-in-place path; no transport/Pi replacement follows a
  refusal. Native unshared reload keeps its existing replacement behavior.
- `pilish-reconnect-agent` (`C` in the menu) reconnects only.
- `pilish-resume-agent` (`B`) confirms explicit fresh startup of a stopped
  conversation. It invokes `pilish-resume-stopped-session`; it sends no prompt.
- `pilish-attach-agent` (`J`) selects public normalized discovery entries and calls
  `pilish-attach-runtime`, never a launcher.
- `pilish-stop-agent` (`K`) confirms stopping the agent and owned work for **every**
  attached frontend, even while idle. It calls `pilish-stop-runtime` and preserves
  the view/input on failure or uncertainty. Closing a view is a different action.

The public runtime callbacks receive nil or one error string. Runtime identity and
actual Pi PID/start identity come from `pilish-session-runtime`, never a network
transport's process ID. `pilish-process-info` reports the distinction.

## Shared context changes

New/fork/resume confirm their every-frontend scope. They send only the owning RPC,
then reconcile with `pimux_bootstrap` including flat entries and messages. Commands
are sent from the validated ready boundary; before the event loop can accept more
input the view awaits a later authoritative snapshot. Cancelled/failed requests
also reconcile rather than inventing a rollback. Send uncertainty remains gated
and requests an explicit reconnect, never an automatic replay.

No shared transition clears or independently reconstructs history, reads the
destination file, retargets buffers, or overwrites the input. The owning snapshot
module applies session/model/thinking/branch state and quarantines local work.
Returned fork text is labelled recoverable input requiring explicit reuse, not a
replacement draft. Legacy independent history-refresh helpers refuse shared
transports so a forgotten caller cannot mix raw history with replay.

Live export uses `export_html` on the owner. Stopped managed export calls
`pilish-storage-export-session(file,output,pilish-runtime-pi-executable)` with the
exact configured release executable. The storage helper's claim/readiness contract
refuses active/uncertain writers and existing outputs. There is no raw export Pi.

## Delayed action context

Every mutating RPC carries the exact opaque `pimuxContext` from the successfully
applied snapshot. Model/thinking discovery, fork-message getters, selectors,
argument prompts and destructive confirmations capture it **before** yielding.
They never substitute a newer file, leaf or snapshot generation when a callback
runs. New/fork/resume confirmation preserves an already-bound context. The owning
router rejects stale commands; rejection is not permission to repeat them.

`pilish--resume-selected-session` and `pilish--execute-fork` accept an optional
captured context for delayed callers. `pilish-set-session-name` does likewise.
Browser live rename decides its RPC-versus-stopped-file dispatch before asking
for text, so a later session adoption cannot retarget the name or switch into a
new dispatch path. Stopped mutations retain their common lease protection.

Custom slash-command pickers refuse a changed context before calling prompt
preparation; their preflight must preserve that same context until native RPC
submission. Image selection and tree-label entry refuse if their draft/tree owner
changed while the minibuffer was active. Runtime Stop/Resume confirmations also
retain the original mux and saved-file identity rather than acting on whatever
agent later occupies the view. A failed steering acknowledgement retains its
requester's text under its original context, not in the replacement draft.

`test/pilish-command-context-test.el` covers these delayed-action races with
explicit core helper doubles. Core's own validation/wire tests and native mux
acceptance remain separate evidence.

## Owning integration and tests

The runtime module must supply the public APIs listed above and the configured
`pilish-runtime-pi-executable`. Menu loading itself does not enable sharing or
start a runtime. Final startup/session transitions must not call the native-only
history helpers for a shared transport.

Abort is owned by `pilish-input.el` and `pilish-ui.el`, not this menu module:
`pilish-abort` must dispatch to `pilish--abort-shared-turn` **before** changing local
stop/queue state. A delayed shared `pilish--send-abort` sends Abort only; it must not
clear newly queued input without fresh confirmation. See [DRAFTS.md](DRAFTS.md).
The menu still binds Abort to that owning public command, rather than replacing it
with a second implementation or advice.

`test/pilish-menu-detached-test.el` exercises reconnect-only reload, worker refusal,
missing-runtime safety, authoritative transitions, cancellation/send uncertainty,
explicit stop/resume/attach, actual process identity and protected export. Run it
alongside `test/pilish-menu-test.el` with fresh locked Lisp/grammar inputs and an
isolated HOME. The deterministic peers are post-validation fixtures; runtime
socket/process validation and native reconnect need the owning integration lane.
The candidate's Makefile must include the new test in its focused/default graph;
this menu-only change does not edit the parent-owned harness.
