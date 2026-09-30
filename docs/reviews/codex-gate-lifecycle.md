# Independent rereview: corrected gate lifecycle

Verdict: **narrowed** on exact tip `c8589c7f57dea40c0476c8984694fea7dc7b1770`, tree `b71e56efc505b133c0ef644707c51f3c9adcf953`. The blocking detached-descendant drain finding is **resolved on this tree**. Full merged-tree smoke, native Linux coverage and merge-lane adapter convergence remain pending.

Producer: `term_2806604b-b664-48da-8aed-68b78b482bdd`, branch `change/codex-gate-lifecycle`. Independent reviewer: `codex`, authentic session `term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50`, Codex thread `01a0f296-0194-7cf3-ba24-f89d764b1a0b`. Reviewer branch: `change/review-codex-gate-lifecycle`; dispatch: `task_87d4718ed368` / `ctx_62b4512e09a9`; date: 2026-09-30.

The earlier refusal of `19bf2bdd2f434f48756a522cb2388923c3a02e5b` remains preserved in review commit `97fd67973d50473a27b946bf9485b09775c3dbd2`. Its raw fixture description and evidence are not repeated here. This bounded rereview covers the correction and related regressions; I authored neither producer commit. The schema-1 manifest beside this report binds both reviewed commits and the corrected tip/tree.

## Verified correction

- The **unchanged** independent timeout probe now exits 0. After owner PID **54504** exited, descendant PID **72972** was positively alive before and after the next private command. That command refused with exit **75**; the reservation remained **orphaned**, with **`drain_required=1`**. The probe hash matches the one that falsified the prior tip.
- Finish calls owner/lease-validated `defer` before dropping uncertain execution. Ordinary release refuses drain-required rows. Reconciliation and the acquisition watchdog preserve cancelled running work instead of inferring drain from disappeared roots.
- The retained independent fixture still held `drain_required=1` after its owned owner, survivor, watcher and recorded gate were stopped and observed absent. An ungranted queued request lost its lease and recovered only its queue position; the protected reservation stayed held. Explicit owned stop/reconcile evidence then cleared the flag and admitted the next stand-in command.
- Archived `test-gate-drain.cjs` independently verified live-survivor refusal and explicit stop/reconcile/resume. The changed lifecycle suite passed **31 + 18 checks**, including cancellation recovery and fast-command sampler settlement.
- Source hashes and absolute native Git Bash selection were verified. No producer bytes changed. The unchanged probe uses its prior **2500 ms** execution-timeout seam and **9 s** owner retention instead of waiting out the production 3500-second budget.

## Findings and limits

1. **`summary_exceeds_code:resolved`** — the prior timed-shell descendant falsification now refuses the next gate, persists drain uncertainty after owner exit, and resumes only after explicit owned drain evidence. No required repair remains for that finding on this tree.
2. **`unverifiable_claim:unresolved`** — publisher/merged-tree full smoke is pending; native Linux/macOS execution and installed-runner convergence were not tested. These are private Windows fixtures with fake commands, not a production gate receipt.
3. **`boundary_gap:unresolved`** — `scripts/merge-lane.mjs` remains unchanged and its adapter convergence belongs to the warm owner. The new Windows-only drain regression was invoked manually here and is not named by this tree's explicit `scripts/test.sh` test list. Do not infer standard-gate inclusion or Linux coverage.

The compatibility cost is explicit: cancelled running reservations need owner drain evidence even when recorded roots vanish. Waiting-only lease loss still recovers its queue position automatically. Reconciliation trusts supplied drain evidence; these fixtures establish honest owned recovery, not authentication of arbitrary evidence text.

The previously passing finish26 and wiring38 suites were not rerun for this bounded correction. The producer reports them passing on the corrected tree; this report does not adopt those reports as independent results. No broader architecture or unrelated fixes were reviewed.

## Commands and retained evidence

Private retained root (`$rereviewScratch`): `C:/Users/Victor/AppData/Local/Temp/wa-codex-gate-rereview-078ced0fc262413483c64351a48651a5`.

```powershell
git archive --format=zip --output="$rereviewScratch/delivery.zip" c8589c7f57dea40c0476c8984694fea7dc7b1770 scripts skills .githooks
Expand-Archive -LiteralPath "$rereviewScratch/delivery.zip" -DestinationPath "$rereviewScratch/source"
```

All commands used archived source, separate private TEMP/TMP directories, private home/store fences and cleared inherited markers. Git's bin directory was prepended to PATH. Node `v24.19.0`, Git `2.55.0.windows.3`.

| Command | Result |
| --- | --- |
| `node "$rereviewScratch/drain-probe.cjs"` | Exit 0; unchanged independent falsification refused; source hashes verified. |
| `node scripts/test-gate-drain.cjs` from archived source | Exit 0; descendant refusal and explicit owned recovery passed; Windows path ran, no skip. |
| `node scripts/test-gate-lane.cjs` from archived source | Exit 0; core31 and orphan18 checks, both **0 skipped**. |
| `node "$rereviewScratch/recovery-probe.cjs"` | Exit 0; **7 checks, 0 skipped**; durable uncertainty, waiting lease-loss recovery, reconciliation and resume. |
| `git merge-tree --write-tree origin/main c8589c7f57dea40c0476c8984694fea7dc7b1770` | Exit 0; `b71e56efc505b133c0ef644707c51f3c9adcf953`, against main `ab827c88a6ac091318b5adb8be34e83e858c4e9a`. |

One initial recovery-harness attempt exited 1 because it asserted `waits_for` before the asynchronous update populated it. The corrected oracle waits for that observation; `recovery-first.log` and `recovery-probe-first.cjs` retain the failed attempt. This was not a passing check or skipped test. The unchanged independent probe, source regression and lifecycle suite each ran once.

| Evidence relative to retained root | SHA-256 |
| --- | --- |
| `drain-probe.cjs` | `e71e74b46d1f3f89fbd8a41171b39764414b3adaf2afabbd1f091ff7558a4264` |
| `source/scripts/gate-lane.mjs` | `1094b422ea9571c92f10b2d4456c2c65b9d013c9362b1f2dfd0e8520879077ea` |
| `source/skills/parallel-evolution/scripts/finish.mjs` | `b5b268b4e84ee23dd6cd2cfb436b751637e795e4f2e7023f396d845744f6126f` |
| `source/scripts/test-gate-drain.cjs` | `e36a5420facfb03d12ea8639ca17706c808211f532d409f398fde44b86ebae01` |
| `independent.log` | `15f1cbe1567e92f4ae9a27e2a70109fed1db2463ace6f440dfc095db8bf99791` |
| `regression.log` | `1a3f92d085fe50de060321262a58aff626fd31d2f3de05d949b26f9927172385` |
| `lifecycle.log` | `0be84fc148038b92f968c6ef92eae540db7c317f2442593f47191a1369356b3f` |
| `recovery.log` | `2b6ac98178eefa497bcf352f19bcf58a12ed8526ae255e065a460510d21eff7f` |
| `drain-variant-evidence/drain-evidence.json` | `bea5d82832ae58fa7710735328d9482308d3d90bbe4084a24288fd88702a062a` |
| `recovery-evidence.json` | `0fb755cdd092c98b922d263fe358ad0170e051382eb7bea90cb7c8837d94fcea` |

Raw source, process/queue receipts and logs remain retained until publication settlement. Only this report and the schema-1 manifest are committed/pushed, with `Agent: codex session=term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50`. Closing review-tip merge proof is sent through the new dispatch lifecycle. Parent relays these artifacts to wasm-agent `df71ee84`, the sole publisher. No producer, main, other workspace, installed files, production gate or live runtime was changed.
