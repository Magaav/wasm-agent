# remote-pending - a remote call is never killed for waiting

Mission `change/remote-pending`, branch `change/remote-pending`, worktree
`/home/victor/Work/missions/remote-pending/wt`, based on `ac7717e0` (origin/main). Built and tested HERE
on avell (x86_64, 16 cores) with `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-remote-pending`;
committed locally, **never pushed**.

Rule 5 says reports live here, not in the repository root; this file follows rule 5 and not the brief's
last line ("Write REPORT.md in the worktree root"), because the two contradict each other and rule 5 is
the one stated as a quality rule. Say so if the other was meant.

## What each item is, what the code does, and which commit implements it

### Item 1 - a remote call past the relay's hold is ADOPTED, not killed

**Measured first** (rule 9), the kill chain as it stood:

* the relay stamps the caller's deadline and carries it to the node as `deadline_ms`
  (`rust/wa-rendezvous/src/rendezvous.rs:81, 700-716`);
* the node installs it as the run's own cancel flag:
  `install_relay_context(Some(job.cancel.clone()), job.deadline_ms, ...)`
  (`rust/wa-capabilities/src/serve.rs:2651`);
* the foreground `bash` path **cancels its own operation** when that flag flips
  (`rust/wa-capabilities/src/operations.rs:1163`) - the command died mid-run;
* `operation await`, by contrast, only *interrupts the wait* and says the work was not cancelled
  (`operations.rs:1537-1540`, `await_interrupted`, "the independently supervised operation was not
  canceled ... Do not rerun it");
* `operation start` is detached by construction (`operations.rs:1300`).

So the primitive for adoption already existed; what was missing was the peer *using* it for a relayed
`bash`, and the caller being able to resume it.

**Now** (`fc409e3c`):

* `lua/core/nodes.lua`: `M.RELAY_PEER_BUDGET_MS = 35000`, and `M.remote_call` copies `args` and adds
  `budget_ms` for `capability == "bash"` only. It travels **inside the signed body** (in `args`, which is
  what the peer hands its capability: `server.lua` `node_capability(capability, request.args, caller)`), so a
  peer adopts by the caller's own number and nothing on the path can raise it.
* `lua/core/server.lua`: `adopt_bash` starts `operation start` through `wa_peer_dispatch` (so the peer's
  own path guard, session and admission all run), watches it in 1 s `operation await` steps up to
  `budget - 4000`, answers the command's own result when it settled, and otherwise answers
  `{state:"pending", op, operation_id, node, tool, waited_s, adopted, note}`.
* `lua/core/codemode_pending.lua`: a `remote` executor (`M.EXECUTORS["remote"]`) whose `applies` is
  `capability == "bash"` with a node; `start` answers `{op, node}` from the peer's handle; `poll` is
  short relayed `operation await` slices (`REMOTE_SLICE_MS = 15000`), with a `status` read when there is no
  wait to spend (a `wait_s:0` poll must not issue a zero-length await); `cancel` routes `operation cancel`
  to the op's node; `record.node` and `handle().node` carry the node, and `pending()` rows list it.

**Test**: `scripts/test-remote-pending.lua` (36 checks) - the peer half is the real
`wa_peer_dispatch`/`operation` path on a scratch home, the caller half is the real pending executor over a
relay stand-in. It pins: adoption past the budget, the handle naming the node, the command settling on the
peer, a second look re-running nothing, a fast command answering its own result with no handle,
`cancel(op)` stopping an adopted op, `wait(op)` resuming through the executor and answering the real
output, and `cancel(op)` routing to the node.

### Item 2 - the relay never carries the long wait

The peer answers a handle inside the relay's hold (`RELAY_PEER_BUDGET_MS = 35000` against a 45 s
`SEND_WAIT` minus `ANSWER_MARGIN_MS = 3000`); every later wait is one short relayed `operation await`
(15 s slice), so no call depends on holding a connection open.

**Test**: the items 5/2 section of `scripts/test-remote-pending.lua` (`fe7177ba`) checks
`RELAY_PEER_BUDGET_MS < RELAY_DEADLINE_SECONDS * 1000` and that the caller half is a real executor
(`EXECUTORS["remote"].poll` is a function). The executor's own slice is 15 s; the peer-side *wait step* is
1 s.

### Item 3 - never a half-run; the relay-deadline note is replaced

Three outcomes only: pending (a handle), finished (a result), cancelled by name (`cancel(op)`), and a
resume never re-runs an effect. The note a model reads on a relay deadline no longer says only that the
call stopped waiting; it names the adoption, the handle shape and the two calls that route back.

**Commits**: `b95b899b` (`M.relay_deadline_note`, the `fix` field, `docs/CODEMODE.md`, and five new
checks in `scripts/test-remote-call-shape.lua`), plus the same text pinned in
`scripts/test-remote-pending.lua` because that other suite cannot run on this node (see below).

### Item 4 - tests

* `scripts/test-remote-pending.lua`, wired into `scripts/test.sh` beside the `test-remote-call-shape.lua`
  and `test-remote-refusals.lua` rows (`0c00e3a2`), running as
  `WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-remote-pending.lua" "$BIN" --db "$DB.remote-pending" | grep 'remote pending ok'`.
* It refuses to run outside a scratch `WASM_AGENT_HOME` (same guard, same words, as
  `scripts/test-session-isolation.lua`, including macOS's `/var/folders/`) and never touches the real
  `~/.wasm-agent`.
* Two scratch nodes in one process: the peer half is this node's own `wa_peer_dispatch` (the seam
  `scripts/test-session-isolation.lua:568` already reaches), the caller half the real pending executor, and
  a relay stand-in carries the two halves' answers. No fleet, no second machine.
* Exactly-once: the marker file holds exactly two `run` lines for the two adopted commands
  (`check(lines_of(marker) == 2, ...)`), which is the failure the relay bound used to cause.
* The two kinds item 1 does **not** adopt are pinned by name (`aa8e6d4f`): a `batch` is read-only on the
  wire (`REMOTE_READ` / `remote_read_refusal`), and a remote `operation await` past the bound is
  interrupted, never cancelled (`operations.rs:1537`), so the executor refuses both.

**What these tests do NOT prove, said plainly**: the real relay's stamped deadline
(`rust/wa-rendezvous`) and the peer's own cancel flag (`rust/wa-capabilities`) are not driven end to end -
the stand-in carries answers, it does not hold connections or flip a flag at a wall-clock bound. The
behaviour those two produce was *read* in the code (`serve.rs:2651`, `operations.rs:1163/1537`,
`rendezvous.rs:700-716`) and is the premise of the adoption, not an assertion of the suite.

### Item 5 - the adopted op belongs to the calling peer session

No new mechanism was needed: `wa_peer_dispatch` already derives `"peer:" .. caller.node_id` from the
verified caller (never from the request) and dispatches with it, so the operation is recorded under that
peer's session.

**Test** (`fe7177ba`): the peer sees its own adopted op in `operation list`; the local session and a second
peer do not; the local session cannot reach it by id; the peer that owns it can cancel it.

## Premises of the brief that were wrong (rule 9)

1. **"~45-60 s cap"** - two different numbers, and neither is a guess: the relay's own hold is
   `SEND_WAIT = 45 s` with `ANSWER_MARGIN_MS = 3 s` (`rendezvous.rs:32,47`, so the honest peer budget is
   42 s), while the *caller's* loop stops after `RELAY_DEADLINE_SECONDS = 60` in 3 attempts of ~20 s holds
   (`lua/core/nodes.lua:778-780`). `RELAY_PEER_BUDGET_MS = 35000` is derived from the 42 s figure and keeps
   ~7 s for the return trip and the signature.
2. **"the 1c relay-deadline note"** - there is no text labelled "1c" in `docs/CODEMODE.md`. What existed is
   the "The limitation, named" paragraph (a `remote`/peer call has **no** executor and cannot be resumed)
   plus `lua/core/nodes.lua` `M.relay_deadline_note` / the `fix` field. Those are what `b95b899b` replaces.
3. **A smaller one, recorded because it cost a cycle**: `/usr/bin/luac` on this node is Lua 5.5 and refuses
   the BASE file (`lua/core/nodes.lua:87: attempt to assign to const variable 'entry'`). Syntax is checked
   here with `luajit -bl` (the node runs LuaJIT 2.1), never `luac`.

## A pre-existing failure, named rather than claimed

`scripts/test-remote-call-shape.lua` **aborts on this node before its note section**:

    lua error: ... "the run declared no tool at all (63), so it ran on the CodeAct surface"

Reproduced on a **separate worktree at HEAD** (`git worktree add /tmp/rp/basewt HEAD`) with the same
binary, and the log line just before it is `selfloop: publish served natively: component_missing`. So it
is the selfloop component's absence on this machine, not this change; the checks `b95b899b` added there
therefore could not be executed here, which is why item 3's text is *also* pinned in
`scripts/test-remote-pending.lua` (section 6), which does run.

## What was run, and the result

All on this node, scratch `WASM_AGENT_HOME` each time, `WASM_AGENT_LUA_ROOT` = this worktree, binary
`/home/victor/wasm-agent/target/m-remote-pending/release/wa` (76 867 288 B, built with the prepared asset
directory, so the sandbox really runs):

* `scripts/test-remote-pending.lua` -> `remote pending ok (36 checks)`
* `scripts/test-codemode-pending.lua` (existing, unchanged) -> `codemode pending handles ok (92 checks; real sandbox)`
* `scripts/test-session-isolation.lua` (existing, unchanged) -> `141 checks, 0 failed` (two named skips: the
  canary env this runner does not export)
* `scripts/test-remote-call-shape.lua` -> pre-existing abort above, on base and on this branch
* a first build with `WA_CODEMODE_ALLOW_EMPTY=1` was **not** usable for the code-mode suite (the node
  answered "no embedded code-mode assets"), so the binary was rebuilt with
  `WA_CODEMODE_BUILD_ASSETS=/home/victor/wasm-agent/checkout/.git/codemode-build-w4tSRl/assets`. That
  directory is another worktree's prepared assets; the private target dir is never shipped.

Not run here: the full `scripts/test.sh` gate (it builds and runs the whole repository) and any Rust test
suite. `rust/` was read, not modified - every change is Lua, docs and one shell row.

## Texts to approve

Model- or operator-facing strings this change adds or changes, verbatim.

1. New, the peer's pending answer's note (`lua/core/server.lua`, `adopt_bash`, `fc409e3c`):
   `"the command outlived the relay hold and is still running on that node as operation " .. id .. "; wait(op) resumes it, cancel(op) stops it, and nothing was re-run"`
2. Changed, `M.relay_deadline_note` (`lua/core/nodes.lua`, `b95b899b`), the inserted sentences:
   `"A relayed bash that outlives that hold is ADOPTED, not killed: it answers {state:"pending", op, node} and stays running there as a managed operation, and wait(op) or cancel(op) route back to that node. This answer is the other case - the peer never took the call - so nothing here says the action did not run: read that node's state before re-issuing it."`
3. Changed, the `fix` field of a relay-deadline refusal (`lua/core/nodes.lua`, `b95b899b`), appended:
   `" A bash that outlives the hold is adopted on its own and answers {state:"pending", op, node}: resume it with wait(op) or stop it with cancel(op)."`
4. Changed, `docs/CODEMODE.md` (`b95b899b`): the paragraph now headed
   `**A remote call is never killed for waiting.**` and the limitation list, which now reads
   `Today that is `bash`, `operation`, the WhatsApp send and a relayed `bash`.`
5. New, the pending `remote` executor's progress rows (`lua/core/codemode_pending.lua`, `fc409e3c`) carry
   `{state, node, op, elapsed_ms, output_bytes, tail}` - field names a model reads, no prose.
6. New, the test's own refusal line (`scripts/test-remote-pending.lua`, `fc409e3c`), the same words the
   isolation suite uses: `"refusing to run: WASM_AGENT_HOME must be a scratch or temp directory, and never the node's own ~/.wasm-agent (got ...)"`
7. New, the `scripts/test.sh` row's comment and grep token (`0c00e3a2`): the gate prints
   `remote pending ok`.

## Commits

```
fc409e3c item 1   adoption + caller executor + test-remote-pending.lua
b95b899b item 3   the note, the fix, docs/CODEMODE.md, test-remote-call-shape.lua
fe7177ba item 5   peer-session ownership + item 2's numbers, pinned
0c00e3a2 item 4   the suite wired into scripts/test.sh
aa8e6d4f item 4   the two kinds not adopted, pinned by name
```
`git log -S` evidence: `RELAY_PEER_BUDGET_MS`, `adopt_bash` and `EXECUTORS["remote"]` -> `fc409e3c`;
`ADOPTED` -> `b95b899b`; `test-remote-pending` in `scripts/test.sh` -> `0c00e3a2`.

## Not done, still open

* The real relay's stamped deadline and the peer's cancel flag are not driven end to end (item 4 asked for
  "two scratch nodes in one test, no real fleet" - done - but the `rendezvous`/`install_relay_context` halves
  are read, not executed).
* No Rust test suite was run and no Rust file changed.
* `scripts/test.sh` as a whole was not run.



## Review r1 (independent) - what changed, and which commit

The review is `review-latest.md` (11 lines, MUST 1-3 plus five SHOULDs). Each premise was re-measured
before a line changed; the file:line in the review were correct.

### MUST 1 - cancel lied (fixed in `5ac7b171`)

Measured: the peer's cancel answer carries the operation id even for a refusal and for an already-settled
call, and the old line read `answer.cancelled ~= false`, so a refusal and a no-op both answered
`cancelled:true`. Now `lua/core/codemode_pending.lua` answers a stop only when the peer's own snapshot
says so: `answer.cancelled == true`, or a status read that shows `cancelled`/state `cancelled` within a
3 s observed window; `finished` is answered as `finished` (the result is retained, nothing was re-run);
anything else is `cancel_not_confirmed` with the state seen. Test: `scripts/test-remote-pending.lua`
section 9 - a confirmed stop is `cancelled:true`, the SAME handle cancelled twice is `cancelled:false`
with a reason, and an unknown id is never reported cancelled.

### MUST 2 - capacity (fixed in `4ed3163c`; one gap named below)

Measured: every peer call lands in ONE session (`peer:<node_id>`, `wa_peer_dispatch`), whose share is
`PER_SESSION_MAX = 6` of `MAX_ACTIVE = 8` (`rust/wa-operation/src/lib.rs:135,147`), so six adopted
commands held that whole share for up to 300 s each. Now `lua/core/server.lua` counts the caller's own
unsettled operations through the peer's own `operation list` (in the peer session that owns them, never a
local guess) and refuses past `MAX_ADOPTED_OPEN = 2` with `remote_adopted_limit` (naming `open` and
`limit`, `effect:"none"`); an unreadable list refuses by name (`remote_adopted_unknown`) rather than
adopting work it cannot account for. Test: section 10 - two adopted commands run, the third is refused by
name with nothing started, and the two are cancelled after.

**The second half - reaping - is now closed** (`d43437a1`), after measuring two things the first cut
got wrong:

1. A list row's `elapsed_ms` is the supervisor's LAST SNAPSHOT, not a clock: measured 29 ms for a command
   that had been running 1.2 s, so reaping on it would never fire. This node therefore records the start
   time IT observed, per peer session, in `<data>/remote-adopted/<peer session>.json`, and reaps on that.
   Only ids in that file can be reaped - work started by anything else in the peer session is not this
   rule's to stop.
2. The peer's `cancel` is a REQUEST: it sets the flag and answers a snapshot that still says `running`
   (rust/wa-operation, `pub fn cancel` -> `self.snapshot(id)`). So the reap OBSERVES the stop, bounded
   at 2 s, exactly as MUST 1 makes a caller's cancel observe it.

The ceiling is `MAX_ADOPTED_SECONDS = 900` whatever the caller asked for (up to 86400 s), and the pending
answer reports the number it was really given in `timeout_seconds` rather than the caller's. Both bounds
read from the environment (`WASM_AGENT_REMOTE_ADOPTED_SECONDS`, `..._GRACE_SECONDS`) the way
`M.full_wait_ms` does, so a test holds the rule in seconds; production reads the constants.

Tests (scripts/test-remote-pending.lua sections 10 and 11): two adopted commands run and the third is
refused by name with nothing started; a command under a 1 s ceiling settles BY ITSELF, so its slot returns
without anyone polling (measured: the supervisor's own deadline ends it); and a record of a command started
under the real 900 s ceiling, aged past a lowered ceiling, is reaped by name on the next adoption, with the
reaped id named in `reaped` on the answer. The test says in its own comment that the overdue-supervisor
case is made deterministic by ageing the record instead of pretended to have happened.

**One measured surprise worth recording**: `host.sleep` takes MILLISECONDS (rust/wa-capabilities, "Block
this interpreter for a bounded number of milliseconds"). The first cut of these tests called
`host.sleep(2.2)` and waited 2.2 ms, then reported the rule broken; the cancel-observation window in
lua/core/codemode_pending.lua had the same bug (`host.sleep(0.2)`). Both are fixed (200 ms and 2200 ms).

### MUST 3 - the real failure is now tested (fixed in `4ed3163c`)

`rust/wa-capabilities/src/operations.rs`, module `adoption_survives_the_relay_deadline`: with
`host::set_run_cancel_probe` + `serve::test_set_run_cancel` (the pair subagents' cancel test uses) the
flag is set for real, and the test asserts (a) the foreground `bash` IS cancelled by it - proof the flag
is live, so the test cannot pass while flipping nothing - (b) an adopted `control("start")` is not
cancelled and settles by finishing, and (c) the command's marker holds exactly ONE line. Gate row:
`scripts/test.sh`, `gate_run env HOME="$GATE_HOME" cargo test ... -p wa-capabilities
adoption_survives_the_relay_deadline` (`6143b263`). It refuses to run unless HOME is a scratch/temp
directory and never the node's own `~/.wasm-agent`; measured here, the gate's `GATE_HOME` resolves under
`~/.wasm-agent/tmp` (this environment's `TMPDIR`), which is the gate's own scratch area and passes. The
review's "90 s command" shape is covered by the 3 s adopted command in the Rust test plus the 5-6 s
commands in `scripts/test-remote-pending.lua`; a literal 90 s run is not in either, deliberately, so the
suite stays inside a normal gate.

### SHOULD - slice (fixed in `5ac7b171`)

`REMOTE_SLICE_MS` was 15 s, above the operation tool's own `wait_ms` maximum (10 s), so it asked for a
number the peer's schema refuses. It is now
`min(nodes.OPERATION_AWAIT_MAX_MS, nodes.RELAY_PEER_BUDGET_MS)` computed in one place, and `left` is
decremented by the time actually waited (`host.monotonic_ms`), not by the slice requested.

### SHOULD - a transient relay error (fixed in `5ac7b171`)

A transport error during one slice no longer marks anything final: the poll answers pending with the
reason and the handle stays resumable. Test: section 9/10 exercise the same executor against a relay that
refuses an unknown id and against a peer that has already settled the op; the "stays pending" behaviour is
pinned by the existing suite's unreachable-executor row (`scripts/test-codemode-pending.lua`, item 11)
plus the reason the new poll returns.

### SHOULD - the note outside code mode (fixed in `4ed3163c`)

The pending note now names the call a model can make when it has no `wait()`:
`tools.remote({node:"<this node>", capability:"operation", action:"await", id:"<id>", wait_ms:10000})`, or
`action:"cancel"` with the same id - the real parameter, read from `OPERATION_AWAIT_MAX_MS`.

### SHOULD - the relay-timeout text (fixed in `4ed3163c`)

`M.relay_deadline_note` no longer says the peer never took the call. It says the relay never delivered
the answer and the peer **may still have adopted it late**, and to check `operation list` on that node
before re-issuing.

### SHOULD - the shape test (fixed in `6143b263`)

Measured on a separate worktree at the base commit with the same binary: the CodeAct row at
`scripts/test-remote-call-shape.lua:158` fails there too ("the run declared no tool at all (63)"), after
`selfloop: publish served natively: component_missing`. It is therefore PRE-EXISTING and not this
change's, but the row sat AFTER that abort, so the five checks item 3 added never ran. The relay-deadline
section (with them) now runs before the CodeAct row, no assertion was changed or removed, and the suite
passes end to end: `remote call shape ok (88 checks, 0 skipped)`, twice.

### SHOULD - report the ownership rule (fixed here)

Measured, and now said: the adopted operation belongs to the calling **node**, recorded under
`peer:<node_id>`. Any session on that node that holds the peer session can await or cancel it by id
(that is what `test-session-isolation.lua`'s peer rows and section 7 of
`scripts/test-remote-pending.lua` measure); a LOCAL session, and another peer, cannot see or reach it.

## Re-run after the review (all on this node, scratch HOME under /home because /tmp hit its 16 G quota)

* `scripts/test-remote-pending.lua` -> `remote pending ok (61 checks)`
* `scripts/test-codemode-pending.lua` -> `codemode pending handles ok (92 checks; real sandbox)`
* `scripts/test-session-isolation.lua` -> `141 checks, 0 failed`
* `scripts/test-remote-call-shape.lua` -> `remote call shape ok (88 checks, 0 skipped)` (twice)
* `cargo test -p wa-capabilities adoption_survives_the_relay_deadline` with `HOME` = a scratch dir of the
  gate's own shape -> `1 passed; 0 failed`

Still not run: the whole `scripts/test.sh` gate, and no Rust suite beyond the one named above.

