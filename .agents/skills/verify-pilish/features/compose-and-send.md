# Compose and send

Pilish opens a chat and input pair, then sends consecutive prompts without losing the later submission.

## Sub-features

- `compose-layout` opens a live session with chat and input windows.
- `compose-send` submits a prompt and displays its reply.
- `compose-sequential` submits a second prompt after the first turn and returns to idle.
- `compose-submit-navigation` returns a scrolled-back chat to the live end on submission, keeps input focus, and preserves the reading position when `pilish-jump-to-end-on-submit` is nil.
- `compose-queued-messages` shows steering and follow-ups above the draft; its Restore and Clear controls and Stop take them back, and only Stop ends the run.
- `compose-header-toggles` hides the input header's activity phase, cost, and context usage when their options are customized off.

## How to get to it (user POV)

- Run `M-x pilish` from a project directory.
- Enter a prompt in the input buffer and press `C-c C-c`.
- Enter and send another prompt after the first reply.
- Scroll the chat back while composing, then submit with `C-c C-c`. Set `pilish-jump-to-end-on-submit` to nil to keep the reading position instead.
- While Pi works, queue with `C-c C-s` and `M-RET`, then click Restore or Clear above the draft, press `M-<up>` or `C-c C-u`, or stop with `C-c C-k`.
- Customize `pilish-header-activity-phase`, `pilish-header-cost`, or `pilish-header-context-usage` with `setopt` or `M-x customize-group RET pilish`.

## Driving it with Pilish harnesses

Preconditions:

- The Doctor check passed. `RUN_DIR` is a new empty evidence directory.

- **Open the session.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-session-starts 2>&1 | tee "$RUN_DIR/layout.log"`. Record `layout.exit`. A passing, non-skipped result proves the fake process and stacked chat and input windows.
- **Send two prompts.** Run `./test/run-gui-tests.sh --headless pilish-gui-test-send-waits-for-turn-start 2>&1 | tee "$RUN_DIR/send.log"`. Record `send.exit`. The test sends through `pilish-send`, displays the fake reply to the second prompt, and returns to idle.
- **Submit while reading earlier text.** Run `G1_CAPTURE="$RUN_DIR/submit" ./test/run-gui-tests.sh --headless pilish-gui-test-submit-jump-to-end-option 2>&1 | tee "$RUN_DIR/submit.log"`. Record `submit.exit`. With Pi style and a long earlier exchange, typing preserves the view. `C-c C-c` returns to the live end with the option on; with it off, the point and viewport stay on the earlier text. Both cases keep input focus and display the fake reply. Require zero status, `PASS: pilish-gui-test-submit-jump-to-end-option`, `0 skipped`, and nonempty `submit/submit-jump-on.png` and `submit/submit-jump-off.png`. `make test-answer` also covers steering, follow-ups, double-RET, refused/empty submissions and hidden chats.
- **Take queued messages back.** Run `G1_CAPTURE="$RUN_DIR/queue" ./test/run-gui-tests.sh --headless pilish-gui-test-queue-restore-clear-and-stop 2>&1 | tee "$RUN_DIR/queue.log"`. Record `queue.exit`. During a slow fake run, real steering and a local follow-up show above the draft. A real click on Restore moves them into the draft ahead of it, a click on Clear leaves the draft and fills the kill ring, and both keep the run going; `C-c C-k` restores them and stops it. Require zero status, `PASS: pilish-gui-test-queue-restore-clear-and-stop`, `0 skipped`, and nonempty `queue/queue-panel.png`, `queue/queue-restore.png`, `queue/queue-clear.png` and `queue/queue-stop.png`. `make test-queue` covers ordering, the bounded panel, a follow-up being submitted, failed clears and session switches.
- **Hide header fields.** Run `G1_CAPTURE="$RUN_DIR/header" ./test/run-gui-tests.sh --headless pilish-gui-test-input-header-field-toggles 2>&1 | tee "$RUN_DIR/header.log"`. Record `header.exit`. After a fake turn reports session stats, the displayed input header shows `idle`, `$0.25`, and `25.0%/200k`. Turning the three options off with `setopt` repaints it without them, and turning cost back on restores only the cost. The test writes `header-default` and `header-hidden` traces and PNG frames.
- **Check the proof.** Require zero statuses and nonempty logs. Require `PASS: pilish-gui-test-session-starts`, `PASS: pilish-gui-test-send-waits-for-turn-start` and `PASS: pilish-gui-test-input-header-field-toggles` in their respective logs, plus `0 skipped` in all three. Use `test "$(cat "$RUN_DIR/layout.exit")" -eq 0`, `test "$(cat "$RUN_DIR/send.exit")" -eq 0`, `test "$(cat "$RUN_DIR/header.exit")" -eq 0`, `test -s "$RUN_DIR/layout.log"`, `test -s "$RUN_DIR/send.log"`, `test -s "$RUN_DIR/header.log"`, `test -s "$RUN_DIR/header/header-default.png"`, and `test -s "$RUN_DIR/header/header-hidden.png"`.

## Gotchas

- The fake supplies deterministic replies. It does not prove provider authentication or model output.
- Header toggle, submission navigation and queued message tests write PNG captures; the other tests provide assertion logs.
- Completion and image attachment are outside this seed entry, as are steering and abort beyond the queued message journey. Do not claim them from this run.
