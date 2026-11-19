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

