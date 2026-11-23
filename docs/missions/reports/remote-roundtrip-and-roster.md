# remote-roundtrip-and-roster

Branch `change/remote-roundtrip-and-roster`, base `2104a4d8`, worktree `~/Work/missions/remote-roundtrip-and-roster/wt`.
All measurement on scratch nodes on this machine (its own `HOME`, its own ledger, a local rendezvous on
loopback). No live peer, no fleet, no release.

## 1. Where the ~460 ms went (re-measured, not assumed)

Route of one signed peer call, unchanged and shipped: caller process -> `GET /nodes` on the rendezvous ->
signed `POST /node/call` to the peer -> the peer's admission, verify, capability dispatch, signed reply ->
the caller's verification. Measured with a phase probe on both halves (caller marks in a WA_SCRIPT process;
peer marks in a *copy* of `lua/core` under `/tmp`, so the tree stayed clean).

**Caller half, one call, before any change (ms):**

| phase | ms |
|---|---|
| read this node's key (`nodes.identity`) | 0.1 |
| sign the roster header | 0.2 |
| `GET /nodes` (roster) | 1.4-2.1 |
| sign the call body | 0.3 |
| `POST /node/call` (the peer's whole side, see below) | 287-366 |
| verify the reply's signature | 0.2-0.3 |
| the process's own start (wall minus the interpreter's own span) | 26-30 |

**Peer half of the same call, before any change (ms):** json.decode 0.07, mesh admission 4-8,
`verify_peer` 0.1-0.2, **capability dispatch 177-710 (median ~240)**, signed reply 0.5.

So: not the connect, not the signing, not the verification, and not the response. The round trip was the
peer's capability dispatch, and inside it `adopt_bash` - the path every peer `bash` takes because
`nodes.remote_call` stamps `budget_ms` into the signed body (`lua/core/server.lua`, `wa_peer_dispatch`) -
made **six `tools.dispatch` calls** per call: reap (`operation list`), `start`, `await`, `status`,
`read` stdout, `read` stderr. Split of those six (instrumented copy): reap 36-60, start 35-87,
await 44-71 (the command itself is ~20), result 92-195.

**Why one `tools.dispatch` cost ~35 ms** (measured by timing the dispatcher's own parts):

* `dofile('lua/core/orchestration_mode.lua')` **9 ms** - re-read and re-compiled on every dispatch, and that
  module's own header loads json, memory, users and the 1,969-line `nodes.lua`;
* `M.all(role, ctx, memory)` **11-18 ms** - every tool schema rebuilt on every dispatch, read by four
  paths (`tool_search`, `tool_call`, `run`/`codemode`, `capabilities`) and by nothing on a normal call;
* the remaining guards (`retired`, `secret_guard`, whatsapp names, `codemode_policy`) ~2-3 ms.

**And the caller's own overhead, which is bigger than the peer's:** a `wa call` CLI process in a scratch
home with **no rendezvous at all** took 380-500 ms, of which ~190 ms is the binary's start before Lua runs,
15-21 ms `memory.setup()`, ~4 ms loading `nodes.lua`, and **122 ms inside `nodes.list`** - of which
**120.3 ms is `host.system_resources()`**, which measures CPU as a delta between two `/proc/stat` reads and
therefore sleeps 120 ms on purpose. `M.find` builds that local roster row for *every* remote call.

## 2. What was cut, and by how much

| cut | commit | where |
|---|---|---|
| the reap's `operation list` is skipped when this peer session has no adopted id, and the index is not rewritten when nothing changed | `a2bb92e6` | `lua/core/server.lua` (`adopted_open`) |
| the settled record is read once: `adopted_result` takes the snapshot that already said "settled" | `a2bb92e6` | `lua/core/server.lua` (`adopted_result`, two call sites) |
| the dispatcher builds the tool catalogue only where it is read | `af2db6d6` | `lua/core/tools.lua` (`routed_catalog`) |
| `orchestration_mode` is compiled once per process, not once per dispatch (lazily, and the disk stays the source of truth on every call) | `af2db6d6` | `lua/core/tools.lua` (`orchestration()`) |
| the roster's local row asks for a resource sample without the 120 ms CPU delta, and the answer says the figure was not measured | `27a4ff96` | `lua/core/nodes.lua` (`M.list`), `rust/wa-host-support/src/system_resources.rs` (`sample_quick`), `rust/wa-capabilities/src/host.rs` (`system_resources`), `capabilities.rs` |

Measured, alternating base worktree and this tree in one session, five samples per run, three rounds
(median of each run shown; this node's load was 2-10 on 16 cores):

* **the peer half of one call** (caller-visible `POST /node/call`): base 204 / 214 / 248 ms ->
  this tree **36 / 38 / 36 ms** (5.7x);
* **the speed board's own row** (`scripts/speed/probe-remote.sh`, whole `wa call` process included):
  base 507 / 469 / 521 ms -> this tree **258 / 193 / 219 ms** (2.3x).

The row's floor is now the `wa call` CLI's own start (~190 ms of it is the binary before Lua runs), which
the `start` row owns; that is named under "not done" below rather than folded into this number.

## 3. A node that never registered hears so by name

The rendezvous answers `GET /nodes` only to a node it can verify, and it learns a node's key when that node
registers (`rust/wa-rendezvous/src/rendezvous.rs`, `verify()` and `list()`; `verify()` answers **401
`unknown_node`** when it holds no key for the id). The caller collapsed that into `roster_unavailable`, so a
node's own missing registration read as a network problem. Now (`465eb80c`):

* `lua/core/nodes.lua` `fetch_peers` keeps the status and the allow-listed code of a refused roster read
  (`M.relay_code`, the same allow-list the relay refusals use) and records
  `not_registered = (status == 401 and code == "unknown_node")`;
* `M.not_registered()` and `M.not_registered_refusal()` answer by name, and `remote_call` prefers that
  answer over `roster_unavailable`; every other refusal (503, 401 `bad_signature_key`, 500) stays
  `roster_unavailable` and stays retryable;
* the docs say it too (`5885ac80`, `docs/RENDEZVOUS.md`).

Verified across processes, not only in a stub: a scratch rendezvous + a serving peer + a caller CLI that
never serves answered

    {"connector":"not_registered","error":"not_registered:peer", ... "retryable":false, "roster_status":401}

where before the same fixture answered `roster_unavailable:box` (`/tmp/rr-noserve.sh`, this machine).

## 4. Tests, and that they fail on the base

Every row below creates its own scratch `WASM_AGENT_HOME` and refuses to run when that is the node's own
`~/.wasm-agent` (the guard is the first block of each file). Each was run against a **separate worktree of
the base commit** (`git worktree add /tmp/base-rr 2104a4d8`, rule 12 - no stash), with the base's own Lua:

| row | wired into | fails on base with |
|---|---|---|
| `scripts/test-network-not-registered.lua` (19 checks) | `scripts/test.sh` line 1426, and the fast path (not excluded) | `got roster_unavailable:box` where `not_registered:box` is required |
| `scripts/test-remote-call-bound.lua` (21 checks) | `scripts/test.sh` line 1431, fast path | `a short peer bash costs at most 4 host.operation calls, got 6: list,start,await,status,read,read` |
| `scripts/test-tool-dispatch-cost.lua` (9 checks) | `scripts/test.sh` line 1435, fast path | `two dispatches load orchestration_mode once, loaded 4` |
| `scripts/test-roster-sample-quick.lua` (15 checks) | `scripts/test.sh` line 1438, fast path | `and no CPU percentage it did not measure, got 64.4` (the roster row took the 120 ms full sample) |

The last row has two halves. Its Lua half was run against the base *tree* with this tree's binary and fails
there as shown. Its Rust half (`{quick:true}`) cannot fail against the base tree at all, because the host is
the binary: at the base commit `host.system_resources` ignores every argument
(`git show 2104a4d8:rust/wa-capabilities/src/host.rs`, the function's only statement is
`push_json(l, &wa_host_support::system_resources::sample())`), so the base binary answers a measured
`used_percent` for the quick call and the row's first three checks fail there. An older binary on a newer
tree is harmless: it ignores the extra argument and simply pays the 120 ms.

The bound row also pins the two things the cut must not break: the answer carries what the local
synchronous `bash` answers (`code`, `ok`, `stdout`, `stderr`, compared field by field against
`tools.dispatch('bash', ...)` in the same process), and **once one handle is adopted the reap's `list`
runs again** - laziness removed the idle cost, not the rule.

Parity was checked against a **real peer answer recorded on the base commit** (`2104a4d8`, the fixture in
§1), not only in-process: the base answers **41 fields** (`adopted`, `cleanup`, `cleanup_budget_ms`, `code`,
`containment`, `cpu_priority`, `cwd`, `cwd_requested`, `cwd_source`, `effective_cwd`, `elapsed_ms`,
`last_output_elapsed_ms`, `ok`, `operation_id`, `output_bytes`, `output_complete`, `output_streams_closed`,
`output_truncated`, `overdue`, `owner`, `owner_boot`, `owner_process_id`, `process_exit_code`,
`process_exit_elapsed_ms`, `promoted`, `session`, `settled`, `state`, `status`, `stderr`, `stderr_bytes`,
`stderr_elided_bytes`, `stderr_path`, `stderr_truncated`, `stdout`, `stdout_bytes`, `stdout_elided_bytes`,
`stdout_path`, `stdout_truncated`, `timeout_ms`, `timing`) and this tree answers **exactly those 41** - no
field missing, none added - after `d51b614e`, which removed three marks the first version of the cut had
leaked: the answer said `output_omitted: true` (and its hint, "ask for it with output=true") next to
`stdout: "ok"`, because the snapshot it now reuses had been through `tools.lua`'s list/await pruning. The
recorded set is asserted by the row (`test-remote-call-bound.lua`, section 2b), so the next cut cannot drop
or invent a field silently.

Rule 14's order was not kept here and that is a mistake worth naming: the golden set above was recorded from
the base **after** the cut, not before it. The base worktree at `2104a4d8` and the same fixture were still
available, so the recording is of the real old path - but it happened in the other order, and the first
version of the cut had already changed the answer (the three leaked marks) when it was taken. A cut that
reshapes an answer should record its golden first.

### The rows that were run, individually (the full fast path was queued behind the suite lock)

Twenty rows were run one at a time on this tree, each with its own scratch home, no network: the four above
plus `test-session-isolation` (141 checks), `test-remote-edit` (46), `test-remote-call-shape` (87),
`test-remote-pending` (90), `test-undo-command` (40), `test-refusal-contract` (17,181),
`test-orchestration-mode` (77, no inference), `test-node-dispatch-wiring` (10, 29 admitted capabilities),
`test-tool-schema-fidelity` (69), `test-codemode-parity` (56, 67 tools), `test-codemode-boundary` (33),
`test-hooks-tools` (25), `test-prompt-tool-names` (288). All green. `test-exec-timeout` SKIPPED by its own
guard (its fixture child cannot run here), and `test-orchestration-routing` is not runnable standalone at
all - it asserts `WA_ROUTING_SOURCE`, a private-Git fixture only the runner provides (`scripts/fast.sh`) -
so its green is only claimed by the suite, not here.

## 5. Job 5 - the remote `edit` shape: measured, inconclusive, so no schema change

The premise is right: the `remote` schema's *parameters* are `node, capability, command, path, args, calls`
(`lua/core/tools.lua:590-597`) and `edits` appears only in the description. What the ledger can and cannot
say:

* `remote_arguments` forwards **every** top-level key that is not the remote call's own into the
  capability's arguments (`lua/core/tools.lua:244-253`), so a flat `edits` reaches the peer's `edit`
  unchanged; the omission costs discovery, not correctness. Nothing in the path drops it.
* `search_messages` over this node's ledger returns **zero** results for `tool_name:"remote"` - remote tool
  results are not indexed under that name at all - so "how often a remote edit's first call has a wrong
  shape" **cannot be counted from the ledger**. Unknown is not zero (rule 1), and it is not "rare" either.
* What the ledger does show: the codes a wrong-shaped remote edit would produce -
  `edits_required_1_to_64`, `unsupported_edit_option`, `mixed_edit_forms`,
  `remote_argument_conflict`, `remote_node_required` - occur **zero** times anywhere in indexed content
  except in this session's own source reads. The four remote-edit task sessions that do appear
  (`capability:edit` searches) all used the documented flat form, and the one complete example
  (session `86500d9b`, "change line 2 to TWO ... with capability edit") succeeded on its first call.

**Proposal: no schema change.** Not because the count is zero, but because the ledger cannot support a
count; a schema change spends every session's cache prefix and the runtime already accepts the key. If it
is wanted anyway, the smallest honest change is one line in the `remote` schema -
`edits = { type = "array", items = { type = "object" }, description = "For edit: [{old_text,new_text}] ..." }` -
and it should be proposed with a measurement the ledger can actually make (a tool-argument index, or a
count of `tool_name:"remote"` results once that indexing exists).

## 6. Texts to approve (model- or operator-facing, verbatim)

1. The refusal a node with no registration now gets (`lua/core/nodes.lua`, `M.not_registered_refusal`, commit `465eb80c`):

   ```
   error:    "not_registered:" .. <peer>
   connector: not_registered
   retryable: false
   message: "this node is not registered at the rendezvous, so <peer> cannot be looked up: the rendezvous
             holds no key for this node's id and refuses its roster reads. Nothing was sent to <peer> and
             nothing ran there."
   fix:     "start this node's own serve loop so it registers its key at WASM_AGENT_RENDEZVOUS -
             `wa serve` does it and keeps the registration alive - then retry this call. `wa bind status`
             says what the rendezvous knows about this node."
   ```

2. `docs/RENDEZVOUS.md` (commit `5885ac80`): "A node that does NOT serve cannot call anybody, and now
   hears why. ... `wa call` names that case `not_registered:<peer>` with the fix (`wa serve`, which
   registers and heartbeats) instead of the `roster_unavailable` that an unreachable registry produces".

3. The host capability line (`rust/wa-capabilities/src/capabilities.rs`, commit `27a4ff96`):
   "CPU, memory and disk facts for this machine; passed {quick:true} it skips the 120 ms CPU delta and says
   the figure was not measured".

4. The sample itself (`rust/wa-host-support/src/system_resources.rs`, commit `27a4ff96`), read by anything
   that decodes `host.system_resources` or `tools.nodes[1].resources`:
   `"quick": true` and
   `"cpu": {"logical_cores": 16, "used_percent": null, "unmeasured": "no CPU delta was taken: it costs a
   120 ms window between two samples, and this caller only displays the sample"}`.

No other model-facing string changed: the peer-bash answer keeps every field it had (§4), and the refusal
codes a peer call can return are unchanged.

## 7. Premises from the brief, re-measured, and what was wrong

* "411-477 ms (median 461) ... on 8862b600" - same phenomenon, different machine-day: on this node at the
  base commit (`2104a4d8`) the same row measured 469-528 ms (median ~507) at load 2-10 on 16 cores.
* "about 5x the process's own cold start" - true of the row, but the interesting part is *which* start:
  the interpreter's own span is 26-30 ms, the `wa call` CLI's own start is ~190 ms before Lua runs, and
  the peer's work was ~300 ms of the row. The row is not 5x a peer call; it was 1 part CLI start, 1 part
  peer bookkeeping.
* "The rendezvous answers GET /nodes only to a node it can verify" - confirmed, `rendezvous.rs` `/nodes`
  (`verify` + `is_master`) and `verify()`'s 401 `unknown_node`.
* "the remote parameters don't list edits" - confirmed, `lua/core/tools.lua:590-597`; and it does not
  matter at runtime (§5).
* Not a premise but worth knowing: this node's `/tmp` intermittently refuses SQLite writes for the `wa`
  binary (`[db] pragmas not applied to /tmp/.../x.db: disk I/O error`, 2 of ~6 fixture starts), which makes
  `scripts/speed/probe-remote.sh` answer `unavailable` because it takes its scratch from `/tmp`
  unconditionally. Its own guard refuses a scratch directory inside the operator's home, so a `TMPDIR`
  inside `$HOME` cannot be used either. Not changed here (not this mission's file); the numbers above were
  taken from fixtures that came up.

## 8. Not done, and not verified

* **The `wa call` CLI's own ~190 ms start (before Lua) is untouched.** It is now about two thirds of the
  row's remaining 219 ms and it belongs to the `start` row. Measured, named, not cut.
* **No release, no fleet update, no deploy, nothing on a live peer** (overnight rules). The cross-process
  `not_registered` proof ran against a scratch rendezvous and scratch nodes on loopback.
* The dispatch bound is a *count* of `host.operation` calls, not a wall-clock assertion: timing rows flake
  under this node's load, and the count is the thing the cut changed.
* The full fast path is running under `flock -o ~/Work/missions/.suite.lock`; its result line is added
  here when it settles (see the last section).
