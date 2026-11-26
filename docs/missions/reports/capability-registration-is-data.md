# capability-registration-is-data

**Verdict: item 2 is landed and items 1, 3, 4 and 5 are measured.** A capability's registration is now
data in its own area's file: `rust/wa-capabilities/src/capability_rows/` holds 20 files with all 152
rows, `build.rs` collects them, and `capabilities.rs` (576 -> 365 lines) declares none. Adding or moving
a capability edits its own row file and never `capabilities.rs`; of the last 30 days' commits on
`origin/main`, **50 of the 55 that edited `capabilities.rs` would no longer edit it**, and **21 would no
longer touch `capabilities.rs` or `host.rs` at all**. Nothing the model or the operator reads changed:
the digest, `wa capabilities --json`, the text form and `scripts/probe-prompt-bytes.lua` are
byte-identical, and the inventory row passes through the real QuickJS sandbox (152 entries, sha256
`a28fbb10...`) on both surfaces.

Branch `change/capability-registration-is-data`, base `522e12ae` (`origin/main`), worktree
`/home/victor/Work/missions/capability-registration-is-data/wt`. Nothing pushed, no release, no fleet
call, no install into `~/.local/bin`, no `git stash`, no background shell. Commits, all authored Victor
with the Agent and Co-Authored-By trailers:

| commit | what |
|--------|------|
| `4b9c327c` | the move: 152 rows into 20 files under `src/capability_rows/`, `build.rs` + `src/registry_scan.rs` collect them, `capabilities::registry()` replaces the `REGISTRY` const, two new test files |
| `873f2174` | the four doc places that said a row goes in `capabilities.rs` now say the row file (`docs/HOST.md` x4, `docs/FEATURES.md`, `docs/CODEMODE-VIEW.md`, `docs/KERNEL.md`) |
| `5965b46f` | the row judges the registry through `inventory()`, so it fails on the base by assertion instead of by a missing symbol |
| this commit | the two new rows wired into `scripts/test.sh`, and this report |

## Item 1 - what a capability's registration IS today, measured

**Three sites, not five.** `host.*` registration is already one table, so the brief's "dispatch arm" and
"Lua binding" and "catalogue" are not separate places a new function had to be added to:

| site | where | what a new capability added |
|------|-------|------------------------------|
| the handler | `rust/wa-capabilities/src/host.rs` (8,217 lines) or its own module | the function itself |
| the row | `rust/wa-capabilities/src/capabilities.rs:108` `pub const REGISTRY: &[Capability] = &[...]` | one `plain!`/`upvalue!` line: name, effect class, one-line description, handler, and the bind kind (`Bind::Plain` = `lua.register`, `Bind::Upvalue` = `lua.register_with_upvalue`) |
| the doc row | `docs/HOST.md:807-962`, between the `capability-inventory` markers | one `name<padding>effect` line; the drift test fails without it |

There is no dispatch: `capabilities::register` (`capabilities.rs:400-408`) walks `REGISTRY` and hands each
`HostFn` to `lua.register`, so the C function pointer IS the dispatch. `core_component.rs:839,867` reads
the same list only to answer `unknown_capability:<name>`; `lua/core/capability_inventory.lua` is a door
onto `host.capability_inventory`, not a second copy (its own header says so). A new capability also
touched the test fake `scripts/lib/contract-host.lua` (and `scripts/test-contract-host.lua`, which judges
the fake against the real host) - that is a fixture, not registration.

A real recent example, `7c450e59` (`rename_file`, `remove_file`): `host.rs` +80, `capabilities.rs` +2,
`docs/HOST.md` +11, `scripts/lib/contract-host.lua` +30. `6bedf472` (`append_file`) is the same shape
(+71/+1/+15) and its `docs/HOST.md` row arrived in a later commit, which is how the drift test can be red
for a while without anyone noticing (see the pre-existing failure below).

**Brief facts re-measured** (the brief asked for this): `host.rs` 8,217 lines and `capabilities.rs` 576
lines are right; 246 `wa-capabilities` commits in 30 days and "133 of 246" are right; **110** commits
touched `host.rs` (the brief said 86) and **55** touched `capabilities.rs` (the brief said 47).

## Item 2 - what it is now

* `rust/wa-capabilities/src/capability_rows/` - one file per area: `storage, paths, files, graph,
  operations, codemode, identity, http, plugins, kernel, mesh, whatsapp, email, governance, stt, fabric,
  audio, client, console, inventory` (152 rows). Each file is `pub const ROWS: &[Capability]` and carries
  the rows of the modules that implement its handlers, with the comments that explained them.
* `rust/wa-capabilities/src/registry_scan.rs` - the scan: `row_files` (missing or empty directory is a
  build error, never an empty registry), `module_name`, `generate` (one `#[path] mod` per file plus the
  `SECTIONS` list; a file with no `pub const ROWS` is refused by name).
* `rust/wa-capabilities/build.rs` - `generate_capability_rows` runs that scan and writes the aggregate
  `capabilities.rs` includes; `cargo:rerun-if-changed` on the directory, so a file added or removed
  reruns the script, and the compiler tracks each file's content through the generated `mod`.
* `capabilities.rs` - keeps `Effect`, `Bind`, `Capability`, the two row macros (now `$crate`-qualified, so
  a row file imports the macro and nothing else), `registry()`, `inventory()`, `inventory_json()`,
  `digest()`, `health()`, `register()`, `capability_inventory` and the drift test. Its own module doc says
  where a row goes.

Adding a capability is now: one row in its area's file (or a brand-new file in that directory, which needs
no edit anywhere), and one `docs/HOST.md` row. Moving a capability to another crate or component takes its
row file with it.

## Item 3 - identical behaviour, measured

Same binary flags on both sides (`cargo build --release -p wa-host`, `WA_CODEMODE_ALLOW_EMPTY=1`, one
scratch `WASM_AGENT_HOME`, `WASM_AGENT_LUA_ROOT` = this tree):

| surface | before | after |
|---------|--------|-------|
| `wa --capability-digest` | `a28fbb10ebcbb51c326c94966349d92faf80543b08921be48fd370f508ab729f` | identical |
| `wa capabilities --json` (22,825 B) | sha256 `cee0c602...` | identical, `cmp` clean |
| `wa capabilities` (text) | sha256 `eb19d2a1...` | identical, `cmp` clean |
| `scripts/probe-prompt-bytes.lua` | sha256 `9906aef9...` (`prompt_bytes` 30197, `system_bytes` 21357, `envelope_bytes` 8840, `catalogue` 73/23) | identical, `cmp` clean |

The model's tool catalogue lives in `lua/core/tools.lua` and no Lua file is in this diff at all, so it
cannot have moved; the probe above is the measurement that says so.

The inventory row, on the asset-carrying binary (assets verified against the pins in
`scripts/codemode-build.mjs`: `quickjs.wasm` `d4c9375f...`, `prelude.js` `57c8dc8c...`):
`node scripts/test-capability-inventory.mjs` answers `{"ok":true}` - CLI 152 entries and the real QuickJS
sandbox 152 entries, both `a28fbb10...`, 476 sandbox checks, 0 paid calls.

`cargo test -p wa-capabilities` with a scratch `HOME` (as `scripts/test.sh` runs it): **411 passed, 1
failed**, and the one failure is pre-existing (see below). Four rows that refuse to run outside a scratch
`HOME` passed on the re-run; the first run's five failures were those four plus the pre-existing one.

Build, before/after of `cargo build --release -p wa-host`, both into a fresh target directory:

| | wall time | binary |
|---|-----------|--------|
| before (`522e12ae`) | 294,846 ms | 78,372,568 B |
| after | 258,315 ms | 78,370,416 B |

The binary is 2,152 B smaller. The 36 s difference in wall time is one run each on a shared machine and is
NOT claimed as an effect of this change: what the change does to a build is one more build-script step
(the scan of 20 files, milliseconds) and no extra compilation unit. For scale, an incremental rebuild of
`wa-host` after touching a row file is 24,635 ms in the mission target dir.

## Item 4 - a row in its own file shows up in the inventory

Measured, not asserted: `src/capability_rows/zz_probe.rs` was added ALONE - `git status` showed no other
change - the tree was rebuilt, and `wa capabilities` answered `(153 capabilities; sha256 404de498...)`
with `"name":"capability_registration_probe"` in the JSON. The file was then deleted, the tree rebuilt,
and the answer was `(152 capabilities; sha256 a28fbb10...)` again - the baseline digest. `host.rs` and
`capabilities.rs` were not edited to make that happen.

Two landed rows keep it that way, both wired into `scripts/test.sh` beside the existing
`capabilities::tests` gate (and into `scripts/fast.sh`'s full-crate run for free, since that row runs
`cargo test -p wa-capabilities` unfiltered):

* `tests/capability_registration.rs` - `capabilities.rs` declares no row; every row file declares at
  least one; the declared (name, effect) set and `capabilities::inventory()` are equal in BOTH
  directions. It reads the sources with its own parser, not the build script's, so two independent
  readers have to agree. **It fails on the code before this change**, by name:
  `capabilities.rs declares 152 capability row(s) itself (sql_exec, sql_query, sql_rows, script_run,
  sql_patience...)`.
* `tests/capability_row_discovery.rs` - runs `registry_scan::generate` on a directory it makes itself:
  two files added on their own are collected as modules with their `ROWS`, a directory with no row files
  is refused (`holds no row files`), a file with no `ROWS` is refused by name, and the aggregate over
  the REAL directory collects exactly one block per row file.

Base evidence (a worktree of `522e12ae` with only these two test files laid over it):
`capability_registration.rs` FAILED with the assertion above; `capability_row_discovery.rs` failed to
compile (`E0433: cannot find registry_scan in wa_capabilities`), which is the class this repo calls
`new-symbol` - it proves nothing and is named, not hidden.

## Item 5 - how many commits stop touching the shared files

Last 30 days of `origin/main`, commit by commit (`git log --since=30.days`, and for each commit that
touched `capabilities.rs`, its diff there classified as row lines versus anything else):

| | count |
|---|---|
| commits touching `rust/wa-capabilities` | 246 |
| ... touching `host.rs` | 110 |
| ... touching `capabilities.rs` | 55 |
| ... touching BOTH (the conflict pairs) | 32 |
| `capabilities.rs` edited ONLY by rows (registration-only) | **50** |
| ... of those, also touching `host.rs` for the handler | 29 |
| ... of those, NOT touching `host.rs` at all | **21** |
| ... of those, also editing `docs/HOST.md` | 34 |

After this change: **50 commits no longer touch `capabilities.rs`**, **21 no longer touch `capabilities.rs`
or `host.rs`** (their handlers already lived in `whatsapp_query.rs`, `disk.rs`, `stt.rs`, `fabric.rs`,
`email_*.rs`, `codemode_seam.rs`, `graph.rs`, `whatsapp_archive.rs`), and the set that touches BOTH files
falls from **32 to 3**. The 29 that still touch `host.rs` do so for the handler, not for registration -
that is what moving the capability into a component fixes, not this.

## What is NOT closed, and the one red gate

* **`docs/HOST.md` is still a shared row per capability** (34 of the 50 registration-only commits edited
  it). The drift test keeps it hand-maintained ON PURPOSE ("a generated block would only prove that the
  generator ran"), and that is a policy decision I did not overrule: a capability still edits one shared
  document, though no shared code. It is one sorted table, so two new capabilities in different places
  merge.
* **`cargo test -p wa-capabilities capabilities::tests` is RED on the base commit, and this branch does
  not change that.** `documented_inventory_matches_the_live_registry` fails with
  `registered but undocumented in docs/HOST.md: ["run_state"]`: `5e789ad7` (r8a(2)/(8)) registered
  `run_state` and no commit has ever added its `docs/HOST.md` row (`git log -S run_state -- docs/HOST.md`
  is empty; the file at `HEAD` has none). Proven on the base worktree: the same test fails there for the
  same reason. `scripts/test.sh` runs that row ("-p wa-capabilities -- capabilities::tests"), so the gate
  is red on main for anyone until a one-line doc row lands. I did not add it: `docs/HOST.md`'s inventory
  table is not this mission's file, and the row belongs with whoever owns `run_state`.
* `scripts/lib/contract-host.lua` (the shared contract fake) is still edited by a new capability - 2 of
  the 50 commits. Test-only, judged against the real host, out of scope here.
* I did not run the whole gate (`scripts/test.sh`) or the whole fast path: both are long suites and this
  diff is Rust-only with byte-identical output. What I did run is named above.

## Texts to approve (new or changed, verbatim)

Operator- and developer-facing strings this branch adds or changes:

1. `docs/HOST.md`, "The capability inventory", first paragraph: *"What this node can do is **data**, not
   prose. A capability's registration is one row - a name, a one-line description, an effect class and a
   handler - in a file under `rust/wa-capabilities/src/capability_rows/`, one file per area beside the
   module that implements the handler. `rust/wa-capabilities/src/capabilities.rs` collects those files
   (`build.rs` lists the directory, so a new row file is collected without an edit there) and the
   interpreter is booted from the collected rows: a `host.*` function that is not in a row cannot be
   called, and one that is in a row is a row below. Each entry carries a name, a one-line description and
   an effect class (`read-only`, `writes files`, `runs a process`, `network`, `device`), stably ordered by
   name so two nodes can be diffed."*
2. `docs/HOST.md`, the comment inside the inventory block: *"; the row files under
   rust/wa-capabilities/src/capability_rows/ by the drift test in capabilities.rs (cargo test -p
   wa-capabilities capabilities::tests)."*
3. `docs/HOST.md`: *"Adding a capability is two edits: one row in its area's file under `capability_rows/`,
   one row here."*
4. `docs/HOST.md`, "Adding a capability": *"...the row goes in an area's file under
   `rust/wa-capabilities/src/capability_rows/` (a row file added there is collected with no edit anywhere
   else) and the function itself in `rust/wa-capabilities/src/host.rs`; ..."*
5. `docs/FEATURES.md` table row: *"| the capability | `rust/wa-capabilities/src/features.rs`, its row in
   `capability_rows/kernel.rs`, documented in `HOST.md` |"*
6. `docs/CODEMODE-VIEW.md` table row: *"... `transcript_rewrite`), its rows in `capability_rows/console.rs` |"*
7. `docs/KERNEL.md`: *"to, so it does not come from `capabilities::registry()`"*.
8. Build-time refusals a developer can hit (`src/registry_scan.rs`), each naming the file: *"no
   capability-row directory at {}: {error}"*, *"{} holds no row files: a registry with no rows is a node
   that can do nothing"*, *"{} declares no `pub const ROWS:`, so it would register nothing"*, *"{} is not a
   Rust module name: a row file is a module, so its name has to be one"*.

No `wa capabilities`, `/health`, sandbox or refusal text changed: the JSON and the text form are the same
bytes as before (item 3).

