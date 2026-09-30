# Evidence per required item (independent review of `ea2f2011`)

Reviewer's scratch tree: `git archive ea2f201 | tar -x -C /tmp/rev-af915180/tree`; the binary is the
delivery's own `rust/target/release/wa.exe`; `WASM_AGENT_HOME` and every `--db` are scratch. The
delivery's worktree was read, never written; its branch was not modified.

## Item 1 - a real request through our own client, with Pi renamed aside: REPRODUCED

With `@earendil-works` renamed aside and `PI_CODING_AGENT_DIR` + `WASM_AGENT_PI_MODELS_STORE` pointing
at paths that do not exist:

```
pi-package-absent:   ls: cannot access '.../npm/node_modules/@earendil-works': No such file or directory
pi-agent-dir-absent: ls: cannot access '/tmp/rev-af915180/NO-PI-AGENT-DIR': No such file or directory
pass 1: finish_reason=tool_calls ttft_ms=1100.8286 events=11 usage={"completion_tokens":18,...,"prompt_tokens":80,"total_tokens":98}
pass 1 tool call: id=call_IcuVrsmKfmaXo7YcWsQaQk3a|fc_02f6ca779eadfb9e016abd1805dc0087d2b62fcf848b624578 name=get_time arguments={"zone":"UTC"}
pass 2: finish_reason=tool_calls ttft_ms=1397.2395 events=24 answer="" commentary=1 usage={...}
pass 2 streamed events: commentary=1 decision=2 pending_delta=8
subscription wire live check ok          (EXIT=0)
restore: C:/Users/Victor/AppData/Roaming/npm/node_modules/@earendil-works   <- restored, verified on disk
```

Deltas, a tool call with the `call_id|fc_item_id` shape and parsed arguments, usage, and 8
`pending_delta` events resolved by one `commentary` - same shape as the producer's numbers, from a
different run at a different time. The line `credential: lua/core/subscription_auth.lua is absent;
using the pi-auth stand-in` is **absent**, so the seam answered, not the diagnostic stand-in.

Route entry point (`lua/core/openai_sub.lua` -> `wire.complete`, `WASM_AGENT_SUBSCRIPTION_TRANSPORT=native`,
Pi unreachable): `finish=tool_calls complete=true model=gpt-6-luna req=resp_00a4... ttft=1168.4379
tool_calls=1 usage={...}`; result keys exactly `content, commentary, final_phase, reasoning,
tool_calls, finish_reason, stream_complete, model, request_id, ttft_ms, usage` plus the delivery's
own telemetry keys (`events, lines, saw_terminal_event, termination, transport, commentary_streamed`).

Event vocabulary seen live (never from the fixtures), with Pi unreachable:
`pending_delta`, `commentary`, `decision` (live check) and `delta` for a streamed final answer
(`Reply with the single word OK` -> `PLAIN events: delta=1`, `finish=stop phase=final_answer
content="OK" events=9`).

## Item 2 - no node, no pi at runtime: REPRODUCED, as the finer claim this box forces

This box runs many `node.exe` processes owned by other lanes (codex, `merge-lane.mjs`,
`gate-lane.mjs`), so "there is no node on the box" is false here and would be the wrong thing to
test. What was measured is the **process tree the request actually ran in**: the process table was
sampled every ~430-500 ms while the request was in flight (`Get-CimInstance Win32_Process`), and the
tree rooted at the request's own `wa.exe` was computed from every sample.

* The request's process: `"41204","67860","wa.exe","C:\Users\Victor\.wasm-agent\wa-worktree-childdispatchaf915180-...\rust\target\release\wa.exe --db .../inflight.db"`.
* In all 7 samples in which it was alive: `ancestors = wa.exe -> bash.exe -> bash.exe`,
  `descendants = 0` - **no child process at all**, so no `node.exe` and no Pi adapter under it.
* Control, so the sampler is not blind: the same sampling run while a `node -e ...` was alive caught
  it (`control.csv`, 329 rows, `node.exe` present), and the in-flight samples themselves contain
  unrelated `node.exe` rows owned by other lanes. The sampler sees node; it is not in this tree.
* The three rows matching `earendil-works` in those samples are the reviewer's **own** `bash.exe`
  command line (it names the path in the `ls -d` that proves the package is gone), not a process
  reading the package.
* Same run proves the client is ours: the result carried `transport=native-codex-responses`.

## Item 3 - credentials only from the seam

`lua/core/subscription_wire.lua:111-125`: `M.credential()` is `dofile('lua/core/subscription_auth.lua')`
under `pcall`, requires `module.token`, requires a non-empty `value.access`, and
`M.credential_provider = M.credential` is what `M.complete` calls at `:860`. There is no other
credential source and no `~/.pi` read in the wire.

Live, with Pi's package renamed aside **and** `PI_CODING_AGENT_DIR` unreachable, both requests
completed with no stand-in line printed. Reproduced with the sibling's module copied (read-only,
`git show a6e111d:lua/core/openai_sub_auth.lua`, 1030 lines) to `lua/core/subscription_auth.lua`
**inside the reviewer's scratch tree only**. Nothing was merged; the delivery's branch is untouched.

The seam-name mismatch is real, confirmed independently: the sibling tip `a6e111d`
(`…8ad3ecc6…`) contains `lua/core/openai_sub_auth.lua` and **no** `lua/core/subscription_auth.lua`
(`git ls-tree -r --name-only a6e111d -- lua/core/ | grep -i auth` -> one path). As both branches
stand, `dofile('lua/core/subscription_auth.lua')` cannot resolve. Facilitating detail: `24fb23c`
(`…95d6189a…`) is an ancestor of `a6e111d`, and the producer recorded its live run against the older
one.

## Item 4 - the event contract: preserved in the code, `reasoning` unverified

Emission sites (`lua/core/subscription_wire.lua`): `delta` (`:533`, and `:711` on resolution),
`pending_delta` (`:536`), `reasoning` (`:641`, `:648`, `:656`), `decision` (`:491-495`),
`commentary` (`:708`). `session.result` (`:785-843`) returns exactly `content, commentary[],
final_phase, reasoning, tool_calls[], finish_reason, stream_complete, model, request_id, ttft_ms,
usage`. The provisional-then-resolved rule is `text_delta` (`:530-538`): text streams as `delta` only
when the block's phase already said `final_answer`, otherwise as `pending_delta` keyed
`stream_id .. ':' .. slot.index`, resolved once at `output_item.done` (`:702-713`, and only if it had
not already streamed).

Verified live: `pending_delta` -> `commentary` (8 -> 1), `decision` provisional then complete, `delta`
for a streamed final answer. **Not verified anywhere**: no live run of mine and neither committed
fixture contains a single `response.reasoning_*` event (`grep '^event: '` on both fixtures lists only
`created, in_progress, output_item.added/done, function_call_arguments.delta/done,
output_text.delta/done, content_part.added/done, completed`), so the `reasoning` stream event and the
`reasoning` result field are exercised by no test and were observed by nobody in this review.

## Item 5 - cancellation, `WASM_AGENT_SUBSCRIPTION_TIMEOUT`, truncation

Live, bound `WASM_AGENT_SUBSCRIPTION_TIMEOUT=1` (Pi unreachable), stream asked to count to 200:

```
DEADLINE ok=false err=subscription_timeout: no completion within 1s (WASM_AGENT_SUBSCRIPTION_TIMEOUT);
        the stream was stopped after 6 line(s)
```

The name is the documented one, there is no Lua traceback and no file path in it, and it stopped
mid-stream (6 lines), not at the end. Out-of-range bound: `WASM_AGENT_SUBSCRIPTION_TIMEOUT=0` ->
`invalid_subscription_timeout: expected 1..86400 seconds`, before any request leaves. (That one
*does* carry a `...subscription_wire.lua:148:` position prefix, unlike the two documented names,
because `M.request_timeout` raises without `error(..., 0)` - cosmetic, same class as defect (a) in
the status file.)

Cancellation and truncation are offline-only in this delivery; the offline suite asserts both,
anchored (`^run_cancelled`, `^subscription_timeout`) plus "no `subscription_wire.lua` path in the
message", and asserts a cut fixture fails as `subscription_stream_truncated` with `partial answer is
not an answer`. I ran that suite (below). A live truncated stream needs an endpoint that cuts the
response; I did not build one, and neither did the delivery.

## Item 6 - the fixture is real wire bytes: REPRODUCED, re-recorded identical

The fixtures are the endpoint's own bytes (`access_programs`, `sequence_number`, `obfuscation`,
`tool_usage`, `max_tool_calls` - fields no hand-write invents). I re-recorded both streams live
through the delivery's wire and diffed them against the committed files, normalising only the four
redacted fields plus the ids/`created_at` the README names as deliberately not redacted:

```
== tool mine lines 34 committed lines 34 identical: True
== text mine lines 73 committed lines 73 identical: True
```

So the recorded bytes are the endpoint's and are current, not stale. Redactions are named in
`tests/fixtures/subscription/README.md` (`prompt_cache_key`, `safety_identifier`, `user_id`,
`account_id`, all as the literal `<redacted>`), enforced by the recorder
(`check-subscription-wire-live.lua:55,61-62`) and bounded at 1 MiB, failing loudly rather than writing
a truncated fixture (`:28,64-70`). Bound observed: the two files are 7 407 and 11 218 bytes. The
parser is tested against them offline (suite runs below).

## Item 7 - the catalogue we own

Live, with `WASM_AGENT_PI_MODELS_STORE` pointing at a file that does not exist:

```
TRANSPORT native
CONFIGURED true
CATALOGUE known=table unknown=nil unknown_is_table=false     <- nil, not {}
WINDOW {"context_window":272000,"max_output":128000} unknown_window=nil
SERVES gpt-6-luna=true gpt-9-nope=false
```

The documented update path exists and reproduces the file (real store via `WASM_AGENT_PI_MODELS_STORE`):

```
import: 9 openai-codex-responses entry/entries from C:/Users/Victor/.pi/agent/models-store.json
catalogue unchanged: lua/core/openai_sub_catalogue.lua already matches the store, so nothing was written
```

sha256 of the catalogue unchanged by that run. Falsified the other way: with one id tampered in the
block, the same command prints `catalogue update: added gpt-6-luna; dropped gpt-6-luna-TAMPERED
(9 entries)` and writes - and the file it writes is **byte-identical to the committed one** (sha256
equal again). That is the strongest available form of "the checked-in catalogue is the import's
output". Doc nit in that script: its header says "Exit is non-zero when nothing was written"; the
unchanged path exits 0 (observed).

Still reading `~/.pi` outside this route, as the producer says: `lua/core/model_window.lua:167`,
`lua/core/provider.lua:162`, and `openai_sub.lua`'s `auth_path`/`models_store_path` for the **Pi**
transport (`:13-22,34`). Nothing under `lua/` reads the store for the **native** route.

## Offline suites run by the reviewer (delivery's binary, scratch tree)

| suite | command | result |
| --- | --- | --- |
| wire (the new one) | `WA_SCRIPT=scripts/test-subscription-wire.lua wa --db …` | `subscription wire ok (132 checks)`, exit 0, 82 ms |
| levels | `WA_SCRIPT=scripts/test-openai-sub-levels.lua wa --db …` | `openai-sub levels ok (22 checks)`, exit 0 |
| bridge | `node scripts/test-openai-sub.cjs wa` | `native subscription operations ok (15 checks)` + `PASS`, exit 0 |
