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
├── build/<tree>-<hash>/target   one cargo output island per tree on this node
├── cache/               (already existed: host.paths().cache)
├── logs/                node and operation logs
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

`wa status` shows the facts the rule asks a node to publish about itself:

```
root      376M in /home/wa/.wasm-agent  ·  disk 11% of 1007G (cap 85%)  ·  last clean never
```

## `wa clean`

```
wa clean [--dry-run] [--days N] [--pin <path>|--unpin <path>] [--cap <percent>] [--status] [--json]
```

| group | rule |
| --- | --- |
| `worktrees` | deleted only when the branch is **merged into `origin/main`**, the tree is **clean**, it is **not detached** and **not pinned**. `git worktree remove` (never `rm -rf`), so the registration goes too. |
| `operations` | older than N days **and settled**; anything not settled, or with no `state.json`, is live work and stays |
| `logs`, `tmp` | older than N days |
| `build` | older than N days, **except** `build/target`, the shared cache that makes builds fast |
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

## The build cache: one island per tree, under the one root (measured on `wa-desktop`, 12/11)

One `CARGO_TARGET_DIR` shared by every tree on a node was measured and is **wrong** - not merely slow:

| probe | result |
| --- | --- |
| cold `cargo build --release` into an empty shared target dir (16 cores) | 3 m 25 s, 7.6 GB |
| a second worktree at the same commit into the same dir | 1 m 34 s, size unchanged |
| a source edit in that second tree, rebuilt in the shared dir | `wa-host-support` rebuilt there |
| back in the first tree, `cargo build` | **failed**: `cannot find function state_root in module wa_host_support::paths` - the shared `libwa_host_support-*.rlib` (mtime 20:25:59) was newer than the first tree's source (20:10:56), so cargo called it fresh and compiled the first tree against the **second** tree's library |

Cargo decides freshness by comparing source mtimes against the fingerprint in the target dir; it does
not know that the same unit id came from another checkout. A shared target dir therefore hands one
tree another tree's artifacts - a verdict about a tree that was never loaded, which is the failure
this project keeps paying for.

**So what is shared is the root, not the target dir.** Every tree's cargo output lives at

```
<root>/build/<basename>-<first 12 hex of sha256(canonical tree path)>/target
```

with a `tree` file beside it naming the tree it was built from. One owner (`<root>/build`), one
`wa clean`, one disk cap - and no artifact ever crosses trees. `rust/wa-capabilities/src/disk.rs`
(`build_island`, `build_env_for`) computes the name with `ring`; `scripts/lib/fast-binary.sh`
(`fast_binary_target_dir`) computes it with `sha256sum`; `scripts/test-oneroot.lua` checks the two
agree, so the binary `fast.sh` builds is the one the node's own builds use.

`wa clean` deletes an island when **the tree it belongs to is gone or has landed** - "a finished
worktree and its build outputs" is one decision, not two - and keeps the island of a tree still in
use.

**The node does not set `CARGO_TARGET_DIR` for an ordinary shell, on purpose.** This function sees the
child's *starting* directory, and `cd other-tree && cargo build` - an ordinary thing for an agent to
type - would compile one tree into another tree's island and re-create exactly the failure above. So
the build entry points that *know* their tree point at the island themselves: `scripts/lib/fast-binary.sh`
for the fast path, the deploy scripts for a deploy. Everything else keeps cargo's own `rust/target`,
which is per tree by construction.

**What this does not deliver is dedupe**, and this file does not pretend it does: N islands hold N
copies of the same dependency set. The smallest fix that would add it is `sccache` with per-tree target
dirs, which keeps compiled dependencies outside the target dir entirely; it is not installed here, so
it is **proposed**, not claimed.

**The binary rule is unchanged.** `fast.sh` still identifies the binary it tests by the commit it was
**stamped** with, never by the path it sits at: an island holding another commit's binary is `stale`,
and the run rebuilds it stamped with this tree.

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
