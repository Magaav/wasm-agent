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
