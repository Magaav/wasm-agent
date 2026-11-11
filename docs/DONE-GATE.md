# The done gate: a turn ends when the request is done, or measurably impossible

Measured, 10/11 and 11/11 (the operator's "fix 1"): sessions ended turns at natural break points with
work still to do, and needed a human "go/continue" to move again.

| session | what it said | what was actually left |
| --- | --- | --- |
| `b5a92f25` | 18 operator messages, ~5 h, one request | scope shrunk to "a separate item" |
| `0ed9a783` | "Phases 2-4 not started" | three phases |
| `08c59fbc` | "I stopped exploring" | its bootstrap |
| `31792e47` | "done to the limit" | the landing |
| `06:39` | wrote its own check (`mcp_whatsapp_*` in code mode) | dropped it at 07:01 |

Each of those answers was true about the machine. The fault was not a lie and not a lack of effort: it
was that "the model has nothing more it wants to say" ended the turn. A prompt that says "keep going"
cannot fix that — it is another turn of the same coin, and it is exactly the nudge text the operator
forbade. So the decision moved out of the model's prose and into a fact the harness can run.

Models are free: no turn cap, no round cap, no "wrap up" instruction. What stops a turn is one of four
things, and nothing else:

1. **the recorded checks pass**;
2. **a measured impossibility** — a named blocker with a probe the harness reruns and sees hold;
3. **operator input** — a steer, a new message, a stop;
4. **a stall** — the same failing check output, with no state change, `N` turn ends in a row. That is one
   named record and one wake, never another round.

## 1. Capture: the acceptance checks, next to the operator's words

A request that asks for a change in the world gets its acceptance checks recorded **before the first
effect**, in the session's own store, beside the operator's verbatim words:

```
done_criteria {action="capture", checks=[
  {command="npm test -- --grep landing", why="the queue test the bug broke"},
  {command="git log --oneline -1 | grep -q 'change/landing'", why="the fix is landed"},
  {text="the run report says which checks were skipped and why", why="the operator asked for a report"}]}
```

Two kinds of check, and that is the whole schema:

- **a command** the harness runs (`host.exec`, in the session's workdir, 120 s default). It passes when
  the exit code equals `expect_exit` (default `0`) and, when `expect` is given, its output contains that
  literal substring.
- **a criterion** in words. A fresh verifier judges it (see §2). Written criteria exist because not
  everything worth requiring is a shell command — "the report says what it could not verify" is a
  criterion, and pretending otherwise would make the gate blind to the operator's actual words.

`request` is optional and is checked against the transcript: a paraphrase is refused
(`done_gate_request_not_in_transcript`), and when it is omitted the newest user turn is used verbatim.
The gate is keyed to `(session, request)`, so two requests in one session are two gates — a session is a
conversation, a mission is a request.

Checks may be **added** at any time (`action="add"`); nothing else about them is the model's to change.

**Removing or weakening a check requires the operator, and the requirement is checked, not declared.**
`action="remove"` and `action="weaken"` take `operator_quote`: the operator's instruction, verbatim,
which must be found in a **user turn of this session** (whitespace-collapsed, nothing else forgiven). A
quote the operator never said is refused (`done_check_removal_requires_operator_words`), and a removed
check keeps its row (`removed_at`, `removed_by`, `operator_quote`) so the audit trail survives the
removal. A check the model can quietly drop is not a check — that was the 06:39 session's failure in one
line.

**`exempt`** records why a request needs no change in the world (a question, an explanation). It is the
honest way to say "nothing to check here", it is refused while the gate has live checks, and it is
recorded next to the request.

## 2. The turn-end gate

`M:run_body` calls the gate at the one point where a candidate answer exists
(`lua/core/agent.lua`, "The done gate runs on the candidate, before the Stop hook"). What happens then:

- **no tool calls this run** → not gated. A pure answer cannot have changed anything, and this is what
  keeps a plain question out of the gate entirely.
- **a work-shaped request with no gate** → **recorded, not re-entered.** The run changed the world and
  recorded nothing to test it against; the harness cannot invent the criterion, so it writes a gate row
  with status `uncaptured` and the close code `no_checks_recorded`, and says so on the status line. An
  extra round of "record your checks" would be a turn spent on paperwork nobody asked for, and the
  operator asked for no nudge text. A skipped capture is a visible fact, never a silent one.
- **a gate whose checks pass** → the gate closes `passed`, and the turn ends.
- **a gate whose checks fail** → the run is **re-entered**: the next user turn is the operator's words,
  verbatim, plus the failing check output, marked `[done gate · harness]` so no later reader mistakes it
  for a human message. The candidate answer stays in the transcript as what it was — a step, not the
  answer.
- **a closed gate** (passed, impossible, exempt, stalled) → nothing. A settled mission is not re-judged.

Written criteria go to a **fresh verifier pass**: one model request whose system prompt is
`done_gate.VERIFIER_SYSTEM`, carrying only the request, the criteria and the evidence the run produced
(its candidate answer, the files it changed, its tool-call count). It has no stake — it did not do the
work, it cannot answer the task, and it cannot see the working session's reasoning. It answers JSON; a
reply that is not the JSON asked for is `unjudged`, never a pass. An unreadable verdict must not release
work.

If no verifier is available at all, the criteria are reported as unjudged and the turn ends: looping on
"the verifier is unavailable" would be a budget in disguise.

## 3. It is not a budget

There is no round count anywhere in this module. The loop it drives is the run loop it always was, and
the reason it ends is one of the four in the header. Two details matter:

- **the round ceiling is not ours.** `WASM_AGENT_MAX_TOOL_ROUNDS` is being replaced by the progress
  guard (`change/no-silent-stops`, `lua/core/progress_guard.lua`): a repeated call, or rounds that
  changed nothing. This gate adds no cap of its own and does not duplicate that judgement. A run that
  the guard stops is stopped by the guard, with its own named reason.
- **a stall is a fact, not a failure to try.** `WASM_AGENT_DONE_GATE_STALL` (default `3`) is the number
  of *identical* failing turn ends — same check output digest, same changed-files digest — before the
  loop stop repeating. A fix that changes the output resets it; a fix that changes nothing does not.
  The stall writes **one** named record (`done_gate_stalled`, through `lua/core/run_failure.lua` when it
  is present: the same `ok=false` assistant row, the same bus/event channels every non-answer ending
  uses), closes the gate `stalled`, and schedules **one** wake (`WASM_AGENT_DONE_GATE_WAKE_SECONDS`,
  default `60`), recorded in `done_gates.wake_id` so a second turn cannot wake twice for the same stall.

## 4. Questions and explanations are not gated

No capture, no gate, and a run whose request is a question is never asked for checks. The switch is
`done_gate.work_shaped`, deliberately dumb and deterministic so a reader can predict it: an asking word
first (`what`, `why`, `how`, `explain`, `describe`, `tell`, `show`, `compare`, ...) or a trailing `?`
with no imperative verb is a question; an imperative verb first, `can you <verb>`, `please <verb>`,
`I need ...`, `let's ...`, a numbered list or a phased plan is work. It decides only whether the
harness *asks* for a capture — never whether a check passes — so a wrong answer costs one round, not a
false verdict.

## Storage and surfaces

Two tables beside the transcript, created on first use (`lua/core/done_gate.lua`):

- `done_gates`: one row per `(session, request)` — the verbatim request, its seq, `status`
  (`open|passed|impossible|exempt|stalled`), `close_code`, `close_detail`, `wake_id`;
- `done_checks`: one row per check — `kind` (`command|criterion`), `command`, `expect`, `expect_exit`,
  `timeout_seconds`, `text`, `why`, `added_by`, and on removal `removed_at`/`removed_by`/`operator_quote`,
  or `weakened_from` for a weakening.

An open gate survives a restart, a compaction and a wake: it is a row, not a field of the object that
happens to be running. A harness turn (`[self-wake]`, `[run failure]`, `[done gate ...]`) has no
operator words of its own, so it inherits the newest open gate instead of asking for a capture.

The tool is `done_criteria` (`action`: `capture|add|remove|weaken|exempt|impossible|status`), master and
admin only, in the `memory` tier. It runs commands, so it is not a guest's tool. Subagent runs are not
gated: a bounded child's acceptance criteria belong to its parent, which asked for it.

## What this does not do

- **It does not prove the work is correct.** A recorded check that is too weak passes. The gate makes
  "the check the run wrote for itself" unavoidable, visible and operator-removable; it does not invent
  the check. A run that records nothing and exempts itself on a work request leaves a record saying so.
- **A command check is a probe, not a sandbox.** It runs as the node's user, in the session's workdir.
  A check that writes is the model's own doing; the harness runs what was recorded and does not launder
  it.
- **A measured impossibility can be a wrong measurement.** The probe has to hold *now*, which is
  stronger than a sentence, and still weaker than an operator's judgement: an impossibility is evidence
  that the turn should end, not a claim that the goal was impossible.

## Checks that pin it

`scripts/test-done-gate.lua` (model-free: a scripted provider, a real shell, a scratch database) —
fifty-two checks, including the five the operator asked for:

| case | what it pins |
| --- | --- |
| re-entry | a fixture agent that stops at a natural break point is re-entered, with the operator's words and the failing output, until its check passes; the early answer is kept |
| refusal | a captured check cannot be dropped without the operator's words in the transcript; with them it is removed, and the removal keeps its row |
| impossibility | a probe that does not show the blocker is refused; one that does ends the turn and closes the gate `impossible` |
| stall | three identical failing turn ends produce exactly **one** `done_gate_stalled` record and one wake, and no fourth round |
| no gate | an explanation request, even one that runs a command, is never gated |

plus the written-criterion verifier (hold, then release), the `uncaptured` record for a run that
changed state without recording checks, and `work_shaped` itself.
