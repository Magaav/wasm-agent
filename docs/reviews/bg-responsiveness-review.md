# Independent review: background responsiveness

Verdict: **passed** for bounded code/evidence review of exact delivery
`change/bg-responsiveness` at replacement tip
`5ab46834330602ffc913278cf30b3ddf9e8e492d`, tree
`8a6ebb9a46a724d1cf3da29448ca01fb41c4a508`, base
`ab827c88a6ac091318b5adb8be34e83e858c4e9a`.
The bounded host-path fix and fixture assertions pass source/evidence review; no blocking
implementation defect was found. This is not a production latency guarantee, gate receipt,
admission decision, integration or deployment approval. The two documentation precision
findings are resolved in the replacement tip; untested behavior below limits the verdict.
The originally dispatched tip `010f25a1cd45c11692caaa6b979c4236b628133a`, tree
`13390e6d5145688a4c011779eb4f0fa078c976e6`, was inspected first; coordinator follow-up
`msg_c4c628a3d9ac` authorized rebinding to the published documentation-only correction.

Reviewer: **Orca terminal `term_9ad62481-604a-4c9e-9aee-bca11d499980`**, task
`task_9fb20fca4650`, dispatch `ctx_6aa2aca88593`. Orca's live terminal listing associates
this handle with `C:/Users/Victor/orca/workspaces/wasm-agent/bg-responsiveness-review`;
the dispatch/check receipt names the same dispatch. The inherited environment's different
terminal handle is not this review's provenance. The reviewer did not produce the delivery.
This document alone is published on `change/review-bg-responsiveness`, cut from current
`origin/main`; producer core files and branch were never edited or checked out here.

## Immutable inspection and per-commit findings

Inspection used `git show` and per-commit diffs of the pinned objects, not mutable producer
files. The complete delivery changes only `scripts/test-bg-responsiveness.cjs`,
`rust/wa-host/src/serve.rs` and `docs/CONCURRENCY.md`. Supporting immutable inspection covered
`serve/scheduler.rs` admission, ownership snapshots and run IDs, `main.rs` startup
redirection, and `lua/core/server.lua` admission, identity and verified peer handlers.
The unchanged Lua paths reject invalid credentials and preserve conversation ownership;
reading these paths is not an authentication integration test.
`git diff --check ab827c88 010f25a1` returned zero.

| Commit | Independent finding | Disposition |
| --- | --- | --- |
| `c3446247ea85bd21d2bc51ca0ee1c7519825ae1b` | Adds the scratch reproduction. Explicit background class, held provider, held worker 0, idle sibling readers, per-request fresh sockets, response tokens and interpreter UUIDs distinguish wrong-worker routing from general listener delay. The separate admission barrier starts with no active run and checks static health/page plus Lua read before releasing identity. Baseline mode requires the failure, not its repair. | Passed for bounded reproduction. |
| `980595b3bac0a2da7551e7a3cf634f8e86d952b7` | Reads exclude scheduler-owned and visibly busy slots, including claimed worker 0 before dequeue. Scheduler snapshot precedes the pool lock, matching scheduler admission's scheduler-then-pool order. A single bounded dispatcher moves identity waits off the listener; queue and resolver share an absolute deadline, and expired resolver jobs are skipped before Lua. Authentication still precedes scheduler ownership and journaling; peer verification, cancellation ownership and send-failure run release remain present. | Passed within documented observational routing and admission limits; cancellation documentation needs qualification. |
| `010f25a1cd45c11692caaa6b979c4236b628133a` | Adds depth-2 overflow, staggered waiter expiry and recovery probes. Named 503 errors, deadline windows, no pressure run IDs, file-based Lua/run-entry tokens and unchanged mock-call count test effects rather than infer them from timing. Normal verification executes all three phases; reproduction skips pressure explicitly. Cleanup releases the added barrier and retains exact-PID exit proof. | Passed for fixture assertions; documentation read range is narrowed below. |
| `5ab46834330602ffc913278cf30b3ddf9e8e492d` | Changes only the measured read range to 1..8 ms and the Cancellation section to admission-dispatcher/shared-identity-queue wording. Immutable diff and tree checks confirm Rust and fixture bytes are identical to the previously reviewed tip. Both independent precision findings are closed. | Passed; final reviewed tip. |

All four commits have producer provenance `Agent: codex
session=term_df8e16a3-c7fd-4081-8ca3-6dc024066d4e`. They form one adjacent delivery.
Neither the dispatcher nor fixture adds per-request threads. Admission queue depth defaults
to 4 and clamps to 1..256; the existing resolver channel depth remains 4. The new pressure
fixture tests outer depth 2, not all supported settings.

## Raw evidence checked

The reviewer parsed all six JSON artifacts, hashed their bytes, and independently asserted
phase scope, modes, verdicts, source-hash agreement, response statuses/tokens, attribution,
pressure timeout/refusal effects, unchanged inference counts and child exit. This validation
executed no server, build or smoke gate. Files are under
`C:/Users/Victor/AppData/Local/Temp/`.

| Artifact | Elapsed | Routing reads | Admission probes | Pressure overflow / expirations |
| --- | ---: | --- | --- | --- |
| `wa-bg-cloud-baseline.json` | 1468 ms | Two at 610 ms; others 3..6 ms | 610 ms each | Not present |
| `wa-bg-cloud-baseline-2.json` | 1382 ms | Two at 610..611 ms; others 4..6 ms | 610 ms each | Not present |
| `wa-bg-cloud-baseline-3.json` | 1380 ms | Two at 612 ms; others 4..7 ms | 610..611 ms | Not present |
| `wa-bg-pressure-candidate-1.json` | 3665 ms | 5..8 ms | 2 ms each | 1 ms / 1802, 1801, 1809 ms |
| `wa-bg-pressure-candidate-2.json` | 3630 ms | 5..8 ms | 2 ms each | 1 ms / 1802, 1802, 1802 ms |
| `wa-bg-pressure-candidate-3.json` | 3641 ms | 5..8 ms | 2 ms each | 2 ms / 1801, 1801, 1802 ms |

Baseline **3/3** means both original causes reproduced: routing-0 and routing-3 remained
pending at the 600 ms observation and returned the same interpreter UUID as background
worker 2, while sibling reads completed; admission held health, page and Lua read.
Candidate **3/3** means all routing, admission and pressure phases passed with no skipped
phases, no pending routing/admission probes, and read UUIDs different from background.
These are different test scopes, so total elapsed times are not a speedup comparison.

Pressure uses an 1800 ms deadline and 300 ms probe bound. Every candidate returns
`503 admission_busy` for overflow and `503 admission_timeout` for holder and waiters.
Before release, only the holder entered Lua; after recovery, only holder and recovery
tokens had entered. No pressure token entered run Lua, no sampled health snapshot contained
a pressure owner or even a settled pressure run ID, and mock requests stayed **1 -> 1**
(the one call belongs to routing). Recovery actually entered Lua and returned the expected
400 fixture refusal in 7..14 ms. Pressure health/page/read probes took 1..7 ms.
Every artifact reports `childPidsExited=true` and `retained=true`: child exit is recorded,
but scratch-directory deletion must not be claimed for these retained runs.

Immutable base `serve.rs` SHA256:
`cfb89bec5e7148c13527d000d4d9f5c296519577ab29b7a5ad3bd6be22bdd51d`.
Immutable candidate `serve.rs` SHA256:
`6eaa98da5e48e32b28a7d7d0814970865dd456a000cfb884a1e52420b528067e`.
Independent raw-byte `git show` hashing matches each cohort's `serveSha256` and
`compiledServeSha256`. Candidate fixture SHA256:
`38d60193edf74a3420ef6ad9af6874260d1650333ee6bef7df72c9cefcec8951`.
Baseline binary SHA256 is
`2c426c635c580be51cd7c93ca778056e39e1912ceed7ff8ae541d85bd421ad00`;
candidate binary SHA256 is
`c55254ee08d9d8c09eae29bf6902cde60aa409b1d8a6131de3f585e7cf8cb089`.
The JSON explicitly says `caller-attested-match`: this is source-attested evidence,
not independently extracted binary build provenance or a complete source-tree attestation.
The reports do not contain the script digest; inspection proves the committed assertions,
not cryptographic identity of every historical script invocation.

Artifact SHA256, in the table's order:

```text
86afdf494eb95c99ce1818ac386770e92260ddcb96e8d0aad4100076451bd930
5b535d3b75fbec6ac1722254e1a82d2af0c73fd3ca8e541b0fc22554f83c6490
1fe4a2aaa9b1291d6ffb148ea764644585affda59ad9766c9b203216f00bae73
5f3c099942a54adbb1863bbf0e18675335cc1cd33cce0a663617bd7686b7a2ce
c1ae25e42d6bdea95ed3abe71207dee07a407bcf5245079c55969708ed0d8b78
563ad6b76ae2ad009b7c9871658dbfe3a9abbfce165ec682aea93714b7da0677
```

## Resolved findings and remaining limits

1. **Resolved in 5ab4683:** the original candidate measurement said 1..7 ms. The
   six routing reads reach **8 ms in each candidate**; pressure probes are 1..7 ms.
   The replacement now uses 1..8 ms for the combined measured read scope.
   This rounding-range error does not change any test verdict or production default.
2. **Resolved in 5ab4683:** the original Cancellation section said `POST /runs` was
   answered on the accept thread. It now correctly names the dispatcher and shared
   bounded identity queue/deadline. Some unchanged source comments retain old
   prompt-cancellation wording. Cancellation avoids run workers but
   shares authentication FIFO/resolver capacity and may return busy/timeout. The new
   admission paragraph and corrected Cancellation section state that limitation.
   This review does not certify cancellation under identity
   pressure or a separate cancellation capacity guarantee.
3. Busy labels and scheduler snapshots do not atomically reserve a read. Saturation,
   a new concurrent claim, queued ordinary reads, retirement fallback to worker 0,
   parser delays, interpreter creation, journal/SQLite locking and blocking socket
   writes remain outside the measured guarantee. Static health itself snapshots the
   scheduler and can contend on its lock. Queue deadlines cover residence and identity
   wait after parsing, not every subsequent scheduler or socket operation.
4. An already executing Lua resolver is not interrupted. Its late result cannot
   admit the timed-out caller, but Lua side effects can still occur; subsequent
   identity requests can time out until it returns. FIFO expiry replies require the
   dispatcher to make progress. The pressure fixture tests this controlled held
   resolver shape, not arbitrary stalls or every queue-depth boundary.
5. Fixture configuration is four run slots with two interactive-reserved slots and
   one separate control slot, explicit scratch Lua root, private database/home,
   random ports excluding 8799/8800, a local provider and exact child PID cleanup.
   `--db` preceding `serve` bypasses installed worktree redirection. This validates
   real Rust host paths with minimal Lua, not full application behavior, UI, paid
   provider behavior, peer-signature cases or a real two-node exchange. Three runs
   locate mechanisms; they cannot choose production defaults or throughput policy.
6. The 8-second watchdog starts cleanup; exact child-exit verification has a separate
   1.2-second bound. It is not an exact absolute process-lifetime guarantee.

The prior reproduction report
`C:/Users/Victor/orca/reports/task_a9b77ada2abb-reproduction-review.md` was read as
corroboration, including its independent historical Windows baseline and negative
verification. It does not accept the fix and was not substituted for source inspection.
The fix report `C:/Users/Victor/orca/reports/task_ff745b2dc94b-fix-review.md` was also
read. Its independent reviewer, `term_25b9d360-c00f-4fc5-b022-5b10ea4a6975`, reports
passed code review of original tip `010f25a1` and an independent execution of committed
fixture bytes on the existing candidate cloud binary, without building or gating.
Its raw `task_ff745b2dc94b-independent-cloud.json` records all three phases passing in
4163 ms, routing reads 16..25 ms, admission probes 6..7 ms, pressure overflow 3 ms,
expirations 1809/1802/1803 ms, no extra pressure inference, and child exit with
`retained=false`. The reviewer distinguishes caller-attested compilation alignment
from independent build provenance. This is corroborating independent runtime evidence;
this manifest's author did not execute that run. Its broader statement that documentation
measurements were consistent is qualified by the 8 ms raw routing observations above;
the replacement documentation closes that discrepancy. Both independent runtime reports
predate the documentation correction; their source and test bytes still apply, while their
original complete-tree identities are not silently relabeled as the replacement tree.
The independent raw report SHA256 is
`c867858fc8610b15e3b9e2b9ab3d0126df94789c3e0a6a1425d327f5fbc5df92`;
the fix-review report SHA256 is
`937be0b08d5602ab45729c3b2107c12111a4fb64358b888267c29b4d6cffb7ac`.

## Publication and ownership

Only this Markdown document is changed. The review branch is synchronized with
`origin/main` and must pass `git merge-tree --write-tree origin/main HEAD` before publication;
the exact published review commit is bound in the delivery record's reviewer-owned field.
No full gate was run for this review artifact, as expressly instructed. This manifest
supplies no gate evidence. Root coordinates independent admission after the candidate gate;
the reviewer writes no admission, lane, landing or deployment decision.
At publication, coordinator follow-up reports a prior cloud full gate exit 101 in a sentinel
fixture and a pending isolated rerun. This reviewer did not execute or diagnose that gate;
its failure must not be described as a pass or attributed independently to a preexisting cause.
