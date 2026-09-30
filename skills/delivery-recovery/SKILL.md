---
name: delivery-recovery
description: >-
  Reconcile concurrent delivery-record updates or an admission event whose enqueue
  failed, returned queued zero, or was interrupted. Use before retrying notifications
  and when review, admission and landing records disagree.
---

Use source-owned scripts by absolute native paths. Every JSON record has a revision;
`writeRecord` compares the observed revision/snapshot under an OS-held SQLite writer
lock. A conflict is a refusal: reload, inspect both owners' fields and apply only the
intended change. Never overwrite a stale snapshot. Published landing SHAs are immutable.

The trigger persists an outbox intent and exact payload before emission. Its identity
binds delivery tip/tree, review, caveats and expected subscriber revision. A different
review or commit at the same tree is a different generation. Do not use tree alone or
truncate acknowledgement history while publication remains unsettled.

```
node <source>/scripts/delivery-trigger.mjs --store <own-store> --repo <repo> --subscriber delivery-lane
```

An enabled subscriber with the expected topic is required. `wa-sentinel job receipt`
reads the exact job revision, event ID and payload from a consistent read-only snapshot.
Only that durable enqueue effect acknowledges an intent. `queued:0`, emitter exit 0,
or receipt of a wake is not proof the model read it or that the delivery landed.
A pending event or record-write failure is reported with exit 4; admission refusal
alone is a settled answer. Read the event error and the expected binding separately.

After interruption, rerun the reconciler: it observes the exact existing effect before
retrying the queue's idempotent enqueue. Do not blindly repeat publication or another
external effect. `jobs.db` mutation remains entirely with `wa-jobs`.

For an older installed sentinel only, the explicit `--receipt-db <private-or-owned-path>`
seam observes the schema read-only and records `legacy_readonly_schema`. Missing columns
fail loudly. This is installation debt, removed when the receipt API lands through
the existing gate/sentinel deployment procedure. Never substitute a queue count.

Fixtures: `test-delivery-store.mjs` uses real competing processes;
`test-delivery-outbox.mjs` injects emitter failure, zero enqueue, interrupted local
acknowledgement and changed subscription revision in an isolated store. The focused
Rust `exact_event_receipt` test verifies missing/different/stale effects. These are
focused proofs; full merged-tree gating and platform coverage remain separate.
