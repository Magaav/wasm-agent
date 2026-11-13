# One root, one `wa clean`, one disk cap

Everything an agent creates lives under one directory, one command reclaims it, and a cap refuses new
heavy work instead of filling the disk. The operator's decision (KISS / Da Vinci): **one folder, one
command, one cap**.

## Why (measured)

On `wa-desktop`, after one morning of agents (12/11):

| what | size | where |
| --- | --- | --- |
| worktrees | ~45 GB | `~/wt-*`, 42 of them, scattered beside the home |
| per-mission build dirs | ~25 GB | `rust/target-*`, one per mission |
| `/tmp` | 3.3 GB | mission scratch nobody removed |
| mission logs | 0.8 GB | mission scratch |
| **the node's own state** | **0.4 GB** | `~/.wasm-agent` |

The same day, on other nodes: `work`'s `/tmp` was 98 % full and broke deploys, `nextcloud` held 152
orphaned docker volumes and a 4 GB journal, `openclaw` was at 99 %. Nothing cleaned up after the
agents, and nothing could say what was reclaimable: a `bash` call had no idea which of the 42 trees
beside the home still held work, and no command owned the question.

## The one root

The root is the state root the node already had - **no second root concept**:

```
<WASM_AGENT_HOME or $HOME>/.wasm-agent/          the node's state root (ledger, sessions, memory)
├── tmp/                 scratch: TMPDIR/TEMP/TMP for every child the node spawns
├── worktrees/           worktrees created by agents and landing scripts
├── build/target/        THE ONE BUILD ROOT: one cargo directory per tree, and a hard cap on its size
├── cache/               (already existed: host.paths().cache)
├── logs/                node-level logs (retention-managed; a supervised operation logs under operations/)
├── clean/               pins (clean/pins) and the last clean record (clean/last.json)
├── operations/          (already existed: supervised operations)
└── wa-worktree-<id>/    (already existed: session worktrees, lua/core/workspaces.lua)
```

`rust/wa-host-support/src/paths.rs` owns the names (`state_root`, `root_dir`, `tmp_dir`,
`build_cache_dir`, `worktrees_dir`). A caller asks for the name; nothing builds the string by hand, so
`wa clean` and the thing it cleans cannot drift apart.

**Migration.** New things go to the new places. The directories that predate the root are **reported**
by `wa clean --dry-run` and never moved or deleted automatically: `~/wt-*`, a `rust/target-*` beside a
checkout and `/tmp/wa-*` are somebody's work until a human says otherwise, and half of them are drafts
that were never committed.

`scripts/new-worktree.sh <name>` creates an agent worktree at `<root>/worktrees/<name>`; the landing
queue names it when it refuses a preflight for want of a tree, so the refusal leads to the right place.

## Rule 4: the cap

`<root>`'s filesystem is measured (`statvfs` on POSIX; an unmeasurable disk answers
`disk_percent_unavailable` rather than a made-up zero). Past `WASM_AGENT_DISK_CAP` (default **85 %**):

1. the node runs the same `wa clean` before it starts new heavy work;
2. if cleaning gets under the cap, the work proceeds and says what it freed;
3. if it cannot, the work is refused **by name** (`disk_cap`) with the numbers.

"New heavy work" is where a full disk actually kills something: a supervised build, test or deploy
(`operation start`, and the `bash` tool when its command is one). A cheap command is never gated - a
`git status` on a full disk is not what broke a deploy, and refusing it would leave the node unable to
say what is wrong. A new session is gated too (`wa` before a chat starts).

There is a second cap, on build space rather than on the disk, in "The one build root" below.

`wa status` shows the facts the rule asks a node to publish about itself:

```
root      376M in /home/wa/.wasm-agent  ·  disk 11% of 1007G (cap 85%)  ·  build 8.4G of 30.0G cap  ·  last clean never
```

## `wa clean`

```
wa clean [--dry-run] [--days N] [--pin <path>|--unpin <path>] [--cap <percent>] [--build-cap <GB>] [--status] [--json]
```

| group | rule |
| --- | --- |
| `worktrees` | deleted only when the branch is **merged into `origin/main`**, the tree is **clean**, it is **not detached** and **not pinned**. `git worktree remove` (never `rm -rf`), so the registration goes too. |
| `operations` | older than N days **and settled**; anything not settled, or with no `state.json`, is live work and stays |
| `logs`, `tmp` | older than N days |
| `build` | the one build root: a per-tree directory whose tree is **gone or landed** goes, an island from the layout this replaced goes, and past the **build cap** the oldest build output goes first (see below) |
| `wa-worktree-<id>` (session trees) | the same rule as `worktrees` |

Retention default is **7 days** (`WASM_AGENT_CLEAN_DAYS`, or `--days`). `--dry-run` prints what would
go and how many bytes, grouped, and deletes nothing; the real run prints what it freed and records it
in `clean/last.json` for `wa status`.

**Pins.** `wa clean --pin <path>` writes `clean/pins` (one path per line, relative to the root or
absolute). A pin on a directory pins everything inside it. A `.wa-pin` marker file in a directory pins
that directory and everything inside it, so a mission can protect its own work without editing a list
outside it. A pinned path is never touched, whatever its age or state.

**Never deleted**, as candidates at all and then again on an explicit list (`PROTECTED`): the ledger
(`memory.db`), `graph.db`, `rendezvous.db`, sessions, `components/`, `releases/` (the rollback pin),
`archive/`, `sentinel/`, `watchdog/`, `commands/`, `bin/`, `node/`, `installed.txt`,
`deploy-result.json`, `env`. A detached worktree (a deploy pin) is never removed automatically.

**The guard.** No candidate outside the root is ever deleted, and the refusal is by name:

* a `..` component is refused **before** the filesystem is touched (`outside_root`): a path like
  `root/tmp/../../../etc` reads as inside the root and is not;
* a **symlink** is refused, not followed (`symlink_not_followed`): a cleaner that follows one is one
  mistake away from deleting its target;
* the canonical path must still start with the canonical root, which catches a parent directory that
  is itself a link out of the root.

`scripts/test-oneroot.lua` proves a symlink and a `..` path are refused and that the link's target is
untouched; `rust/wa-capabilities/src/disk_tests.rs` proves the same at the function boundary, plus
pins, retention, the landed-worktree rule and the status shape.

## The one build root: one folder, reused; new space only by deleting the old

The operator's decision (13/11, after the disk grew to 246 GB and filled the Windows C: drive until WSL
crashed): **do not allow build folders to accumulate - reuse the build, and if a build needs new space,
delete the old so there is only one**. Cleanup that morning removed **73 separate Rust build folders,
~196 GB**: a `rust/target` inside every worktree (up to 16 GB each), `rust/target-<name>` directories in
the canonical checkout (`target-ops` 11 GB, `target-onetool` 8.3 GB, `target-eval` 7.2 GB), one-root
islands `build/<name>-<hash>` (`graphdb-baseline` 9.8 GB, `wt-oneroot-<hash>` 6.9 GB, `sign-target`
6.2 GB) and a deploy cache. **None was ever deleted**, because every script invented its own directory
and nothing owned the question "how much build space is this node using".

Three rules, and `scripts/lib/build-target.sh` is the only place they are written down.

### 1. One build root

```
<root>/build/target/<basename>-<first 12 hex of sha256(canonical tree path)>
```

Every build kind the repo does resolves its `CARGO_TARGET_DIR` here: an agent's worktree,
`scripts/fast.sh` (the binary, the `cargo test` rows and the components), `scripts/build-components.sh`,
`scripts/codemode-build.mjs` (a landing and a deploy), `scripts/publish-node-binaries.sh` (a cross build
nests `<target>/<triple>/` inside it, as cargo already does) and `scripts/test.sh`. **No script invents
another target dir**, and the ones an older layout left behind are deleted before a build uses new space:

| candidate | rule |
| --- | --- |
| a child of `<root>/build` that is not `target` | an island from the layout this replaced: deleted |
| `<root>/build-cache` | the deploy cache from before this layout: deleted |
| `<tree>/rust/target`, `<tree>/rust/target-*` in any live checkout of this repo | deleted |
| a child of `<root>/build/target` no live tree owns (its tree is gone, was renamed, or was never named) | deleted |
| `deploy-<commit>` | kept - keyed by the **commit**, so a retried deploy of the same commit reuses it; the cap evicts it by age |

The sweep runs before every build and prints what it reclaimed:

```
onebuild: reclaimed 7.2G from 4 build dir(s) no script owns any more - one build root owns build space from now on: /home/wa/.wasm-agent/build/target
```

A **legacy** directory something wrote to in the last ten minutes belongs to a build that may still be
running in another session, so it is left and said so (`WASM_AGENT_BUILD_GRACE`, default 600 s) and
swept on a later run - after this change nothing new is ever written to one. The one build root's own
children are never delayed that way; the cap decides about those, and a child whose build lock is held
is skipped there.

### 2. Inside it, one child per tree - and why that is not a detail

One **flat** `CARGO_TARGET_DIR` for every tree on a node was proposed (fewer bytes, everything
reused) and **measured wrong on this node in twenty seconds** (`scripts/test-onebuild.mjs` keeps the
measurement as a row):

| step | result |
| --- | --- |
| two checkouts of one workspace at two paths, one flat target dir | cargo gives a member the **same metadata hash** in both: one `libbase-0b6880c448f07380.rlib` for both trees |
| tree A builds, tree B's library source is edited, tree B builds into the same dir | tree B overwrites that one file |
| back in tree A, `cargo build` | **a no-op**, and A's binary printed `base=2` - it ran **tree B's library** |

Cargo decides freshness by comparing source mtimes against the artifact in the target dir, and it does
not know the same unit id came from another checkout; an older source then reads as *fresh*. The 12/11
instance was the same shape and worse: `cannot find function state_root in module wa_host_support::paths`
- the first tree compiled against a library that was never built from it. A verdict about a tree that
was never loaded is the failure this project keeps paying for, so the target dir is per tree.

What is shared is the **root**: one directory, one `wa clean`, one `wa status` line, one cap, one owner,
and no artifact crosses a tree. Reuse inside a tree is unchanged (cargo's incremental build in that
tree's child), so a fast-path run on a tree that already built is still seconds.

**The name is computed three times and checked once**: `rust/wa-capabilities/src/disk.rs`
(`build_island_in`, `ring`), `scripts/lib/build-target.sh::wa_build_tree_name` (`sha256sum`) and
`scripts/codemode-build.mjs::treeName` (`node:crypto`). `scripts/test-onebuild.mjs` compares the shell
and the node one; `scripts/test-oneroot.lua` compares the shell and the node's own
`host.disk("island")`. A tree that has just been removed still has its directory named the same way:
both sides fall back to the absolute path when it can no longer be canonicalized.

**The node does not set `CARGO_TARGET_DIR` for an ordinary shell, on purpose.** This function sees the
child's *starting* directory, and `cd other-tree && cargo build` - an ordinary thing for an agent to
type - would compile one tree into another tree's build dir and re-create exactly the failure above.
The entry points that *know* their tree point at it themselves.

### 3. The build cap: a hard limit, enforced before the build, oldest first

`WASM_AGENT_BUILD_CAP_GB` (default **30**, decimal GB; `WASM_AGENT_BUILD_CAP_BYTES` for a test) is a
limit on the one build root, and it is a **separate number** from `WASM_AGENT_DISK_CAP`: "the disk is
85 % full" and "this node is holding 40 GB of compiled artifacts" are different facts, and only the
second has an eviction order that touches nothing but build output. Before every heavy build:

1. over the cap, the **oldest** build output goes first (mtime = when a build last wrote there), and the
   build says what it deleted;
2. if the cap still cannot be met with everything else gone, the build proceeds and says so - it never
   deletes the thing it is about to build;
3. `wa clean` shows the same number and enforces the same rule, so a `--dry-run` names the victims the
   real run takes. `wa clean --build-cap <GB>` writes the cap into `<config>/env`.

Never a candidate: source, git objects, the `~/.cargo` registry, operator data (the `PROTECTED` list),
and any tree's build dir while its build lock is held.

**The one entry point this file does not yet move is the nightly gate.** `scripts/test.sh` names its own
artifacts by path in four places (`rust/target/release/wa`, `rust/wa-sentinel/target/release/wa-sentinel`,
`wa-core-pool-bench`) and hands them to rows as `WA_BIN`, so pointing the gate at the one build root is a
change to the gate itself, not a line in this file - and a gate that cannot be run here (it is ~50 min,
the nightly job) is not one to change blind. It is **named here as a gap, not claimed as done**: until it
is moved, a gate run writes the tree's own `rust/target`, which the next build's sweep deletes (so it is
bounded by the same rule) but which the build cap does not yet see.

### Concurrency: builds share the root, and a wait is printed

Two builds of the same tree share one child; the second waits on that child's lock
(`wa_build_run`, `flock`, default wait 1800 s) and **the wait is printed with its length** when it is
worth mentioning, so a slow build can be attributed to the queue and not to the compiler:

```
onebuild: waited 34.2s for the build lock on wt-alpha-4c5a4c064c1b (another build of this tree was running)
```

**What this does not deliver is dedupe across trees**, and this file does not pretend otherwise: N live
trees hold N copies of the same dependency set, bounded by the cap. The smallest fix that would add it is
`sccache` with per-tree target dirs, which keeps compiled dependencies outside the target dir entirely;
it is not installed here, so it is **proposed**, not claimed.

**The binary rule is unchanged.** `fast.sh` still identifies the binary it tests by the commit it was
**stamped** with, never by the path it sits at: a build dir holding another commit's binary is `stale`,
and the run rebuilds it stamped with this tree.

### A tree that goes takes its build output with it

"A finished worktree and its build outputs" is one decision, not two:

* `wa clean` deletes the build dir in the same run that removes the worktree (`build_islands_deleted`
  in its JSON), so the island never outlives the tree by even one run;
* a released session worktree asks the node itself (`host.disk("forget", {path})`,
  `lua/core/workspaces.lua`), `scripts/reap-worktrees.mjs` reports what it freed, and
  `scripts/landing-queue.mjs` forgets the build dir of a deploy pin it replaces;
* `scripts/lib/build-target.sh forget <tree>` is the same operation for shell callers; the next build's
  sweep would delete an ownerless child anyway, so a missed call costs one build, not one leak.

## TMPDIR

Every child process the node spawns gets `TMPDIR`, `TEMP` and `TMP` pointing at `<root>/tmp/`
(`rust/wa-capabilities/src/operations.rs`, in `configure_spec`, the one place both the `bash` tool and
`operation start` pass through). It is set even when the caller's environment already names a TMPDIR:
the promise is that everything an agent creates lives under one root, and a child that honoured an
inherited `/tmp` would break exactly that promise. When `<root>/tmp` cannot be created, nothing is
pushed - a child is never pointed at a directory that does not exist.

This is the rule that would have caught the `work` node: `/tmp` at 98 % broke deploys while the node's
own state was 0.4 GB.

## Not in scope (the operator agreed)

A per-agent virtual filesystem, per-session quotas, moving system logs (journald) under the root, and
WASI isolation for builds.
