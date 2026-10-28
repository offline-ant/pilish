# Pilish — Development Guide

Pilish is an Emacs frontend for the [Pi coding agent](https://pi.dev).
A session has a Markdown chat window and an ordinary prompt-editing window.
Pilish communicates with the Pi CLI through JSON-over-stdio RPC.

## Start here

- Read [README.org](README.org) for installation and user-visible behavior.
- Run `make help` for supported test, integration, benchmark, and quality targets. The [Makefile](Makefile) owns prerequisites and command details.
- Use [the verification skill](.agents/skills/verify-pilish/SKILL.md), or `/skill:verify-pilish`, to drive user-facing behavior and capture evidence. Its feature map selects the relevant journey.
- Read [the fake Pi contract](test/support/fake-pi-contract.md) before changing deterministic subprocess fixtures.
- Read each module's `Commentary` and owning tests before changing its behavior. The source tree, not this guide, is the file inventory.

## Architecture and ownership

- `pilish.el` starts sessions. `pilish-core.el` owns the process protocol. `pilish-ui.el` owns shared session state and disclosure behavior. `pilish-render.el` owns streaming, tool display, and cooling.
- `pilish-jsonl.el` reads Pi's saved data. `pilish-browse.el` owns session and tree browsers. `pilish-snapshot.el` owns independent read-only saved-conversation observers.
- Keep internal `require` dependencies acyclic. `pilish-ui.el` does not depend on `pilish-jsonl.el`. `pilish-menu.el` and `pilish-input.el` are siblings. `pilish-evil.el` is an optional leaf integration.
- Use the accessors in `pilish-ui.el` for cross-module state mutations. Direct `setq` is fine for state owned within a module.
- Loading Pilish must not make `md-ts-mode` claim unrelated Markdown buffers.
- Protocol settlement, owner-scoped rendering, cold-tool retention, and saved-conversation identity have local contracts in their owning modules and tests. Read those contracts instead of inferring behavior from event names, tool names, or output text.

## Workflow

1. Choose the owning module and the narrowest existing test. Add regressions to that suite rather than creating a parallel test layout.
2. Run focused tests during development, then `make check` before committing. Run the fake or real integration lane when the subprocess contract changes.
3. Before opening a PR, use `/skill:verify-pilish` for every changed user-facing feature and preserve its evidence. Standard tests do not replace this user-action pass.
4. When a user-facing journey changes, update the verification feature map through `/maintain-verification-skill`. Report product regressions separately from documentation drift.
5. Treat benchmark smoke targets as correctness checks. Use the primary benchmark lanes and their evidence rules for performance claims.

The unit suite runs in batch Emacs. Do not run the full unit suite inside an interactive Emacs. The GUI suite uses real frames with a deterministic fake backend. The real integration target starts Ollama.

For RPC changes, consult the Pi source that matches `PI_VERSION` in the Makefile. Its `packages/coding-agent/docs/rpc.md` and RPC implementation are the protocol reference.

## Conventions

- Prefix public symbols with `pilish-` and internal symbols with `pilish--`.
- Name tests after their owning suite, such as `pilish-test-...` or `pilish-gui-test-...`.
- Require `pilish-test-common` in module test files that use shared fixtures.
- Install the pre-commit hook with `make install-hooks`. It runs `make check`.
- Stage files explicitly with `git add <specific-files>`. Run `git status` before committing and keep test artifacts out of the commit.

## Session API contract

`pilish-start-session` creates background sessions that never display buffers, offer interactive dependency installation or prompt for missing tree-sitter grammars; a nil name selects the directory's default session and `:session-file` resumes a session with its history. Launch args/environment survive reload. Integrations register `pilish-session-environment-functions` before first spawn (failing functions are warnings). Consumers read sessions only through the public accessors in `pilish.el` (`pilish-session-directory`, `-name`, `-title`, `-file`, `-model`, `-context-usage`, `-queued-prompts`, `-busy-p`, `-exists-p`, `pilish-view-session-file`); add an accessor rather than letting integrations read `pilish--` state. `pilish-submit-prompt` relies on Pi's own queue (`queue_update`), not Pilish's follow-up queue. Pilish has no server or host-specific integration dependency. Covered by `test/pilish-session-api-test.el` (`make test-session-api`).

## Chat styles

`pilish-style.el` (requires ui; render requires it) defines and implements `pilish-chat-style` (its `:set` uses `set-default`, so a `let` scopes it). `pi` decorates with overlays from a `jit-lock` function over unchanged buffer text: setext turn headings (recognized by upstream's `pilish--at-turn-heading-p` plus `pilish--style-summary-heading-re` for Compaction/Branch Summary; hidden via invisibility spec `pilish-style-heading`, which `pilish--visible-text-span-p` honours through `get-char-property`, so visible copies omit them), the `pilish-thinking-block` and `pilish-custom-message` text properties, and tool block overlays (padding strings follow the overlay face; `pilish--tool-block-finalize` flushes font-lock so they update). Each pass touches only the jit-lock region, the heading owning it and the next heading; decorations are reused by kind and start, so a redraw costs the same however long the turn is (keep it that way: no widening to whole turns, no all-pairs scans). Tool block overlays are disjoint. Tool faces are remapped buffer-locally (`face-remap-set-base`). Successful tools finalize with `pilish-tool-block-success` (inherits `pilish-tool-block`, so classic is unchanged). `pilish-input-window-height` `fit` sizes input windows to the draft (`pilish-fit-input-window`, after-change timer, size-change refit); `pilish-split-input-window` is the public split used by window managers such as pi-deck. Covered by `test/pilish-style-test.el` (`make test-style`).

## Extension dialogs

`pilish-dialog.el` (requires ui; render dispatches confirm/select/input/editor requests to `pilish--handle-extension-dialog`) owns extension dialogs: the per-process pending list (requests are event plists plus `:pilish-timer` and `:pilish-editor`), `pilish-extension-dialog-functions`, `pilish-session-pending-dialogs`, the answer/cancel commands (bound to `C-c C-a`/`C-c C-x` in chat and input maps, menu `A`/`D`) and the header segment. Core only runs `pilish--process-exit-functions`, through which pending requests close when their process exits. Editor requests always open a separate `*pilish-editor: …*` buffer that is killed when its request closes. `pilish-extension-dialog-style` `minibuffer` (default) uses upstream's prompt helpers unchanged; `inline` appends read-only button widgets at chat end, protected from Markdown fontification by the `pilish-dialog` property in `pilish--restore-tool-properties`. Output appended after a waiting widget moves the widget back to the end (`pilish--dialog-reanchor`, debounced from `after-change-functions`). A dialog takes focus only when it follows an answer given from a widget while one of the tools running at that answer still runs (or, outside tools, while the session is idle). Pi never reports requests it settles itself: request timeouts expire them locally and Stop cancels pending requests between `clear_queue` and `abort`; a run Pi aborts without Pilish's Stop leaves its widgets until answered, cancelled or expired. Covered by `test/pilish-dialog-test.el` (`make test-dialog`).

