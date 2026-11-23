# slim-tool-results

Priority 2, Victor 22/11: "a bash result carries what a caller acts on; the bookkeeping stays one
handle away". Branch `change/slim-tool-results`, base `899fdd47`, worktree
`/home/victor/Work/missions/slim-tool-results/wt`. Build and tests on avell only
(`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-slim-tool-results`).

| commit | what it is |
|---|---|
| `1e523c2b` | `lua/core/bash_result.lua` (the allow-list), the dispatcher door, and the two readers that moved |
| `691f7ea0` | `scripts/test-slim-bash-result.lua`, the three recorded fixtures, and `scripts/test-workspace-cwd.lua` reading the record |
| `4db64991` | `docs/CODEMODE.md` "What a command's answer carries", and the fixtures' provenance |

## Premises, re-measured before writing code

| the brief said | measured on the base | verdict |
|---|---|---|
| a bash result carries ~45 fields, 1,096 bytes of them bookkeeping | one real run block on the base (`echo hi`): **38 fields and 1,308 bytes** for a direct call, **40 fields / 1,370 bytes** for the value a script sees; the 200-result census and its 33% are the previous report's numbers (`docs/missions/reports/write-names-its-node.md`), which this mission did not re-run - the live ledger is fenced to agents (`secret_path_denied`) and only the recorded answer store is readable | the byte claim holds, "about 45" is 38-42 |
| re-measure which fields scripts read from "the fixture ledger (last 500 runs)" | **there is no fixture ledger**: `fixtures/` holds `one-run-path/`, `raw-default/`, `run-live/`, none of them a run ledger, and the ledger itself (`~/.wasm-agent/memory.db`) is refused to an agent tool. What is reproducible: the recorded ANSWER store (`~/.wasm-agent/tool-results`), this repo's own readers (below), and this mission's runs | the premise was stale; measured differently, said so |
| `docs/CODEMODE.md` and the generated prompt docs list removed fields, so the prompt prefix moves once | `bash scripts/sync-prompt-docs.sh --check` on this branch: **`sync-prompt-docs: ok (4 blocks current)`**, rc=0 - the generated docs (`ENVELOPE.md`, `LAYERED-PROMPT.md`, `PROGRESSIVE-ENVELOPE.md`) do not move, so the **prompt prefix delta is 0 bytes**. No doc listed a command result's fields; `docs/CODEMODE.md` does now, +2,204 bytes, and it is not part of the cached prefix | the prefix claim was wrong for this change |
| items 2-5 as written | confirmed by the code paths cited per item below | correct |

## Item 1 - who reads a removed field (the census)

Receiver-qualified grep over `lua/core/*.lua` (`rg "[%w_)]\]\.<field>\b"`), for the 32 fields the
previous report put in the removable set. **None of them is read off a command result anywhere in the
tree** - with exactly two exceptions, both handled in this change:

| field | reader on the base | what this change does |
|---|---|---|
| `process_exit_code`, `settled` | `lua/core/codemode.lua`, `script_value`: "a command that RAN and exited non-zero is a result, not an exception" decided on `value.process_exit_code` + `value.settled` | reads `code` + `output_complete`, the fields the answer still carries (`1e523c2b`) - the documented behaviour is unchanged and `scripts/test-slim-bash-result.lua` pins it |
| `effective_cwd`, `cwd_requested`, `cwd_source`, `cwd`, `promoted` | `scripts/test-workspace-cwd.lua`, six assertions | read from the operation record through the handle instead (`691f7ea0`); the assertions are the same six, and one is added |

Everything else the grep names is a different object, checked line by line: `platform.cwd()` and
`ctx.cwd` (agent, chat, done_gate), the operation record (`codemode_pending`, `tool_output`,
`wave-executor`), a subagent/wake row (`completions`, `orchestrator`, `handle_wake`, `selfloop`),
a command the module ran itself (`command_output`, `patch_audit`, `wave_autoflush`), or the tool
catalogue (`tools.lua`). `progress_guard` reads `promoted`/`settled`/`output_bytes` off ANY answer as
wait evidence; a settled command was never in its wait states, so a slim answer changes its verdict for
no case, and a promoted (still-running descendants) answer now reads as the answer it is - the note says
"Do not rerun the command" and is kept.

## Item 2 - the shape (and where the rest lives)

`lua/core/bash_result.lua` (`1e523c2b`) is an **allow-list**: `stdout`, `stderr`, `code`, `ok`,
`node`, `operation_id`, `timeout_ms`, the eight truncation/size facts, and the hint/refusal words
(`output_hint`, `staged_script_note`, `error`, `note`, `fix`, `normalized`). Everything else is dropped
from the answer - and a shape that is not a command envelope (no `stdout` and no `code`: a transport
refusal, a `{state:"pending"}` handle, a page a `read` returned) is passed through **untouched**.

It is applied at the last door every call passes, `lua/core/tools.lua`'s final dispatcher wrapper - after
the hooks, after the refusal renderer and after `status.stamp`, so every other caller of that layer sees
what it saw before. A script's bash is a *managed operation* built by `lua/core/codemode_pending.lua`,
which never crosses that door, so `lua/core/codemode.lua` applies the same function to the value the
script receives (twice: before `script_value`, so the evidence `showCall` keeps is the native answer,
and after it, so the `ok:true, status:200` the non-zero-exit rewrite adds does not come back as a
duplicate of `ok`).

**Nothing was lost, and the row proves it field by field.** Every removed field is on the operation
record, written by `rust/wa-operation/src/lib.rs` before any of this runs, and
`operation {action="status", id:<operation_id>}` answers it verbatim
(`rust/wa-capabilities/src/operations.rs`, the `status` arm). `scripts/test-slim-bash-result.lua`
takes the removed set **from the recorded old answer** (not from a list) and asserts that each of those
fields is reachable through the handle, plus the kept fields agreeing with the record. One field is
special, and the row says why instead of skipping it: `overdue` is a live-wait fact the record computes
only while the operation is unsettled, so a command that answered carries it as always-false and the
handle still answers it while work is live.

## Item 3 - local and remote, one shape

`bash_result.slim_for(name, args, value)` decides by the CALL, not by the answer's text: `bash` is
slimmed, `remote` with `capability:"bash"` is slimmed, and a `remote` batch slims the entries whose
`calls[i].capability` is `bash` and leaves every other entry byte-identical. So an **OLD peer's fat
answer is slimmed by the caller** - exercised in the row against `old-remote-bash.json`, the peer's real
answer recorded from this node's result store, and against a live `remote` call addressed to this node
(local and remote answers come back with the same field set, asserted key by key).

## Item 4 - the docs

`docs/CODEMODE.md` gains "What a command's answer carries (22/11)": the kept fields, the record fields by
name, and why. The generated prompt docs did not move (above), so the prefix delta is 0 bytes and no
release-time prompt miss is due; the doc itself is +2,204 bytes and is read on demand.

## Item 5 - the tests

`scripts/test-slim-bash-result.lua`, **135 checks, green**. It refuses the real `~/.wasm-agent` first
(`scripts/lib/scratch-home.lua`), writes its own home, and calls no peer but this node itself. It holds:
the three recorded answers load and *are* the fat shape; nothing outside the kept set reaches a caller
(run block and direct call); the removed set is derived from the recorded answer and every removed field
is reachable through the handle; the shape is a copy, idempotent, and the routing function leaves reads
and refusals untouched; a non-zero exit is still an answer; `r.stdout`/`r.code`/`r.ok` read what they
read before; local and remote bash answer the same fields.

Wiring: it is a `scripts/test-*.lua` that `scripts/fast-path.exclude` does not name, so the fast path
runs it by construction (`scripts/lib/fast-rows.sh`), and `scripts/test-core-parity.sh` takes the same
set. `scripts/test-workspace-cwd.lua` (a gate row, excluded from the fast path because it needs
`WA_CWD_SOURCE`) now reads the attribution from the record.

## Numbers, measured here

| answer | fields | bytes (minified JSON) |
|---|---|---|
| `tools.bash("echo hi")`, base | 38 | 1,308 |
| `tools.bash("echo hi")`, this branch | 12 | 261 |
| the same value inside a run block, base | 40 | 1,370 |
| the same value inside a run block, this branch | 14 | 295 |
| the same, on a peer (recorded old answer) | 42 | 1,608 (unchanged on the wire; the caller keeps 12 fields / 295 bytes of it) |

The census number this mission moves (previous report, 200 recorded results): 1,096 bytes of bookkeeping
per call, 33% of the window went to it, 219,168 bytes of 660,497. The allow-list drops 26 of the 38
fields of a settled local answer.

## Tests against the base code (rule 16)

`bash scripts/test-discriminates.sh 899fdd47`: `1 discriminating, 0 blocking, 0 not judged` -
`scripts/test-slim-bash-result.lua` is `new-symbol` (the base has no `lua/core/bash_result.lua`:
`lua_root_unreadable`), and `scripts/test-workspace-cwd.lua` is `discriminates`, but for a reason that is
not mine: that row is driven by its own `.mjs` and dies at its first line on the missing
`WA_CWD_SOURCE`. So the automatic row is **not** evidence from this change, and the honest evidence is
the measurement below.

The shape assertion on its own, without the new module, run through the same run block against both Lua
roots (a 10-line scratch script, kept out of the tree):

    WASM_AGENT_LUA_ROOT=/tmp/wt-base   (base 899fdd47): lua error: a removed field reached the script:
      cleanup,cleanup_budget_ms,containment,cpu_priority,cwd,cwd_requested,cwd_source,effective_cwd,
      elapsed_ms,last_output_elapsed_ms,output_bytes,output_omitted,output_streams_closed,overdue,owner,
      owner_boot,owner_process_id,process_exit_code,...
    WASM_AGENT_LUA_ROOT=<this branch>:  SHAPE OK (no field outside the kept set)

## Runs

PLACEHOLDER_SUITE

`scripts/test-workspace-cwd.mjs` (the gate driver for the row above): **fails on the base and on this
branch at the same assertion** - `actual process succeeded` for the parallel-batch await, because a raw
`host.operation` caller is refused `operation_not_yours` for an operation a workspace session started
(`git worktree add --detach /tmp/wt-base 899fdd47`, same driver, same message). Pre-existing, not this
change's: the record's `session` is the workspace id, not the caller's, and the raw `op('await')` door
never names one. Everything before that point - two verifies that now read the record - passes on this
branch.

## Texts to approve

Model-facing:

1. `docs/CODEMODE.md`, "What a command's answer carries (22/11)" - the kept field list, the record field
   list, and the two rules (an unrecognised shape passes through untouched; one allow-list for a direct
   call and a script). +2,204 bytes in a doc, 0 bytes in the prompt prefix.
2. The answer shape itself: a `tools.bash` result keeps `stdout, stderr, code, ok, node, operation_id,
   timeout_ms, stdout_truncated, stderr_truncated, output_truncated, output_complete, stdout_elided_bytes,
   stderr_elided_bytes, stdout_bytes, stderr_bytes, output_hint, staged_script_note, error, note, fix,
   normalized`, e.g. `{"stdout":"hi\n","stderr":"","code":0,"ok":true,"operation_id":"op-...",
   "timeout_ms":300000,"output_complete":true,"output_truncated":false,"stdout_truncated":false,
   "stderr_truncated":false,"stdout_elided_bytes":0,"stderr_elided_bytes":0}`.

No tool schema, description, refusal sentence, or refusal code changed (the catalogue is what the model
reads at the start of a session; `scripts/sync-prompt-docs.sh --check` is green, which is the check that
would catch a schema move).

## Not done / still unknown

* No live-peer call was made (mission rule 13). The remote half is proven with a real recorded peer
  answer and a `remote` call addressed to this node; a *live* old node answering fat was not exercised,
  and the slimming path for it is the same function the recorded answer goes through.
* `wait(op)` / a settled pending handle still answers the operation record (fat). The brief scoped the
  shape to "the result a script receives" from a call, not to the handle's own resume, and changing
  `wait` would move `docs/CODEMODE.md`'s "the same shape a direct call answers" promise. Named here so
  it is a decision, not an oversight.
* `showCall` shows the same slim answer the script got: its evidence is stored from that value. The
  pointer to the removed fields is `operation status`, which the row exercises; I did not add a second
  door.
* A local bash answer still carries no `node` (only a peer's does). Adding it was out of scope - it is a
  new model-facing field - and the earlier `write`/`edit` receipt mission is where that decision lives.
* The 200-result census was not re-run (the ledger is fenced); this report uses its numbers and says so.
