# Independent review — persistent gate tree / "merge speed" delivery

**Verdict: `accept with named residue`.**

* **Tree this verdict covers:** `73668558022b7c7820741974166228f0f2c95dd6`
  (`git rev-parse 7ed53a38^{tree}`), tip `7ed53a38e057b3aab88c7d56f185f057c8561290`,
  branch `change/wa-session-childdispatchcd206d1c-287c-46fa-919d-703ff645dc5e`,
  base `origin/main` = `da8dc8918a34c880768956ff775d883802dcb7a7`.
  Reviewer's branch: `change/wa-session-childdispatch52fb63d8-f2c0-4442-b28b-77da6228a827`.
* **Reviewer ran no gate and took no slot.** `node scripts/gate-lane.mjs status` (read-only) showed
  slot #194 held by another live landing throughout; `scripts/test.sh` was never run, no slot was
  acquired, held or stolen, and `scripts/test-merge-lane.mjs` was not run either (its fixtures request
  the same gate lane). Everything below is from commits, code, run receipts, gate logs and the gate
  lane's own records. The delivery was not edited; the persistent trees were only listed/read, never
  given a git command.
* **Nothing found that lets a warm gate pass a tree it never rebuilt.** The false-green
  falsification is *proven from receipts* (§2). The residue is documentary and coverage, not mechanism.

Evidence files beside this verdict (`evidence/E1`…`E6`) each show the exact command and its raw output.

---

## 1. The saving: the corrected pair is right; a stale cross-tree pair survives in the doc

**What its own measurements show.** The corrected same-tree pair is **cold 1 625 532.454 ms → warm
825 069.004 ms = 800 463 ms** (13.3 min), build 797 521 → 22 635 ms:

* `docs/MERGE-SPEED.md:286-287` (§6): "cold 1625532 ms, warm 825069 ms — a saving of 800463 ms (13.3 min)
  per landing, about **2x**, essentially all of it in the build phase (797521 ms against 22635 ms)".
* `docs/measurements/merge-lane-tree-landing.json:44` (cold `gate_ms`), `:59` (warm `gate_ms`), `:67`
  (both gated the *same* candidate tree `028380ac…`, i.e. base + tip 9b4adfa), `:68` (`saving_ms`
  800463), `:69` (the build attribution).
* Verified against the runs themselves (`evidence/E2`, five receipts re-hashed): cold slot **#181**
  `reused=false` 1 625 532.454 ms exit 0; warm slot **#189** `reused=true` 825 069.004 ms exit 0; both
  candidate tree `028380ac6d7d…`; both `smoke ok (2 skipped)`; both gate logs hash to the `log_sha256`
  the run recorded. `gate.ms` ⇒ 1625.5 s / 825.1 s, difference 800.5 s.

**The superseded figure (891,139 ms) is where it should be.** `891138.877` survives only in
`docs/measurements/gate-phases-suites.json:71` (`gate_ms_saving_ms`, from `:11` cold 1 030 126.449 and
`:34` warm 138 987.572, i.e. the "7.4x"), and the tip repudiates it twice: §6:280-287 and the artifact's
`does_the_7x_hold` ("Both of those runs stopped inside self-update on the wrapper defect … a saving of
800463 ms … about 2x, not 7x").

**The claim as put to me is falsified, however: "1145.9 s cold → 528.1 s warm on one tree, so 617.8 s per
landing" is not a same-tree measurement.** It is still printed at the tip as the "decisive number": `docs/MERGE-SPEED.md:21` ("the cold/warm gap on
ONE tree … same tree"), `:27` ("on one tree, the same gate costs 617.8 s more"), `:66` (option 1's bound),
`:89-91` ("617.8 s per landing (1145.9 s -> 528.1 s on one tree)"), and `:214`/`:251`, where the
measurement-era sections call the same two EVOLUTION rows "the existing same-tree warm figure of 528.1 s"
and "the existing same-tree pair in `docs/EVOLUTION.md`". It is `1145.9 − 528.1 = 617.8`. The gate lane's own retained request records for those two rows show two **different
trees** (`evidence/E3`):

```
c-w1                label=pair-at-once-w1      gated_in=w1  capacity=2 gate_ms=1145938  exit=0
pair-cold-w2        label=pair-cold-w2         gated_in=w2  capacity=2 gate_ms=1093542  exit=0
pair-cold-w3        label=pair-cold-w3         gated_in=w3  capacity=2 gate_ms=1096781  exit=0
pair-warm-serial-w2 label=pair-warm-serial-w2  gated_in=w2  capacity=1 gate_ms=528114   exit=0
pair-warm-serial-w3 label=pair-warm-serial-w3  gated_in=w3  capacity=1 gate_ms=523405   exit=0
same tree w2  1093542 - 528114 = 565428 ms      same tree w3  1096781 - 523405 = 573376 ms
```

So the honest EVOLUTION-derived same-tree gaps are **565.4 s (w2)** and **573.4 s (w3)**, and this
delivery's own same-tree gap is **800.5 s**. The error is conservative (it understates the saving) and
the correct number is in the same file, but the row as written is wrong and is attributed to "ONE tree".
Option 2's projection from it ("a landing's gate falling to roughly 7-9 minutes") does not follow from
either pair: 900 s − 617.8 s = 4.7 min, and the delivery's own warm gates were 825.1 s / 854.6 s
(13.8 / 14.2 min). §6:288 says the queue cost falls "from ~27 minutes to ~14" — consistent with the
receipts; §1/Option 2 are not.

**Item 1 answered:** the pair the producer's measurements actually show is 1 625 532 / 825 069 →
**800 463 ms**, carried by `docs/MERGE-SPEED.md:286-287` and `merge-lane-tree-landing.json:44,59,67,68`;
the 891 139 ms figure is superseded and quarantined to the older artifact; the 617.8 s headline is a
cross-tree number left uncorrected in §1 and Option 2 (residue R1).

## 2. The false green: proven from retained receipts, no fresh gate needed

**Yes, proven — by receipts, not by a re-run.** `evidence/E4`:

1. `56920b8` adds exactly 14 lines to `rust/wa-operation/src/tests.rs` — a `#[test]` named
   `deliberate_falsification_probe_the_warm_gate_must_fail_on_this` containing `assert!(false, …)`.
   `41ae5c9` removes exactly those 14 lines.
2. **The tree really is restored:** `git diff --stat 56920b8^ 41ae5c9` is *empty*, and
   `git rev-parse 56920b8^^{tree}` = `git rev-parse 41ae5c9^{tree}` =
   `028380ac6d7d2c12d8f925d3629c55e3c5f4609e` — the same tree the cold and warm runs gated.
   `git diff --name-status da8dc891 7ed53a38 -- rust/` is empty: no trace of the probe in the tip.
3. **Warm gate went RED on it (slot #191):** candidate tree `4f67582f…` (base + `56920b8`),
   `clone.reused = true`, gate exit **101**, lane exit 3, `gate.ms` 24 756.6. Its retained gate log
   (sha256 `0f6112694fbe…`, re-hashed and equal to the run's own `log_sha256`) contains
   `180: Compiling wa-operation v0.1.0 (…merge-lane-tree-landing\rust\wa-operation)` — the reused tree
   **recompiled** the crate whose source changed, which is the invalidation under test —
   `244: test tests::deliberate_falsification_probe_the_warm_gate_must_fail_on_this ... FAILED`,
   `266: panicked at wa-operation\src\tests.rs:11:5`, `274: test result: FAILED. 36 passed; 1 failed`.
4. **Reverted, the same warm tree passed (slot #193):** run `restored2`, candidate tree `028380ac…`,
   `clone.reused = true`, gate exit **0**, `gate.ms` 854 594.2, verdict line `smoke ok (2 skipped)`,
   log sha256 `65dd709daf7b…` (re-hashed, equal), phases `build 22028` ms (warm).
5. **Independently corroborated:** the gate lane's own records read `failed #191 merge-lane
   4f67582f3b46 exit 101`, `failed #192 … exit 1`, `done #193 … exit 0` (`evidence/E2`).
6. The named tree's owner record shows `runs: 5`, `created_at 16:42:19Z`, `last_used_at 17:40:21Z` —
   exactly five runs (cold, warm, broken, restored, restored2), and its reuse lock is gone.

**Proven by receipts:** a content change in the merged tree reaches the *warm* gate as a red verdict
after a rebuild, and removing it returns that same warm tree to green.

**What a fresh gate would still be needed for (the producer names most of this; I agree):** the probe is
`cfg(test)` code, so this exercises the rebuild of **wa-operation's test target**, not a release-rlib
rebuild from a non-test source change; and the toolchain-clearing and dirty-tree paths were not
exercised by a real gate. A second observation worth carrying: restored run 1 was red on the *same*
candidate tree for an unrelated reason (`AssertionError: the node reported busy while the subagent ran
(reserved capacity)` at `scripts/test-job-subagents.cjs:38`, `evidence/E4`), then green on re-run — so a
warm gate can be red for noise, which is the safe direction, but it is one unresolved sample.

## 3. The clone reuse: correct by code, with a real refusal→cold-clone fallback

Code path at the tip (`scripts/merge-lane.mjs`), read in full: reuse is refused unless the directory's
toplevel is itself, its `origin` is the landed repository, its owner record names that repository, the
reuse lock is free or held by a provably dead pid, and — after `git clean -xdf -e target`, a pinned
`core.autocrlf`, `git switch --detach --force <base>` and `git reset --hard <base>` —
`git status --porcelain` is empty (`evidence/E6` quotes the function). `-e target` is what keeps the
warmth; `clean -xdf` is what discards everything else, and what it discarded is *named*
(`reuse_dirt_discarded`). A refusal does not fail the landing: it is recorded in `clone.reuse_refused`
and the run continues in a disposable clone (`fallback(...)` → `cloneRepo`), i.e. cold and correct.

* **Held for the whole run:** the reuse lock is released only after the gate
  (`releaseReuseLock(clone.lock)` sits after the gate/result block, plus a `process.once('exit')`
  handler), so two lane runs cannot reset one tree under each other's gate; the second is refused by
  name and gates cold in a clone.
* **`target` really is kept:** the warm run's build phase is 22 635 ms against 797 521 ms cold, and
  `rust/target/release` is present in the persistent tree now (read-only `ls`).
* **`git status --porcelain` empty after a run:** each receipt after the warm run reports
  `reuse_dirt_discarded: []` — i.e. the *pre-reset* porcelain status of the tree the warm run had just
  gated in was empty (`evidence/E2`). `scripts/test-merge-lane.mjs` §9b asserts the same thing directly
  (`git(tree,'status','--porcelain') === ''`), plus: the default tree is never created for a repository
  under the temp directory, a named tree is created once and reused, a dirty tree's 2 discarded paths are
  named, a tree with a foreign lock is refused by name and the candidate is still gated in a disposable
  clone, and a non-checkout is refused without being touched.
* **What I could NOT verify first-hand:** I did not run that suite (its fixture runs request the gate
  lane, and the slot is held), so §9b stands on the code I read, not on a re-run. The retained refusal
  receipt `<home>/refusal-probe.json` shows a real refused reuse (`reuse_refused: "it is not a git
  checkout (…)"`, `clone_ms 281.779`, disposable clone created) — but that particular probe ended
  `verdict: gate_refused, exit_code 6` (its slot was refused), so it evidences the *refusal and the
  clone*, not a gated fallback. The gated-fallback path is pinned by §9b only.

## 4. The wrapper defect: the wrapper is DROPPED, and no remaining instrumentation can change a verdict

**Dropped, verified at the tip.** `git ls-tree -r --name-only 7ed53a38 -- scripts/lib` contains no
`gate-shims/`, no `gate-suite.mjs`, no `gate-suites.mjs` (`evidence/E5`). The only surviving references
anywhere are in `docs/` (MERGE-SPEED prose and the measurement/backlog JSONs). `scripts/lib/gate-phases.sh`
(98 lines) is the whole remaining instrumentation.

**`scripts/test.sh` is purely additive and check-neutral.** Its whole diff against `origin/main` is
+20 lines / **0 removed**; filtering the added lines down to "not a comment, not
`. scripts/lib/gate-phases.sh`, not `trap gate_phase_summary EXIT`, not `gate_phase_begin <name>` or
`gate_phase_summary`" leaves **nothing**, so no check, no exit code, no `SKIPPED` arithmetic and no
suite invocation is added, removed, reordered or skipped (`evidence/E5`).

**Can the remaining instrumentation change a suite's verdict or count?** No, on three independent
checks: (a) no PATH shim, no `$BIN` rewrite, no per-suite wrapper exists to interpose; (b) the phase
helper prints once (`GATE_PHASE_WRITTEN` guard), always `return 0`, never calls `exit`, and cannot fail
the gate; (c) it prints its table *before* the verdict line, and the three green receipts all end on the
verdict as the log's last line — which is what `merge-lane.mjs` and the finish gate anchor on — with the
same skip count (2) as the rest of tonight's green gates. In the deliberately-broken run it correctly
printed the partial table instead of a verdict. §3b's own defect report is therefore honoured by the tip:
the wrapper is not landed at all, so the 6-of-34 path-spelling defect cannot reach the gate.

## 5. Everything else: every file this tip changes, classified

`git diff --name-status da8dc891 7ed53a38` — 8 files, `1792 insertions(+), 10 deletions(-)`, **no
`rust/` file at all** (the falsification break leaves no trace):

| file | class |
| --- | --- |
| `scripts/merge-lane.mjs` (+331/-10) | **mechanism** — the persistent tree, reuse lock, refusals, toolchain clearing, `--reuse-tree`/`--no-reuse-tree` |
| `scripts/lib/gate-phases.sh` (new, 98) | **instrumentation** — phase wall-time markers only |
| `scripts/test.sh` (+20/-0) | **instrumentation** — phase markers only (verified additive, §4) |
| `scripts/test-merge-lane.mjs` (+61/-0) | **test-only** — §9b pins reuse and every refusal |
| `docs/MERGE-SPEED.md` (new, 298) | docs (the producer's own report) |
| `docs/measurements/merge-lane-tree-landing.json` (new) | docs/measurements — the retained receipt index |
| `docs/measurements/gate-phases-suites.json` (new) | docs/measurements — the 7.4x run, repudiated in §6 |
| `docs/measurements/gate-instrument-evidence.json` (new) | docs/measurements — instrument falsifications |

## Residue (named, with what would close it)

* **R1 (doc accuracy, must fix before §1 is quoted as the record).** `docs/MERGE-SPEED.md:21,27,66,89-91`
  lead with 617.8 s / "on ONE tree" and `:214,251` repeat the same-tree attribution, all from two
  different trees; the same-tree numbers are 800 463 ms
  (this tree), 565 428 ms (w2), 573 376 ms (w3). Also stale in the same file: the header `:3-6`
  ("none of the options below is implemented here" — option 2 *is* landed per §6; and it lists the
  dropped `gate-suite.mjs`/`gate-suites.mjs`/`gate-shims/` as the artifact) and §3c `:191-192`, which
  points a reader at files that do not exist at this tip. Docs-only; the mechanism is unaffected. If the
  owner treats §1 as the decision record, this alone is a `needs-change` **on docs**.
* **R2 (coverage of the invalidation claim).** The falsification exercised a `cfg(test)` change, i.e. the
  test target of one crate. Not exercised by any real gate: a **non-test/release** source change, a
  **dependency/Cargo.lock** change, a **toolchain bump** (the `toolchain_cleared` path exists in code and
  both live trees carry a fingerprint, but it never fired), and the dirty-tree path under a live gate. A
  new suite in `scripts/test.sh` *is* covered by construction — `test.sh` is tracked and re-materialised
  by the reset, so the merged tree's own suite list is what runs; its cost is simply paid per landing.
* **R3 (cost under concurrency).** The saving is per **non-overlapping** landing. The clone/reuse
  decision happens before the slot is acquired, so a landing that arrives while another holds the tree's
  reuse lock is refused the tree and gated **cold in a disposable clone** — correct, but it pays the full
  build. Observed in the window, unattributed by any receipt: a temp clone
  `wa-merge-lane-OggNib` created 14:48 whose own `rust/target/release` was written until 15:01 (~13 min,
  a cold build) while run `restored2` held the tree lock until ~14:54. (Receipts for this delivery's five
  runs show no disposable clone, so the artifact's scoped claim holds; its absolute parenthetical "no
  `wa-merge-lane-*` directory … holds a `rust/target` of its own" is false as of this review.)
* **R4 (small, in the mechanism).** If an owner record has no `toolchain` field (falsy), the toolchain
  check is skipped silently rather than treated as unknown — both real trees carry one, so this is
  latent, not live.
* **R5 (one unresolved sample).** The `test-job-subagents.cjs` capacity assertion failed once on the
  restored tree under other lanes' load and passed on re-run. Named by the producer; still one sample.

## What I could not verify

* Any part of this by running a gate: slot #194 was held by another landing throughout, and a cold gate is
  the resource the delivery exists to protect. No `scripts/test.sh`, no `scripts/test-merge-lane.mjs`,
  no reuse fallback exercised end-to-end by me.
* Whether the *release-profile* artifact invalidation holds (R2), and the toolchain-clearing path.
* The tree's live `git status --porcelain` right now (read-only policy: no git command inside the tree
  the live landing is gating in); the empty-status claim is evidenced by the following run's receipt and
  by §9b's assertion instead.
* Whether `wa-merge-lane-OggNib` belongs to a lane run of *this* delivery — no JSON under the agent home
  names it.

## Harness note

`harness:` the delivery's own artifact claims for the *dropped* wrapper
(`gate-phases-suites.json`, `gate-instrument-evidence.json`) cost review time to re-read as live
evidence even though §6 drops them; a one-line `"status": "superseded - wrapper dropped, see §6"` in
those two JSONs would let a reviewer skip them and shorten the shortest falsifiable path (expected
metric: reviewer reads of superseded artifacts, 3 → 1).
