# Detached runtime API and verification

This is the privately tested Phimacs integration candidate, not a published
release. Pilish remains a separate upstream-tracking fork. Phimacs consumers must
acquire the exact tested fork revision and retained source archive from the
complete immutable release; stock MELPA Pilish and a moving default branch do not
establish the integration contract. Ordinary unshared Pilish remains supported.

## Configuration and capabilities

The detached candidate requires Linux, Node 24 and Emacs 31.1 or newer. Provision
Lisp/native dependencies and essential grammars explicitly before reference
startup. No normal startup download, private provider, personal configuration or
existing home cache is a dependency.

```elisp
(require 'pilish)
(pilish-configure-runtime
 :pi-executable "/absolute/release/node_modules/.bin/pi"
 :pimux-executable "/absolute/release/node_modules/.bin/pimux"
 :protocol 2
 :pi-version "1.4.0")
```

Replace both paths with executable paths from one complete selected release. The
optional `:pi-sha256` is the release's lowercase entry-point SHA-256. The compiled
owning launcher validates the exact host/version and, when supplied, its digest
before opening a conversation. Whole-release dependency integrity remains the
installer/manifest's responsibility. An unrelated global Pi is neither required
nor updated. Authenticate the selected release with the intended private agent
directory before intentional provider use; credentials are never release assets.

`pilish-integration-capabilities()` returns API version 1 and pimux protocol 2,
including implemented symmetric socket, runtime identity, desktop state, stopped
view, context-bound input, managed storage and essential grammar capabilities.
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
compiled CLI as `pimux start --json -- <absolute Pi> --mode rpc ...`. The launcher
claims the exact session before Pi opens it, commits the detached owner and returns
an identity receipt. It is short-lived, not an stdio bridge. Pilish then connects
directly to the socket as an ordinary peer; the creator has no privileged lifetime.

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

Closing a buffer, Emacs, the last client or a browser view disconnects only.
**Accepted work and provider waits may continue and incur usage invisibly.**
There is no idle auto-stop, central scheduler, automatic crash restart or paid
prompt replay. Reconnect and desktop restoration never submit `continue`, tools,
queued work or inferred retries. A pre-commit launcher cancellation belongs to its
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
  retained owner. Shared `pilish-reload` uses this policy, not process replacement.
- `pilish-resume-stopped-session(buffer &optional callback)` is an explicit managed
  launch of an exact saved path with no prompt. Active/uncertain owners refuse;
  task-owned workers cannot be promoted into independent roots.
- `pilish-stop-runtime(buffer &optional callback)` performs acknowledged,
  identity-bound stop everywhere and reconciles its terminal receipt. The caller
  owns confirmation, including an idle agent. It never signals a bare Pi PID.
- `pilish-close-session(buffer)` closes a detached view, not its runtime. Unshared
  Pi retains its native process lifetime.

The three callback-taking control APIs invoke the callback exactly once with nil
on acknowledged success/readiness, or an error string on failure/uncertainty.
A failed stop retains the view and local recovery. Runtime view state `"live"`
means the validated live boundary was reached; it is distinct from activity such
as streaming. `"disconnected"` or `"unavailable"` does not prove Pi stopped.
For a retained owner, only authoritative termination/stop reports `"stopped"`.
An identity-free saved conversation is also a stopped view: there is no runtime
to reconnect. Reconnect refuses it without discovery or launch; explicit Resume
still acquires the exact file's managed claim, attaching an existing compatible
owner or refusing conflicting ownership. Discovery also carries its advertised
activity state; consumers must not mistake that for view readiness.
Workers retain their parent-task/result protocol; cancellation/resume belongs to
that owner, not a root-stop fallback.

The interactive menu exposes Attach (`J`), Reconnect (`C`), Resume stopped (`B`)
and Stop agent everywhere (`K`). Abort (`C-c C-k`) stops a turn, not the agent.
See [MENU-RUNTIME.md](MENU-RUNTIME.md) for confirmations and transition ordering.

## Desktop state and input recovery

`pilish-session-desktop-state(buffer)` returns serializable `:directory`, `:name`,
`:session-file`, `:runtime`, `:draft`, `:images`, `:followups`, `:quarantine`,
`:leaf-id`, `:context`, `:editor-notices` and `:submitted`. Preserve the complete
value rather than selecting only text and runtime ID. Materialized images are
saved data, not paths reopened on restore. Keep desktop files private.

`pilish-restore-session-state(state)` allocates a background view and attaches the
specified compatible surviving identity, adopting its current file and branch.
Missing/incompatible retained owners stay as unavailable views with explicit
recovery; identity-free legacy conversations restore as stopped/resumable views,
not failed connections. Restoration never opens their JSONL for writing or starts
a fresh Pi. Saved automatic
follow-ups and uncertain submissions become suspended recovery, never armed work.

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
placeholder and does not replay its command. Its explicit Resume and confirmed
Stop actions remain distinct from hide, disconnect and Emacs restart.

## Managed storage boundary

Managed starts and stopped-file mutations share pimux's atomic canonical-path/
inode claims under fixed `/tmp/phimacs-session-claims-<uid>`, independent of
`TMPDIR`, release version, agent directory and `PIMUX_DIR`. A live or uncertain
wrapper **or actual Pi** retains ownership. Refused sockets and timeouts do not
prove death. Tests cannot redirect that production policy into arbitrary files.

The browser's managed rename/delete/append/rewrite/export paths use the owning
public claim facilities, not scan-then-write checks or raw Pi fallback. Live name
and export changes use owning RPC commands. Pi 1.4 lacks owning live tree/label
RPC, so those active-file mutations refuse rather than writing beside the owner.
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
corresponding source/licenses and report with release evidence. Normal startup
does not call the installer. The interactive unshared installer keeps its older
Emacs-compatible recipe policy. See README.org for the exact public call.

## Isolated verification

The deterministic `test/pilish-runtime-test.el` uses private fake Unix peers,
validates hello/identity/readiness and refuses prelive input. Shared/drafts/queue/
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
| `PHIMACS_PI_EXECUTABLE` | Absolute exact candidate release Pi executable |
| `PHIMACS_PIMUX_EXECUTABLE` | Absolute compiled candidate pimux executable |
| `PHIMACS_FAUX_EXTENSION` | Absolute audited `pimux/test/fixture.ts` fixture from the selected source input |
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

The candidate's five real Pi/faux tests passed: creation from Pilish and an
independent creator, equal contextual direct-socket attachment, zero-client
survival, reconnect/desktop restore to the same actual Pi, another frontend's
moved-session adoption/quarantine and acknowledged explicit stop. The public
saved-file entry point opens its exact existing conversation during asynchronous
startup and submits once there. The migrated identity-free view additionally
resumes its exact persisted history without submitting a draft or any prompt. An injected renderer failure during a real
snapshot/live sequence retains identity and recoverable input, refuses prompts,
and recovers only through explicit reconnect without replay. The independent
synthetic peer captures the snapshot's exact `inputContext` before its one action. Deck's three native tests plus
its disposable-daemon TTY smoke passed desktop restore, stopped-view recovery,
no shell replay and frontend restart/ordinary-exit survival with unchanged mux/Pi
identity. These are candidate-native results, **not** packed clean-install,
full Tau/orchestration acceptance or publication approval. Release/source retention,
security/licensing and the complete private cross-frontend matrix remain separate
gates; no user daemon or running service was restarted for this evidence.
