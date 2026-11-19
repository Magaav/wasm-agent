# thinking-block — the run block in the thinking (#52), and the finish contract

Base: `origin/main 44229140` (worktree `wt`, branch `change/thinking-block`). Date of the fix: 19/11.

Scope note: this report covers PHASE 0, PHASE 1 and the part of PHASE 2 that is implemented. What is
**not** implemented is listed with its measurement in "Not done", and nothing here claims it.

---

## PHASE 0 — root cause

### Verdict: **H2**. The provider put the block in the reasoning field; the harness read only the answer.

H1 (our adapter mis-split the stream and moved an answer into reasoning) is refuted by the adapter's own
code, and H2 is what the failing turns' record shows. The raw HTTP body of those turns could **not** be
read (see "Evidence limit"), so H2 rests on (a) the harness's own record of what the provider returned and
(b) the proof that no code path can move content into reasoning.

### Evidence 1 — what a failing turn looked like (the harness's record of the response)

`/home/victor/Work/missions/vault-one/out.log:161570-161577`:

    Thinking · 4m40s · run 1 · step 27

    Let me see both sides of host.rs hunk boundaries — HEAD side 5817-6003, mine 6004-6061. Likely both
    add tests at the end of the module; I should keep both.
    ```js run
    const r = await tools.bash({command:"cd .../vault-one/wt && ..."});
    return r.stdout;
    ```
    ! run_failed: run_failed - the run stopped without an answer: the model spent its output on reasoning
    (476 chars) and returned no answer (finish_reason=stop); reasoning is not an answer, so either it ran
    out of budget before writing one or this endpoint only streams thinking ...

The block is rendered under `Thinking`, it is complete (opening and closing fence), and the failure names
476 chars of reasoning with `finish_reason=stop`. The same shape, at the same point of the turn, in:

| log | line | reasoning chars | last thing the model wrote |
|---|---|---|---|
| vault-one/out.log | 161576 | 476 | complete `js run` block |
| edit-transport/out.log | 1462 | 310 | complete `js run` block |
| land-routing/out.log | 5684 | 17901 | complete `js run` block |
| tui-polish-2/out.log | 9941 | 4580 | complete `js run` block |

"Thinking" is the UI's rendering of `result.reasoning`, and `result.reasoning` is assigned in exactly one
place — from the provider's reasoning field (below). So the block arrived in the reasoning field.

### Evidence 2 — no code path moves an answer into reasoning (H1 refuted)

* Streaming reader, `rust/wa-capabilities/src/host.rs:2903-2941`: `delta.content` is appended to
  `content`, and only `delta.reasoning_content` / `reasoning` / `reasoning_text` to `reasoning` — two
  separate accumulators, no code that moves one into the other.
* `lua/core/provider.lua:1420-1432` `M.reasoning_of` reads those same three fields and nothing else;
  `M.complete_with` copies `result.reasoning` through unchanged.
* `lua/core/provider.lua:1439-1454` `M.visible_text` strips `<think>` markup from **content** only; it
  never writes to `reasoning`.
* If an answer had arrived in `content` and been misread, `reasoning` would have been empty and the
  failure would have been the *other* sentence (`provider.lua:1677`, "the provider returned an empty
  message with no tool call and no text"). Every observed failure carried a non-zero reasoning length
  instead.

### Evidence limit (stated, not hidden)

The failing turns' raw SSE body is not reachable from this node's tool surface. The session ledger
(`~/.wasm-agent/memory.db`, where the step's span keeps `reasoning_head`, `finish_reason` and
`reasoning_chars`) is behind the node's secret guard: `tools.bash` on it returned
`secret_path_denied` — *"this is the node's own store ... 'wa show' / 'wa vault' are the surfaces"*. The
named surface does not exist in this build (`wa show` → `unknown command: show`). I did not circumvent the
guard. Consequence: the reasoning field is quoted from the harness's own record of the response and from
the adapter code, not from a captured HTTP body. A reproduction against the live provider was not run for
the same reason: its credentials live in the same guarded store.

### Rate (measured, per mission logs)

Counted `run stopped without an answer: the model spent its output on reasoning` and
`^--- launch ` (turns) in every mission dir, with the mode read from that mission's `run.sh`/`serve.env`:

| mode | turns | reasoning-only failures | missions with a failure |
|---|---|---|---|
| `first` | 25 | 10 | vault-one 3, edit-transport 4, land-routing 1, tui-polish-2 1, turn-signal 1 |
| `codemode` | 63 | 0 | — |
| `only` | 0 | 0 | no mission ran with `only`: unmeasured |

A turn may contain several runs (a failed run is woken and resumed), so failures can exceed turns in a
mission; the table reports both counts rather than a ratio that would hide it. Mode for
`thinking-block` is ambiguous in its own dir (`serve.env:182` says `first`; `run.sh:3` says `codemode`,
dated 19/11 00:35, "back to codemode until harness #52 ... is deployed").

The concentration in `first` is the mechanism: `first`/raw-channel is the mode where the model writes its
action as a code block in the message text, so a model that writes that block in its thinking has written
nothing the harness can run. In `codemode` the action is a native tool call, which has no thinking field.

Whether reasoning effort, `WASM_AGENT_LLM_MAX_OUTPUT` or the provider's thinking settings change the rate:
**not measured.** `finish_reason=stop` (not `length`) in every observed failure argues against a budget
cap being the cause, but that is an inference, not a measurement.

---

## PHASE 1 — the fix at the owning layer

Nothing is executed from the thinking. A step that reasoned and wrote no answer gets **one** named,
counted continue; a second consecutive one fails the run by name (rc != 0).

```
 lua/core/agent.lua    |  45 ++++++++++++++++++
 lua/core/raw_code.lua | 125 ++++++++++++++++++++++++++++++++++++++++++++++++--
 scripts/test.sh       |   1 +
 3 files changed, 166 insertions(+), 5 deletions(-)
```

* `lua/core/raw_code.lua`: `M.in_thinking(reasoning)` (pure: shape `run`/`cut_run`/`plain_js` or nil),
  `M.thinking_notice`, `M.reasoning_only_notice`, `M.thinking_failure`, `M.reasoning_only_failure`,
  `M.THINKING_CONTINUES = 1`. Only the last block of the thinking counts, and only when it ends the
  thinking — a block the thinking went on from is the model reasoning about code.
* `lua/core/agent.lua` (`M:run_body`, the empty-reply path): the gate. Only a step that **reasoned**
  reaches it, so `provider.is_empty_reply` and its retry budget keep the behaviour they had.
* The continue is a durable `phase = "finish_contract"` user row plus an in-context message, so a resumed
  run rebuilds the same request; the failure names the shape and records it on the step's span.

---

## PHASE 2 — the finish contract, shape by shape

| # | shape | before (44229140) | after |
|---|---|---|---|
| 1 | #22 reasoning only, no block | turn failed at once: "reasoning is not an answer" | one continue (`M.reasoning_only_notice`), then `reasoning_only:` failure |
| 2 | #51/C lenient fences | only `js run` with the tag alone on the fence line; `js run <code>` parsed as prose and the step ended with its action as text | `js run <code>` (code becomes line 1), `js  run`, `javascript run`, `JS run` all run; `js runner` still does not |
| 3 | cut run block | refused `raw_code_unterminated`, answered as the call's result (one continue) | unchanged, now pinned by tests |
| 4 | #D several run blocks | only the last runs; the result carries a note saying so | **not done** |
| 5 | A plan-only ending | ends the turn as an answer | **not done** |
| 6 | B language of the user's last message | envelope sentence only (`agent.lua:232`), no end-of-turn check | **not done** |
| 7 | E relay deadline names the real cap | not changed | **not done** |
| 8 | #53 resume that cannot run | not changed | **not done** |

Premise correction on shape 2: three of the four spellings the brief lists (`js  run`, `javascript run`,
`JS run`) **already parsed** at 44229140 (`is_run` lowercased the tag and allowed any spacing). Only the
code-on-the-fence-line spelling was broken. The new tests pin all four so the claim is measured, not
assumed.

---

## Verification (commands actually run)

    cd /home/victor/Work/missions/thinking-block/wt
    WASM_AGENT_HOME=/tmp/tb-home WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1 \
      WASM_AGENT_LLM_API_KEY=fixture-only \
      WA_SCRIPT=scripts/test-thinking-block.lua wa --db /tmp/tb-home/db.sqlite
    => thinking block ok (34 checks)

Driven through `host.http_stream` with the recorded response shape (content empty, reasoning ending with
a complete `js run` block, `finish_reason=stop`). It asserts: the turn continues instead of failing; the
harness asked exactly once; **no tool row exists, i.e. nothing was executed from the thinking**; two
consecutive ones fail with `run_block_in_thinking`; #22 fails with `reasoning_only`.

Regression suites on the touched paths, all green: `test-empty-reply` (51 checks — its retry assertion is
untouched and passes), `test-raw-code` (34), `test-raw-code-answer` (11), `test-raw-first` (47),
`test-raw-native` (23), `test-codeact-default` (12). Each ran with its own scratch `WASM_AGENT_HOME`
under `/tmp`, never the real `~/.wasm-agent`.

Pinned into the fast path: `scripts/test.sh`, line after the empty-reply suite —
`WA_SCRIPT=scripts/test-thinking-block.lua "$BIN" --db "$DB" | grep "thinking block ok"`.

Pre-existing, not mine: `test-codeact-default` prints `wa: session ... failed` while reporting
`ok:true`; checked on the base with the worktree changes stashed — identical output.

Not run: the full `scripts/test.sh` gate, and any `cargo` build/test (this change touches no Rust).

---

## Texts to approve (verbatim, model-facing unless marked)

1. `[Harness notice] This message had no answer: the run block you wrote was in your thinking, not in your
   answer, so nothing ran. Write it in your ANSWER, as one ```js run block that ends with a ``` line.`
2. `[Harness notice] This message had no answer: the ```js block you wrote was in your thinking, not in
   your answer, and it was tagged js rather than js run, so nothing ran. Write it in your ANSWER, as one
   ```js run block that ends with a ``` line.`
3. `[Harness notice] This message had no answer: your ```js run block was in your thinking, not in your
   answer, and it was cut off before its closing ``` line, so nothing ran. Write it in your ANSWER, as one
   ```js run block that ends with a ``` line.`
4. `[Harness notice] This message had no answer: you reasoned and then stopped, so nothing ran. Write your
   next step in your ANSWER: the script as one ```js run block, or the answer itself and why.`
5. (operator-facing status line) `the step ended without an answer (<shape>): asked once for it in the
   answer; nothing was run`
6. (failure name, operator-facing) `run_block_in_thinking: a run block is in the model's reasoning, not in
   its answer, and the harness asked for it in the answer once already; nothing ran, so the turn is failed
   rather than finished without its action`
7. (failure name) `reasoning_only: the step reasoned and returned no answer and no action, and the harness
   asked for an answer once already; nothing ran, so the turn is failed rather than finished without it`

---

## Not done (with what I measured instead)

* PHASE 2 items 4-8 above. #D needs a stop-at-the-first-error rule in the per-call loop, which today runs
  every call in the batch; A (plan-only) and B (language drift) need new end-of-turn detectors; E and #53
  touch the relay and resume paths, which I did not open. None of them is in this diff.
* A reproduction of the failing turn against the live provider (blocked by the secret guard, above).
* The `only` column of the rate table: no mission used that mode.


---

# ROUND 2 — close the circle: ONE rule, every shape

Base: the same branch, round 1 committed as `2cc76de8`. Round 2 covers the ten items of the operator's
19/11 brief. Everything below is a claim about this diff (`git diff --cached --stat`, the whole round
2 change including this report):

    docs/missions/reports/thinking-block.md | 208 +++++++++++++++++++++
    lua/core/agent.lua                      | 133 ++++++++++----
    lua/core/chat.lua                       |  12 +-
    lua/core/codemode_policy.lua            |   3 +
    lua/core/finish_contract.lua            | 309 ++++++++++++++++++++++++++++++++
    lua/core/nodes.lua                      |  58 +++++-
    lua/core/raw_code.lua                   | 131 ++++++++++----
    lua/core/reload.lua                     |   7 +
    scripts/test-raw-code.lua               |  31 +++-
    scripts/test-raw-first.lua              |   5 +-
    scripts/test-remote-call-shape.lua      |  28 +++
    scripts/test-resume-tool-registry.lua   |  10 ++
    scripts/test-thinking-block.lua         | 255 ++++++++++++++++++++++++++
    13 files changed, 1106 insertions(+), 84 deletions(-)

## The rule, once

`lua/core/agent.lua` has ONE gate, `finish_continue(shape, notice, failure_name)`, defined once inside the
run loop and called from the two places a step can end without an action: the empty-answer path (round 1's
shape) and the answer path (round 2's shapes). It owns one counter (`self.finish_continues`) and one limit
(`finish_contract.CONTINUES`, which re-exports the one number the raw channel publishes as
`raw_code.THINKING_CONTINUES`, so the two cannot drift apart). First ending: a durable `phase = "finish_contract"` user row with the named sentence, and the turn
continues. Second consecutive ending: `error(failure_name, 0)` after the step's span is marked `ok = false`
with the shape and `self.pending_failure` is set, so a scripted `wa chat --once` exits non-zero instead of
reporting a finished turn with nothing run. A step that ran a tool resets the counter, because it did act.

`lua/core/finish_contract.lua` (new, pure: no host, no network, no ledger) only names WHICH shape ended the
step, so the continue names the one thing to change. Precedence: markup, then shutdown, then compaction,
then plan, then language - the first match wins, because a model given three sentences follows none.

## Shape by shape

| # | shape | measured before | after (this diff) |
|---|---|---|---|
| 1 | tool-call markup as TEXT | the answer was the markup and the turn ended (land-routing 19/11 00:59 `<ds_tool>{"command":...}</ds_tool>`; thinking-block 00:41 `}}</parameter>`) | `finish_contract.markup` + `raw_code.markup_in_text`: one allow-list of markers; ONE continue naming the operator's sentence; a second consecutive one fails with `tool_call_markup_as_text`. The markup is not recorded as the answer, and a marker inside a fenced sample is prose (never fired) |
| 2 | a context-compaction summary as the answer | the model's own `<analysis>…</analysis> <summary>…</summary>` was the run's last output (edit-transport 01:01, `out.log:12452`) | `finish_contract.compaction` (the summary form AND the harness's own `## Goal/## Progress/## Next Steps` checkpoint template): one continue, then `compaction_answer`. Separately, the harness's OWN in-run compaction is pinned by a test that makes it fire mid-turn and shows the run continuing the task |
| 3 | a stale "node shutdown" notice | the last output was a `<system_warning>The previous response was interrupted by a node shutdown (sessions before the shutdown see un-settled operations).</system_warning>` plus a plan, and the run ended there (land-routing 00:50, `out.log:12771`) | `finish_contract.shutdown`: the harness sends no such notice (grep: the string exists in no file under `lua/` or `rust/`), so a reply carrying one is stale by construction - it is not recorded as the session's answer (never shown to it) and it never ends the turn: one continue, then `stale_shutdown_notice` |
| 4 | D: several run blocks in one message | only the LAST block ran and the result said so | every block runs, in the order written, one codemode call each, each result labelled `run block N of M`; the batch stops at the first block that fails and every later block is answered `run_block_not_run` with the position of the failure (the protocol needs a result per call id, so it is answered, not dropped) |
| 5 | A: a plan-only ending | it was the answer | `finish_contract.plan`: conservative - no fence anywhere, at most three sentences, the LAST sentence must open with first-person intent, and a last sentence addressing the user (`you`/`your`) is a next step for the USER and stays an answer. One continue, then `plan_only` |
| 6 | B: language of the user's last message | nothing checks it | `finish_contract.language`: the dominant SCRIPT (Latin, CJK, Hangul, Cyrillic, Arabic, Greek, Hebrew) and, for two Latin-script languages, a function-word profile (English, Portuguese). Unknown is not drift: it needs 40+ words in the answer, 8+ in the request, and a 2:1 margin. One continue, then `language_drift` |
| 7 | E: the relay deadline names the real cap | `{error="remote_error", detail="relay_timeout", retryable=true}` and nothing else | `nodes.RELAY_ATTEMPT_HOLD_SECONDS/ATTEMPTS/DEADLINE_SECONDS` are the numbers the loop now reads, and the model gets `message` + `fix` naming the cap and the exact `tools.remote({node, capability:"operation", action:"start"})` + `await` call on that node |
| 8 | #53: a resume that cannot run | the refusal was returned and the process exited 0 (measured on the base: rc=0) | the refusal still returns (an interactive reader sees why, nothing crashes) and sets `self.turn_refused`; `chat.turn_ok` turns it into exit 1, and the sentence names the mode this process runs (measured after: rc=1) |
| 9 | ENVELOPE | the guidance had no sentence about a call still running when the script ends | the operator's sentence, verbatim, added to the CodeAct guidance (`lua/core/codemode_policy.lua`, GUIDANCE_LINES[3]) so it survives the `first`/`only` rewrite of lines 1-2 |

## Premises re-measured (the brief's facts)

* `<ds_tool>` at land-routing 00:59 - **confirmed**: `out.log:14732-14736`, and the run ended there
  (`19 rounds · 18 tools · 2m10s`), so the markup was the last output.
* leftover `}}</parameter>` at thinking-block 00:41 - **confirmed**: `out.log:4117`, as the tail of
  `"Careful with output size. Let me do these in parallel.}}</parameter>"`.
* #58 at edit-transport 01:01 - **partly confirmed**: `out.log:12452` holds the `<analysis>`/`<summary>`
  answer and the run ended on it. The rc of that run is **not** in the log and that mission has no `done`
  file, so I read the log's facts only; "run ended rc=0" is the brief's claim, not something I re-measured.
* #56 at land-routing 00:50 - **corrected**: the "node shutdown" notice is not the harness's. It is the
  model's own `<system_warning>`, and the string appears in no file under `lua/` or `rust/`
  (`rg -n 'system_warning|interrupted by a node' lua/ rust/` -> nothing). The requirement is therefore met by
  a detector on the reply, not by deleting a notice the harness never sent.
* #53 - **confirmed and named**: the base exits 0 for a resumed session whose frozen prefix holds no tools
  (below, "failing on the base"), and `resume.sh` in the operator's own tree says "a mode switch cannot
  resume: #53" - the reason the resume path now names the mode.
* ENVELOPE wording - taken verbatim from the brief; it is the operator's sentence, not a paraphrase.

## Behaviour changes to existing assertions (named, not loosened)

#D changes two assertions in files that already existed. Neither was deleted or weakened; both were
rewritten to the new behaviour with a STRONGER check:

* `scripts/test-raw-code.lua` section 3: was `#dispatched==1` + "only the last one ran"; now
  `#dispatched==2`, in the order written, plus "the step formed one codemode call per run block", plus the
  two results labelled `run block 1 of 2` / `2 of 2` in row order.
* `scripts/test-raw-first.lua` section 6: the same, plus the label.
* `scripts/test-remote-refusals.lua`: **not** modified (I had added the relay checks there, found the file
  fails on the base, and moved them; `git checkout` restored it byte for byte).

## Verification (commands actually run, this node)

Each row with its own scratch `HOME`, `TMPDIR` and `WASM_AGENT_HOME`, never the real `~/.wasm-agent`;
`WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1` and a fixture key, so no paid call and no network:

    lua/core/finish_contract.lua     new module, 85 checks through scripts/test-thinking-block.lua
    test-thinking-block    85 checks   (was 34; 51 new: 5 shape detectors, 11 loop rows)
    test-raw-code          40 checks   (was 34: the #D stop-at-the-first-error row)
    test-raw-first         47 checks   (was 47 against fewer rows in its #D row)
    test-raw-native        23 checks
    test-raw-code-answer   11 checks
    test-empty-reply       51 checks   (its retry budget is untouched)
    test-codeact-default   12 checks
    test-resume-tool-registry 81 checks (was 77: #53 turn_refused + chat.turn_ok both ways)
    test-remote-call-shape 71 checks   (was 62: item E, the note, the caller and the numbers)
    and green, unchanged: test-answer-not-fake-tool-result 31, test-fake-answer-repeat-reset 13,
    test-codemode-boundary 33, test-no-silent-stops 84, test-compact-idle-route 17,
    test-overflow-recovery 16, test-model-facing-texts 19, test-prompt-tool-names 286,
    test-toolcall-gate 20, test-run-counts 36, test-stream-cut-recovery 29
    scripts/sync-prompt-docs.sh --check   ok (4 blocks current)

`#53` end to end, the failing-on-the-base / passing-after evidence (the same scratch home and the same
command, `WASM_AGENT_RAW_CODE=codemode`, a session whose frozen prefix holds no tools):

    base (stashed):  rc=0    "wa capabilities --json names what this node actually registered."
    this tree:       rc=1    "run is refused by name and exits non-zero rather than reporting a finished turn."
                             "wa: session e1f5d1f7-... failed"

Wired: `scripts/test-thinking-block.lua` at `scripts/test.sh:1616` (round 1's line, now 85 checks);
`scripts/test-remote-call-shape.lua` at `scripts/test.sh:1101`; `test-raw-code`, `test-raw-first`,
`test-raw-native`, `test-raw-code-answer`, `test-codeact-default`, `test-resume-tool-registry` are in the
fast path by directory (`scripts/test-*.lua`, none of them in `scripts/fast-path.exclude`; grep of
`scripts/test.sh` shows they were never rows there, before this change either).

## The `only` column, measured (item 10)

Ten short CodeAct turns on this node, in a scratch home (`HOME`=`TMPDIR`=`WASM_AGENT_HOME`=`/tmp/tb-only10`),
`WASM_AGENT_RAW_CODE=only`, provider settings inherited exactly as the node's own serve unit gets them
(`~/.wasm-agent/env` through the vault, never printed), model `deepseek-v4.1-flash`, ten different
one-to-three-tool tasks (count entries, date, write+size, read a file, count lines, git branch, remove a
file, join strings in JS, free space, count files):

| mode | turns | reasoning-only failures | gate continues |
|---|---|---|---|
| `first` (round 1's measurement, mission logs) | 25 | 10 | - |
| `only` (this round, live) | 10 | 0 | 0 |

Every one of the ten exited 0 with 1-3 tools run; none reached `reasoning is not an answer`, none needed the
finish-contract continue (`grep` for the status line: 0). Directional, not a controlled A/B: ten short turns
are not the 25 long mission turns behind the `first` column, and the tasks differ. What it shows is that the
mode the whole harness now defaults to did not reproduce the failure in ten live turns on this node.

## Texts to approve (verbatim; numbering continues from round 1)

8. (model-facing, markup) `[Harness notice] This message had no action: your message contains tool-call
   markup as text, so nothing ran; act with a js run block in your answer. The markup was <marker>, and no
   call could be read from it. One ```js run block that ends your message.`
9. (failure name) `tool_call_markup_as_text: the message carried <marker> tool-call markup as text and
   nothing ran; the harness asked for a js run block in the answer once already, so the turn is failed
   rather than finished without its action`
10. (model-facing, shutdown) `[Harness notice] That node shutdown warning is not from this session: it
    describes work from before this session started, this harness never sent it, and it is not an answer.
    Nothing ran. Continue the task from the state on this machine: your next step in your ANSWER, as one
    ```js run block.`
11. (failure name) `stale_shutdown_notice: the step ended on a node-shutdown warning about work from before
    this session started, and the harness asked for the next step once already; nothing ran, so the turn is
    failed rather than finished on it`
12. (model-facing, compaction) `[Harness notice] This message was a context-compaction summary, not an
    answer: nothing ran and the turn does not end here. Continue the task from where you stopped, in your
    ANSWER: your next step as one ```js run block, or the answer itself and why.`
13. (failure name) `compaction_answer: the step answered with a context-compaction summary instead of
    continuing the task, and the harness asked for the next step once already; nothing ran, so the turn is
    failed rather than finished on a summary`
14. (model-facing, plan) `[Harness notice] This message was a plan, not an action: nothing ran. Do the step
    you just described, in your ANSWER: one ```js run block that ends your message.`
15. (failure name) `plan_only: the step ended on a first-person intent with no action and no result, and the
    harness asked for the action once already; nothing ran, so the turn is failed rather than finished on a
    plan`
16. (model-facing, language) `[Harness notice] The user's last message is in <asked> and this answer is in
    <said>, so it is not the final answer: nothing was recorded as one. Write the same answer again in
    <asked>.`
17. (failure name) `language_drift: the answer was written in <said> and the user's last message is in
    <asked>, and the harness asked for the user's language once already; the turn is failed rather than
    finished in the wrong language`
18. (operator-facing status line, unchanged wording, new shape names) `the step ended without an answer
    (<shape>): asked once for it in the answer; nothing was run` - shapes now include `markup`,
    `shutdown`, `compaction`, `plan`, `language`
19. (#D, per result) `[raw code] run block 2 of 3; the N byte(s) you wrote after the last run block were
    dropped; this result replaces them` (replaces round 1's `your message had N ```js run blocks; only the
    last one ran`)
20. (#D, the block after a failure) `run block 3 of 3 did not run: run block 2 failed first, and the run
    blocks of one message stop at the first error.`
21. (ENVELOPE, CodeAct guidance, the operator's sentence verbatim) `A call still running when your script
    ends is not cancelled: it keeps running as a pending operation and its id is in the result - wait(op)
    resumes it in a later script, cancel(op) stops it.`
22. (item E, model-facing) `work did not answer a relayed call within 60 s (3 attempts; the relay holds a
    queued call about 20 s each), so this call stopped waiting (last reason: relay_timeout). Nothing here
    says the action did not run: read that node's state before re-issuing it. Work that needs longer is
    started ON that node and awaited there: tools.remote({node:"work", capability:"operation",
    action:"start", command:"<the command>"}) returns its id, and tools.remote({node:"work",
    capability:"operation", action:"await", id:"<id>", wait_s:300}) waits for it.`
23. (item E, the fix line) `Start the work on that node and await it there: tools.remote({node:"work",
    capability:"operation", action:"start", command:"<the command>"}) then tools.remote({node:"work",
    capability:"operation", action:"await", id:"<id>", wait_s:300}).`
24. (#53, the refusal's new clause) `, and this process runs WASM_AGENT_RAW_CODE=codemode, whose only action
    channel is a declared tool: a raw-code mode set now (`first` or `only`) cannot resume this thread
    either, because the frozen prefix is what the request is built from` and `This run is refused by name
    and exits non-zero rather than reporting a finished turn.`

## Not done, and pre-existing failures

* `scripts/test-remote-refusals.lua` FAILS ON THE BASE in this environment: `lua error: [...]:16: node
  refusal through the relay`, reproduced with the worktree changes stashed (`git stash push -u`). It is not
  mine and I did not touch it; because it dies before the end, item E's checks live in
  `scripts/test-remote-call-shape.lua` (green, `test.sh:1101`) instead.
* `scripts/test-done-gate.lua` FAILS ON THE BASE here too (`done-gate: 20 failed, 58 checks`, first line
  `FAIL the run continued past the early stop: Phase 1 is done...`), reproduced with the changes stashed. I
  checked the one thing that could have been mine - `finish_contract.inspect` on the three scripted answers
  returns nil, so the new gate does not touch that row - and the failure is identical on the base.
* `scripts/test-no-silent-stops.lua` is FLAKY here: `a beat moves the heartbeat` at line 55 fails on the
  base as well, and passed once on this tree in an earlier batch (84 checks). Not mine; the row measures
  host.beat against the wall clock.
* A reproduction of the round-1 failing turn against the live provider: still blocked (the credentials and
  the session ledger are behind the node's secret guard; round 1's "Evidence limit" stands).
* The `first` column of the rate table is round 1's measurement, not re-run this round.
* The ten `only` turns are not the same tasks as the `first` turns: the columns are directional.
