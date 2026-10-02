# Review: lane enforcement — re-verified on `c89ee06` (second half of one review)

Reviewed delivery: `change/lane-enforcement`
Reviewed tip: `c89ee06987c7cc079969366e0c8412c44b309f05` (tree `3d09fb4e765cab65a42dbaa66d87721695a53048`, parent `a6d788db0e491b5f5e4ecb15b7577d329312de3c`)
Reviewed delta: `git diff a6d788d c89ee06` — 9 files, +391/-72 (`.githooks/pre-push` mode, `docs/CONCURRENCY.md`,
`docs/SENTINEL.md`, `docs/WAVE-CONVERGENCE.md`, `rust/wa-sentinel/src/main.rs`, `scripts/lib/lane-boundary.mjs`,
`scripts/test-lane-boundary.mjs`, `scripts/test-push-guard.sh`, `scripts/test-wave-monitor-budget.mjs`)

Reviewer: `child:dispatch:ebf847df-ef4b-4371-be67-8e1e6eb54e9e`, in its own worktree
(`C:/Users/Victor/.wasm-agent/wa-worktree-childdispatchebf847df-ef4b-4371-be67-8e1e6eb54e9e`), on
`review/lane-enforcement` cut from this tip. Nothing was pushed, merged or deployed; `scripts/test.sh` was not
run (reserved serial resource); the canonical tree was not touched. Mutation testing ran on a throwaway clone
(`git clone --no-hardlinks … /tmp/mut-tip`); my worktree's one temporary probe edit was reverted and verified
byte-identical to the tip's file.

**Independence.** A fresh lane with its own reading and its own runs, but on `deepseek-v4.1-flash`/high — the
*same model family as the producer*, because `gpt-6-luna` is refused by this node's provider route
(`model_not_servable`). Not a second-model check, and not presented as one.

Verdict: **passed**. The defect that made the first half `narrowed` is fixed and is now *pinned* — I removed the
behaviour and the suite failed. Both rewritten tests now fail when the behaviour they name is removed (10
mutations, 10 caught), the trigger door is closed in both directions, and the refusal reason carries the failing
check's own words, bounded and on one line. What remains is two diagnostic residues, neither of which changes
anything a lane may do.

## First half (tip `a6d788d`): `narrowed`, review commit `79f7afa`

Findings: `.githooks/pre-push` committed `100644` (git ignores a non-executable hook, so the guard was inert on
every POSIX checkout and the delivery's own gate step could not pass there); two of the new tests could pass
with the behaviour removed (a source-text grep for the wiring, a replayed loop for the 120-tick cap); the
trigger path still wrote a request for an unknown verb; a boundary refusal dropped the failing check's stderr;
plus the bootstrap exemption's one-sidedness and the monitor bound's real reachability. All four of the first
four are fixed below; the last two are now documented and asserted rather than changed.

## Second half: the delta, attacked

### 1. The mode finding: closed, and now impossible to reopen silently

`git ls-tree HEAD .githooks/` → `commit-msg 100755`, `pre-commit 100755`, **`pre-push 100755`**. The suite no
longer *trusts* that: `scripts/test-push-guard.sh` asserts the index mode of all three hooks, asserts the
configured `core.hooksPath` is this repository's `.githooks`, and reaches the hook through a plain `git push`
(the per-command `-c core.hooksPath=` override survives only in the three deliberate bypass cases). It also
asserts the refusal names the *fixture's* policy path, so what ran is provably this repository's hook.

Mutations, on the clone at the tip:

| mutation | suite result |
| --- | --- |
| `git update-index --chmod=-x .githooks/pre-push` (index mode `100644`) | **exit 1**: `.githooks/pre-push is committed 100644, not 100755 - git ignores a non-executable hook (git githooks(5)), so the guard would never run on a POSIX checkout (fix: git update-index --chmod=+x …)` |
| hook replaced by a silent `exit 0`, mode intact | **exit 1**: `a non-main branch push was allowed while lane-policy.json declares main_only` |

The first is the case that made the old version pass. It now fails, with the remedy in the message.

### 2. The two rewritten tests: do they still pass with the behaviour removed?

Ten mutations, run against the clone at the tip, each followed by `git reset --hard`:

| # | mutation | result |
| --- | --- | --- |
| A1 | `wave-lifecycle.mjs` entry check neutered (`if (false && manifest.bootstrap !== true)`) | exit 1 — `a wave whose declared enter check fails is not admitted` |
| A2 | exit check neutered (`if (false) fail('lane_boundary_exit_refused:…')`) | exit 1 — `a failed exit boundary blocks the wave` |
| A3 | bootstrap exemption removed (`if (!entry.ok && true)`) | exit 1 — throws `lane_boundary_enter_refused:…` |
| A4 | `lane_boundary_check_stderr` token removed from `lane-boundary.mjs` | exit 1 — `the refusal carries the failing check's own words` |
| B1 | budget fix reverted (`if(false)return …owner_live_or_unverifiable…`) | exit 1 — `tick 4 must keep the monitor scheduled while the owner is alive` |
| B2 | observation cap removed (`.observations>120000`) | exit 1 — `the real monitor() blocks a wave whose spent observations are past the bound` |
| B3 | restart budget removed (`attempts>=300`) | exit 1 — `a dead owner is blocked once the restart budget is spent` |
| C1 | `pre-push` index mode `0644` | exit 1 — mode assertion |
| C2 | hook neutered | exit 1 — `a non-main branch push was allowed` |
| C3 | hook replaced by a silent allow (mode intact) | exit 1 — same |

**The `test-strength` finding is closed.** The boundary suite now builds a real wave fixture (canonical repo on
main, bare origin carrying main only, a valid combined-gate receipt, stand-in land/deploy/retire drivers whose
postconditions pass, a *committed* policy whose phase checks read a flag file outside the repository so a phase
can fail without dirtying the tree the next `verify()` judges) and runs `create()`/`advance()` for: a refused
entry (no wave row at all), an admitted entry, the bootstrap exemption, a blocked exit (durable
`inspect().reason`, no receipt, three ordered stages actually run first) and a completed exit. The monitor suite
drives the real `monitor()` for both bounds. Both would now fail on the behaviour they describe — which is what
the previous version did not do.

### 3. The trigger-verb door

`fire()` now judges the verb with the same `REQUEST_VERBS` list, audits `triggers-bad-verb` and returns before
the `atomic_json` write (`main.rs:1868-1891`). `docs/SENTINEL.md` claims enforcement "at both doors that can
write a request" — checked: `request()` (`:1788`) and `fire()` (`:1889`) are the only two creation sites into
`sentinel_dir()/requests`; the other `atomic_json` sites (`:1548`, `:1630`) move a request between `requests/`
and `claimed/`.

Its own unit tests pass (`a_trigger_with_an_unknown_verb_writes_no_durable_state`, `…request_verb…`; 2 passed).
I did not stop there, because the cheap regression here is the *default*: the docs' own trigger shapes name no
verb (`{"kind":"schedule","every_seconds":30,…}`), and the default is applied by the `object.insert("verb"…)`
that sits above the new check. I injected a temporary probe into the tip's `main.rs` in my worktree and ran it
(one throwaway test, reverted afterwards, file verified byte-identical):

    REVIEW-PROBE verb-less trigger wrote 1; non-string verb added 0; health restart added 1

So: a verb-less trigger still fires (default `wake`); a non-string verb (`"verb": 5`) is refused and writes
nothing; the documented `{"kind":"health","when":"down","verb":"restart"}` still fires. Both directions of the
door hold, and the change does not break the working shapes.

### 4. The refusal reason: the check's own words, bounded, one line

Probe: a fixture policy whose first declared check writes 848 bytes on 8 lines, containing a `|`, to stderr and
exits 1. `node scripts/lib/lane-boundary.mjs <repo> enter`:

    reason (no stderr token): "lane_boundary_check_failed:enter:node probe.mjs"
    stderr token chars: 400 | newline in it: false | pipe in it: true | tab: false
    token head: "probe line 0: Cannot find module X | padding xxxx…"
    detections[0].stderr bytes (untruncated form): 848

Yes: it is the failing check's own words, whitespace-collapsed, cut at exactly 400 characters, and the
untruncated 848 bytes stay in `checks[].stderr`. Their test (d) asserts the same token in the *durable*
`inspect().reason` of a blocked wave, so the token really is what a blocked wave keeps. In this repository the
detector's own failure still reads cleanly — `node scripts/lib/lane-boundary.mjs . exit` in my worktree returned
`lane_boundary_detector:integration_incomplete` with no stderr token, because the audit writes its report to
stdout and exits 1 with empty stderr.

### 5. Everything that proved the first verdict, re-run on this tip

| check | result |
| --- | --- |
| `node scripts/test-lane-boundary.mjs` | `lane boundary ok (68 checks; …)`, exit 0 (was 50) |
| `bash scripts/test-push-guard.sh` | `push guard ok (hook committed 100755 and reached through core.hooksPath; …)`, exit 0 |
| `bash scripts/test-deploy-preconditions.sh` | `deploy preconditions ok (…)`, exit 0 |
| `node scripts/test-wave-monitor-budget.mjs` | `wave monitor budget ok (16 checks; …)`, exit 0 (was 9) |
| `test-wave-hot-guards / test-wave-lifecycle / test-wave-proof / test-wave-restart` | 8 / 40 / 26 / 9 checks, all exit 0 |
| `cargo check --offline --manifest-path rust/wa-sentinel/Cargo.toml` | `Finished dev profile`, exit 0 (one pre-existing `dead_code` warning) |
| `cargo test … -- request_verb` / `-- trigger` | 2 passed / 1 passed, exit 0 |
| boundary end-to-end in my own worktree | `ok:false … lane_boundary_detector:integration_incomplete`, exit 1 |

The three new suites are still wired into `scripts/test.sh` (`:194`, `:1733`, `:1743`, `:1765`), unchanged by
this delta.

## Residues

1. **A `|` in the check's stderr makes the durable reason's token stream ambiguous**, and that one is new in
   this delta. `scripts/wave-lifecycle.mjs` builds a blocked wave's reason as `reasons.join('|')`; my probe's
   2 reasons joined into 6 `|`-tokens, because the stderr body kept four pipes of its own. Blocking semantics do
   not depend on the token stream — a consumer grepping for `lane_boundary_exit_refused` or
   `lane_boundary_check_failed:exit:` still matches — so this is diagnostics-only, but a parser that splits the
   durable reason on `|` will misread it. Escaping `|` (or using a separator that cannot appear after the
   whitespace collapse) would close it.
2. **The bootstrap case fails by uncaught exception, not by assertion.** With the exemption removed (mutation
   A3) `create()` throws out of the test body, so the failure arrives as a node stack rather than a labelled
   check. It fails loudly — the property is pinned — but the diagnosis is a stack.
3. **Record-keeping, outside the delivery.** The refreshed delivery record was reset to `revision 1` with
   `review: null` and **no `tip_history`**, so the first half's review commit `79f7afa` is now on no ref (the
   object is still present; `git branch -r --contains 79f7afa` is empty). The orchestrator did preserve the
   prior record as `change-lane-enforcement.reviewed-a6d788d.record.txt`, which is where that verdict lives;
   nothing in the delivery lost it. Flagged because a `refresh` that drops the history would silently orphan a
   review whenever it is not also archived by hand.

## Should anything block landing?

No. The blocking finding from the first half is fixed and mutation-pinned, the delta is verified in both
directions where it could have broken a working path, and the two residues above are diagnostics — one of them
in a message string, the other in a test's failure mode. Publication remains an open owner decision: by
instruction this review commit is local, so `delivery-admission.mjs`'s `review_not_published` cannot be
satisfied until the branch reaches a pushed ref.

Agent: wasm-agent node=wasm_the_first role=reviewer session=child:dispatch:ebf847df-ef4b-4371-be67-8e1e6eb54e9e
