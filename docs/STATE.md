# Component state — versions, migrations, snapshots

Every component owns one kv namespace (`wa:kernel/kv`, `storage` grant). This document is the rule
book for changing what lives in it. The implementation is `rust/wa-state` (pure library: no
wasmtime, no clock, no filesystem) plus the host half in `rust/wa-host/src/state_host.rs` and the
shared kv adapter in `rust/wa-kv`: the transactional install, the snapshot admin tool (`host.state`),
and one `Store` over the kernel's per-component SQLite kv that this crate, the queue and the bus all
run on. The install sequence is at the end, with what is built and what is still a policy knob. See [KERNEL.md](KERNEL.md) for the component model and
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md) for how a service's state directory is chosen today.

## One namespace, one owner, one version

A namespace is `<components>/<name>.state/` and its kv (`kv.sqlite` today). Three facts are stored
inside it, under keys a component can neither read nor write (`__wa/` is host-owned):

| key | holds | why |
| --- | --- | --- |
| `__wa/meta/schema` | schema version, a monotone integer `vN` | which migration steps have been applied |
| `__wa/meta/component` | component id (`wa-whatsapp`, `agent-core`) | a namespace belongs to one component; a different id is refused, never adopted |
| `__wa/meta/last-migrated-by` | sha256 of the component that last moved the data | "which build wrote this?" is answerable from the state alone |
| `__wa/meta/component-version` | semver of the build that last opened it | pairs with the pin; both are semver'd with the artifact |
| `__wa/meta/created-at`, `…/last-migrated-at`, `…/updated-at` | unix milliseconds | ordering and operator questions |
| `__wa/meta/migration/journal`, `…/pending` | the unfinished step and the writes it still owes | crash recovery, see below |

The component sees its own keys through a view that hides these and **refuses** writes to them
(`wa-state::UserView`). That is deliberate: a component that could write `__wa/meta/schema` could
skip a migration, and a component that could write the journal could make the next upgrade replay
someone else's writes. The host broker must enforce the same refusal for `wa:kernel/kv` (today the
library enforces it; the WIT host does not yet).

## Schema version and component version are different numbers

- The **component version** is semver and moves for any change.
- The **schema version** is `v1, v2, v3, …` and moves only when the *shape* of the namespace
  changes — a key prefix, an encoding, a value that must be rewritten.

Rules:

1. A component declares the schema version it writes natively (`SCHEMA`). A fresh namespace starts
   there, not at v1.
2. Raise `SCHEMA` in the same release that ships the migration for it. One release, one step.
3. **A shipped step is never edited.** Later work adds `vN+1 → vN+2`; the old step stays byte for
   byte. A node that has been offline for three releases replays exactly the path a node that
   upgraded three times did.
4. Never reuse a schema number, and never skip one: the registry refuses a fork (two steps from the
   same version) and the migrator refuses a gap (no step from vN) instead of guessing.
5. A schema bump with no data change is still a step (an empty one); the version is the record that
   the component can run on that data.

## Where migrations live

Two shapes, one registry type (`wa-state::Registry`):

- **Inside the component** (default). The component builds its `Registry` at start and calls
  `Migrator::migrate` before it serves. The steps travel with the artifact, so the component's pin
  (sha256) covers the code that moves the data — the same approval that installs the component
  approves its migration.
- **As a sidecar** when a step is too large or too slow to ship with the service (re-encoding
  media, rebuilding an index over hours). A sidecar is a separately pinned artifact that declares
  the same component id and a schema range `[from, to]`; it runs the same `Registry`/`Migrator`
  against the same namespace, and it must be installed and pinned like any component. The journal
  makes the two interchangeable: if a sidecar stops mid-step, a component that carries the same
  step (or a newer sidecar) finishes it.

The crate splits along that line: the migration core (`kv`, `Batch`, `meta`, `Migrator`) builds for
`wasm32-wasip2` with `default-features = false`, so it can run inside the component that owns the
data; the snapshot file format (`export`/`import`, zstd) is behind the default `snapshot` feature and
is host- or sidecar-side, because `zstd-sys` compiles C and a wasm guest has no C toolchain.
*(Measured: `cargo check -p wa-state --target wasm32-wasip2 --no-default-features` passes; with the
default feature it stops at `zstd-sys` wanting clang.)*

A step is a pure function over a batch of the component's keys (`&mut Batch`), never over the store
directly, and it must be **deterministic**: no clock, no randomness, no network. Replay reads the
journaled values, but a crash *before* the journal is written means the step is recomputed from the
previous version � a step that ran at a different time must not produce a different shape. It computes the whole next batch in memory; the engine diffs old and new, journals the
full values it is about to write, then applies them. That is what makes replay exact even for a step
that is not idempotent (append to a value, increment a counter):

```rust
let registry = Registry::new(vec![
    Step::new(2, "messages/prefix", |batch: &mut Batch| {
        batch.rename_prefix(b"m/", b"msg/")?;      // v2 -> v3
        Ok(())
    }),
    Step::new(3, "values/v4", |batch: &mut Batch| { /* … */ Ok(()) }),  // v3 -> v4
])?;
let meta = wa_state::meta::open(&mut kv, &ComponentInfo::new("wa-whatsapp", "1.5.0", &pin)?, 3, now)?;
wa_state::Migrator::new(&mut kv, &registry, &info)
    .migrate(4, now, &mut snapshot_sink)?;         // takes a snapshot first, always
```

## Crash, resume, and why the journal exists

The migrator writes in this order; every arrow is one kv put:

1. take the snapshot (read-only),
2. compute the step's next batch in memory,
3. `pending` = the full put/delete list,
4. `journal` = which step, how many changes applied (`applied: 0`),
5. apply the changes, checkpointing `applied` every 32 writes,
6. move `schema` (one atomic put — the commit point),
7. clear `journal` and `pending`.

A crash before 4 applied nothing and leaves no journal; a stray `pending` is dropped. A crash during
5 replays the tail of the list (puts carry full values, deletes are idempotent, so re-applying is
safe) and never re-runs the step function from a half-migrated batch. A crash between 6 and 7 leaves
a journal whose step already committed; resume only clears it. **A crash between 5 and 6 is the one
that matters**: the next start finishes the step, not restarts it.

The journal is in meta keys, so it survives exactly as well as the data does. `wa-state::journal`
reads it without touching it; a `state status` should print it (step, `applied`/`total`, `attempts`)
rather than hide it. If the journal names a step the installed registry no longer carries, the run is
refused: the only safe move is the pre-migration snapshot, not a guess. The same applies when
finishing the journaled step lands the data *above* the version an older build asked for: that is a
downgrade, and it is refused like any other.

## Snapshots: backup and node moves

`export` streams the namespace to a file: magic `WASTATE1`, a zstd frame whose payload is
`header JSON | entries | footer{entries, bytes, sha256}`. The checksum covers the **uncompressed**
payload, so a broken zstd frame and a frame that decompresses to the wrong bytes fail the same check.
The header carries the schema version, the component id, its semver and the pin that last wrote the
data; reserved meta keys never travel, and import re-derives them from the header. A snapshot
therefore cannot be used to forge a schema version or a journal.

Rules:

- **Backup before every upgrade** (the migrator does it itself; the host also keeps the file).
- **Move a node by exporting and importing, never by copying `kv.sqlite`.** A copied database brings
  a WAL and, worse, a journal from another machine; an import is verified, versioned and owned.
- Import refuses a non-empty namespace unless `replace` is explicit, and refuses a header whose
  version/component/pin does not match what the caller requires. The caller must pass all three:
  the target node knows which component and which schema it is installing.
- A node move is `export` on the source, `import` on the target at the snapshot's version, then the
  ordinary `migrate` to the version the installed component writes. Do not import straight into a
  newer schema.
- Snapshots are bounded (`max_bytes`, default 512 MiB, and 16 MiB per value / 4 KiB per key as the
  host's kv already enforces). A namespace above the bound is refused, not truncated.
- Import is not atomic (the store has no multi-key transaction): a failure part-way leaves a partial
  namespace, the error is returned, and `replace` is the repair. The source snapshot is untouched.

## Downgrades

Refused by default. Allowed only when the caller says so **and** every step on the way down
registered a `down` function; one step without a reverse refuses the whole path. A component that
ships `down` steps does so for a bounded window (the release that introduced the bump and the one
after), and says so in its docs.

After that window the correct rollback is not a downgrade: it is stopping the new instance and
restoring the snapshot taken before the upgrade. That is also the only rollback that works when the
new version's writes cannot be represented in the old shape.

## Host integration: the transactional install

Built in `rust/wa-host/src/state_host.rs` (`prepare_install`, called by `services::start` before the
instance exists). The sequence below is what it runs; the notes after it say where the code differs
and what is still open.

The install/upgrade sequence the kernel must run (order matters; each line names what exists today
in `rust/wa-host`):

1. **Stage** the new `.wasm` + manifest beside the installed one; verify the pin
   (`components::load` already refuses an unpinned or mismatched component).
2. **Check the WIT versions** the new component imports are served. Refuse otherwise; nothing has
   been started.
3. **Snapshot** the namespace (`wa_state::export` to `<name>.state.snapshot-<timestamp>`,
   `SnapshotSink` from `migrate`).
4. **Migrate a copy**: copy `<name>.state/` to `<name>.state.next/`, import the snapshot or open the
   copy, and run `Migrator::migrate` to the installed schema. A failure here leaves the running
   instance and its state untouched; the copy and journal are evidence, not a rollback path.
5. **Start the new instance** against the migrated copy and wait for `lifecycle.report(ready)`
   (health `starting` → `ready`). A migration that "succeeded" but starts unhealthy is a failed
   install.
6. **Switch** only then: the new instance keeps the migrated copy; the old instance keeps its state
   directory and stays running until the new one has been healthy for the grace period.
7. **Retire** the old instance and its state directory, and keep the pre-upgrade snapshot under the
   node's retention policy.

If the host cannot afford a full copy (very large namespace), the fallback is: stop the old
instance, migrate in place with the journal, start the new one, and restore the snapshot if it does
not become ready. The journal makes that safe; the copy makes it cheap to abandon. Which of the two
a node uses is a policy knob (`state.mode = copy | in_place`), not a per-upgrade decision.

What is built, and how it differs from the sketch above:

- **The manifest declares the version**: `state_version` (and optional `state_component` for a state
  id that is not the installed name, `version` for the semver the meta records). No declaration means
  the host does not touch the namespace - migrations inside the artifact stay the default.
- **Copy mode only.** Step 3 exports a snapshot file (`<name>.state.snapshot-<unix-ms>`, the newest
  three kept); step 4 imports it into `<name>.state.next/` and runs the migrator there; the swap is
  a rename with the previous generation kept as `<name>.state.prev`. `in_place` is not implemented:
  the knob waits for a namespace large enough that copying it hurts.
- **The steps come from the host's registry** (the sidecar path, in-process):
  `state_host::register_steps(component, Registry)` plus the shipped table. A manifest that declares
  a version this host has no step for is refused (`state_migration_unavailable`) and a gap in the
  path is refused before the snapshot (`state_no_migration_path`) - the install then starts nothing
  and leaves the old state at its old version. The alternative (a component that migrates itself
  inside the guest) remains the wa-state default and is unaffected.
- **The admin tool** is the capability `host.state`: `status` (schema, component, versions, keys,
  journal, snapshot count, whether this host has steps for it), `dry-run`, `export`, `import`,
  `verify`. No key, no value and no payload is ever reported.
- **Still open:** step 2's WIT-version check is still the loader's compile step (a missing import
  fails at instantiation, after the migration); step 5's `lifecycle.report(ready)` wait is the
  supervisor's, not the install's, so an instance that migrates and then never becomes ready is
  caught by the supervisor's restart path rather than by refusing the install; and the `__wa/`
  refusal in the *WIT* kv host (the library's `UserView` refuses it; the WIT host does not yet
  filter the reserved prefix).

## Verifying a change

`cargo test -p wa-state` covers multi-step migrations, a crash at **every** write of a migration
(the fault-injecting `MemKv` fails the n-th mutating call and the run is repeated until it completes),
downgrade refusal with and without `down` steps, snapshot round trip, corrupted/truncated/tampered
snapshot rejection, and a dry run that is proven not to write. A component that adds a step adds a
test with the old and the new shape; a step without a test is an untested data path.
