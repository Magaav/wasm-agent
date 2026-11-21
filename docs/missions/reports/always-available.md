# always-available - talk to wa while work runs, the way Claude Code does

Worktree `/home/victor/Work/missions/always-available/wt`, branch `change/always-available`,
based on `93168d96`. Committed locally, never pushed.

## What is built, and where

| item | commit | what the diff does |
| --- | --- | --- |
| one result shape | `c27f7336` | `codemode_pending.M.flat_entry`; a settled `wait(op)` entry is the tool's own result at the top level with `op`/`state`/`reason` beside it, a list wait answers a list of those, and `pending_settled` rows carry the value plus `result_sha256`. `codemode.lua`'s `wait` global stops throwing on a failed entry (a refusal is the only answer with no `state`). |
| Enter queued / Ctrl+Enter now | `6b3be460` | `rust/wa-term/src/keymap.rs`: `DraftAct::SubmitNow` with rows for `CSI 13;5u`, `CSI 27;5;13~` and Ctrl+G; `terminal_editor.rs`: `Action::SubmitNow`; `host.rs`: per-line kind (`TypedLine`/`LineKind`), `submit_interrupt(send_now, run_in_flight)`, `input_take` answers `{lines, now, eof, running}`; `lua/core/cli_input.lua` carries the kind and names it (`now_lines()`). |
| a settled handle wakes the session | `a61d3ad1` | `codemode_pending.wake_settled`/`open_handles`; `selfloop.schedule_settled` (one-shot wake, id `handle:<op>`, `INSERT OR IGNORE`); new `lua/core/handle_wake.lua` (the sweep and the row's words); wired into `wa_orchestrator_tick` (`subagents.lua`) and the CLI's idle prompt (`chat.lua`). |
| the three counters | `821d2395` | `lua/core/counters.lua`; `codemode_pending` marks `opts.cut_at_cap`, `codemode.finish` bumps `script_cut_at_cap`/`handle_mishandled`, `selfloop.run_wake` bumps `wake_only_round`, `/stats` prints the three. |
| docs | this commit | `docs/CODEMODE.md` ("A settled handle wakes the session", "The three counters", the flat shape in "Pending calls"), `docs/HOST.md` ("A line typed during a run: queued or now", the `input_take` answer). |

## Tests, and where they are wired

| row | what it holds | wired |
| --- | --- | --- |
| `scripts/test-codemode-wait-shape.lua` (new) | inline and `wait()`-collected answers expose the same `stdout`/`code`/`ok` keys, neither has a `result` key, a pending entry flattens nothing, an unknown op is `{state=failed, reason}`, an announced handle is the value plus its hash | fast path (globbed by `scripts/fast.sh`; not in `scripts/fast-path.exclude`) |
| `scripts/test-handle-wake.lua` (new) | the sweep, the wake row's words (the answer plus `Still pending (1): <op> (bash, Ns)`), exactly once across a second sweep and a reloaded module, no second `pending_settled`, the row is claimable by `selfloop.claim_due` | fast path |
| `scripts/test-cli-queued.sh` (new, shell) | **end to end**: a real `wa chat` under a stub model on loopback, a line typed three seconds into a running script - the script executes BOTH of its calls (marker file) and the line reaches the model afterwards (`/calls` prompt record). Cannot fail on the base for the queued half (that behaviour was already true); it protects the route | `scripts/test.sh` (the CLI-input block) |
| `scripts/test-handle-wake-turn.lua` (new) | the last hop, with the provider stubbed: the wake is claimed exactly as the node tick and the CLI idle prompt claim it, the model is asked ONCE with the settled answer in its input, the turn is a durable `[self-wake ...]` row, the effect ran once, and `wake_only_round` moved by one | fast path |
| `scripts/test-codemode-counters.lua` (new) | `script_cut_at_cap` once per script (not per handle), `handle_mishandled` on the pending-value TypeError, a clean script moves neither, unknown counter names refused | fast path |
| `scripts/test-cli-input.lua` (extended) | a `now` array is kept per line, `now_lines()` names the send-now ones, an answer without `now` is queued, **and on the real host** the take answer carries the kinds and a line that arrived through a pipe is queued | `scripts/test.sh` (its existing pipe producer) |
| `scripts/test-codemode-pending.lua`, `-never-killed`, `-queue-timeout` (updated) | the same assertions as before, read in the flat shape (`.result.code` → `.code`); the cancelled-entry check now asserts the handle's `reason` and that nothing threw | fast path / `test.sh` as before |
| `rust/wa-term` `enter_queues_and_ctrl_enter_sends_now` | Enter still submits; Ctrl+Enter, Ctrl+G and the xterm form send now; the draft is cleared the same way | `cargo test -p wa-term` (fast path's Rust rows) |
| `rust/wa-capabilities` `a_queued_line_never_ends_a_run_and_a_send_now_line_does` | the four combinations of (send now, run in flight) and the two line kinds | `cargo test -p wa-capabilities` |

Discrimination, measured here: `test-codemode-wait-shape.lua` fails on `93168d96` with
`keys ["op","result","state","tool"]` and `nested: object`; `test-handle-wake.lua` and
`test-codemode-counters.lua` fail on the base with `lua_root_unreadable ... handle_wake.lua` /
`counters.lua` (the modules do not exist there), which is the change itself.

### Test 1 as specified passes on the base, and that is a finding

"Enter mid-script: the script runs to its end, every planned call executed, the message delivered
right after" is **already true at `93168d96`** (premise 1 below), so a row asserting it would pass on
the base and catch nothing - which is why none was added for it. What is new, and therefore measured,
is the pair it presupposes: that the line carries a kind, that the kind of a pipe line is *queued*, and
that a send-now line is the one that raises the run's interrupt (`test-cli-input.lua` on the real host,
plus the two Rust unit tests). `scripts/test-cli-steering.lua` already holds the round-boundary
delivery half ("a complete line typed during a tool call reaches the next model request, and is durable
in the session").

## Premises of the brief that were wrong (re-measured at `93168d96`)

1. **"Today every typed line is a steer and drops the rest of the script."** Not in this tree. A line
   typed during a run sits in the host's queue; `cli_input.take_steering` is called only from
   `agent.steer`, which `agent.lua` invokes at a model round boundary (`round > 1`), and a script's
   wait ends only on `host.run_cancelled` — which the reader raises for Ctrl+C and Escape
   (`host.rs` `CLI_INTERRUPT`), never for a submitted line. So plain Enter was ALREADY queued; what
   was missing was a way to say "now" (this branch adds it) and any wake on settlement.
2. **`lua/core/agent.lua` ~2931 refuses an effect once a steer is queued**: that line is inside the
   provider retry loop. The fence is `agent.lua:3826` (`superseded_by_steering`) with
   `steering.pending` from `lua/core/steering.lua`, and it fences a *durable* (`wa steer`) message,
   not a CLI line.
3. **`lua/core/codemode.lua` ~951 budget 30 s default / 300 s at most**: the script has no default
   budget any more (`codemode.lua`, "a budget exists only when the caller asked for one"). The 60 s
   default / 300 s cap are the `wait_s` of one call (`codemode_pending.M.DEFAULT_WAIT_S` /
   `MAX_WAIT_S`), which is what this mission's "max 300 s" bound actually is.
4. **"a handle nobody resumed is only reported on the NEXT script"** — still true, and it is exactly
   what the wake replaces for a live session; the announcement stays for a scope with no session.

## Not done (named, not hidden)

* **Ctrl+Enter end to end (test 2).** Attempted and NOT achieved: `scripts/test-cli-queued.sh` drives
  `wa chat` under a pty (`script -qec` with `stty rows 40 cols 120`) and sends `CSI 13;5u` three
  seconds into the script; the run completed with the whole line delivered as text (marker had both
  calls, footer `2 rounds`), so the harness cannot deliver the chord to this binary's editor. The phase
  was removed rather than shipped as a row that cannot tell the two apart, and the script says so where
  it would have been. Ctrl+Enter is covered by the two Rust unit rows and the queue kind in
  `test-cli-input.lua`.
* **Test 2 and test 6 as written**: Ctrl+Enter mid-script and mid-reasoning end-to-end through a real
  terminal. What is measured here is the classification and the interrupt (`wa-term` and
  `wa-capabilities` unit tests) and the queued/send-now queue on the Lua side
  (`test-cli-input.lua`). A pty-driven CLI test that asserts "answered before the long call settles"
  and "the partial reply is in no later request" is **not written**; the provider-stream stop mid
  reasoning is not built either — `Ctrl+Enter` reuses the run's own interrupt, which stops the stream
  at the next chunk (`host.rs` `run_cancel_requested`) and the run ends as `run_cancelled`; the
  "append the line and start a new model call in the same turn" refinement is **not** implemented.
* **Test 5's real `opencode-go` turn with cache-read tokens** was not run: it needs a live provider
  and a recorded baseline this session did not have. The prefix-stability claim is therefore
  unverified here.
* **The wake turn with a model** is now covered without a network: `scripts/test-handle-wake-turn.lua`
  claims the row the way both surfaces do and runs the turn with a stubbed provider, asserting one
  model call, the durable labelled row, the effect run once and the `wake_only_round` increment. What
  is **not** written is the same turn *through the two transports*: a serve process's
  `wa_orchestrator_tick` dispatching through `host.enqueue_completion`, and a `wa chat` at its idle
  prompt. Those need a running node with a stub model behind it.
* **Counters**: `script_cut_at_cap` counts the pending-answer half only; "hit its deadline with lines
  still to run" is not counted. `handle_mishandled` counts the pending-value TypeError and the
  wait-never-settles bound; "a model polling `wait()` in a loop" is only counted when it ends on that
  bound.
* **Screen work** (running handles visible with name and elapsed; a queued message drawn as queued):
  unchanged — the host already lists queued lines above the status line and the send-now line is not
  queued long enough to be drawn; no new rendering was added.

## Texts to approve (model- or operator-facing)

1. `codemode_pending.WAIT_HELP.description`: "Resume one pending call, or a batch of up to 20, that
   answered {state:\"pending\", op}. Answers one entry per op in the order asked, in the SAME shape a
   direct call answers: a settled op answers the call's own fields at the top level (stdout, code, ok,
   ...) with op, tool and state:\"done\" beside them; a failed one the same with state:\"failed\" and
   reason; a still-running one {state:\"pending\", op, tool, waited_s, progress}. It answers results,
   not handles - there is no result key to reach through. ..." (unchanged tail)
2. `/keybindings`, "Sending": "Ctrl+Enter - send the draft NOW: during a run this one ends the wait the
   run is in and is answered at once (Enter alone is queued and never interrupts)"; "Ctrl+Enter - the
   same, as an xterm's modifyOtherKeys reports it"; "Ctrl+G - the same send-now, for a terminal whose
   Ctrl+Enter arrives as a plain Enter".
3. The wake row, whole: "<tool> <op> finished while no script was waiting for it (it is <state>)."
   / "Its answer, in the same shape the call itself answers:" / <the flat answer, clipped at 8 KiB
   with "[clipped at N bytes of M; the whole answer is the handle's own, read it with results.get(op)]">
   / "No handle is pending any more." OR "Still pending (N): <op> (<tool>, <age>s), ..." +
   "wait(op) resumes one, cancel(op) stops one, results.get(op) re-reads an answer."
4. The wake's reason: "a pending call settled" (shown as `[self-wake · a pending call settled]`).
5. `/stats` rows: `wake_only_round`, `script_cut_at_cap`, `handle_mishandled`.
6. Refusal added: `handle_wake_requires_a_session` (logged, not shown).

## Rows run here, and one pre-existing failure

Run with this tree's binary and `WASM_AGENT_LUA_ROOT` pointed at the tree, each in a scratch
`HOME`/`--db`:

* green: `test-codemode-wait-shape` (25 checks), `test-handle-wake` (16), `test-handle-wake-turn` (10), `test-cli-queued.sh` (end to end, `script calls=2, model calls=3, line delivered=1`), `test-codemode-counters`
  (11), `test-codemode-pending` (92), `test-codemode-never-killed` (19), `test-codemode-queue-timeout`
  (20), `test-codemode-presentation`, `test-codemode-friction`, `test-cli-input` (21),
  `test-selfloop`, `test-selfloop-pause` (101), `cargo test -p wa-term` (177), the `terminal_tests`
  of `wa-capabilities` (6).
* **pre-existing failure, not this change**: `scripts/test-codemode-native.lua` stops at line 24
  ("opt-in adds one tool, direct tools retained", `#boot ~= 11`) **identically on the base worktree**
  (`/tmp/base-always` at `93168d96`), so the difference is this machine's tool catalogue, not the
  branch. Named here so it is not read as a regression.

## The gate's first round (preflight, main 0b9d574c + this branch)

Two rows were red; both are fixed at 875f525b's successor \`af62ac53\`, and neither was weakened:

* \`scripts/test-refusal-contract.lua\` - the inventory of refusal codes was stale because
  \`selfloop.schedule_settled\` answered \`error = "handle_wake_requires_a_session"\`. That string was
  never rendered through \`lua/core/refusal.lua\` (nothing model-facing reads it), so it was a *code*
  only by spelling. It is now a \`reason\` (\`{ok=false, reason=...}\`) beside a comment saying why, and
  \`lua/core/refusal_codes.lua\` is byte-identical to main's again - the row passes with 17003 checks.
* \`scripts/test-remote-pending.lua:166\` - it read a settled \`wait(op)\` entry as
  \`resumed.result.stdout\`. That is the wrapped shape the one-result-shape change removed; it now reads
  \`resumed.stdout\` and additionally requires it to be a STRING, which is stricter than before. The row
  passes with 83 checks.

Both were run on this branch with the tree's binary before the commit; \`test-handle-wake\` (16) and
\`test-handle-wake-turn\` (10) were re-run after the \`reason\` rename and stay green.

## Remaining blockers

* `scripts/test-discriminates.sh` (the land gate) was not run: it needs a clean base tree and a
  binary per side, and this node was already running one heavy suite at a time. The base checks above
  were run by hand with a second worktree (`/tmp/base-always`, `git worktree add --detach`).
* The full fast path / `scripts/test.sh` were not run (they are the landing gate's job, and they take
  ~50 minutes on this node); the rows this change touches were run individually and are listed above.
