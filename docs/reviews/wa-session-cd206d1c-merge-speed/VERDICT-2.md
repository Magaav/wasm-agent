# Independent review #2 — the merge-speed delivery *with* its conflict resolution against the retention sweep

**Verdict: `accept with named residue`.**

* **Tree this verdict covers:** `72e807b3c1ccd6214df53ff71b3516b8692341e6`
  (`git rev-parse 82873b174f3c6a32b010d1384900b781ac097f35^{tree}`), tip
  `82873b174f3c6a32b010d1384900b781ac097f35`, branch
  `change/wa-session-childdispatchcd206d1c-287c-46fa-919d-703ff645dc5e`, base `origin/main` =
  `ad3acad6a2c242cc678ffd303911efa2e7ec33c6` (merge-base with main is `ad3acad` too, so everything
  below is this delivery's own change: `A docs/MERGE-SPEED.md`, `A docs/measurements/*`,
  `A docs/measurements/merge-lane-tree-vs-retention-probe.mjs`, `A scripts/lib/gate-phases.sh`,
  `M scripts/merge-lane.mjs`, `M scripts/test-merge-lane.mjs`, `M scripts/test.sh`).
* **Reviewer:** branch `change/wa-session-childdispatch1aae04ee-e44a-4dcc-9811-8f5a74fb5d12`, whose
  own worktree holds this file and `evidence-2/E1…E7`.
* **No gate was run and no slot was taken.** `scripts/test.sh` was never executed; slot **#199** was
  held by a live landing for the whole review. `scripts/test-merge-lane.mjs` *was* run (item 3) from a
  `git archive` extraction of the tip in a scratch directory, with `TMP`/`TEMP` **and**
  `WA_GATE_LANE_DIR` redirected into that scratch directory, so its fixture lanes used a *fixture*
  lane — the real lane's newest row is still `#200`, and the fixture slots landed in the scratch lane
  (`evidence-2/E7`). That redirection is the only deviation from a plain run; it takes no real slot and
  changes no assertion of the test (its own env is just `WA_MERGE_LANE_AUDIT`).
* No edit was made to the delivery; nothing was merged, `main` was not pushed, no force and no
  rewrite. The persistent trees were **listed and read only** — never given a git command, never
  moved, never deleted.

Evidence files (raw command output) sit beside this verdict in `evidence-2/`: `E1` (item 1),
`E2a`/`E2b` (item 2), `E3a`/`E3b` (item 3), `E4`/`E4b` (item 4), `E5`/`E6` (item 5), `E7` (no slot).

---

## 1. Both intents survive — yes, and the retention side survives byte for byte

**The conflict was real and the resolution kept both sides.** The retention rule that landed in main
(`90766a96`, through `ad3acad`) is *untouched text*, not a re-typed approximation:

```
main  scripts/merge-lane.mjs lines 113-247 : 2e634787fb3e35c66ea05c9085f3437f4a7a59af6b5dd781fd1d9418f423fa7d
tip   scripts/merge-lane.mjs lines 117-251 : 2e634787fb3e35c66ea05c9085f3437f4a7a59af6b5dd781fd1d9418f423fa7d
```

The diff of `scripts/merge-lane.mjs` against main has **no hunk anywhere in that region** (its hunks
are `@@ -30,6 +30,10 @@`, `@@ -276,8 +280,11 @@`, `@@ -290,9 +297,11 @@`, `@@ -360,9 +369,311 @@`,
`@@ -602,…`, `@@ -669,…`, `@@ -712,…`, `@@ -741,…`, `@@ -763,…`, `@@ -777,…`, `@@ -791,…`), so
`holderProbe`, `legacyGraceMs` and `sweepClones` are main's own bytes (`E1`).

**The grace is still derived, not re-hardcoded** (`scripts/merge-lane.mjs:126-143`):

```js
const GATE_LANE_WAIT_DEFAULT_SECONDS = 7200;
const LANE_GATE_TIMEOUT_DEFAULT_SECONDS = 3600;
const LEGACY_GRACE_SLACK_SECONDS = 60;
export function legacyGraceMs({waitSeconds = process.env.WA_GATE_LANE_WAIT_SECONDS,
  gateTimeoutSeconds = null} = {}) {
  const wait = budgetSeconds(waitSeconds, GATE_LANE_WAIT_DEFAULT_SECONDS);
  const gate = budgetSeconds(gateTimeoutSeconds, LANE_GATE_TIMEOUT_DEFAULT_SECONDS);
  return (wait + gate + LEGACY_GRACE_SLACK_SECONDS) * 1000;
}
```

Evaluated on this machine the producer's own probe printed `legacy grace as merged: 10860 s`, i.e.
7200 + 3600 + 60, still a function of the two budgets (`E2b`).

**Every deletion still goes through the rename probe.** `sweepClones` has exactly one deletion of a
candidate and it is preceded by `holderProbe` (`scripts/merge-lane.mjs:229-244`):

```js
    if (index < budget) { record.kept.push({...}); return; }
    const probe = holderProbe(candidate.dir);
    if (probe.gone) return;
    if (probe.in_use) { record.in_use.push({...}); ... return; }
    try { fs.rmSync(candidate.dir, {recursive: true, force: true}); ...
```

and the tree-side resolution keeps main's bound and the reuse rule as *two* terms rather than one
(`scripts/merge-lane.mjs:1094-1096`, `1127-1131`, `1147`):

```js
const retainClone = Boolean(clone) && (clone.disposable === false || options.keepClone
    || (exitCode !== 0 && options.keepClones !== 0));
...
if (clone && clone.reused === true) releaseReuseLock(clone.lock);
if (clone && !retainClone && clone.disposable !== false) { fs.rmSync(clone.dir, ...); ... }
...
retention.sweeps.push(sweepClones({keep: options.keepClones, currentKept: retainClone && clone.disposable !== false,
    ... current: clone ? clone.dir : ...}));
```

with main's pre-write sweep still first ("before anything new is made"). I read the whole resolved
file: the only other `fs.rmSync` of a tree is the run's own *disposable* clone (`clone.disposable !==
false`), so a persistent tree (`disposable: false` on both the create and the reuse path) is never
removed by the lane, and the sweep's budget is never spent on it. **Nothing was quietly dropped.**

## 2. "The tree cannot be swept" — falsified attempt: it survives, by NAME and by RULE

Constructed and run (`E2a`), importing `sweepClones`/`legacyGraceMs` from the **tip's own**
`scripts/merge-lane.mjs`:

* **By rule.** The sweep's root is `os.tmpdir()` only (`sweepClones`, `tmp = os.tmpdir()`); the real
  persistent tree `C:/Users/Victor/.wasm-agent/merge-lane-tree-landing` is **not inside it**
  (`inside os.tmpdir()? false`).
* **By name.** The enumerator filters before it stats anything:
  `if (!entry.isDirectory() || !entry.name.startsWith(CLONE_PREFIX)) continue;` and the tree's
  basename is `merge-lane-tree-landing`, not `wa-merge-lane-*`.
* **Run against the tree's own parent, real semantics** (`keep=1`, and verified first that
  `~/.wasm-agent` holds zero `wa-merge-lane-*` entries, so nothing could be pruned):
  `{"kept":[],"removed":[],"in_use":[],"recent_legacy":[],"live":[],"not_this_family":0}` — the tree
  survives with an unchanged mtime, and `not_this_family: 0` is the proof it was filtered out **by
  name before the family test**, not spared by a probe.
* **Idle and older than any grace.** A mimic with the tree's basename, idle, 20 000 s old (1.84 × the
  10 860 s grace) in a scratch root, beside a family-shaped leftover: the mimic **survived**; the
  leftover was kept by the budget. With `keep=0` the family-shaped, idle, old directory **was
  removed** and the mimic still survived. So an idle, old directory that *is* in the family is
  deletable, and the tree's name is what keeps it out of that family.
* **The one configuration the sweep could reach is refused by name** before it can become a tree:
  `scripts/merge-lane.mjs:592` (item 3), so a persistent tree can never *be* a family member.

The producer's own probe reproduces the same A/B/C result, with one environment difference: part C
reported `candidates seen 2` in the receipt and `1` in my run, because a live lane's own sweep pruned
one temp leftover between the receipt and my run (`E2b`).

**Answer: the tree cannot be swept, by rule (its root is never enumerated) *and* by name (its
basename is not in the family); the only in-temp family configuration is refused by the lane's own
guard.** Residues R4/R5 below bound that.

## 3. The new test pins the refusal, and it can fail — both observed

* **It passes.** `node scripts/test-merge-lane.mjs` at the tip (`E3a`): **exit 0**,
  `merge-lane spine ok (85 checks)`, `85 ok / 0 FAIL`, ~54 s, in the scratch extraction with a
  fixture lane. The two checks `1448108` added are:
  `a tree inside the temp root named like the sweepable family is refused by name` and
  `and that run clones instead, leaving no tree for a sweep to find`.
* **It fails when the guard is inverted.** In a *scratch copy* (not the delivery) I changed
  `scripts/merge-lane.mjs:592`
  `if (insideTemp(dir) && path.basename(dir).startsWith(CLONE_PREFIX)) {` →
  `if (false && insideTemp(dir) && path.basename(dir).startsWith(CLONE_PREFIX)) {` (exactly one
  occurrence). Result (`E3b`): **exit 1**, `merge-lane spine: 83/85 ok, 2 FAILED`, and the two
  failures are exactly those two checks —

  ```
  FAIL a tree inside the temp root named like the sweepable family is refused by name - null
  FAIL and that run clones instead, leaving no tree for a sweep to find - {"verdict":"pass","path":"…\tmp2\wa-merge-lane-test-ty0D47\wa-merge-lane-tree","created":true}
  ```

  So the checks are causally tied to the guard: with the guard gone the lane really does create the
  sweepable tree. A test that can fail, pinning a refusal that is real.

## 4. The wrapper: absent; the remaining instrumentation changes no verdict and no count — but it does displace main's gate-home trap

* **The per-suite instrumentation wrapper is not in this tree.** `git ls-tree -r 82873b1 -- scripts/lib`
  has no `gate-shims/`, no `gate-suite.mjs`, no `gate-suites.mjs`, and no path in the whole tip tree
  matches `shim|wrapper` (`E4`). The only instrumentation is `scripts/lib/gate-phases.sh` (98 lines).
* **`scripts/test.sh` is additive and check-neutral.** Its whole diff against main is `+20/-0`;
  filtering the added lines down to "not a comment, not `. scripts/lib/gate-phases.sh`, not
  `trap gate_phase_summary EXIT`, not `gate_phase_begin <name>`/`gate_phase_summary`" leaves
  **nothing** (`E4`) — no check, no suite invocation, no exit code and no `SKIPPED` arithmetic is
  added, removed, reordered or skipped. `gate_phase_summary` prints once (`GATE_PHASE_WRITTEN`),
  always `return 0`, never calls `exit`; the warm and cold gate logs both end on the verdict line
  `smoke ok (2 skipped)` (`E5`). **It cannot change a suite's verdict or its count.**
* **Residue R1, observed (not a verdict and not a count):** `scripts/test.sh:162`
  `trap gate_phase_summary EXIT` is set *after* main's `scripts/test.sh:153`
  `trap gate_home_release EXIT` and *before* main's `scripts/test.sh:287`
  `trap 'rm -f "$DB" …' EXIT`. bash keeps one trap per signal, so for every exit between 162 and 287
  the EXIT trap is now `gate_phase_summary`, and `gate_home_release` (main's bounded gate home: "a
  passing run removes its home; … the sweep keeps the newest") **does not run**. Reproduced with the
  tip's real `gate-phases.sh` and the tip's trap order (`E4b`): a failure in the build region runs
  `gate_phase_summary` and prints the table, `gate_home_release` does **not** run, and the exit status
  is preserved at 1; the same script with only main's trap runs `gate_home_release`. The window
  contains the build, instances, self-update, cli, memory-update, tools, sessions, recovery-cli and
  plugins phases — i.e. the phases where a cold gate spends its time and most red gates land. At this
  tip `gate_home_release` is unreachable on **any** exit path (162's trap covers everything before
  287, main's 287's trap covers the rest). It changes no verdict and no count; it does mean main's
  gate-home bound is not applied where the merge's own comment says it runs "on every exit path".
  A one-line chain of the two traps would fix it; **I did not touch the delivery.**
  Attribution, so this is not overstated: main's own trap at 287 *already* displaced
  `gate_home_release` for every exit at/after it — including every passing run — which I reproduced
  the same way (`E4b`-main), and 27 `wa-gate-home-*` directories were sitting in the temp root during
  this review. The pass-path leak is main's; what this tree adds is the earlier window.

## 5. Re-measured: this tree's numbers, checked against the lane's own records

What the receipts for this tree actually say (the *gated* candidate is
`4c5cc536182ce1e6e0302c93c460df4893c6375d`, which is exactly `8cefa35^{tree}` — the merge commit,
i.e. the conflict resolution itself):

| | cold (#197) | warm (#198) |
|---|---|---|
| candidate tree | `4c5cc536182c…` | `4c5cc536182c…` (same tree) |
| `gate.ms` (lane's own) | **1 619 933.554 ms** | **858 965.580 ms** |
| gate exit / skipped / verdict line | 0 / 2 / `smoke ok (2 skipped)` | 0 / 2 / `smoke ok (2 skipped)` |
| `clone` | `reused false`, `reuse_created true`, `clone_ms` 1287.5 | `reused true`, `clone_ms` 576.5, dirt `[]`, toolchain `[]` |
| gate log sha256 | `df6b6be2dd7f…` | `deefcccf4f0c…` |

**saving = 1 619 933.554 − 858 965.580 = 760 967.974 ms (12.68 min)**; the saving is essentially all
build (756 971 ms cold vs 22 731 ms warm).

Cross-checked, not restated:

* the runs' own JSON receipts carry those exact `gate.ms`, `skipped`, verdict lines and clone fields;
* the retained gate logs **re-hash** to each run's recorded `log_sha256` (`E5`);
* the gate lane's own rows read `#197 done … exit 0` and `#198 done … exit 0`, both
  `label merge-lane 4c5cc536182c`, both `cwd C:\Users\Victor\.wasm-agent\merge-lane-tree-landing`
  (`node scripts/gate-lane.mjs status`, read-only). `gate_ms` is `null` in those rows because the slot
  is `mode=acquire` — the caller runs the gate — so the lane corroborates candidate, tree path and
  exit status only, and the milliseconds come from the runs' own JSON;
* the persistent tree's owner record reads `runs: 2` (one create + one reuse) and
  `rust/target` is present;
* the **warm run's own retention record** shows the budget fix on a real landing, not only in the
  probe: pre-sweep `{keep 1, current null, budget 1, kept 1, removed 0}`, post-sweep
  `{current = the persistent tree, current_kept FALSE, budget 1, kept 1, removed 0}` — the tree appears
  only as `current`, is never a candidate, and is not counted against the budget.

Against the earlier accepted pair: the previous verdict covered cold **1 625 532.454** → warm
**825 069.004** = **800 463 ms** *on the pre-merge tree*. On this tree it is **1 619 933.554 →
858 965.580 = 760 967.974 ms**. The saving shrank by ~39.5 s because main added suites: the warm gate
grew (825 069 → 858 966) while the cold one is flat (1 625 532 → 1 619 934). The structure holds —
build 797 521 → 22 635 ms before, 756 971 → 22 731 ms now.

One documentary defect in the receipt, **R2**: the cold `phases_ms` table in
`docs/measurements/merge-lane-tree-retention-merge.json` has **11 rows summing to 1 595 038** and
omits `ui-js` (15 903) and `ui-browser` (8 487), while the cold run's own JSON and log both carry
**13 rows with `total_ms` 1 619 428** (`E5`/`E6`). `gate_ms` and `saving_ms` are unaffected; only the
cold phase table is short and its rows do not add up to the total printed beside them. (The warm
table is complete: 13 rows, 858 431 ms.)

**Coverage limit, R3:** the *reviewed* tree `72e807b3` was never itself gated. The gated candidate is
`4c5cc536182c` = `8cefa35^{tree}`, and the two trees differ by exactly three files —
`scripts/test-merge-lane.mjs` (+13), `docs/measurements/merge-lane-tree-vs-retention-probe.mjs` (+70),
`docs/measurements/merge-lane-tree-retention-merge.json` (+50/−19). `scripts/merge-lane.mjs`,
`scripts/test.sh` and `scripts/lib/gate-phases.sh` are **identical** between the gated candidate and
the reviewed tree, so the measured numbers transfer to the mechanism — but the tip's own test file
was outside the gate, which is why running it (item 3) mattered.

---

## Residues

| | residue | evidence |
|---|---|---|
| **R1** | `scripts/test.sh:162`'s phase trap displaces main's `trap gate_home_release EXIT` (line 153) for every exit in 162–287, so main's bounded gate home / family sweep does not run where a red build dies. No verdict and no count changes. One-line fix (chain the traps) — not applied by me. The pass path was already displaced by main's own line-287 trap. | `E4`, `E4b` |
| **R2** | the receipt's cold `phases_ms` table omits `ui-js`/`ui-browser` (11 rows, sum 1 595 038, vs 13 rows / `total_ms` 1 619 428 in the run it cites) | `E5`, `E6` |
| **R3** | the reviewed tree `72e807b3` was never gated; the gated candidate is `4c5cc536182c` (= `8cefa35^{tree}`); delta = the two measurement docs + `scripts/test-merge-lane.mjs` | `E5` |
| **R4** | the in-temp guard resolves the path with `path.resolve`, not `realpathSync`, so a junction/symlink from outside the temp root into it would defeat the in-temp refusal (the tree would then physically be a temp-root family child). Requires an operator to configure `WA_MERGE_LANE_TREE` through such a link. | `scripts/merge-lane.mjs` `insideTemp()` / `samePath()` |
| **R5** | the guard refuses only basenames starting with `wa-merge-lane-`. An operator-chosen in-temp tree with a **non-family** name (e.g. `<tmp>/warm-tree`) is accepted; today's sweep does not prune it (`not_this_family`), so it survives by name only, not by rule — the producer's own "not a promise about tomorrow's sweep" argument applies to that path too. Low: it opts out of the default. | `E1`, `E2a` |
| **R6** | pre-existing, **main's**, named for context: main's own `trap 'rm -f "$DB"…' EXIT` at `scripts/test.sh:287` already displaces `gate_home_release` for every exit at/after it, including every passing run — so "a passing run removes its home" was already false in main, and 27 `wa-gate-home-*` directories were in the temp root during this review. Not caused by this merge. | `E4`, `E4b`-main |
| **R7** | `scripts/test-merge-lane-retention.mjs` is red at the tip per the producer (2/15 ok, 13 failed, attributed to main's `check-disk-floor.sh` line inside the slice). **I did not run it** — its later blocks acquire real gate slots (gate-lane rows `#182–#188` are seven slots labelled `merge-lane 91f535f9` from a `wa-retention-test-*` fixture). I verified only the attribution's premise by identity: lines 1–153 of the tip's `test.sh` and of main's both hash `0edeb31c0d1a78720a05e26d08ff3a0dcf5cbf4b185d41042045c3dc2551b3fd`, so the slice the suite runs is main's text. Note also that the suite's slice stops at the line-154 marker and runs `1..153` in isolation, where `gate_home_release` is the only trap — the suite is structurally blind to R1. | `E4`, suite lines 78–88 |

## What I could NOT verify

* **No gate of my own.** No cold/warm pair was reproduced (slot #199 was held throughout and the gate
  is capacity 1): this tree's numbers are the producer's, *checked* against the runs' own JSON,
  re-hashed logs, the tree's owner record and the gate lane's rows — not re-measured by me.
* The reviewed tree was never gated as a whole (R3); the tip's `scripts/test-merge-lane.mjs` is
  outside the gated candidate, though I ran it myself (85/85, exit 0).
* `scripts/test.sh` was not run and no gate slot was taken; `scripts/test-merge-lane-retention.mjs`
  was not run (R7).
* The release-profile invalidation probe was not re-run (only the `cfg(test)` probe exists), as the
  producer's own receipt also records.
* The persistent trees' git state was inspected only by listing and by reading the owner record — no
  git command was given to them, and nothing in them was created, reset, moved or deleted.
