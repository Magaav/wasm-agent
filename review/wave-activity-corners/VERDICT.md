# Independent review: REFUSED

Delivery: `change/wave-activity-corners`
Exact tip: `e15bdc1da3fad149da141a4ed0989c4b892478ff`
Exact tree: `a853249966c8b5cc1a4046e823e2b8991bdc3ba7`
Delta base: `e2a86bc`
Main observed locally and remotely: `898a9a238c89c5f64b83cfa219f8c17840b441f9`
Reviewer: `child:dispatch:98e77c9b-60c9-4a3f-8bf3-5eda1620f33c`
Owned branch: `change/wa-session-childdispatch98e77c9b-60c9-4a3f-8bf3-5eda1620f33c`
Producer: `child:dispatch:eae7f780-048c-40ad-ac82-d7c4b7d7ccc2` (not this reviewer).

## Blocking findings

**B1: negative corroboration can clear genuinely working ownership.**
`scripts/wave-activity.mjs:75` refuses positive resolution only for `corroborated === true`; `scripts/lib/wave-activity.mjs:265-267,346` applies a prose resolution otherwise. A process command line not naming the worktree is not proof of death: the child runs inside the node, and a held helper can work with its tree only in its cwd. Durable identity matching prevents borrowing, not clearing a live exact identity.

Original failed review session seq151 (`original/session-evidence.json`, raw `seq151.stdout`, full `c1q.out`) observed real working child6204126f with corroborated=false, registered tree, active turn/run/boot. POSITIVE_CLAIM excluded that child; other children kept aggregate activity on. The interrupted review is NOT certified as passed.

Independent `probe.mjs` on an archived exact tip creates private registered ownership and a real helper with a changing private heartbeat. With corroborated=false, the public `resolve()` accepts mere prose, removes the only agent and changes ON to OFF while the heartbeat keeps changing and the recorded turn stays active. See `results/probe-corrected.log`. Visible-process positive control is refused. Helpers were killed by owned handle and their exit awaited.

**B2: unknown process visibility also accepts resolution.**
With process_probe=false, corroborated=null. The same public path accepts prose and turns activity OFF without any owner settlement. This is a reachable source/config option, not a fabricated store error. Unknown visibility must refuse clearing, not behave as negative settlement. See the UNKNOWN_VISIBILITY section of the same corrected probe.

**Bounded remedy (producer work, not implemented here):** retain positive active ownership unless independently validated durable settlement/drain names the exact session/run/boot/child/ownership identity. Require owning runtime/boot lease death or authenticated terminal run settlement plus owned descendant/effect drain; stale-record recovery may then be explicit and audited. A negative or unavailable command-line scan and caller prose alone cannot establish settlement. Revalidate this condition when applying an existing resolution, not just when creating it. Add real working-but-unseen and unavailable-probe refusal fixtures, and correct the playbook's implication that a scan establishes death. Do not broaden this review into another implementation.

## Proven narrower behavior

On the exact tip: corners **30**, derived-state **55**, activity-fix **62**, lifecycle **44**, retire **20** checks passed (exit 0). These suites assert existing safety and functionality but do not falsify B1/B2; corners equates no process naming the tree with nothing running.

A merge-tree probe against observed main is clean, merged tree `657d774f95d88793fd71a33ff8180e8fb2259fc0`. Its private archive reran corners30/derived55/activity-fix62 successfully. This is focused merge evidence, not a release gate.

The corrected independent identity probe asserts same blind identity matches, new run or boot does not, and visible corroboration suspends resolution. Delivered corners verifies completed newest plus unfinished older admits produce/allocate, still fences land/admit naming exact older id, and closing freeze still fences production/allocation. These passing subclaims do not make the unsafe delivery acceptable.

## Nonblocking caveats and execution limitations

- The public suite was attempted using the available installed wasm_cli binary (hash retained). It fails during private setup: `memory.lua:60: no such table: child_completions`. That binary is dated September 22 and incompatible with the archived tree's schema; no build/install/live migration was performed. Public native end-to-end evidence is unverified, separately from the proven blocker.
- Initial independent probe used native backslashes in its manual identity control, so its sameBlind=false was not meaningful. Original log retained; corrected slash-normalized probe adds assertions and establishes nonborrowability. B1/B2 reproduced in both runs.
- Original instruments and outputs are preserved byte-for-byte. The originals c1e/c2 read live stores; they were NOT rerun unchanged. New tests write only private repositories/data. Original memory-copy snapshot was retained privately, not committed (it contains unrelated private rows).
- Full release gate was deliberately not run; no production fix, producer checkout edit, main move, install, deploy, live-store write or remote ref change was made.
- Delivery record update is a PRIVATE copy only, bound to this refusal commit; the original live record is unchanged. Publishing review evidence conflicts with the explicit no-remote-refs scope and main-only policy. The record CLI says review commits are published, and admission requires containment in a pushed ref; do not bypass those requirements. Authorized merge-lane/coordinator publication and live-record update remain external work.
- parallel-evolution finish check/verify are used only as diagnostics: own branch cannot satisfy published readiness under this scope; no gate is run to compensate for a refusal.

## Reproduction

`git archive e15bdc1 | tar -x -C PRIVATE_TIP`

`node review/wave-activity-corners/probe.mjs PRIVATE_TIP FRESH_PRIVATE_ROOT`

Run each focused suite from PRIVATE_TIP using `node scripts/test-wave-<suite>.mjs`. Source archives, helper databases, mutation archives and private delivery store remain under `.review-private/` in the owned tree, ignored by its own `.gitignore`. Logs and instruments remain under this review directory. See `results/` for exact observed outcomes and hashes.

## Targeted mutations

Preserved `original/mutate.mjs` completed eight exact-tip archive mutations. Corners killed M1/M2/M3/M4/M6/M7/M8; activity-fix additionally killed M4. M5 (observe always marks positive claims resolvable) survived both usable JS suites. This is a nonblocking test-coverage caveat, not a passing safety argument. Public was red for the incompatible binary even without mutations and cannot count as mutation kills. The original mutation script's final `baseline` runs its REPO argument (this review branch, based on main), not the archive, so its corners=RED is a missing-corners baseline artifact, NOT an exact-tip regression. Exact-tip baseline was independently green30/green62 above; raw output is retained without rewriting. Each mutation archive was private, no producer changes.
