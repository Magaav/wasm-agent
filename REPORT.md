# harness-fixes — measured 18/11 on avell (node-63c4dad7) and work (14963b6f)

Branch `change/harness-fixes`, base origin/main `74d48431`. Nothing pushed; no real node state touched:
every row runs in its own `mktemp -d` home with no rendezvous, no relay and no vault, and each row stubs the
provider stream (no paid call).

Three sessions' work is recorded here, in the order it was measured: round 1 and round 2 on
change/harness-fixes, items 6-8 on change/harness-fixes-rust, and - at the end - the integration that
merged the two branches into change/harness-land and the full re-run of every row both of them named.

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

> Delivered later, on a node with a toolchain - see "Items 6, 7, 8 - delivered" below. The text stays as it
> was written: it is what this session measured, and why it could not measure the rest.

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

---

# Round 2 — independent review of `62c3c064` (measured 18/11 on avell)

Seven findings. Each is fixed here with a row that **fails on 62c3c064 and passes on this commit**; the
"before" column was measured by unpacking the old commit into `/tmp/hf-before` (`git archive 62c3c064 | tar -x`)
and running the *same* row against it with `WASM_AGENT_LUA_ROOT=/tmp/hf-before`. Nothing pushed, nothing
deployed, no node state touched: every row runs in its own `mktemp -d` home with the provider stubbed.

## How the rows were run

```
h=$(mktemp -d); env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE \
  -u WASM_AGENT_VAULT_PASSPHRASE -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN -u WASM_AGENT_RAW_CODE -u WA_MESH \
  WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=$h WA_COMPONENTS_DIR=$h/.wasm-agent/components \
  WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT=scripts/<row>.lua \
  timeout 300 wa --db $h/t.db
```

`cargo` **is** on this node now (`cargo 1.100.0`, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/mission`), so
the round-1 note "this node has no Rust toolchain" no longer applies — but this round changes no Rust, and every
row is Lua, shell or Node, so no build was run. Nothing here is a claim about a compiled change.

## Results

| # | finding | row | on 62c3c064 | now |
|---|---------|-----|-------------|-----|
| 1 | BLOCKER: remote sessions and any principal counted as the operator | `scripts/test-wave-operator-session.lua` | `ITEM 4 (allocated): a remote session: it does not skip wave admission` | `{"checks":28,"ok":true}` |
| 2 | BLOCKER: the operator path crashes while allocating; "in place" is false | `scripts/test-wave-operator-session.lua` | `workspaces.lua:409: attempt to index a nil value (global 'start_state')` | same row, green (case 4) |
| 3 | BLOCKER: with code mode off every plain js-fenced sample became a failing codemode call | `scripts/test-raw-code-answer.lua` | `ITEM 1: the sample is not dispatched as code (dispatched 1)` | `{"checks":11,"ok":true,"paid_calls":0}` |
| 4 | `unexecuted` failed normal answers (an md example, a list item's fence, a plain js fence under `only`) | `scripts/test-raw-code-answer.lua` | `ITEM 2: an example inside a md block does not fail the answer: run_block_not_executed: … line 6 …` and `ITEM 2: a fence inside a list item …: it is indented 4 spaces` | same row, green (cases 2 and 3) |
| 5 | deploy no longer re-checks the runtime binding before install | `scripts/test-deploy-runtime-recheck.sh` | `ITEM 9: the preflight answer is not kept in WA_RUNTIME_PREFLIGHT` | `deploy runtime re-check ok (11 checks)` |
| 6 | a failed uncertainty mark is silent when the release succeeds | `scripts/test-run-claim-release.lua` | `ITEM 5: a failed uncertainty mark is reported on its own …` | `{"checks":10,"ok":true}` |
| 7 | the real-host end-to-end claim test was replaced by a fake host | `scripts/test-run-claim-release-live.lua` (restored) | file absent (deleted by 62c3c064) | `ok run-claim-release: 7 checks` against the real claim store |

Findings 1 and 2 are one row because they are one function: `ensure` decides who is admitted and then runs the
allocation that admission allows, and the old code crashed in the second half before the first could be
observed for the operator itself.

## What each fix is

### 1 + 2. Who is the operator, and does the operator path survive? — `lua/core/workspaces.lua`

`operator_session` required three facts and read one of them:

- `objective` was read as `~= 'subagent'`, which admits every other value — including `remote`, the objective
  `lua/core/session_watch.lua` gives a session **another node** started. That session is the other node's
  operator asking over the mesh, and it skipped wave admission on this node's shared repository. Only an empty
  objective is this node's own conversation.
- `user_id` was never read at all, so a root session of **any** principal was the operator as far as the rule
  could tell. It is now the node's owner principal (`users.json` `default_user`, `master` out of the box, read
  through `lua/core/users.lua`), and an unreadable owner admits nobody (`node_owner()` returns nil → false).
  This is the same rule `memory.ensure_session` already applied from the other side, when it refuses to hand a
  `remote` thread to a local `wa chat`.

The allocation path set `start_state.wave_admission` **before** `local start_state` existed: the one path the
exception is for died with `attempt to index a nil value (global 'start_state')` (measured, above), and the
table built four lines later would have dropped the fact anyway. The decision is now carried in a local
(`absent_admission`) and written **after** the table exists.

The verdict no longer says "works in place", which was false at both call sites — the session gets its own
linked worktree, never the source checkout. It says `proceeds unregistered - it still works in its own linked
worktree, never in the source checkout`, the verdict's field is `unregistered`, the binding records
`start_state.wave_admission = "absent_operator_unregistered"` (was `absent_operator_in_place`) and the journal
keeps `{unregistered=true, reason=…}`. `docs/WAVE-CONVERGENCE.md` says the same three facts, and
`scripts/test-wave-registration-refusal.lua` asserts the wording and the field.

### 3 + 4. A normal answer is not an action — `lua/core/raw_code.lua`, `lua/core/agent.lua`

- `M.take(result, stop_sent, policy)`: the re-tag of an untagged ```js fence now asks `M.only(policy)`, not
  `M.mode()`. `only` is the default **mode** on every node, including one whose code mode is `off`; there the
  re-tag turned every ordinary sample in an answer into a codemode call, and dispatch refused it
  `codemode_not_enabled`. Outside `only(policy)` only a block the model itself tagged `js run` acts.
- `M.unexecuted(text, policy)`: it scanned **every line**, inside other blocks included. It now decides with
  `M.parse` (a fence inside any parsed block is that block's text — a ```js run example inside a ````md block),
  skips a fence inside a list item (`list_content_column`: a fence up to three spaces inside its container is
  valid CommonMark), and asks the policy for the `only` clause. What is left is the miss the check exists for:
  a fence the parser could have seen and did not (indented 4+ spaces at the top level, unclosed) still fails
  the turn by name — case 4 of the row proves the guard was not simply switched off.

### 5. Deploy re-checks the binding after the build — `scripts/deploy.sh`, `scripts/lib/runtime-binding.sh`

The preflight exported `WA_RUNTIME_WORKTREE`, so the install-time block read a value that was already set and
skipped itself: the "clean and equal to main" re-check after the build — the half that catches a second worktree
appearing while cargo ran — was gone, silently. Now the preflight answer is kept in `WA_RUNTIME_PREFLIGHT` and
not exported; step 6 asks the binding script again, and `wa_runtime_binding_recheck` (new, shipped beside
`deploy.sh` by `ship_file`, and sourced by the same loop as the other libs) refuses when the two answers differ,
naming both and saying nothing was installed. An operator who sets `WA_RUNTIME_WORKTREE` explicitly still
chooses it: no preflight answer, nothing to compare.

### 6. A failed uncertainty mark is said out loud — `lua/core/agent.lua`

When `resources.uncertain` failed and `resources.finish` succeeded, nobody heard it: `finish` deleted the claim
**and** its uncertainty, and the sentence "both facts are reported" was false. The uncertainty failure now emits
its own `resource_uncertain_failed` error event (and a `run/uncertain_failed` telemetry event) before the
release, which still runs on every path.

### 7. The real-host claim test is back — `scripts/test-run-claim-release-live.lua`

62c3c064 replaced the end-to-end test with a fake host whose `reconcile` frees the key unchecked. That fake is
worth keeping — it can inject a **failed** uncertainty write, which the real store will not do on demand — so
both live side by side: the fake-host row in `scripts/test-run-claim-release.lua`, and the real-host row
restored verbatim under its own name. It passes here: the failed turn released `session:<id>`, the next run's
claim was admitted, and the guard's stop released it too (7 checks).

## Corrections to the round-1 section above

- §4 said the operator session "works in place" and the binding records `absent_operator_in_place`: both were
  wrong and are fixed in round 2 (finding 2). The recorded value is `absent_operator_unregistered`, and the
  session works in its own linked worktree.
- §9 said `deploy.sh` "exports `WA_RUNTIME_WORKTREE` so the installing phase does not decide it again". That
  export is exactly what removed the install-time re-check; it is gone (finding 5).
- §2 said `unexecuted` "finds a run-block attempt the parser never turned into a call (a 4-space indented block,
  a block inside another block, an unclosed one)" — the middle case was a false positive on the model's own
  prose; the rule is now "a fence outside every parsed block, not inside a list item" (finding 4).
- §1's "the block is answered by name (`codemode_not_enabled`)" still holds for a block the model **tagged**
  `js run`; it no longer happens to an untagged sample in an answer (finding 3).

## Regression rows run against this tree's Lua (all green)

```
test-wave-operator-session      {"checks":28,"ok":true}
test-raw-code-answer           {"checks":11,"ok":true,"paid_calls":0}
test-run-claim-release         {"checks":10,"ok":true}
test-run-claim-release-live    ok run-claim-release: 7 checks
test-wave-registration-refusal {"checks":15,"ok":true}
test-codeact-default           {"checks":12,"ok":true,"paid_calls":0}
test-raw-code                  {"checks":34,"ok":true,"paid_calls":0}
test-raw-first                 {"checks":47,"ok":true,"paid_calls":0}
test-raw-native                {"checks":23,"ok":true,"paid_calls":0}
test-codemode-default          {"checks":39,"ok":true,"paid_calls":0,"rounds":2}
test-codemode-blocks           codemode blocks ok (31 checks)
test-codemode-promises         codemode natural promises ok (31 checks; real sandbox)
test-codemode-boundary         {"checks":33,"ok":true}
test-envelope                  envelope ok (97 checks)
test-toolname-repair           toolname repair: 33 checks, 0 failed, 0 skipped
test-session-worktree-status   {"checks":15,"ok":true}
```

Node/shell checks: `node scripts/check-deploy-shipped.mjs` (179 checks), `node scripts/check-deploy-docs.mjs`
(6 checks), `bash scripts/test-deploy-runtime-recheck.sh` (11 checks).

## What was not verified, and what is known red

- **The full deploy was not run** (it builds for minutes, installs and restarts the node). Finding 5 is proved in
  two halves: the comparison is executed case by case (`scripts/lib/runtime-binding.sh`), and the wiring in
  `deploy.sh` is asserted as structure — the preflight keeps its answer in its own variable, nothing exports
  `WA_RUNTIME_WORKTREE` before step 6, and step 6 calls the comparison with both answers after the install
  phase. Reaching step 6 for real is a build plus an install, which no test may do to this machine.
- `scripts/test-codemode-native.lua` is red here and red on `62c3c064` **and** on `62c3c064^` (origin/main
  `74d48431`) under this runner: `#tools.envelope == 11` is not what this environment produces (it produces 1,
  `codemode`). It is a proof-environment test (`WA_CODEMODE_PROOF_*`, `scripts/test-codemode-component.sh`), not
  a regression from this round, and I did not change it — editing the number without its proof environment
  would hide whatever it is meant to catch.
- The full gate (`scripts/fast.sh`) was not run: it builds and runs the whole suite, which is beyond this
  review's scope, and every file touched here is covered by a row above.
- Nothing was deployed, pushed or run against a real node: this branch only.

# Items 6, 7, 8 — delivered (18/11, this node, with cargo)

Base: branch `change/harness-fixes` 62c3c064, worktree `.../harness-fixes-rust/wt`, branch
`change/harness-fixes-rust`. Everything below was built and tested **on this node** (avell, 16 cores) with
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/mission`. Nothing was pushed; no real node state was touched
by a test (every fixture uses a `mktemp -d` home, and `WASM_AGENT_PORT=1` where a probe would otherwise
meet this machine's own node on 8799).

```
cd rust/wa-sentinel && cargo test                       # its own workspace
cd rust && cargo test -p wa-mesh-core -p wa-mesh        # the mesh crates
```

## Results

| # | test | before | after |
|---|------|--------|-------|
| 6 | `rust/wa-sentinel/src/withdraw_tests.rs` (5 tests) | `wa-sentinel request withdraw <id>` → `unknown request verb "withdraw"; no request was written`, rc 1, the request still in the box; `status` printed no id and no way out of a held request | `withdraw_tests`: 5 passed, 0 failed |
| 7 | `rust/wa-sentinel/src/observation_tests.rs` (6 tests) | on `work`: **523,067** `return-observation-problem` lines for 75 ids over 7 days, every one `No such file or directory (os error 2)` | `observation_tests`: 6 passed, 0 failed; one line per (id, problem), the directory retired |
| 8 | `wa-mesh-core/src/cache.rs` (2 tests) + `wa-mesh/src/seam.rs` (1 test) | `work`'s `mesh/peers.json`: `avell -> ["https://rendezvous.colmeio.com"]`, `source: "roster"`, `last_error: resolve_failed:invalid port value` | `wa-mesh-core`: 30 passed, 0 failed; `wa-mesh`: 74 passed, 2 failed (both fail identically on the untouched base) |

### 6. `request withdraw <id>` — a queued or held request leaves the queue; a claimed one is refused by name

`rust/wa-sentinel/src/main.rs` (`withdraw_request`, the `withdraw` branch of `request`, `next_step`,
`pending_lines`, the `withdrawn` lane in `sentinel_dir`), `withdraw_tests.rs` (new),
`publish_loop_tests.rs` (the status line it now prints).

Before — the installed 16/11 `wa-sentinel` (the base behaviour) on a scratch home with one queued request:

```
$ wa-sentinel request withdraw 1700000000000000000-4242-00000000000000000000 --reason "no longer needed"
  sentinel: unknown request verb "withdraw"; no request was written. The verbs are: restart, recover, wake, deploy, run, spell, stop
rc=1
--- the request is still in the box:
1700000000000000000-4242-00000000000000000000.json
--- and status says nothing about withdrawing it:
  requests:  1 waiting, 0 done, 0 failed
    waiting  restart  target: no commit recorded  queued 2023-11-14T22:13:20Z (1099d ago)  ready: the node is down, so there is nothing to interrupt; no watcher is running, so nothing would perform it
```

After — what the verb does, in the words the tests assert:

* a **queued or held** request is renamed `requests/<id>.json` → `sentinel/withdrawn/<id>.json` (kept, not
  deleted, byte-identical), the queue record says `state: "withdrawn"`, a pending deferral is cleared, and **one**
  audit line `withdraw<TAB><id><TAB><reason>` is written; a second withdraw answers `withdraw_not_queued: <id> is
  already in withdrawn/ …`; an id that names nothing `withdraw_unknown_request`; a malformed id
  `withdraw_request_id_invalid`; two ids `withdraw takes one request id`;
* a **claimed** request is refused by name, before anything moves: `withdraw_refused_claimed: <id> is claimed - the
  watcher is performing it now, and a request in flight is never withdrawn or replayed …`;
* a withdrawn **deploy** that named a session settles its durable outcome record (`deploy_outcome::settle`,
  outcome `failure`, detail "withdrawn by the operator before the sentinel performed it …"), so the session is told
  instead of the watchdog reporting the deploy *silent* an hour later —
  `withdrawing_a_deploy_settles_its_outcome_instead_of_leaving_it_silent`;
* `wa-sentinel status` now prints, for every waiting request, its **id** and both actions. Exact line (asserted
  by equality in `publish_loop_tests::a_waiting_request_is_one_line_of_facts`):

```
  waiting  deploy  target commit 0123456789abcdef0123456789abcdef01234567  queued 2023-11-14T22:13:20Z (2m ago)  held: node busy; next: end the turn (no further tool calls) so the node goes idle, and the next watcher tick runs it; or withdraw it: wa-sentinel request withdraw 1700000000000000000-4242-00000000000000000000
```

and for a request nothing holds the same line adds
`next: nothing blocks it: the next watcher tick runs it; or withdraw it: wa-sentinel request withdraw <id>`.

The five tests: `a_queued_request_is_withdrawn_once_with_one_audit_line`,
`a_claimed_request_is_refused_by_name_and_nothing_moves`,
`status_names_the_unblock_and_the_withdraw_for_a_held_request`, `every_other_answer_is_refused_by_name`,
`withdrawing_a_deploy_settles_its_outcome_instead_of_leaving_it_silent`.

### 7. The observation log is one line per (id, problem), then the entry leaves the lane

`rust/wa-sentinel/src/observation.rs` (new: the lane), `observation_tests.rs` (new), and the watcher
loop in `main.rs`, which now calls `observations.pass()` instead of auditing `return-observation-problem`
on every failed `sentinel_return::observe`.

The measurement, re-read on `work` today (`sentinel.log`, `awk` over the audit lines):

```
total 523067
distinct ids 75
first 1794344077
last  1794998822
```

and every one of the five directories the mission named is a **finished** deploy — a `result.json` saying
`ok: true` (installed 2199eaff on 11/11) with no `intent.json`, `ack.json` or `binding.json` at all — so the
observation could never succeed. The per-id poll backoff turned "every tick" into one line a minute per id,
which is 108,000 lines a day across the 75 ids and never stops.

The rule now, as a function (`observation::verdict`), tested without a watcher and without a clock:

* a **new** (id, problem) → one audit line, and the clock starts; a **changed** problem is new information and is
  said again; anything in between writes nothing at all (no repeat, no counter, no heartbeat);
* the problem is named: `cannot be observed: missing binding.json, ack.json, intent.json` — not a bare
  `No such file or directory (os error 2)`;
* a **structural** problem (the files intake writes are missing) that survives a grace period
  (`WASM_SENTINEL_OBSERVE_GRACE`, 300s by default) **retires** the directory: `deploy-protocol/<id>` →
  `deploy-protocol-retired/<id>`, one `return-observation-retired` line, nothing deleted, and no later pass
  observes it again. A **runtime** problem (`parent_owner_unavailable`, a disabled return hook) is retried and
  **never** retired — retiring a live deploy's directory would throw its report away to make a log quieter;
* what was said is kept on disk (`observation-problems.json`), because a watcher restarted every minute must not
  re-report every stale directory every minute — the same defect at a lower rate. A directory that disappears is
  forgotten, so a later request with that id does not inherit its silence.

```
running 6 tests
test observation_tests::a_missing_file_is_reported_once_however_many_ticks_go_by ... ok
test observation_tests::the_same_problem_past_the_grace_retires_the_directory ... ok
test observation_tests::the_rule_is_one_line_per_id_and_problem ... ok
test observation_tests::a_restarted_watcher_does_not_say_it_again ... ok
test observation_tests::a_directory_that_is_gone_is_forgotten ... ok
test observation_tests::a_runtime_problem_is_never_retired ... ok
test result: ok. 6 passed; 0 failed
```

Against the measured fixture (a directory holding only `result.json`): 50 ticks → **1** line, naming the three
missing files; with `WASM_SENTINEL_OBSERVE_GRACE=0` a second pass retires it, and 20 further passes write nothing.

### 8. A binding's `state.service` is never a peer's direct address

Cause, found by reading the node's own files: `rust/wa-mesh/src/client.rs` recorded the **relay** URL as the
peer's address when a relayed call succeeded —

```rust
self.cache.record_success(&target.node_id, relay, now_ms);   // relay = the binding's state.service
```

— and the peer cache's `addresses` are dialled *directly* first, so every call to that peer began with
`resolve_failed:invalid port value` before the relay carried it. On `work` today:

```
"999b87f068a92d132caf0a16ea094b84": {            # avell
  "addresses": ["https://rendezvous.colmeio.com"],
  "source": "roster",
  "last_ok_ms": 1794917636071,
  "last_error": "resolve_failed:invalid port value"
}
```

The fix, in one rule with three doors:

* `RosterNode::is_direct_address` (`wa-mesh-core/src/roster.rs`) — the same grammar the roster already refuses a
  bad address with when it is signed and verified, now reachable by the cache: `host:port`, nothing with a
  scheme, no bare host, port 1..=65535;
* `wa-mesh-core/src/cache.rs`: `push_address` (the one door every writer uses — roster, rendezvous, "a call that
  worked") refuses what is not a direct address, and `addresses()` skips one an **older** file already holds, so
  the poisoned `peers.json` measured above is not dialled either (nothing is deleted from the file by a read);
* `wa-mesh/src/client.rs`: a relayed success calls `record_relay_success` — it keeps the fact that the peer was
  reachable (`last_ok_ms`, `last_error` cleared) and adds no address;
* `wa-mesh/src/seam.rs`: `addresses` filters what it hands the `wa:mesh` component and what the component
  returns, so a component that answers faithfully cannot put a service URL back.

The tests — the first two at the rule, the third built from the measured file:

```
test cache::tests::a_service_url_is_never_a_peers_direct_address ... ok
test cache::tests::the_direct_address_rule_is_the_one_the_roster_signs_with ... ok
test seam::tests::a_service_url_in_the_peer_cache_is_never_handed_out_as_an_address ... ok
test result: ok. 30 passed; 0 failed                (wa-mesh-core)
test result: FAILED. 74 passed; 2 failed; 1 ignored (wa-mesh; the 2 are pre-existing, below)
```

## The suites, and the failures that were already there

Measured on this node. The "base" column is the same command with my changes stashed (`git stash push -u`), so the
comparison is the untouched 62c3c064 tree.

| suite | base | with items 6-8 |
|---|---|---|
| `cargo test` (wa-sentinel) | 110 passed, **5 failed** | 121 passed, **5 failed** (3 full runs: 121/120/121 passed) |
| `cargo test -p wa-mesh-core` | — | 30 passed, 0 failed |
| `cargo test -p wa-mesh` | 77 total, the 2 below fail | 74 passed, **2 failed**, 1 ignored (77 tests) |

The 5 wa-sentinel failures are identical in both columns:

```
deploy_outcome_tests::the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end
deploy_visibility_tests::a_failing_deploy_leaves_its_message_in_the_capture
node_script_tests::javascript_requests_run_native_node_and_preflight_before_any_operation
node_script_tests::job_run_prepare_and_pipeline_use_the_same_native_node_dispatch
role_tests::the_watcher_records_its_own_owner_where_a_later_stop_reads_it
```

The 2 wa-mesh failures are identical on the base too (measured by stashing; `t has not been pushed a roster yet`,
and the test relay answering `"unknown_caller"`):

```
tests_relay::a_caller_enabled_only_by_its_policy_reaches_the_roster_through_a_service_url
tests_relay::the_roster_decides_on_the_relay_path_too_and_an_existing_operator_bootstraps_it
```

Two rows are flaky under a full parallel run and are **not** settled by me:
`run_script_tests::run_script_interpreter_is_explicit_and_allowlist_precedes_it` and
`reap_tests::a_killed_unreaped_child_is_not_alive`. Each failed in some runs with my changes and not in others, and
`run_script` passes with `--test-threads=1`; they are timing-sensitive (an interpreter/allowlist window, a
kill-and-reap window), they do not touch the code of items 6-8, and the base full run did not show them. I did not
prove them innocent: the toolchain was gone before I could repeat the pair on the base.

## What happened to the toolchain, and one thing that was not mine

cargo was on PATH when the mission started (`cargo 1.100.0 (3acc79c0c 2026-11-05)`), and every number above was
produced with it. At about 08:07 local (-03) it disappeared from the machine: `command -v cargo` answers nothing,
`find / -name cargo` finds no toolchain, and neither `~/.rustup` nor `~/.cargo` exists. So the runs quoted here are
the ones made while it was there; nothing was rebuilt afterwards.

At 08:08:47 something **outside this session** ran `git stash push` in this worktree (a stash named
`harness-fixes-rust WIP`), and a build in this tree at 08:09-08:12 replaced the test binaries with ones built from
the stashed (pre-change) sources. I recovered the work with `git stash apply stash@{0}` and checked every changed
file before committing; the diffs are the ones measured above. Anyone else using `.../harness-fixes-rust/wt` should
know the tree was moved under it once.

## What was not verified

* The full `scripts/fast.sh` suite and the release gate: not run. They build the tree's `wa` with cargo, which is
  gone. The mission asked for `cargo test -p <crate>` for the crates touched plus the fast suite; the crate suites
  are quoted above, the fast suite is not.
* Nothing was rebuilt, re-tested or re-measured after 08:07 (no toolchain), including the two flaky rows above.
* Items 6 and 7 have no "fails on the base commit" *test run* to quote: their tests call a function and a module
  that do not exist before the fix, so they would not compile there. The before behaviour is measured instead —
  the installed 16/11 binary's refusal for item 6, and the live 523,067-line measurement on `work` for item 7.
  Item 8's cache and seam tests do compile against the base and are red there (the service URL is returned as a
  direct address, which is what the failing rows above and the measured file show).
* Nothing was deployed or pushed: this branch only, committed locally.

# Second pass — falsification of each item, the base-vs-after counts, and two holes item 8 still had

Same day, same node (avell), same base 62c3c064. The section above ("Items 6, 7, 8 — delivered") was
written by a session that ran **in this same worktree at the same time as this one**; that is worth
recording, because it cost a measurement: a `git stash` taken here to measure the base was raced by the
other session's changes, and the "base" run came back with the new modules in its test list. The base row
below was re-measured with the source state verified by `grep` before the run
(`grep -c 'mod withdraw_tests' main.rs` → 0 and `grep -c is_direct_address roster.rs` → 0), and the
contaminated run was thrown away. Two sessions in one worktree can stash and pop each other's files; the
number that survived is the one whose source state was checked.

## The base, re-measured

| suite | base 62c3c064 (stashed, verified) | this change |
|-------|----------------------------------|-------------|
| wa-sentinel, `cargo test --manifest-path wa-sentinel/Cargo.toml -- --test-threads=1` | 110 passed, **5 failed** | 121 passed, the **same 5 failed** |
| wa-mesh-core, `cargo test -p wa-mesh-core` | — | **29** passed, 0 failed (the row above says 30; this run does not reproduce it) |
| wa-mesh, `cargo test -p wa-mesh --lib` | 72 passed, **2 failed** (76 total) | 74 passed, the **same 2 failed** (77 total) |

The five wa-sentinel failures, pre-existing and named so nobody looks for them again — they fail
identically on the stashed base:

~~~
deploy_outcome_tests::the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end
deploy_visibility_tests::a_failing_deploy_leaves_its_message_in_the_capture
node_script_tests::javascript_requests_run_native_node_and_preflight_before_any_operation
node_script_tests::job_run_prepare_and_pipeline_use_the_same_native_node_dispatch
role_tests::the_watcher_records_its_own_owner_where_a_later_stop_reads_it
~~~

The two wa-mesh ones, also pre-existing (stashed base: 2 passed, 2 failed — the same two):

~~~
tests_relay::a_caller_enabled_only_by_its_policy_reaches_the_roster_through_a_service_url
  relay_answer_unreadable:unknown field 'error', expected one of 'schema','ts','from_node_id','reply','signature'
  raw_head={"error":"unknown_caller"}   -> left "mesh_relay_failed", right "mesh_refused"
tests_relay::the_roster_decides_on_the_relay_path_too_and_an_existing_operator_bootstraps_it
  t has not been pushed a roster yet
~~~

## Each item's test, falsified: it fails without the fix

Keep the test, disable exactly the guard the fix adds, run the test, restore the file. After the four
runs the tree was byte-identical to before them (`git diff | sha256sum` =
1f17d8d2e9b79c3bd59b93f898f30df8a08c9da325d7739ad694c9e3e3c3d829, before and after).

### 6 — without the claimed-lane refusal, without next_step

~~~
--- disable the claimed check in withdraw_request (if false {):
thread 'withdraw_tests::a_claimed_request_is_refused_by_name_and_nothing_moves' panicked at src/withdraw_tests.rs:124:5:
the refusal names the state: withdraw_unknown_request: no request 1700000000000000000-4242-00000000000000000000 is queued; nothing was moved and 'wa-sentinel status' lists the ids that are
test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 125 filtered out

--- drop the next-step clause from pending_lines (the status line as it was):
thread 'withdraw_tests::status_names_the_unblock_and_the_withdraw_for_a_held_request' panicked at src/withdraw_tests.rs:147:5:
the line names the request the operator has to name:   waiting  deploy  target commit 0123456789abcdef0123456789abcdef01234567  queued 2023-11-14T22:13:20Z (2m ago)  held: node busy
test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 125 filtered out
~~~

The same three commands measured on a scratch home with the base binary built from the stash and with
this tree's binary (WASM_AGENT_HOME=/tmp/sentinel-cli-home, one queued deploy):

~~~
BEFORE  wa-sentinel status
  requests:  1 waiting, 0 done, 0 failed
    waiting  deploy  target commit 0123456789abcdef0123456789abcdef01234567  queued 2023-11-14T22:13:20Z (1099d ago)  held: node busy; no watcher is running, so nothing would perform it
BEFORE  wa-sentinel request withdraw 1700000000000000000-4242-00000000000000000000 --reason no-longer-needed
  sentinel: unknown request verb "withdraw"; no request was written. The verbs are: restart, recover, wake, deploy, run, spell, stop
  rc=1     lanes after: requests: 1700000000000000000-...json   withdrawn: (does not exist)
BEFORE  wa-sentinel request --help | grep -c withdraw   ->  0

AFTER   wa-sentinel status
    waiting  deploy  target commit 0123...4567  queued 2023-11-14T22:13:20Z (1099d ago)  held: node busy; no watcher is running, so nothing would perform it; next: end the turn (no further tool calls) so the node goes idle, and the next watcher tick runs it; or withdraw it: wa-sentinel request withdraw 1700000000000000000-4242-00000000000000000000
AFTER   wa-sentinel request withdraw 1700000000000000000-4242-00000000000000000000 --reason no-longer-needed
  withdrawn deploy 1700000000000000000-4242-00000000000000000000: moved to /tmp/sentinel-cli-home/.wasm-agent/sentinel/withdrawn/1700000000000000000-4242-00000000000000000000.json; no watcher tick can claim it now
  rc=0     lanes after: requests: (empty)   withdrawn: 1700000000000000000-...json
AFTER   wa-sentinel request --help | grep -c withdraw   ->  1
~~~

### 7 — with the old rule (audit on every pass), and with no grace

~~~
--- Verdict::Quiet audits again (what the watcher did on every tick):
thread 'observation_tests::a_missing_file_is_reported_once_however_many_ticks_go_by' panicked at src/observation_tests.rs:91:5:
one problem, one line - not one per tick: [... 50 identical lines for one id ...]
50 occurrences of "cannot be observed: missing" in that one failure - one per tick, the measured defect
at 1/10000 the scale of work's 523,067 lines
test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 125 filtered out

--- retire on the first report instead of after the grace:
thread 'observation_tests::a_missing_file_is_reported_once_however_many_ticks_go_by' panicked at src/observation_tests.rs:98:5:
nothing is retired inside the grace
test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 125 filtered out
~~~

The old code path, for the record (main.rs, the watcher tick before this change) — one audit line per
directory per tick, forever:

~~~
if let Err(error)=sentinel_return::observe(id) {audit("return-observation-problem",id,&error.to_string());}
~~~

### 8 — with the store's rule removed

~~~
--- push_address accepts anything again (the rule disabled):
thread 'cache::tests::a_service_url_is_never_a_peers_direct_address' panicked at wa-mesh-core/src/cache.rs:386:9:
a service URL is not an address: ["https://rendezvous.colmeio.com"]
test result: FAILED. 4 passed; 1 failed; 0 ignored; 0 measured; 24 filtered out
~~~

## Two holes item 8 still had, closed in this commit

The first pass claimed "the one door every writer uses". Reading every write while measuring found two
paths around it, both now closed and both asserted:

1. **An unknown peer.** `PeerCache::record_success` has a branch for a node the cache has never seen, and
   it inserted `addresses: vec![address]` directly, without the rule — so the first answer from a new
   peer arriving at a service URL would store the URL where the checked doors would have refused it. It
   now builds the entry and calls `push_address`. The test walks it:
   `record_success(unseen, "https://rendezvous.colmeio.com:443")` keeps `last_ok_ms` and stores no
   address (`a service URL is not an address, not even for a peer seen once`).
2. **A scheme with an explicit port.** `is_direct_address` delegated to the roster's `check_address`,
   which reads the **last** colon: `"http://10.0.0.4:8891"` satisfies `host:port` while naming a URL, and
   a relay written as `https://rendezvous.colmeio.com:443` is exactly that shape. The rule now refuses a
   scheme before the shape, and then requires the alphabet of an address
   (`[A-Za-z0-9.:-_[]%]`) so a path separator cannot pass as a host. Asserted in
   `the_direct_address_rule_is_the_one_the_roster_signs_with`: `http://10.0.0.4:8891`,
   `https://rendezvous.colmeio.com:443` and `10.0.0.4:8891/path` are not direct addresses.

## The fast suite

`bash scripts/fast.sh --jobs 8` on this node, this tree. Its first acts are what the earlier section
could not do at all: it built this tree's `wa` with cargo and stamped it —

~~~
fast: binary /home/victor/wasm-agent/target/mission/release/wa (build 2d2c0e2dfe3d, tree 2d2c0e2dfe3d, fresh: built from this tree) sha256=af18f880f020
fast: env: node v26.13.1 (node:sqlite yes), cargo 1.100.0, wasi-sdk absent, lua 5.4.9
fast: components SKIPPED (graph hooks memory selfloop mesh codemode svc-echo): error: component graph needs wasi-sdk (C inside); set WASI_SDK=<dir>
~~~

```
fast: lua 218/224 passed (56 excluded: scripts/fast-path.exclude)
fast: 43 named skip(s) inside passing rows
fast result FAILED (257 checks, 14 failed, 0 skipped)
fast path FAILED (14 of 257 checks, 0 skipped, 297s)
```

re-run on the committed tree (e658eebf, after the two holes above were fixed and committed), so the
binary the rows run is built from this commit and nothing is uncommitted:

~~~
fast: env: root .../wt at e658eebf on change/harness-fixes-rust; binary .../release/wa (sha256 3644c9bc07c6...)
fast: components SKIPPED (graph hooks memory selfloop mesh codemode svc-echo): wasi-sdk absent
fast result FAILED (257 checks, 14 failed, 0 skipped)
fast path FAILED (14 of 257 checks, 0 skipped, 147s)
~~~

The same 14 both times, with the same names - which is what makes them a property of the base and the
machine rather than of one run.

All 14, classified, with how each was decided:

| check | verdict |
|-------|---------|
| 6 Lua rows: test-codemode-model-boundary, test-host-return-docs, test-orchestration-mode, test-observability, test-remote-call-shape, test-skill-discovery | **pre-existing on 62c3c064.** Re-run one by one against the **installed** node binary (build 2e6fab41, not this tree's) with this tree's Lua, so the binary is not the cause: all six fail identically ("mode-on declares subagent and route_task from the start", "opt-in short index retains every full tool schema", "ripgrep shell fallback disclosure rule", "preamble guideline in the progressive prompt", "host return docs: 1 of 10 checks failed", "MODEL_BOUNDARY_CONTENT_REQUIRED"). This branch changes no lua/, scripts/ or docs/ file (`git diff --stat 62c3c064 HEAD -- lua scripts docs` is empty), so those rows run the same bytes as the base |
| rust wa-sentinel: the 5 tests named above | **pre-existing**, measured on the stashed base (110/5 → 121/5, same five) |
| rust wa-mesh: the 2 relay tests named above | **pre-existing**, measured on the stashed base (2 passed / 2 failed, the same two) |
| prompt-docs (stale generated blocks: docs/ENVELOPE.md tool-catalogue) | **pre-existing**: docs/ and lua/ are identical to the base commit |
| orphan-tests (scripts/test-runtime-binding-preflight.mjs orphaned) | **pre-existing**: that file is 62c3c064's (item 9 of the section above), which declares no harness entry |
| publish-artifacts | **the check, not the branch**: it compares `ls-tree | sort` in the ambient locale against a list written in C order. LANG=en_US.UTF-8 here, so `sort` answers "node-2d2c0e2dfe3d.manifest PUBLISH.sh ..." while the expected string starts "PUBLISH.sh SHA256SUMS ..."; with `LC_ALL=C` the same two names sort the other way round. Nothing in this branch touches releases/ |
| land-signing | **the machine**: WA_RELEASE_SIGN_DEFER=1 and no vault here, so there is no signature to publish (the row says so itself) |
| fast-binary (`build e658eebf5b90 is not this tree (3870cdd35c24)`) | **pre-existing**: this row is `scripts/test-fast-binary.mjs`, a self-test of the binary planner over a fixture repo (it writes `lua/core/agent.lua` into a clone and asks that the refusal name the file it saw). The assertion that fails is `and names a file it saw`: the planner answers "build <commit> is not this tree (<tree>)" instead of naming the uncommitted file. It is not about this worktree - the first run said it while the tree was dirty, the re-run said it with a clean tree committed at the very commit the binary was stamped with, and `scripts/` is byte-identical to the base commit |
| component-pins | **open, and the only one that is ours to answer.** rust/components/mesh declares `wa-mesh-core = { path = "../../wa-mesh-core" }`, so a change to wa-mesh-core is a change to a pinned component's inputs and components.lock's mesh pin (42872bbc..., 209612 bytes) must move. Rebuilding it needs wasi-sdk, which this node does not have (`WASI_SDK` unset, no wasi-sdk directory, and the suite reports "components SKIPPED (graph hooks memory selfloop mesh codemode svc-echo): error: component graph needs wasi-sdk"). I did **not** write `Components-Unchanged: mesh ...`: I cannot show the guest's bytes are the same, and a trailer that says so would be a claim I did not measure. So the pin is stale until someone with wasi-sdk runs `scripts/publish-components.sh` for mesh |

## What is still open

- **The mesh component pin** (above): the only landing gate this change leaves red for a real reason, and it
  cannot be cleared on this node.
- The 13 other failures are pre-existing on 62c3c064 or properties of this machine, each named above; none
  is fixed here, because none is item 6, 7 or 8. Seven of them (the wa-sentinel five, the wa-mesh two) were
  also measured directly against the stashed base, not only read from this run.
- Nothing was pushed, deployed or run against a live node or watcher; every row is a scratch home.


---

# Integration — `change/harness-land` (18/11, avell, this node)

One landable branch out of two: `change/harness-fixes` at `e31704d1` (round 1 `62c3c064` + round 2), with
the three commits of `change/harness-fixes-rust` cherry-picked onto it. Nothing else was added, and nothing
in the tree changed except `REPORT.md` and the one orphan row below.

```
git log --oneline -6        # change/harness-land
be6cdb91 harness: the runtime binding preflight is a row of the fast path, not an orphan
ec62cf4c REPORT: the fast suite re-run, and fast-binary classified as the runner's self-test  (was 91bd2380)
d85f9347 harness-fixes 6-8, second pass: the direct-address rule holds for an unknown peer …   (was e658eebf)
6c2a4bdd harness-fixes items 6-8: request withdraw, one observation line per (id, problem) …   (was 2d2c0e2d)
e31704d1 harness-fixes round 2: a remote session is not the operator, …
62c3c064 harness-fixes: default CodeAct acts, …      # the common base of both branches
```

`REPORT.md` was the only file both branches touched, and both appended after the same line 141. The
conflict was resolved by keeping round 2's report whole and appending items 6-8's sections behind it, so the
document reads: round 1 (items 1-5, 9), round 2, items 6-8 (delivered), items 6-8 second pass, this
integration. No paragraph of either report was dropped; the round-1 section "Not delivered: items 6, 7, 8"
stays, with a pointer to the section that delivers them, because that is what that session measured.

## How the base was measured — a detached worktree, not `git stash`

`git worktree add --detach /tmp/hl-base 62c3c064`, own `CARGO_TARGET_DIR`
(`/home/victor/wasm-agent/target/m-harness-land-base`). A stash in this worktree can no longer reach the
base — the cherry-picks are **committed**, so `git stash` leaves `HEAD` with items 6-8 in it. The second
pass above also lost one measurement to a stash raced by another session in the same worktree, and this node
was running three other missions while this one measured (`release-glibc`, `vault-one`). The base state was
verified before every base run, not assumed:

```
$ grep -c 'mod withdraw_tests' rust/wa-sentinel/src/main.rs   -> 0
$ grep -c is_direct_address rust/wa-mesh-core/src/roster.rs    -> 0
$ ls rust/wa-sentinel/src/observation.rs                       -> No such file
```

## Every row either branch named, re-run against this branch

Lua rows, each in its own `mktemp -d` home, this tree's Lua (`WASM_AGENT_LUA_ROOT`), no rendezvous, no
relay, no vault, provider stubbed — the same runner the sections above used:

```
test-codeact-default           {"checks":12,"ok":true,"paid_calls":0}
test-session-worktree-status   {"checks":15,"ok":true}
test-wave-registration-refusal {"checks":15,"ok":true}
test-run-claim-release         {"checks":10,"ok":true}
test-wave-operator-session     {"checks":28,"ok":true}
test-raw-code-answer           {"checks":11,"ok":true,"paid_calls":0}
test-run-claim-release-live    ok run-claim-release: 7 checks
test-raw-code                  {"checks":34,"ok":true,"paid_calls":0}
test-raw-first                 {"checks":47,"ok":true,"paid_calls":0}
test-raw-native                {"checks":23,"ok":true,"paid_calls":0}
test-codemode-default          {"checks":39,"ok":true,"paid_calls":0,"rounds":2}
test-codemode-blocks           codemode blocks ok (31 checks)
test-codemode-promises         codemode natural promises ok (31 checks; real sandbox)
test-codemode-boundary         {"checks":33,"ok":true}
test-envelope                  envelope ok (97 checks)
test-toolname-repair           toolname repair: 33 checks, 0 failed, 0 skipped
test-resume-tool-registry      resume tool registry: 77 checks
test-prompt-tool-names         prompt tool names ok (286 checks, 0 skipped)
test-codemode-native           rc=1  red — and red on 62c3c064, same message (below)
```

Node and shell rows both branches named:

```
node scripts/check-deploy-shipped.mjs        deploy shipped ok (179 checks; 58 rules …, 44 from ship-wave.mjs)
node scripts/check-deploy-docs.mjs           deploy docs check ok (6 checks)
bash scripts/test-deploy-runtime-recheck.sh  deploy runtime re-check ok (11 checks)
node scripts/test-runtime-binding-preflight.mjs  {"ok":true,"checks":8}
node scripts/test-orphan-tests.mjs           ok (196 wired, 47 orphaned and declared)
```

## The cargo suites, base against branch

```
cargo test                       # rust/wa-sentinel, its own workspace, CARGO_TARGET_DIR=…/m-harness-land
cargo test -p wa-mesh-core -p wa-mesh   # in rust/
```

| suite | base `62c3c064` | this branch |
|---|---|---|
| wa-sentinel, `cargo test` (parallel), run 1 | 110 passed, **5 failed** | 120 passed, **6 failed** |
| wa-sentinel, `cargo test` (parallel), run 2 | 110 passed, **5 failed** | 120 passed, **6 failed** |
| wa-sentinel, `-- --test-threads=1` | 110 passed, **5 failed** | **121 passed**, **5 failed** |
| wa-sentinel parallel, `--skip withdraw_tests:: --skip observation_tests::` | — | 110 passed, **5 failed** (the base's five, by name) |
| wa-mesh-core | 27 passed, 0 failed | **29 passed**, 0 failed (+2: the two cache tests of item 8) |
| wa-mesh | 73 passed, **2 failed**, 1 ignored | 74 passed, **2 failed**, 1 ignored (+1: the seam test of item 8) |

The five wa-sentinel failures and the two wa-mesh ones are the ones the second-pass section already named,
and they fail **identically on the base**, same names, same messages:

```
deploy_outcome_tests::the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end
deploy_visibility_tests::a_failing_deploy_leaves_its_message_in_the_capture
node_script_tests::javascript_requests_run_native_node_and_preflight_before_any_operation
node_script_tests::job_run_prepare_and_pipeline_use_the_same_native_node_dispatch
role_tests::the_watcher_records_its_own_owner_where_a_later_stop_reads_it
tests_relay::a_caller_enabled_only_by_its_policy_reaches_the_roster_through_a_service_url
tests_relay::the_roster_decides_on_the_relay_path_too_and_an_existing_operator_bootstraps_it
```

**The sixth parallel failure, settled.** `reap_tests::a_killed_unreaped_child_is_not_alive` failed both
parallel runs of this branch and neither parallel run of the base (two runs each), so it is not dismissed by
saying "flaky" and it is not left open either — it was measured three ways:

- alone: `cargo test reap_tests` -> `1 passed` on this branch;
- serial: `--test-threads=1` -> passes on the branch **and** on the base (121/5 and 110/5);
- and the parallel run with the eleven new tests filtered out returns exactly the base: 110 passed, 5 failed.

`rust/wa-sentinel/src/reap.rs` is byte-identical to the base (`git diff --stat 62c3c064 HEAD -- …/reap.rs`
is empty), so what changed is the schedule — eleven more tests running at once, two modules of which spawn
processes — not the reaping code. Anyone landing this should expect that row to be red in a parallel full run
on a loaded node and green serially.

## `test-codemode-native`: red before this work

Red on this branch, and red with the **base tree's own Lua** (`/tmp/hl-base`, installed `wa` 2e6fab41):
`test-codemode-native.lua:24: opt-in adds one tool, direct tools retained`. It is a proof-environment row
(`WA_CODEMODE_PROOF_*`, `scripts/test-codemode-component.sh`), unchanged by both branches. Not fixed here.

## The orphan, wired (mission item 2)

`scripts/test-runtime-binding-preflight.mjs` arrived with item 9 and no harness named it. The ledger said
so and nothing else ran it:

```
$ node scripts/test-orphan-tests.mjs            # before
FAIL scripts/test-runtime-binding-preflight.mjs: orphaned and not declared in scripts/test-orphans.json - wire it into a harness or declare why not
orphan-tests: FAIL (195 wired, 48 orphaned, 47 declared)      exit 1
```

It needs no toolchain, no build and no network (two worktrees in a `mktemp -d`), so it is wired as a row of
the fast path, next to `install-front-door`, in `scripts/fast.sh` — not declared as an orphan with a reason,
because the reason would have been false: it can run on a landing. After:

```
$ node scripts/test-orphan-tests.mjs            # after
orphan-tests ok (196 wired, 47 orphaned and declared with a reason)      exit 0
$ grep -n runtime-binding-preflight scripts/fast.sh
672:  check runtime-binding-preflight node scripts/test-runtime-binding-preflight.mjs
```

and in the fast run below: `fast: runtime-binding-preflight ok (87ms)`.

## `scripts/fast.sh`, once: 261 checks, 13 failed, 438s

`bash scripts/fast.sh --jobs 8` on this node, this tree, at `ec62cf4c` with the row above still uncommitted.

```
fast: binary /home/victor/.local/bin/wa (build 2e6fab41e7be, tree ec62cf4c6d07, stale: …) sha256=fc6a9d8034f4
fast: binary /home/victor/wasm-agent/target/m-harness-land/release/wa (build ec62cf4c6d07, tree ec62cf4c6d07, fresh: built from this tree) sha256=3bb48b14fa34
fast: build root /home/victor/.wasm-agent/build/target/wt-20ab8fb1729d (4.0K of a 27.9G cap)
fast: env: node v26.13.1 (node:sqlite yes), cargo 1.100.0, wasi-sdk absent, lua 5.4.9
fast: components SKIPPED (graph hooks memory selfloop mesh codemode svc-echo): error: component graph needs wasi-sdk
fast: lua 221/227 passed (56 excluded: scripts/fast-path.exclude)
fast result FAILED (261 checks, 13 failed, 0 skipped)
fast path FAILED (13 of 261 checks, 0 skipped, 438s)
```

Every one of the 13, classified, with the base result that decides it:

| check | verdict | the base result |
|---|---|---|
| `test-codemode-model-boundary` | **pre-existing** | run with the base tree's Lua: `agent.lua:2471 … MODEL_BOUNDARY_CONTENT_REQUIRED: complete must not display empty or missing data` — the same sentence, on the same line of the same script |
| `test-host-return-docs` | **pre-existing** | base: `host return docs: 1 of 10 checks failed` (branch prints `FAIL every capability that answers JSON text says so: ["http_stream"]`) |
| `test-orchestration-mode` | **pre-existing** | base: `test-orchestration-mode.lua:7: mode-on declares subagent and route_task from the start` |
| `test-observability` | **pre-existing** | base: `test-observability.lua:17: opt-in short index retains every full tool schema` |
| `test-remote-call-shape` | **pre-existing** | base: `test-remote-call-shape.lua:19: preamble guideline in the progressive prompt` |
| `test-skill-discovery` | **pre-existing** | base: `test-skill-discovery.lua:7: ripgrep shell fallback disclosure rule` |
| rust `wa-sentinel` | **pre-existing** | serial in the runner: 121 passed, **5 failed** — the base's five, same names (base: 110/5) |
| rust `wa-mesh` | **pre-existing** | 74 passed, **2 failed** — the base's two, same names (base: 73/2) |
| `prompt-docs` | **pre-existing** | `bash scripts/sync-prompt-docs.sh --check` in `/tmp/hl-base`: `docs/ENVELOPE.md: tool-catalogue` stale, the same message |
| `publish-artifacts` | **the check, not the branch** | `LC_ALL=C bash scripts/test-publish-artifacts.sh` -> `publish artifacts: ok (55 checks)`; in the ambient `LANG=en_US.UTF-8` the same commit's names sort in the other order and the row fails. Nothing here touches `releases/` |
| `land-signing` | **the machine** | the same failure in `/tmp/hl-base`: `release_not_signed: WA_RELEASE_SIGN_DEFER=1 and …/SHA256SUMS.sig does not exist` — no vault on this node |
| `fast-binary` | **this node's environment, not the tree** | the row is `scripts/test-fast-binary.mjs`; `CARGO_TARGET_DIR` is exported in this node's session, and `scripts/fast.sh:144` says what that costs ("the row would then resolve the fast path against this run's build dir"). Measured pairwise on the same trees: with the variable -> rc=1 (9 of 28 checks); `env -u CARGO_TARGET_DIR node scripts/test-fast-binary.mjs` -> **rc=0, 28 checks** — once with `scripts/fast.sh` still uncommitted (tree `3be2c7e6`) and once on the commit that wires it (`be6cdb91`, tree `b103847f`) - so the row is red for as long as a binary stamped at an older tree sits in that exported directory, and green when the row is left to build its own fixture |
| `component-pins` | **introduced by this integration, and not clearable here** | base: `11 of 11 pinned component(s) verified: the bytes this node would install ARE the pin`. On this branch: `FAIL component-pins: mesh source changed and its pin did not — rust/wa-mesh-core/src/cache.rs, rust/wa-mesh-core/src/roster.rs` |

The ledger above is the difference between the rust branch's 14 and this run's 13: `orphan-tests` is green
here because the row is wired (`fast: orphan-tests ok (982ms)`), which is the only check this integration
changes.

**The one red that is ours.** `component-pins` is right, and it is the price of bringing items 6-8 in:
`rust/components/mesh` path-depends on `wa-mesh-core`, so changing `cache.rs` and `roster.rs` moves the
mesh pin in `components.lock` (`42872bbc…`, 209612 bytes) — and rebuilding it needs wasi-sdk, which this
node does not have (`WASI_SDK` unset, no wasi-sdk directory). I did **not** write a
`Components-Unchanged: mesh …` trailer: I cannot show the guest's bytes are the same, and that trailer would
be a claim I did not measure. So the branch is landable as code and **red on that gate** until someone with
wasi-sdk runs `scripts/build-components.sh mesh` and `scripts/publish-components.sh --from <artifact-dir>`.

## What this integration did not verify

- **The mesh component pin** (above): not rebuilt, not repinned, not excused.
- **`scripts/fast.sh` ran once**, as the mission asked. Its 13 failures are each attributed above; I did not
  re-run the whole suite after the last two commits (the row, the report), because no row reads its own
  history — the two rows that do depend on the tree state (`fast-binary`, `publish-artifacts`) were re-run on
  their own, quoted above.
- **The landing path was not exercised**: no `scripts/landing-queue.mjs`, no gate, no push, no deploy, no
  node state touched. Commits are local, on `change/harness-land`.
- `scripts/fast.sh`'s component rows (6 components) were skipped for want of wasi-sdk, exactly as on both
  source branches; nothing about them was measured here.

---

# Round 3 — the independent review of round 2, and items 6-8 again (avell, this node)

Same worktree and branch, head `3ce1a95f` before this round, base `change/harness-fixes`. This node has a Rust
toolchain (`cargo`, 16 cores, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-harness-land`) and a release
`wa` built from this tree, which is what the Lua rows below run against with `WASM_AGENT_LUA_ROOT=$PWD`.
Nothing pushed. `components.lock` and finding 3 (the mesh pin) untouched, as instructed: that one belongs to the
components-toolchain mission.

## 1. Item 7 retires a held deploy, then spams again

**Defect.** `Observation::observe` treated "missing a file intake writes" as structural, and `binding.json` is
written at `admit` (`deploy_protocol.rs`) while `intent.json`/`ack.json` are rewritten on every tick. A protocol
deploy held past the 300 s grace (busy node, protocol not ready, `parent_owner_unavailable`) was therefore judged
structural, moved to `deploy-protocol-retired/` with its evidence, recreated by the next intake under the same id
- and then `retire` failed forever because the target exists, while `verdict` kept answering `Retire`: one
`return-observation-retire-failed` line per tick, for as long as the machine runs.

**Fix.** `observation.rs`: the structural test is about what is in flight, not about which file is absent. A
directory is structural only when the id is in neither `requests/` nor `claimed/` (new `Observations::in_the_box`)
**and** its state does not say `withdrawn` (new `Observations::owes_a_report`, item 4 below). A failed retirement is
remembered: `Said { problem, first_seen, retire_failed }` replaces the old tuple, `verdict` answers `Quiet` for a
settled retirement, and the flag is persisted in `observation-problems.json` so a restart does not re-ask either.

**Test.** `observation_tests::a_held_deploy_survives_the_grace_with_one_line` - a request written where
`request deploy --expected-sha` writes it, then the real `deploy_protocol::intake` (intent + ack, no binding),
then 50 real lane passes with `WASM_SENTINEL_OBSERVE_GRACE=0`: the directory survives, nothing is retired, one line
naming `binding.json`, and no retirement is attempted.
`observation_tests::a_retirement_that_cannot_happen_is_said_once` - the retired lane already holds that id, 20
passes with grace 0, exactly one `return-observation-retire-failed` line and the earlier evidence byte-identical.

**Falsified.** Reverting the fix in place (the tuple type change means the base tree cannot compile these tests, so
the reversion is of the code the test exercises, not a `git stash`):
- "structural from the missing files alone" (the pre-review rule) → `a_held_deploy_survives_the_grace_with_one_line` FAILED;
- "`verdict` keeps answering Retire after a failed retirement" → `a_retirement_that_cannot_happen_is_said_once` FAILED, `left: 19` lines against `right: 1`.

**One more defect found while writing those tests, and fixed with its own test.** `sentinel_return::observe_at`
answers `Ok(())` both when it observed a directory and when it deliberately did nothing because its own
ten-second cadence (or its backoff after a failure) is not due. The lane read that silence as "observed cleanly" and
*forgot* the problem, so the next real attempt found nothing remembered and reported the same sentence again: "one
line per (id, problem)" at a term's length instead of a tick's - the same defect class, one lane down. `due(id, now)`
is now a fact the lane can ask (same two schedule files, same rule), and a deferral says nothing and forgets
nothing. `observation_tests::a_deferred_observation_does_not_forget_the_problem` fails without the gate with two
identical lines and passes with it (`left: 2` against `right: 1`).

## 2. Operator exception unreachable (round-1 #1/#2)

**Defect.** `workspaces.lua`'s `operator_session` required an empty `objective`, and every real operator session
carries `objective = "chat"` (`chat.lua` for a bare `wa chat`, `commands.new_session` for `/new`, `agent.lua`
for a named thread, `memory.ensure_session`'s `title or "chat"`, `subagents.lua` for a parent thread). So the
exception could be reached by no code that exists - and the test passed only because it built its own
`objective = ''` session, a shape no code produces. On a node without wave registration, `wa chat` was refused.

**Fix.** `lua/core/workspaces.lua`: accept `''` or `'chat'`, exclude `remote` and `subagent` (any other objective
still refuses), and keep the owner-principal check. The comment now records why `'chat'` is the shape that matters.

**Test.** `scripts/test-wave-operator-session.lua` (the review's own file) now builds its operator sessions through
the real constructors: `commands.new_session({user=owner.id,node=''})` for the allocated-admission site and
`memory.ensure_session(owner.id,'node-second')` for the new-allocation site, asserting the objective each carries
(`"chat"`); a third case keeps the `''` shape admitted, so the fix widens the rule instead of swapping one shape for
the other. The remote session and the root session of another principal still refuse by name.

**Falsified.** With the new test and the *unfixed* rule: `lua error ...:34: ITEM 4 (allocated): the operator session is
admitted in place of the wave: workspace_wave_admission_refused:wave_registration_required - the shared wave store
exists without a registration for this repository`. With the fix: `wave operator session ok`,
`{"checks":35,"ok":true}`. The old file on the same tree passed with 28 checks, which is the point: the only session
it admitted was its own fixture.

**Wired, because it was named by no harness.** The row is now in `scripts/test.sh` next to the other session rows:
`WA_SCRIPT=.../test-wave-operator-session.lua "$BIN" --db "$DB.wave-operator-session" | grep 'wave operator session ok'`
(the script prints that line, in the idiom of the Lua rows). A test nobody runs is a comment.

## 3. The mesh pin

Not touched, as instructed (`components.lock` is unchanged in this round's diff).

## 4. Item 6 is silent for protocol deploys

**Defect.** `withdraw_request` settled a deploy's outcome record only when the request carried no `expected_sha` -
and a protocol deploy has no outcome record (`deploy_outcome::open` is deliberately not called for one). A withdrawn
protocol deploy therefore stayed `held`/`accepted` in its own `state.json`, the return engine kept observing a
deploy that could never happen, and the session that asked waited for a terminal answer no code would write.

**Fix.**
- `main.rs` `withdraw_request`: for a request carrying `expected_sha`, record the `withdrawn` phase in the deploy's
  own directory through `deploy_protocol::record`, with the same words the legacy door uses, and say in the answer
  that its own return engine reports it. A record failure is audited (`withdraw-protocol-record-failed`) and named
  in the answer instead of being swallowed.
- `sentinel_return.rs` `observed_phase`: a `withdrawn` state is a **terminal** outcome. It is reported as phase
  `failed` on purpose: the phase a return event may carry is a closed vocabulary (`scripts/sentinel-return-hook.mjs`
  refuses any other word), and the detail says exactly what happened. Terminal is what stops the engine from
  observing it for ever and what stops the requesting session from waiting.
- `deploy_protocol.rs` `record`: `withdrawn` joined the list of states a later `held` record cannot overwrite.
- `observation.rs`: a directory whose state says `withdrawn` owes a report, so its missing `binding.json` is not
  structural - the observation that follows is what establishes the binding admit never wrote (a claimed request
  cannot be withdrawn, so a withdrawable protocol deploy was never admitted).

**Test.** `withdraw_tests::withdrawing_a_protocol_deploy_gives_its_session_a_terminal_report`: a real queued request,
the real `deploy_protocol::intake`, the real `withdraw_request`, then the real lane and the real return engine. Only
the owner lookup (a private listener on 127.0.0.1) and the job store are stood in for. It asserts the state is
`withdrawn`, that `returns/<id>-0.json` carries phase `failed` with the withdrawal in its detail,
`installation-observation.json` is terminal, the one event is `pending-return.json` for the parent that asked, and
that 20 further ticks do not rewrite the journal, do not add a second slot, and do not retire the directory.
`observation_tests::a_withdrawn_deploy_is_not_retired_before_its_report` pins the other half with no node at all
(`WASM_AGENT_PORT=1`): 20 passes, grace 0, the directory survives, one line naming `parent_owner_unavailable`.

**Falsified.** With the protocol door not told and a `withdrawn` state not terminal:
`assertion left == right failed: the deploy stops claiming to be waiting: {"phase":"held", ...}`.

## 5. Minor: the unwired shell test, the ledger's blind spot, the list-item fence

- **`scripts/test-deploy-runtime-recheck.sh` is wired** into `scripts/test.sh` beside the deploy-record and
  self-ship rows. It runs here: `deploy runtime re-check ok (11 checks)`.
- **The orphan ledger now sees shell tests**: `TEST_FILE` in `scripts/test-orphan-tests.mjs` is
  `^test[-.].*\.(mjs|cjs|js|sh)$`, and its header says why. Extending it found **14** unreferenced shell test scripts,
  not one: the named one is now wired, and the other **13** are declared in `scripts/test-orphans.json` with a
  specific reason each (what it needs and why it is not a landing row). Two of them - `test-build-cap-skip.sh` and
  `test-linux-launcher.sh` - are hermetic and cheap and are unwired only because no gate row was ever added; their
  entries say exactly that, which is the visible form of that debt.
  Evidence both ways: with the row removed, `FAIL scripts/test-deploy-runtime-recheck.sh: orphaned and not declared in
  scripts/test-orphans.json - wire it into a harness or declare why not` (`257 wired, 61 orphaned, 60 declared`);
  with it, `orphan-tests ok (258 wired, 60 orphaned and declared with a reason)`.
- **The list-item fence trade-off is documented, not flagged.** Which of the two the item allowed is a decision, and
  it is the first: failing every answer that contains an indented sample was the measured defect, and a sample is far
  more common in prose than an action is inside a list item. `docs/CODEMODE.md` has a new section, "A run block, and
  the fences that are only text", listing the three shapes that are text and stating the accepted trade-off with its
  price, so a reader meets it before a model does.

## The suites, before and after

`cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1` (`CARGO_TARGET_DIR` as above):

| tree | result |
|---|---|
| base, head `3ce1a95f` (before any edit of this round) | `121 passed; 5 failed` |
| this round | `126 passed; 5 failed` |

The five failures are the same five, they are in the base, and they are environment, not code: this machine runs the
watcher outside systemd, and two of them need a native `node` on the child PATH.

```
deploy_outcome_tests::the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end        (this watcher is inside wa-serve.service, which cannot be shown to own it)
deploy_visibility_tests::a_failing_deploy_leaves_its_message_in_the_capture            (same unit-identity refusal)
node_script_tests::javascript_requests_run_native_node_and_preflight_before_any_operation  (operation code=1)
node_script_tests::job_run_prepare_and_pipeline_use_the_same_native_node_dispatch      (operation code=1)
role_tests::the_watcher_records_its_own_owner_where_a_later_stop_reads_it               (Os { code: 2, NotFound })
```

Lua and harness rows run this round: `scripts/test-wave-operator-session.lua` 35 checks,
`scripts/test-wave-registration-refusal.lua` 15 checks, `scripts/test-session-worktree-status.lua` 15 checks,
`bash scripts/test-deploy-runtime-recheck.sh` 11 checks, `node scripts/test-orphan-tests.mjs` ok,
`node scripts/check-instructions.mjs` PASS (79 checks, 231 files), `bash -n scripts/test.sh` ok.

## What this round did not verify

- **No landing, no push, no deploy, no node state**: commits are local on `change/harness-land`.
- **`scripts/test.sh` as a whole was not run** (it builds this tree and takes the better part of an hour); the two
  rows added or changed were run on their own, and `bash -n` checks the file parses.
- **The installed `wa` does not carry the Lua fix** - `lua/core/workspaces.lua` is embedded at build time, and
  rebuilding/reinstalling the node is a deploy, not a test.
- **The sentinel binary was not exercised against a live watcher**: every claim about the lane is from its own tests
  in a scratch `WASM_AGENT_HOME`, plus the engine's own suite (`observation_io_tests`, `return_engine_tests`).

## Round 4 — a protocol withdrawal that lands before the first intake now reports

Measured on avell, in this worktree (`wt`, branch `change/harness-land`, head `1a7bfaa8` + this commit). Local
commit only: nothing pushed, no node state touched, no deploy.

### The edge case

A protocol deploy (one carrying `--expected-sha`) that the operator withdraws **before the watcher ever ticked**
never got its terminal return:

1. `request withdraw <id>` → `main::withdraw_request` → `deploy_protocol::record(&request, id, "withdrawn", …)`
   (`rust/wa-sentinel/src/main.rs:2109`, `rust/wa-sentinel/src/deploy_protocol.rs:53-57`). Because no tick ran,
   `intent.json` and `ack.json` do not exist, so `record` **creates the ack itself** with `phase: "withdrawn"`;
   `state.json` gets the same word in the same call;
2. `sentinel_return::validated_ack` accepted only `held/spawned/failed/unknown/verified`
   (`sentinel_return.rs:91`), so the deploy's own immutable acknowledgement was refused as
   `ack_identity_or_revision_mismatch; unknown, never replay`;
3. `observe_due` therefore wrote a `returns/<id>-0.json` with `phase: "unknown"` and returned the error — it never
   reached the emit that delivers the event - and every later pass took the same path, because the ack never
   changes. The session that asked waited for ever for a deploy that could never happen.

### The fix, and why this one of the two

`rust/wa-sentinel/src/sentinel_return.rs:91` — `withdrawn` is now one of the phases `validated_ack` accepts, with the
reason written beside it.

The other candidate was to write the ack as `held` when it is absent while the state says `withdrawn`. Rejected:
`deploy_protocol::record` writes **one** phase word into both files, and that is the single definition these two
readers share. Writing `held` into the ack and `withdrawn` into the state would put two different answers to "what
phase is this request in?" in one directory — and the ack would be the false one, because nothing is holding a
withdrawn deploy. Accepting the word keeps `record`'s `phase` argument the only place the vocabulary is chosen; the
validator reads what that function may write, and `observed_phase` still decides what the session is *told*
(`state.phase == "withdrawn"` → terminal `failed` + the withdrawal detail, the mapping round 3 already added). No
new phase word reaches a return journal.

### The test, and that it fails without the fix

`rust/wa-sentinel/src/withdraw_tests.rs`, test 7: `a_withdrawal_before_any_intake_reports_once`. Queue a protocol
request, **withdraw it with no intake at all** (no `intent.json`, no `ack.json`, no `binding.json`), then run the real
observation pass (`observation::Observations::load(); lane.pass()`) — the lane the watcher runs on every tick, with
the real queue, withdrawal, engine and job store; only the owner lookup (a private 127.0.0.1 listener) and the job
store are stood in for. It asserts the ack and the state carry the same phase; that `returns/<id>-0.json` is
`phase: "failed"` with a detail naming the withdrawal (and not an `ack_…` refusal); that `pending-return.json` is
queued for the parent; that 20 further passes rewrite nothing; and that the directory holds **exactly one terminal
return**, in the one immutable slot (`returns/<id>-0.json`).

Falsified by hand, as recorded in the test file: dropping `withdrawn` from `validated_ack` and re-running this one
test fails it at the phase assertion with exactly the reported defect —

```
assertion `left == right` failed: terminal, not an unknown ack problem:
  {"detail":"ack_identity_or_revision_mismatch; unknown, never replay", "event_key":"…-0", "phase":"unknown"}
  left: String("unknown")   right: "failed"
```

The same edit leaves the older protocol-withdrawal test green, which is the point: that one runs intake first, so its
ack exists with `held`.

The private listener test 6 carried inline is now `owner_lookup()` in the same file, used by tests 6 and 7 — the only
change to an existing test, and it is a move, not a rewrite (test 6 still passes).

### The suite, and the `WASM_AGENT_PROVENANCE` note

```
cd rust/wa-sentinel && CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-harness-land \
  env -u WASM_AGENT_PROVENANCE cargo test -- --test-threads=1
→ 127 passed; 5 failed; 0 ignored   (27.79s)
```

`WASM_AGENT_PROVENANCE` **must be unset** when the sentinel suite runs. It is set to `child` inside a `wa` call,
where the sentinel refuses supervisor effects by name, and three *older* withdraw tests go through the CLI door
(`request(&["withdraw", …])`) that gate guards. Measured here rather than assumed:

```
WASM_AGENT_PROVENANCE=child cargo test withdraw_tests -- --test-threads=1
→ 4 passed; 3 failed
   a_claimed_request_is_refused_by_name_and_nothing_moves      sentinel_coordinator_only: workers may implement/merge/report, never request supervisor effects
   a_queued_request_is_withdrawn_once_with_one_audit_line      (same refusal)
   every_other_answer_is_refused_by_name                       (same refusal)
```

Those three are environment, not code (`main.rs:2692`), they pass with the variable unset (7/7 for this module,
parallel and serial), and the new test 7 passes either way because it calls `withdraw_request` directly.

The five wa-sentinel failures are the five already named in this report (two need the systemd unit identity of a
watcher this machine does not run under, two need a native `node` on the child PATH, one is a missing record), same
names, same messages, and they fail identically on the base (see "The base, re-measured"):

```
deploy_outcome_tests::the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end
deploy_visibility_tests::a_failing_deploy_leaves_its_message_in_the_capture
node_script_tests::javascript_requests_run_native_node_and_preflight_before_any_operation
node_script_tests::job_run_prepare_and_pipeline_use_the_same_native_node_dispatch
role_tests::the_watcher_records_its_own_owner_where_a_later_stop_reads_it
```

No new test fails. `wa-mesh-core`, `wa-mesh` and the script suites were not run: this change touches only
`wa-sentinel` (one validator line and one test file).

### What this does not do

- **Directories already stuck before this commit** have their `returns/<id>-0.json` written with
  `phase: "unknown"` (the bug), and a written journal is immutable. After this fix such a directory no longer
  spins: the ack validates, the terminal phase is delivered — but the event the session receives is the stored
  `unknown` ("ack_identity_or_revision_mismatch; reconcile, never replay"), not the withdrawal. The session's wait
  ends either way; the answer for those pre-existing directories is the weaker one, and rewriting a journal to
  improve it would break the immutability the rest of this engine is built on. No such directory exists in this
  scratch-state proof; this is reasoning from the code path, not a measurement of a real stuck directory.
- **Ordering within `record`**: the ack is written before the state. A watcher tick landing between those two writes
  of a withdrawal would see a valid ack and a state that is not yet `withdrawn`, and would report one non-terminal
  `held` slot before the terminal one. It is a two-write window inside one locked call, it is the shape `record`
  already had, and closing it is a change to the write order, not to this vocabulary — not done here, and not
  measured.
- **No live watcher** was run against a real node: every claim above is from tests in a scratch `WASM_AGENT_HOME`.

---

# green-main — the landing gate on avell (mission `change/green-main`)

Branch `change/green-main`, base `change/harness-land` at `97ef887f`. Everything below was built and run in this
worktree (`/home/victor/Work/missions/green-main/wt`) on this node, with
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-green-main`. Nothing was pushed, no landing-queue run, no gate,
no deploy, no node state touched. Every row keeps its own `mktemp -d` home.

**The task.** `wa land`'s gate (`bash scripts/fast.sh` + the cargo rows + `prompt-docs`) stops on `gate_failed`
and cannot tell a pre-existing failure from a new one, so the gate had to be able to PASS on this node: each of
the reds attributed to its real cause and fixed in the code, or made robust to an honest environment difference -
never skipped, deleted or weakened.

## The baseline: 12 red of 261, measured on the base commit before any change

```
$ bash scripts/fast.sh --jobs 16            # at 97ef887f, this node, this tree
fast: lua 221/227 passed (56 excluded: scripts/fast-path.exclude)
fast result FAILED (261 checks, 12 failed, 0 skipped)
fast path FAILED (12 of 261 checks, 0 skipped, 149s)
```

The harness-land report (this file, above) counted 13 on the same node with `--jobs 8`. The difference is
`test-codemode-native`: that node had no wasi-sdk, so `fast.sh` could not build the `codemode` component and the row
skipped the half that needs it; **this** node has wasi-sdk 34.0, the component is built from this tree, and the row
runs - and passes. Every row below was measured BEFORE (on `97ef887f`, before any change here) and AFTER.

## What each red was, and what changed

| # | check | the measured BEFORE | the cause | the change | the measured AFTER |
|---|---|---|---|---|---|
| 1 | `test-observability` | `opt-in short index retains every full tool schema` | `lua/core/raw_code.lua`'s `M.DEFAULT` is `only` since 17/11, so a node with nothing in its environment declares NO tool: the row asserted a schema the surface no longer had | the row pins `WASM_AGENT_RAW_CODE='codemode'` through `host.getenv` - the pattern `scripts/test-envelope.lua` and `test-codemode-default.lua` already use for this exact change | `observability ok: 78 assertions; zero model calls` |
| 2 | `test-remote-call-shape` | `preamble guideline in the progressive prompt` | same | same pin (in its existing `overrides` table) | `remote call shape ok (59 checks, 0 skipped)` |
| 3 | `test-skill-discovery` | `ripgrep shell fallback disclosure rule` | same | same pin | `skill discovery ok (49 checks, 0 skipped; no provider or paid calls)` |
| 4 | `test-orchestration-mode` | `mode-on declares subagent and route_task from the start` | same | same pin | `orchestration mode ok (66 checks, 0 skipped; no inference)` |
| 5 | `test-codemode-model-boundary` | `MODEL_BOUNDARY_CONTENT_REQUIRED: complete must not display empty or missing data` | same: the JSON `codemode` call the row drives is not declared under CodeAct | same pin, in the row's own `host.getenv` override | `{"artifact_retrievals":5,"checks":664,"ok":true,"paid_calls":0,"phase":"seed","write_calls":1}` |
| 6 | `test-host-return-docs` | `FAIL every capability that answers JSON text says so: ["http_stream"]` | a real documentation defect: `host.http_stream` was the one capability that pushes JSON (`push_json`) with no doc comment at all, and the row exists because a caller that iterates that string with `ipairs` reads exactly like "there are none" (the 12/11 `list_dir` cycle) | the doc comment it was missing, naming the encoding, the record's shape and its fifth argument | `host return docs ok (10 checks; 35 JSON-text capabilities documented)` |
| 7a | `wa-sentinel node_script_tests` (both) | `called Result::unwrap() on an Err value: Os { code: 2, kind: NotFound }` (reading the receipt the failed run never wrote), and the operation's own `state.json` says `code=1` with **mise's usage text** in its stdout | `script_runner::resolve_node` canonicalized the interpreter it found, and a version manager's shim **is** a symlink to the manager: this node's `~/.local/share/mise/shims/node -> /usr/bin/mise`, so every approved JS script ran `mise -- <script>` | `launch_path()` returns an absolute path and never resolves the last component (an absolute path is all canonicalization bought: the file checked is the file launched; a shim picks the interpreter by its OWN name). The crate's resolver test gained the shim case | `cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1` -> `test result: ok. 132 passed; 0 failed` |
| 7b | `wa-sentinel deploy_visibility_tests::a_failing_deploy_leaves_its_message_in_the_capture`, `deploy_outcome_tests::the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end`, `role_tests::the_watcher_records_its_own_owner_where_a_later_stop_reads_it` | `this watcher is inside wa-serve.service, which cannot be shown to own it` / `inside wa-serve.service, which this cannot claim as its supervisor` / `the record is written where identity() reads it: Os { code: 2 }` | the fixtures stated no supervisor, so they inherited the control group of whoever ran the suite - and this node runs it inside its own systemd user unit `wa-serve.service` (`/proc/self/cgroup` = `/user.slice/.../wa-serve.service`). `owner_of` then answers `Unrecognised{wa-serve.service}`, which is the CORRECT answer for a process the unit handed nothing to | each fixture declares `WA_SENTINEL_SUPERVISOR=none` - the code's own documented name for "nothing outside owns the watcher" (`main.rs`, `record_owner`). The unit cases set their own supervisor and are unaffected | (same run) 132 passed; 0 failed (was 121 passed, 5 failed) |
| 8 | `wa-mesh tests_relay` (both) | `relay_answer_unreadable: unknown field 'error', expected one of 'schema', 'ts', 'from_node_id', 'reply', 'signature'` and `t has not been pushed a roster yet` | two causes. (a) A real defect: the relay carries the target's unsigned refusal as the body it answered with - `{"error":"unknown_caller"}` - which is not a `RelayAnswer`; the `Err` arm of `RelayAnswer::open` returned that verification error first, so a relayed refusal read as `mesh_relay_failed`, and the arm below it (whose comment says "a refusal the target could not sign is a diagnosis, never a result: only its allow-listed code is kept") was unreachable - the compiler's `unreachable_patterns` warning on that match was the same defect. (b) one row inherited this session's `WA_MESH=1`, and `gate::decide_with_roster` reads the environment's word before the policy's | (a) the body is read for an allow-listed pre-auth code BEFORE the verification error is the verdict; a refusal keeps its code with `verified:false`, and a body that names no allow-listed code still reports the verification's own reason. The `[probe]` eprintln that leaked that reason to the crate's stderr is gone. (b) the row clears `WA_MESH`/`WASM_AGENT_MESH` through `testkit::EnvGuard`, as its sibling row already did | `cargo test --offline -p wa-mesh` -> `76 passed; 0 failed; 1 ignored` (was 74 passed, 2 failed) |
| 9 | `prompt-docs` | `sync-prompt-docs: stale generated blocks (run scripts/sync-prompt-docs.sh --write):   docs/ENVELOPE.md: tool-catalogue` | the committed generated block no longer matched the catalogue | `bash scripts/sync-prompt-docs.sh --write` - the repo's own script; one row changes (`recall`'s parameters are `limit? query? scope?`) | `prompt-docs ok` in the final run |
| 10 | `fast-binary` | `9 of 28 checks failed`, first: `a fresh tree binary is used, got action=refuse (build 97ef887f544a is not this tree (d042c8606fb1); WA_FAST_SKIP_BUILD=1 forbids building one)` | the row's fixtures build their own stub tree, but an inherited `CARGO_TARGET_DIR` makes `scripts/lib/fast-binary.sh` look in the CALLER's directory first ("a caller that names CARGO_TARGET_DIR keeps it"), find a binary from another tree, and refuse. `env -u CARGO_TARGET_DIR node scripts/test-fast-binary.mjs` -> 28/28 on the same tree | `plan()` clears `CARGO_TARGET_DIR` for the scenarios that are not about it (the same way it already clears `WA_BIN`), and **scenario 7 passes one back in** and asserts the rule itself | `fast binary: 32 checks`, green with and without the variable exported |
| 11 | `publish-artifacts` | `publish artifacts FAILED: the commit holds 'node-97ef887f544a.manifest PUBLISH.sh SHA256SUMS …', expected exactly 'PUBLISH.sh SHA256SUMS …'` | the check compares a file SET to a literal written in byte order, and read the ref back sorted in the ambient collation `en_US.UTF-8`, whose sort ignores case and puts `node-…` before `PUBLISH.sh` | `LC_ALL=C sort` on the readback: the order is the one the literal names, whatever the operator's locale is - the commit's contents are what the check is about | `publish artifacts: ok (55 checks)` under the same `LANG=en_US.UTF-8` |
| 12 | `land-signing` | `land signing FAILED: the refusal is named signature_stale: 'signature_stale:' not in: … release_not_signed: WA_RELEASE_SIGN_DEFER=1 and …/SHA256SUMS.sig does not exist …` plus, on every run, `publish-node-binaries.sh: line 161: …/scripts/lib/build-target.sh: No such file or directory` | **not a vault at all** - this row signs with an offline fixture signer over this tree's own `vault/wa_vault.py` and never touches one. (a) the 17/11 change ("a signature left from ANOTHER build is moved aside, said, and the build goes on") had dropped the *named* reason the row greps for; (b) the row's fixture checkout does not carry `scripts/lib/build-target.sh`, which the publisher sources unconditionally; (c) step 5's restore put the payload bytes back but not the signature the refusal had just moved aside, so "the signature over them verifies again" asked it of a directory whose signature had been taken away - a case the row never reached before (a) | the moved-aside line now carries `signature_stale:` and the fix instruction (no assertion changed: exit 6, the name, the instruction and "nothing was uploaded" are all still required); the fixture names its target directory with the publisher's own documented `--target-dir` (it publishes `--from` a built set and never builds); the restore puts the signature back with the bytes, and asserts the stale one was left in a named place | `land signing ok (44 checks)` |

**No row needed a named SKIP**, so `fast.sh`'s skip grammar was not extended and no check was excused: the last
row of the mission's list (`land-signing` → "no vault here") turned out not to need a vault, and the two reds the
harness-land report called "the machine" (`fast-binary`, `publish-artifacts`) were fixed at their real cause.

## The environment these verdicts belong to (stated, not assumed)

```
fast: env: node v26.13.1 (node:sqlite yes), cargo 1.100.0, wasi-sdk 34.0, lua 5.4.9
```
* **wasi-sdk 34.0 is present** on this node, so the seven component rows build and run here (the harness-land run
  skipped them). That is also why `test-codemode-native` passes here.
* **node comes from mise shims** (`~/.local/share/mise/shims/node -> /usr/bin/mise`): the cause of 7a.
* **the session runs inside the systemd user unit `wa-serve.service`**: the cause of 7b.
* **`WA_MESH=1`** and **`WASM_AGENT_RAW_CODE`** are in the ambient environment of every child a node session
  spawns; `LANG=en_US.UTF-8`, `TMPDIR=/home/victor/.wasm-agent/tmp` and an exported `CARGO_TARGET_DIR` too.
`fast.sh` already clears the vault, identity and mode variables for its LUA rows (`env -u …`); the two rows that
needed more state that themselves, which is the runner's documented contract ("a row that tests one of these sets
it itself").

## What this did not do, and what it did not verify

* **Nothing was pushed**, and the landing path was not exercised: no `scripts/landing-queue.mjs`, no gate run, no
  deploy, no node state touched. Commits are local on `change/green-main`.
* **The harness-land `component-pins` red is out of scope here** and was green in both runs on this node
  (`fast: component-pins ok`), because wasi-sdk is here and the components build.
* **`wa-sentinel` and `wa-mesh` were run as `fast.sh` runs them** (`--test-threads=1` for wa-sentinel) and also by
  hand for the failing names; the numbers quoted are from the whole crate.
* **No new test was added for the mesh relay fix** beyond the two rows that already exercise it (they are exactly
  the two that were red, and they assert both the code (`unknown_caller`, `verified:false`) and the wording that
  follows it). The sentinel's shim fix has its own case in the crate's resolver test.
* **A falsification was not run for every fix**: the "BEFORE" column is the base commit `97ef887f` measured on this
  node with no change of mine applied, which is the falsification for each row (revert the fix and the row is red
  again). The two rows where the before is also a code defect (`http_stream`, the relay arm) are the ones where
  the compiler or the source shows the defect directly.

## The extra red the gate could not see before, and why it appeared

Selecting the crate rows by what a change touches (scripts/fast.sh) means a crate nobody touches is never tested, so
its drift is invisible - the harness-land report measured the same shape with `orphan-tests`. This branch made the
change that revealed one: commit `2ef62c99` touched `rust/wa-capabilities/src/host.rs` (a doc comment), which is what
selects the `rust wa-capabilities` row. It came back

```
FAIL rust wa-capabilities (exit 101):
test capabilities::tests::documented_inventory_matches_the_live_registry ... FAILED
registered but undocumented in docs/HOST.md: ["transcript_expand"]
```

which is red at `97ef887f` too - the capability is registered there (`git show 97ef887f:rust/wa-capabilities/src/capabilities.rs | grep -c transcript_expand` -> 1) and the inventory row is not (`git show 97ef887f:docs/HOST.md | grep -c transcript_expand` -> 0), and it arrived with
`1af78376` ("cli: a long result is one row that opens on a click") without one. `docs/HOST.md` now documents it
(`transcript_expand    device`, in the block's own order and column, the class `capabilities.rs` registers), and the
crate's row is green: `fast: rust wa-capabilities ok (30s)`, 281 + 1 tests.

## The final gate run: 262 checks, 0 failed, 0 skipped

```
$ bash scripts/fast.sh --jobs 16            # at 5b542393, this node, this tree
fast: binary /home/victor/wasm-agent/target/m-green-main/release/wa (build 5b5423934abd, tree 5b5423934abd, fresh: built from this tree)
fast: env: node v26.13.1 (node:sqlite yes), cargo 1.100.0, wasi-sdk 34.0, lua 5.4.9
fast: components graph hooks memory selfloop mesh codemode svc-echo built from this tree and pinned in …
fast: lua 227/227 passed (56 excluded: scripts/fast-path.exclude)
fast: rust wa-capabilities ok (30s)
fast: rust wa-sentinel ok (28s)
fast: rust wa-mesh ok (1s)
fast result ok (262 checks, 0 failed, 0 skipped): …/wa-fast-result.json
fast path ok (262 checks, 0 skipped, 178s)
```

Before: `fast path FAILED (12 of 261 checks, 0 skipped, 149s)`. After: `fast path ok (262 checks, 0 skipped, 178s)`,
exit 0. The gate's own skip grammar was not touched: nothing is skipped, nothing is excused, and every check the
landing gate runs - the Lua rows, the three Rust crates, `prompt-docs`, and the contract rows - is green on this node.

Re-run at HEAD after this report was committed (`02f1782a`, docs only, so the binary stayed fresh): `fast path ok (262 checks, 0 skipped, 165s)`, exit 0 - the tree this branch leaves behind is green, not only the one the first green run measured.

## Commits (local, on change/green-main, not pushed)

```
974e30fc lua rows name the tool surface they assert: CodeAct is the default since 17/11
2ef62c99 host.http_stream says it answers JSON text: only undocumented push_json capability
598737c8 docs/ENVELOPE.md: regenerate (recall's parameters are query? limit? scope?)
8d41c561 wa-sentinel: a version manager's shim is launched by its own name, and a fixture states its owner
7d7eeb9e wa-mesh: a relayed refusal that could not be signed is a refusal, not an unreadable answer
2ebec818 fast-binary: the row does not inherit the caller's CARGO_TARGET_DIR (and scenario 7 keeps the rule it covers)
b318b894 publish-artifacts: the file list is compared in byte order (LC_ALL=C sort)
e3cfeb61 land-signing: the moved-aside signature is named signature_stale, and the row restores the state it took apart
5b542393 docs/HOST.md: document transcript_expand, a registered capability with no inventory row
```

## Round 2: the review of 97ef887f..02f1782a, item by item (18/11)

The review was right on item 1, right on item 2, and right that the CodeAct surface had no coverage - with one
correction to my own first reading of items 2 and 3, recorded below rather than quietly dropped. Three commits,
each with a failing-before case; then the gate.

### 1. Land signing: a --publish run refuses with the real cause and leaves the directory alone

The row's `signature_stale:` came from the informational `say` on line 614 of `scripts/publish-node-binaries.sh`,
while the exit came from `release_not_signed` on line 640: under `WA_RELEASE_SIGN_DEFER=1 --publish` the 17/11
move-aside renamed the stale signature to `.sig.stale` first and the run then refused for its absence. The row
passed because it grepped a name printed on the way past, and because it put `.sig.stale` back by hand
(`scripts/test-land-signing.sh:202-203`) - so its own comment, "nothing was left in a broken state", was true
only because the row made it true.

Moving a stale signature aside is a build-host courtesy: the build has something to get on with. A publishing run
does not - it ships these exact bytes. The condition now excludes it (`[ "${PUBLISH:-0}" != 1 ]` at 619), so the
stale signature reaches the check below and is refused there by its real name: `signature_stale`, exit 6, nothing
moved, nothing uploaded, the directory untouched. The row's hand restore is gone; it asserts instead that the
signature is still there byte for byte, that no `.sig.stale` exists, and that `release_not_signed` is never printed.
Its payload/manifest restore stays - that mutation is the case's own.

BEFORE (the publisher's condition narrowed back to the old one, the new row unchanged):

```
land signing FAILED: the refusal names the cause, not the hole a move-aside would leave:
  'release_not_signed' unexpectedly in: ... signature_stale: .../SHA256SUMS.sig is not a signature over
  the sums just written ... moved aside as .../SHA256SUMS.sig.stale ... release_not_signed:
  WA_RELEASE_SIGN_DEFER=1 and .../SHA256SUMS.sig does not exist ...
```

AFTER: `land signing ok (46 checks)`, was 44.

### 2. wa-mesh: the unverified_reply arm audits its deny again

`7d7eeb9e` split the relay path's refusal arm in two: the allow-listed code kept its code and its audit `Event`,
and the early return beside it - an answer that opened, verified, and names no allow-listed code, i.e. another
call's answer - kept only the `Refused` shape. It is the same verdict about the same call, so a node's
`mesh.jsonl` said nothing at all about an answer that arrived signed, verified and belonged to somebody else.

The arm now emits the deny `Event` it replaced (`verdict deny`, code `unverified_reply`, transport `relay`)
before returning, exactly as the branch below it does.

The row is a stub relay that carries one answer the test chose - the two fields a real relay hands on (`status`
and `body`, headers dropped) - so the caller's own verification is the only thing that decides. t's key seals the
answer and the roster has that key, so `RelayAnswer::open` verifies; the request id inside belongs to another
call, which is the one path that reaches this arm.

```
BEFORE: panicked at wa-mesh/src/tests_relay.rs:897: the unverified refusal is audited as a deny,
        like every other refusal: []          (no events at all)
AFTER:  cargo test --offline -p wa-mesh -> 77 passed; 0 failed; 1 ignored   (was 76/0/1)
```

### 3. The DEFAULT CodeAct surface: three variants, and a correction to my own first reading

Rows 4, 3 and 2 of round 1 named their surface with a file-wide `WASM_AGENT_RAW_CODE='codemode'` pin. That
fixed those rows and left the surface the node actually runs untested by the very rows that named it: CodeAct
(`raw_code.M.DEFAULT` is `only`) declares nothing and a run block is the only way to act. Each row now names its
surface in one variable (`raw_surface`) and carries a CodeAct variant at the end:

| row | the CodeAct variant | result |
|---|---|---|
| `test-orchestration-mode` | `route_task` is callable from a run block and records the route there; `subagent` is refused from a script BY NAME with the fix it carries, because it is on `codemode.DIRECT_ONLY`; the direct call it is pointed at reaches the tool itself, not a script wrapper | 66 -> 76 checks, green |
| `test-skill-discovery` | a stubbed-provider run on the default surface (no pin, 0 tools declared, no network, no paid call); the ripgrep fallback rule read out of the system message the provider was actually given | 49 -> 53, green |
| `test-remote-call-shape` | the same run shape for the step-preamble rule | 59 -> 62, green |

Row 4's answer is honest rather than convenient: of the coordinator's two named routes, `route_task` runs inside
the script (`attempt.admitted == true`) and `subagent` does not
(`codemode_target_not_available: subagent runs outside code mode`, fix: "call it as an ordinary tool call") - it is
one reviewable call by design. The variant asserts both, plus that the direct `subagent` call that refusal points
at is dispatched to the tool itself (`its own guard answers: orchestration_mode_not_enabled`) and is not wrapped
into a script.

**A first reading of items 2 and 3 was wrong, and how it was wrong is worth recording.** I built the CodeAct
prompt by calling `agent.system_prompt(...)` directly with an empty tool list, found neither the ripgrep rule nor
the preamble rule in it, and started writing an `agent.lua` fix. A run does not build its prompt that way:
`M:build_context` passes session options, and `raw_code.first(policy)` is true for `only` as well as `first`, so
`guidelines_for` already fills the core names on the default surface. A stubbed-provider run on the default surface
carried both rules before and after that change - the same 19,024-byte system message. The change was reverted
(`lua/core/agent.lua` is untouched by this round) and the variants are written against a real run instead of a
hand-built prompt.

Falsification instead of a fix: mutating `if raw_first then have.codemode = true end` to `if false then ...` (the
code surface no longer fills the core names) turns both variants red on exactly their own assertion, and restoring
it turns them green:

```
lua error: [string "scripts/test-skill-discovery.lua"]:14: ripgrep shell fallback disclosure rule on the DEFAULT CodeAct surface
lua error: [string "scripts/test-remote-call-shape.lua"]:24: preamble guideline on the DEFAULT CodeAct surface
```

A coverage variant that cannot fail is not coverage.

### Correction to row 12's claim in this report

The round-1 table says of `land-signing`: "no assertion changed: exit 6, the name, the instruction and 'nothing
was uploaded' are all still required". That was wrong, and the review was right to say so. The exit came from
`release_not_signed` (640), not from `signature_stale` (618); the name the row greps for came from the
informational `say` on 614; and the row ended by restoring `.sig.stale` itself, so the set was taken apart and
put back by the test. The row asserted a phrase printed on the way past a refusal, not the refusal. What is claimed
now is what item 1 above measures, and the claim is made by the row's own assertions rather than by the wording it
happens to print.

### The gate: 262 checks, 0 failed, 0 skipped

```
$ CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-green-main bash scripts/fast.sh
fast: binary .../m-green-main/release/wa (build f529e61d7edf, tree f529e61d7edf, fresh: built from this tree)
fast: lua 227/227 passed (56 excluded: scripts/fast-path.exclude)
fast: rust wa-capabilities ok (31s)
fast: rust wa-sentinel ok (28s)
fast: rust wa-mesh ok (4s)
fast: prompt-docs ok (13296ms)
fast: land-signing ok (1231ms)
fast result ok (262 checks, 0 failed, 0 skipped): .../wa-fast-result.json
fast path ok (262 checks, 0 skipped, 186s)
```

The same 262 as round 1 and no new red: the additions are checks INSIDE rows (the gate counts rows and contract
checks, not a row's internal assertions), so a row-level count that stayed at 262 is the expected shape, not a
measurement that skipped anything. The run measured this tree's content (the working tree at the time); the commits
below change no bytes of it, and `git status` is clean after them. One compiler warning remains and is not this
round's: `warning: function connect is never used --> wa-mesh/src/http.rs:475` (a file this round did not touch).

### What this round did not do

- **Not pushed, not landed.** The branch is local; `wa land` / the landing queue is the operator's step.
- **No real inference.** Every new assertion runs through a stubbed `host.http_stream`; no model call was made and
  no child was started (`subagent`'s reachability is asserted at the dispatch level; starting one spends model
  calls, which a row must not do).
- **`subagent` is still not callable from inside a script** on the default surface - by design
  (`codemode.DIRECT_ONLY`), and now asserted rather than assumed. If the coordinator is expected to call it from a
  run block, that is a design change for the operator, not a defect this round should have patched.

## Commits (round 2, local, on change/green-main, not pushed)

```
a2452666 lua rows: the DEFAULT CodeAct surface has its own cases (surface, not file-wide pin)
c83ced23 wa-mesh: the unverified_reply arm audits its deny again
e0ca5acc land-signing: --publish refuses a stale signature instead of moving it aside
```
