# graph-one-store-per-root

**Verdict. Item 0 is answered and fixed: what starts the indexer is the WRITE, not the reader.**
`write`, `edit` and every `host.write_file` called `host.graph_notify`, which created a scheduler entry,
registered a recursive OS watch on the root and queued a full index - in every process, with no `graph`
call anywhere. Indexing is now on demand: nothing is parsed and nothing is written until a graph call
asks. Every root now has its own store, keyed by the real root, claimed once, refused **by name** when a
store belongs to another root, and bounded at 8 stores / 2 GiB. A store that `PRAGMA integrity_check`
calls ok is never quarantined. `graph_db_*` lines now reach one file under the node's home for every
process, so they can be counted.

**Item 6 (the fair comparison table) is NOT done** - see §7. The decision it was meant to answer is
still open, and I do not pretend otherwise.

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

**Verified by running it:** the 41 unit tests above; the build of `wa-host` and of the `graph` component
from this branch; the live store's metadata read-only; the journal counts; the file:line citations
against base `41d6420c`.

**Not verified, and said so:**
* The brief's acceptance test - "a serve + three workers running for ten minutes with no graph call leave
  the store's mtime untouched" - **was not run as a ten-minute multi-process soak.** What is verified is
  the mechanism that makes it true (no code path reaches `scheduler()` from a write, and the new test
  holds a store's mtime) and that a `wa` process performing writes and edits creates no store
  (the `test-graph-automatic` row).
* **Item 5's cross-process form was not run.** The resolution rule (a store keyed by the real root) is a
  pure function of the root and is tested in-process; the end-to-end row above runs one process that
  writes and asks. What was NOT run is the brief's literal test - a `serve` plus three workers, in three
  processes with three cwds, alternating for ten minutes. A child `wa` process started by a Lua row needs
  the built binary passed in by the row, which this session did not wire.
* **Item 6, the fair comparison table, is not done** (see §7).
* Nothing ran against a live peer, and no key, pin or installed file was touched.

## 7. Deliberately not done / what is still open

* **Item 6 (the decision number).** The table needs ten real impact questions answered twice - by the
  `graph` tool and by grep+read - over an indexed copy of this repo, in a scratch HOME. That is hours of
  indexing plus ten paired investigations, and this session did not have them. The decision (does the
  graph earn a line in the routing text, or move out of the default bundle) is therefore **still open**,
  and the honest state is: dormant, no longer expensive, not yet justified.
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
