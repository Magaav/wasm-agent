# write-names-its-node

Priority 2. A worker model (deepseek, on nextcloud) reported: "tools.write defaulted to the local node, so a
path I meant for the peer silently landed on avell. Binary success (ok:true) with the wrong target is the
friction ... the receipt echoing the node would have removed a failed round."

Branch `change/write-names-its-node`, base `c6f890e3`, worktree
`/home/victor/Work/missions/write-names-its-node/wt`. Commit `960e94c0` carries items 1 and 2 of the
mission; item 3 is measurement only and changed no code.

## Premises, re-measured before writing code

| brief said | measured on the base | verdict |
| --- | --- | --- |
| local write result `{ok, path, graph_index}`, no node (tools.lua:1934) | `lua/core/tools.lua:1934` is exactly that return, and it carries no node | correct |
| the remote result names its node | `tools.lua:1323` puts `node = node.name` in the `remote` answer; a recorded remote write result is `{"graph_index":{...},"node":"nextcloud","ok":true,"path":"/tmp/colmeio-browser/nav-gap-check.cjs","status":200}` (164 bytes, `~/.wasm-agent/tool-results/b496f17d0e7c...txt`) | correct |
| `tools.write`'s schema is at tools.lua:452 | `452:  schema("write", ...)` on the base | correct |
| remote bash result: 1608 bytes for 196 bytes of stdout, "about 45 bookkeeping fields" | `60cd56b7...txt` is 1608 bytes with 196 bytes of stdout - correct; the field count is **52 distinct names, 41.7 per call** (min 39, max 45) over the last 200, not 45 | the byte claim holds, the field count was low |

Nothing in the brief was wrong about the code; only the field count needed correcting.

## Item 1 + 2 - the receipt names the node (`960e94c0`)

`git show 960e94c0 -- lua/core/tools.lua` adds one module-level helper (`on_this_node`, branch
`lua/core/tools.lua:67`) and wraps the results of the `write` and `edit` branches in it
(`:1952` write-applied, `:1962` edit, plus the three refusals above them). The helper reads
`nodes.node_name()` once per process, through `pcall`, and writes `node` only when the result does not
already have it.

* The word is the one `nodes` reports for this node: the test asserts the receipt's `node`,
  `nodes.node_name()` and the local row of `nodes.list()` are the same string
  (`scripts/test-write-node-receipt.lua`, checks 3-4).
* Unknown is not yes: when the name cannot be read the field is **absent** - not `"host"`, not `""`, not a
  directory - and a check proves it by making the name file unreadable for a fresh `dofile` of the module
  and asserting `result.node == nil` while the write still applied.
* Every field the receipt had before is still there and is asserted: `ok`, `path`, `graph_index` for a
  write; `applied`, `path` for an edit; `error` for a refusal. Nothing is replaced.
* No `node` parameter was added to `write` or `edit` (the mission's item 2). Measured, not asserted by
  eye: the catalogue JSON and the two tool schemas are byte-identical between `c6f890e3` and `960e94c0`
  - catalogue 66,583 bytes sha256 `dabdadc3...`, write schema 332 bytes sha256 `c9608c0d...`, edit schema
  1711 bytes sha256 `eaa3c78d...`, envelope sha256 `4684aa73...` in both trees. So the text a model reads
  at the start of a session does not move; only appended tool-result text gains a key.
* Nothing was added for the second half of item 2 (a local write followed by a `remote` call naming the
  same path that fails with "No such file"): with the node in the receipt the model can see the mismatch
  itself, and the mission asked for no extra mechanism.

Item 1 was measured through the real path, not a direct dispatch: the test opens one run block
(`tools.dispatch(memory,'codemode',{code=...})`, the call the tool loop makes for a fenced block) and
reads the value the script received from `await tools.write(...)` / `tools.edit(...)`, including the
refusal text a failed nested call throws:

    {"graph_index":{"ok":true,...},"node":"wn-receipt-node","ok":true,"path":"...","status":200}
    {"error":"mixed_edit_forms",...,"node":"wn-receipt-node","status":500,"tier":"code"}

**Test and wiring.** `scripts/test-write-node-receipt.lua`, 18 checks, green on this branch. It refuses the
real `~/.wasm-agent` first (`scripts/lib/scratch-home.lua`) and names its fixture node inside its own
scratch home. It is a fast-path row by construction - `scripts/lib/fast-rows.sh:73` runs every
`scripts/test-*.lua` that `scripts/fast-path.exclude` does not name, and this file is not named there - and
`scripts/test-core-parity.sh:7` takes the same set for the guest/native parity. **Runs, measured on this node (avell):**

* `flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh --jobs 6` on `960e94c0`:
  `fast path ok (394 checks, 0 skipped, 665s)`, 0 failed, and the new row is in the result as
  `scripts/test-write-node-receipt.lua: pass, 1898 ms, environment: false` - it ran, it did not skip.
* `bash scripts/test-discriminates.sh c6f890e3` (with `WA_BIN` pointing at the binary that run built from
  `960e94c0`, since the mission's `CARGO_TARGET_DIR` is not the one-root target the script resolves):
  `discriminates - lua error: ...:33: the write receipt names the node it wrote on`, 1 discriminating, 0
  blocking, 0 environment. So the row fails on the base code at exactly the assertion it exists for, and
  the same verdict was reproduced by hand first against a separate base worktree
  (`git worktree add --detach /tmp/wn-base c6f890e3`, removed afterwards).

## Item 3 - what a remote bash result costs, measured (no change made)

Read-only. Source: `~/.wasm-agent/tool-results`, the blob store the ledger's tool rows point at - the
session ledger itself (`~/.wasm-agent/memory.db`) is refused to an agent tool by `secret_guard`
(`secret_path_denied`, measured), so the measurement reads the recorded results, not the SQL. Scope: the
last **200** recorded results that carry an operation envelope (`owner_boot` + `stdout`), newest first,
window 2026-11-22T15:49Z .. 20:34Z; 134,524 files scanned.

| measure | all 200 | remote (37 with `node`) | local (163) |
| --- | --- | --- | --- |
| envelope bytes, total | 660,497 | 112,093 | 548,404 |
| median / mean per call | 2,111 / 3,302 | 1,776 / 3,030 | 2,182 / 3,364 |
| fields per call, mean | 41.7 | 41.9 | 41.6 |
| `{ok,code,stdout,stderr}` | 382,964 | 62,711 | 320,253 |
| that plus the byte/truncation limits | 413,821 | 68,416 | 345,405 |
| envelope / decision-fields, median | 2.68x | 3.0x | 2.55x |

So a script that returns `r.stdout` pays nothing for the envelope (the model's script decides), but a
script that returns the whole object - the default a model reaches for when it does not know the shape -
pays **2.7x** what it needs: 2,111 bytes instead of 756, and up to 17,351 bytes in the window.

### Which fields could move behind `showCall`

Field means per call over the same 200 (JSON bytes including the key). The decision fields, which should
stay: `stdout` 1851, `stderr` 42, `operation_id` 47 (the handle to read the rest), `stdout_truncated` /
`stderr_truncated` / `output_truncated` / `output_complete` 24/24/24/22, `stdout_elided_bytes` /
`stderr_elided_bytes` 23/23, `timeout_ms` 19, `stdout_bytes` / `stderr_bytes` 18/16, `ok` 9, `code` 8,
`node` 3.

The 32 fields below are recoverable bookkeeping - none of them changes what a model does next, and 179
bytes per call of them are remote filesystem paths (`/home/ubuntu/.wasm-agent/operations/<id>/stdout`)
that also leak the peer's layout:

| field | mean bytes/call | | field | mean bytes/call |
| --- | --- | --- | --- | --- |
| `timing` (15 sub-fields) | 260 | | `owner_process_id` | 26 |
| `stderr_path` | 89 | | `cleanup_budget_ms` | 24 |
| `stdout_path` | 89 | | `cpu_priority` | 24 |
| `effective_cwd` | 61 | | `cleanup` | 22 |
| `owner_boot` | 49 | | `process_exit_code` (duplicate of `code`) | 21 |
| `session` | 48 | | `cwd_source` / `cwd_requested` / `cwd` | 45 |
| `owner` | 47 | | `output_bytes` / `output_omitted` | 27 |
| `output_hint` | 45 | | `state` / `status` (duplicate of `ok`) | 30 |
| `containment` | 35 | | `promoted` / `elapsed_ms` / `overdue` / `settled` | 61 |
| `process_exit_elapsed_ms` | 28 | | `stdout_omitted` / `stderr_omitted` / `background` | 10 |
| `output_streams_closed` | 28 | | `adopted` | 3 |
| `last_output_elapsed_ms` | 27 | | | |

**Proposal (not implemented).** Keep the decision set inline; move those 32 behind `showCall`. Measured on
the same 200 results: 219,168 bytes of 660,497 are those fields - **33% of the window, 1,096 bytes per
call**, the envelope dropping from 2,111 to 879 bytes median (a median of 2.32x smaller). The three
fields worth moving first are `timing` (51,960 bytes of the window, nothing a caller acts on),
`stdout_path`+`stderr_path` (35,792 bytes, and the peer's directory layout with them) and
`effective_cwd`+`cwd*` (24,596 bytes, already summarised inside `timing`).

Two caveats, stated rather than smoothed over: `stdout` alone is 56% of the window (370,644 bytes), so a
slimmer envelope cannot make a bash result small - only 84 of 200 results withheld their output
(`output_hint` present); and the 37 "remote" rows are the ones that carry `node`, which is a lower bound
on how much of this ledger traffic went to a peer.

## Texts to approve

New model-facing text (the field name a receipt gains; nothing else in this mission is model-facing):

1. `node` - a new key in the result of `tools.write` and `tools.edit`, applied or refused, carrying this
   node's name as `nodes` reports it, e.g. `{"ok":true,"path":"...","graph_index":{...},"node":"avell"}`.
   Absent when the name cannot be read.

No schema text, description, refusal sentence or prompt document changed (measured: identical catalogue
hash, above). The regression messages in `scripts/test-write-node-receipt.lua` are test text, not
model-facing.

### Which word "avell" will be

The acceptance test expects `node: "avell"`. The field is `nodes.node_name()`, whose order is the stored
name file, then the checkout's directory name, then `WASM_AGENT_NODE_NAME`, then `"host"`
(`lua/core/nodes.lua:121-131`) - the same word `wa nodes` prints for this node. Measured in this mission's
worktree, a scratch home and `WASM_AGENT_NODE_NAME=avell` set: the receipt says `"node":"wt"`, because the
directory name wins over the environment on a master node. So on a node whose checkout, name file or
`wa nodes` line says `avell`, the receipt says `avell`; in a mission worktree it names the worktree. That
is deliberate and is why the row asserts equality with `nodes`, not the literal string.

## Not done / still unknown

* No `node` parameter on write/edit (by the mission's instruction), so a model still cannot *aim* a write
  at a peer with `tools.write`; it aims with `remote`. The receipt now tells it which node answered.
* The `showCall` move in item 3 is a proposal only: the envelope was not changed, per the mission.
* The measurement reads `tool-results` blobs, not `memory.db`: 200 recorded results is what the store
  holds for that window, and I did not correlate them with session rows (the DB is guarded from an agent
  tool). Whether every one of those 200 was a caller's outermost call is not something this measurement
  can tell.
