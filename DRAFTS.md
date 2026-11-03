# Shared views and context-bound input

The detached candidate uses protocol 2 only. Socket ownership, hello validation,
real process identity and launcher receipts belong to `pilish-runtime.el` and core.
`pilish-shared.el` owns the exact snapshot/replay/live boundary. Every accepted
snapshot replaces file, flat entries, leaf, model, thinking and history together,
including an initiating client's own session transition. Frontends must not
follow that with an independently loaded history reconstruction. A history error
clears the old transcript and leaves an explicit notice.

A newer boundary abandons buffered paints/replay from its predecessor. Only its
matching live record enables input. Gaps, superseded records and snapshot failures
do not make a partially reconstructed view ready. Dialogs survive unrelated run
starts and close through authoritative closure, timeouts or stale-dialog snapshot
reconciliation. Statuses/widgets retained by replay do not flicker through clearing.

## Owning command context

A complete snapshot supplies `inputContext`: `{sessionFile, leafId, contextId}`.
This is the router's opaque selected-file/branch anchor, not the moving history
head or snapshot generation. Keep it unchanged across ordinary same-branch
appends and unrelated refreshes. Actual file/branch replacement changes the
anchor. Never manufacture one from displayed file/leaf fields.

Every mutating RPC, including Abort, dialog answers and global queue clearing,
carries the captured anchor as reserved `pimuxContext`; pimux validates it before
forwarding and strips the metadata before native Pi. The public
`pilish-session-input-context(buffer)` returns a copy only from a ready detached
view. Pass that copy to `pilish-submit-prompt` for delayed programmatic actions.
Immediate actions capture at dispatch; asynchronous selectors, confirmations,
prompt preflight and dialogs preserve their original expectation. A rejection
never retries against the newer conversation.

Only explicit read-only getters and pimux management requests may cross a pending
boundary without the anchor. In particular, a stale Abort cannot abort the new
conversation. Shared queue confirmations validate their original context again
before taking local work, then send that same expectation to the router.

## Local input is not a shared queue

`pilish-drafts.el` binds local text, materialized images, automatic follow-ups and
pending prompt ownership to the previous file/branch before applying a snapshot.
A file replacement or real branch navigation suspends that work. Ordinary linear
append leaves a draft in place. An iterative flat-entry ancestry check handles
missed changes and deep trees without recursion. Pi does not emit current leaf IDs
on normal live message appends; a compact digest of the last observed canonical
message identifies that later entry when the next full snapshot arrives. Missing
ancestry fails conservatively rather than declaring a different context safe.

Suspended records are plain Lisp data, with no markers/processes or armed queues.
They contain `:id`, `:origin`, `:session-file`, `:leaf-id` and applicable `:draft`,
`:images`, `:followups`, `:uncertain`, `:shared`, `:diagnostic` or truncation metadata.
Images are the already materialized name/MIME/size/base64 fields, never paths that
are reopened during restoration. An in-flight FIFO owner is retained once as an
uncertain submission, not again as an unsubmitted follow-up.

- `pilish-session-quarantine(buffer)` returns a plain copy, newest first.
- `pilish-restore-quarantined-input(&optional identifier)` selects one record and
  **always** confirms reuse in the current context. It restores only ordinary draft
  text/image, never a prompt or automatic follow-up. An existing image is never
  silently replaced. A diagnostic-only uncertain operation has no inferred text.
- `pilish-session-desktop-state-functions` receives the chat when images, local
  follow-ups, submission evidence or suspended input change without a text edit.
  Observer errors do not break state updates.
- `pilish--desktop-local-state()` supplies `:draft`, `:images`, `:followups`,
  `:quarantine`, `:leaf-id`, `:context`, `:editor-notices` and `:submitted` to the
  owning desktop API. Preserve all of these fields in that API, not a hand-picked
  subset. `:context` carries the original file/branch/digest for comparison.
- `pilish--restore-local-desktop-state(state)` restores an editor, but saved local
  follow-ups and pending submissions become explicit suspended recovery. They are
  never armed automatically, even when a surviving runtime is still on that file.

Pimux editor-text notices have ambiguous origin. They become labelled, selectable
recovery rather than overwriting any draft. Per-mux notice watermarks survive
local desktop serialization, so a replay after explicit recovery does not offer
the same text again. Truncated notices are explicitly labelled incomplete.

## Close suspends local input

Close immediately gates normal prompts, steering and automatic follow-up draining,
including the public submission API. Draft text and materialized images remain
editable recovery. Unsubmitted local follow-ups move to explicit reuse-only
quarantine before notifications; notification failure cannot leave them armed.
An already-submitted FIFO owner keeps its acknowledgement callback and is not
copied into unsent recovery. Accepted Pi-owned work is not inferred or replayed.
Only the freshly admitted, context-bound worker cancellation crosses this input
gate. Ambiguous cancellation keeps input suspended through waiter timeout and
reconnect; definitive rejection permits an explicit new attempt. Task evidence
and cancellation admission belong to [RUNTIME.md](RUNTIME.md#worker-task-completion).

## Destructive shared queue removal

Pi's `clear_queue` removes the entire runtime queue, including other frontends'
input. It returns all removed text **only to its requester**. Neither the displayed
queue nor the response supplies reliable per-client provenance. Every intentional
shared clear/recover action asks explicit every-frontend confirmation, even if its
latest displayed snapshot is empty. Only a successful response determines recovery.
It is retained as labelled requester-only suspended input; it is never inserted
into a new context or resubmitted. Other frontends receive the authoritative queue
update, not a promise of their own recovery. Failed/lost acknowledgements retain
uncertainty notes, not invented recovery or an automatic retry.

The existing explicit unshared mode retains its ordinary draft/kill-ring behavior.
Local queue removal happens before the RPC so local follow-ups cannot run during
its round trip, and known local input remains recoverable even on RPC failure.

## Owning runtime/input integration

These are internal module contracts, not additional transports or compatibility
paths:

1. Core/runtime command gates consult `pilish--shared-input-ready-p(proc)` for
   shared user-input commands. Read-only getters and management/bootstrap remain
   possible while a snapshot is pending; Abort and dialog answers remain gated.
   A pending or failed boundary never authorizes prompt replay.
2. Shared calls `pilish--runtime-note-snapshot(proc,snapshot)` after authoritative
   state/history adoption, `pilish--runtime-live(proc)` after the matching replay
   boundary, and `pilish--runtime-snapshot-failed(proc,error)` for a non-superseded
   failure. These are optional observers while independently loading this module.
3. `pilish-abort` must dispatch a shared run to
   `pilish--abort-shared-turn()` **before** mutating stop intent or taking local
   queues. That helper confirms once, suspends known local work, clears the global
   queue and sends Abort in wire order. Cancellation changes no state.
4. A delayed-start retry of `pilish--send-abort` for a shared process must send
   **Abort only**, not clear a new shared queue without new human authorization.
   This distinction prevents later accepted input from being destructively cleared
   by the first abort action. Unshared behavior remains unchanged.
5. UI submission notifications bind original text/image to the opaque request before
   the RPC. Invalidating that owner ends its evidence; context changes retain it
   first as uncertain recovery and invalidate late acceptance/rejection callbacks.

The parent integration owns core/runtime/entry/menu and input Abort dispatch.
Protocol-1 primary termination/reload tests are removed from this module suite;
the owning runtime suite must test disconnect-only teardown and actual Pi lifetime.

## Focused verification

Use fresh locked Lisp sources and freshly provisioned essential grammars, a private
HOME and candidate-only load paths. Load `test/pilish-test-common.el`,
`test/pilish-shared-test.el`, `test/pilish-queue-test.el` and
`test/pilish-drafts-test.el`; run the explicit `pilish-*-test` selector for those
three suites. They use deterministic post-validation synthetic peers, not paid
providers or live runtime discovery. Real socket validation/reconnect is a distinct
owning-runtime integration lane. Compile UI/drafts/queue/shared and the new test with
warnings as errors; checkdoc the three feature modules. No home grammar/package
cache is accepted as evidence.
