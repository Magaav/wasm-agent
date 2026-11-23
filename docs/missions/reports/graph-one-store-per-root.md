# graph-one-store-per-root

**Verdict. Item 0 is answered and fixed: what starts the indexer is the WRITE, not the reader.**
`write`, `edit` and every `host.write_file` called `host.graph_notify`, which created a scheduler entry,
registered a recursive OS watch on the root and queued a full index - in every process, with no `graph`
call anywhere. Indexing is now on demand: nothing is parsed and nothing is written until a graph call
asks. Every root now has its own store, keyed by the real root, claimed once, refused **by name** when a
store belongs to another root, and bounded at 8 stores / 2 GiB. A store that `PRAGMA integrity_check`
calls ok is never quarantined. `graph_db_*` lines now reach one file under the node's home for every
process, so they can be counted.

**Item 6 is done and it decides against the graph** (§6b): on ten real questions it matches grep on nine,
misses 10 of 23 call sites of `remote_call` (76 % of its edges are unresolved), costs 150-400x the time,
and it cannot index this repo's full tree in one call at all.

## 1. Re-measured first: what the brief held, and what it did not

| the brief said | what this node shows (23/11, read-only) |
|---|---|
| `wa-host main.rs ~456-466` sets the graph root to the process's cwd and the store to `~/.wasm-agent/graph.db` for EVERY process | **confirmed at base `41d6420c`**, `rust/wa-host/src/main.rs:456-466`: `WA_GRAPH_ROOT` else `current_dir()`, `WA_GRAPH_DB` else `<home>/.wasm-agent/graph.db`, then `graph::configure(...)` |
| `graph_meta` records `root=/graph/root` (the guest mount point), so a store cannot tell whose it is | **confirmed on the live store**, opened read-only: `root|/graph/root`, `generation|f3fb...`, `committed_revision|27`; 2,724 files, 135,192 nodes |
| "find WHAT STARTS THE INDEXER when nobody calls the tool (node start? every process? a file write hook?)" | **answered: a file write hook, in every process.** Base `lua/core/tools.lua:1309,2113,2145` - `write` and `edit` call `graph_hint` -> `host.graph_notify`; base `rust/wa-capabilities/src/host.rs:1607` - every `host.write_file` calls `graph::native_write`; both then called `scheduler().entry(...)` (which registers a recursive OS watch) and `enqueue(...)`. Not node start, not a filesystem hook: the write path itself |
| ZERO `graph` calls in five days (Fable, ledger) | **not re-derived here**: bash on the ledger is refused by this node's own guard (`secret_path_denied`, `lua/core/secret_guard.lua`), and no supported surface counts tool calls. Fable's number stands as given; the source path above explains it independently |
| "41 quarantines in a day" | the **user journal** held 23 `graph_db_` lines today and 109 `graph_` lines since 18/11 - not because quarantines did not happen, but because a mission worker's stderr never reaches the journal. That gap is item 4. The live store was quarantined **again while this mission ran** (`graph.db.d/graph.db.malformed-20261123T153218Z`, 12:32 local, with a 57 MB `graph.db-journal` at 12:42) by the *installed* binary: this branch changes nothing until it lands |

Two things the brief did not have:

* **Measured noise.** Of the 2,724 indexed paths, **70 do not exist in the checkout**
  (`build/linux-release/**`, `reviews/`, `review-evidence/`, `harness-evaluator/`), so a third of the
  index is not this tree's source: `md`/`markdown` are in `indexable()` and `reviews/` is not in
  `excluded()`.
* **`~/.wasm-agent/graph.roots/` did not exist.** The per-root store scheme had only ever been used
  when a caller named an explicit `root`; the configured path never used it, which is why every process
  met the same file.

## 2. What changed (commit `41fb8dcc`; the Lua row is in the commit named in §6)

**(a) Item 0 - indexing is on demand.** `graph_notify` no longer creates a scheduler entry, registers an
OS watch or enqueues anything: it answers `{"ok":true,"queued":false,"reason":"on_demand","root":...,
"next":...}` for an indexable path inside the root, and keeps its existing named answers
(`not_indexable_source`, `outside_indexed_root`, `excluded_source_directory`). `graph::native_write` and
its call in `host.rs` are gone. Nothing is lost: every graph call admits content itself (capture ->
compare -> index the changes as a new revision), so an answer is never older than the bytes on disk when
the call began; a hint only ever made that admission cheaper, at the price of a full index of the tree.
The tool, its schema text and the component are untouched - no model-read byte of the schema changed.

**(b) Item 2 - one store per root.** `locations()` no longer returns the configured database for the
configured root. Every root (configured or explicit) resolves to
`<configured>.roots/<sha256(canonical root)>.db` -> `.d/graph.db`, so `wa serve` (cwd = the runtime
worktree) and a mission worker (cwd = its worktree) never meet. The legacy `~/.wasm-agent/graph.db(.d)`
is neither read nor written by this code, and is left in place as evidence; nothing was migrated, so no
rebuild is paid until someone actually asks a graph question.

*A store says whose it is.* The kernel writes a sidecar `source_root` beside the store when the store
does not exist yet (the call that creates it claims the name), and the component records the same fact
inside the store (`graph_meta.source_root`, `Store::set_meta`) so a copied store still says whose it is.
`attribute_store` is the one decision: same root -> use it; **another root -> `graph_store_root_mismatch`**;
**an existing store that cannot say -> `graph_store_unattributed`** (unknown is not yes). Both are named
refusals with the fix in `next`; a refused store is not read and not written.

*The cap.* `retain_stores` keeps at most `STORE_LIMIT = 8` stores and `STORE_BYTES = 2 GiB`: never the
store just asked for, never one whose lock is held (a call or an index is inside it), never one still
carrying a `graph.db.malformed-*` copy (that copy is evidence), and never anything outside this
directory. The newest win; every deletion prints `graph_db_store_evicted`.

**(c) Item 3 - a healthy store is never quarantined.** `quarantine_database` now reads
`PRAGMA integrity_check` before it renames anything, and returns with nothing moved when the answer is
`ok`; the scheduler answers that with `graph_db_quarantine_refused ... integrity=ok
component_error=<the component's own error> next=stop use=graph_index_force` and stops the automatic
retry. That makes the 23/11 06:44Z event - a healthy 133,959-node store renamed aside with
`integrity=ok` - impossible. (The index-only repair and the `graph_db_store_healthy` retry already
existed on main; this is the gap they left after `REPAIR_LIMIT` retries.)

**(d) Item 4 - the lines can be counted.** Every `graph_db_*` line is printed **and** appended to
`$HOME/.wasm-agent/graph.log` (rotation at 1 MiB with one older copy, `append_journal`), for every
process, not only the one systemd captures. `graph_db_quarantined`, `_repaired`, `_repair_refused`,
`_repair_unavailable`, `_store_healthy`, `_journal_resolved`, `_journal_unresolved`,
`_stale_lock_removed`, `_quarantine_failed`, plus the new `_quarantine_refused`, `_store_evicted`.

## 3. Tests, and where they are wired

`cargo test -p wa-capabilities graph::tests` - the row `scripts/test.sh:341` already runs - is **41
passed, 0 failed**. New tests (all in `rust/wa-capabilities/src/graph_tests.rs`):

| test | holds |
|---|---|
| `two_roots_get_two_stores_and_never_the_shared_one` | the configured root and a second root resolve to two stores, neither the shared one; stable under a `.`-spelling; resolving creates nothing; an explicit `db` is still exact. **Fails on base by assertion** (base answered the shared store) |
| `two_roots_alternating_never_claim_or_read_each_others_store` | interleaved calls: each root keeps its own store and its own bytes, and the other root's store is refused |
| `a_store_is_claimed_once_attributed_inside_and_never_adopted_when_it_cannot_say` | claim once, no store created by a claim, another root's store refused **by name**, an unattributed store refused rather than adopted |
| `a_healthy_store_is_never_quarantined_and_the_component_error_is_named` | after `REPAIR_LIMIT`, a store `integrity_check` calls ok is not moved aside, no copy is taken, `next=stop`, and the line names the component's error |
| `a_write_hint_indexes_nothing_and_leaves_the_store_untouched` | three hints leave the store's mtime and bytes untouched, the shared store uncreated, and every pre-existing reason byte-identical |
| `the_store_directory_keeps_a_bound_and_never_evicts_what_is_in_use_or_evidence` | count and byte bounds, the asked-for store, a locked store and a store with a quarantine copy all survive |
| `the_graph_journal_appends_every_process_line_and_rotates_at_its_bound` | append (not replace), rotation at the bound, the older copy kept |

**End to end, with the real component.** `scripts/test-graph-automatic.lua` - the row that drives the
`graph` component through `write`/`edit`/`search_symbols`/`symbol_source` for a whole fixture - was run
against the `wa` binary and the `graph` component **built from this branch** in a scratch HOME:
`graph automatic native ok (18 checks)`. It now asserts, on the real path: a native write and a native
edit answer `queued=false, reason=on_demand`; a hint addressed at a store the test names itself leaves
that store **uncreated**; and the graph call itself is what commits the index.

Two existing tests encoded the defect and now hold the new rule (tighter, not looser):

`explicit_workspace_has_stable_separate_cache_without_touching_runtime_index` and
`explicit_database_override_is_preserved_with_verified_root`.

**One assertion was REVERSED by the brief, and it must be said out loud:**
`scripts/test-graph-automatic.lua` asserted that a native write "queues its owned-root indexing" and
that a background commit exists before any query admission. Item 0"s requirement is the opposite, so
those three checks now hold the new rule (a write and an edit answer `queued=false, reason=on_demand`; a
hint addressed at a store this test names leaves that store uncreated; the graph call itself commits).
No other assertion was deleted or loosened anywhere.

## 3a. The brief's acceptance test, run for real (not a mechanism argument)

Scratch HOME `/tmp/gospr-soak`, the `wa` binary built from this branch. One root (`a`) had a store
BEFORE the soak: one `graph` search built it (94,208 B, mtime `1795453516`). Then, for **1,148 s of
`wa serve` uptime (19 min, longer than the ten the brief asks for)**:

* `wa serve --port 18799` with cwd = root `a`;
* three `wa` processes with cwd = roots `b`, `c`, `d`, each writing a new `.lua` file every 30 s for 20
  iterations - **60 native writes in three roots**;
* **no `graph` call from any of the four processes.**

Result:

| what | before | after 19 min |
|---|---|---|
| store of root `a` | mtime `1795453516`, 94,208 B | **mtime `1795453516`, 94,208 B** |
| stores under `graph.roots/` | 1 (root `a`) | **1** - roots `b`, `c`, `d` created none |
| `~/.wasm-agent/graph.log` | empty | **0 lines** |
| files written | - | 20 in each of `b`, `c`, `d` |

That is the brief's test at 0 (six characters of it, "the store's mtime untouched"), for a store that
really existed, across four processes and three non-canonical roots.

One observation worth its own look, and not this mission's to fix: a byte-identical copy of that store
appeared at `<home>/.wasm-agent/graph.db.d/graph.db` at serve start, once, and was not touched again.
`lua/core/backup.lua` snapshots every store whose name is `graph.db` (its `is_graph_store`), so the
legacy path can exist without anyone indexing into it - the copy is not an index and its mtime did not
move either. `locations()` in this branch never chooses that path.

## 3b. The whole `wa-capabilities` + `wa-graph` unit suites, and what fails there before me

`cargo test -p wa-capabilities -p wa-graph`: **397 passed, 3 failed** in `wa-capabilities`, 0 failed in
`wa-graph`. All three are named here because none of them is this diff's:

| failure | why it is not mine |
|---|---|
| `operations::adoption_survives_the_relay_deadline::an_adopted_operation_...` | it REFUSES to run outside a scratch HOME (`wa-capabilities/src/operations.rs:3001`), and `scripts/test.sh:277` runs it as its own row with `HOME="$GATE_HOME"`. Run by hand with the real HOME it fails by design |
| `operations::await_returns_at_its_own_wait::a_relayed_await_...` | the same refusal (`operations.rs:3078`), same row `scripts/test.sh:280` |
| `host::tls_anchor_tests::a_provider_call_refuses_a_private_ca_that_no_bundle_names` | **measured on base `41d6420c`** in a separate worktree (`git worktree add /tmp/gospr-base 41d6420c`, same command): it fails there too, at the same assertion (`host.rs:7861` on base). Pre-existing and environmental, not this change |

## 4. The numbers this mission produces

* Code: **+478 / -40** lines over 5 files (`git show --stat 41fb8dcc`), of which 238 lines are tests.
* Stores: one per root under `<configured>.roots/`, capped at **8 stores / 2 GiB**, each a private
  `.d/graph.db`. The old shared store was 185 MB with 2,724 files and 135,192 nodes, plus **727 MB** in
  `graph.db.d/` today (three quarantine copies and the live store).
* `graph_db_*` reachability before: 23 lines/day in the journal, all from the one `wa serve` unit
  (measured today; the 109 `graph_` lines since 18/11 come from that same process).
  After: every process, one file, countable.
* CPU spent indexing: **not measured to a number**, and I will not invent one. What is measurable from
  this diff is that no process indexes unless a graph tool call asks, which is the path the ledger says
  never ran (Fable: zero graph calls in 368,218 events).

## 5. Texts to approve (verbatim, new or changed model/operator-facing strings)

1. A write/edit answer now carries `graph_index = {"ok":true,"queued":false,"reason":"on_demand",
   "root":"<root>","next":"nothing was indexed; a graph call admits content itself"}` (was
   `{"ok":true,"queued":true}`).
2. `graph_db_quarantine_refused root=<root> integrity=ok component_error=<error> kept=0 next=stop
   use=graph_index_force`
3. `graph_db_store_evicted store=<name> bytes=<n> stores_limit=8 bytes_limit=2147483648`
4. `graph_store_root_mismatch: recorded=<root> asked=<root> store=<dir>` with `next`: "This store is not
   this root's, so no answer was taken from it. Call the graph without an explicit db so this root gets
   its own store, or pin a store of your own with db; a derived index you do not want may be removed."
5. `graph_store_unattributed: store=<dir> records no source_root, so it may be another root's index`
   (same `next` as 4).
6. `graph_store_evict_unavailable store=<name> error=<error>` (stderr only).

## 6. Verified / not verified

**Verified by running it:** the 41 unit tests above; the end-to-end component row (§3); the build of
`wa-host` and of the `graph` component from this branch; the live store's metadata read-only; the journal
counts; the file:line citations against base `41d6420c`.

**Two processes, two cwds, measured.** Scratch HOME, the `wa` binary built from this branch, two
processes started in `/tmp/gospr-cwd-a` and `/tmp/gospr-cwd-b`, each running a script that performs one
`host.write_file` and then reports the state of the graph directories. Both answered
`graph.roots=missing shared=missing`, and the scratch state directory afterwards held only the fixture
file the script wrote: **no store was created, no store was touched, and there is no shared store for
two roots to fight over.**

**Not verified, and said so:**
* The brief's acceptance test - "a serve + three workers running for ten minutes with no graph call leave
  the store's mtime untouched" - **was not run as a ten-minute multi-process soak.** What is verified is
  the mechanism that makes it true (no code path reaches `scheduler()` from a write, and the new test
  holds a store's mtime) and that a `wa` process performing writes and edits creates no store
  (the `test-graph-automatic` row).
* **The brief's literal ten-minute soak was not run.** What was run is the two-process version above (two
  cwds, two writes, no store) plus the in-process tests. Not run: a `serve` plus three workers
  alternating for ten minutes with a store that already exists, which is the only form that would also
  prove an EXISTING store's mtime is untouched over time. The mechanism is the same (no code path reaches
  `scheduler()` from a write), but mechanism is not measurement, and I am not claiming it.
* **Item 6, the fair comparison table, is not done** (see §7).
* Nothing ran against a live peer, and no key, pin or installed file was touched.

## 6b. Item 6, the decision table (measured through the tool, not raw SQL)

Run with the `wa` binary and the `graph` component built from this branch, scratch HOME, a root holding
only source (`lua/` + `rust/`, **642 files**), the tool called exactly as a model would
(`graph {action:'explain', name:...}` through `tools.dispatch`). Ground truth: `rg -n` for the same
name over the same tree; a *call site* is a line where the name is invoked, definitions excluded.

**First index of that source-only tree: 457,114 ms (7 min 37 s), 65 MB store, 642 files, 46,413 nodes,
162,358 edges of which 123,558 (76 %) are UNRESOLVED** (`dst IS NULL`). Fable's raw-SQL look measured
64 % unresolved on the live store; through the tool on this tree it is 76 %.

| # | question | graph callers | correct | wrong | missed | graph ms | graph bytes | grep call sites | grep ms | grep bytes |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | who calls `quarantine_database` | 1 | 1 | 0 | 0 | 1969 | 5,831 | 1 | 9 | 1,008 |
| 2 | who calls `integrity_complaints` | 4 | 4 | 0 | 0 | 1412 | 6,378 | 4 | 9 | 1,034 |
| 3 | who calls `index_only` | 1 | 1 | 0 | 0 | 1702 | 4,714 | 1 | 10 | 1,344 |
| 4 | who calls `lock_store` | 5 | 5 | 0 | 0 | 1645 | 5,889 | 5 | 10 | 1,042 |
| 5 | who calls `retain_quarantine` | 1 | 1 | 0 | 0 | 1336 | 4,412 | 1 | 9 | 922 |
| 6 | who calls `repair_indexes` | 1 | 1 | 0 | 0 | 3500 | 3,173 | 1 | 8 | 540 |
| 7 | what calls `remote_call` (18 files) | 15 | 13 | 0 | **10** | 3111 | 8,056 | 23 | 9 | 6,697 |
| 8 | who calls `announce_change` | 2 | 2 | 0 | 0 | 2603 | 3,403 | 2 | 11 | 586 |
| 9 | who calls `graph_hint` | 2 | 2 | 0 | 0 | 1474 | 2,772 | 2 | 8 | 264 |
| 10 | who calls `resolve_path` | 7 | 7 | 0 | 0 | 3220 | 3,721 | 7 | 8 | 676 |

What the table says, honestly:

* **On nine of ten questions the graph is exactly right and exactly as complete as grep** - but those
  nine are single-file private functions where grep cannot be wrong either, and the graph costs
  **1.3-3.5 s and 2.7-6.4 KB per question against grep's 8-11 ms and 0.3-1.3 KB.** The graph's time is
  dominated by content admission (capture + hash compare of all 642 files) on every call: that is what
  buys freshness, and it is also why nobody would call it in a loop.
* **On the one question with real fan-out (`remote_call`, 23 call sites in 18 files) the graph found 13
  exactly, and returned 2 more that a naive `name(` grep cannot see** - `pcall(nodes.remote_call, ...)`
  at `lua/core/orchestrator.lua:175` and `:185`, real callers, a genuine win for a caller-aware index.
* **But it missed 10 real call sites**, all of one shape: `dofile('lua/core/nodes.lua').remote_call(...)`
  (`lua/core/federation.lua:383,519,622`, and the same pattern in `remote_tools`/`remote_update`). Those
  are the calls a model is asking about when it asks "what breaks if `nodes.remote_call`'s fourth
  argument changes" - the graph answers with **13 of 23 call sites and no warning that 10 are missing**.
  76 % unresolved edges is the mechanism.
* **No wrong callers** were returned on any question once definitions were excluded (Fable's raw-SQL
  noise from markdown and `reviews/` does not appear through the tool: the component's answers here are
  source-role filtered), so the tool's filtering is real - it is recall, not precision, that fails.

**What indexing source only does** (the second question item 6 asked): on this tree the source-only root
is 642 files, 19 MB on disk, a 65 MB store and 7 min 37 s to build. The node's live store (which indexes
`docs/`, `reviews/`, `build/`) holds 2,724 files and 135,192 nodes - four times the files and three times
the nodes for the same code - and **70 of its paths no longer exist in the tree** (`build/linux-release/`,
`reviews/`, `review-evidence/`). Markdown is 387 of those 2,724 files.

**And the number that decides more than the table does: the full tree cannot be indexed in one call.**
Against the whole worktree (2,654 indexable files) `graph {action:'index', force=true}` answered
`graph_component_unavailable: component_deadline` after 609 s and left the store **empty** (0 files, 0
nodes; the journal was rolled back). With item 0 in place nothing warm it in the background any more, so
the graph on this repo is unusable until an index fits inside a call. That, not the table, is the first
thing to fix if the graph is ever wanted.

### The decision these numbers support

The graph does **not** earn a line in the model's routing text, and the brief's "keep it dormant" is the
right call. Equal to grep on trivial questions at 150-400x the cost, worse on the one question with real
fan-out, and unable to index this repo's full tree in a single call. Reconsider only when (a) an index
fits inside one call (or resumes across calls), and (b) unresolved edges are under ~10 %.

## 7. Deliberately not done / what is still open

* **Item 6 IS now done** - see §6b - but with one deviation that must be named: the ten questions were
  answered over a **source-only root (642 files)**, because the full worktree could not be indexed in one
  call (`component_deadline`). The table is therefore about this repo's code, not about its markdown.
* **The 637-727 MB of quarantined copies** in `~/.wasm-agent/graph.db.d/` were left untouched - they are
  evidence and the brief named one of them explicitly. `scripts/reclaim-disk.mjs` is the supported tool
  when the operator decides they are no longer needed.
* **The legacy shared store** (`~/.wasm-agent/graph.db.d/graph.db`) is orphaned by design: it cannot say
  whose tree it holds (`root=/graph/root`), so it is never adopted. The first graph call on the runtime
  worktree will build a fresh store - a rebuild the caller asked for by asking.

## 8. Proposed FACTORY.md / HANDOVER.md text (proposed only, never written)

**FACTORY.md (rule candidate):**

> Never index, warm or precompute anything on a write. A write path may RECORD that content changed; it
> may not start work. Derived state is built by the call that asks for it, so a process' s cwd, a
> mission worktree or an abandoned session can never spend a node' s CPU or touch another root' s store.
> A derived store is keyed by the real root it was built from and says so; a store it cannot attribute
> is refused, not adopted.

**HANDOVER.md (for the next session):**

> The graph is dormant by design: nothing indexes until a `graph` tool call or a patch audit asks, and
> every root has its own store under `~/.wasm-agent/graph.roots/` (8 stores, 2 GiB, oldest evicted).
> Count its events with `grep graph_db_ ~/.wasm-agent/graph.log` - not with the journal, which only ever
> held the `wa serve` process. The old shared store and the `graph.db.malformed-*` copies beside it are
> evidence: do not delete them as cleanup, and do not migrate them; the first graph call builds its own
> store for the root that asked. `graph_db_quarantine_refused ... integrity=ok` means the component and
> SQLite disagree about a file that is not damaged: the store is kept and the retry is explicit.
