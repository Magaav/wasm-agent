# The torus: nothing is the core, every segment is replaced by a neighbour

Status 2026-11-11: **design, not built.** This document defines the topology (the segments, the seams
between neighbours, the restorers, the invariants) and then the two rings to build first. Every
"today" sentence cites the file and the function that holds the behaviour; every "target" sentence is
a decision, not a measurement. Nothing here is implemented unless its row says **exists**.

The operator's decision this answers (11/11): putting the update logic *in the core* would lock
evolution — the updater would become the one thing that cannot be updated. The answer is a torus:
**nothing is the core; every segment is replaceable, always by a neighbour, never by itself.** Two
consequences decide the whole design:

- **A segment never restores itself.** The restorer is the clockwise neighbour, a process or a node
  whose identity is not the one being replaced. `#122` produced the exact form of this rule for
  candidates: a candidate never runs under the live identity. (The issue itself is on GitHub, not in
  this tree; this document records only the rule, and says so wherever the rule is used.)
- **The contract lives at the seam.** A neighbour may only touch a segment through its declared seam,
  and every seam has one contract test in the gate. A repair that needs a guard bypass is not a
  repair (invariant d).

## 1. The segments, and why today's shape is a star

The nine segments and where their bytes live today (read from the installer, not guessed —
`scripts/deploy.sh`, `scripts/upgrade.sh`):

| # | segment | its bytes today |
| --- | --- | --- |
| 1 | **seat** | the OS service or logon task: `wa-sentinel.service`, `scripts/install-sentinel-service.ps1`, `scripts/install-sentinel-task.ps1`, `scripts/lib/service-target.sh` |
| 2 | **sentinel** | `wa-sentinel` beside `wa` (rust/wa-sentinel); its state is `<config>/sentinel/` (request box, `done/`, `failed/`, `deploy-protocol/<id>/`) |
| 3 | **deploy** | `<install>/scripts/` (`deploy.sh`, `upgrade.sh`, `lib/node-binaries.sh`, `lib/deploy-components.sh`) plus the staging slots |
| 4 | **host** | the `wa` binary (rust/wa-kernel-runtime, wa-capabilities, wa-term, the mesh/relay code) |
| 5 | **components** | the pinned WASI set in `components.lock`, installed by `scripts/lib/deploy-components.sh` into `WA_COMPONENTS_DIR` |
| 6 | **core** | `<install>/lua-core` (the `lua/core` tree), or the `agent-core` component (`wa --core-component`) |
| 7 | **state** | `~/.wasm-agent` (memory.db, graph.db, kv) — never replaced, always carried — and the install records `<install>/installed.txt`, `deploy-result.json`, `deploy-state.json`, `<config>/update-check.json` |
| 8 | **surface** | `ui/` served by the node, `rust/wa-term`'s editor row, `lua/core/cli_view.lua` |
| 9 | **peer** | the neighbour node and the transport to it: `rust/wa-mesh/src/relay.rs`, `rust/wa-rendezvous/src/relay_client.rs`, `lua/core/remote_update.lua` |

**What exists today is a star, and that is the point of this document.** One mover — the deploy,
acting for the sentinel — swaps six of the nine in one pass: the binary and the sentinel
(`scripts/upgrade.sh`, `$BACKUP` copy, `.new` + `mv -f`, restore on failure), the Lua tree
(`$LUA_STAGE` → `<install>/lua-core`, `lua-core.prev`, `restore_lua_tree`), the component set
(`wa_components_record_set` / `wa_components_install_set` / `wa_components_restore_set`), the UI
(`$UI_DIR/$asset.pre-upgrade`) and `policy.json` (`scripts/lib/install-default-policy.sh`). The star's
centre is the thing the operator does not want to make irreplaceable. The torus re-cuts the star so
that each of those moves is performed by exactly one neighbour, and the deploy is itself a segment
with its own restorer.

The ring order below is the **cut we choose**, not a discovery. Each arrow reads "the segment on the
left is the only one allowed to move, and to observe, the segment on the right — through the seam in
§2, and only through it":

```
seat → sentinel → deploy → host → components → core → state → surface → peer → seat
```

One place where this cut contradicts today's code is named here rather than hidden: the deploy script
set is installed by the deploy itself (`scripts/upgrade.sh`, the block that rewrites
`<install>/scripts/upgrade.sh` via `.new.$$` + `mv -f`). That is segment 3 restoring segment 3 — the
one live violation of invariant (b), and the reason ring 1 moves that write to the sentinel.

## 2. The seams

Nine seams, one per arrow. "Contract test" means a test that exercises the seam itself (both sides,
one declared shape), not a test of one side's internals; the ones that run in
`bash scripts/fast.sh` are marked **fast**, the ones only `scripts/test.sh` runs are marked **gate**.

### 2.1 seat → sentinel

- **Today.** The OS manager owns the process: a systemd unit or a logon task starts the watcher and
  restarts it (`Restart=always`, `scripts/install-sentinel-service.ps1`, `-RestoreOnly` in
  `scripts/restore-sentinel-task.ps1`). A stop file cannot beat the manager, which is why the docs
  say to stop through the manager (`docs/SENTINEL.md`, "A kill switch"). The deploy may ask the
  manager for a restart, through `sudo -n env … $INSTALL_DIR/wa-sentinel restart` when
  `WA_DEPLOY_SENTINEL_SUDO=1` (`scripts/deploy.sh`).
- **Contract.** In: a unit/task definition naming the exact binary, home and script directories; a
  start/stop/restart command. Out: one of `running(pid)`, `stopped`, `restarting`, and the watcher's
  own liveness line in `<config>/sentinel/sentinel.log`. Failures, each named and none silent:
  `unit_missing`, `authority_refused` (polkit/sudo refusal — terminal, never a weaker ownership
  retry), `binary_identity_mismatch` (the unit names a binary that is not the recorded one),
  `manager_not_applicable` (a machine with no manager at all).
- **Contract test.** `rust/wa-sentinel/src/supervision_tests.rs`, `role_tests.rs`,
  `target_identity_tests.rs` (**fast**, when `wa-sentinel` is touched) and
  `scripts/test-deploy-sentinel-sudo.sh` (**gate**) cover the sudo path and identity. **Missing:** no
  test asserts that a unit referencing a replaced binary is refused before it starts.

### 2.2 sentinel → deploy

- **Today.** A drop-box: `<config>/sentinel/requests/*.json`, consumed by `wa-sentinel request
  deploy --expected-sha …`; the watcher records `intent.json`, `ack.json`, `state.json` under
  `sentinel/deploy-protocol/<request-id>/` and settles into `done/` or `failed/`
  (`rust/wa-sentinel/src/main.rs`, `deploy_protocol.rs`, `deploy_outcome.rs`). The node's own
  `/update` writes the same request (`lua/core/update.lua` `M.run`, `M.request_box`,
  `M.request_command`), and answers **queued**, never "updated".
- **Contract.** In: one immutable intent — verb, expected commit, owner, session, reason — and no
  other channel. Out: a request id; then a durable record naming what ran, how long each phase took,
  and one verdict. Failures: `refused(preconditions)` (a verified watcher is not there, a stop file
  is set, a deploy is already pending — `lua/core/update.lua` `M.preconditions`), `refused(dirty)`
  (`tree_dirty`), `refused(downgrade)` (`scripts/deploy.sh`'s downgrade rule), `below_floor` (disk),
  and `silent` when a request neither settled nor was refused inside the idle bound
  (`deploy_idle_bound_secs`).
- **Contract test.** `rust/wa-sentinel/src/deploy_protocol_tests.rs`, `deploy_outcome_tests.rs`,
  `deploy_recovery_tests.rs`, `deploy_visibility_tests.rs` (**fast**); `scripts/test-update.sh`,
  `scripts/test-update-watcher.lua`, `scripts/test-update-release.lua` (**gate**/**fast**).

### 2.3 deploy → host

- **Today.** `scripts/upgrade.sh`: copy the installed binary to `$BACKUP` and `cmp` it (a recovery
  binary that does not match is not a recovery binary), wait for an idle node, install with
  `.new` + `mv -f` (one rename), restart, and restore `$BACKUP` on any failure. Before that,
  `scripts/deploy.sh` proves the candidate on a scratch port with `WASM_AGENT_HOME=$SCRATCH_HOME`,
  its own `--db`, and `env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY`. That last line is already
  the `#122` rule in practice: the candidate runs under a throwaway identity.
- **Contract.** In: one verified candidate directory (`wa_node_binaries_prepare`'s
  `binary_verified: <triple> <dir> <sha12>`), the commit it belongs to, and the phase list to record.
  Out: an installed binary the listener pid proves is *this* install (`deploy.sh` compares the
  listener's pid with `serve.pid`/`sentinel/node.json`), and a record. Failures:
  `candidate_does_not_answer` (no `/health` on the scratch port), `identity_mismatch` (the pid that
  answers is not the pid this install recorded), `downgrade` (this tree does not contain the commit
  `installed.txt` names), `swap_failed` (the rename did not happen — restore the backup and say so).
- **Contract test.** `scripts/test-deploy-node-binaries.sh`, `test-deploy-preconditions.sh`,
  `test-deploy-record.sh`, `test-deploy-downgrade.sh`, `test-deploy-staging-sweep.sh`,
  `test-deploy-self-ship.sh`, `test-deploy-on-main.sh`, `test-deploy-build-status.sh` (**gate**);
  `scripts/test-deploy-policy-order.sh` is the model for a structural test — it reads the script and
  fails when the install drifts back below the restart.

### 2.4 host → components

- **Today.** The supervisor starts a component when every interface it imports is served
  (`rust/wa-kernel-runtime/src/supervisor.rs`: `plan`, `plan_with`, `served`, `note_started`,
  `pending`, `reconcile`), and a service is started/stopped with backoff
  (`rust/wa-kernel-runtime/src/services.rs`: `start`, `stop`; `service_components.rs` /
  `service_components_v2.rs` pick the runner from the module's own imports). A missing component
  answers `component_not_installed:<name>` / `component_*_unavailable` — a named gap, not a silent
  fallback. Installing a staged set is `rust/wa-kernel-runtime/src/install.rs` `upgrade`, today
  driven by `scripts/lib/deploy-components.sh`.
- **Contract.** In: a manifest (name, version, pin sha256, declared capabilities) and a staged module
  pair; a start/stop/status request. Out: `running(instance)`, `stopped`, `refused(grant)`,
  `refused(pin)`, `refused(interfaces_unserved)`. Failures: `component_hash_mismatch`,
  `component_size_mismatch`, `component_install_failed` (the whole previous set is put back and the
  deploy refuses — `docs/RELEASE-UPDATE.md`), `start_by_imports_deadlock` (a cycle in declared
  imports, named with the unsated interface).
- **Contract test.** The parity suites `scripts/test-memory-component.lua`,
  `test-hooks-component.lua`, `test-mesh-component.lua`, `test-selfloop-component.lua`,
  `test-codemode-component.lua`, `test-service-component.lua`, `test-services-cli.lua`,
  `test-features-gate.lua` (**fast**), `cargo test -p wa-kernel-runtime` for the supervisor, and
  `scripts/test-deploy-components.sh` / `test-deploy-components-shipped.sh` (**gate**).

### 2.5 components → core

- **Today.** This arrow is the one the torus *requires* and the tree does not yet have in
  production. The core runs from the installed Lua tree (`WASM_AGENT_LUA_ROOT`, `<install>/lua-core`),
  which the deploy swaps. The component form exists and is measured: `rust/components/agent-core`
  (built by `scripts/build-agent-core.sh`) runs the unchanged `lua/core` inside a wasm component,
  every `host.*` crossing `wa:kernel/host.call` (`rust/wa-capabilities/src/core_component.rs`);
  `docs/KERNEL.md` "A2.1 results" has the numbers (377 KB, ~0.8 µs per host call, 1.45× on
  Lua-compute-heavy scripts, ~1 ms load from cache).
- **Contract (target).** In: the core's declared imports (`wa:kernel/host.call`, `wa:memory`,
  `wa:hooks`, `wa:selfloop`, `wa:mesh`, …), the core's version, and the previous version's handle.
  Out: `served(version)` or `refused(import_unserved, name)`; a core that fails to start leaves the
  previous core serving. Failures: `core_import_unserved`, `core_start_failed`, `slow_host_call`
  (named with the call, because a host call is the only way a guest can hang).
- **Contract test.** **Missing** for this arrow. The parity suites above are the pattern to copy:
  send the same calls through the tree path and the `agent-core` component path and compare field
  for field, ids normalised (`docs/CORE-SPLIT.md`, "What a seam must look like").

### 2.6 core → state

- **Today.** The core owns what the stores *mean*: schema-by-id, `db_ready`, `store_failed` as a
  visible refusal, and the pre-update snapshot in `lua/core/backup.lua` (every store read through
  SQLite's `VACUUM INTO`, busy/locked retried three times, a copy that fails `PRAGMA integrity_check`
  never counted as a snapshot; `rust/wa-snapshot` is the same rule as a library). A refused backup
  deploys nothing (`backup_failed`).
- **Contract.** In: a snapshot request naming every store, each store's own integrity verdict, and a
  destination. Out: `snapshot(ok, per-store)` or `refused(damaged, sqlite's-own-message)`. Failures:
  `store_busy` (retried, then refused), `store_damaged`, `snapshot_unverified`, `schema_newer`
  (an older binary meeting a migrated store must refuse, not migrate backwards).
- **Contract test.** `scripts/test-backup-live.lua` (real stores, a WAL-only row, a damaged store
  refused, retry/backoff) and `scripts/test-backup-locks.lua` (**fast**), `cargo test -p wa-snapshot`.
  **Missing:** no test exercises *restoring* from a snapshot, because nothing restores today.

### 2.7 state → surface

- **Today.** A record seam, and one of the best-tested in the tree. The only inputs to the one
  notice row are the install record (`<install>/installed.txt`: `commit=`, `release=`,
  `binary_source=`, `binary_release=`) and the cached published window
  (`<config>/update-check.json`); `lua/core/update_banner.lua` recomputes the verdict on every read
  and `session_content({notice, build, now})` resolves the one line. `unknown` is a real answer and
  never reads as "up to date" (`docs/RELEASE-UPDATE.md`).
- **Contract.** In: the installed record, the window, and the clock. Out: exactly one of
  `behind(sha12)`, `current`, `ahead`, `unknown(reason)` — reason named
  (`no_recorded_release`, `feed_unreachable`, `no_installable_asset`, `tree_dirty`, …). Failures: a
  record that cannot be read is `unknown`, never `current`; a surface may never claim more than the
  record says.
- **Contract test.** `scripts/test-update-banner.lua` (174 checks, no network),
  `scripts/test-release.lua`, `scripts/test-seamless.lua` (**fast**), `tests/update-banner.js` and
  `tests/seamless-reconnect.js` (**gate**, `js:` set). This is the template every other seam should
  reach.

### 2.8 surface → peer

- **Today.** A request edge, never an effect edge. `wa update <node>` → `lua/core/remote_update.lua`
  `serve(args, caller)`: the peer admits a signed capability call from a node the roster/binding
  already trusts and then writes **its own** deploy request; a relayed shell is refused
  `sentinel_coordinator_only` because a child task may not replace the supervisor it runs under
  (`rust/wa-capabilities/src/operations.rs` sets `WASM_AGENT_PROVENANCE=child`). When a node had no
  door at all, the path that worked was a session started **on that node** by a master
  (`session_start`, `docs/REMOTE-UPDATE.md`, "A node that had no door: `work`").
- **Contract.** In: caller identity, the target commit (an ancestor of `origin/main`), and one
  capability name. Out: `queued(record_id)`, then a status read from the peer's own files —
  `queued | running | installed | failed | silent | unknown`; `installed` only when `installed.txt`
  names the requested commit. Failures: `forbidden_role`, `commit_not_on_main`,
  `commit_not_reachable`, `tree_dirty`, `grant_absent`, and the honest `unknown` when a claim and the
  bytes disagree.
- **Contract test.** `scripts/test-remote-update.lua` (51 checks, **fast**),
  `scripts/test-mesh-admission.lua`, `test-mesh-attest.lua`, `test-mesh-trust.lua`,
  `test-mesh-verb-admission.lua` (**fast**), `scripts/test-relay-attach.lua` (**fast**).

### 2.9 peer → seat

- **Today.** Nothing. A peer can ask a node to update itself; it cannot start, stop or restart that
  node's service, and it should not be able to edit the shared registry — the shipped guard refuses
  exactly that (`lua/core/hooks_defaults.lua`: editing `WASM_AGENT_NETWORK_ADMINS` or restarting
  `wa-rendezvous` is refused with the sentence "this detaches nodes that pin the admin set"). The
  seat is the ring's floor today: the machine's own manager, or an operator, is what brings it back.
- **Contract (target).** In: the neighbour's seat observation — is the unit running, which binary
  does it name, which pid answers `/health`, what does the registry believe about this node. Out:
  `aligned`, `displaced(reason)`, `unknown(reason)`; a repair is *requested* through §2.8's edge (a
  signed ask, or a session on that node), never performed across the seam. Failures: `no_registry`
  and `no_seat` are `unknown`, never `aligned`; `repair_refused(guard)` is reported, not worked
  around.
- **Contract test.** **Missing**, and this is exactly what ring 2 builds.

### Seam coverage, in one table

| seam | today's interface | contract test in the gate |
| --- | --- | --- |
| seat → sentinel | unit/task + manager restart | partial (`supervision_tests`, sudo path); identity-before-start **missing** |
| sentinel → deploy | `sentinel/requests/*.json`, `deploy-protocol/<id>/{intent,ack,state}.json`, `done/`/`failed/` | yes — rust protocol tests + `test-update*.lua` |
| deploy → host | `scripts/upgrade.sh` backup/`.new`/`mv`, scratch-port proof | yes — `test-deploy-*.sh` (gate) |
| host → components | supervisor `plan`/`served`, `install.rs::upgrade` | yes — parity suites + `test-deploy-components.sh` |
| components → core | `agent-core` component, measured, not installed as the core | **no** |
| core → state | `lua/core/backup.lua`, `store_failed`, `db_ready` | yes for take; **no** for restore |
| state → surface | `installed.txt` + `update-check.json` → `session_content` | yes — 174+64 checks, both surfaces |
| surface → peer | `remote_update.lua` signed ask, status read-back | yes — `test-remote-update.lua` |
| peer → seat | nothing | **no** — ring 2 |

## 3. The restorers

Every segment has two, one per direction. **In-node**: the clockwise neighbour, inside the same
machine — normally an A/B slot swap performed by a process that is not the segment. **Fleet**: a peer,
for when the in-node restorer is what broke.

| segment | in-node restorer (A/B swap by the neighbour) | fleet restorer (a peer) |
| --- | --- | --- |
| seat | **exists** — the manager restarts the unit; `-RestoreOnly` for a dead task | **missing** — a peer may not touch the seat; a session started on the node is the only supported door (`session_start`) |
| sentinel | **exists** — manager restart of a stopped watcher; a request survives its death | **partial** — `remote_update` writes a deploy request; a *dead* watcher is not restorable from a peer |
| deploy | **partial** — the sentinel holds the intent through a failed run and `done/`/`failed/` settle it; but the script set replaces itself (`upgrade.sh` `.new.$$` + `mv`) = the one live violation of (b) | **missing** — a peer cannot install a deploy script on another node |
| host | **exists** — `upgrade.sh`: `$BACKUP` + `cmp`, atomic `mv`, restore on failure; scratch-port proof before the swap | **partial** — `wa update <peer>` asks the peer's own sentinel to install a published binary; the effect is still the peer's own |
| components | **partial** — `wa_components_restore_set` + `.prev/components.set` restore the previous triple; the supervisor starts/stops, it does not choose a version | **missing** — no peer serves a component set |
| core | **partial** — `lua-core.prev` + `restore_lua_tree` on a failed upgrade; the node reads its Lua once at start, so the swap is invisible to it | **missing** |
| state | **partial** — the pre-update snapshot; there is no restore path (an older binary refuses a migrated store) | **missing** — no peer holds another node's snapshot |
| surface | **exists** — the host serves the bytes and keeps `$UI_DIR/$asset.pre-upgrade`; the page reloads itself, and a window is never restarted (`AGENTS.md`) | **missing** |
| peer | **partial** — the node re-registers on start; a displaced relay identity is not watched | **missing** — ring 2 |

Two facts worth stating plainly, because they are what the table above is for:

1. **The seat is the ring's floor.** Nothing inside the fabric can bring back a machine whose seat is
   gone. The honest options are to accept the floor (an operator or the OS is the seat's restorer) or
   to build a fleet restorer that reaches the seat *through the node's own manager* on a signed ask.
   Choosing is part of ring 2, not of this document.
2. **Only two segments are restorable end to end today** (host, surface) and two more nearly are
   (sentinel, components). The torus is a design that says which restorations are missing; it does
   not pretend they exist.

## 4. The invariants

- **(a) The ring stays closed.** Never change two adjacent segments in one landing or one deploy —
  one move, one restorer, one observable seam. A landing that changes `scripts/deploy.sh` and
  `scripts/upgrade.sh` *and* the binary is a landing with no neighbour left standing to observe it.
  Enforcement target: the landing queue refuses a row whose changed paths cross two adjacent
  segments, unless the row names the seam test that covers the pair.
- **(b) The restorer of X is not X.** Neither a process nor a node restores itself, and a candidate
  never runs under the live identity (`#122`). Today the rule holds in the scratch proof
  (`deploy.sh`: own home, own `--db`, `env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY`) and is
  broken by the deploy script set restoring itself. Enforcement target: a structural test that the
  swap runs from a process whose home, pid and relay identity differ from the segment's.
- **(c) Contracts live at seams, with a contract test per seam in the gate.** A field a segment
  needs is added to its seam, never read out of another segment's files. Each seam in §2 that says
  "missing" is a gate hole; a new seam lands with its test, or it is not a seam.
- **(d) Neighbours watch neighbours and repair through supported paths only.** A repair that needs a
  guard bypass (editing the rendezvous admin set, restarting the shared registry, stripping a run
  marker, hand-copying a binary) is refused and reported. `lua/core/hooks_defaults.lua` already
  encodes the two refusals that hurt most; a neighbour-watch ring must reuse them, not route around
  them.

## 5. The first ring to build: updates

Target, in one sentence: **the node never does the slow part, and the swap is one rename performed by
a neighbour at a turn boundary.** The table below is the whole ring; "today" is what the code does
now, "build" is what this ring adds.

| piece | today | build |
| --- | --- | --- |
| **A/B slots** | scattered `.prev` conventions: `lua-core.prev`, `<components>/.prev/`, `$BACKUP`, `$UI_DIR/$asset.pre-upgrade`, `.upgrade-proof` | one slot convention under the data root: `slots/a`, `slots/b`, an `active` record naming the served slot plus its sha12 and `compiled_inputs`, and `previous`. Every segment above writes into the *inactive* slot |
| **the staged swap** | performed by the deploy (segment 3 moving segments 3, 4, 5, 6, 8 at once) | performed by the sentinel (segment 2) as one rename of the `active` record, after the neighbour has proved the inactive slot. The deploy script set itself is staged by the sentinel — closing the violation named in §1 |
| **candidate never runs live** (`#122`) | true for the scratch proof only | true for the whole pre-stage: the candidate slot is exercised with its own home, its own `--db`, and no rendezvous/relay environment; a test fails if any of the three is inherited |
| **phase timings in every deploy record** | `wa_phase` prints `deploy: [phase] <name> <s>` to stdout (`scripts/lib/build-status.sh`) and `deploy-result.json` carries commit/hashes/pids/detail only (`scripts/deploy.sh` `write_result`) | the same phases as a `phases:[{name,ms}]` array in `deploy-result.json`, copied into `sentinel/deploy-protocol/<id>/result.json`, and shown by `wa update --all`. A record without timings is a refusal, not a zero |
| **pre-stage on publish** | the publisher records `compiled_inputs=` in `node-<sha>.manifest` (`scripts/publish-node-binaries.sh`), and the node fetches at deploy time (`wa_node_binary_download`) | the quiet tick (`update_banner.tick` in `lua/core/server.lua`) *pre-stages* the inactive slot when a newer release covers this target, so the swap's critical path has no fetch |
| **swap at a turn boundary** | `upgrade.sh` waits for idle (`waiting_for_idle`, `node_is_idle`, three consecutive idle polls, `DEPLOY_IDLE_BOUND`); the node read its Lua once at start | unchanged in behaviour, moved in place: the swap is bound to the boundary as the *first* action after the node reports idle, and nothing else runs between the boundary and the rename |
| **Lua-only releases skip the binary** | a docs/Lua-only commit still resolves a binary by digest (`wa_node_release_digest_search`) and may fetch and verify it | if the candidate's `compiled_inputs` equals the one the installed binary records, the plan has no binary step at all and the record says `binary: unchanged (compiled_inputs=<digest>)` |
| **content-addressed cache** | `<cache>/<sha12>/<triple>` keyed by *source commit*, `.complete` marker, digest fallback by scanning manifests (`scripts/lib/node-binaries.sh`) | keyed by `compiled_inputs` digest: a hit needs no release lookup and no network; the release tag stays as provenance in the record |
| **`wa update --all`** | `wa update [--check]` for this node, `wa update <node>` for one peer (`lua/core/init.lua`, `lua/core/remote_update.lua`) | one call → one table: `node · installed · candidate · channel · plan(binary/lua/components/state) · last phases · verdict`, assembled from `lua/core/fleetview.lua`'s records plus each peer's `status` read. A node that cannot be read is `unknown` with its reason; a refused node says its refusal word |
| **structural gate tests** | `scripts/test-deploy-policy-order.sh` is the only test of this shape (it reads the script and refuses an ordering drift) | two new ones, below |

The two structural tests the ring adds (both read source or a recorded call log — neither can be
satisfied by a comment):

1. **A staged update does no download and no proof on the critical path.** With the inactive slot
   pre-staged, a fixture run of the swap records every external call it makes; the test fails unless
   that list is exactly `rename`, `restart`, `record`. The `WA_NODE_BINARIES_URL` fixture and
   `test-deploy-node-binaries.sh`'s stub style are the mechanism; `test-deploy-policy-order.sh` is the
   structural pattern.
2. **A Lua-only release fetches no binary.** A fixture commit whose `compiled_inputs` equals the
   installed one must produce a plan with no binary step, and a fetcher stub that fails the run on any
   call proves it. The negative half matters as much: a Rust-touching commit must still fetch or
   build, so the test cannot be passed by making the step unconditional.

Ring 1 is done when: the swap is one rename performed by the sentinel, the record of that deploy
carries its phases, a Lua-only update transfers no binary, and both structural tests fail when the
behaviour they describe is removed.

## 6. The second ring: a neighbour watches the relay seam

`#122`'s class of failure is a displacement: the transport seam ends up serving an identity that is
not the live node, and nothing in the tree says so. Today the seam is `rust/wa-mesh/src/relay.rs`
(`seal`, `open`, `send` — a relayed answer must be the same signed statement as a direct one) plus
`rust/wa-rendezvous/src/relay_client.rs`; detection is `fleetview`'s `online`/`last_seen`/`missing`
(`lua/core/fleetview.lua`, `rust/wa-fleetview`) — a *sample*, not a statement about identity.

Ring 2 makes it a seam with a watcher on each side:

- **The seam contract.** In: the registry's view of a node (identity prefix, last seen, address), the
  node's own claim (`/health`'s identity, `installed.txt`), and the age of both. Out: exactly one of
  `aligned`, `displaced(reason)` (`stale_registration`, `foreign_identity`, `identity_mismatch`), or
  `unknown(reason)` when the registry or the node could not be read. `unknown` never reads as
  `aligned` — the same rule `fleetview` already applies to every other field.
- **Who watches whom.** The clockwise neighbour (§1): the peer that reaches a node watches that
  node's relay seat. It is the same edge §2.8 already carries, so the watcher needs no new authority —
  a signed read plus the node's own `/health`.
- **What a repair may be.** Only two things: a signed ask to the node to re-attach (its own process,
  its own key, §2.8's edge), or `aligned=false` reported to the operator and to the node's own log.
  Never an edit of `WASM_AGENT_NETWORK_ADMINS`, never a `wa-rendezvous` restart, never a hand-copied
  key — invariant (d), and the guard in `lua/core/hooks_defaults.lua` already refuses both of the
  destructive ones with a reason and a safe path.
- **Proof.** A two-node fixture on loopback with a stub registry: (1) both nodes registered → both
  neighbours `aligned`; (2) one node's registration replaced by a foreign identity → its neighbour
  reports `displaced(foreign_identity)` and the node's log names it; (3) the registry unreachable →
  `unknown(registry_unreachable)` on both sides, and nothing is "repaired"; (4) the neighbour asks the
  node to re-attach, the node does it with its own key, and the next read is `aligned`; (5) the
  negative that matters: the neighbour never edits the admin set and never restarts the registry —
  the guard's refusal is the evidence.

## 7. What this document does not decide

- Whether the seat keeps its floor (an operator/OS restorer) or gets a fleet restorer. Ring 2 needs
  the answer; ring 1 does not.
- Which segment becomes "the core" once the Lua core is the `agent-core` component (§2.5). The ring
  order survives either answer, because the arrow moves with the bytes.
- Any timing: this document names phases to record (§5) and deliberately invents no numbers. The
  measured cycle in `docs/W6-UPDATE-CYCLE.md` (139.6 s deploy, 32.8 s of it compiling) is the
  baseline ring 1 has to beat, and its own record is where the comparison is made.
- Any change to the prompt, the envelope or the law text: those are not segments of this torus and
  this document proposes none.
