# Independent review: `change/deploy-record-hardening` (tip `9cc3517`)

**Verdict: narrowed.** Every mechanism the delivery claims reproduces on the exact tree, under my own
fixtures, and each of the six findings is closed *for the state it names* — three of them are narrower than
the commit message says, and I demonstrated each narrowing the only way that counts: **the check still says
`ALL PASS` while the bug is present**.

* Reviewed tree: `9cc351719bc1ee2a580945d4250982a58ddc566e`, tree
  `a86f25c57bd0b5a5adfd925e827bbe935e0cfe16`, 2 commits ahead of local `main` `e2a86bc`
  (`git merge-tree --write-tree main 9cc3517` → `a86f25c…`, exit 0). This review branch — the tip plus this
  directory — merges clean too (`git merge-tree --write-tree main HEAD` → `66045ea…`, exit 0). Review branch
  `review/deploy-record-hardening-child-eaf6` in my own worktree
  (`wa-worktree-childdispatcheaf69dde-54cb-4664-84ae-f69916709273`).
* Producer: `child:dispatch:6204126f-93d1-4249-96a5-514acff56693` (the lane I reviewed as
  `change/deploy-unbound`; I did not produce this delivery).
* **Independence is the lane, not the model.** This node's provider refuses `gpt-6-luna`, so this review ran
  on `deepseek-v4.1-flash`/high — the same family as the producer. What makes it independent is that every
  number below came from my own fixtures, my own mutations and the real scripts, not from the producer's
  report.
* **Hygiene.** No deploy, no node or window restart, nothing pushed, and the live install was never written.
  Read-only, and disclosed: I `cat`ed the live install's `installed.txt` and `deploy-result.json`, and one
  probe copies the live `wa` binary into a throwaway fixture (question 6 below). Every experiment ran in
  `/tmp` temp directories, a private install, or a scratch clone with its own bare `origin`. The mutation
  matrix ran in my own worktree and each file was restored with `git checkout --` (worktree clean after:
  `git status --porcelain` empty).
* Probes: `probe-f1-verdict.sh`, `probe-f1-launder.sh`, `probe-f1-live-and-edges.sh`, `probe-knob-direct.sh`,
  `probe-f6-e2e.sh`, `probe-gate-skip.sh`, `probe-docs-attacks.sh`, `mutations.py`, all in this directory.

## 1. The suites on the tip (baseline, unmodified)

```
$ bash scripts/test-deploy-record.sh        → test-deploy-record: ALL PASS (34 checks; private install directory …)
$ bash scripts/test-deploy-on-main.sh       → test-deploy-on-main: ALL PASS (3 checks; the rule is not waivable by WA_INSTALL_DIR)
$ bash scripts/test-deploy-staging-sweep.sh → test-deploy-staging-sweep: ALL PASS (7 checks; bounded collection, only its own staging names)
$ bash scripts/test-deploy-gate-policy.sh   → test-deploy-gate-policy: ALL PASS (8 checks; the default never looks a release up, the knob refuses by name)
$ node scripts/test-verify-install.mjs      → verify install checks ok (16 checks, 0 skipped; isolated source/install fixture)
$ node scripts/check-deploy-docs.mjs        → deploy docs check ok (6 checks; the doc, the skill and the deploy path say the same thing)
$ bash scripts/test-deploy-downgrade.sh     → SKIPPED, exit 3 (lane branch: see §7)
```

## 2. F1 — a `final` record is not the deploy's outcome: CLOSED

`bash review/deploy-record-hardening/probe-f1-verdict.sh <tree>` builds a deploy's own final record
(`via=deploy.sh`, `record_role=final`, `at=…`) in a private install beside a scratch source tree, and runs the
real verifier. The same fixture against `main`'s `verify-install.sh` (only that file swapped; `scripts/lib/`
is byte-identical between `main` and the tip) and against the tip:

```
###### MAIN (e2a86bc) — verifier sha256 0d8ff2674625b1b9
  A missing verdict      exit=0  NO SUCH CHECK (checks=20, failed=0, skipped=0)
  B stale verdict        exit=0  NO SUCH CHECK (checks=20, failed=0, skipped=0)
  C non-ok verdict       exit=0  NO SUCH CHECK (checks=20, failed=0, skipped=0)
  D control (matching)   exit=0  NO SUCH CHECK (checks=20, failed=0, skipped=0)
###### TIP (9cc3517) — verifier sha256 72372f84c5eeb11e
  A missing verdict      exit=1  [fail] the record was written by a deploy (via=deploy.sh, record_role=final) and
                                      <install>/deploy-result.json does not exist: the deploy that wrote this record
                                      never wrote a verdict, so the record does not establish that it finished
  B stale verdict        exit=1  [fail] the record was written at 2026-10-02T19:30:02Z and the newest verdict at
                                      2026-10-02T19:29:00Z: the verdict is OLDER than the record, so it belongs to an
                                      earlier deploy and this one did not finish
  C non-ok verdict       exit=1  [fail] the deploy's last verdict is ok=false (at=2026-10-02T19:31:00Z, "upgrade.sh
                                      failed"): the record names a deploy that did not succeed
  D control (matching)   exit=0  [ok] verdict ok at 2026-10-02T19:31:00Z, record at 2026-10-02T19:30:02Z
```

On `main` all four states are a healthy install (exit 0, check absent); on the tip each of the three bad states
fails **by name** and says which it found, and the honest state is reported `ok`, not skipped. Reverting the
verifier to `main` also turns the suite red — mutation **M-G** (`node scripts/test-verify-install.mjs` →
`exit 1`, `AssertionError: a missing deploy verdict fails verification: undefined`), so the claim "the check
that fails without it" holds.

Ordering is safe in the real script: the record's last write (`deploy.sh:850`) precedes
`write_result true` (`deploy.sh:854`), and both stamps are second-granular with the comparison strict
(`\<`), so a real deploy cannot fail its own check by being fast.

## 3. F3, F4, F5 — each fix reverted, its suite re-run

`python review/deploy-record-hardening/mutations.py` applies one literal mutation at a time, runs the suite
named in the delivery, and restores the file from git:

| # | mutation | suite | result |
| --- | --- | --- | --- |
| M-A | `record_installed` writes `> "$INSTALL_DIR/installed.txt"` directly (M8: no staging, no rename) | `test-deploy-record.sh` | **exit 1** — `the record is committed by renaming, not by writing the name directly - a direct > installed.txt (mutation M8) calls no mv at all, and fails this check` |
| M-B | the keep-final branch in `upgrade.sh` disabled (`[ "$via" = "deploy.sh-never" ]`) | `test-deploy-record.sh` | **exit 1** — `an interim write cannot downgrade a final record for the SAME bytes - record_role=interim` |
| M-C | the on-main rule wrapped in the old `if [ -z "${WA_INSTALL_DIR:-}" ] \|\| [ "$REQUIRE_MAIN" = "1" ]` | `test-deploy-on-main.sh` | **exit 1** — `the refusal does not name the on-main rule:` the unmerged run reached `deploy: building` → `refused(cargo_unavailable)` |
| M-D | the knob also truthy on any non-empty value, the original semantics, with the value-read case left intact | `test-deploy-gate-policy.sh` | **exit 1** — `WA_DEPLOY_REQUIRE_RELEASE_PROOF=0 was treated as ON (status 3)` |
| M-E | the call site `sweep_stale_staging` deleted (nothing ever looks for residue) | `test-deploy-staging-sweep.sh` | **exit 0, ALL PASS (7 checks)** — see §5 |
| M-F | the sweep function renamed (marker moved) | `test-deploy-staging-sweep.sh` | **exit 1** — `could not read sweep_stale_staging out of deploy.sh (the marker moved?): the residue sweep is gone` |
| M-G | `verify-install.sh` replaced with `main`'s | `test-verify-install.mjs` | **exit 1** — `AssertionError: a missing deploy verdict fails verification: undefined` |

So F3 (M8), F4 (the final→interim overwrite) and F5's rule (the install-dir branch) are each pinned by a
check that goes red when the fix is reverted.

### F5's knob, measured on the real script, not read structurally

`bash review/deploy-record-hardening/probe-knob-direct.sh <tree>` runs the real `scripts/deploy.sh` in a
private install against a scratch tree with an `origin/main`, no cargo, once per value:

```
### tip (9cc3517)                                      ### main (e2a86bc)
  …=UNSET  exit=1  reached the build (proof NOT consulted)   …=UNSET  exit=1  reached the build (proof NOT consulted)
  …=0      exit=1  reached the build (proof NOT consulted)   …=0      exit=1  REFUSED for the release proof
  …=false  exit=1  reached the build (proof NOT consulted)   …=false  exit=1  REFUSED for the release proof
  …=off    exit=1  reached the build (proof NOT consulted)   …=off    exit=1  REFUSED for the release proof
  …=no     exit=1  reached the build (proof NOT consulted)   …=no     exit=1  REFUSED for the release proof
  …=1      exit=1  REFUSED for the release proof              …=1      exit=1  REFUSED for the release proof
  …=true   exit=1  REFUSED for the release proof              …=true   exit=1  REFUSED for the release proof
  …=on     exit=1  REFUSED for the release proof              …=on     exit=1  REFUSED for the release proof
```

`0`/`false`/`off`/`no` meant ON before and are OFF now; the ON set still refuses by name.

## 4. F6 — the sweep works end-to-end, but its *call site* is pinned by nothing (**narrowed**)

`bash review/deploy-record-hardening/probe-f6-e2e.sh <tree> <label>` SIGKILLs a real `cp` mid-write, leaving
two staged files (the sentinel shape `<name>.new.<pid>` and the `ship_file` shape `<name>.ship.<pid>`, 40 MB
each), ages them past the bound, and runs the real `deploy.sh` against that private install:

```
########## WITH the sweep call (tip as delivered)
[TIP] before: …/install/scripts/lib/service-target.sh.ship.888888(40000000 bytes) …/install/wa-sentinel.exe.new.777777(40000000 bytes)
[TIP] deploy exit=1 ; last line: deploy: refused(cargo_unavailable): cargo is not on PATH …
[TIP] deploy.log sweep lines:
      2026-10-02T23:36:29Z … note: staging residue swept: service-target.sh.ship.888888 (40000000 byte(s)) - a staged copy whose rename never happened
      2026-10-02T23:36:29Z … note: staging residue swept: wa-sentinel.exe.new.777777 (40000000 byte(s)) - a staged copy whose rename never happened
      2026-10-02T23:36:29Z … note: staging residue: removed 2 file(s), 80000000 byte(s)
[TIP] install dir on disk: 8.0K
########## M-E: the sweep is NEVER CALLED
[M-E] after: …/install/scripts/lib/service-target.sh.ship.888888 …/install/wa-sentinel.exe.new.777777   (both still there)
[M-E] deploy.log sweep lines: (no sweep note in deploy.log)
[M-E] install dir on disk: 77M
---- and the suite that pins F6, with that mutation still in place ----
test-deploy-staging-sweep: ALL PASS (7 checks; bounded collection, only its own staging names)   exit=0
```

**What this means.** The function is pinned (M-F fails by name) and the residue is really collected
(80 MB, each removal named with its size, three levels deep, with the young and non-pid-suffixed neighbours
left alone). But the delivery's own bug for F6 was "nothing ever looked for one" — and deleting the one line
that makes the deploy look (`deploy.sh:238`) leaves 77 MB of a killed run on disk **and the suite green**.
`grep -rn sweep_stale_staging scripts/` finds it only in `deploy.sh` and the suite that extracts the function
body; nothing exercises the deploy path against residue. The check that fails without the fix exists for the
function, not for its invocation.

## 5. F2 — the doc checker pins one paragraph (**narrowed**)

`bash review/deploy-record-hardening/probe-docs-attacks.sh` (private copy of the tree; the worktree is never
touched):

```
=== 0. baseline: the delivered doc ===                       deploy docs check ok (6 checks; …)
=== A. the stale claim REWORDED inside the checked paragraph ===
   the doc now also says: "a deploy looks a discoverable complete proof up ... and records what it found"   exit=0
=== B. the ORIGINAL stale sentence, byte for byte, two paragraphs later ===                                exit=0
=== C. a release-proof lookup promised in the SKILL ===                                                    exit=0
```

Three ways to make it pass while the documentation is wrong: reword the claim inside the paragraph
(`looks a discoverable complete proof up` misses `/looks up\*{0,2}[^\n]{0,40}discoverable complete proof/`),
restore the original sentence **byte for byte** outside the 1362-char paragraph the checker slices (the doc
then contradicts itself and still passes), or promise the lookup in `skills/self-update/SKILL.md`, whose two
checks are `/does not\s+(consult|look)/` and `/release proof/` anywhere in a 400-line file. It does fail
closed when the opening sentence moves (`no longer contains the paragraph this check reads`), so it is a pin,
not a doc-truth check — which is a narrower guarantee than "the doc cannot drift from the default path again".

## 6. F4's reverse direction is still open: a hand-run upgrade launders `interim` into `final`

Not one of the six, but the same class, and it sits on the branch the F4 fix relies on.
`bash review/deploy-record-hardening/probe-f1-launder.sh <tree>`, on the tip:

```
1) BEFORE: the record a dead deploy left (record_role=interim, via=deploy.sh)
   verdict: FAIL (checks=18 failed=2 skipped=3)
   [fail] the install record is its owner's final one :: the last record is an INTERIM one …: a deploy was installing
          this node and did not reach its own record step …
   [skip] the deploy's verdict matches the record :: … - a hand-run upgrade writes no deploy verdict
   record_install: exit 0            ← the real record_install from upgrade.sh, WA_UPGRADE_VIA unset
   the record now says: commit=unknown source_provenance=unverified-binary record_role=final via=upgrade.sh at=…
2) AFTER a hand-run upgrade that changed NO bytes:
   verdict: FAIL (checks=18 failed=1 skipped=3)
   [ok]   the install record is its owner's final one :: record_role=final, via=upgrade.sh
   [skip] the deploy's verdict matches the record :: … - a hand-run upgrade writes no deploy verdict
   [fail] installed commit is the tree HEAD :: installed unknown is not an ancestor of tree 14296e4
```

A hand-run `upgrade.sh` that changes nothing rewrites the interim record as `final` (its `sha256=` matches the
installed bytes, so the identity branch fires, `commit` stays `unknown`), and the new verdict check then
**skips** it because it is not a deploy's record. The deploy death survives only as the generic symptom
`installed unknown is not an ancestor of tree …`. The F4 fix is monotone against the *downgrade* it names; the
*upgrade* of a role — the direction that erases evidence — is untouched, and nothing pins it.

## 7. The skip path: proved a skip, never a pass

`bash review/deploy-record-hardening/probe-gate-skip.sh <tree> <subject>` executes the gate's own bytes
(`scripts/test.sh:280-291` and `1966-1970`) around the real suite:

```
###### A. lane branch (HEAD is not on origin/main)
  deploy downgrade gate SKIPPED - needs a clean tree that is on (and not behind) origin/main
    (here: 0 uncommitted file(s), 0 commit(s) behind, on-main: no)
    note: the on-main rule that refused this tree is tested in both directions by scripts/test-deploy-on-main.sh
  suite exit 3 → GATE_STATUS=3, SKIPPED=1 → the gate's verdict line: smoke ok (1 skipped)
###### B. control: a tree whose HEAD IS origin/main (scratch clone, main == the tip)
  deploy downgrade gate ok (22 checks)          → GATE_STATUS=0, SKIPPED=0 → smoke ok
###### C. control: the suite exits 1             → the gate's block exits 1 (a failure is not a skip)
###### D. control: any exit 3                    → SKIPPED=1, "smoke ok (1 skipped)"
```

The suite prints no verdict it did not earn: on the lane it prints the `SKIPPED` line and its reason and exits
3; the gate counts it, and the run's last line becomes `smoke ok (1 skipped)`. In a faithful landed
simulation (`git clone` a bare scratch whose `main` is the tip, so the fixture tree is *on* `origin/main`)
the whole suite runs: **22 checks, ok, exit 0**, stable across two consecutive runs — the producer's own
measurement reproduces.

One measurement I made first and am NOT reporting as a defect: faking `origin/main` inside a clone whose
`origin` still pointed at `main` gave `FAILED (9 of 22)`, because the deploy under test runs `git fetch
origin`, which moved `origin/main` back *after* the precondition had been evaluated and made the tree
ahead-of-main mid-run. That is an artifact of my scratch setup, not of the delivery; on a real lane branch the
precondition catches it up front (case A). The residual is a race that needs `origin/main` to move backwards
during a gate run.

## 8. `scripts/test.sh`: additive, and nothing dropped

```
main e2a86bc: 71 gate_run lines      tip 9cc3517: 74
diff of the gate_run sequence (main → tip):  53a54,56  (+3, 0 removed)
whole-file diff: scripts/test.sh | 7 +++++++   1 file changed, 7 insertions(+), 0 deletions
```

The three added lines (`gate_run bash scripts/test-deploy-on-main.sh`,
`gate_run bash scripts/test-deploy-staging-sweep.sh`, `gate_run node scripts/check-deploy-docs.mjs`) sit
beside `test-deploy-record.sh`, and I ran each of the three suites standalone green (§1). They are plain
`gate_run` lines, so a failure is a red gate; none of the three has an exit-3 path, so none can be silently
counted as a skip. Run through the gate's own runner (`scripts/lib/gate-timing.sh`, which is how `test.sh`
invokes every suite), all three exit 0 and are recorded:

```
1875	0	bash scripts/test-deploy-on-main.sh
1860	0	bash scripts/test-deploy-staging-sweep.sh
68	0	node scripts/check-deploy-docs.mjs
```

Nothing else in the repository pins the gate's line count
(`scripts/lib/full-gate-proof.mjs` and `scripts/merge-lane.mjs` read the verdict line and the skip count, not
a command count).

## 9. What I could not verify, and the live install

* **The full gate was not run.** My commit adds review documents only, and the gate that counts for this
  delivery is the merged tree's, run by the merge lane; the producer did not run it either. The command is
  `bash scripts/test.sh`. `finish.mjs check` on my worktree reports every readiness item true (revision, tree,
  branch, clean, fresh refs, current, merge proof) except `pushed`, which stays false because a review commit
  is not pushed (`no upstream configured for branch 'review/deploy-record-hardening-child-eaf6'`).
* **The deploy path itself was never executed past the pre-build refusals** (no cargo on the fixture PATH), so
  nothing here proves a real install, a real swap or a real restart — by instruction, and by design.
* **Two fail-open edges of the new verdict check, measured** (`probe-f1-live-and-edges.sh`), both unreachable
  from the shipped writers, which always write `at=`: a verdict with no `"at"` field passes
  (`[ok] verdict ok at , record at 2026-10-02T19:30:02Z`), and a record with no `at=` line passes beside an
  ancient verdict (`[ok] verdict ok at 2020-01-01T00:00:00Z, record at `). A hand-edited or truncated verdict
  escapes the staleness arm; a hand-written record escapes it entirely. The other two arms (missing, not `ok`)
  still hold.
* **The live install's current record, read-only** — `installed.txt`: `commit=unknown`,
  `source_provenance=unverified-binary`, `record_role=final`, `via=upgrade.sh`, `at=2026-10-02T23:02:02Z`, and
  **no `install_dir=` line**; `deploy-result.json`: `{"ok":false,…,"at":"2026-10-02T20:33:12Z"}`, i.e. a
  non-`ok` verdict seven hours older than the record. Copied byte for byte into a private fixture, the tip's
  verifier says:

  ```
  [ok]   the install record is its owner's final one :: record_role=final, via=upgrade.sh
  [skip] the deploy's verdict matches the record :: the record is not a deploy's own final one
         (record_role=final, via=upgrade.sh) - a hand-run upgrade writes no deploy verdict
  ```

  **Would this delivery have caught it? No — not this state.** The verdict check is scoped to
  `via=deploy.sh` (declared, deliberately), and the live record was written by `upgrade.sh`, so both the stale
  7-hour-old non-`ok` verdict and the record that names no commit are still passed over; the run's only red is
  the pre-existing `installed unknown is not an ancestor of tree …`, which names the symptom and not the
  cause. What it *would* have caught is the same install had a deploy written that record: missing, stale or
  non-`ok` verdict, each by name. §6 is exactly the live shape, reproduced.
* Also observed, outside the six: the live record carries no `install_dir=`, so the verifier's "the record was
  written for this install" check does not run at all for it.

## Findings

1. **F1 — closed.** `verify-install.sh` fails by name for a deploy's own final record with a missing, stale or
   non-`ok` verdict, and reports a matching one `ok`; all four cases pass on `main` (exit 0) and the suite goes
   red when the verifier is reverted. Narrower scope than "the record is the outcome": records written by a
   hand-run `upgrade.sh` are skipped by design, and §6 shows a route that reaches `final` that way.
2. **F2 — narrowed.** The exact stale text is gone and pinned; the checker pins one 1362-char paragraph plus
   two loose regexes over the skill, and passes with the original sentence restored verbatim two paragraphs
   later, or with the claim reworded inside the paragraph, or with the skill promising the lookup.
3. **F3 — closed.** M8 (a direct `> installed.txt`) now fails `test-deploy-record.sh` by name; the rename is
   observed, not described.
4. **F4 — closed for the direction it names (final→interim), narrowed the other way.** Kept final for
   identical bytes is proved, and the revert fails the suite; the reverse — a hand-run upgrade rewriting an
   `interim` record as `final` and the verdict check then skipping it — is unpinned and demonstrated.
5. **F5 — closed.** The knob is read by value (direct measurement on the real script, tip vs main) and the
   on-main rule is unconditional (the old `WA_INSTALL_DIR` exemption restored → suite red; both directions
   exercised on a scratch repository).
6. **F6 — narrowed.** The sweep function is pinned and collects a real SIGKILL residue end-to-end (2 files,
   80 MB, named with sizes, young and non-staging neighbours untouched, bounded at 8 files); the *call* is
   pinned by nothing — deleting `deploy.sh:238` leaves 77 MB on disk and the suite green.
7. **Skip accounting — closed.** `test.sh` is +7 additive lines, 0 removed, 71 → 74 gate runs, each new suite
   green; a skip is counted as a skip with its reason and the run says `smoke ok (1 skipped)`.
8. **New (not one of the six), for whoever next touches `upgrade.sh`:** the role is not monotone *upward*
   (§6). A verifier cannot distinguish "a hand-run upgrade preserved a healthy install" from "a hand-run
   upgrade laundered a dead deploy's interim record", and nothing pins the check that would have to.

Agent: wasm-agent session=child:dispatch:eaf69dde-54cb-4664-84ae-f69916709273
