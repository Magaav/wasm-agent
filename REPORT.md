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
