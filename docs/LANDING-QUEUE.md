# The landing queue

One lander at a time on the canonical checkout, FIFO, with a lease, a refusal for a tree nobody owns,
and a retest decided by what the upstream move actually changed.

`scripts/landing-queue.mjs` (CLI) over `scripts/lib/landing-queue.mjs`. Durable state, no watcher, no
scheduler, no recurring wake. Wired into `scripts/fast.sh` and `scripts/test.sh` by
`scripts/test-landing-queue.mjs` (43 checks, ~13 s, self-contained).

## Why it exists

Measured on wasm_the_first, 2026-11-10, in one session (`883ffeda`):

- six landings interleaved on `origin/main` while that session landed two branches
  (`e7470cc8 -> 12bae363 -> cb0bf23d -> ad488c22 -> b7103c01 -> 261c7d37`). Each move cost a rebase
  plus the full fast path for the branch **and** for a pristine base: 6-10 minutes a round, ~20
  minutes lost in that session alone;
- two of those six moves were docs-only (`cb0bf23d`, `ad488c22`: `skills/clean-disk` and its report
  script) and still forced a full retest of Rust/Lua branches;
- in the same window another session (`e0fc6da6`) edited the canonical checkout directly for ~25
  minutes; the deploy then refused the dirty tree and blocked the landing's deploy for ~7 minutes.

Both failures are queue failures: the tree had no owner, and the retest decision was made by the shape
of a rebase instead of by what changed.

## The five things it decides

### 1. One lander at a time, in order, with a lease

```
node scripts/landing-queue.mjs land --branch change/<name> --checks "bash scripts/fast.sh"
```

`land` enqueues, waits, is handed the lease, lands and releases. Anyone else who asks is told their
position and the holder while they wait:

```
landing-queue: #7 enqueued for a073ee85-... (ledger-live-session): branch change/x, base 261c7d37
landing-queue: #7 waiting: position 1 of 3; holder #5 883ffeda-... on change/y for 142s
landing-queue: #7 GRANTED to a073ee85-... on change/x after waiting 218s (base 261c7d37, lease 6d16db85, expires in 1800s); 2 waiting
```

The lease is an **OS-held lock**, the repository's own liveness primitive
(`rust/wa-host/src/resources.rs`, shared through `scripts/lib/sqlite-lease.mjs` with the serial gate's
lane): an exclusive SQLite lock the kernel drops when the process holding it dies. A pid is evidence,
never the latch. That is deliberate: lesson `les-dcbabb9d2835` records a killed deploy whose
`.deploy.lock` held a dead pid and blocked every later deploy for **1h44**, because nothing reclaimed
it. A lease cannot do that - a dead holder's lock is free the moment it dies, and the queue then
reclaims the row **with a logged reason**:

```
landing-queue: #9 reclaimed after 31s: holder pid 41232 is gone, lease 0b0e... not held; owner a073ee85-..., branch change/x, base 261c7d37
```

Rules, stated so a reader can check them against the code:

- a holder whose lease is free and whose pid is dead **or belongs to another boot** is reclaimed
  automatically and logged (`reclaimed`, `history`);
- a holder whose pid is **alive** but whose lease is gone is `orphaned` and is *not* freed: two
  landers on one tree is the storm this removes, so that row waits for a person
  (`reconcile --id <n> --evidence <text>`);
- `--force` on `reconcile` ends a live holder's claim; the holder re-checks its own token before the
  merge and before the push and aborts instead of pushing, so a forced reclaim cannot produce two
  publishers;
- `acquire` blocks and holds the lease in its own process (for a caller that keeps its own runner),
  and stays alive until `release --id <n>`; `land` is the same thing in one process.

### 2. A dirty canonical checkout nobody owns is refused, by name

The canonical checkout is not an editor. `acquire`/`land` refuse before queueing when the tree is
dirty and no lease is held, and `land` refuses again under the lease (a merge starts from a tree that
is exactly `origin/main`):

```
landing-queue: dirty_canonical: C:/.../wasm-agent has 2 uncommitted change(s) and nobody holds the
landing lease: scripts/publish-node-binaries.sh, tests/x.lua.
  The canonical checkout is not an editor: work in your own worktree (a change/<name> branch), commit
  and push it, and let the landing queue merge it. ...
```

`status` flags the same condition with `canonical_dirt` and the file list. This is the `e0fc6da6`
failure made visible instead of discovered by a deploy 25 minutes later.

### 3. Retest only what can change the result

The decision is a **digest over a tree's test-relevant inputs**, not over a diff - the same idea as
`wa_compiled_inputs_digest` in `scripts/lib/node-binaries.sh`, generalized from "is compiled" to "can
change a check result". Two trees with the same digest are indistinguishable to every check in the
fast path, so a proof recorded for one covers the other:

```
node scripts/landing-queue.mjs record --tree change/<name>      # a producer records what its checks proved
node scripts/landing-queue.mjs classify --from <a> --to <b>     # what moved, and whether it matters
```

```
landing-queue: #7 upstream moved 261c7d37..b7103c01: docs-only: 12 path(s) moved, none of them read by a check
               -> retest skipped (candidate retest digest 4b2c9f1e77aa already proven by 883ffeda-... 214s ago, bash scripts/fast.sh)
landing-queue: #8 upstream moved b7103c01..cb0bf23d: 3 of 9 moved path(s) can change a check result (lua, rust)
               -> RETEST REQUIRED (candidate retest digest 91ab3d6c0f12 has no proof); baseline rerun
landing-queue: #8   changed test input: lua/core/agent.lua
```

What counts as "can change a check result" is data, not a guess: `testRelevant()` treats `docs/`,
`skills/`, markdown and review/vault paths as documentation, **except** the documents the fast path's
checks actually read (`CHECK_INPUTS`: the three prompt docs `scripts/sync-prompt-docs.lua` writes and
compares, and the instruction documents `scripts/check-instructions.mjs` reads). That list is guarded:
`scripts/test-landing-queue.mjs` parses both scripts and **fails** when either starts reading a
document that is not listed, so adding a checked doc cannot silently weaken the skip.

The compiled-inputs classifier is a second implementation of the shell one, pinned by a parity test
against `scripts/lib/node-binaries.sh` over real paths, because the shell function is the authority and
a divergence would change which landings publish a binary.

`retest_required` is terminal: a landing whose candidate has no proof refuses (exit 75) and names the
inputs that changed; it never lands unproven and never silently reruns. `--checks` runs the given
command **on the merged tree** after the merge and before the push, and rolls the merge back if it
fails.

### 3b. Judged against what main already fails, not against zero

Measured on wasm_the_first, 2026-11-10: main's own fast path was red with twelve Lua checks that fail
because the installed node's component set is behind the tree (graph, codemode and features compare
pinned contracts). A landing that demanded zero failures therefore demanded something no correct
branch could reach, and five sessions improvised their own judge - a subset of the suite
(`graph c54b3957`, `ui 1d23cbed`), a "scoped phase-1 check" (`whatsapp 3f40b12f`), and a by-name
matcher against a pristine tree (`footer`, row #15 -> `a1bed507`, "12 tolerated, 0 new"). Each landing
paid 6-15 minutes re-running a pristine baseline.

There is now **one** implementation, `scripts/lib/landing-baseline.mjs`, folded from those two
improvisations (the footer session's by-name matcher and session `08c59fbc`'s `wa-fast-baseline.sh`,
which also refused an increase in the failing-check count and any failure in a non-Lua section). The
queue applies it to every `--checks` run, by default:

- **pass** - no failing name main does not already fail, no more failing checks than main, and no
  section (rust, prompt-docs, instructions, landing-queue, fast-environment) that main passed;
- **worse** (refused, named) - a new failing name, a passing one now failing, more failing checks, or
  a stricter section that now fails: a crate that will not compile is never an environment fact;
- **fixed** - a name main fails and the candidate does not is *reported*, never treated as a failure:
  the base moves while a landing waits in the queue;
- **environment** - the only NEW failures are ones `scripts/fast.sh` classified as the machine
  (`cannot fork`, exit 125/126, errno 5, `scripts/lib/fast-environment.sh`). That is never a verdict on
  the code: the queue retries the check once, serially, and if it still cannot run it refuses with
  `environment_blocked`, which says plainly that the branch was not judged and no code change is owed;
- **unproven** (refused) - the check command names no failing test, so a by-name comparison would be a
  guess.

Before a `worse` verdict is acted on, the new rows are measured **A-B-A**: directly on main, then on the
merged tree, then on main again (the row recipe of `scripts/fast.sh` - this binary, this tree as the Lua
root, a scratch home - not the check command, because an older runner in the baseline tree does not honour
a "just these rows" request; that is how row #30 got a false answer). A row that fails in either main run
is this machine's churn and is tolerated by name; a row that passes both main runs and fails on the merged
tree is the branch's and refuses the landing; a row that passes on the merged tree was transient. This is
not leniency, it is the measured condition of a shared node: on 2026-11-10, within eight minutes the same
main failed the graph/codemode/cli-view set, then a disjoint completion-packet/context-usage/hooks set,
then the first set again, and the same rows run directly failed identically on main and on the merge. A
by-name diff across two moments refuses correct branches; A-B-A at one moment does not. A landing that is
merely tolerated pays nothing for it: the re-check runs only when a candidate would otherwise be refused.

The baseline itself is a record per (check command, machine, retest digest of main's tree):

```
node scripts/landing-queue.mjs baseline [--command "bash scripts/fast.sh"] [--commit <rev>] [--show]
node scripts/landing-queue.mjs baseline --measure        # measure it now, in the canonical checkout
node scripts/landing-queue.mjs baseline --record <log> [--exit-code <n>]   # prime it from a saved run
```

`--measure` is for the question a session asks before it queues anything: *what does main already fail
here, under my check command?* Without it the command could only read a record, so a session with no
record either landed once (paying a pristine run it did not want) or improvised its own judge - which
is what five sessions did on 2026-11-10. It runs the same measurement a landing runs, by the same code,
with the same two refusals a person can act on: `baseline_busy` when a landing holds the queue (the
canonical checkout is not ours to move) and `baseline_dirty_canonical` when the checkout has
uncommitted work (a baseline measured over it is not main's). A record that already exists is reused,
so asking twice costs one run, not two.

Reuse is the point, and so is measuring where the candidate runs. A landing with no record for main's
check inputs measures **one** baseline - main's own commit, detached in the **canonical checkout**,
under the lease, then put back on `main` - records the result by name, and lands. It is measured there
and not in a throw-away `git worktree` because the same commit fails a different set of checks in a
fresh worktree (measured 2026-11-10, row #27: `test-binding-runtime`, `test-capability-inventory`,
`test-changes-roundtrip`, `test-cli-bash-restart` there; the graph/codemode/features set in the
canonical directory), and a baseline not measured where the candidate runs refuses correct branches.
A green candidate needs no baseline at all: there is nothing to compare. Every successful landing then
records its own candidate run as the baseline for the commit it just made main, so the next landing on
that main pays **no extra run at all**. `scripts/test-landing-baseline.mjs` measures exactly that: the
first landing runs the check twice (baseline + candidate), the second runs it once.

### 4. Durable state that survives a node replacement

`<git-common-dir>/wa-landing-queue/` (`WA_LANDING_QUEUE_DIR` to move it): `queue.sqlite` holds one row
per request - owner, owner provenance, branch, base, lease, pid, host, boot, timestamps, the deltas and
the digest it was decided on - plus a `proofs` table keyed by digest and an append-only `log`. Every
worktree of the repository shares it, and it lives outside the working tree so it can never dirty
`main`. Nothing in it needs a process to be alive: a replaced node restarts from the same rows, and a
row whose holder is gone is reclaimed on the next look, with evidence.

"Survives a node replacement" is the reason a pid alone is never the latch: the row records `host` and
`boot`, so a pid recorded before a reboot is read as *not observable*, not as alive.

### 5. The owner is a harness session, not a directory name

Lesson `les-cf782de101c6`: an agent passed `--session <hex>` taken from the name of a session-scratch
directory that belonged to an old session, so a deploy's outcome went to an unrelated session and the
asker never learned it. The queue therefore accepts two provenances and refuses everything else:

- `harness-env`: `WASM_AGENT_SESSION_ID` (or `WA_SESSION_ID`) in the environment - the marker the
  harness sets for a code-mode/MCP child;
- `ledger-live-session`: a uuid passed as `--owner`, checked against the node's own ledger
  (`WASM_AGENT_DB`): the session must exist, must not be ended, and must have been active within 900 s.

`--owner wt-queue` (a worktree name), `--owner deadbeef`, and a uuid the ledger has never seen each
refuse by name (`owner_not_a_session_id`, `owner_unknown_to_harness`). Get the id from the harness:
`session_worktree {action:"status"}` prints `session_id`, and sentinel wake lines carry it.

## Commands

```
status    [--json]                          holder, queue with positions, canonical dirt, verdict
acquire   --branch <name> [--no-wait]       enqueue and hold the lease (blocks; for your own runner)
          [--wait-timeout <s>] [--lease-seconds <s>] [--no-hold]
record    --tree <ref> [--command <what ran>] record a proof for a tree's retest digest
classify  --from <rev> --to <rev> [--json]  what moved and whether it forces a retest
baseline  [--command <cmd>] [--commit <rev>] what main already fails, by name (the landing baseline)
          [--record <log>] [--exit-code <n>] [--json]
land      --branch <name> [--checks <cmd>] [--dry-run] [--no-push]
preflight --branch <name> [--checks <cmd>]   run a branch's checks on its own worktree WITHOUT the
          [--worktree <dir>] [--lane gate|none] lease, and record the proof a landing will reuse
release   --id <n> [--result landed|abandoned] [--evidence <text>]
reconcile --id <n> --evidence <text> [--force]
history   [--limit <n>] [--json]
```

`--owner <id>` wherever a lander acts. Exit codes: 0 success; 75 refused (named, terminal - a refusal
is never retried by itself); 76 the queue or the repository could not answer. `preflight` adds one: 1,
the checks ran and failed (the check's own result, not a refusal - nothing is recorded).

## The deploy gate: a landing must be installable

A landing is the moment a commit becomes main, and main is what every node installs - so `land` now asks
the deploy's own preconditions on the merged tree, **before the push**, and rolls the merge back when a
deploy of that tree cannot work (`scripts/lib/deploy-gate.mjs`).

Measured 2026-11-11: `rust/wa-sentinel` is its own cargo workspace with its own lock (its header says
why), a crate it builds gained a workspace-internal edge, and the sentinel's lock was not updated in the
same landing. `bash scripts/fast.sh` saw nothing - it tests the crates a change touches inside
`rust/Cargo.toml`, and the sentinel's workspace is only built when its own paths change - while
`scripts/deploy.sh` builds it with `cargo build --release --offline --locked --manifest-path
wa-sentinel/Cargo.toml`, which refuses a lock that needs an update. Main was undeployable, the fix was a
second landing (`abe54c90`), and each miss costs a full cycle on the node that finds it.

| check | what it decides | the deploy refusal it covers |
| --- | --- | --- |
| `lockfile` | `cargo metadata --locked --offline` for every workspace `deploy.sh` builds `--locked` (`DEPLOY_WORKSPACES`) | the `--locked` build refusing a lock that needs an update |
| `components` | `components.lock` pins components and `graph` among them | `component_lock_empty` / `component_lock_incomplete` (a deploy that would install nothing) |
| `pin` | the merged commit is materialised as a detached worktree and read back | `pin_failed` / `pin_mismatch` (a tree a deploy cannot check out) |
| `compiled-inputs` | the deploy's own `wa_compiled_input` classifier against the queue's `compiledInput`, over the tree's real paths | a release manifest whose `compiled_inputs=` digest would cover a commit that is not its build |

```
landing-queue: #20 deploy gate ok (lockfile rust/Cargo.toml=ok, lockfile rust/wa-sentinel/Cargo.toml=ok,
               components=ok, pin=ok, compiled-inputs=ok)
landing-queue: #21 deploy gate REFUSED: ... undeployable: a deploy of this tree cannot work ...
               lockfile rust/wa-sentinel/Cargo.toml=refused
```

The refusal is one name (`undeployable`, exit 75), the merge is reset to the base it started from,
nothing is pushed, and every check is named with what it decided. It is recorded in the durable log as a
`deploy-gate` row, so a lander that inherits the tree can read what was proved.

Three properties are deliberate:

- **It costs seconds.** 1.1 s for all five rows on this tree (0.3 s of it `cargo metadata`, 0.4 s the
  pinned worktree): nothing next to a landed-then-undeployable cycle.
- **A check that cannot run is a SKIP, not a pass.** No cargo on PATH, no registry cache for an
  `--offline` resolve, no `sha256` tool: the row says `skip` with the reason and the gate says so in its
  line. `cargo metadata --locked --offline` needs a warmed registry (`cargo fetch --locked` on the
  machine that builds), and a machine without one prints SKIP and has no opinion - it never claims the
  lock is fine.
- **The two classifiers are compared as sets, not as digests.** `wa_compiled_inputs_digest` and
  `treeDigest().compiled` use different schemas on purpose (`wasm-agent-compiled-inputs/1` vs
  `wasm-agent-retest-inputs/1`), so equal values were never the question; equal classification is.

What it still does not cover, said out loud: whether a *release* exists (that is the post-push publish
step, and `status`'s `release_uncovered` rows), whether the tree compiles for every target (that is the
publisher's build), and any check whose result depends on a machine this gate is not running on.

## The preflight lane: test a branch while someone else lands

`land` runs the checks on the merged tree in the canonical checkout, under the one landing lease. A
session that wants to know whether its branch is good therefore has had two bad options: wait for the
lease, or run the suite by hand and have nobody able to point at the result. Measured 2026-11-11: three
sessions ran the fast path in their own worktrees while one landed, the lander's retest hit `cannot fork`
and was refused `environment_blocked`, and two of the three results were thrown away because there was no
record to attach them to.

```
node scripts/landing-queue.mjs preflight --branch change/x --owner <session id>
landing-queue: preflight change/x (a1b2c3d4e5f6) in /home/wa/wt-x: bash scripts/fast.sh - no landing
               lease, admitted by the gate lane
landing-queue: preflight change/x (a1b2c3d4e5f6) passed in 214s and recorded a proof for retest digest
               77aa11bb22cc: `land --branch change/x` reuses it instead of running `bash scripts/fast.sh` again
```

- **No lease.** It never enqueues, never holds the canonical checkout and never merges or pushes: `queue`
  rows are untouched, so it cannot block a lander and a lander cannot block it.
- **On the branch's own tree.** `git worktree list --porcelain` finds the worktree whose HEAD is the
  branch tip; a branch nobody has checked out is refused by name (`preflight_worktree_required`) with the
  command that would make one, and `--worktree <dir>` names an existing clean tree explicitly. A tree
  that has moved off the tip is refused (`preflight_worktree_moved`) rather than checked under the
  branch's name.
- **Admitted by the gate lane** (`scripts/gate-lane.mjs`), so N preflights and a landing do not contend
  for the cores - which is the failure that made the lander's retest unjudgeable. A lane that will not
grant a slot is a refusal (`preflight_lane_blocked`) that names the holder; `--lane none` runs
  unadmitted on purpose and says so.
- **The proof is the same evidence table `record` writes** (`proofs`, keyed by the tree's retest digest),
  so the next `land --branch` of that tree finds it: `candidate tree ... already proven ... with no
  retest`. A red run records nothing, exits 1 and leaves the landing to run its own checks.
- **A skip is reported.** The fast path's own `N skipped` count is printed with the proof, because a
  proof recorded over a skipped check is not a proof of that check.

## What it is not

- It is not the merge lane (`scripts/merge-lane.mjs` builds and gates a candidate in a disposable
  clone), not the gate lane (`scripts/gate-lane.mjs` serializes the CPU-heavy gate), and not the
  release gate. It serializes **the canonical checkout**, which none of those own.
- The deploy gate decides whether a deploy of the merged tree can work; it does not build, publish or
  install anything, and it never replaces the deploy's own refusal when a real deploy runs.
- It does not review a branch, resolve a conflict (`merge_tree` conflict is a named blocked input) or
  push anything but `main` (`.githooks/pre-push` and `lane-policy.json` remain the boundary).
- It does not replace the audit: `skills/git-orchestrator/scripts/audit.mjs verify` still answers
  whether every tip is integrated.

## Risks, named

- **A skip is a claim about inputs, not about behaviour.** If a check's result depends on something
  outside the tree (a toolchain version, a network, a clock), the digest cannot see it move. The
  `CHECK_INPUTS` guard covers the documents the checks read; it cannot cover a dependency the checks
  resolve at run time.
- **The skip trusts the recorded proof.** `record` is the lander's own claim about its own run; the
  queue stores who said it and what command ran, and any session can read that, but it does not re-run
  the proof to check the claim (`--checks` does, and the nightly gate does for the exact tree).
- **A baseline is a measurement of a machine, not a licence.** The names it tolerates were observed on
  this host with this install; the record is keyed by host and check command so it is never borrowed
  from another machine. If a tolerated failure gets worse inside its own name (the same test failing
  for a new reason), a by-name judge cannot see it - the count, the strict sections and the nightly
  gate are what remain.
- **`scripts/fast.sh` decides what "the machine" looks like.** A check that prints a fork/spawn
  signature in its last line is classified environmental. The rule is deliberately narrow
  (`scripts/lib/fast-environment.sh`: exit 125/126 or a system-level signature) and the test beside it
  proves a real assertion failure is never excused - but a regression whose own message ends in
  `cannot fork:` would be reported as `environment_blocked` rather than as bad code.
- **Reclaim is automatic only for a holder whose process is provably gone.** An alive-but-wedged
  holder blocks until a person reconciles it, on purpose.
- **`docs/` and `skills/` are treated as documentation** except the listed check inputs. That is the
  operator's measured case (`skills/clean-disk`), and it is the one place where the classifier is a
  policy decision rather than a fact about the tree.

## The aarch64 release a landing publishes

A landing is the moment a commit becomes installable, so it is the moment the prebuilt binary for that
commit must exist: `scripts/deploy.sh` installs a published release when the commit's compiled inputs
are covered, and compiles on the node only when there is none. Measured 2026-11-10: neither of that
day's two landings published one (`graph c54b3957`, `ui 1d23cbed`), and the aarch64 release for
`1d23cbed` had to be made by hand afterwards — so a remote update (`docs/REMOTE-UPDATE.md`) of
`openclaw` would have fallen back to a build on the node it was replacing.

After the push and the readback, `land` therefore runs

```
bash scripts/publish-node-binaries.sh --ensure --publish --target aarch64-unknown-linux-gnu --commit <merged>
```

in the canonical checkout, and prints and records what it answered:

```
landing-queue: #7 release covered (aarch64-unknown-linux-gnu): covered: node-4147192f2725 covers the
  compiled inputs of <merged> for aarch64-unknown-linux-gnu; nothing to build or publish in 2s
```

- `--ensure` answers in seconds for a Lua/docs/test-only landing (its compiled inputs are unchanged,
  so an earlier release already covers it) and builds once for a Rust landing — here, not on every
  node;
- it can never fail the landing: the merge is pushed and read back before it runs, so a publisher that
  cannot run records `release failed (aarch64-unknown-linux-gnu): <reason>` in the row and keeps its
  log at `<queue dir>/release-<sha12>.log`, and `main` stays what was pushed;
- the publisher finds its own toolchain (`zig`, one `CARGO_TARGET_DIR` for both Cargo workspaces), so
  a landing needs no caller environment — see `scripts/publish-node-binaries.sh`'s header.

`scripts/test-landing-queue.mjs` proves the call (its fixture's publisher records its arguments and
the row's line) and the failure path, and `scripts/test-node-binaries.sh` proves the toolchain is the
script's own.

## A deploy builds a pinned commit, and a dead lander's merge is finished

Two residues from the 2026-11-10 night wave, both recorded rather than remembered:

- **A deploy never builds the live canonical tree.** `scripts/deploy.sh` resolves the commit, takes the
  queue's own lease (`landing-queue.mjs pin`), creates a **detached worktree at that commit** under
  `$WA_DEPLOY_PIN_DIR` (default `<tmp>/wa-deploy-pins/<sha>`), releases the lease, and builds, stages and
  ships only from the pinned tree. A landing can therefore merge into the canonical checkout at any moment
  without moving the bytes a build is reading — the failure that produced three failed deploys
  (`stale embedded module: lua/core/server.lua`) and that commit `2231fc6f` could only make retryable. A
  `pin` waits (bounded by `--wait-timeout`, default 600 s in the deploy) for a landing in progress, so a
  deploy never resolves the tree mid-landing. `installed.txt` records `source_worktree=` and `build_pin=`.
  `WA_DEPLOY_PIN=0` is an explicit exception, and `WA_DEPLOY_ALLOW_UNPINNED=1` is the only way past a pin
  that failed.

- **A lander that died between merge and push is recovered on the next acquire.** When no holder is live and
  the canonical `HEAD` is a queue-shaped merge (`merge(<branch>): …`) ahead of `origin/main`, `acquire` /
  `land` finishes the push and reads it back, or — if the push cannot be made — keeps the merge on
  `refs/wa/recovered/<sha>` and resets the tree to `origin/main`. Both outcomes are written to the durable
  log (`recovered: …`), and `status` reports `recovery: would_push|refused|none` without touching the tree.
  A local commit that is not the queue's own merge form is refused by name (`unpushed_canonical`), never
  pushed or dropped by guess.

- **The holder is published for the tool layer.** On every grant the queue writes `holder.json` beside
  `queue.sqlite` (`id`, `owner`, `kind`, `branch`, `lease`) and removes it when the row ends. It is a hint
  for `lua/core/canonical_guard.lua`, never the authority: a write/edit into the canonical checkout, or a
  bash/`operation start` command that would write there, is refused at the tool layer with the rule and the
  worktree to use — unless the caller's session id is the holder. Reads stay allowed.
