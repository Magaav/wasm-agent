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
land      --branch <name> [--checks <cmd>] [--dry-run] [--no-push]
release   --id <n> [--result landed|abandoned] [--evidence <text>]
reconcile --id <n> --evidence <text> [--force]
history   [--limit <n>] [--json]
```

`--owner <id>` wherever a lander acts. Exit codes: 0 success; 75 refused (named, terminal - a refusal
is never retried by itself); 76 the queue or the repository could not answer.

## What it is not

- It is not the merge lane (`scripts/merge-lane.mjs` builds and gates a candidate in a disposable
  clone), not the gate lane (`scripts/gate-lane.mjs` serializes the CPU-heavy gate), and not the
  release gate. It serializes **the canonical checkout**, which none of those own.
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
