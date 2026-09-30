# Independent review: revisioned delivery state and notification recovery

Verdict: **refused** on exact tip `b00f456681710b38f18a475047f8d3c31e6237fc`, tree `16874083447182f118df5794a6c70226e3ab0aae`, branch `change/codex-delivery-state`. A changed review during enqueue leaves an older durable intent unsettled while the next reconciler reports success and zero pending events. Full workflow, installation and merged-tree smoke remain pending.

Producer: `term_2806604b-b664-48da-8aed-68b78b482bdd`. Independent reviewer: `codex`, authentic session `term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50`, Codex thread `01a0f296-0194-7cf3-ba24-f89d764b1a0b`. Reviewer branch: `change/review-codex-delivery-state`, based on `origin/main` `da8dc8918a34c880768956ff775d883802dcb7a7`; dispatch `task_b81cf9532896` / `ctx_75c75e838ee6`; date 2026-09-30.

I did not author this delivery. Base `3290d32727fcfc77e0646039f6322b0821a408c2` was already independently reviewed in `1d5f7ca119e0431e158f6962fa63f441655dd520`; this review focuses on `1939ff46d5a7bc15abd8ce3a44c8d53c53ff35e2`, `b00f456681710b38f18a475047f8d3c31e6237fc`, and their interactions. All prior local review refs/history remain preserved. I read AGENTS, parallel-evolution and the exact source delivery-recovery procedure.

## Blocking falsification

**`summary_exceeds_code:unresolved` — prior-generation pending intent is silently omitted after an in-flight review change.** The procedure promises that pending events or record-write failures are reported with exit 4, and that reconciliation observes the exact existing enqueue effect before retrying emission.

The independent fixture uses the exact archived trigger/store/outbox modules, a private Git repository with published-review observations, a private job database, and an isolated emitter. During emission it verifies that the pending intent and exact payload are already durable, inserts the queue effect, then changes the delivery's review through the real revisioned `writeRecord` before the original trigger can save acknowledgement.

| Observation | Actual result |
| --- | --- |
| First trigger | Exit **4**, `write_errors=1`; its acknowledgement write loses the CAS race. |
| Record after first trigger | New independent refused review preserved; old outbox intent still **pending**. |
| Durable queue | Exactly one queued effect with the old event ID, expected subscriber revision and exact persisted payload. |
| Second trigger/reconciler | Exit **0**, `pending_events=0`, `write_errors=0`, current review refused. |
| Record after reconciliation | The old intent is still **pending**; current admission's event is null. |
| Emitter calls | **1**; neither duplicate enqueue nor lost queue row is claimed. |

The assertion fails: `unsettled old durable intent was silently omitted from the reconciliation result`. Evidence is retained in `intent-race/evidence.json` with both passes' stdout/stderr, intent proof and queue row. The result was sent promptly via escalation `msg_b819e78435c1` before this report.

The trigger computes/settles only the current generation. When the current review refuses, it never observes the exact older receipt or accounts for older pending outbox entries. CAS correctly prevents overwriting the newer review, but that alone does not reconcile its older durable intent.

**Required repair:** reconcile or explicitly report unsettled prior-generation intents when review/tip/subscription changes, including current refusal. Existing exact effects must be observed without invoking the emitter again. A successful pass must not claim zero pending events while silently leaving such an intent pending. Add the in-flight review/CAS acknowledgement race as a regression. I made no producer repair or architecture change.

## Passing evidence and limits

- Real concurrent stale writers settle with one named CAS refusal; the winner's fields remain intact. Independent probes also verify real OS-lock owner crash recovery, 29 complete reader snapshots during 24 atomic updates, stale-write preservation and immutable landing.
- Event identity distinguishes a new tip with the same tree, changed review and changed subscriber revision, while equivalent object-key ordering stays stable.
- Source outbox fixtures verify durable pending intent before emission, nonzero emitter failure, queued-zero refusal, exact receipt recovery after local acknowledgement interruption without invoking the failing emitter, and new subscriber revision generation.
- Independent legacy-schema observations leave private database bytes unchanged, reject different payloads, fail missing schema columns, and fail a missing database without creating it. Receipt API responses with wrong identity or missing read-only authority refuse clearly. The Rust focused test passes exact, missing, stale, different-payload and disabled-job receipt cases; source opens its receipt connection read-only and avoids the schema writer path.
- The final provenance footer requires exactly one strict `session=` token. The 58-check admission suite refuses `nosession`, legacy fallback, duplicate sessions and body-spoof provenance while retaining authentic Codex/Pi/Claude provenance. This closes the earlier permissive-parser caveat on the bound tree.
- **`unverifiable_claim:unresolved`** — full workflow/installation, live sentinel/node receipt wiring, native Linux/macOS coverage and publisher/merged-tree smoke were not exercised. The sentinel's own-manifest cargo check is producer evidence, not an independent result here.
- **`boundary_gap:unresolved`** — the new store/outbox tests and recovery spell are not yet wired into the standard gate. The explicit legacy read-only schema seam was used for the enqueue race; deployment of the receipt API remains pending.

## Commands and retained evidence

Private retained root (`$deliveryScratch`): `C:/Users/Victor/AppData/Local/Temp/wa-codex-delivery-review-813cee79981a4bd69966b4aaee8fe769`. Exact source was materialized with `git archive --format=zip --output="$deliveryScratch/delivery.zip" b00f456681710b38f18a475047f8d3c31e6237fc` and `Expand-Archive` into its `source` directory.

All fixtures use private homes, databases, Git repositories, temp directories and owned processes; no live reservation, model or runtime was contacted. Node `v24.19.0`, Git `2.55.0.windows.3`.

| Command | Observed result |
| --- | --- |
| `node scripts/test-delivery-admission.mjs` from archived source | Exit 0; **58 checks**; no skipped check branches. |
| `node scripts/test-delivery-store.mjs` from archived source | Exit 0; **9 checks, 0 skipped**, real competing processes. |
| `node scripts/test-delivery-outbox.mjs` from archived source | Exit 0; **8 checks, 0 skipped**, isolated emitter/store. |
| `cargo test --offline --manifest-path "$deliveryScratch/source/rust/Cargo.toml" -p wa-jobs exact_event_receipt -- --nocapture` | Exit 0; **1 passed, 0 failed, 0 ignored, 33 filtered out**; private target/home/temp, build jobs=1, test threads=1. |
| `node "$deliveryScratch/store-receipt-probes.mjs"` | Exit 0; **15 checks, 0 skipped**. |
| `node "$deliveryScratch/intent-race-probe.mjs"` | **Exit 1**, failed prior-intent settlement assertion; raw evidence saved before assertion. |
| `git merge-tree --write-tree origin/main b00f456681710b38f18a475047f8d3c31e6237fc` | Exit 0; `03d27df53f91feb22877d97697f839535b2d8046` against the base named above. |

The first store/outbox fixture runs passed their checks but exited 1 in their cleanup assertions because this review's TEMP value mixed native slash forms. I normalized TEMP/TMP with `Join-Path` and reran unchanged source successfully; both initial logs remain as `test-delivery-store-first.log` and `test-delivery-outbox-first.log`. Those initial runs are not reported as passes. Rust warnings were nonfatal; only the named focused test ran, not the 33 filtered tests.

| Evidence relative to retained root | SHA-256 |
| --- | --- |
| `source/scripts/delivery-trigger.mjs` | `eba781d9a63a982ca160e1a933a46ddfd7e07943ceea4a89f873bf8a392e064c` |
| `source/scripts/lib/delivery-store.mjs` | `5218d44e5c228486ae1a34f144c95aad061a96f97f0a5f1a418ee9b112b452e7` |
| `source/scripts/lib/delivery-outbox.mjs` | `9fde56b43322b5c74a43e979a98feefa83f0965ffcc6d671e1dd3ef9b4ecdb8f` |
| `source/scripts/delivery-admission.mjs` | `23e1ad04f99eb3bd9c137d4bef16a82b68a514f48613cd6036ae182dce57b6d4` |
| `intent-race-probe.mjs` | `f85de4ecfdce074dc6656769c4b1b21c150fbcba120b1b524a431a494f51dc18` |
| `intent-race/evidence.json` | `63edabb325627cec2a219052bac835ae306643d4e26d5d31052e76aeb49d33ea` |
| `intent-race.log` | `d8c76da47cffa21b7d8369fdb191b241542bd966f0cae429d55f63b56d4d6f18` |
| `store-receipt/evidence.json` | `324e3a0eac204774f314172338c94b00bf176506029345ac81b59446a58a7ead` |
| `store-receipt.log` | `751a52d74582a78571fddd68f44296210d48b8d083516c15902916fdc518cdac` |
| `test-delivery-admission.log` | `5e34c2649b2443889e4f43e3dd19b3b20a09fc4f5bdeb19e34b77f0642d9bbb0` |
| `test-delivery-store.log` | `644a11746a30ab11fa0aeb1d1061d15e8bd0e218f4da3f3b443d7cf2208b1eed` |
| `test-delivery-outbox.log` | `c259c58c5e2026e90a582349c9b424d4139fd00fe243d165e068ca52405d8826` |
| `rust-receipt.log` | `87529ff94f0eb51356d2696c6b3fe1ad9c9c854a17d05b63ea3133d6c58e12e9` |

Only this report and schema-1 manifest are committed/pushed on the independent branch with `Agent: codex session=term_3baca61f-5cd3-4e24-92d2-0a4eb0eb6f50`. Raw evidence and prior reviews remain preserved. Parent relays the exact refusal to sole publisher wasm-agent `df71ee84` and owns any repair. No producer, main, installed files, live state, other worktree or branch cleanup was changed. Review-tip merge proof is delivered through this dispatch lifecycle.
