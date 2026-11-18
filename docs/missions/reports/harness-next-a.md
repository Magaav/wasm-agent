# change/harness-next-a - the three things that stop Victor's daily sessions

Base: change/land-r1 (4145b7f7). Branch: change/harness-next-a. Nothing pushed; no node state touched: every
row below ran in its own `mktemp -d` home with no rendezvous, no relay, no vault and its own database, and
each row replaces the provider before any model call (no paid inference).

The three items are implemented once each, with the measured session 100c54ab (18/11) as the evidence:

| # | what the session measured | what is true now | row |
|---|---------------------------|------------------|-----|
| 1 | #15 three turns ended with a *model-written* tool result as the answer (12:48, 13:40, 14:16) | such a message is never an answer: markup stripped, run continues, event recorded, 3 in a row fails by name `fake_tool_result` | `scripts/test-answer-not-fake-tool-result.lua` (31 checks) |
| 2 | 7 TimeoutError endings, one at the 300 s maximum, on scripts that were waiting | no wall clock on a script waiting on tools; a call keeps its wait (60 s default, 300 max) and answers `{state:"pending",op}`; the only hard stop is the CPU guard; the 30 s default and the "pass timeout_ms" hint are gone; past the node's cap an operation QUEUES and runs at `nice+10` | `scripts/test-codemode-never-killed.lua` (19 checks), `scripts/test-operation-queue-priority.lua` (29 checks) |
| 3 | provider stall ended a turn: `provider_stalled - timeout: receive response`, nothing retried, one flat 90 s deadline | a request with no response headers before its (request-sized) deadline is replayed with backoff, bounded, counted and said in the run; a stall that survives its replays says how many it took | `scripts/test-provider-stall-replay.lua` (33 checks) |

## How the rows were run

The full fast path, on this node (avell, 16 cores), with this tree's binary and this tree's Lua:

```
cd /home/victor/Work/missions/harness-next-a/wt
CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-harness-next-a bash scripts/fast.sh --jobs 6
```

A single row, by hand:

```
h=$(mktemp -d); env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE \
  -u WASM_AGENT_VAULT_PASSPHRASE -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN -u WASM_AGENT_RAW_CODE -u WA_MESH \
  WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=$h WA_COMPONENTS_DIR=$h/.wasm-agent/components \
  WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT=scripts/<row>.lua \
  timeout 200 /home/victor/wasm-agent/target/m-harness-next-a/release/wa --db $h/t.db
```

"Before" is the same row with `lua/` and `rust/` reverted to the base (`git stash push -- lua rust`) and the
installed node binary `/home/victor/.local/bin/wa` (build 2e6fab41, quickjs present) - that pair is the
behaviour the session measured. Every "before" below is a real run, quoted from its own output.

## Full suite

The run of record on this branch:

```
fast: binary /home/victor/wasm-agent/target/m-harness-next-a/release/wa (built from this tree)
fast: lua 231/231 passed (56 excluded: scripts/fast-path.exclude)
fast: rust wa-capabilities ok, wa-operation ok, wa-sentinel ok, wa-mesh ok
fast: prompt-docs ok, instructions ok, fast-binary ok, direct-workflow ok, mcp-mail-repairs ok
fast path ok (267 checks, 0 skipped, 188s)
```

Four of those 267 checks are the new rows below.

## 1. A tool result is a fact the harness produces, never text a model writes


New `lua/core/fake_answer.lua` (a pure detector, `M.scan`), wired into `lua/core/agent.lua` at the one place a
text-only step becomes the answer, and named in `lua/core/run_failure.lua`.

* **The rule.* A step with no tool call whose content contains a tool-result or tool-call element the model
  wrote itself is not an answer. The markup is removed from the recorded content, the step is recorded with
  `phase = "fake_tool_result"`, a durable harness-notice row tells the model what it did and to call the tool
  instead, a status line says it in the run, the trace gets a `fake_tool_result` span and telemetry gets a
  `fake_tool_result` event; then the run takes its NEXT step (that is what "keep the run going" means here:
  the same loop, one round later).
* **The bound.* `M.MAX_REPEATS = 3` per run, and a run is one turn. The counter is never handed back
  inside a run: the first version reset it on every non-fabricated round, and a model that alternates a
  fabricated block with a step that only re-drives the loop then never reached the bound - 565 model calls
  before I found it (measured while testing this very row). At the third the turn fails BY NAME -
  `fake_tool_result: the model imitated a tool result instead of calling one 3 times in a row; no fabricated
  output was recorded as the answer, and the turn is failed rather than finished` - and `run_failure`
  classifies it as `fake_tool_result` (retryable), never as "answered".
* **Narrow on purpose.** Fenced code blocks and inline code spans are removed before the scan (documenting or
  quoting the markup is not imitating it), and an element counts only where it starts its own line (or where a
  `<name>...</name>` is answered by an `<output>`), so a sentence that merely mentions a tag stays prose. The
  tags counted: `result`, `output`, `tool_call`, `tool_calls`, `tool_result`, `function_call`,
  `function_results`, `invoke`.

### The three shapes from that session

The mission quotes the measured shape as `<result>\n<name>bash</name>\n<output>...`. **The session's own rows
were not reachable from this machine**: `100c54ab` is in no session table on avell or on the peers I can read
(work, openclaw, mail, nextcloud), so the exact three messages cannot be quoted. The row therefore pins the
quoted shape plus its two nearest siblings, as the three shapes, and each is a fixture in
`scripts/test-answer-not-fake-tool-result.lua` for Victor to compare against the session:

```
1. <result>
   <name>bash</name>
   <output>
   $ ls -la
   README.md
   </output>
   </result>

2. <name>bash</name>
   <output>{"ok":true,"code":0,"stdout":"done"}</output>

3. <tool_call>
   {"name":"bash","arguments":{"command":"ls"}}
   </tool_call>
```

### before / after (row scripts/test-answer-not-fake-tool-result.lua)

before (base lua/rust + installed wa) - the fabricated block IS the recorded answer:

```
README.md
</output>
</result>
--- rc=1
```

after (this tree):

```
ok answer-not-fake-tool-result: 31 checks
--- rc=0
```

What the row checks: the three shapes are detected and strip to nothing; an ordinary answer, a fenced
quotation and a prose mention are not detected; a fabricated step followed by a real answer still finishes the
turn (the answer is the model's next step, the fake row is stripped, the notice is in the ledger, the status
line is in the run, the run ends with a real answer row and no fabricated markup); three in a row fails by
name, the bound is the repeat count, the failure row names `fake_tool_result` and contains no markup, and the
failure layer classifies it as `fake_tool_result`.

**Not verified:** that the notice text makes a real model take the next step instead of repeating itself - that
needs a live session, which this mission does not spend.

## 2. A script is never killed for waiting

The measured cause: the sandbox was created with a wall-clock deadline (`timeout_ms`, 30 000 ms by default in
both loops) and that deadline kept running while the script was *waiting* in the host. A call that takes longer
than what is left of the clock ended the script, and the 30 000 ms default meant a script could not make three
20 s calls in a row at all.

* `rust/wa-capabilities/src/quickjs.rs` - the budget is now a COMPUTING budget. `deadline` is an
  `Option<Instant>`; `pause()` records when the guest handed control back to the host, `resume()` gives that
  host time back. The clock stops at `admit` (the host is about to dispatch the call) and at the end of
  `deliver` / `start`, and starts again at `admit` / `deliver`. With no `timeout_ms` there is no deadline at
  all, and the only hard stop is wasmtime's fuel (the CPU/instruction guard), which answers `while(true){}` in
  about **1.06 s** (measured on this node, with no budget asked for).
* `lua/core/codemode.lua` - neither loop passes a default `timeout_ms` any more (`or 30000` is gone from the
  native spec and the component request); the script's wall clock no longer clamps a wait (`popts.remaining` is
  not set: clamping `wait_s` by "what is left" turned a legitimate 5 s wait into an immediate
  `{state:"pending"}` - the same bug one layer down, caught by the row's last block); `explain` no longer
  says "pass timeout_ms (up to 300000)" and no longer invents a 30 s budget in the CPU-stop sentence;
  `M.run` stamps `ctx.codemode_deadline` only when a budget was actually asked for.
* `lua/core/codemode_pending.lua` - the module's own doc says it: a wait is bounded by its own `wait_s`
  (default 60, ceiling 300) and by the CPU guard, and by nothing else. `M.effective_ms(wait_s, remaining_ms)`
  still honours a `remaining_ms` a caller passes; the loop passes none.
* Item 1.6's safeguard, in `rust/wa-operation`:
  * **a cap that QUEUES**: past `MAX_ACTIVE` (8) running operations a new one is admitted (its receipt exists
    immediately) and its supervisor waits in `Slot::acquire` - recording `state:"queued"`, `queued_because:
    "operation_capacity"`, `queue_depth`, `queue_limit` and, once it starts, `queued_ms` - instead of returning
    `operation_capacity` and throwing the caller's work away. The queue wait is added back to the operation's
    own deadline (`deadline_ms += queued_ms`) so a queued command is not already half-expired when it starts.
    Only a cancel or a queue wait longer than the operation's own deadline ends one, each by name
    (`cancelled` / `operation_queue_timeout`).
  * **low CPU priority**: every operation's command runs one step below the node (`nice +10`;
    `WASM_AGENT_OPERATION_NICE` overrides it, `0` keeps the inherited priority), recorded on the operation as
    `cpu_priority`. On Windows the child is created with `BELOW_NORMAL_PRIORITY_CLASS`.

### before / after (row scripts/test-codemode-never-killed.lua)

before (base lua/rust + installed wa) - a script that waits ran for 28 s and then reported the calls as still
pending, because the 30 s clock had eaten its waits:

```
lua error: [string "scripts/test-codemode-never-killed.lua"]:23: it ran for 28 s - past the old 30 s default it would have died at
--- rc=1
```

after (this tree):

```
{"checks":19,"elapsed_s":71,"ok":true}
--- rc=0
```

What the row checks: two 15 s calls come back as their own RESULTS; a 70 s call answers a HANDLE
(`{state:"pending", op}`) instead of blocking the script; `wait(op)` resumes it to its real output 70 s after it
started; the script ran 71 s and never saw a TimeoutError; `while(true){}` with no budget is still stopped,
named as a CPU stop, without an invented 30 s and without the "pass timeout_ms" hint, in under 25 s; and a
caller that asks for 400 ms of COMPUTING still waits five seconds on a call (waiting is not computing).

### before / after (row scripts/test-operation-queue-priority.lua)

after (this tree): `{"checks":29,"ok":true}` - eight operations fill the node, a ninth is admitted and recorded
`queued` with `queued_because: "operation_capacity"` and `queue_limit: 8`, then runs when a slot frees, exits 0,
carries its own `queued_ms` and its own 60 s timeout, and every operation records `cpu_priority = "nice+10"`.
No row pins the `operation_capacity` refusal on the base (none ever did), so there is no "before" line for
this one: the refusal is what `Slot::acquire` replaced.

**Not delivered / named limits:**
* The mission's fixture says "two 15 s **remote** calls". A hermetic row has no peers, so the two 15 s calls
  are local operations (`bash sleep 15`): they exercise the same wait path (a call that finishes inside its
  wait, started concurrently, then a call that outlives its wait). A peer call is dispatched through the same
  `pending_calls` executor path, so the removal of the wall clock covers it, but the *remote* variant was not
  measured.
* Windows: `BELOW_NORMAL_PRIORITY_CLASS` and the Windows `Process::priority()` compile only on Windows and were
  not built or tested on this Linux node.
* The CPU guard is 500 M fuel (unchanged), which is about a second of computation. That is now the ONLY limit
  on a script's compute, exactly as it already was the binding one before (a heavy script hit the fuel long
  before its 30 s clock), but it is worth knowing: a script that legitimately computes for minutes is not
  possible, by design, and the sentence says so ("an endless loop, or too much work for one script").

## 3. A provider stall is replayed, with a wait, a bound, a count - and a deadline that fits the request

* `lua/core/provider.lua`:
  * `M.first_response_seconds(context_tokens)` scales: base 90 s (or
    `WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS`; `0` still disables the per-call deadline, and a base under
    10 s is still raised to 10 s) **plus one second per 4000 tokens of context past 32 000, capped at 300 s**.
    The request carries it (`opts.context_tokens`) and the stalled fact names the deadline that expired.
  * `M.is_response_timeout` now matches every shape of "no response headers before the deadline": the
    transport's own words (`provider_error: timeout: receive response`) **and** the host's `provider_stalled`
    marker whatever words the edge used - the marker is added exactly when the per-call deadline expired, which
    is the case this replay exists for. A CONNECT timeout is excluded in both spellings (nothing was sent, so it
    stays in the patient connection bucket).
  * `M.response_timeout_backoff_ms(attempt)` - 2, 4, 8 s, jittered and capped. The replay used to leave
    immediately, hit the same dead gateway within milliseconds and read as if nothing had been retried.
* `lua/core/agent.lua` - the replay waits (_saying_ the wait: "provider did not start a response in time -
  retrying in 2s (1/1)"), counts it (`wait_ms` and the deadline in the telemetry event), honours cancel/steer
  while it waits, and a stall that survives its replays says so in the failure:
  `[first-response deadline expired again after 1 bounded replay(s) of the same request]`.
  The bound is still the operator's `WASM_AGENT_PROVIDER_RESPONSE_RETRIES` (documented default 1, `0` = the
  documented off-switch).

### before / after (row scripts/test-provider-stall-replay.lua)

before (base lua/rust + installed wa) - the deadline is one flat number:

```
lua error: [string "scripts/test-provider-stall-replay.lua"]:43: a large request gets more: 90
--- rc=1
```

after (this tree):

```
ok provider-stall-replay: 33 checks
--- rc=0
```

What the row checks: the deadline is the base at small sizes and grows with the request, never shrinks, is
capped, follows the operator's base and keeps `0` as "off"; the transport wording, the host marker alone (the
shape that used to end a turn with no replay at all) and the bare transport timeout all replay, while a connect
timeout, an HTTP answer and a body timeout do not; the backoff is 2 s then 4 s with jitter, capped; a turn that
stalls once answers after exactly one replay, having waited, with the retry and its wait in the run's status;
a gateway that never answers fails after exactly 1 + 2 attempts and the failure counts the replays; the two
documented off-switches still send exactly one request.

**Named limitation:** the row drives `provider.complete_with` (the layer above the transport), so it proves the
policy, the wait, the bound, the count and the deadline *carried to the transport*, not real silence on a
socket. The wording the predicate matches was read from the transport source (`ureq` 3.4:
`Timeout::RecvResponse` renders "receive response"), and the host's marker is added in
`stream_completion` for exactly that error, so the pairing is verified by construction, not by a live socket.

## Pre-existing failures, named

* **`scripts/test-provider-stall.lua` failed on the base on this node** - not because of this branch: this node's
  environment carries `WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS=300` (it is set for the operator's own
  sessions), so the row's first check read the operator's value instead of the 90 s default:

```
  before: lua error: ... test-provider-stall.lua:34: a provider call gets its own 90s first-response deadline: got "300", want "90"
```

  Since item 3 changes that very function, the row now defines the deadline it pins (the same one-line pattern
  the new row uses): the node's ambient tuning is not the row's subject. Nothing about the code was narrowed.
* Nothing else in the fast path failed on this branch; `rust` rows `wa-capabilities`, `wa-operation`,
  `wa-sentinel`, `wa-mesh` and the contract checks (`prompt-docs`, `instructions`, `fast-binary`,
  `direct-workflow`, `mcp-mail-repairs`) all passed.

## Model-facing text: proposed, NOT applied

Per the mission, no model-facing prompt text was changed. These are the exact changes Victor may want, with
the current text quoted verbatim:

1. **New harness notice** (`lua/core/fake_answer.lua`, `M.notice`) - the text a model receives after it fakes a
   tool result. It is new text, not a change of existing text, and it follows the shape of the stream-cut
   notice already in `agent.lua`:

```
   [Harness notice] Your last message contained <tags> markup you wrote yourself (<excerpt>). A tool result is
   produced by the harness, not written into a message: that markup was NOT an answer, it was removed, and no
   call was run from it. This is not a new user request. Take your next step: call the tool you were describing
   with tools.<name>(args) and wait for its real result.
```

2. **`M.WAIT_HELP`** (`lua/core/codemode_pending.lua`, what `searchTools("select:wait")` answers) says:

```
   ... wait_s defaults to 60, is capped at 300 and at the script's remaining time. ...
```

   Proposed replacement of that clause, since a script no longer has a wall clock for a wait to outlive:

```
   ... wait_s defaults to 60 and is capped at 300. ...
```

3. **The `codemode` schema** declares `timeout_ms={type='integer',minimum=1,maximum=300000}` with no description,
   so no prompt text was made stale there. If Victor wants it described:

```
   timeout_ms: how much COMPUTING time the script may use. Waiting on a tool does not count and is never a
   reason to kill it. Omit it for no budget; the CPU guard still stops an endless loop in about a second.
```

4. **The CPU-stop sentence** (`explain`) changed by this mission - a tool result, quoted before and after:

```
   before: TimeoutError: the script was stopped while computing - an endless loop, or too much work for its 300000 ms budget
   after:  TimeoutError: the script was stopped while computing - an endless loop, or too much work for one script
```
   and the dead hint:

```
   before fix line: Split the work across scripts, or pass timeout_ms (up to 300000) to codemode. ...
   after fix line:  Split the work across scripts: waiting on a tool is not charged to the script. ...
```

## Files touched

```
lua/core/fake_answer.lua        (new: the detector, the notice, the failure sentence)
lua/core/agent.lua              (item 1: the answer boundary; item 3: the replay's wait and count)
lua/core/run_failure.lua        (item 1: the fake_tool_result class)
lua/core/codemode.lua           (item 2: no default budget, no wait clamped by a wall clock, no hint)
lua/core/codemode_pending.lua   (item 2: the doc of what bounds a wait)
lua/core/provider.lua           (item 3: the scaled deadline, the predicate, the backoff)
rust/wa-capabilities/src/quickjs.rs  (item 2: the computing clock, pause/resume, no default deadline)
rust/wa-operation/src/lib.rs    (item 2.6: the cap that queues, cpu_priority on the record)
rust/wa-operation/src/process.rs     (item 2.6: nice +10 on unix)
rust/wa-operation/src/windows.rs     (item 2.6: BELOW_NORMAL_PRIORITY_CLASS; not built here)
scripts/test-answer-not-fake-tool-result.lua   (new row, 31 checks)
scripts/test-codemode-never-killed.lua         (new row, 19 checks, ~71 s)
scripts/test-operation-queue-priority.lua      (new row, 29 checks, ~15 s)
scripts/test-provider-stall-replay.lua         (new row, 33 checks)
scripts/test-provider-stall.lua                (one line: the row defines the deadline it pins)
```

## Results

```
row                                   before (base lua/rust + wa 2e6fab41)           after (this tree)
test-answer-not-fake-tool-result.lua  answer WAS the fabrication, rc=1               ok answer-not-fake-tool-result: 31 checks
test-codemode-never-killed.lua        ran 28 s, waits cut to pending, rc=1           {"checks":19,"elapsed_s":71,"ok":true}
test-provider-stall-replay.lua        a large request gets more: 90, rc=1            ok provider-stall-replay: 33 checks
test-operation-queue-priority.lua     (no base row: the refusal it replaced is gone) {"checks":29,"ok":true}
fast path (this tree)                 -                                              ok (267 checks, 0 skipped, 188s)
```
