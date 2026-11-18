# wasm-agent mission queue (orchestrator: Claude; executor: wa on avell, codemode)

Order chosen 18/11: unblock missions first, then the vault, then the folder model on top of both.

| # | mission | state | why here |
|---|---|---|---|
| 1 | change/harness-fixes (62c3c064) | done, tests re-run green; review + land | unblocks every mission on avell (CodeAct, wave refusal, run lock) |
| 2 | change/harness-fixes-rust | running | sentinel withdraw, log spam, rendezvous address; same area as 1 |
| 3 | change/vault-one (5cd9a710) | done, ssh/migration proof + cargo (wa-vault 34, wa-kernel-runtime 183, workspace check) re-run green; polish: unused wa-keystore dep; review + rebase on 1 + land | one vault; then migrate the live vaults (avell, laptop) with import-legacy before stopping the Python service |
| 4 | change/fleet-wire | queued (brief fleet-wire.md) | Victor 18/11 "i like automatic": SSH access updates on mesh attach; needs 3 landed; mesh/vault area, can run beside 5 |
| 5 | change/session-home | queued (brief session-home.md) | one lazy folder per session; needs 1 and 3 landed |
| 6 | change/vault-git-helper | to brief | git/gh credentials through the vault, one repo first |
| 7 | change/guard-wait | to brief | progress guard counts a wait on a running operation as progress (weakness 10) |
| 8 | change/polish-1811 | queued (brief polish-1811.md) | 7 frictions from Victor's real session 378934d2; after guard-wait (same area) |
| 9 | change/python-codeact | queued (brief python-codeact.md) | Victor 18/11 "all the way": js + py peer run blocks, one WIT tool bridge, composition, locked libraries; after polish-1811 (same files) |
| 10 | change/green-main | to brief | main has pre-existing failures (5 sentinel, 2 mesh relay, 6 Lua rows, stale ENVELOPE.md); every mission re-proves them |
| 11 | project manifest, GitHub App token minting | later | after 5 proves the helper |

Rules: one mission per area at a time (missions 1/3/4 touch the same Lua); max 3 on avell; launcher puts
the toolchain on PATH, runs codemode from the mission dir, says "build here only".

Approved 18/11 (Victor "ok"): land harness-fixes first, rebase vault-one on it; after deploy migrate avell's and the laptop's live vault keys with `wa vault import-legacy`, switch nodes to `wa vault serve`, only then stop the Python service. Real-node fleet enrollment still per node with Victor's go.

## Status 18/11 ~10:10 BRT
- Ready to land: harness-land (97ef887f, 4 rounds, reviewed; mesh pin 11/11), release-glibc (d275a7ba, reviewed).
- Landing blocked: main is red on avell (13 pre-existing); `wa land` gate cannot pass -> change/green-main now on the
  critical path (base harness-land). Preflight done: oc-in remote added on avell; main push via openclaw (GitHub OK);
  signing via the laptop wa-vault container API (work has no admin token); ring `--ring work:binary,avell:binary,
  mail:binary,openclaw:binary` (nextcloud out until its key is installed).
- Proposal (later): baseline-aware gate - fail only on reds not present on the base, so a red main never deadlocks
  landing again.
- Running: green-main, vault-one r2, mission-fabric r2, guard-wait. Done, waiting: fleet-wire (rebase on vault-one r2).

## Victor 18/11 ~10:30: the mastermind direction
- Quota: opencode-go 7d at 99% (5h 13%, 30d 60%). No new launches until Victor's bigger key is wired (vaults on
  avell + laptop, via the write-only /login door, never read). Then relaunch green-main (died: guard on a codemode
  wait, 0 files changed), and anything the cap kills.
- New: change/fleet-view (Fleet View: `<` panel of nodes + sessions, enter/back, read-only live view) and
  change/mastermind: refine the EXISTING fork/spawn/subagent machinery (brutal refinement, meticulous tests, polish), every subsession visible in Fleet View; prompt text verbatim to Victor first.
- Order: round 1 land (harness-land + release-glibc + green-main + guard-wait + mission-fabric + missions-docs)
  -> fleet-view (UI, can run beside vault-one) -> mastermind (needs mission.sh, guard-wait, fleet-view landed)
  -> from then on Claude talks to wa's master instead of driving missions itself, and measures the parity.
- New (Victor 18/11): change/fabric-bridge - wa serves its fabric API as an MCP server (`wa bridge serve`) so
  other harnesses (Claude Code first) drive it; ONE fabric API shared by in-CLI orchestration, Fleet View and the
  bridge. Order: fleet-view -> mastermind (defines the fabric API) -> fabric-bridge -> Claude connects to it.
- Order decided 18/11: mastermind (fabric API + fork/spawn refinement) -> in parallel fleet-view (CLI face) and
  fabric-bridge (MCP face `wa-fabric`, full orchestration tool set) -> Claude connects to wa-fabric.
- Approved 18/11 (Victor "go"): change/ab-actions - JSON vs codemode vs CodeAct on 4 read-only real tasks, 3 runs
  each, decision rule fixed up front; runs right after landing round 1 is deployed; baseline for python-codeact.
