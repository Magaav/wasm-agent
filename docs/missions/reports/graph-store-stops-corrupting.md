# graph-store-stops-corrupting

**Verdict: the 20 quarantines in 21 hours were two different things, and neither was a damaged store.**
Class A - a killed writer's rollback journal beside a store whose admission pre-flight is read-only - is
already fixed on main (`2a4b785e`, before this branch) and the installed node used that fix at 22/11
22:57:35 (`graph_db_journal_resolved ... outcome=rolled_back`). Class B is what this branch answers: a
store whose **only** faults are index entries - measured on the copy quarantined at 22/11 22:56, 150
complaints and not one table, page or freelist fault - was copied aside (182,599,680 B) and the whole tree
re-parsed, when `REINDEX` takes the same store to `integrity_check: ok` in **0.746 s** with all 115,947
nodes, 337,621 edges and 2,605 files still there.

This branch: index-only damage is repaired in place instead of quarantined (`b764c597`), a quarantine keeps
the newest three copies (1 GB ceiling) instead of deleting every earlier one (`b764c597`), and its journal
line now names the integrity verdict (`b764c597`).

## 1. Re-measured first, and what the brief had wrong

| the brief said | what the node shows |
|---|---|
| "about 20 times in 21 hours" | **41 lines** in the user journal between 21/11 07:58:49 and 22/11 22:56:19 local (`journalctl --user -g graph_db_quarantined --since '3 days ago'`), every one `root=/home/victor/wasm-agent/checkout`, 40 of them `reason=graph_index_failed:_database_disk_image_is_malformed` and one (22/11 12:03:40) `reason=database_disk_image_is_malformed`; 15 of them on 22/11 alone |
| "a `graph.db.lock` DIRECTORY plus a `.graph.db.lock` file" | not reproducible at 00:22 local on 23/11: `~/.wasm-agent/graph.db.d/` holds `graph.db` (182,820,864 B), `.graph.db.lock` (0 B) and one `graph.db.malformed-20261123T015417Z`. The directory form is a *guest* leftover the node removes (`graph_db_stale_lock_removed file=graph.db` at 20:50:32, 20:53:30, 20:54:27, 22:06:25, 22:25:12, 22:57:35) and it is not there now |
| the evidence copy is `graph.db.malformed-20261123T013620Z` (180 MB) | it is there and `PRAGMA integrity_check` answers **`ok`** on it - it is not a damaged store at all, and its own quarantine line is not in the journal. The copy that carries the damage is `~/.wasm-agent/graph.db.d/graph.db.malformed-20261123T015417Z` (182,599,680 B, quarantined 22:56:19, **no journal moved with it**) |
| "the live store had a 69 MB `graph.db-journal`" | that is class A: a rollback journal, not a WAL. It confirms the guest runs SQLite in `delete` mode (a commit is a page overwrite before a journal delete), which is what makes a kill mid-commit tear pages |

Every quarantine was done by the node process itself (`omarchy wa[<pid>]`), never by a deploy script; the
pids are single node processes, and the same pid quarantined twice (22:06:26 and 22:25:13 by `wa[606883]`),
so no two-writer pair is needed to explain a repeat.

## 2. The cause, and the suspects ruled out with a reproduction

**Class B is index-only damage.** On a scratch copy of `graph.db.malformed-20261123T015417Z`
(`/tmp/gsx/q54.db`, never the evidence file):

```
PRAGMA integrity_check(100000)  -> 150 lines: 149 "row N missing from index ..." + 1 "wrong # of entries in index idx_edges_src"
PRAGMA integrity_check         -> 100 lines (SQLite's default cap truncates the list - why the code reads with a cap)
REINDEX;                        -> 0.746 s, then integrity_check: ok
nodes 115947 / edges 337621 / files 2605 - identical before and after the REINDEX
```

So the store SQLite was asked to throw away had every row it ever had; only the derived indexes disagreed
with their tables. A read through such an index does not fail - it answers `0` where the table holds
337,621 edges and `0` where it holds 200 rows (measured on the copy and on a 200-row reproduction) - and a
*write* through a stale index root is what makes the guest answer `database disk image is malformed`, which
is the verdict the scheduler quarantined on. That ordering is why the damage was discovered by an index
run, not by a query.

**Suspects, each ruled in or out by measurement, not by reading:**

* *two processes writing one store without a shared lock.* The lock that counts is `.graph.db.lock` - a
  dot-prefixed file flock'd by `lock_store`
  (`rust/wa-capabilities/src/graph.rs`) and taken by every opener in this tree: `call`,
  `quarantine_database`, `snapshot_store` and - this branch - `repair_indexes`. The *non*-dotted
  `graph.db.lock` is the guest's own and is removed as stale under that lock. So the store has one
  shared cross-process lock and the shared path (`root=/home/victor/wasm-agent/checkout` for every process
  on this node, store at `~/.wasm-agent/graph.db.d/graph.db`) is covered by it. **Ruled out as a lock bug**;
  the one hole the code names and this branch does not fix is a *foreign* native opener (a human or an agent
  running `sqlite3` on the live store), which takes real SQLite locks the wasm guest does not honour.
* *a writer killed mid-transaction by a deploy or a pause.* **Confirmed for class A** (the 174,969,632 B
  journal beside the 182,599,680 B store at 22:49), fixed by `2a4b785e` before this branch and measured
  working on this node at 22:57:35. **Confirmed for class B as the same trigger with the journal already
  gone**: the damage is exactly "the table pages of a revision got out, the index pages did not".
* *journal mode / synchronous.* The guest's SQLite runs `delete` mode (journal beside the store, no `-wal`
  ever measured); this branch does not change it, and cannot: the mode is chosen inside the guest.
* *the store on a path several worktrees share.* It is one store for every process on the node, by design,
  and the lock above is the answer. No worktree has its own store: `~/.wasm-agent/graph.db.d/` is the only
  one, and per-root stores go to `graph.db.roots/<sha>.db.d/` (none exist on this node).

## 3. What this branch changes (`b764c597`)

`rust/wa-capabilities/src/graph.rs`:

* **`repair_indexes` / `repair_under_lock` / `index_only`** - before a quarantine, and only where a
  quarantine would be, the store is read with `PRAGMA integrity_check(100000)` under its own lock. If
  **every** complaint is one of the two measured index shapes (an allow-list, not a block-list), the store
  is opened read-write (never create) and `REINDEX`'d, then checked again; only `ok` counts as repaired.
  Anything else - a table, page or freelist fault, an empty index name, a list SQLite truncated at the cap,
  or a store SQLite refuses to check at all - falls through to the quarantine exactly as before. The repair
  is bounded by `REPAIR_LIMIT` (3 per streak) so a store the component keeps calling malformed cannot be
  re-repaired forever.
* **`retain_quarantine`** - the newest `QUARANTINE_KEEP` (3) copies of one store are kept, grouped by
  stamp (a database and its `-journal`/`-wal`/`-shm` are one evidence set), totalling at most
  `QUARANTINE_KEEP_BYTES` (1 GB); older groups are deleted, and only **this** store's own
  `<db>.malformed-*` names with one of the four suffixes. The newest group always survives, even alone, so
  a store bigger than the ceiling still leaves the copy that explains its quarantine.
* **`integrity_complaints` / `immutable_uri`** - the diagnosis open is `immutable=1`: a plain read-only
  open of a store with a `-wal` beside it **created a `-shm`** (measured: a test that expected two moved
  files moved three). A diagnosis must not leave anything behind.
* **`quarantine_line`** - the line carries the verdict and the retention count; `copy_verdict` now reads
  through the same function, so the snapshot path and the quarantine path cannot disagree about what
  "malformed" says.

## 4. Tests, where they are wired, and what they measure on the base

* `rust/wa-capabilities/src/graph_tests.rs` (`b764c597`): `index_only_is_an_allow_list_of_the_two_measured_shapes`
  (12 refusal cases), `the_newest_three_quarantine_copies_of_one_store_are_kept_and_the_older_ones_deleted`
  (four quarantines, byte-for-byte copies, another store's copies untouched),
  `the_quarantine_retention_is_a_group_rule_with_a_budget_and_a_newest_copy_that_always_survives`,
  `the_quarantine_line_names_the_integrity_error_the_reason_and_how_many_copies_survive`,
  `index_only_damage_is_repaired_in_place_and_no_copy_is_taken` (a real SQLite store, damaged by one index
  root page from the older revision: repaired, every row kept, no `.malformed-` copy) and
  `a_torn_table_page_is_never_repaired_and_a_refusal_writes_nothing` (the store is byte-identical after a
  refused repair). Wired through `cargo test -p wa-capabilities`, which `scripts/fast.sh` runs for the
  crates a change touches.
* `scripts/test-graph-quarantine-evidence.lua` (`419160fb`): a Lua row, discovered by
  `scripts/lib/fast-rows.sh` (`scripts/test-*.lua` minus `scripts/fast-path.exclude`, which does not list
  it), so it runs on every fast path and gate. It builds its own scratch home and refuses the live one by
  name through `scripts/lib/test-home-guard.lua`. It indexes a tree with the real component, tears a page,
  and lets the **scheduler** quarantine twice - asserting one copy after the first, **two** after the second,
  the older byte for byte, and that the node answers again. On the base the second quarantine deletes the
  first copy, so the row fails there.

Two assertions were **adapted, not loosened**: the pre-existing copies-per-store test asserted "exactly one
copy" - the rule this branch changes - and now asserts three, byte-for-byte content included.

## 5. What a quarantine costs the user today, measured

* The rename is cheap and stays: 182,599,680 B moved aside (same filesystem).
* **The rebuild is the cost.** The journal shows the same store quarantined 22/11 at 22:06:26 and again at
  22:25:13 (18 min 47 s later) and at 20:50:33 / 20:54:28 (3 min 55 s apart): whatever the rebuild produced
  was consumed within minutes - each cycle threw away a complete generation (115,947 nodes / 337,621 edges /
  2,605 files on the copy that survived) and re-parsed the tree in its place.
* Between the quarantine and the rebuild finishing the graph answers nothing (`graph_index_failed ...
  next=Use bounded read/grep now`), which is what the caller sees.
* The repair this branch adds costs **0.746 s** on the same 182,599,680 B store (measured), and keeps the
  generation instead of re-deriving it - a rebuild starts at revision 1.

## 5b. Texts to approve (verbatim, operator-facing)

1. `graph_db_quarantined root=<root> moved=<paths> reason=<error> integrity=<verdict> kept=<n> next=rebuild free_bytes=<n> floor_bytes=<n>`
   (changed: `integrity=` and `kept=` are new; `reason=`, `next=`, `free_bytes=` and `floor_bytes=` are unchanged)
2. `graph_db_repaired root=<root> file=graph.db complaints=<n> next=reindex` (new)
3. `graph_db_repair_refused root=<root> file=graph.db verdict=<verdict>` (new)
4. `graph_db_repair_unavailable root=<root> file=graph.db reason=<reason>` (new)
5. test text: `the newest three copies are kept, the oldest is deleted: <listing>` (new)
6. test text: `a repair is not a quarantine: <listing>` (new)
7. test text: `a refused repair leaves the store byte for byte as it was` (new)
8. test text: `graph quarantine evidence ok: <n> copies kept, the older one byte for byte, and the node answered again` (new)
9. test text: `refusing to run: <reason> - this row builds and quarantines a graph store` (new)

## 6. Not verified, and left open

* The row's own run on this node is reported below only if it finished; the `integrity=` field of the
  quarantine line is covered by a unit test on the formatting function and **not** captured from a live
  node's stderr (a Lua row cannot read its own node's stderr).
* Class B's *exact* trigger was not reproduced end to end: a stale index root that is one page deep answers
  stale values without an error, so the cross-process reproduction of "the guest answers malformed for
  index-only damage" was not built. What is reproduced is the repair itself, on a real SQLite store, and the
  measured evidence copy.
* `REINDEX` on a store whose index damage came with `SQLITE_CORRUPT` from a *torn page inside an index
  b-tree` is refused (measured: SQLite will not even run `integrity_check` there), so that class still
  quarantines.
* No release, no fleet update, no install: this branch is local, `~/.local/bin` and `installed.txt` are
  untouched, and the live store was only ever copied out and read.
