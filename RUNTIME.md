# Detached runtime API and verification

Pilish remains a separate upstream-tracking fork used directly by the Phimacs
checkout. Consumers require the versioned public integration API, not a frontend
source hash or archive. Stock MELPA Pilish does not establish this contract.
Ordinary unshared Pilish remains supported.

## Configuration and capabilities

The detached candidate requires Linux, Node 24 and Emacs 31.1 or newer. Provision
Lisp/native dependencies and essential grammars explicitly before reference
startup. No normal startup download, private provider, personal configuration or
existing home cache is a dependency.

[Phimacs setup](../phimacs/docs/install.md) configures its selected checkout and
reusable assets. Other integrations call `pilish-configure-runtime` explicitly:

| Keyword | Value |
|---|---|
| `:pi-executable` | Absolute selected Pi entry point |
| `:pimux-executable` | Absolute compiled owning pimux launcher |
| `:task-status-executable` | Absolute compiled orchestration task-status CLI |
| `:protocol` | `2` |

Without the task-status CLI, root sessions remain supported, but worker Close and
read-only worker reconciliation refuse. Phimacs selects the global `pi` on
`PATH` as its host. Authenticate that host with the intended agent directory
before intentional provider use.
Credentials are never source or reusable assets.

`pilish-integration-capabilities()` returns API version 1 and pimux protocol 2,
including implemented symmetric socket, runtime identity, desktop state, stopped
view, context-bound input, managed storage, authoritative-close and essential
grammar capabilities.
Check the versioned API, not the package version or existence of one function.

The default mode is `unshared`. To select it explicitly before new native sessions:

```elisp
(pilish-configure-runtime :mode 'unshared)
```

Unshared mode retains `pilish-executable`, ordinary stdio Pi lifetime and native
TRAMP policy. Detached mode uses local same-user Unix sockets; it does not silently
fall back to a remote/raw Pi launch. The old `("pimux" "--" "pi")` primary-stdio
configuration and protocol-1 lifetime semantics are unsupported, not translated.

## Start, readiness and lifetime

A new managed `pilish-start-session` or interactive session invokes the configured
compiled CLI as `pimux start --json -- <absolute Pi> --mode rpc ...`. It requests
the independently supervised foreground pimux service, which claims the exact
session before Pi opens it and returns the committed identity receipt. Pilish
never starts a daemon. Requests wait up to ten seconds for service readiness,
then report ``pimux unavailable; run `sv up pimux` and retry``. It is short-lived, not an stdio bridge. Pilish immediately
publishes the committed identity for desktop recovery, with placement unknown
until discovery succeeds. It asynchronously reads discovery, validates it against
the receipt and retains its task/host placement before connecting directly to the
socket as an ordinary peer. The creator has no privileged lifetime.

Before user input is accepted, Pilish validates the private same-user socket and
parent directory, protocol/capabilities, mux and exact actual Pi PID/start/boot
identity and the `contextual-input` capability, then applies the authoritative
snapshot/replay/live boundary. A protocol-2 owner without that capability refuses
rather than silently accepting unguarded instructions. The
`on-ready` callback reports success only after that boundary. A listening socket,
launcher exit or metadata response alone is not ready. Unsupported/mismatched
owners refuse; no second writer is spawned as recovery. Opening a saved file in a
new detached view supplies that exact file to the initial managed launch. Opening
another file in an existing view requires its successful live boundary; an unready
view refuses without launching a different conversation.

Snapshots adopt the current file, flat entries, leaf, model, thinking and history
together, including an initiating client's own session transition. Newer
generations abandon unfinished replay; gaps and snapshot errors gate input.
History failure removes the old transcript instead of relabelling stale history.
The authoritative new file/runtime identity is retained even when history cannot
be rendered. Only a successfully applied full snapshot with both history arrays
and the owning `inputContext` token can complete its live boundary. Renderer,
identity or reconciliation errors invalidate that token and suspend local input;
a later live marker cannot repair a failed application. Reconnect explicitly to
obtain a new full boundary; recovery never resends the suspended input.
No independent disk/history reconstruction is mixed into shared replay. Dialogs
are first-answer-wins and close through authoritative closure, timeout or snapshot
reconciliation, not an unrelated run. Pi's aggregate prompt signal still cannot
identify one abandoned dialog among several open dialogs.

Explicit Close stops the agent everywhere without confirmation, even when busy.
Authoritative root termination retires active chat/input views in every frontend.
Workers additionally require matching successful final task-cleanup evidence;
runtime exit alone cannot acknowledge their Close or remove recovery. The one
exception is a worker that pimux proves ended despite failed evidence (see Worker task
completion).
Close immediately suspends normal input and automatic local follow-ups while
preserving recovery; see [DRAFTS.md](DRAFTS.md#close-suspends-local-input).
Direct buffer disposal, Emacs exit and socket loss disconnect only.
**Accepted work and provider waits may continue and incur usage invisibly.**
The service, not Emacs, owns every managed RPC agent and worker. Its restart
ends old agents and recreates roots idle with fresh extensions; workers and
interrupted execution are not restored. Individual agent failure does not cause
an automatic replacement. There is no idle auto-stop or paid prompt replay.
Reconnect and desktop restoration never submit `continue`, tools, queued work or
inferred retries. See the owning [service lifecycle](../phimacs/docs/lifecycle.md). A pre-commit launcher cancellation belongs to its
provisional ownership protocol; post-commit attachment failure leaves an existing
runtime available for explicit reconnect/stop.

### Public identity and control

- `pilish-session-process(buffer)` returns the current transport. A detached
  transport is a network process; its process ID is not the Pi PID.
- `pilish-session-runtime(buffer)` returns a plain retained plist, or nil for an
  ordinary unshared session. It contains `:protocol`, `:mux-id`, `:socket`, `:pid`
  (mux), `:pi-pid`, `:pi-start-time`, `:pi-boot-id`, `:session-file`, `:state` and
  available placement/parent/orchestration metadata.
- `pilish-session-process-identity(buffer)` returns actual Pi `:pid`, `:start-time`
  and `:boot-id`, separately from the transport.
- `pilish-session-input-context(buffer)` copies the owning `inputContext` only
  after successful snapshot/live application. Capture it before delayed actions
  and pass it to `pilish-submit-prompt`; unavailable/unshared views return nil.
  This opaque file/branch anchor is distinct from the moving history leaf.
- `pilish-list-runtimes()` returns normalized discovery plists without starting Pi.
  Unsupported entries remain visible, never a reason to start a replacement.
- `pilish-attach-runtime(runtime &optional name)` attaches an existing identity,
  reusing a local view of that mux when present; it never starts Pi.
- `pilish-reconnect-runtime(buffer &optional callback)` reconnects only to the same
  retained owner. On discovery, socket or readiness failure it reads that exact
  identity's terminal receipt (workers read final task evidence instead): known successful closure
  retires the view; absent/wrong/unreadable or failed task evidence retains it as
  unavailable/stopped recovery. Reconnecting the same worker preserves its captured
  task binding and cancellation history, never rearming ambiguous input. No Stop or replacement launch is used as a status
  query. Shared `pilish-reload` uses this policy, not process replacement.
- `pilish-reconcile-worker-task(buffer runtime)` synchronously reconciles a retained
  worker view with read-only final task evidence, without Stop, input or reconnect.
  It performs one read/application and starts no polling.
  `runtime` pins the captured `:mux-id`, `:socket`, `:pi-pid`, `:pi-start-time` and
  `:pi-boot-id`; the current view must still have worker placement. Optional
  frontend parent/placement metadata need not be present in the captured identity.
  The existing task reader also pins any retained parent/task/lease binding.
  Only validated `complete` evidence retires chat/input through ordinary recovery,
  observers and callback settlement. Missing, pending, failed or mismatched evidence
  signals and retains the view. Pending evidence can capture binding/status; validated
  failure records its owning error, cancels polling and settles existing Close waiters
  with error. Retirement errors signal after cleanup and recovery retention. Success
  or an already dead buffer returns nil; a call during existing retirement does not
  wait for disposal. Integrations use this after parent task completion when a
  disconnected transport cannot report exit.
- `pilish-resume-stopped-session(buffer &optional callback)` is an explicit managed
  launch of an exact saved path with no prompt. Active/uncertain owners refuse;
  task-owned workers cannot be promoted into independent roots.
- `pilish-stop-runtime(buffer &optional callback)` performs acknowledged,
  identity-bound root stop everywhere and reconciles its terminal receipt before
  retiring the view. It permits confirmed `root` and independent
  `interactive-fork` placements; pending or failed discovery leaves placement
  unknown, so Stop/Close refuses without runtime
  control and retains the identity. It never signals a bare Pi PID or asks for
  confirmation.
- `pilish-close-session(buffer &optional callback)` closes the agent everywhere,
  using the parent-task cancellation protocol for workers. Before submitting
  `/worker-cancel`, it requires valid pending task evidence and a fresh
  `get_commands` response advertising that extension command, bound to the captured
  mux/transport/input context. A missing command/binding, failed query, changed
  context or expired Close sends no prompt and retains the view. Its callback
  receives nil only after matching final task completion and disposal, or an error
  string on failure/uncertainty, including a failed worker whose view it retired.
  See Worker task completion below.
- `pilish-disconnect-session(buffer)` disposes only this local detached view.
  Ordinary frontend/view teardown uses this primitive, not user Close. Task-owned
  worker completion must retain the view until final task evidence can be reconciled,
  using `pilish-reconcile-worker-task` when necessary. Unshared Pi retains its native
  process lifetime.
- `pilish-session-closed-functions(chat)` runs before terminal view disposal while
  public session/runtime/desktop accessors still work. Observers remove layouts
  and sidebar entries; they must not dispose buffers or send another stop. One
  observer's failure does not prevent remaining observers, buffer cleanup or
  callback settlement. Original/cleanup errors remain in the read-only recovery
  buffer and Close reports them. The hook does not run on socket loss, frontend
  exit or disconnection.
- `pilish-session-state-closed-p(state)` checks root terminal evidence or the
  read-only `pimux receipt --json --id <muxId>` query. Workers require matching
  complete task evidence even when saved runtime exit is known. Missing/failed
  evidence is not successful closure; this never sends Stop.

The callback-taking control APIs invoke the callback exactly once with nil
on acknowledged success/readiness, or an error string on failure/uncertainty.
An uncertain/failed stop retains the view and local recovery. Once termination
is authoritative, observer/cleanup failure still retires the active view, retains
all reported errors and unsent work in recovery, and settles callbacks once with
the error rather than claiming complete success. Runtime view state `"live"`
means the validated live boundary was reached; it is distinct from activity such
as streaming. `"disconnected"` or `"unavailable"` does not prove Pi stopped.
For a retained owner, only authoritative termination/stop reports `"stopped"`.
An identity-free saved conversation is also a stopped view: there is no runtime
to reconnect. Reconnect refuses it without discovery or launch; explicit Resume
still acquires the exact file's managed claim, attaching an existing compatible
owner or refusing conflicting ownership. Close has nothing to stop: it retires
the view through `pilish-session-closed-functions` and keeps unsent work in
recovery. The same holds for an `"unavailable"` view whose launch settled
without an identity, such as a start that pimux refused. Discovery also carries its advertised
activity state; consumers must not mistake that for view readiness.
Workers retain their parent-task/result protocol; cancellation/resume belongs to
that owner, not a root-stop fallback.

### Worker task completion

`pilish-runtime-task.el` reads the configured orchestration CLI as
`phimacs-task-status --id <muxId> --json`, with `PIMUX_DIR` set to the captured
socket's directory, independent of the frontend's default namespace. The CLI
validates private same-user evidence. Pilish matches the mux and actual worker
PID/start/boot identity, captures the parent process/task/lease binding from the
first validated record, and pins it for every later query. Read-only reconciliation
can accept first-seen complete evidence without a prior pending read or local Close.
Discovery's `:parent` is a frontend reference, not this task binding. The retained runtime carries `:task-binding`, latest
`:task-status`, `:task-cancel-requested` and any `:task-error` through reconnect and
desktop recovery.

After command discovery, Pilish rechecks task evidence and the original input
context before submitting cancellation. A definitive rejection clears the attempted
cancellation marker; another explicit Close repeats fresh admission. Unknown replies,
transport exit and uncertain delivery retain that marker and cannot authorize resend. A transport disconnect or
`pimux_exit` cannot complete the wait. Only a matching `complete` record proves
worker death plus owning-task cleanup/name release and retires the view. A
`failed` record reports its original error and keeps recovery, including for a
worker closed remotely without a local Close request. Only the exact owning parent
process publishes final evidence, so `pending` evidence whose parent process is dead
(gone, or its PID reused by another start/boot) is equally final uncertainty: Pilish
reports that the owner exited before cleanup, stops polling and keeps recovery.
Explicit Close of a failed or orphaned view
retires it only when the actual Pi and its mux are dead and either the read-only
`pimux receipt --json --id <muxId>` reports `stopped` for the view's exact launch
`operationId`, or the exact pimux service recorded as the runtime's `:service` is
dead: its owner has published final evidence or can never publish any, so nothing
else can finish the cleanup. Retirement runs closed observers, keeps the failure and unsent work in
`*Pilish closed agents*`, and settles Close with the failure, never nil. Reconnect,
restoration and `pilish-reconcile-worker-task` never retire failed workers. Missing,
unsafe or changed evidence is uncertainty, not permission for another prompt or root Stop.

A Close waiter times out after 45 seconds with an error. Read-only polling remains
owned by the retained view while validated task evidence is pending and its owner
lives, so late matching completion can retire it without recalling settled callbacks.
Each poll runs the CLI asynchronously and schedules the next read 0.25 seconds after
the previous one settles, so any number of pending views never blocks Emacs. Missing,
invalid or changed evidence cancels polling and clears the latest status while
retaining the pinned binding and local work for explicit reconciliation. Another Close joins reconciliation and never replays
a cancellation whose delivery may have succeeded. A late definitive rejection can
rearm explicit retry without recalling a timed-out callback. Final failure or local
view disposal also cancels polling. The owning frontend must not disconnect a worker view while its public
Close is awaiting task evidence.

The interactive menu exposes Attach (`J`), Reconnect (`C`), Resume stopped (`B`)
and one Close agent (`Q`). Chat `q` uses the same unconfirmed Close.
Abort (`C-c C-k`) stops a turn, not the agent. See
[MENU-RUNTIME.md](MENU-RUNTIME.md) for transition ordering.

## Desktop state and input recovery

`pilish-session-desktop-state(buffer)` returns serializable `:directory`, `:name`,
`:session-file`, `:runtime`, `:draft`, `:images`, `:followups`, `:quarantine`,
`:leaf-id`, `:context`, `:editor-notices` and `:submitted`. Preserve the complete
value rather than selecting only text and runtime ID. Materialized images are
saved data, not paths reopened on restore. Keep desktop files private.

`pilish-restore-session-state(state)` allocates a background view and attaches the
specified compatible surviving identity or resolves its service-recorded root
successor, adopting its current file and branch. Durable explicit root Close
returns nil instead of allocating an active view. Other root process receipts
require service resolution before retirement: no successor plus terminal evidence
removes the view asynchronously. Service absence retains an unavailable view and
local input, even if its old process has stopped.
Unsent work/abnormal exits remain in read-only `*Pilish closed agents*` recovery,
outside the active-agent list.

Root restoration after service restart or reboot belongs only to the service's
durable root journal, never to saved frontend state. It proves both old writers
dead before starting a new identity. Pilish uses read-only `pimux resolve` and a
fresh snapshot/live boundary; a previously-live root also attempts this recovery
automatically after transport loss. Desktop restoration never launches a Pi.
Unmanaged prior-boot views remain unavailable for explicit recovery. Workers are
never restored, and no prompt, tool, saved queue or shell command is replayed.

Other missing/incompatible owners remain unavailable with explicit recovery;
identity-free legacy conversations restore as stopped/resumable views requiring
explicit Resume. Saved automatic follow-ups and uncertain submissions become
suspended recovery, never armed work.

Text, images, local follow-ups and uncertain submissions composed for a previous
file/branch are quarantined before context adoption. `pilish-session-quarantine`
returns their labelled plain data. `pilish-restore-quarantined-input` requires
explicit selection/reuse confirmation in the current context and never sends it.
Ordinary linear append is not a branch change. Ambiguous editor-text notices are
recoverable selections, not draft overwrites. Desktop owners subscribe to
`pilish-session-desktop-state-functions(chat)` for image/queue/recovery changes
that need not edit the input buffer.

Shared `clear_queue` is destructive across every frontend. Every intentional
clear/recover action confirms that scope. Only the requester receives all
acknowledged removed text; it is retained as labelled shared recovery without
per-client provenance or automatic resend. A lost acknowledgement remains
uncertain, not an invented recovery or retry. Shared Abort confirms before local
mutation and clears once; delayed Abort never clears a newly accepted queue.
Detailed invariants and focused tests belong in [DRAFTS.md](DRAFTS.md).

Deck owns layout and this local desktop state, not process lifetime. It restores
surviving roots/workers by identity; a missing native shell/panel stays a stopped
placeholder and does not replay its command. Explicit Resume and unconfirmed
Close remain distinct from layout hiding and Emacs restart.

## Managed storage boundary

Managed starts and stopped-file mutations share pimux's atomic canonical-path/
inode claims under fixed `/tmp/phimacs-session-claims-<uid>`, independent of
`TMPDIR`, release version, agent directory and `PIMUX_DIR`. A live or uncertain
wrapper **or actual Pi** retains ownership. Refused sockets and timeouts do not
prove death. Tests cannot redirect that production policy into arbitrary files.

The browser's managed rename/delete/append/rewrite/export paths use the owning
public claim facilities, not scan-then-write checks or raw Pi fallback. Live name
and export changes use owning RPC commands. Live tree navigation uses the
runtime's `pimux-tree-navigate` extension command, never a disk rewrite. Pi lacks
an owning live label RPC, so label writes to an active file refuse rather than
writing beside the owner.
See [STORAGE.md](STORAGE.md) for leases, alias/digest validation and explicit
unshared behavior. This cooperative protection does **not** certify raw external
Pi, arbitrary editors, or Pi's unguarded internal pre-I/O storage mutations;
universal storage safety requires an upstream owning API. No Pi fork is included.

## Essential grammar provisioning

The owning `pilish-install-essential-grammars(directory)` API explicitly provisions
only Markdown and Markdown-inline into a new empty directory. On Emacs 31.1 it
uses source revision `41ff24a6c775492c543b09228aeb98d1cd2b3a0f`, version **v0.5.4**,
and validates both generated libraries with **ABI 15** in a fresh subprocess at
the requested absolute paths. It neither borrows home/system grammars nor installs
optional languages. Its report includes API/Emacs version, exact destination,
source URLs/revisions/subdirectories, library SHA-256 values and ABI. Retain the
corresponding source/licenses and provisioning report with the reusable assets. Normal startup
does not call the installer. The interactive unshared installer keeps its older
Emacs-compatible recipe policy. See README.org for the exact public call.

## Isolated verification

The deterministic `test/pilish-runtime-test.el` uses private fake Unix peers,
validates hello/identity/readiness and refuses prelive input.
`test/pilish-runtime-task-test.el` adds read-only CLI boundaries for captured
namespaces, missing/failed/wrong/unsafe task evidence, Close of failed and orphaned
workers with and without exact pimux termination proof, asynchronous polling and
cancelled reads, dead-owner uncertainty, timeout/late completion,
reconnection without repeated cancellation, definitive-rejection retry versus uncertain
delivery, pending-Close input gates, unsent FIFO recovery, notification failures
and public read-only reconciliation after disconnected natural completion.
Restoration regressions cover completion racing attachment/readiness, uncertain
workers without independent Resume, pending-only task polling, verified prior-boot
root reopening, incomplete boot evidence and uncertain starts without retry.
Shared/drafts/queue/
menu/storage suites cover authoritative snapshots and recoverable input. Use
fresh locked Lisp sources and freshly provisioned essential grammars, not home
packages or a merely plausible old cache stamp. The Makefile exposes focused
`test-runtime`, `test-shared`, `test-drafts`, `test-shared-input`, `test-queue`,
`test-menu-detached` and `test-storage` targets; its normal dependency installer is
an explicit setup action, not reference startup or clean-install evidence.

### Real Pi, faux providers only

`test/pilish-runtime-native-test.el` is an opt-in lane with these exact inputs:

| Environment | Required value |
|---|---|
| `PHIMACS_NATIVE_PILISH` | `1` to opt in |
| `PHIMACS_TEST_ROOT` | A private marked synthetic root created by pimux's `createClaimTestEnvironment()` |
| `PHIMACS_PI_EXECUTABLE` | Absolute selected physical Pi executable |
| `PHIMACS_PIMUX_EXECUTABLE` | Absolute compiled candidate pimux executable |
| `PHIMACS_FAUX_EXTENSION` | Absolute audited `test/support/faux.ts` fixture from the selected source input |
| `PHIMACS_TASK_STATUS_EXECUTABLE` | Absolute compiled task-status CLI from the selected graph (required for managed-worker cases) |
| `PHIMACS_ORCHESTRATION_ROOT` | Absolute candidate source root with compiled orchestration/pimux and lifecycle fixtures (managed-worker cases) |
| `PHIMACS_NATIVE_EMACS_ENDPOINT` | Private socket under the synthetic root, only for the live-companion case |
| `PILISH_NATIVE_SELECTOR` | `^pilish-runtime-native-test-emacs-companion-` for the live-companion runner |
| `PILISH_TEST_ASSETS` | Fresh provisioned `emacs` directory with `provision.json` and locked Lisp sources |
| `PILISH_TEST_GRAMMARS` | Fresh essential grammar directory |

The harness must set a disposable HOME, propagate the helper's returned environment
(including its isolated `PIMUX_DIR`), and clear inherited orchestration/worker/
parent-task identity. Conversations stay inside that root's `sessions/` subtree.
The constrained marker API rejects production paths and escaping aliases. Never
hand-point a test override at a real agent directory. Load dependencies from the
fresh provision receipt and candidate sources only, for example from the candidate
source directory with those environment variables supplied by the harness:

```sh
emacs -Q --batch -L . -L test \
  --eval '(progn
    (require (quote json))
    (let* ((assets (getenv "PILISH_TEST_ASSETS"))
           (receipt (with-temp-buffer
                      (insert-file-contents (expand-file-name "provision.json" assets))
                      (json-parse-buffer :object-type (quote plist)))))
      (dolist (package (append (plist-get receipt :packages) nil))
        (dolist (directory (append (plist-get package :loadPaths) nil))
          (add-to-list (quote load-path) (expand-file-name directory assets)))))
    (setq native-comp-jit-compilation nil
          pilish-essential-grammar-action (quote warn)
          treesit-extra-load-path (list (getenv "PILISH_TEST_GRAMMARS"))))' \
  --eval '(progn
    (require (quote pilish-runtime-native-test))
    (ert-run-tests-batch-and-exit "pilish-runtime-native-test-"))'
```

Before deleting the synthetic root, cleanup must reconcile and stop every runtime
owned by that test namespace, including a committed runtime whose UI failed before
its ready callback. Do not signal foreign PIDs or treat missing acknowledgement as
proof of exit. Retain uncertain test-operation evidence for inspection.

The candidate's real Pi/faux tests cover creation from Pilish and an
independent creator, equal contextual direct-socket attachment, zero-client
survival, reconnect/desktop restore to the same actual Pi, another frontend's
moved-session adoption/quarantine and acknowledged explicit stop. The public
saved-file entry point opens its exact existing conversation during asynchronous
startup and submits once there. The migrated identity-free view additionally
resumes its exact persisted history without submitting a draft or any prompt.
`pilish-runtime-native-test-service-restores-idle-history-without-replay`
restarts its explicit isolated foreground service: history loads idle in a fresh
Pi, local work stays suspended, and restoring the old saved identity again attaches
that one successor without another writer or prompt. The fixture owns and stops
its own service; it never starts or restarts a user service. Cross-frontend service
restart coverage also lives in Phimacs's sharing integration lane. An injected renderer failure during a real
snapshot/live sequence retains identity and recoverable input, refuses prompts,
and recovers only through explicit reconnect without replay. The independent
synthetic peer captures the snapshot's exact `inputContext` before its one action.
The five `pilish-runtime-native-test-managed-` cases use the real compiled
`runEphemeralWorker`, detached faux Pi and worker-frame cancellation. The
`test/support/managed-parent.mjs` fixture pauses native host cleanup after actual
worker death/ended lease while name/task cleanup remains pending. Close stays
unsettled until cleanup/name release and final publication; failed final cleanup
retains recovery, and a missing initial binding sends no cancellation. Adversarial
wrong final binding and an injected waiter timeout both retain recovery until real
late completion without recalling their settled callbacks. Compile
orchestration first with `npm run compile --workspace=@phimacs/orchestration`
from Phimacs. Run these cases and the
remaining native cases separately with bounded native-lane timeouts.
`pilish-runtime-native-test-emacs-companion-direct-close-awaits-task-publication`
additionally uses the actual Emacs host companion and `emacsclient` against a
private test-owned live editor endpoint, without an orchestration Stop waiter.
It requires `PHIMACS_NATIVE_EMACS_ENDPOINT` and a disposable editor/frame: the
headless batch invocation above does not provide that endpoint. With the same
candidate load paths and asset initialization, omit `--batch`, set the two
companion environment variables above, and load
`test/support/emacs-companion-tests.el` instead of calling the batch ERT runner.
That helper runs the selector and exits its own editor. For headless PGTK, launch
it under a dedicated `xvfb-run -a env GDK_BACKEND=x11 emacs -Q ...`, never an existing
display or user daemon. Keep task-owned views alive through host cleanup and retire
only after final publication.
Deck's three native tests plus
its disposable-daemon TTY smoke passed desktop restore, stopped-view recovery,
no shell replay and frontend restart/ordinary-exit survival with unchanged mux/Pi
identity. These native-runtime checks do not grant publication approval or certify
unrelated frontends. [Phimacs development](../phimacs/docs/development.md) owns
checkout checks and the disposable cross-frontend lane. Source edits do not
implicitly reload or restart user services.
