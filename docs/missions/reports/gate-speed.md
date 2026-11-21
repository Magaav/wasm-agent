# gate-speed - no cold compiles, bounded heat

Branch `change/gate-speed`, base `change/batch-4` (3bd47f4d), 21/11.
Every number below was measured on this node (avell, 16 cores, btrfs, Rust stable, 245 crates) during this
mission; the command that produced it is named next to it. Nothing here is estimated.

## The premises, re-measured before writing code

| premise | verdict |
| --- | --- |
| `wa_build_target` gives every tree its own cargo target dir | **TRUE** - `scripts/lib/build-target.sh:95`, `<root>/build/target/<basename>-<12 hex>` |
| every new worktree/land tree compiles from cold | **TRUE** - a new worktree has no child, so cargo finds nothing to reuse |
| the disk is btrfs | **TRUE** - `/dev/mapper/root on /home type btrfs`. `/tmp` is **tmpfs**, where reflink fails (`Operation not supported`): the tests that need a non-reflink filesystem use `/dev/shm` |
| 16 cores, 95 C under parallel builds | **TRUE**, and stronger than the brief: one cold build alone already peaks at **97-98 C** (table below). The 20/11 load-105 fleet storm is what concurrency adds on top |

## Item 1 - a new target dir is seeded from the newest sibling

Implemented in `scripts/lib/build-target.sh` (commit **3ad67f65**, guard in **f09659bf**):
`wa_build_prepare` calls `wa_build_seed` when the tree child does not exist yet. The seed is
`cp -a --reflink=always` from the most recently used sibling built by the *same toolchain* (each child
records `rustc -vV`'s hash in `child/toolchain`). Conditions: same toolchain, not being built into right
now (its build lock is probed non-destructively), and **reflink or nothing** - when the filesystem cannot
share blocks the build says so and starts cold. There is no full-copy fallback.

A fourth condition was found by this item own test (**f09659bf**): an artifact from the future is not a
seed. Cargo calls an artifact current by comparing mtimes, so a sibling built *after* the tree sources
were written hands over artifacts cargo keeps - and the seeded tree ran the sibling code (`base=1` where
its own library answered `base=2`). The cutoff is now the tree newest source mtime; a sibling holding
anything newer is passed over, an older sibling is still used, and an unreadable cutoff builds cold.

### Before/after, measured through the shipped path

Real path (`wa_build_run`, 10 jobs, shipping code-mode assets, two worktrees of HEAD, the second created
*after* the first was built as real use does):

| build | seconds | units compiled |
| --- | --- | --- |
| cold (`wt-m1`) | **135** | 255 |
| seeded (`wt-m2`, from `wt-m1`) | **61** | 33 |

Both binaries report `wasm-agent f09659bf`, and the seeded log says
`onebuild: seeded wt-m2-... from wt-m1-...`. The reflink copy itself: 1.4 GB in **105 ms** against the
74 s it saves. A child seeded across commits (tree at 4169ab79, seed built at 3bd47f4d) built in **61 s**
and correctly reported `4169ab79`.

### Correctness, kept as tests

`scripts/test-build-seed.mjs` (24 checks, wired into **scripts/test.sh:205** and **scripts/fast.sh:745**).
It builds two tiny two-member workspaces whose library answers a different number in each, and asserts
the seeded tree **runs and carries its own code**: the changed crate marker string is read out of the
*binary file*, and the origin binary does not contain it. It drives the refusals (no toolchain record,
another toolchain, `WA_BUILD_SEED=0`, an artifact newer than the tree) and the no-reflink path on
`/dev/shm`, where it asserts the build says it starts cold and pays for no full copy. Both new tests fail
on the base 3bd47f4d (no `wa_build_seed`/`wa_build_host_lock` there), verified by running them from a
base worktree.
## Item 2 - one heavy build at a time, bounded jobs

Implemented in `scripts/lib/build-target.sh` (commit **170ec57f**), wired into every caller that
compiles: `wa_build_run` (mission/gate builds), `scripts/build-components.sh`, and the fast path
per-crate compile row (`scripts/fast.sh`).

* **One host-wide lock**, `<root>/build/build.lock`, taken with `flock -o`. `-o` matters and is proven:
  without it a child a build leaves behind inherits the descriptor and holds the lock (reproduced here:
  `A-o: LOCK FREE` vs `B-noo: lock held`). The lock is taken around **cargo only** - tests are never run
  under it, so two suites still run in parallel and a row that waits on another process cannot deadlock
  the node builds. A nested build (a build script that runs cargo) does not queue behind itself
  (`WA_BUILD_HOST_LOCK_HELD`). The sweep allow-list keeps `build.lock`, so the cap cannot delete the
  lock builds are queued on.
* **A default job cap**, `wa_build_jobs`: `CARGO_BUILD_JOBS` always wins, otherwise
  `WA_BUILD_JOBS_DEFAULT` (default **10**).

### Build time and peak temperature at 6 / 10 / 16 jobs

Cold release build of `wa-host` (255 units), one at a time, temperature sampled once a second with
`sensors` (Package id 0):

| jobs | seconds | peak C | avg C |
| --- | --- | --- | --- |
| 6 | 144 | 97 | 93.4 |
| 10 | 136 | 98 | 92.9 |
| 16 | 132 | 97 | 92.8 |

Ten is the default: within 3% of sixteen (4 s of 136) while leaving six cores free for the interactive
session, the gate tests and a second build. The table also says what the cap does **not** buy: a single
build this long soaks the cooler at any job count, so the peak is ~97-98 C either way. What the heat rule
removes is the *concurrent* case (three 16-job builds = 48 compilers on 16 cores, the 20/11 incident):
the host lock serialises those and the cap bounds each one.

`scripts/test-build-heat.mjs` (18 checks, wired into **scripts/test.sh:204** and **scripts/fast.sh:744**)
keeps it: two builds do not overlap (a held lock makes the second wait, measured as real elapsed time,
not just a message), the lock is not inherited by a surviving child, a nested build does not deadlock,
the caller `CARGO_BUILD_JOBS` wins, and a non-cargo command line is never queued.

## What was not measured

* **The land gate end to end.** No landing ran from this mission (commit locally, never push). Its two
  compiles are the two measured above, so a landing inherits the 135 -> 61 s seed saving, but the gate
  own wall clock was not run here and is not claimed.
* **A full `scripts/fast.sh` run** against a cold worktree. The fast path compile row goes through the
  same helpers and is seeded the same way, and `scripts/test-build-seed.mjs` builds binaries through
  that path, but the whole run was not timed.
* **Concurrent-build temperature.** The 20/11 load-105 incident is quoted from the brief; this mission
  measured single builds and the lock serialisation, not a reproduced fleet storm.

## Texts to approve

1. `onebuild: seeded %s from %s (%s, cp -a --reflink=always: shared blocks, cargo rebuilds only what differs)`
2. `onebuild: reflink is not supported on this filesystem, so %s starts cold instead of being seeded from %s (never a full copy)`
3. `onebuild: %s starts cold: the newest source mtime of this tree cannot be read, so no seed can be shown to predate it`
4. `onebuild: %s starts cold: the sibling %s holds an artifact newer than this tree's newest source, and cargo would keep it instead of rebuilding (measured: a seeded tree ran the sibling code)`
5. `onebuild: waited %ss for the node build lock (another build on this node was running; one heavy build at a time)`
6. `onebuild: waited %ss for the node build lock and gave up; building anyway (WA_BUILD_HOST_LOCK_WAIT raises the wait)`
7. `onebuild: flock is not available, so this build is not queued behind other builds`
8. `onebuild: cannot name this build toolchain (rustc -vV failed), so %s starts cold`

## Pre-existing failures

None observed: `scripts/test-onebuild.mjs` (44 checks) still passes with seeding and the lock in place;
both new rows pass on the branch and fail on the base.

