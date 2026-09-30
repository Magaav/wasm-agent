# Independent review of the repair: prior-generation outbox intents after an in-flight review change

Verdict: **accept with named residue** — the blocking finding is closed, verified against the
refusing review's own fixture, not against a rewritten one.

Tree under this verdict: `43893c317b1698b79afecace42766cec56217f3f`, tree
`1616036696d0c4da34fe4d2307251a2ab581003f`, branch `change/codex-delivery-state-tail`, base
`origin/main` `a6108eda7613976bf09cf592bf4f1aeca9c1f8c1`. I did not write this repair and did not
touch it: the only artifacts I created are this verdict and its evidence.

The finding that must close, verbatim
(`docs/reviews/codex-delivery-state.md` on `change/review-codex-delivery-state`, tip `9485f95`):
`summary_exceeds_code:unresolved` — *"After an in-flight review change causes the enqueue
acknowledgement write to lose CAS, the next reconciler exits 0 with `pending_events=0` while an
older outbox intent remains pending despite an exact durable queued effect. Reconcile or explicitly
report prior-generation pending intents, including current refusal, without repeating an
already-durable enqueue."*

Factual note on the brief: `git rev-list --count b00f456..43893c3` is **3**, not 5 — the five
commits are the three above the refused tip plus the refused tip's own pair `1939ff4`, `b00f456`
above `3290d32`. The tip and tree named are the ones reviewed here.

## 1. The race, on the repaired tip: before and after

I did not build a new scenario. I ran the refusing review's own probe, **unmodified**, over
`git archive` copies of both tips. Its hash is the hash the review recorded in its schema-1
manifest, so the "before" leg is literally the reviewed artifact:

| artifact | SHA-256 | provenance |
| --- | --- | --- |
| `intent-race-probe.mjs` | `f85de4ec…f51dc18` | the review's retained fixture, copied bytes |
| trigger, before leg | `eba781d9…92e064c` | the hash the review recorded for `b00f456` |
| trigger, after leg | `54cd740f…cd89850` | the repaired tip |
| store / outbox / admission | byte-identical in both legs | so the only variable is the trigger |

Raw output, before leg (`evidence/leg-before.log`, exit **1**):

```
in-flight changed review preserves the new review and reports stale acknowledgement writer with exit 4
reconcile after changed review: exit=0, reported pending=0, old intent=pending, queued exact effect exists=true, emitter calls=1
AssertionError [ERR_ASSERTION]: unsettled old durable intent was silently omitted from the reconciliation result
    at file:///…/before/probe.mjs:66:8
```

Raw output, after leg (`evidence/leg-after.log`, exit **0**):

```
in-flight changed review preserves the new review and reports stale acknowledgement writer with exit 4
reconcile after changed review: exit=0, reported pending=0, old intent=acknowledged, queued exact effect exists=true, emitter calls=1
in-flight intent reconciliation ok
```

The outcome changed in exactly the way the finding demanded. From the two legs' retained
`evidence.json`:

| observation | before (`b00f456`) | after (`43893c3`) |
| --- | --- | --- |
| first trigger | exit 4, `write_errors=1`, `emitted=1` | exit 4, `write_errors=1`, `emitted=1` |
| record after first trigger | new refused review preserved, old intent **pending** | same |
| durable queue | 1 row, `state=queued`, `event_id` of the old intent | 1 row, `state=queued`, same identity |
| second trigger | exit **0**, `pending_events=0`, `refused=1` | exit **0**, `pending_events=0`, `prior_generations_settled=1`, `refused=1` |
| record after reconciliation | old intent still **pending** | old intent **acknowledged** |
| emitter calls | **1** | **1** |

Both legs reproduce the race identically (the first pass still loses CAS with `write_errors=1` and
exit 4); the repair changes the reconciler, not the race.

**The settled intent really is prior-generation.** `evidence.json`'s `eventId` field is the *old*
intent's key, so comparing those two fields proves nothing. I recomputed the generation the second
pass would derive (`evidence/generation-identity.mjs`, read-only, using the tip's own `evaluate` +
`eventIdentity`): `sameGeneration=false` in **both** legs — `computedGeneration` `76e2f8a8…` vs held
intent `bba49e8e…` (before), `1ba174b2…` vs `27383f4e…` (after). The pass computes a *different*
generation, so the settle cannot have come from the current-generation path: it came from the new
prior-generation loop. The second pass's own `subscription` is `null` (a refusal), which is why the
old id would otherwise never be looked at again.

The negative leg is in the in-tree regression: a prior intent with **no** durable effect is
reported (`pending_events>=1`, exit 4, `reason=prior_generation_pending`), never invented into
acknowledgement.

## 2. No double emission

`emitter calls=1` in the after leg, raw, above. Corroborated independently: `intent-race/emitter-calls.json`
= `1` in both legs, the `deliveries` table holds exactly **one** row in both legs, and the row's
`event_id` is the identity of the settled intent (`…ed9eacb61`), i.e. the already-durable effect was
*observed*. In the source, `acknowledged()` is read-only in both seams — `new
DatabaseSync(receiptDb,{readOnly:true})` with `SELECT`-only statements, or the
`job receipt … read_only=true` API — and the new loop calls only that function. There is no
emission path in it.

## 3. The new regression: real count, then falsified

`node scripts/test-delivery-intent-race.mjs` on the tip's archive: exit **0**,
`delivery intent race ok (14 checks, 0 skipped; isolated store, repository, database and emitter)`
(`evidence/test-intent-race.log`) — 14, counting the `check()` calls in the source.

Falsified three ways, each in a scratch copy where **only** `scripts/delivery-trigger.mjs` differs
(the test file is byte-identical to the tip in every variant). Each fails by a different name:

| variant | trigger sha256 | exit | failure by name |
| --- | --- | --- | --- |
| fix reverted to `b00f456` | `eba781d9…` | 1 | `unsettled prior-generation intent is settled from its durable effect or reported, never silently omitted` (line 87) |
| report-only (prior intents never settle) | `c6acc8b4…` | 1 | `the older generation is settled exactly once, from the effect it already has` (line 89) |
| settle without observing (invent acknowledgement) | `a16ea302…` | 1 | `a prior-generation intent with no durable effect is reported as an unsettled pending event` (line 103) |

So the regression is not a tautology: too little fix, a fix that only reports, and a fix that
fabricates a receipt each fail at a distinct assertion. Logs: `evidence/test-intent-race-*.log`.

Not wired into the gate: `grep test-delivery scripts/test.sh` matches only
`test-delivery-admission.mjs`, so `scripts/test.sh` does not run the new regression. The repair says
so itself; this is the review's still-open `boundary_gap`, not a new defect.

## 4. Where the fix is, and the shapes it does not cover

`scripts/delivery-trigger.mjs` gains one block after the per-record decision and before
`writeRecord`: for every other non-acknowledged intent in `record.outbox` (the current generation's
id is skipped) it observes that intent's exact effect via `acknowledged()` and settles it, or counts
it into `pending_events`, pushes `reason=prior_generation_pending` and exits 4 through the existing
`exit 4 if pending_events` rule.

It is **not** limited to the fixture's shape. It runs for every record whose decision is evaluated —
refused, admitted, or admitted-with-caveat, and irrespective of `--limit` — and it handles *any
number* of other intents and any prior `subscription.revision`. What it does not cover, demonstrated
with the tip's own modules (`evidence/probe-residue.mjs`, `evidence/residue.log`; each line ends with
the intent state read back from the store):

1. **`--limit` saturation hides a pending current-generation intent.** Precondition: an intent is
   pending for the generation the pass computes, and `--limit` was already consumed by earlier
   records. The emission branch is skipped (`eventAttempts < limit` false) and the new loop skips the
   intent as "current" — so nothing addresses it. Observed: exit **0**, `pending_events=0`,
   `prior_generations_settled=0`, `change/zzz` intent **pending**, no durable effect for it, and the
   only trace is a *wrong* stderr note: `change/zzz: admitted (event already emitted)`. Unlike the
   original finding this is a **deferral, not a permanent loss**: the id is unchanged, so a later
   unsaturated pass looks at it again. It is outside the finding's literal scope (which is
   prior-generation intents and the current refusal) but inside its stated principle.
2. **Records skipped before the loop** are never reconciled and never reported. Demonstrated for
   `already_landed` (a landed record holding a pending intent: exit 0, `pending_events=0`, intent
   still pending) and for the `--repo` filter (`other_repository`, same result). By the same
   `continue`s, `unreadable` and `repository_unreadable` records are identical — read from source,
   not run.
3. **`--no-emit`**: exit 0, `pending_events=0`, prior intent still pending. The repair documents this
   as deliberate (a rehearsal emits nothing and claims nothing about the queue), and `emit:false` is
   in the output, so a consumer can tell — but the reported `pending_events` is still 0 over a
   durable pending intent.

A record that is `refused` is covered: the held intent's id differs from the refusal generation's
(verified in §1), so the loop reaches it. A pending intent for the *current* admitted generation is
handled by the existing current-generation path, except under (1).

## 5. Credited behaviour did not regress (spot-check)

The repair touches four files: `scripts/delivery-trigger.mjs`, `scripts/test-delivery-intent-race.mjs`,
`scripts/delivery-admission.md`, `docs/reviews/codex-delivery-state-repair.md`. Nothing else —
`scripts/lib/delivery-store.mjs`, `scripts/lib/delivery-outbox.mjs` and
`scripts/delivery-admission.mjs` are byte-identical to the reviewed tip, so the credited code paths
are unchanged, and their suites still pass on this tree:

| suite | result |
| --- | --- |
| `node scripts/test-delivery-admission.mjs` | exit 0, `delivery admission ok (58 checks)` |
| `node scripts/test-delivery-store.mjs` | exit 0, `delivery store ok (9 checks, 0 skipped; private store, real concurrent writers)` |
| `node scripts/test-delivery-outbox.mjs` | exit 0, `delivery outbox ok (8 checks, 0 skipped; isolated store and emitter)` |

- **Real concurrent stale writers, one named CAS refusal**: the store suite still asserts "real
  simultaneous writers settle exactly one stale update" and "the losing process receives a named
  refusal" (`delivery_record_conflict`), plus stale-merge preservation, migration through the observed
  snapshot, and "publication cannot be silently erased".
- **Strict single-`session=` footer (58-check suite)**: the admission run retains the checks that
  refuse `nosession`, legacy/substring/ambiguous/body-spoof provenance while keeping authentic
  Codex/Pi/Claude provenance.
- **Read-only receipt connection**: `scripts/lib/delivery-outbox.mjs:31` is still
  `new DatabaseSync(receiptDb,{readOnly:true})` with `SELECT`-only statements and no `jobs.db`
  creation or migration.
- The OS-lock owner crash recovery and the 29-snapshots-during-24-updates observations were the
  review's *own* probes, not in-tree tests; I spot-checked their subject the honest way — the locking
  module they exercised is byte-identical to the reviewed tree and its suite still passes — and did
  not re-derive them.

## What I could not verify

- **`unverifiable_claim` is still open**: full workflow/installation, live sentinel/node receipt
  wiring, native Linux/macOS coverage, publisher/merged-tree smoke. I did not attempt any of them.
  Everything here ran on Windows with private scratch stores and a mock sentinel through the legacy
  read-only `--receipt-db` seam — the same seam the review used. The prior-generation loop's
  `acknowledged()` call over the real `job receipt` API is exercised only by code reading (it is the
  same function the credited current-generation path uses).
- **No gate verdict**: I did not run `scripts/test.sh` and took no gate slot, as instructed. The
  gate on the merged tree remains the landing's business. `bash scripts/test.sh` does not run the new
  regression anyway (see §3).
- The Rust receipt test and the reviewer's own `store-receipt` probe were not re-run.
- The `--limit` residue (1) is demonstrated with two deliveries and `--limit 1`; I did not measure how
  often a real pass has more newly-admitted deliveries than the limit (default 8).

## Verdict

**Accept with named residue.** The finding is closed on its own terms: the older intent is now
settled from its exact durable effect on the repaired tip, the pass that used to exit 0 over a
pending intent no longer does so silently, and no second emission happens. The residue is named
above — `--limit` saturation, records skipped before the loop, `--no-emit` — together with the
still-open `unverifiable_claim` and the unwired regression. None of them reproduces the finding's
permanent-loss shape; (1) is a deferral and (2) needs a landing or a repository filter, so I do not
ask for a change to this repair, but a landing should carry the residue knowingly.

## Method

Private scratch root `C:/Users/Victor/AppData/Local/Temp/wa-verdict-43893c3`: `before/` and `after/`
(`git archive` of `b00f456` and of the tip + the review's unmodified probe), `tip-run/` (the tip for
the in-tree suites), `falsify-{revert,reportonly,invent}/`, `residue/`. Node v24.19.0, Git
2.55.0.windows.3, Git Bash at `C:\Program Files\Git\bin\bash.exe`. No live store, sentinel, model or
reservation was contacted. Review lane `child:dispatch:85261111-9aa8-4b22-9e46-e6082bc4949c`, branch
`change/wa-session-childdispatch85261111-9aa8-4b22-9e46-e6082bc4949c`. I did not edit the delivery,
merge, push `main`, force anything, or run the gate.

## Evidence in this directory

`leg-before.log`, `leg-after.log`, `leg-before-evidence.json`, `leg-after-evidence.json`,
`generation-identity.mjs`, `test-intent-race.log`, `test-intent-race-revert.log`,
`test-intent-race-reportonly.log`, `test-intent-race-invent.log`, `probe-residue.mjs`, `residue.log`,
`residue.json`, `test-delivery-admission.log`, `test-delivery-store.log`, `test-delivery-outbox.log`,
`hashes-and-environment.txt` (versions, tip/tree, file list, every SHA-256 above).
