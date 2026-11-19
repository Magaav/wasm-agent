# change/done-gate-trial

This is the operator-facing report for the mission. It is placed here because quality rule (5) says
reports live in docs/missions/reports/. The same text is at the worktree root as REPORT.md, which the
brief's closing paragraph asks for; the two instructions conflict and this file records that rather
than resolving it silently.

# change/done-gate-trial - report

Base: origin/main (ac7717e0). Worktree: this tree. Commits are local only; nothing was pushed.

## Items, each with the commit that implements it

| item | commit | what the diff does |
| --- | --- | --- |
| 1 | 872795e8 | the unchecked-capture line is no longer emitted; one counted event `done_gate_unchecked` per state-changing turn |
| 2 | afa91ecc | the verbatim sentence is in the code-mode guidance, once |
| 3 | b18fd19a | `wa turns --gate [--since 24h] [--json]` |
| 4 | b18fd19a | the tests: the line is absent from the reader stream, the event is written, the counter is right |

### Item 1 - 872795e8
- `lua/core/done_gate.lua`: `M.record_uncaptured` no longer calls `ctx.emit`; the `done_gates` row
  (status `uncaptured`, close code `no_checks_recorded`) is unchanged. New `M.EVENT = "done_gate_unchecked"` and
  `M.note_turn(state, ctx)` write ONE telemetry event per run (latched on `state.gate_counted`), payload
  `{changed_state, called_done_criteria}` - no request text, no answer, no tool output.
- `lua/core/agent.lua`: `gate_turn_end` calls `done_gate.note_turn(gate, { run_id = self.run_id })` after
  computing `gate.effected`, so every ending is counted once; `dispatch_ctx` carries `gate = gate`.
- `lua/core/tools.lua`: the `done_criteria` door sets `ctx.gate.done_criteria_called = true`, so a direct call and
  a script's inner call count the same.
- `docs/DONE-GATE.md`: the "work-shaped request with no gate" bullet now says the fact is the counted event,
  not a status line.

### Item 2 - afa91ecc
- `lua/core/codemode_policy.lua`: one line appended to `GUIDANCE_LINES`, verbatim:
  "When a request asks for a change, record its acceptance checks with `done_criteria` before the first effect."
  It is in the shared list, so it reaches the codemode, `first` and `only` guidance alike. Nothing else in the gate changed.

### Item 3 - b18fd19a
- `lua/core/turnfeed.lua`: `M.gate_stats(opts)` - the denominator is EVERY state-changing turn
  (`payload.changed_state == true`), the numerator the ones with `called_done_criteria == true`; a payload that
  does not say it changed state is in neither side; `percent` is nil when nothing was measured.
- `lua/core/turnfeed_cli.lua`: `wa turns --gate [--since 24h] [--json]` (also `wa turns gate`), the 30% rule printed
  with the number, and an explicit "unmeasured, not 0%" when the ledger holds no state-changing turn.

Observed on a scratch ledger (4 events, 2 state-changing, 1 captured; synthetic fixture, not this node's history):

    wa turns --gate (all time): 2 state-changing turn(s) from 1 session(s)
      1 called done_criteria: 50.0%
      rule: fewer than 30% deletes the done gate; 30% or more keeps it, reduced to what is used
      this run is 30% or more

and the unmeasured case, on an empty ledger:

    wa turns --gate (all time): no state-changing turn recorded yet
    the run journal holds 0 gate event(s); the capture rate is unmeasured, not 0%

### Item 4 - b18fd19a
`scripts/test-done-gate.lua` (a fast-path row, so it runs in scripts/fast.sh and in the gate):
- the warning is never a status event: re-adding the old `ctx.emit` line fails it
  ("the warning is NEVER printed to the user");
- the word is not in the answer text either;
- the `done_gates` row is still written;
- exactly ONE event per turn, with `changed_state` true and `called_done_criteria` false (unchecked run) / true (captured run);
- the counter over both: 1 of 2 = 50%, via `turnfeed.gate_stats`.
Item 2's sentence is pinned in the same row (verbatim, and said exactly once).
`scripts/test-turnfeed.lua` (also a fast-path row): the `--gate` verb's text form, its `--json` form, and its refusal of an
unreadable window.

Where the tests are wired: both files are `scripts/test-*.lua` and appear in the fast-path row inventory
(`scripts/lib/fast-rows.sh`, `wa_fast_row_candidates`) and in the gate's fixture list - no new runner was added.

## Measurements I ran (commands and results)

- `scripts/test-done-gate.lua`: "done-gate ok: 77 checks" (58 before this change).
- `scripts/test-turnfeed.lua`: "turn feed ok (149 checks)".
- `scripts/test-turn-signal.lua`: "turn-signal: 145 checks, 0 failed".

All three ran with a scratch `WASM_AGENT_HOME` under `$TMPDIR` and with the fast path's credential fence
(`env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE -u WASM_AGENT_VAULT_PASSPHRASE
-u WASM_AGENT_VAULT_OPERATOR_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN
-u WASM_AGENT_RAW_CODE -u WASM_AGENT_PROVENANCE -u WA_MESH -u WA_MESH_COMPONENT`).

## Falsifications (each new assertion was made to fail on purpose)

- Re-adding the removed status line: 1 failed ("the warning is NEVER printed to the user"). Reverted.
- Deleting the `done_criteria_called` mark in tools.lua: 4 failed, including
  "the counter sees both turns: 8 changed, 0 called". Reverted.

## Pre-existing failures, not mine

- `scripts/test-codemode-boundary.lua` refuses to run on this node at its line 10
  ("default node pins code mode"): code mode is unavailable here (the logs say
  `component_missing`), so `policy.pin` cannot enable it. I first pinned item 2's sentence there, hit
  this, and moved the pin to `scripts/test-done-gate.lua` - the file was restored byte for byte
  (`git diff --stat` after the revert listed only `lua/core/codemode_policy.lua`).
- An unfenced run of `scripts/test-done-gate.lua` fails exactly 20 of 58; that is the vault/DB leak
  `scripts/fast.sh` documents, not a regression.

## Brief premises re-measured

- "150 of 153 mission sessions" and "`done_criteria` is almost never called": I did not re-measure these
  against this node's ledger - they are the operator's own numbers and the change does not depend
  on them. What I DID verify: `lua/core/done_gate.lua` was 1032 lines at ac7717e0, and the warning text
  lived in exactly one place (`M.record_uncaptured`), so "the line is never printed" is one removal, not a
  sweep.
- The brief says the line's text starts with "!": in the code it is emitted as a `status` event with the
  text "done gate: this request changed state but recorded no acceptance checks; ...". Same line, no
  "!" prefix in the source.
- "or a field in wa turns output": I chose the verb (`--gate`), which keeps the existing report untouched.

## Texts to approve (verbatim)

1. Guidance sentence (model-facing, item 2):
   "When a request asks for a change, record its acceptance checks with `done_criteria` before the first effect."
2. USAGE lines (operator-facing):
   "  wa turns --gate [--since 24h] [--json]         the capture rate: state-changing turns, and how many"
   "                                                 called done_criteria (change/done-gate-trial, item 3)"
3. Report header (operator-facing):
   "wa turns --gate (%s): %d state-changing turn(s) from %d session(s)"
   "  %d called done_criteria: %.1f%%"
   "  rule: fewer than 30% deletes the done gate; 30% or more keeps it, reduced to what is used"
   "  this run is " .. ("below 30%" | "30% or more")
4. Unmeasured case (operator-facing):
   "wa turns --gate (%s): no state-changing turn recorded yet"
   "the run journal holds %d gate event(s); the capture rate is unmeasured, not 0%"
5. Machine form keys (operator-facing): available, since, events, changed, called, percent, sessions,
   threshold, side, reason.

## Not done / unknown

- Nothing was pushed; the three commits are local on change/done-gate-trial.
- The event name and payload are new, so a node that has not run this release has no
  `done_gate_unchecked` rows: the rate over the last 24h before the release is unmeasured, and
  `wa turns --gate` says so instead of printing 0%.

## What I could not measure, and why

The rate on THIS node's real history is unmeasured by me. Reading the operator's ledger from an agent
tool is refused, correctly, by the node's own guard:

    secret_path_denied: lua/core/secret_guard.lua refused bash: secret path denied
    (this is the node's own store: it holds the MCP registry, every connector's approval and the
    session ledger, so an agent tool neither reads nor writes it - wa show / wa vault are the surfaces)

Copying that file to measure it is the same read, so I did not attempt a workaround: a guard is not a
gap in my knowledge, and the answer is the operator's `wa turns --gate` on the node, not mine. What IS
verified is the code path: the verb on scratch ledgers with synthetic events (fixture output above), and
the unmeasured branch that refuses to print 0% when it has nothing to count.

Also note: my first attempt at this printed the ordinary `wa turns` report, because I ran the binary
without WASM_AGENT_LUA_ROOT and it used its own embedded (pre-change) Lua. The lesson is the one this repo
already writes down: a binary with embedded Lua answers a question about the wrong source unless the root
is named.
