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
| 1 | 872795e8 | the unchecked-capture line is no longer emitted; one counted event per state-changing turn (now `done_gate_turn`, r1 fix 3) |
| 2 | afa91ecc | the verbatim sentence is in the code-mode guidance, once |
| 3 | b18fd19a | `wa turns --gate [--since 24h] [--json]` |
| 4 | b18fd19a | the tests: the line is absent from the reader stream, the event is written, the counter is right |
| J | fce803eb | the <turn> what-hurt bullet asks for HARNESS friction only, pinned verbatim |

## Review r2 (verification: LAND after two items)

| item | commit | what changed |
| --- | --- | --- |
| 1 | affed947 | this run's gate is created at RUN START, so a run that throws early is recorded once |
| 2 | c3610994 | an unreadable ledger answers available = nil and the verb refuses it; the comment matches |

### Item 1 (affed947)
The gate used to be built inside run_body, past the first provider call. A run that threw before that
line left the PREVIOUS run's latched gate on the agent, so the end-of-run record was skipped (the old
gate had latched) - a silent hole in exactly the measurement the 30% rule reads. The gate is now created
in M:run before anything that can throw, and run_body reads self.gate instead of building a second one.
`scripts/test-done-gate.lua` runs one good turn, then a run whose run_body raises: the ledger holds TWO events,
the thrown one says changed_state = false, and a further note_turn on it writes nothing (one run, one turn).
Falsified: moving the gate back inside run_body produced "1 event(s) for 2 runs" plus a nil-gate raise -
the reviewed defect, reproduced.

### Item 2 (c3610994)
gate_stats always answered available = true, while its own comment said an absent ledger answers unknown.
The read now goes through query_checked, which tells an EMPTY ledger (available = true, changed = 0) from
an UNREADABLE one (available = nil, percent = nil, a named ledger_unreadable reason), and the CLI
refuses the latter with exit 2 instead of printing a count it does not have. The comment was rewritten to
describe what the code does. Nit: the stats_for(sid) helper ignored its argument and was a node-wide read
wearing a scoped name; it is gone, and the test asserts the module's own answers directly.
`scripts/test-turnfeed.lua` injects both failure shapes (a raise and a decoded error table) and pins the
refusal; falsified by restoring the permissive read, which answered available = true on an unreadable ledger.

## Review r1 (LAND + four measurement fixes), each with its commit

| fix | commit | what changed |
| --- | --- | --- |
| 1 | 3f135e28 | the counted turn is written ONCE, at run end, on every path (answer, abort, error, guard stop) |
| 2 | c679b7c4 | the tests assert what gate_stats ANSWERS, plus a re-entered run counting once |
| 3 | e951ce73 | the event is done_gate_turn; the old name done_gate_unchecked is still read |
| 4 | 4a835810 | the root REPORT.md is deleted; the report lives here only |
| 5 | 19f3360a | the event carries the build stamp; wa turns --gate takes --build SHA12 |

### Why fix 1 mattered (3f135e28)
The event was written at the FIRST candidate answer, then latched. A Stop-hook continuation that changed
something after it, and a run that ended with no candidate at all (abort, an error, a progress-guard
stop), were both counted wrong: the first as "no change", the second as nothing. The write moved to the end
of M:run - right after the pcall that wraps run_body, the one point reached on every path - where it re-measures
gate.effected from the run's own effect count and changed files, then calls note_turn, which still
latches, so a re-entered run is ONE turn. A run whose gate is disabled (a subagent, a guest) writes
nothing, because it has no capture rule to measure.

### Fix 2 (c679b7c4)
The old test recounted the rows itself: a second implementation of the rule, which can agree with a bug in
the first. It now asserts gate_stats's own answers on a ledger the row owns - 2 state-changing turns, 1
captured, exactly 50% - and the verb is compared against the module re-read at that point, not a stale
snapshot. A new case in scripts/test-done-gate.lua runs a real RE-ENTERED run (capture, fail, continue,
pass) and asserts ONE event and a count of 1/1, because the second candidate answer used to write a
second event.

### Fix 3 (e951ce73)
The event is written for EVERY state-changing turn, so done_gate_unchecked named only the minority that
skipped the capture. It is now done_gate_turn, with M.EVENT_LEGACY held beside it, and the reader asks for
BOTH names in one statement. The turn-feed fixture writes its rows under the OLD name on purpose, so the
legacy read fails the moment it stops working.

### Fix 4 (4a835810)
The root REPORT.md is deleted (git rm); this file is the report. It was a duplicate, and rule 5 of the
mission rules says reports live here.

### Fix 5 (19f3360a)
The payload now carries build: the source commit the binary embedded, from
turn_journal.build_of(), empty when unknown and never filled from HEAD. wa turns --gate takes
--build SHA12 and compares it as a PREFIX of the long sha the payload holds. Unknown is not yes: a
turn whose event carries no build is EXCLUDED when a build is asked for, and the answer reports
skipped_unknown_build and mismatched_build rather than quietly counting them. A build that matches
nothing answers changed = 0, which the verb prints as unmeasured, never as 0%.


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

### Item J - fce803eb (round 2, Victor 19/11)
- `lua/core/agent.lua`: ONE line replaced in `s.turn` (the <turn> contract). The model reports
  what wa did to its reasoning; its own mistakes and the project's own failures (tests, scripts,
  fixtures) are not wa friction. Principle 0, no classifier: the prompt asks for the right thing,
  nothing filters it afterwards.
- `scripts/test-batching-guidance.lua` (a fast-path row, which already reads
  `agent.system_prompt`): pins the bullet VERBATIM, pins the retired wording as gone, pins that the
  rule appears exactly once, and pins that it survives a smaller tool surface.

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
6. The <turn> what-hurt bullet (model-facing, item J, verbatim):
   "- **what hurt** - only what wa did to your reasoning (its tools, instructions, results or missing facts
   it should have given) and what would have removed it; your own mistakes and the project's own
   problems (its tests, scripts, fixtures) are not wa friction - leave them out;"
   (one line in the source; shown wrapped here)

## Not done / unknown

- Nothing was pushed; the three commits are local on change/done-gate-trial.
- The event name and payload are new, so a node that has not run this release has no
  `done_gate_unchecked` rows: the rate over the last 24h before the release is unmeasured, and
  `wa turns --gate` says so instead of printing 0%.

### Item J measurement (before/after share of notes naming a harness cause)

Attempted, and what the journal actually shows:

- 2026-11-19: 8 notes, from 8 sessions, every one stamped with build ac7717e0 - the BASE, which does
  not carry item J;
- 2026-11-18: no note at all, so a 24h-before window is those same 8 notes;
- the AFTER side does not exist yet: it needs sessions run on a release that carries fce803eb.

So the before/after share cannot be computed here, and I did not fake it by judging 8 notes by eye with
a rule invented afterwards. The supported surface (wa turns --day --json) prints themes and counts,
not a per-note classification, and the per-note hurt text is in the ledger the node's guard refuses to
an agent tool. The operator can take both sides in one command each, once an after-build has run:

    wa turns --day <YYYY-MM-DD> --json

filtered by the build field: notes on a build without item J are the BEFORE side, notes on a build
carrying fce803eb are the AFTER side.

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
