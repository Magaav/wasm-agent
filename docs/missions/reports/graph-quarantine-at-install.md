# graph-quarantine-at-install

**Verdict: a graph store a killed writer left mid-commit was quarantined as malformed 19 times in 21 hours
on 22/11, and it was never damaged.** The commit's rollback journal was sitting beside it the whole
time; a read-only opener cannot roll a journal back, and the component's admission pre-flight is read-only,
so the guest answered `database disk image is malformed` for a store one rollback away from perfect. The
scheduler answers that verdict with a quarantine: the store is moved aside and the whole index rebuilt.

The fix (`2a4b785e`) resolves the journal under the store's lock, before the component is called, and takes
no copy. Everything below is measured on this node on 22-23/11; every claim names the file and line or the
command that produced it.

## 1. What was re-measured, and what the brief had wrong

| the brief said | what the node shows |
|---|---|
| evidence at `~/.wasm-agent/graph.db.malformed-20261122T144358Z` (153 MB) | **gone** - `quarantine_database` deletes every earlier `graph.db.malformed-*` of the same store before it renames a new one (`rust/wa-capabilities/src/graph.rs`, `quarantine_database`). The next quarantine destroyed it. The surviving evidence is `~/.wasm-agent/graph.db.d/graph.db.malformed-20261123T000626Z` (175,513,600 B) plus its `-journal` (161,603,672 B), copied unmodified to `scratch/malformed.db` (+`-journal`) before anything read it |
| `~/.wasm-agent/graph.db` | the store lives at `~/.wasm-agent/graph.db.d/graph.db`; `graph.db*` also matches the `.d` directory, which is how the 153 MB/150 MB pair was first read |
| one quarantine | **19 lines in the user journal** (`journalctl --user --since '2026-11-22 00:00' | rg -c graph_db_quarantined`), 22/11 00:59:33 local through 22:06:26 the next evening, every one of them `root=/home/victor/wasm-agent/checkout` and 18 of them carrying `reason=graph_index_failed:_database_disk_image_is_malformed next=rebuild`; plus the copy that survives, `20261123T000626Z`, whose own line is not in the journal, so at least 20. `20261122T144358Z` was quarantined at 11:43:59 local and destroyed by the next one at 11:45:10 |

## 2. The store was recoverable, not damaged - measured

On a copy of the surviving pair:

* **without** the journal: `PRAGMA integrity_check` reports dozens of b-tree faults (`Tree 9 page 8470
  cell 0: invalid page number 167772160`, `btreeInitPage() returns error code 11`, `2nd reference to page
  17995`, freelist size 1017 vs 45) - a database no run produced;
* **with** the journal, one read-write open (SQLite's own rollback): `integrity_check` = `ok`, and the
  store answers **101,422 nodes** with every table intact;
* the journal's own shape says the same thing: a commit's rollback journal, page size 4096, sector 512,
  record count 0x1b0 at offset 8, and a final record cut off mid-write - a writer killed between the
  journal sync and the last page write.

So the install did exactly what the brief suspected: it swapped the running node while its graph worker
was committing, and what the kill left was a rollback-pending store, not damage.

## 3. Why the node called it damage

`rust/components/graph/src/main.rs`, `admit()` reads the store through `Store::open_readonly` (the
committed revision, then `manifest_fingerprint`/`matches_manifest`, which scans `graph_sources`). A
read-only SQLite connection cannot roll a hot journal back, so on the torn pages it answers the message
`malformed()` classifies as corruption (`rust/wa-capabilities/src/graph.rs`, `fn malformed`). The
scheduler's `failed()` then quarantines: `quarantine_database` renames the database **and** `-wal` `-shm`
`-journal` aside, and the rebuild starts from nothing.

Reproduced before any change: the real component, given the surviving pair in a scratch store, answered

```
graph_index_failed: database disk image is malformed
```

and after **one native read-write open** (`sqlite3 graph.db 'PRAGMA integrity_check'`) the *same*
component indexed the *same* store successfully (`ok:true`, `committed_revision:3`). That is the whole bug:
the store was never damaged, only rollback-pending.

## 4. The change (`2a4b785e`)

`rust/wa-capabilities/src/graph.rs`:

* `hot_journal(dir, file)` - an allow-list of one cause: a **non-empty** `<db>-journal` beside the store. A
  store with no journal, a zero-length journal, or a directory carrying the name is untouched, so every
  verdict the scheduler made before this change still stands (a store damaged without a journal still
  quarantines);
* `roll_back_hot_journal(dir, file)` - one read-write open that cannot create the database plus one read of
  the schema, which is the step SQLite performs the rollback in. Nothing is copied and nothing is rebuilt;
* `call()` runs it **after** the store's cross-process lock and **before** the component request is built,
  and reports one line with the outcome it actually measured (`rolled_back` = SQLite spent the journal,
  `not_pending` = SQLite read the store and left the journal alone).

No assertion, limit or quarantine rule was removed; `quarantine_database` and `failed()` are unchanged.

## 5. Tests, and what they measure on the base

* `scripts/test-graph-crash-recovery.lua` (real path: the node binary, the real `graph` component, a
  scratch home). It indexes a 120-file tree, builds the crash state with `scripts/lib/crash-store.sh`, then
  requires: the same store answers, no `graph.db.malformed-*` appears, and the committed revision does not
  fall back (a rebuild starts at revision 1).
* `scripts/lib/crash-store.sh` (needs `sqlite3` on PATH - it refuses by name without it, never passes) builds the state a killed writer leaves and **verifies it with SQLite**: a
  transaction is journaled with a small page cache, the commit is caught by its own record count (0 while
  journaling, non-zero when the commit begins), the journal is copied and the writer killed; then the page
  the caller's read breaks on is chosen by SQLite and the pair is accepted only if the copy **without** the
  journal fails that read and the copy **with** it rolls back to the store's exact pre-crash answer. No
  verified fixture, no test - it refuses by name.
* Wired: rows are discovered by `scripts/lib/fast-rows.sh` (`wa_fast_row_candidates`, `scripts/test-*.lua`
  minus `scripts/fast-path.exclude`), so this row runs on every fast-path and gate run; the two Rust tests
  are in `rust/wa-capabilities/src/graph_tests.rs` and run under `cargo test -p wa-capabilities`.
* The component the row cannot run without is named in the row's own text (`WA_GRAPH_COMPONENT_WASM`), which
  is the runner's contract: `scripts/lib/fast-row-exec.sh` installs a component into a row's own home, and
  hands over the override, only for the components the row names. Without that line the first main-health
  run of this row failed with `component_not_installed:graph` (`31b55a46`) - a missing fixture, not a
  verdict. The row now refuses by name when the override is absent or names no file, and passes through the
  fast path's own row executor (`lua_run`) with the component built from this tree: measured 23/11, exit 0,
  `graph_db_journal_resolved ... outcome=rolled_back` and `revision 1 kept, 13 row(s) answered, no
  quarantine copy`.

**Discrimination, measured twice each on this node:**

```
base  (~/.local/bin/wa, 8862b600): exit 1 - "a store a killed writer left mid-commit was refused:
                                   database disk image is malformed"            (2 of 2 runs)
fixed (2a4b785e build):           exit 0 - "graph crash recovery ok: revision 1 kept, 13 row(s)
                                   answered, no quarantine copy"                (2 of 2 runs)
```

with the fixed binary logging `graph_db_journal_resolved ... journal_bytes=166408 outcome=rolled_back` and
leaving `graph.db` + `.graph.db.lock` in the store directory - no `.malformed-` copy.

## 6. Was the rebuilt index whole or partial?

Whole, and that is not the cost. The quarantined store rolled back to 128,314 nodes / 367,228 edges /
2,631 files at revision 2; the store the rebuild produced holds a complete generation of its own (119,164
nodes / 335,378 edges / 3,009 files, revision 11). What the quarantine cost was not a half-built index but
the previous generation and the whole re-parse, five times in five hours, each 337 MB copied aside.

## 7. Texts to approve (verbatim)

1. `graph_db_journal_resolved root=<root> file=graph.db journal_bytes=<n> outcome=rolled_back|not_pending`
2. `graph_db_journal_unresolved root=<root> file=graph.db journal_bytes=<n> error=<error>`
3. `crash-store: mid-commit store at <db> - page <p> of <pages> torn, journal record count 0x<n>, attempt <a>; without the journal the read fails: <sqlite error> | with it: <verdict> | '<query>' -> <answer>`
4. `crash-store: refused: <reason>` (and the per-attempt `crash-store: attempt <n>: <reason>`)
5. `graph crash recovery ok: revision <n> kept, <k> row(s) answered, no quarantine copy`
6. test failure text: `a store a killed writer left mid-commit was refused: <error>`
7. test failure text: `the crash state was quarantined, not rolled back: <listing>`

## 8. Not verified, and left open

* The 22/11 kill itself was not re-run (it is a live install on this node). The crash state was reproduced
  from the surviving artifact and from a rebuilt equivalent, not by reinstalling.
* Whether the *guest's* SQLite can roll the journal back itself is not needed by this fix and was not
  measured; the rollback is native, under the store's lock.
* The brief's suggested acceptance (`wa-sentinel request deploy` while a worker indexes) needs a live
  install; the equivalent path was measured instead (`scripts/test-graph-crash-recovery.lua` through the
  node binary and the real component).
* `graph.db.malformed-20261122T144358Z` no longer exists; `quarantine_database` deletes the previous copy.
  If the evidence file must survive the next quarantine, that deletion rule needs its own decision - it is
  not changed here.

## 9. The same crash happened again while this was being written (22/11 22:49 local, 23/11T0149Z)

A live install finished on this node at 22:47 local, and at 22:49 its graph store was already in the exact
state this report describes: `~/.wasm-agent/graph.db.d/` held `graph.db` (182,599,680 B) beside a hot
`graph.db-journal` (174,969,632 B), and the copy taken to `scratch/evidence2/` measures what the 22/11
quarantine measured:

* without the journal: `Freelist: size is 1017 but should be 115`, `Tree 4 page 25947 cell 303: Rowid
  238123 out of order`, `Tree 4 page 33166: btreeInitPage() returns error code 11`;
* with it, one read-write open: `integrity_check` = `ok`, then 133,090 nodes / 377,622 edges / 2,668 files
  at revision 3 - the whole index, intact.

The earlier evidence file `graph.db.malformed-20261123T000626Z` no longer exists: a later quarantine
destroyed it, by the same rule that destroyed the brief's `20261122T144358Z`. The node is still running the
old code (`2a4b785e` is local and unpushed), so the next graph call on that store will quarantine it too.

## 10. Pre-existing failures seen while testing

`cargo test -p wa-capabilities --lib` (with `HOME` the real home) fails two `operations::` tests by design -
they refuse to run outside a scratch home (`wa-capabilities/src/operations.rs`, "refusing to run: this test
starts real operations"); `scripts/test.sh` runs them with `HOME=$GATE_HOME`. `2a4b785e` touches neither.
