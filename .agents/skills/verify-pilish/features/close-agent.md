# Close agent

## User contract

Chat `q`, menu `Q` and `pilish-close-session` close the agent everywhere without
confirmation, even while busy. A root uses identity-bound stop; a worker requests
its exact task's cancellation and waits for matching final owning-task cleanup,
not runtime exit alone. Failure or lost acknowledgement retains the view and
recoverable input. Root authoritative remote exit removes active views without
sending another stop; worker remote exit obeys the same final-task evidence gate. Unsent input and crash details
remain in read-only `*Pilish closed agents*`, not a stopped active-agent placeholder.

Emacs exit, direct buffer disposal and transport loss only disconnect. They never
implicitly stop, restart or replay a detached agent. Desktop restoration returns
nil for authoritative terminal identities; absent evidence remains unavailable.
Workers require complete task evidence even when a stopped runtime receipt exists.
Failed attachment/readiness reconciles that evidence too. Unknown workers remain
parent-task-owned, without independent Resume; only validated pending evidence
permits read-only polling.

## Focused evidence

Run `make test-runtime test-menu-detached` with explicit isolated locked
Lisp/grammar dependencies. The owning suites cover actual Unix-socket remote
termination, no confirmation, acknowledgement ordering, worker runtime-versus-task
completion, uncertainty recovery, repeated close and read-only terminal-receipt
reconciliation. `test/pilish-runtime-task-test.el` covers task namespace/binding,
missing/failed/wrong/unsafe evidence, timeout/late completion and reconnect without
repeated cancellation, pending-Close submission/drain gates, unsent FIFO recovery,
notification failure and definitive-rejection retry versus uncertain delivery.
It also covers restoration races at socket/readiness failure and polling stopping
on missing, invalid, changed or failed evidence.
Run `test/pilish-command-context-test.el` for captured mux/receipt identity checks.

For actual Pi/faux evidence use the explicit isolated native lane documented in
[RUNTIME.md](../../../../RUNTIME.md), selecting
`pilish-runtime-native-test-creates-detaches-restores-and-stops` and
`pilish-runtime-native-test-remote-close-removes-active-view`, plus the five
`pilish-runtime-native-test-managed-` cases with real compiled orchestration,
worker-frame cancellation and event-gated final cleanup. The separate
`pilish-runtime-native-test-emacs-companion-direct-close-awaits-task-publication`
uses an isolated live Emacs endpoint and the real host companion: direct public
Pilish Close must retain its view through task cleanup without an orchestration
Stop waiter. The configured release
must supply both read-only pimux receipt and orchestration task-status CLIs. Assert Pi identity
exit, chat/input disposal and no resurrected saved view. This is lifecycle evidence,
not a screenshot/pixel claim or proof of a real provider call.
