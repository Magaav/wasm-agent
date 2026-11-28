# turn-survives-a-provider-stall: report first (H week 1)

Victor, 24/11 (work node, build 7865a08e): a provider stall ended the turn and showed a raw Lua stack,
and the self-wake turn that followed rendered as legacy - the Commentary header, no run box, no status
row.

Branch change/turn-survives-a-provider-stall, base origin/main at 18b83398.
**This commit is the report only: no product code is changed, per the H-wave rule ("REPORT FIRST ... No
product change until Fable answers").** Every number below is a measurement I ran on this node or a line
of this tree, and each one says which.

---

## 0. How the numbers were taken

~~~
tree's Lua   WASM_AGENT_LUA_ROOT=/home/victor/Work/missions/turn-survives-a-provider-stall/wt
scratch home HOME=WASM_AGENT_HOME=/tmp/wa-measure-stall/home   (the script refuses any other home)
host         the installed release binary "wa v0.1.2 - v9a0c589a" (build 16/11)
provider     stubbed in-process: host.http_stream replaced; no network, no vault, no fleet
~~~

The host is **stale relative to this tree** (no binary for this tree is built yet), so this measures the
tree's Lua, not the tree's Rust. What it cannot prove is host-side behaviour
(rust/wa-capabilities/src/host.rs); the deadline arithmetic, the request counts, the ledger rows and the
error text are all Lua.

The script is scratch (/tmp/wa-measure-stall/measure.lua, not in the repo). Its core, so the number can
be re-taken:

~~~lua
local calls = 0
host.http_stream = function()                    -- case A: one stall, then an answer
  calls = calls + 1
  if calls == 1 then return json.encode({ error = "timeout: receive response (provider_stalled: no response within 90s)" }) end
  return json.encode({ status = 200, content = "answer", finish_reason = "stop", tool_calls = {}, stream_complete = true })
end
local agent = agentlib.new(sid, function() end, "master", "master", "local"); agent.stream = true
local ok, err = pcall(agent.run, agent, "ask")
~~~

---

## 1. Re-measured premises (the brief's facts, checked against this tree)

| the brief says | measured today on 18b83398 | verdict |
|---|---|---|
| a raw Lua stack reaches the person: agent.lua:3366 / provider.lua:1666 / provider.lua:1599 | a failing stall really prints: ".../lua/core/agent.lua:3366: .../lua/core/provider.lua:1666: .../lua/core/provider.lua:1599: provider_error: timeout: receive response (provider_stalled: no response within 90s) [first-response deadline expired again after 1 bounded replay(s) ...]" | **true, and those exact three frames**. It is a chain of location prefixes, not a debug.traceback - the wording "stack" is loose, the effect is the same. Sources: agent.lua:3366 error(problem); provider.lua:1599 and provider.lua:1666 re-raise it; chat.lua:716 prints it unsanitised as view:failed(redact.text(tostring(reply))). redact.text does not strip locations, and run_failure.strip_locations (run_failure.lua:110) is applied to the **row**, never to that line. |
| "1 bounded replay each" | provider.response_timeout_retries() = **1** by default (provider.lua:1074; clamp 0..3 via WASM_AGENT_PROVIDER_RESPONSE_RETRIES); the replay waits 2 s, jittered (provider.lua:1086) | **true** |
| "EACH became a new turn, started by a self-wake" | a run that stalls twice: the run fails, run_failure.wake (run_failure.lua:270) schedules one wake **60 s out** (run_failure.lua:246) with reason "run failed: provider_stalled"; its dispatch is a **second run** in the same session | **true** |
| "one request cost 3 turns" | measured row sequence for one ask that stalls twice: user ask -> failed assistant row -> user row "[self-wake - run failed: provider_stalled] ..." -> assistant answer. 4 messages, 2 of them prompt rows the person reads as if they had typed them | **true** |
| item 3: two drawing paths; replay draws a wake | confirmed in the code, see section 3 | **true** |
| **new** | **one stall alone already survives today**: 2 HTTP requests, 1 run, 1 user row, 1 assistant row, 0 failure rows, 0 wakes | the first clause of acceptance item 1 is already true at the request and ledger level; what is missing is the second stall, the render, and the text |
| **new / stale** | the "300 s" in "provider_stalled: no first response within 300s" is **this node's configuration**, not a measurement of the request: WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS=300 is set in the environment the agent runs under (measured with printenv). With the default formula a 300 s deadline would need at least 872 000 estimated context tokens (section 2) | the brief's item 5 premise ("context size vs provider") is **not** what a 300 s reading shows |

---

## 2. Item 5: why a long session's first response stalls

The deadline is one function (provider.lua:1016-1030): 90 s base, **+1 s per 4 000 estimated tokens above
32 000**, ceiling 300 s. Called directly on this tree:

| estimated context tokens | deadline |
|---|---|
| 1 000 | 90 s |
| 32 000 | 90 s |
| 100 000 | 107 s |
| 400 000 | 182 s |
| **872 000** | **300 s (ceiling)** |
| 1 200 000 | 300 s (ceiling) |

So a call is given 300 s in exactly two ways: an estimated context of at least 872 000 tokens, or the
**flat override**, which is what this node has. On a node with the override, "no first response within
300 s" says nothing about the size of the request, and the size hypothesis cannot be settled from the
sentence Victor saw.

What that changes for the design: with the override at 300 s and the measured retry budget of 1, **one
stalled request is up to 601 s plus backoff inside a single turn**, with only the status row saying
"retrying in Ns (1/1)" (agent.lua:3081). Then a new turn starts the whole 600 s again.

**What I could not measure**: the deadline_seconds and context_estimate of the work and laptop sessions.
The local ledger read is refused to agent tools - lua/core/secret_guard.lua answers secret_path_denied on
~/.wasm-agent/memory.db, correctly, because that store holds every connector's approval - and **I did not
route around the guard**. The operator settles it with one read-only query:

~~~sh
sqlite3 -readonly ~/.wasm-agent/memory.db "SELECT json_extract(payload,'$.deadline_seconds') deadline,
  json_extract(payload,'$.context_estimate') ctx, count(*) n FROM harness_events
  WHERE kind='provider_retry' GROUP BY 1,2 ORDER BY n DESC"
~~~

Every row at 300 with a small ctx means the configuration explains it; a ctx near 872 000 means the
formula does. The event is written at agent.lua:3085-3088.

---

## 3. Item 3: which drawing path each wake kind takes today

Every one of the four kinds ends as **the same row** - a self_wakes row claimed by selfloop.claim_due
(selfloop.lua:1215) - and the turn is run by **whichever process claims it**: wa_completion_run on the
node thread (completions.lua:331 -> selfloop.run_wake, selfloop.lua:1441), or an attended CLI at its idle
prompt (chat.lua:918 wake_if_due -> chat.lua:901 wake_turn).

| wake kind | where it is armed | who runs the turn | what the person sees |
|---|---|---|---|
| 1. provider stall retry | run_failure.wake, run_failure.lua:270 (one row, 60 s out) | the node thread, or the attended CLI if it claims first | claimed by the CLI means **live**; claimed by the node means **replay** in every window (below) |
| 2. resume after an install pause | deploy_pause.lua:195 and deploy_pause.lua:793 (the same schedule call) | same | same |
| 3. a re-armed lost resume | selfloop.defer_refused re-times a refused row; run_recovery.due (run_recovery.lua:83) re-drives the model turn in the process that opens the thread | the opening CLI (live, but as a **new** turn) or the node (replay) | live for run_recovery, replay for the wake |
| 4. a pending call settled | handle_wake.schedule, handle_wake.lua:91 (id handle:<op>) | same as 1 | same as 1 |

The two paths, in the code:

- **live** - chat.lua:901 wake_turn: view:run_started() (cli_view.lua:2818), then agent.run emits every
  event into the view. Run box, status row, spinner, timer.
- **replay** - chat.lua:881 catch_up, on the same 2 s tick as the restart check, at the idle prompt: it
  reads the rows this CLI has not shown, prints "  -> added to this session elsewhere (the node, a
  sentinel wake):" (chat.lua:891) and calls view:replay (cli_view.lua:3680). In replay, assistant text
  that carries tool calls is drawn as the **Commentary** topic (cli_view.lua:3273, through the
  row.phase == "commentary" branch), and "a replay is not a run, so no status line is started for it"
  (cli_view.lua:3746).

**That is exactly what Victor saw**: the wake turn ran on the node, the window was not connected to it,
and 2 s later catch_up drew it as history. There is no second TUI, and no window ever attaches to a turn
it did not start.

---

## 4. Ledger consequences: what the turn/run rows become

Today, per ARCHITECTURE.md section 6 (:152-163): a **run** is one ask-and-answer execution, a **turn** is
one speaker's contribution, a **message** is one stored row. In the store: runs (schema.sql:45) holds one
row per run with run_id = its own id, and messages (schema.sql:83) holds the transcript and **carries no
run id at all**.

What this mission makes them, and what that costs:

1. **One turn, several runs.** Each attempt is one runs row, as memory.record_run writes it today
   (memory.lua:1825). To read them as one turn the continuation rows need a parent: a runs.parent_run_id
   (not a rewrite of run_id). That field is **replicated** - memory.record_run journals every run
   (memory.lua:1829) and peers apply it (memory.lua:1955) - so it needs the same old-peer alias treatment
   the turn_id -> run_id rename got (memory.lua:277-282); an unmigrated peer must not read a new column as
   empty and call one turn two.
2. **The failure row stops ending the turn.** Today run_failure.record writes **one durable assistant row
   with ok=false** (run_failure.lua:185-206) and memory.session_state / evidence.failure() read exactly
   that shape. If the turn continues instead, the pause has to be a **span** inside the turn plus one thin
   view line, and either session_state learns the "paused, continuing" tail or the state stays running,
   because the turn really is still running. **That is the named risk of this change**, and it stands on
   the same ground as resume-carries-state: one mechanism, not two - a turn that ENDS hands the next one a
   machine-written line of what the dead turn completed, and a turn that only PAUSES must not need that
   line at all, because nothing was rebuilt. Cross-referenced here, and to be reused, never duplicated.
3. **The person's reading**: one prompt row, one run box, one status row that never resets, and one thin
   marker where it paused ("paused 4m12s: waiting for the provider"). The wake marker stays in the
   transcript as evidence, not as a fake prompt row.

---

## 5. Esc and /status during the pause

**Today.** Esc (or Ctrl-C) during a provider wait shuts the socket to wake the silent read; the run ends
run_cancelled, run_failure.handle records one plain row - "Interrupted by user" (run_failure.lua:145,
:303-305) - with **no wake and no retry** (M.wake refuses a cancellation, run_failure.lua:270-280), and
the CLI's cancel flag **pauses the schedule** (selfloop.claim_due -> M.pause, selfloop.lua:696).

/status (commands.lua:48) is **session id, model, and each provider's usage and limits**. It does not name
a pause, a pending wake or a wait - /wakes is the surface that lists pending wakes (commands.lua:50).
Nothing on screen says "this turn is paused, here is why, here is the bound".

**What the design must say (for Fable to settle):**

| surface | during a pause |
|---|---|
| status row (cli_view.status_text, :1718) | shows the wait and its bound: "waiting for the provider 4m12s of 10m". This is the row that already exists; no new row. |
| Esc | stops the turn it is pausing - the same one line, the same no-retry - **and releases the pause record**, so "paused 4m" cannot outlive a turn the person stopped. |
| /status | I propose it stays exactly as it is (usage and limits) and **does not** grow a pause line: a second place reporting the same fact is a second place that can disagree. /wakes keeps listing pending wakes. If Fable wants a line there, it must be the same string the status row uses. |

---

## 6. Cost and time per turn

Today the ledger can separate model time and tool time per **run**, but nothing aggregates them per turn,
and the wait between two runs belongs to nobody:

- a model call writes a span with ms and request_bytes (provider.lua request_meta -> telemetry.start and
  telemetry.finish);
- the first-response replay **sleeps inside the run**, so a stalled run's ms already contains it
  (agent.lua:3093-3105; run_failure.handle is given ms = now - run_counts.started_at, agent.lua:2356);
- the 60 s wake and a 4-minute install pause are between runs and appear in **no** turn's time.

What I propose: model_ms = the sum of model-call spans, tool_ms = the sum of tool spans, provider_wait_ms =
the sum of pause records - all three from rows already written plus the one new pause record, written on
the run row. No new instrument for model and tool time; one new field for the wait. Cost per attempt does
not change (a continuation re-sends the same request), so a paused turn costs exactly what its attempts
cost.

---

## 7. Prompt-cache bytes: a healthy turn must not change

The bounded replay today changes **only call options**, never messages (agent.lua:3081-3110:
context_tokens, call_opts.attempt, and steering if any arrived), so the retry sends byte-identical
content, and provider.lua's request_meta records request_hash, system_hash, schema_hash and
prefix_fingerprint to prove it.

**Rule for the change**: the pause marker is a ledger row and a view line, **never** a message in the
context. A continuation that slipped "paused 4m12s" into the request would change system_hash and
prefix_fingerprint and turn every pause into a cache miss for the whole prompt. The check after
implementation is the one already recorded: the prefix on the model-call span and normalized.cacheRead
(agent.lua:3378) must be the same across the pause as across today's replay.

---

## 8. What is not done, and what waits on Fable

- the four acceptance rows (one turn per wake kind, counters never reset, driven on a scratch node) -
  **not started**, by the H-wave rule;
- a wake-started turn captured at 80 columns - **not started**. The harness to use already exists:
  scripts/test-run-live-pty.mjs (private tmux socket, capture-pane, a local SSE fixture, env -i plus an
  allow-list, a scratch root that refuses the real ~/.wasm-agent);
- a binary built for this tree - the measurement above used the tree's **Lua** under the installed host
  v9a0c589a, and says so;
- the runs.parent_run_id migration and the session_state decision (4.2);
- this branch is **behind origin/main by 11 commits** (the G wave landed while this report was written); it
  will be rebased onto origin/main before it goes anywhere.

## 9. Texts to approve

None. This commit adds no product string and changes none; the only new text is this file.

## 11. Item 5 closed, and two answers this branch uses (mission continues on branch
## change/turn-survives-a-provider-stall)

**Item 5, re-measured on this tree in a CLEAN environment** (the report's §2 computed it; this is my own run):

| estimated context tokens | deadline |
|---|---|
| 1 000 | 90 s |
| 32 000 | 90 s |
| 100 000 | 107 s |
| 400 000 | 182 s |
| 872 000 | 300 s (ceiling) |
| 1 200 000 | 300 s (ceiling) |

and with no argument and no override: **90 s**. `WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS` is **nil** in a clean
agent environment while the agent's ambient environment has it at 300. So the 300 s Victor saw is the node's
flat override, not the size of the request: the size hypothesis cannot be settled from that sentence, and
the operator's read-only query in §2 is what distinguishes the two.

**Two answers this branch relies on, both already in this report:**

* §4.2 - a turn that continues must NOT write the failure row (`run_failure.lua:185-206`, which
  `memory.session_state` and `evidence.failure()` read); the pause is a SPAN plus one thin view line. The stall
  pause (item 1, commit `e11c0bba`) does exactly that: the loop's own `status` line and one `provider_retry`
  span, no assistant failure row - asserted by `scripts/test-stall-pauses-the-turn.lua`.
* §4.3 - what the person should read for a turn that ran elsewhere: one prompt row, one run box, one status
  row that never resets, and one thin marker where it paused. That is the specification for the next write
  (item 3's replay half).

## 12. The pty harness is RED on main (measured both ways), and what that means for acceptance item 2

The brief's acceptance item 2 is "a wake-started turn captured at 80 columns looks like a typed turn", and
the harness the report names for it is `scripts/test-run-live-pty.mjs`. Measured on this node:

| tree whose Lua it runs and whose binary it uses | result |
|---|---|
| this branch (`change/turn-survives-a-provider-stall`) + the tool-progress binary | **2 ok, 6 failed** |
| a worktree WITHOUT this branch's changes, same binary, same script | **2 ok, 6 failed** |

The same six fail either way, so they are **pre-existing on main** and are not this branch's. They are named
here, not fixed: a pty harness that is red before the change cannot serve as the green row the acceptance
asks for, and repairing it is its own item. What IS proved for item 2 on this branch is the rendering
itself, in the capture-based row C1 added to `scripts/test-cli-view.lua`: the same rows drawn as history
say Commentary, drawn as a turn do not, and the answer reaches the reader at the width the view is given.

## 13. Rows re-run around item B (the retry-loop change), all green

Item B changes the loop every provider failure goes through, so the rows that pin it were run on this
tree's Lua (scratch home, stubbed provider, no network):

| row | result |
|---|---|
| `test-provider-stall.lua` / `-marker` / `-replay` | 17 / 6 / **35** (two exact counts changed on purpose, named in its diff) |
| `test-no-silent-stops.lua` | 154 |
| `test-cancel-not-retry.lua` | 15 |
| `test-empty-reply.lua` | 51 |
| `test-run-lease-order.lua` | 6 |
| `test-answer-not-fake-tool-result.lua` | 31 |
| `test-operation-survives-turn.lua` | 16 |
| `test-provider-rate-limit-recovery.lua` | 46 |
| `test-retry-context.lua` | 7 |
| this branch's own rows: `stall-pauses-the-turn`, `stall-line`, `turn-time-split`, `turn-tail`, `cli-view` | 13, 13, 12, 10, 569 |

No adjacent row regressed. The one row whose numbers changed states the new numbers, the reason, and the
arithmetic (`1 try + 2 replays + the pause = 5`; both switches off = `2`, the loop once plus the run's own
re-drive) - it was tightened, not loosened.



**Shas move; subjects do not.** This branch has been rebased onto `origin/main` more than once while it was
being worked (each rebase rewrote every sha), so the table above names commits by SUBJECT and
`git log --oneline` on the branch resolves them. The single sha that matters to a landing is the one in the
ready file's first line, and it is updated whenever a rebase is observed.

**Rebased.** This branch was rebased onto `origin/main` `f6fea716`; the commits named above are the ones on
the rebased branch (the earlier SHAs pointed at commits the rebase rewrote, and are gone). The rows were
re-run on the rebased tip by this mission - `stall-line` 13/0, `stall-pauses-the-turn` 13/0,
`turn-time-split` 12/0, `turn-tail` 10/0, `provider-stall-replay` 35/0, `cli-view` 569/0 - not taken from
an earlier run.

## 10. Every claim, and the check behind it

| claim | checked by |
|---|---|
| the three frames, agent.lua:3366 / provider.lua:1666 / provider.lua:1599 | case B of the scratch script, run on this node; the text is in its output |
| replay budget = 1 | provider.response_timeout_retries() called in the scratch script (printed 1); source provider.lua:1074 |
| one stall = 2 requests, 1 turn, 0 wakes | case A: A_http_requests=2, A_user_rows=1, A_assistant_rows=1, A_failed_rows=0, A_wakes=0 |
| two stalls = 2 requests, a wake, then a second turn, 4 rows | case B: B_http_requests_after_wake=3, B_rows_after_wake=4, B_user_rows_after=2, and the second user row read "[self-wake - run failed: provider_stalled]" |
| the deadline table | the script printed it from provider.first_response_seconds on this tree |
| 300 s is this node's configuration | printenv WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS -> 300 |
| the two drawing paths | code: chat.lua:881/891/901, cli_view.lua:2818/3680/3746/3273 |
| the ledger shapes | schema.sql:45/83, memory.lua:1825/1829/1955/277-282 |
| Esc's behaviour today | code: run_failure.lua:145/148/303-305/270-280, selfloop.lua:696/1215 |
| /status says nothing about a pause | code: commands.lua:48/50 |

## 14. This branch's verdict (mission continues after the report-first commit)

**Landed, with the row that pins it:**

| brief item | commit (by subject - a rebase rewrites the shas) | what it does | row |
|---|---|---|---|
| 2 - no raw stack reaches the person | `stall: the person reads the failure, not three Lua paths` | `run_failure.human_line` classifies, strips the leading locations and renders the row's own wording; `chat.lua` prints it | `test-stall-line` 13 |
| 1 - a stall pauses the turn | `stall: a stall pauses the turn instead of ending it` | the stall becomes its own class in the run's existing retry loop, with its own budget (`STALLED_ATTEMPTS`, default 2, clamp 1..4), backoff (2/4/8 s, capped 30 s) and the loop's waiting row stating it | `test-stall-pauses-the-turn` 13 (one stall = 2 asks, ONE turn, no failure row) |
| 3 - a wake turn draws like a typed one (replay half) | `stall: a wake-run turn’s answer draws as an answer` | `replay()` gained `opts.answer`; `catch_up` passes it, so a wake turn's text is an answer, not the Commentary topic; history keeps the commentary treatment | `test-cli-view` 569 |
| 3 - the CLI attaches to a node-run turn (C2a) | `stall: the CLI attaches to a node-run turn by cursor` | `lua/core/turn_tail.lua`: a cursor over `harness_events` draws the pause ("paused 2s: the provider has not answered (1/2)") and the model status; not a run, no timer | `test-turn-tail` 10 |
| 4 - time split per turn | `stall: the three times are separable per turn` | no new columns: `provider_retry.wait_ms`, `model_call.ms`, `tool`, all in one `run_id` | `test-turn-time-split` 12 |
| 5 - why a long session's first response stalls | `stall: item 5 closed with my own measurement` | the 300 s is the node's flat override; in a clean environment the default is 90 s and the ceiling needs 872 000 estimated tokens | the table in §11 |

Adjacent rows re-run around the retry-loop change: §13. The pty harness is red on main, measured both
ways: §12.

**ONE item open: C2b - Esc on a turn a SERVED node owns.** `host.run_cancelled` is process-local
(`host.rs:593`) and `scheduler.cancel_run` is in-process memory (`scheduler.rs:376`), so the cancel has to
reach the node over its own door. The route and the credential are already in use by the window
(`POST /runs`, headers `X-WA-Session` / `X-WA-Node`, `ui/app.js:230-233`); the missing fact is the BASE URL
of a local `wa serve` as a sibling process sees it - `binding.status()` is `present=false` on a local node,
`host.binding_state` needs an action, `wa serve --port` defaults to 8799 (`main.rs:744`) and publishes no
file. That is a product contract to name, not a mechanism to invent, and it is why this item stops here.
