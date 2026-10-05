# Independent repair review: REFUSED acceptance; narrow runtime safety verified

Exact delivery: `change/wa-session-childdispatch009bbf4b-3957-461b-959e-23a22f58fa29`
Tip: `288cdd5ab7a260e775a0944dac011182fe476ede`
Tree: `0406348cf61abfbad914dd735e2841f19673b88f`
Main: `898a9a238c89c5f64b83cfa219f8c17840b441f9` (local and remote observations).
Reviewer: `child:dispatch:98e77c9b-60c9-4a3f-8bf3-5eda1620f33c`
Producer: `child:dispatch:009bbf4b-3957-461b-959e-23a22f58fa29` (independent of reviewer).
Owned review branch remains `change/wa-session-childdispatch98e77c9b-60c9-4a3f-8bf3-5eda1620f33c`.

Original e15bdc1 refusal commits `4d2257d` / `d7bc370` and all original probes/evidence remain intact; original evidence hashes rechecked equal. This review reads the entire repaired tree against main and against e15bdc1, not just the last repair commit. No producer implementation was edited.

## Acceptance blocker R1: regression protection is unreachable

Exact repaired tip `scripts/test.sh:246-260` enumerates lifecycle/retire/executor/proof/restart/public only. `scripts/gate-checks.mjs:19-30` catalogs the same wave family. Neither calls owner-refusal, owner-mutations, activity-corners, activity-fix or derived-state; no reachable normative suite imports/spawns those tests. The only incoming owner-refusal reference is owner-mutations, itself unreachable. `results/gate-reachability.txt` preserves the bounded entrypoint and incoming-reference evidence.

The explicit prevention acceptance criterion is therefore unmet. Manual 281-check proof cannot establish recurrence protection. Bounded producer remedy: wire the owner safety regression and mutation/phase coverage into the normative gate/catalog with truthful verdict/count handling, then demonstrate reachability and real mutation assertion kills. Do not silently treat catalog coverage globs as executed fixtures. No full gate was run and no reviewer implementation of this fix was made.

## Verified NARROWED safety result (not a completed original recovery)

Original B1/B2 are repaired: public resolve always refuses supported-source activity ownership with `exact_owner_settlement_and_drain_unavailable`; it has no success/persistence path. `findResolution()` returns null irrespective of negative, absent or positive corroboration, preserving old receipt bytes but disabling replay. This is an explicit capability reduction, not invented owner/drain validation. Source exposes no authenticated exact-owner terminal+descendant/effect-drain adapter.

Independent warm-review heartbeat probe was adapted into a NEW file (`probe.mjs`), leaving the original intact. Exact tip retains working false/null owners as ON, refuses creation without a receipt, then rejects valid exact-identity legacy prose replay while retaining the receipt bytes. Visible holder also refuses. Producer owner suite independently verifies fresh-process observation/replay, changed run and boot, visible holder recreation, unsupported terminal-looking stale ownership, observation accuracy and named unavailable source. No legitimate settlement success is tested or claimed. Direct CLI flags are ignored, but no flag can cause success or fake identity acceptance: all found owners still fail named unsupported settlement.

`observe` truthfully emits `resolvable:false`, supported refusal and recovery guidance. Existing legacy bytes remain available to readResolutions for audit; no receipt deletion or migration was introduced. The retained writeResolution helper can store audit/fixture bytes but cannot cause settlement while replay is disabled.

Availability cost: an old positive active steering row remains ON; an unresolved stale child/tree/binding remains named UNVERIFIABLE. This does NOT implement stale cleanup, automatic wave ending, an authenticated terminal/drain adapter, or the original full lifecycle. Accepted narrowing is safety only.

## Actual focused execution

Private exact-tip archive, actual exit 0 for each:

- owner-refusal: 53 checks, 0 skipped
- corners: 24 checks (formerly 30, deliberate replacement of unsupported prose-success assertions with explicit refusal/held properties)
- derived-state: 55 checks
- activity-fix: 62 checks
- lifecycle: 44 checks
- retire: 20 checks
- public: 23 checks, native private runtime/source Lua; missing application verification correctly blocked

Total **281 focused checks**, no focused skips reported. Owner mutations: **3 kills**, each exit 1 for the intended assertion, not timeout/setup failure: creation `Missing expected exception` at refuse; replay `owner retained, not OFF`; M5 `observe positive/corroborated/resolvable accuracy`. Parent mutation suite exit 0. Raw assertion traces retained.

Public binary was copied read-only from producer's built debug candidate into our private directory, SHA256 `0094516f76dbe05af604ceb1c60c0d688d4fe730f9454bd9e4588e041cd96023` (matches claimed bytes). Archived source root supplied by public fixture via WASM_AGENT_LUA_ROOT; private home/data/install. CARGO_BUILD_JOBS=2/RUST_TEST_THREADS=2 set for the run. This reviewer did not rebuild it, install it or reuse the incompatible old wasm_cli binary. Byte identity and observed native test are verified; compilation provenance is producer-attested, not independently reproduced.

Independent probe exit 0 in addition to these counts. Extra private phase instrument extends corners on the mixed completed-newest/older-unfinished store: all four freeze phases refuse (produce/allocate/admit named frozen; land named fresh-public-start with exact older ID). Instrumented corners28 exit 0. Unfrozen delivered suite verifies produce/allocate allowed and land/admit named older ID refusal, plus read-only observe allowed. No phase coverage was skipped.

All real helpers in owner suite, mutations and independent probe are direct owned children, killed by exact process handle and awaited on exit in finally, including assertion-failure mutant runs. No paid model loop or live-owner cancellation was used.

## Exact tree convergence

`git merge-tree --write-tree origin/main 288cdd5` exits 0 and returns **the identical delivered tree** `0406348cf61abfbad914dd735e2841f19673b88f`. Thus focused exact-tip source tests cover the merge-probed source bytes as well; no different merged source tree was certified. Remote heads observation contains main only at 898a9a2. No main merge/ref publication/deploy occurred.

## Additional caveats / scope limitations

- Dead replay-success branches remain in `scripts/lib/wave-activity.mjs:342,348`: both depend on findResolution, which unconditionally returns null. They cannot currently clear an owner, but contradict the requested no-dead-success-code cleanup and create a future enabling hazard. Remove misleading unreachable settlement branches in bounded producer cleanup; this is additional unmet cleanup, not evidence B1/B2 remain exploitable now.
- WAVE-CONVERGENCE.md still has the sentence 'reported with a ready-made resolution command' immediately before explaining unsupported settlement. The surrounding playbook clearly says refuse/no write, but this leftover wording is misleading and should be corrected (nonblocking doc caveat).
- A terminal-looking stale row isn't tested as legitimately settled and should not be: no trusted drain API exists in scope. Constant refusal is intentional and honestly documented, not a claim to have validated nonexistent legitimate resolution.
- Updated activity-fix assertions explicitly test unsupported refusal for missing/wrong/right identity flags, no receipt writes, unverifiable persistence and next-wave refusal. Corners removes unsafe success expectations and moves visible/replay coverage to owner-refusal; that relocation reinforces R1 until entrypoints reach it. No blanket skip hides changed scope.
- Full release gate and application deploy not run. No producer tree, live wave/memory/resource/index store, install, main or remote ref was changed. Only the new DELIVERY record is authorized for a local reviewer update in this continuation; original e15bdc1 record stays unchanged. Publication/admission remains external and blocked by existing pushed-ref contract/no-push scope.

Evidence/instruments under `review/wave-owner-repair/`; exact source/binary/private fixtures under ignored `.review-private/`. Independent refusal verdict does not authorize landing or claim a finished wave.
