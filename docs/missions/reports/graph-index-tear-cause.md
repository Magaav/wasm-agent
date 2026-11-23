# graph-index-tear-cause

**Verdict: the one line Fable asked for is not cosmetic. The "component says malformed, store says
`ok`" case happened for real at 23/11 03:44 local, three times in a row, and then the node copied a
store that `PRAGMA integrity_check` calls `ok` aside and rebuilt it (`907ce8b3` names it now). The
writer that leaves an index short was NOT reproduced: ten kills of a committing writer left ten stores
that pass `integrity_check`, and the tree has exactly one component invoker behind one cross-process
lock. What the re-measurement did find is a real defect of a different kind: two different roots write
ONE store file on this node, so a mission worktree's `wa` and `wa serve` each throw the other's index
away, which is why the indexer is writing at all hours - and one of those writes is what a kill, a
pause or a foreign reader then meets.**

## 1. Re-measured first, and what the brief had wrong

| the brief said | what the node shows at 23/11 04:53 local |
|---|---|
| "41 quarantine lines in about a day" | **38** lines matching `graph_db_quarantined` in the user journal over `--since '2026-11-21 00:00'`: the first at 21/11 07:58:49, the last at 23/11 01:56:19Z (22/11 22:56:19 local) - 39 h, not a day. Nothing was rotated: this journal reaches back to 16/11 03:38, so 41 is not reproducible with this filter. 37 of them carry `reason=graph_index_failed:_database_disk_image_is_malformed` (and the journal has exactly 37 lines containing `graph_index_failed`, i.e. no other failure line at all), one (22/11 12:03:40) carries `reason=database_disk_image_is_malformed`. `~/Work/missions/_orch/evidence/quarantines.txt` holds 22 of those lines and no repair line at all |
| "since graph-store-stops-corrupting landed, each event writes graph_db_repaired / graph_db_quarantined to the journal" | **the journal has zero `graph_db_repaired`, `graph_db_store_healthy`, `graph_db_repair_refused` and `graph_db_repair_unavailable` lines in the whole retained window.** The repairs happened; they are not in the journal (see §3: the process that did them writes to its own stderr) |
| "how many repairs a day" | at least three, all `complaints=0`, all at 23/11 03:44 local, in ONE process's stderr; the journal cannot answer this question at all |
| "some quarantined copies read integrity_check ok, while the component called the store malformed" | confirmed twice over: `~/.wasm-agent/graph.db.d/graph.db.malformed-20261123T064420Z` (182,968,320 B, 03:44) answers `ok` on `PRAGMA integrity_check(200)` with 133,959 nodes, 380,380 edges and 2,694 files; and the quarantine line for it, found in a mission log, carries `integrity=ok` |
| "the trigger was NOT reproduced" | still not reproduced, and §4 says what that rules out |

## 2. What the component's SQLite really is (measured, not read off a comment)

Three measurements, none of which needs the live store open for writing:

* **It can never be in WAL mode.** The bundled amalgamation (`libsqlite3-sys-0.30.1`, SQLite 3.46.0)
says so itself: `#if defined(__wasi__)` sets `SQLITE_WASI`, `SQLITE_OMIT_WAL 1 /* because it requires
shared memory APIs */`. And the files agree: the store header's read/write version bytes 18 and 19 read
`1 1` on both quarantined copies and on the live `graph.db` - rollback journal, page size 4096, never
WAL. `wa_sqlite::tune` asks for `journal_mode=WAL` in the guest and is silently answered "delete",
because `PRAGMA journal_mode=WAL` reports the mode it *has*, and an omitted WAL is not an error.
* **Its locks are lock FILES, not fcntl.** The same source, `#ifdef SQLITE_WASI`, defines
`SQLITE_DEFAULT_UNIX_VFS "unix-dotfile"` (SQLite's own comment beside it: `/* ^^^ should
SQLITE_DEFAULT_UNIX_VFS be "unix-none"? */`). Measured live at 04:52-04:53 on this node: while a
commit was in flight, `~/.wasm-agent/graph.db.d/` held `graph.db-journal` (31,272,000 B, still growing -
31,321,248 B 18 s later) and **`graph.db.lock` as a DIRECTORY**, beside the node's own `.graph.db.lock`.
That directory is what a `unix-dotfile` writer holds; `graph_db_stale_lock_removed` is the node cleaning
one a killed guest left behind.
* **So a native SQLite opener and the guest share no lock at all.** `sqlite3`, python's sqlite3, or any
native `rusqlite` connection takes POSIX `fcntl` locks; the guest takes a link-file. Neither sees the
other. Deletes journal mode means a commit is page overwrites in place, so a second writer with an
independent page cache can put an older index page over a newer table page - which is exactly the shape
of the class-B copy, "row N missing from index idx_edges_path" + "wrong # of entries in index
idx_edges_src" with every table intact.

## 3. The line Fable asked about, found in the wild

`~/Work/missions/secret-guard-scripts-root/err.log` (2,220 B, mtime 23/11 04:17:13 local), verbatim:

```
graph_db_repaired root=/home/victor/Work/missions/secret-guard-scripts-root file=graph.db complaints=0 next=reindex
graph_db_repaired root=/home/victor/Work/missions/secret-guard-scripts-root file=graph.db complaints=0 next=reindex
graph_db_repaired root=/home/victor/Work/missions/secret-guard-scripts-root file=graph.db complaints=0 next=reindex
graph_db_quarantined root=/home/victor/Work/missions/secret-guard-scripts-root moved=/home/victor/.wasm-agent/graph.db.d/graph.db.malformed-20261123T064420Z reason=graph_index_failed:_database_disk_image_is_malformed integrity=ok kept=2 next=rebuild free_bytes=190464454656 floor_bytes=5368709120
```

Four facts, none of them in the journal:

1. the "Healthy" case is real: `complaints=0` means `PRAGMA integrity_check` found **nothing** to repair,
   and the line still said `graph_db_repaired ... next=reindex`;
2. `REPAIR_LIMIT` (3) then ran out and the same store was quarantined with `integrity=ok` - a store that
   SQLite calls healthy was copied aside (182,968,320 B) and re-parsed from nothing;
3. the copy is `graph.db.malformed-20261123T064420Z`, which is the "healthy" copy the brief mentions, and
   the copy in `~/Work/missions/_orch/evidence/` (`...013620Z`) is a different, older one;
4. **the root that quarantined it is a mission worktree, and the store it moved is the node's default one**
   (`~/.wasm-agent/graph.db.d/graph.db`) - see §5.

## 4. Suspects, ruled in or out by measurement

* **One in-tree writer, one lock, checked at the call sites.** `wa_kernel_runtime::components::mcp` -
the only way a guest runs at all - has exactly ONE call site, `rust/wa-capabilities/src/graph.rs:858`,
inside `call()`, which takes the store's flock at `:798`. The other native openers all take it too:
`repair_indexes` `:1052`, `quarantine_database` `:1117`, `snapshot_store` `:1245` (and the pre-update
backup goes through `host.graph_snapshot`, `lua/core/backup.lua`, i.e. through `snapshot_store`). **Ruled
out: a second writer inside this tree.**
* **A killed writer splitting a table page from an index page.** Ten scratch nodes (own HOME and
WASM_AGENT_HOME, own tree of 600 Lua files, the node's pinned component copied in) were SIGKILLed at
3, 4, 5, 6, 7, 8, 9, 10, 11 and 12 s into their first index. Three died before the first write (no
store); seven left a 1,724,416 B store that answers `ok` on `integrity_check` **both** through a plain
read-only open and through `immutable=1`, with no journal and no `graph.db.lock` left. **Not
reproduced - and the window was missed rather than absent**: the whole index of that tree commits by
about 6 s, so a random kill lands beside a commit far more often than inside one.
* **Journal mode / synchronous.** Not a setting the node can fix: see §2, the guest is delete mode by
compilation, and `synchronous=FULL` in delete mode is what makes a kill leave a hot journal (class A,
fixed by `2a4b785e`).
* **A store shared by several roots.** Ruled IN, but as churn, not as damage: two roots indexed into one
explicit `db` in one scratch node went 4800/4200 nodes (root A), then 1600/1400 (root B), then
4800/4200 (root A again): revisions 1, 2, 3, `integrity_check: ok` at the end, every row replaced each
time. So a root switch costs a full re-parse of the tree and rewrites the whole store - it does not by
itself leave an index short.
* **A native opener beside the guest.** Ruled in as a *mechanism* (§2) and out as an *in-tree caller*
(§4 item 1). What is still missing is a foreign opener's identity: nothing in this tree opens the graph
store natively outside the four locked call sites, and `fuser` on the live store at 04:53 showed no
process holding it while the node was idle.

## 5. The real defect the re-measurement found: two roots, one store file

`rust/wa-host/src/main.rs:456-466`: the graph root is `WA_GRAPH_ROOT` or **the process's current
directory**, and the graph database is `WA_GRAPH_DB` or `<home>/.wasm-agent/graph.db` - the same file for
every process that does not override it. `rust/wa-capabilities/src/graph.rs:75-94` (`locations()`) puts a
root into `graph.roots/<sha256>/` only when it is NOT the configured root; when it is, it uses the one
configured store.

So on this node: `wa serve` (cwd `/home/victor/wasm-agent/checkout`) indexes the checkout into
`~/.wasm-agent/graph.db.d/graph.db`, and **every `wa` started in a mission worktree** (`wa chat --once`,
cwd `/home/victor/Work/missions/<mission>`) has that worktree as its own configured root and indexes it
into the SAME file. Both are serialised by the one flock, so this is not a tear - it is a fight:

* `verify_snapshot()` is false for whichever root did not write last, so every call re-parses a whole
tree (measured above: 600 files re-parsed on each switch);
* the indexer is therefore committing for hours on end, which is the exposure that a deploy, a pause or a
kill needs;
* and the store cannot even say whose it is: `graph_meta` holds `root = /graph/root` (the guest's mount
point, measured), not the real root.

That is the next item, and it is not for this branch to decide alone: keying the store by root always
changes where the node's own 245 MB store lives (a migration), while recording the real root in
`graph_meta` and refusing an incremental update of a store built for another root is local and
backwards-compatible. The second is what this report recommends.

## 6. What this branch changes

`907ce8b3` (`rust/wa-capabilities/src/graph.rs`, `rust/wa-capabilities/src/graph_tests.rs`):

* `Repair::Healthy` is now its own variant (it carried a `complaints: usize` that was always 0 and was
printed as if a repair had happened) and it prints its own line, `store_healthy_line()`, instead of
falling into the repair arm;
* nothing else in the policy moves: the store is kept byte for byte, no copy is taken, no `REINDEX` runs,
the component's answer is retried, and the bound is still `REPAIR_LIMIT` a streak before the verdict that
was always taken (a quarantine and a rebuild) - which §3 shows is the right open question, not something
this change should quietly alter;
* the test `a_component_verdict_of_malformed_over_a_healthy_store_is_its_own_event_and_not_a_repair`
reads the scheduler's own `state.reported` (not stderr), which is why it compiles against the base and
fails there on the assertion rather than on a missing symbol. Measured on a separate worktree of the base
`2104a4d8` with only this test file checked out on top:

```
thread 'graph::tests::a_component_verdict_of_malformed_over_a_healthy_store_is_its_own_event_and_not_a_repair' panicked at wa-capabilities/src/graph_tests.rs:966:5:
assertion `left == right` failed: the healthy case is its own line and says what happens next
  left: "graph_db_repaired root=/home/victor/.wasm-agent/tmp/wa-graph-locations-532274-1795420722124065559 file=graph.db complaints=0 next=reindex"
 right: "graph_db_store_healthy root=/home/victor/.wasm-agent/tmp/wa-graph-locations-532274-1795420722124065559 file=graph.db next=retry"
test result: FAILED. 0 passed; 1 failed
```
* Wired into `scripts/test.sh:336` by existing - the crate row `cargo test ... -p wa-capabilities
graph::tests`; all 34 rows in that filter pass on the branch.

## 7. Texts to approve

1. `graph_db_store_healthy root=<root> file=graph.db next=retry`
   (was: `graph_db_repaired root=<root> file=graph.db complaints=0 next=reindex`, which claimed a repair
   that never ran; the new line names the unexplained pair of verdicts and says what happens next.)
2. Unchanged but now reached with an honest name beside it: `graph_db_repaired root=<root> file=<file>
   complaints=<n> next=reindex` - `complaints` is now only ever the number of index complaints that were
   actually repaired, never 0.

## 8. What is still missing

* **The identity of a foreign native opener, if one exists.** Everything in this tree locks; the lock a
native opener takes is not the lock the guest takes (§2), so the pair is possible and unnamed. Killing
the ten-kill experiment's window-miss needs a fixture that kills *inside* a commit - `scripts/lib/
crash-store.sh` builds that state, but only for a caller that names the transaction.
* **The 03:44 store's state at the instant of the verdict.** The kept copy reads `ok`; there is no
journal beside it; so either the store was never damaged on disk (a read-side verdict) or the damage was
gone by the time it was copied. The next occurrence answers it: `graph_db_store_healthy` says the case
happened even when nothing was repaired, `graph_db_quarantined ... integrity=ok` says a healthy store was
moved, and `graph_db_repaired` after it now means a repair that really ran.
* **`graph_meta.root`.** It holds the guest's mount path, so no store can tell which root it belongs to -
the fact §5 needs before anything can refuse a foreign store.
* **Events outside the journal.** A test of the form `journalctl --user -g "graph_db_repaired|
graph_db_quarantined"` is empty on a day when the events happened in a process whose stderr went
elsewhere (measured: three repairs and one quarantine, all absent from the journal). `systemd-run`
launches of missions DO reach the journal, which is why 38 of them are there; a mission that redirects
its own stderr (as `secret-guard-scripts-root` does) is invisible to it.

## 9. Pre-existing failures

None: `cargo test --release --offline -p wa-capabilities graph::tests` is 34 passed, 0 failed on the
branch, and the only test this branch adds is the one in §6.

