# federated-connector-read — a relayed connector read could not observe its own session

Mission: `federated-connector-read` (G candidate, Fable 24/11). Branch `change/federated-connector-read`
off `origin/main` `4bceddd5`. Report written 2026-11-24 (local -03:00), node avell.

## 1. The report, and what it turned out to be

Victor, 21:55-21:57Z: on the laptop, `peer_work__mcp_google_imap_list_accounts` and work's other external
connector failed three times with

    mcp_session_startup_failed … operation_not_yours: operation op-… is not your operation:
    another session owns it. Only an explicit node scope may read or act on it.   outcome not_submitted

**The cause is one asymmetry, and it is on the PEER's side: the node decides which owner an operation is
recorded under, and never told the caller what it decided.**

- A relayed call runs on a thread whose runtime owner the relay lane installed
  (`relay:<rid>`, `rust/wa-rendezvous/src/binding_runtime.rs:131`; the legacy relay loop does the same at
  `rust/wa-capabilities/src/serve.rs:3429`), and `configure_spec` prefers that context over the owner the
  caller named (`rust/wa-capabilities/src/operations.rs:1001`).
- A connector read starts a **persistent read session** as a supervised operation and names its own owner
  (`lua/core/mcp_session.lua:147`, `slot_owner = ctx.session_id or 'mcp-read-session'`), then names that
  same name again on its own first wait (`:153`) and on every later status/cancel/await.
- `Caller::owns` compares a sessionless caller's name with the recorded runtime owner
  (`rust/wa-capabilities/src/operations.rs:1268-1303`). `mcp-read-session` ≠ `relay:<rid>` → its own
  operation is refused, and the peer answers `mcp_session_startup_failed`.

It is a **regression from `6d30aa1e` (2026-11-18, session-isolation r2)**, which made a sessionless caller
match by runtime owner. Before it, `owns` answered `owner.is_empty()` for such a caller — the row's
*session* is empty, so the read session's own wait matched. The condition it exposed had existed since
`fe599864` (2026-11-10) began stamping relayed calls with `relay:<rid>`; nothing compared the owner until
18/11. `6d30aa1e` is an ancestor of `v0.1.1` (`2104a4d8`), which is why the released build has it too.

## 2. Reproduced first, on three pairs, with real processes

Measured before any code changed; the full record is `ready-1.md` in the mission directory, and the
harness that produced it (`probe/probe.mjs`) is the scratch ancestor of the row in §4.

Three real processes per pair on this machine — a scratch rendezvous, a caller node and a peer node, each
with its own HOME, key, database and ports; the peer enrolled through `wa bind` + the master's accept so
its calls arrive in the relay lane; a stub stdio MCP server (`scripts/fixtures/mcp-session-peer.mjs`) with
one read tool registered through `mcp.control put → probe → enable`; the call made through
`lua/core/nodes.lua`.remote_call(peer, "federation", …), which is what `peer_<node>__<tool>` runs.

| pair | caller | peer | result |
|---|---|---|---|
| (i) | main `4bceddd5` | main | **fails**, `mcp_session_startup_failed` / `operation_not_yours` |
| (ii) | main | v0.1.1 `2104a4d8` | **fails**, identical |
| (iii) | v0.1.1 `2104a4d8` | v0.1.1 | **fails**, identical |

The v0.1.1 binary is the published asset, verified: `wa-linux-x64-musl-2104a4d88a37.tar.gz` (21,697,226
bytes); its `files.sha256` hashes to `5eafe945…4cb956`, which is `bundle.manifest`'s `files_sha256`;
`sha256sum -c files.sha256` passes on every file; the binary answers `wasm-agent v0.1.1 · v2104a4d8`, the
commit `releases/index-linux.json` lists for that tag.

The owners, from the peer's own operation store (`.wasm-agent/operations/<id>/state.json`) after pair (i):

| operation | recorded `owner` | recorded `session` |
|---|---|---|
| the operator's connector probe | `mcp-control` | `""` |
| the same read on the peer, no relay lane (control) | `mcp-read-session` | `""` |
| the federated read session | `relay:2122d5ff-…` | `""` |

So: **Lua starts it with `mcp-read-session`; the host records `relay:<rid>`; the wait names
`mcp-read-session`.** The control in the same run — the same tool on the same peer with no lane under it —
answered `{"ok":true,"session_mode":"persistent-read"}`, so the connector, the stub and the read session are
all sound.

Classification: **(i) fails → G blocker (regression)**; (ii) and (iii) failing as well means the fleet's
rollout order is *not* the cause and no build of this shape could have worked. It is not
"pre-existing H week 1" in the sense of a missing feature: it is a working path turned off on 18/11.

A second measured effect: the refused session was **left running** for its full 3600 s, with its row
`accepted`/`settled:false`, because Lua never reached the code that cancels it.

## 3. The fix (`138f621d`)

The host is the authority on whose an operation is; the receipt now says what it recorded, and the callers
read it back.

- `rust/wa-capabilities/src/operations.rs` — the `start` receipt already copies the cwd the node resolved;
  it now also copies `owner` and `session` from the operation's own record
  (`rust/wa-capabilities/src/operations.rs:1535`, commit `138f621d`). Nothing
  widens: a sessionless caller still owns only what was started under its own owner, and
  `operation_not_yours` is unchanged for anybody else's row.
- `lua/core/mcp_session.lua` — `slot.owner = start.owner or slot_owner` at `:155`, so every later
  wait (`:158`)/status (`:178`)/cancel (`:164`/`:219`)/await (`:220`) names the recorded owner; and a
  startup that fails now cancels the session it started (`:164`) instead of parking it on the peer for an
  hour (`138f621d`).
- `lua/core/mcp.lua` — the one-shot client path (`mcp_<tool>` for a write) names
  `start.owner or op_owner` (`:1171`) on its await (`:1172`) and on its cancel (`:1174`); it had the
  identical gap (`138f621d`).

Red/green on the two-node probe: before, `mcp_session_startup_failed`/`operation_not_yours` with the row
owned by `relay:<rid>`; after, `{"ok":true,"session_mode":"persistent-read","status":200}` with the echoed
value.

**It is a peer-side fix.** A fixed master calling an unfixed peer still fails: `work` (`7865a08e`) has to
run a build with `138f621d` before the laptop's federated connector tools answer again.

The same shape exists in two more callers, which this branch does **not** touch: `lua/core/accepted.lua:181`
and `:197` (start and status with the same named owner) and `lua/core/session_watch.lua:329`
(`session:<id>`). By reading, a relayed or child-task call through them would be refused the same way; that
is read, not measured, and it is named for the next round rather than changed without a test.

## 4. The row (`8cb49201`, `39079381`)

`scripts/test-federated-connector-read.mjs` — three processes, two scratch homes, a scratch rendezvous, an
enrolled peer, a real relayed call. Nine checks; the two that matter assert both halves:

- `ok: the federated connector read answers the caller` — the red/green for this bug;
- `ok: the call was really run in the relay lane (its read session is owned by relay:<rid>)` — without it
  the row could pass on a peer reached directly, where the bug never showed.

Plus a control first (`the same read answers ON the peer with no relay lane under it`), so a failure cannot
be blamed on the stub. `scripts/test-federated-connector-read-node.lua` is one node's half
(`setup | local | call`), run as a `wa --script` process in each home; run on its own it prints
`SKIP …` because it has no verdict without the harness (`39079381`).

Wired in **two** places, because "joins main-health" means "runs in the fast path" —
`scripts/main-health.sh` records a verdict about main by running `scripts/fast.sh`:

- **`scripts/test.sh:1749`** — `gate_run node scripts/test-federated-connector-read.mjs "$BIN"`, beside the
  two-node speech row (`8cb49201`);
- **`scripts/fast.sh:1299`** — `WA_BIN="$bin" check federated-connector-read node
  scripts/test-federated-connector-read.mjs` (`9863a226`), measured at **3.8 s** wall on this node, so it
  costs the fast path four seconds to be able to say the cross-node connector read is green.

Hermetic: every `WA_*`/`WASM_AGENT_*` variable (vault included) is dropped before any child starts, and the
harness refuses to run when `WASM_AGENT_HOME` is the real `~/.wasm-agent`. It honours an inherited
`WASM_AGENT_LUA_ROOT`, which is how every row here names the tree it judges. It calls no live node: its
only peers are the scratch nodes it started.

### Red before the change (rule 16)

`bash scripts/test-discriminates.sh origin/main` on this branch:

    discriminates   scripts/test-federated-connector-read.mjs   federated connector read FAILED (1 of 9 checks)
    unrevertable    scripts/test-federated-connector-read-node.lua   this branch changes rust/ …
    rows: discriminates=1 unrevertable=1  —  1 discriminating, 0 blocking

The one red check is the right one; re-running the row against a scratch worktree of the base with this
tree's binary (`WASM_AGENT_LUA_ROOT` = a worktree at `4bceddd5`, never `git stash`) names it:

    ok: the same read answers ON the peer with no relay lane under it (the control)
    FAIL: the federated connector read answers the caller — … "error":"mcp_session_startup_failed" …
          "error":"operation_not_yours" …
    federated connector read FAILED (1 of 9 checks)

## 5. The wider check, and the one failure that is not this branch's

**The crate this branch changes: `cargo test -p wa-capabilities` with a scratch HOME — 411 passed, 1
failed.** The one failure is `capabilities::tests::documented_inventory_matches_the_live_registry`:

    registered but undocumented in docs/HOST.md: ["run_state"]

**Pre-existing, proved:** `run_state` is registered at base `4bceddd5`
(`rust/wa-capabilities/src/capabilities.rs:136`) and `docs/HOST.md` at that same commit mentions it zero
times (`git show 4bceddd5:docs/HOST.md | grep -c run_state` → 0). Nothing in `138f621d`, `8cb49201` or
`39079381` registers a capability. Without a scratch HOME, four more of these tests refuse to run by their
own guard ("this test starts real operations, so HOME must be a scratch or temp directory") — the guard
working, not a failure of the code.

**The fast path: `bash scripts/fast.sh --jobs 8` — 484 checks, 70 failed, 0 skipped.** It was given
`WA_BIN` = this tree's **debug** binary, and every failing row is one that needs something that binary does
not carry: embedded code-mode assets ("this node has no embedded code-mode assets", `codemode_not_enabled`),
a pty/model fixture, a release build (`release-channel`), or disk headroom
(`disk_cap_refused_before_launch`). Rows it names: the `test-codemode-*` family, the `*-pty` rows,
`test-operation-cpu-priority`, `test-operation-answer-not-a-raise`, `test-session-vars`,
`test-write-node-receipt`, `check-install-guards`, `check-build-info`, `check-deploy-wait`,
`check-mission-amend-resume`, `check-release-channel`, `check-tmp-cleanliness`.

**Nothing in mcp/, federation, operations or session isolation failed there:**
`test-federation.lua`, `test-mcp-command.lua`, `test-mcp-component.lua`, `test-mcp-native.lua`,
`test-mcp-node-runtime.lua`, `test-mcp-registry-state.lua`, `test-mcp-request-shape.lua`,
`test-mcp-retired-connector.lua`, `test-mcp-session-settlement.lua`, `test-mcp-share.lua`,
`test-mcp-vault-approval.lua`, `test-operation-cwd.lua`, `test-operation-blocked-on.lua`,
`test-operation-queue-priority.lua`, `test-operation-survives-turn.lua`,
`test-accept-two-process.lua` and `session-isolation` all pass. The two `test-operation-*` rows that do
fail fail on `codemode_not_enabled`, not on the receipt.

The 70 were **not** re-run with a release binary: that is a ~35-minute suite on this node, and this session
does not claim they pass. They are named as unjudged, which is what they are.

**The fast-path wiring itself is measured**, with the Lua rows narrowed (`WA_FAST_ROWS`, one row) so the run
is minutes rather than the whole suite — 139 checks, 22 failed, and among them:

    fast: federated-connector-read ok (3999ms)

The 22 are the same families as the full run and none is this branch's: the ten always-on
`scripts/test-land-*.lua` rows (each `host_error: disk_cap_refused_before_launch` — this node's own disk
guard, `/home` at 81 % when the run was made), the `*-pty` rows, `build-info`, `install-guards`,
`mission-amend-resume`, `release-channel`, `tmp-cleanliness`, `codemode-parity`, `edit-aliases`, and
`rust wa-capabilities` — whose one failure is the pre-existing `run_state` line above. No mcp, federation,
operations or session row failed in either run.

## 6. Texts to approve

New or changed model- or operator-facing strings, verbatim. Field names first, then the gate's own lines.

1. The `operation start` receipt now carries two more keys: `"owner"` and `"session"` (the values the node
   recorded). No sentence was added, removed or reworded on any refusal path.
2. `federated connector read: <binary> (lua <lua tree>)`
3. `  ok: a scratch rendezvous lists both nodes (<url>)`
4. `  ok: the peer submits its binding request`
5. `  ok: the master accepts the peer`
6. `  ok: the peer is attached to the relay (its calls arrive in the relay lane)`
7. `  ok: the peer publishes the stub read tool`
8. `  ok: the same read answers ON the peer with no relay lane under it (the control)`
9. `  ok: the federated connector read answers the caller`
10. `  ok: the call was really run in the relay lane (its read session is owned by relay:<rid>)`
11. `  ok: the read session rows carry the session the node recorded`
12. `  FAIL: <the same label> - <the answer>`
13. `federated connector read ok (9 checks)` / `federated connector read FAILED (<n> of 9 checks)`
14. `federated connector read: SKIPPED (no wa binary: pass one, or set WA_BIN)`
15. `federated connector read: FAIL (the stdio MCP fixture is missing: <path>)`
16. `federated connector read: FAIL (refusing to run with WASM_AGENT_HOME at the real ~/.wasm-agent)`
17. `federated connector read: FAIL (the scratch directory is the real node home)`
18. `  FAIL: the harness threw - <message>`
19. `SKIP this file is one node's half of scripts/test-federated-connector-read.mjs; it has no verdict of its own`
20. `  work kept: <path>` (only with `WA_FED_KEEP=1`)

## 6b. The second round (`c066c713`): nothing outlives the call, and the old peer named

Fable's G-blocker round, with the measurements in `ready-fix.md`:

- **The leftover is ~30 s, not 3600 s.** Measured on a matched buggy build: the read session's row sits
  `accepted` under `relay:<rid>` for ~25-30 s and then settles by its own idle timer (`idle_ms=30000`);
  3600 is the operation's timeout cap. During that window `/health` carries the id in `operations` — the
  field `wa-sentinel`'s `activity_of` reads — so a deploy asked for in the window is held with "the node
  is busy: a run, a subagent or an operation is in flight". After it, idle.
- **(e) MEASUREMENT ONLY — there is NO fix for it in this branch** (Fable's clarification, 25/11). The
  question: does an operation record whose process is gone still read "running" after a node restart?
  **Answer: NO.** Two measurements, both on scratch homes:
  1. A node restarted with an unsettled row on disk: the row reads `completed`/`settled` and
     `/health` answers `operations: []` (the `probe/lifetime.mjs` run in `ready-fix.md`, measured *after*
     the restart);
  2. the sharper one — a row whose supervising process is gone, read by a *different* process (which is what
     a restart is): it answers
     `{"settled":true,"state":"outcome_unknown","error":"operation_owner_not_attached; it may still be active
     elsewhere; reconcile effects, never replay blindly", "owner_gone_note":"the process that started this
     operation is gone and the operation never reported an outcome: its state above is the last one that
     process recorded. … Nothing was replayed and no success is claimed."}`
     — i.e. `settled:true`, never "running".
  So nothing in this branch reconciles operations: `git diff --name-only 4bceddd5..HEAD` shows
  `rust/wa-capabilities/src/operations.rs` changed only by the two receipt fields (`138f621d`), and no
  other file near that machinery.
- **(e)+(g) together**: an operation whose process is gone does **not** stop an update on a restarted node —
  after the restart `/health` answers `operations: []`, which is the field `activity_of` reads, so
  `hold_for` answers `None` and the request is `ready`, not `held: node busy`. The ~30 s hold of (g) belongs
  to a *live* session on a *running* node, not to a restarted one. This is reported for Fable to decide;
  the branch fixes the federated bug (b) and nothing else.
- **The fix** is one exit in `lua/core/mcp_session.lua` (`done()`): a peer call closes the session it
  started, on success, on every failure return and on timeout, under the owner the start receipt answered.
  A node's own turn keeps its pooled session. `Caller::owns` is untouched, and the row proves it: a second
  relay id is refused by name on the first one's operation.
- **The old peer is named, not excused** (`lua/core/federation.lua`, allow-listed on exactly
  `mcp_session_startup_failed` + `operation_not_yours`): `<peer> runs a build that cannot serve connector
  calls for another node; update <peer>`, with the inner cause, the owner, and the statement that the
  connector server was not contacted. A caller cannot cancel an operation another node owns, and does not
  pretend to.
- **The row is 13 checks** now: the read through `federation.call` (the model's route), the write door, the
  relay lane's owner, the foreign relay id refused by name, and nothing left running. `WA_FED_PEER_BIN`
  runs the same row against an un-updated peer (11 checks).
- **Red on `2d7ac300`** (the base Fable named), matched build + its own Lua: **3 of 13** — the read, the
  write, and "nothing the federated read started is still running on the peer".
- **Still not proved**: the direct (non-relay) carrier and the mesh carrier (the scratch peer never got an
  endpoint into the roster), and the sentinel's own `request` command was not run — the hop from the
  measured `/health` body to "held: node busy" is its code, cited line by line.

## 7. What this report does NOT claim

- **The direct (non-relay) cross-node arm was not proved.** In the scratch fixture the peer's roster entry
  carried no endpoint (the heartbeat announced none for the scratch node), so `nodes.lua` fell back to the
  relay and every "direct" attempt still arrived in the relay lane. What is proved is the relay carrier —
  the reported one — and the local control with no lane at all.
- **The mesh carrier** (`WASM_AGENT_MESH`) and a peer that is not enrolled through `wa bind` were not
  exercised.
- **The write path was read, not measured.** `lua/core/mcp.lua`'s one-shot path is fixed on the same rule,
  but no row drives a write tool through a relay yet.
- **The cancel-on-failure half is not measured either**: no row forces a startup failure now that the
  owner mismatch is gone. The code path is `lua/core/mcp_session.lua` (`138f621d`), and it is named here as
  a claim about the diff, not as a measured effect.
- **Pre-existing failures are named, never excused** — see §5.
- The branch is **17 commits behind `origin/main`** (which moved from `4bceddd5` to `2d7ac300` while this
  mission ran). None of those commits touch `lua/core/mcp_session.lua`, `lua/core/mcp.lua`,
  `rust/wa-capabilities/src/operations.rs`, `rust/wa-rendezvous/src/binding_runtime.rs` or
  `lua/core/server.lua` (`git log --oneline 4bceddd5..origin/main -- <those paths>` prints nothing), so the
  finding and the fix are unchanged in relevance. The branch was **not rebased**: it is not a reviewed
  branch, but restructuring it is the orchestrator's call, not this session's.
- The row commit `8cb49201` carries two typos in its message ("frerated", "startd"). They are left as they
  are rather than rewritten.

## 8. Where the facts in the brief were re-measured

- `lua/core/mcp_session.lua:147-153` — confirmed before the fix: 147 is the owner expression, 148 the
  start, 153 the first wait. (After `138f621d` the same call sites are 147, 148, 155 and 158.)
- "On work, /health showed relayed ops with owner `relay:<uuid>` and session `peer:<id>`" — the owner is
  exactly what this mission measured on a scratch peer; the **session** was empty (`""`) on the connector
  read-session row. `peer:<node_id>` is the session the peer-*bash* adoption route stamps
  (`lua/core/server.lua:1138-1140`, `adopt_session`), a different route. The brief's pairing of the two
  values therefore describes two routes, not one row.
- "The model then tried remote(capability "mcp"/"sessions") and got `capability_not_granted` — a correct
  refusal" — agreed, and untouched here.
