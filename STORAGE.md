# Managed saved-session mutations

The configured protocol-2 runtime owns session storage policy. Pilish's session
browser loads `pilish-storage.el` directly; no extra entry-point registration is
needed. Explicit unshared/plain-Pi mode retains the upstream/native browser policy.

## Stopped-file contract

The Lisp frontend invokes the pinned source's `scripts/pilish-storage.mjs` with
Node 24, an absolute configured `pilish-runtime-pimux-executable`, and one JSON
request on stdin. The helper resolves that executable's compiled public
`@phimacs/pimux/ownership` and `process-identity` exports. It does not copy claim
code, search sibling repositories, use `NODE_PATH`, inspect home caches or fall
back to a raw Pi writer.

For append/delete/rewrite the helper acquires a common `kind:"lease"` claim before
any mutation. Its wrapper identity includes its exact Linux PID/start/boot identity;
`pi` starts null for in-process operations. Trash records the auxiliary local
writer's exact process identity in that second identity slot; helper death must
not free a lease while that writer can still move the file. The lease covers the
complete fresh read, validation and write, and only its unchanged capability is
released. A live or uncertain RPC, TUI or other lease owner refuses,
including symlink/hardlink aliases. Refusal never retries through an unguarded path.
Synthetic claim namespaces cannot authorize files outside their marked session root.

Supported requests are deliberately narrow:

- `append`: only `session_info` with a nonempty `name`, or `label` with `targetId`
  and an optional text `label`. The helper rereads the physical tail under the
  lease, skips malformed trailing lines, checks fresh entry IDs, preserves missing
  final newlines, and never creates a missing session. An omitted label clears it.
- `delete`: the confirmed `expectedCanonical` identity and explicit `trash` policy
  are checked after acquiring the lease. A selected symlink itself is removed,
  never its target. Managed trash uses optional `gio trash` with its local VFS and
  XDG trash policy. Failure never falls back to permanent deletion. The browser's
  confirmation still names permanent versus trash and direct-fork consequences.
- `rewrite`: raw base64 `contents` plus mandatory `expectedSha256` of the source
  snapshot. Changed bytes refuse. A sibling exclusive temporary file preserves
  modes and commits by rename under the claim. Old/new inode indexes reconcile
  before releasing the lease. The browser takes the digest before deriving its
  navigation bytes, not after them.
- `export`: the explicit absolute release Pi and a **new** `.html` output. The
  helper invokes the configured `pimux tui` managed launcher, which claims before
  Pi's repair-capable open and waits for actual exit. It never invokes raw Pi.
  Existing output files/aliases are not overwritten. Empty owned reservations
  are removed on failure; uncertain nonempty output is retained for inspection.

Requests are bounded at 128 MiB, including base64 expansion. Receipts carry an
operation ID and `committed:true`. A release failure after commit reports that
operation identity and uncertainty; clients never automatically replay it. No
lease token is returned in public output or diagnostics.

## Public Lisp APIs

- `pilish-storage-managed-p()` consults the owning
  `pilish-runtime-configured-p()` contract.
- `pilish-storage-file-digest(file)` returns the exact raw SHA-256 without opening Pi.
- `pilish-storage-append-entry(file,type,payload,expected-canonical?)` performs a
  stopped append, optionally bound to the canonical identity selected before a
  confirmation/rename prompt.
- `pilish-storage-delete-session(file,trash,expected-canonical)` performs deletion.
- `pilish-storage-rewrite-session(file,lines,expected-digest)` performs a stopped
  raw-line rewrite. Digest acquisition must precede deriving the lines.
- `pilish-storage-export-session(file,output,pi-executable)` performs managed export.
- `pilish-storage-call(request)` exposes the same narrow receipt/error contract.

These functions do not acquire or refresh authentication, start inference, inspect
live discovery as a substitute for a claim, or retry an uncertain mutation.
Remote managed mutations refuse; explicit unshared TRAMP keeps its native policy.

## Owning-runtime integration boundary

Current-session name changes retain `set_session_name` RPC. Live exports retain
`export_html` RPC. A stopped current view instead uses the leased append path.

Pi 1.4's RPC command set has no tree-navigation or label command. The imported
browser's live tree navigation rewrites disk and resumes; that cannot be used next
to a protocol-2 owner. The managed lease correctly refuses those active-file
writes, including the current runtime, instead of pretending an idle check is a
lock. Full live managed tree/label controls therefore need an explicit owning
runtime command/capability in the runtime integration. Until wired, these actions
report the claim refusal; no feature is silently converted to an unsafe parallel
writer. The reusable stopped-file primitives are complete independently of that
runtime command. Strong universal protection from raw external Pi/internal storage
mutations still requires the upstream owning API described by the runtime package.

## Verification

Use fresh pinned Lisp sources and essential grammars, never a personal package or
grammar directory. The executable inputs must be compiled release candidates:

```sh
PILISH_TEST_ASSETS=/absolute/fresh-assets/emacs \
PILISH_TEST_GRAMMARS=/absolute/fresh-grammars \
PILISH_TEST_PIMUX=/absolute/release/node_modules/.bin/pimux \
PILISH_TEST_PI=/absolute/release/node_modules/.bin/pi \
  node test/run-storage-tests.mjs
```

This runs deterministic ERT frontend contracts, the selected existing browser
rename/delete/label/navigation regressions, warnings-as-errors source compilation,
checkdoc, and multiprocess Node tests. The latter exercise actual common claims,
aliases, live-Pi/dead-wrapper refusal, digest-bound concurrent rewrites, a real
managed launcher blocked by a lease, real stopped export without provider calls,
Emacs/helper JSON framing, trash inside a synthetic XDG home, and helper death
while an identity-tracked auxiliary trash writer still lives. Every conversation
and claim is synthetic. No production runtime, user's Emacs daemon or account data
is used. Pre-existing obsolete `when-let` warnings in the imported browser test
file are reported, not suppressed or presented as warning-free full-suite evidence.
