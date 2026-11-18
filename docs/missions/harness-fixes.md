# Mission change/harness-fixes — the 9 weaknesses measured on avell and work, 18/11

Base: fresh origin/main (74d48431 or later). One implementation per behaviour; errors quote the
offending input and name the real cause; one reused build dir. Commit locally, never push.
Each item: a test that fails before the fix and passes after, quoted in REPORT.md.

## Measured evidence (18/11, avell = release node-63c4dad7, work = 14963b6f)

1. **CodeAct (default mode) cannot act on avell.** Same prompt ("run git log -1 in the worktree, read
   3 lines of docs/VAULT.md, reply TOOLS_OK"), run from a non-git directory:
   - default (WASM_AGENT_RAW_CODE unset): the model called `session_worktree({"action":"status"})`
     3 times, `guard_repeated_calls` ended the turn, rc=1. In another run it wrote a ```js run block
     as its final message and the turn ended with "1 round · 0 tools" - the block never ran.
   - `WASM_AGENT_RAW_CODE=codemode`: TOOLS_OK, 1 tool, 15 s.
   Fix so the default mode does what codemode does. A run block in the model's message always runs.
2. **A turn whose last run block never ran exits 0** (`wa chat --once`, rc=0, "0 tools"). A turn
   that ends with an unexecuted action is a failure with a named reason, rc != 0.
3. **The prompt pushes the model to `session_worktree` when no workspace exists.** After
   `session_worktree set path=...`, `status` returned nothing new, so the model looped until the guard
   (lua/core/agent.lua, codemode_policy.lua, envelope.lua, progress_guard.lua). `status` must say,
   in one line, what is bound and what to do next; with no workspace required the tool is not offered.
4. **No wave registration = no worktree for any session started inside the repo.** On avell
   (repo moved from the old desktop) every session in `~/wasm-agent/checkout` or its worktrees is
   refused `workspace_wave_admission_refused:wave_registration_required` (lua/core/workspaces.lua:309/334,
   scripts/wave-entry.mjs:23). The refusal must reach the model/operator with the reason and the one
   command that fixes it; a top-level operator session (`wa chat` by the human) on a node with no
   wave authority works in place rather than being refused. Document the registration in docs.
5. **A finished session keeps its run lock.** `wa chat --resume <id> --once "<note>"` right after the
   session ended (rc=1) -> `run_resource_refused` (claim key `session:<id>`, lua/core/agent.lua).
   A settled run releases its claim; a stale claim from a dead process is reclaimed with an audit line.
6. **wa-sentinel cannot withdraw a request.** A `request deploy --expected-sha ... --session X` was
   held `deploy_protocol_not_ready` forever; the only way out was moving the queue file by hand.
   Add `wa-sentinel request withdraw <id>` (queued/held only; never a running one; audit line).
   Also: a held request must say in `status` how to unblock or withdraw it.
7. **Sentinel log spam.** `~/.wasm-agent/sentinel/sentinel.log` on work has ~520,000
   `return-observation-problem ... No such file or directory` lines (rust/wa-sentinel/src/main.rs:3007),
   the same 5 ids every tick. Log a given (id, error) once, then retire or quarantine the entry.
8. **The rendezvous URL is stored as a peer's direct address.** work's `mesh/peers.json` gives avell
   `addresses: ["https://rendezvous.colmeio.com"]` (source "roster"; the signed roster has `[]`); every
   call first fails `resolve_failed:invalid port value`, then relays. A binding's `state.service` is the
   relay, never the peer's address.
9. **Deploy refuses with two worktrees on branch main** ("exactly one canonical main checkout is
   required", scripts/runtime-install-binding.mjs:28) after 4 min of build+prove. Check it in preflight,
   before building, and name both paths in the refusal.

## Done when

All 9 have a failing-then-passing test; the fast suite is green; REPORT.md lists each item with the
test name and the quoted before/after line. No real node state touched; no push.

## Found later (18/11, harness-fixes-rust session)

10. **The progress guard kills a legitimate wait.** After 126 rounds the turn ended with
    `guard_repeated_calls` on `tools.operation({action:"await", id:"op-…", wait_for:"settled"})` repeated 3 times
    while a long cargo test ran. Awaiting the same still-running operation is waiting, not a loop: the guard
    must count it as progress while the operation's state is running (or `await` must block up to its timeout).
11. **Cost of a long mission:** 126 rounds, ↑15.3M input tokens (98.7% cache hit), 28m50s. The whole history
    is re-sent each round; worth measuring against a compaction or checkpoint policy.
12. **A provider stall kills a whole mission.** mission-fabric 18/11 11:58: `provider_stalled - timeout:
    receive response` after 20 rounds / 7 min, with 5 sessions sharing one OpenCode Go key. One stalled
    request ended the turn (rc=1); nothing was retried. A stall before any byte arrived is safe to retry
    with backoff (no effect was dispatched); say so in the run and count it.
13. **`wa chat --once` exits "failed" while the node keeps running the turn.** mission-fabric 18/11: session
    830fa92f printed `provider_stalled ... failed` and the CLI exited rc=1, but the node-side run continued and
    kept writing the worktree; a relaunch became a second writer (two sessions interleaved in one branch,
    measured in its REPORT). The CLI's exit must mean the run ended: either it waits for the node-side run to
    settle, or it cancels it, and its rc says which. A run must not outlive its launcher silently.
