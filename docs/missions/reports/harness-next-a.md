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

---

## Round 2 - the review's nine findings (18/11 17:20)

Base @ change/harness-next-a e8b5da87 (round 1). Branch @ change/harness-next-a + this round, nothing
pushed. Every row below ran in its own @mktemp -d@ home with @WASM_AGENT_LUA_ROOT@ pointing at the tree
under test, no vault, no relay, no rendezvous, provider replaced before any model call (no paid
inference). The "before" column is the SAME row run against a clean worktree of e8b5da87
(@git worktree add /tmp/base-wt e8b5da87@) with a release binary built from it (@/tmp/wa-base@), so
both sides measure the code, not the harness.

### The nine findings, each with the row that proves it

| # | finding | row | before (e8b5da87) | after (this tree) |
|---|---------|-----|-------------------|-------------------|
| 1 | fake_answer cuts from the code-stripped copy | @scripts/test-fake-answer-original-span.lua@ (19 checks) | @lua error: ...:14: an unterminated fence is still code: A fixture, unterminated:@ then the message ends inside the code fence | @ok fake-answer-original-span: 19 checks@ |
| 2 | @self.fake_answer_repeats@ never reset | @scripts/test-fake-answer-repeat-reset.lua@ (13 checks) | @lua error: ...:29: three imitations with a real tool call between them are not three in a row: fake_tool_result: the model imitated a tool result instead of calling one 3 times in a row@ | @ok fake-answer-repeat-reset: 13 checks@ |
| 3 | the removed markup is dropped | @scripts/test-fake-answer-evidence.lua@ (13 checks) | @lua error: ...:19: the row carries the fake_tool_result trace entry@ | @ok fake-answer-evidence: 13 checks@ |
| 4 | ledger order inverted (notice before the message) | @scripts/test-fake-answer-ledger-order.lua@ (8 checks) | @lua error: ...:18: the stripped message comes BEFORE the notice it provoked (message at 3, notice at 2)@ | @ok fake-answer-ledger-order: 8 checks@ |
| 5 | the stall marker is added to every send() error | @scripts/test-provider-stall-marker.lua@ (6 checks) + rust @only_a_response_header_timeout_is_a_stall@ | @{"error":"io: Connection refused (provider_stalled: no response within 2s)"}@ | @ok provider-stall-marker: 6 checks@ |
| 6 | the queue can lose work / the registry is unbounded | @scripts/test-codemode-queue-timeout.lua@ (19 checks) + rust @a_settled_operation_is_retired_at_the_next_admission@, @the_registry_ceiling_refuses_by_name_and_creates_nothing@ | @lua error: ...:21: the record says the QUEUE is what ran out, not the command: {"error":"operation_queue_timeout", ...}@ (no @queue_state@) | @ok codemode-queue-timeout: 19 checks@; @cargo test -p wa-operation@: 42 passed |
| 7 | @while(1) await wait(op)@ has no bound | @scripts/test-codemode-wait-bound.lua@ (13 checks) | @lua error: ...:23: a script that only re-waits on one op does not run forever: {"error":"nil","ok":true,"value":"{\"answers\":60}"}@ | @ok codemode-wait-bound: 13 checks@ |
| 8 | stale model-facing text (WAIT_HELP, explain, the notice) | @scripts/test-model-facing-texts.lua@ (16 checks) | @lua error: ...:19: it no longer promises a bound the code does not have ("at the script remaining time")@ | @ok model-facing-texts: 16 checks@ |
| 9 | nice is applied to every operation | @scripts/test-operation-cpu-priority.lua@ (9 checks) | @lua error: ...:24: a call the run waits for keeps the node own priority: nice+10@ | @ok operation-cpu-priority: 9 checks@ |

The exact "before" lines, as the rows printed them (paths shortened to the row name):

@
[base] test-fake-answer-original-span.lua   rc=1  lua error: [string "/tmp/base-wt/scripts/test-fake-answer-original-span.lua"]:14: an unterminated fence is still code: A fixture, unterminated:
```xml
[base] test-fake-answer-repeat-reset.lua    rc=1  lua error: ...:29: three imitations with a real tool call between them are not three in a row: fake_tool_result: the model imitated a tool result instead of calling one 3 times in a row; no fabricated output was recorded as the answer, and the turn is failed rather than finished
[base] test-fake-answer-evidence.lua       rc=1  lua error: ...:19: the row carries the fake_tool_result trace entry
[base] test-fake-answer-ledger-order.lua   rc=1  lua error: ...:18: the stripped message comes BEFORE the notice it provoked (message at 3, notice at 2)
[base] test-codemode-wait-bound.lua        rc=1  lua error: ...:23: a script that only re-waits on one op does not run forever: {"error":"nil","ok":true,"value":"{"answers":60}"}
[base] test-codemode-queue-timeout.lua     rc=1  lua error: ...:21: the record says the QUEUE is what ran out, not the command: {"cleanup":"unknown",...,"error":"operation_queue_timeout","fix":"clear the condition `operation_queue_timeout` ...}
[base] test-operation-cpu-priority.lua     rc=1  lua error: ...:24: a call the run waits for keeps the node own priority: nice+10
[base] test-model-facing-texts.lua         rc=1  lua error: ...:19: it no longer promises a bound the code does not have ("at the script remaining time"): Resume one pending call, or a batch of up to 20, ...
[base] test-provider-stall-marker.lua      rc=1  lua error: ...:14: a refused connection is NOT a stall: {"error":"io: Connection refused (provider_stalled: no response within 2s)"}
@

### What changed, per finding

1. **@lua/core/fake_answer.lua@** - code is now MASKED IN PLACE (closed fences, an unterminated fence to
   the end, inline spans, four-space/tab indented blocks): only the visible bytes become spaces, every
   newline stays, so a span found in the masked copy is a span of the ORIGINAL. @M.scan@ finds every
   element on the masked copy and cuts those spans **from the original**, so the model's own code and
   the rest of its message survive the cut. Markup inside code is never fake.
2. **@lua/core/agent.lua@** - @self.fake_answer_repeats = 0@ at the start of @run_body@ (a run is one
   turn), and again after every call that actually reached the dispatcher (@dispatched@ is set where the
   call enters @tools.dispatch@, or where a launched parallel batch is collected - a call the harness
   refused before dispatch does not reset it).
3. **the evidence** - @M.scan@ returns @removed@ (the markup verbatim) and @removed_blocks@. The step's
   trace entry carries @removed@, @removed_bytes@ and @tool@; the row for that step now stores its
   trace (@messages.trace@ and the journal row), and @harness_events@ carries the same fields. Nothing
   about the fabrication is only in a status line any more.
4. **ledger order** - the notice is staged and written AFTER the stripped assistant row it is about, so
   the ledger reads message-then-notice, the order they happened in.
5. **@rust/wa-capabilities/src/host.rs@** - @stall_marker(&error, first_response_seconds)@ marks exactly
   @ureq::Error::Timeout(ureq::Timeout::RecvResponse)@ (nothing of the response arrived before the
   deadline, so no tool call can have come back and the replay is safe) and nothing else: a refused
   connection, a TLS failure, an unresolvable host, a connect/send/body timeout keep their own words and
   are not replayed as stalls. Unit test: @only_a_response_header_timeout_is_a_stall@.
6. **@rust/wa-operation/src/lib.rs@** - every admission retires settled entries whose state was persisted
   (the registry tracks work, not history) and past @MAX_TRACKED@ (128) unsettled operations the answer
   is @operation_registry_full@ BEFORE anything is created. A queued operation whose own deadline runs
   out settles @failed@ with @error: "operation_queue_timeout"@ plus @queue_state: "timed_out"@,
   @queue_waited_ms@ and a @queue_note@, so "it never started" is on the record; the script reads it
   through @wait(op)@ (@entry.reason == "operation_queue_timeout"@) and @pending.retained@ re-reads it.
7. **@lua/core/codemode_pending.lua@ + @lua/core/codemode.lua@** - a per-script count of pending ANSWERS
   per op (@M.PENDING_ANSWER_LIMIT@, 20; @WASM_AGENT_CODEMODE_WAIT_ANSWERS@ overrides it for a test).
   At the limit the script ends by name (@codemode_wait_never_settles@) and the sandbox is closed, so the
   slot comes back (six scripts in a row, six > the four slots, each end the same way in the row). The
   approved rule is untouched: no wall clock on waiting, the CPU guard is the only hard stop for
   computing, and the error says which bound it is. The handle is kept (@pending()@ still lists it,
   @cancel(op)@ still stops it).
8. **model-facing text** - @M.WAIT_HELP@ no longer promises the script's remaining time and names the
   never-settles bound; @explain@ names the new ending and says what to do, and its budget sentence says
   "of computing" instead of "wall-clock"; the notice names the tool the way THIS session can call it
   (@tool_ref@: @tools.x()@ in code mode, @tool_call(name="x")@ for an on-demand tool, the bare name for
   a declared one) or says "the tool you were describing" when it cannot tell - never @tools.<name>@.
9. **@rust/wa-operation@ + @lua/core/tools.lua@** - @Spec.background@ decides the priority: @false@ for a
   foreground shell (@host.exec@), @true@ for an explicit @operation start@; the code-mode pending layer
   sets it from the one thing knowable before the process exists, "does this caller wait at all"
   (@wait_s 0@ = backgrounded, any wait above 0 = the script is awaiting it). The record's
   @cpu_priority@ is @default@ or @nice+10@ accordingly. Windows (@BELOW_NORMAL_PRIORITY_CLASS@) compiles
   only on Windows and was not built here.

### Texts to approve

Every model-facing string this round adds or changes, verbatim. (1) and (2) are two of round 1's five
proposed strings; the finding forced a change in both, so old and new are shown.

**(1) @M.WAIT_HELP@ (the @wait@ builtin's help, what @searchTools("select:wait")@ answers) - changed.**

old: @... It dispatches nothing and never re-runs an effect, so it batches with anything. wait_s defaults to 60, is capped at 300 and at the script's remaining time. until:"any" stops waiting ...@

new: @... It dispatches nothing and never re-runs an effect, so it batches with anything. wait_s defaults to 60 and is capped at 300 (a script has no clock for a wait to outlive). A wait on one op that never settles ends the script by name (codemode_wait_never_settles, after 20 pending answers in one script) and the handle survives, so the next script resumes it. until:"any" stops waiting ...@

**(2) the harness notice (@fake_answer.notice@) - its last sentence changed.**

old: @Take your next step: call the tool you were describing with tools.<name>(args) and wait for its real result.@

new: @Take your next step: call <ref> and wait for its real result.@

where @<ref>@ is one of, from the session's own catalogue and the same rule the prompt uses
(@lua/core/agent.lua@, @tool_ref@):

@
`tools.bash()`          (code mode: the tool is in the catalogue)
tool_call(name="bash")   (an on-demand tool)
`bash`                   (a tool this request declares)
the tool you were describing   (the markup named no tool we can place, or one this session cannot call)
@

**(3) NEW: the named ending of a script that waits on one op that never settles** (@codemode_pending.lua@;
it reaches the model as the script's error, @code = "codemode_wait_never_settles"@):

@
codemode_wait_never_settles: op <op> (<tool>) answered pending <n> times in this script without settling; the call itself is still running and its handle is kept. This is not a CPU stop and not a wall-clock limit on waiting: it is the bound on ONE op that never settles. Take the handle to a new step (pending() lists it, wait(op) resumes it there) or stop it with cancel(<op>).
@

**(4) NEW: @explain@'s fix for that ending** (@lua/core/codemode.lua@):

@
The call is still running and its handle is not lost: pending() lists it and wait(op) resumes it in a new script, or cancel(op) stops it. Nothing was undone. Already done, not undone: <names>. | No call had succeeded yet.
@

**(5) CHANGED: @explain@'s budget sentence** (a tool result, not a prompt: the deadline a script is given
now bounds COMPUTING only):

old: @TimeoutError: the script ran past the 3000 ms budget it was given (or the run was stopped)@ /
@TimeoutError: the script ran past the wall-clock budget it was given (or the run was stopped)@

new: @TimeoutError: the script ran past the 3000 ms of computing it was given (or the run was stopped)@ /
@TimeoutError: the script ran past the budget it was given (or the run was stopped)@

**(6) NEW: two refusal names and one record field a model can read** - @operation_registry_full@ (the
@operation start@ refusal past 128 tracked operations, with no operation created) and, on a queued
operation that ran out of time, @queue_state: "timed_out"@, @queue_waited_ms@ and:

@
this operation was admitted and queued for a free slot for <n> ms; its own deadline ran out first, so it never started
@

Nothing else model-facing changed: no prompt layer, no tool schema, no description of another tool.

### One row from round 1 changed, and why

@scripts/test-answer-not-fake-tool-result.lua@ (round 1's row) cycled through its three imitation
shapes in the streak block, i.e. it depended on "nothing between two imitations ends the streak". Finding
2 says the opposite - a real tool call DOES end it - and one of those three shapes (the @<tool_call>@ one)
is turned into a real @codemode@ call by the raw-code channel, so with the reset in place that block
looped until the fast-path timeout (measured: exit 124, twice). The block now repeats ONE shape, which is
what "a model that only imitates" means, and the two halves of finding 2 (reset at run start, reset after
a real tool call) are pinned in @scripts/test-fake-answer-repeat-reset.lua@. Every other check in the
row is unchanged, and it still passes in both envelopes (code mode and raw-code-only), 31 checks.

### The envelope matters, and one row reads it

The fast path runs rows with @WASM_AGENT_RAW_CODE@ unset, which is raw-code @only@ mode: the request
declares no tools at all, so "call tools.bash()" would be a door that is not there. The notice says "the
tool you were describing" there and @tools.bash()@ in code mode; @scripts/test-model-facing-texts.lua@
reads the session's own tool list and checks that whatever the notice offers is offered only because this
session can use it (and that @tools.<name>@ is gone in both), instead of pinning one envelope's spelling.

### Files touched

@
lua/core/fake_answer.lua              (1: mask in place, cut from the original, removed/removed_blocks, tool; 3, 8: ref)
lua/core/agent.lua                    (2: the two resets; 3: trace/event evidence; 4: notice after the row; 8: tool_ref)
lua/core/codemode_pending.lua         (7: the never-settles bound; 9: the background fact; 8: WAIT_HELP)
lua/core/codemode.lua                 (7, 8: explain() names the bound and says "of computing")
lua/core/tools.lua                    (9: background on the operation start the pending layer asks for)
rust/wa-capabilities/src/host.rs      (5: stall_marker + its unit test)
rust/wa-capabilities/src/operations.rs (9: Spec.background threading; foreground is not background)
rust/wa-operation/src/lib.rs          (6: registry ceiling, queue facts, tracked_limit; 9: cpu_priority(background))
rust/wa-operation/src/process.rs      (9: nice only for a backgrounded command; priority(background))
rust/wa-operation/src/windows.rs      (9: BELOW_NORMAL_PRIORITY_CLASS only for a backgrounded command)
rust/wa-operation/src/tests.rs        (6: retirement + ceiling tests)
scripts/test-fake-answer-original-span.lua, -repeat-reset.lua, -evidence.lua, -ledger-order.lua   (1, 2, 3, 4)
scripts/test-provider-stall-marker.lua       (5)
scripts/test-codemode-queue-timeout.lua      (6)
scripts/test-codemode-wait-bound.lua         (7)
scripts/test-model-facing-texts.lua          (8)
scripts/test-operation-cpu-priority.lua      (9)
scripts/test-answer-not-fake-tool-result.lua (the streak fixture, see "One row from round 1 changed")
@

### Fast suite: green

@CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-harness-next-a WA_BIN=<this tree's release wa> bash scripts/fast.sh --jobs 6@

@
fast: lua 240/240 passed (56 excluded: scripts/fast-path.exclude)
fast: rust wa-capabilities ok (9s)
fast: rust wa-operation ok (2s)
fast: fast result ok (274 checks, 0 failed, 0 skipped, 180s)
@

(274 checks, up from round 1's 267: this round's nine rows and their assertions. The fast path runs rows
with @WASM_AGENT_RAW_CODE@ unset, i.e. raw-code @only@ mode - the envelope the two "envelope" notes above
are about.)

Rust, run directly: @cargo test --release -p wa-capabilities@ -> 288 passed, 0 failed;
@cargo test --release -p wa-operation@ -> 42 passed, 0 failed (both include this round's new tests).

### Pre-existing failure on this node, named

@scripts/test-provider-stall.lua@ fails when run on the BASE tree on this node, not because of this
branch: an interactive shell here carries @WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS=300@, so the BASE
row's first check reads 300 where it expects the 90 s default. Round 1 changed that row to clear the
variable for the check it pins, so this tree's row passes (@ok provider-stall: 17 checks@, run here with
the variable still set) and the fast path is green. Nothing in this round touches it.

### Costs and limits, named

* The two @wa-operation@ tests are new source that cannot compile against e8b5da87 (neither @MAX_TRACKED@
  nor @Manager::with_tracked_limit@ nor the retirement nor the queue facts exist there), so their
  "before" is quoted from that tree's own source instead of run: @if entries.len() >= 128 { retain(settled) }@ with no ceiling and no refusal,
  and @return Err(error("operation_queue_timeout"))@ with no queue facts on the record. The lua row above
  measures the same two facts from outside, against the real base binary, and fails there.
* The ceiling test uses a per-manager ceiling (@Manager::with_tracked_limit@, a test/diagnostic seam, not
  an operator knob) so it can reach the refusal with 2 operations: filling all 128 live ones would take
  every CPU slot the test process has and made a pre-existing row
  (@parallel_launches_do_not_inherit_each_others_pipes@) wait behind them - measured once, then fixed and
  re-run green.
* Finding 9's Windows half (@BELOW_NORMAL_PRIORITY_CLASS@ only for a backgrounded command) compiles only
  on Windows and was not built or tested on this Linux node.
* @scripts/test-codemode-wait-bound.lua@ runs six sandboxes in sequence to prove the slot comes back; it
  is fast (each script ends after the 20th pending answer, which is immediate for a @wait_s:0@ loop) but
  it does start and stop six guests.
* The stall marker's positive case (a receive-response timeout on a real socket) is not in the row: the
  row pins the negative case live (connection refused, no marker) and the positive one at the predicate
  and unit-test level. Nothing here opens a second listener.
* A model-facing sentence that only a live model can judge (does the notice make it call the tool?) is
  not verifiable in a hermetic row, same as round 1.

---

## Round 3 - the review of 18/11 21:40 (items 1-6)

Base: origin/main `e5ba9089`, rebased FIRST (the branch's two commits rewritten onto it). Nothing
pushed. Every row below ran on this node (avell, x86_64, 16 cores) in its own scratch HOME with
`WASM_AGENT_LUA_ROOT` pointing at the tree under test, no vault, no relay, no rendezvous, and the
provider replaced before any paid call.

### 1. The report lives in docs/missions/reports, and there is no root REPORT.md

The root `REPORT.md` carried round 2's text and nothing else did. Its content is now the "Round 2"
section of THIS file (the rounds in the order they were measured, the shape harness-land.md already
uses), the root file is deleted, and the deletion rides in the rebased commit - so the branch neither
adds a root report nor leaves one behind. origin/main's own root `REPORT.md` (land-gate-fix) was
byte-identical to `docs/missions/reports/land-gate-fix.md`, which is why deleting it loses nothing.

### 2. The wait bound counts waits that spent their whole budget WITH NO PROGRESS

The first cut counted every pending ANSWER for an op (limit 20). That is a wall clock under another
name, and it failed in three measured ways: a `wait_s:0` poll loop hit 20 at once, a long build
awaited with `wait_s:60` died at about 20 minutes, and the `until:"any"` pool loop added one to the
long op every time a SHORT op finished. The rule now (lua/core/codemode_pending.lua):

| what the wait did | counts? |
| --- | --- |
| poll (`wait_s:0`), or a wait cut short because a short op of the same batch settled | no - it spent none of the budget the bound is about |
| spent its whole budget (>= `M.FULL_WAIT_MS`, 30 s) and the op's progress fields did not change | **one** |
| spent its whole budget and the bytes / counters / state DID change | no - any progress resets the count to zero |

The fingerprint is over `output_bytes`, `bytes`, `progress`, `promoted`, `shell_exited` and `state`
only: the clock fields the same answer carries (`elapsed_ms`, `remaining_ms`, `output_idle_ms`) are
deliberately absent, or the passing of time would read as progress. The failure text says what it
counts and that a wait with progress never counts; `WAIT_HELP` says the same to the model.

The row is `scripts/test-codemode-wait-bound.lua` (29 checks), rewritten around the three cases the
review named, plus the poll case:

    sixty polls of one op do not end anything
    a silent op re-waited for its whole budget ends the script by name codemode_wait_never_settles,
      says "without progress", "not a CPU stop", "not a wall-clock", names the op and the cancel(id)
    a long op with steady progress awaited 40 times survives (the row saw the bytes it survived by)
    the pool loop with 25 short ops finishing does not kill the long one, still pending afterwards
    in a real sandbox: 60 polls of one handle, and a 25-op pool, neither end the script

How the numbers stay fast, and what that does NOT measure: the row shrinks the two numbers the code
reads (whole-budget threshold, count) on its own copy of the module, and every wait goes through that
copy's `M.wait` - the code under test. The production numbers (30 000 ms, 20) are asserted as
constants in the same row instead of being waited out; a row that measured 20 x 30 s of deliberate
silence would cost ten minutes and prove nothing more about the rule.

### 3. A connect timeout is not a stall

lua/core/run_failure.lua mapped `timeout: connect` / `connect: timeout` onto `provider_stalled`
(retryable). Nothing was sent in that case and no answer was awaited, so it is not a stall: it now has
its own class, `provider_unreachable` ("the provider could not be reached: the connection never
opened"), which also takes "connection refused", "failed to lookup address", "dns error", "network is
unreachable" and "no route to host". Still retryable - the network may come back in a second - but a
different next step for the reader: the node's route, endpoint and account, not the model's patience.
`provider_stalled` keeps exactly `provider_stalled` and `timeout: receive response`.
Row: `scripts/test-no-silent-stops.lua` (84 checks), which now asserts both spellings of the connect
timeout, a refused connection and an unresolvable name are `provider_unreachable`, never a stall.

### 4. Indented-code masking: one tab, and the first line

lua/core/fake_answer.lua masked an indented block only after a newline and only for four spaces, so a
block indented with ONE TAB and a block that was the FIRST line of the message were both read as the
model imitating a tool result - and the model's own fixture was cut for it. The mask is now applied to
every line, line 1 included, and a single tab counts as an indent (one tab stop). Row:
`scripts/test-fake-answer-original-span.lua` (24 checks): the tab block, the first-line block in both
spellings, and the two controls - two spaces are not an indent, and a bare imitation at byte 0 is
still fake.

### 5. The CPU priority is lowered when the call GOES PENDING, not from the wait_s it named

Round 2 decided the priority at spawn from `wait_s == 0` - a guess about the future, and wrong for a
`wait_s:0` call the script resumes at once. The guess is gone: a code-mode call now always starts at
the node's own priority, and the priority is lowered at the one boundary where "nobody is waiting" is a
fact - the end of the script that left the handle behind (`M.background(scope, dispatch)`, called from
lua/core/codemode.lua's `finish`). The lowering itself is a new operation action,
`operation background` (rust/wa-operation, `Manager::background`), which re-nices the running
operation's whole process group on unix (`setpriority(PRIO_PGRP)`) and sets below-normal on Windows;
it is best effort and says so (`cpu_priority_error`), and a call that goes pending before its child
exists is lowered by the flag the spawn site reads. `Spec.background` stays for an explicit
`operation start`, which is backgrounded by definition.
Rows: `scripts/test-operation-cpu-priority.lua` (18 checks - the priority is still `default` while a
script can still wait, `M.background` lowers it, a real script reports `pending_backgrounded` and the
operation's own record names the lower priority, and a call resumed and finished inside the script is
never lowered) and rust `background_lowers_a_running_operation_and_names_the_priority_it_runs_at`.

### 6. The telemetry "removed" field is bounded; a settle that could not be written is retired after it is reported

* `removed` - the markup the model wrote, kept verbatim as the evidence - is now bounded at
  `fake_answer.EVIDENCE_BYTES` = 2000 bytes, and what is dropped is COUNTED, not silently lost: the
  trace entry and the event carry `removed_bytes` (the whole markup's size) and
  `removed_dropped_bytes`, so kept + dropped is the whole fabrication. Row:
  `scripts/test-fake-answer-evidence.lua` (20 checks) with a 12 KB fabrication, plus the small case
  that drops nothing.
* A settle whose own record could not be written (`persistence_error`) was the one entry the registry
  never retired - a registry slot lost for ever the first time a disk write failed. It is now kept
  exactly until a caller has read it (`snapshot` marks `persistence_error_reported` on the entry) and
  retired at the next admission after that. Row: rust
  `a_settle_that_could_not_be_written_is_reported_once_then_retired`, which makes the operation's own
  directory read-only between admission and settle, so the failure is the real one and not a stub.

### Texts to approve (verbatim, as they now read)

1. `WAIT_HELP.description` (lua/core/codemode_pending.lua), the sentence that changed:

       A wait on one op that never settles ends the script by name (codemode_wait_never_settles)
       after 20 waits that each spent their whole budget - 30 s or more - WITHOUT PROGRESS: no change
       in that op's output, counters or state. A shorter poll does not count, and any progress resets
       the count. The handle survives, so the next script resumes it.

2. The bound's failure sentence (what the script and the model see when it ends):

       codemode_wait_never_settles: op <id> (<tool>) was waited on 20 times in this script for its
       whole budget without progress: no output, no counter, no state change. The call itself is
       still running and its handle is kept. This is not a CPU stop and not a wall-clock limit on
       waiting, and a wait that saw any progress does not count: it is the bound on ONE op that never
       settles and never moves. Take the handle to a new step (pending() lists it, wait(op) resumes it
       there) or stop it with cancel(<id>).

3. The failure class's sentence (lua/core/run_failure.lua):

       run_failed: provider_unreachable - the provider could not be reached: the connection never
       opened: <the transport's own words>

4. The operation tool's new action, as the model sees it (lua/core/tools.lua): the enum gains
   `"background"`, described as

       background only lowers a running operation's CPU priority once nobody is waiting for it; code
       mode does that by itself when a call goes pending.

5. A codemode result that lowered handles carries one new key, `pending_backgrounded`:
   `{count, ops:[...], failed?:[...]}` - the calls this script stopped waiting for that now run one
   step below the node.

### The fast path, after all of it

    fast: lua 240/240 passed (56 excluded: scripts/fast-path.exclude)
    fast: rust wa-capabilities ok (9s)
    fast: rust wa-operation ok (4s)           (cargo test -p wa-operation: 44 passed, 1 ignored)
    fast result ok (274 checks, 0 failed, 0 skipped)
    fast path ok (274 checks, 0 skipped, 162s)

That run measured commit d95c8ba2. This section was written after it: the commit that carries these
numbers differs from the measured tree ONLY in this file.

Five runs are worth naming rather than hiding, because four of them were mine:

* run 1 red on the RELEASE timing row `deadline_covers_both_streams_without_serial_graces` (its own
  1400 ms bound) while 240 Lua rows ran beside it. It passes alone 3/3 on this tree, and the whole
  `cargo test -p wa-operation` suite passes on the BASE (stashed tree, twice) and on this tree
  (twice), so it is a pre-existing load-sensitive row and not this round's; its own comment already
  records the same measurement under the release gate's uncapped test threads.
* run 2 red on my own new rust row `a_settle_that_could_not_be_written_is_reported_once_then_retired`,
  which raced its own fixture: the window between admission and settle was a `sleep 1`, and the cleanup
  ran while the second operation was still writing. Fixed, not retried: the command now WAITS for a
  file the test creates (so the window stays open for as long as the machine needs and closes exactly
  when the directory is read-only), and the second operation is waited out before the fixture is
  removed. 6/6 green, 0.09 s each.
* run 3 red on my own Lua row `test-operation-cpu-priority.lua`, which assumed a `wait_s:0` call always
  answers a handle. A call that settles inside the start answers its RESULT instead - the script waited
  for it from beginning to end - and the row now reads both shapes.
* run 5 red on the same row again: its "nothing was lowered for it" assertion was reading a handle the
  row's PREVIOUS script had left open (the row cancelled it through the operation tool, which stops the
  work but does not close the pending handle - so the next script's sweep lowered it, correctly). The
  row now cancels from inside a script and asserts on its own op. 5/5 green, and green in run 6.
