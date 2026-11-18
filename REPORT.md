# harness-fixes — measured 18/11 on avell (node-63c4dad7) and work (14963b6f)

Branch `change/harness-fixes`, base origin/main `74d48431`. Nothing pushed; no real node state touched:
every row runs in its own `mktemp -d` home with no rendezvous, no relay and no vault, and each row stubs the
provider stream (no paid call).

## How the rows were run, and the one thing that could not be run

```
h=$(mktemp -d); env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE \
  -u WASM_AGENT_VAULT_PASSPHRASE -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN -u WASM_AGENT_RAW_CODE -u WA_MESH \
  WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=$h WA_COMPONENTS_DIR=$h/.wasm-agent/components \
  WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT=scripts/<row>.lua \
  timeout 180 wa --db $h/t.db
```

The Lua under test is this tree's (`WASM_AGENT_LUA_ROOT=$PWD`). `scripts/fast.sh` itself could not be run:
its first act is to build this tree's `wa` with cargo, and **this node has no Rust toolchain** —
`cargo --version` answers `bash: line 1: cargo: command not found`, there is no `~/.cargo` and no
`rust/target`. So the rows below were run one by one against the installed node binary (`wa` 0.1.0), which
loads the tree's Lua. That is enough for every item whose code is Lua or Node, and it is why items 6–8 are
not delivered (see the end).

## Results

| # | test | before (HEAD 74d48431) | after |
|---|------|------------------------|-------|
| 1 | `scripts/test-codeact-default.lua` | `ITEM 1: a run block written with a tilde fence runs (ran 0 script(s), reply Running.` | `{"checks":12,"ok":true,"paid_calls":0}` |
| 2 | `scripts/test-codeact-default.lua` | `indented 4 spaces run ok=true calls=0 toolrows=0 reply=do it ```js run return 4; ``` ` (turn answered, 0 tools, rc 0) | `! run_block_not_executed: the ```js run block at line 2 did not run: it is indented 4 spaces…` / `1 round · 0 tools · 0.2s` / `wa: session … failed` |
| 3 | `scripts/test-session-worktree-status.lua` | `ITEM 3: status answers with one line: {"session_id":"cd3164fc…","workspace":{"base_commit":"","branch":"","error":"","required":false,…"state":"unbound",…}}` | `{"checks":15,"ok":true}` |
| 4 | `scripts/test-wave-registration-refusal.lua` | `attempt to call a nil value (field 'wave_admission_outcome')` | `{"checks":12,"ok":true}` |
| 5 | `scripts/test-run-claim-release.lua` | `ITEM 5: and says so in an audit line: nil` | `{"checks":9,"ok":true}` |
| 6 | — | not delivered: needs cargo (see below) | — |
| 7 | — | not delivered: needs cargo | — |
| 8 | — | not delivered: needs cargo | — |
| 9 | `scripts/test-runtime-binding-preflight.mjs` | `Error: ITEM 9: it names the canonical path: exactly one canonical main checkout is required; no actor tree was moved` | `{"ok":true,"checks":8}` |

## What each fix is

### 1. The default mode acts, and a run block always runs — `lua/core/raw_code.lua`, `lua/core/agent.lua`, `lua/core/tools.lua`

- `M.parse` reads a fence of 3+ backticks **or 3+ tildes** (CommonMark), `M.retag` re-tags both, and `M.take`
  no longer early-outs on a backtick search: a `~~~js run` block used to become the turn's answer.
- The run block is read whenever the **mode** is on (`raw_code.mode() ~= nil`), not only when code mode
  happens to be ready. With code mode off the block becomes the `codemode` call it stands for and dispatch
  answers it by name (`codemode_not_enabled`) instead of the text surviving as the answer.
- `M.only(policy)` is policy-aware, so the empty declared surface is only used where the channel can run a
  block: with code mode unavailable a session used to declare **nothing** and refuse to start
  (`no_dispatchable_tools`) while its ordinary tools were there all along.

### 2. A turn that ends with an unexecuted action fails, by name — `lua/core/agent.lua`, `lua/core/raw_code.lua`

`raw_code.unexecuted(text, mode)` finds a run-block attempt the parser never turned into a call (a 4-space
indented block, a block inside another block, an unclosed one). The loop raises
`run_block_not_executed: the ```js run block at line N did not run: <why>; write it at the start of a line…`,
writes the failed assistant row and the failure record, so `wa chat --once` exits non-zero.

### 3. `session_worktree status` in one line, and not offered where it has nothing to say — `lua/core/workspaces.lua`, `lua/core/tools.lua`

- `workspaces.status_line(memory, id)` is the one implementation of the sentence: what is bound and what to
  do next (`no workspace required: this session's tools run in the node's own directory; nothing to bind…`,
  `workspace allocated: <path> on branch <b> (base <sha>); nothing to bind - work there`,
  `workspace failed: <reason>; next: fix that cause, then session_worktree action=allocate`). `status` returns
  it as `status_line` beside the old fields.
- `tools.envelope` stops offering `session_worktree` to a session with no managed workspace and no bound
  path. It stays in the catalogue (`searchTools` finds it, `callable=false`), so it is out of sight at the top
  level, not out of reach — the rule the outer facades already follow (29/10).

### 4. No wave registration: the reason and the one command; the operator session works in place — `lua/core/workspaces.lua`, `docs/WAVE-CONVERGENCE.md`

- `workspaces.wave_admission_outcome(reason, {operator_session})` is the single verdict used by both admission
  sites. An absent authority (`wave_registration_required`) appends the fix:
  `… register the repository with node scripts/wave-entry.mjs register <repo> <wave-config.json> <attestation.json>`.
- A **top-level operator session** (no parent, no fork parent, not a subagent) on a node with no wave
  authority is admitted in place; the binding records `start_state.wave_admission = absent_operator_in_place`
  and the journal keeps the fact. A child still refuses, because a shared wave with no owner cannot say who
  may land.
- `docs/WAVE-CONVERGENCE.md` gains the section "No registration on a node: what a session does (18/11)".

### 5. A settled run releases its claim; a stale claim is reclaimed with an audit line — `lua/core/agent.lua`, `lua/core/resources.lua`

- The release no longer depends on the uncertainty write: `resources.finish` is called on every path, and a
  failed uncertainty write is reported beside it instead of standing in for it. A failed run whose uncertainty
  write failed used to keep `session:<id>` claimed, so the next `--resume` was answered `run_resource_refused`.
- `resources.begin` returns `reclaimed` and an `audit` line (`run lock reclaimed: session:<id> was held by run
  <run> (principal <p>), which is no longer running; no effect was replayed`), which the run emits as a status
  line and a telemetry event.

### 9. The canonical runtime binding is decided in preflight, and names both paths — `scripts/runtime-install-binding.mjs`, `scripts/deploy.sh`

- The refusal lists every worktree on branch main: `exactly one canonical main checkout is required; found 2 on
  branch refs/heads/main (/a, /b) - a runtime binding is installed from exactly one tree, so remove or re-point
  the extra checkout(s); no actor tree was moved`.
- `scripts/deploy.sh` resolves the binding before the first `cargo build` (fail: `canonical runtime binding
  refused before anything was built: …`), exports `WA_RUNTIME_WORKTREE` so the installing phase does not decide
  it again, and the test asserts the ordering inside the script as well as the message.

## Not delivered: items 6, 7, 8 (Rust, no toolchain on this node)

All three live in Rust and both a fix and a failing-then-passing test need a compiler:
`rust/wa-sentinel/src/main.rs` (6: `request withdraw <id>`; 7: the once-per-`(id, error)` return-observation log
line at `main.rs:3007`), and `rust/wa-mesh` (8: `cache.rs`/`seam.rs` — the roster's `addresses` must never take
the rendezvous URL, and `state.service` is the relay). Measured impossibility on this node:

```
$ cargo --version
bash: line 1: cargo: command not found
$ ls ~/.cargo /root/.cargo
ls: cannot access '/home/victor/.cargo': No such file or directory
ls: cannot access '/root/.cargo': Permission denied
```

I did not write Rust I could not compile: an uncompilable commit is worse than a named gap, and the mission's
rule is the measured impossibility over a claim. The reading I did is recorded here so the next session starts
from it: the withdraw verb belongs beside the existing `request` verbs (queued/held may be moved, a claimed
one may not, one audit line), and the log-spam fix is a seen-set of `(id, error)` in the watcher loop with the
entry retired or quarantined after the first report.

## Regression rows run against this tree's Lua (all green)

```
test-raw-code            {"checks":34,"ok":true,"paid_calls":0}
test-raw-first           {"checks":47,"ok":true,"paid_calls":0}
test-raw-native          {"checks":23,"ok":true,"paid_calls":0}
test-codemode-default    {"checks":39,"ok":true,"paid_calls":0,"rounds":2}
test-codemode-blocks     codemode blocks ok (31 checks)
test-codemode-boundary   {"checks":33,"ok":true}
test-envelope            envelope ok (96 checks)
test-toolname-repair     toolname repair: 33 checks, 0 failed, 0 skipped
test-resume-tool-registry resume tool registry: 77 checks
test-prompt-tool-names   prompt tool names ok (286 checks, 0 skipped)
```

`scripts/test-codemode-boundary.lua` went red on the first version of item 3 — hiding `session_worktree` in
the catalogue made a codemode member disappear instead of refusing it — and is green again with the hide
moved to the offered envelope, which is the narrower fix the item asked for.

## What was not verified

- The full `scripts/fast.sh` suite (and the gate): both build the tree's `wa` with cargo; no toolchain here.
- Items 6, 7, 8: no code, no test run.
- Nothing was deployed, pushed or run against a real node: this branch only.