# The fleet update cycle, measured (night wave 6)

One cycle is: land a commit on `origin/main` -> its release is published for both Linux targets ->
the node that must build (`wasm_the_first`) deploys it -> a peer that can take a prebuilt (`work`) is
updated with `wa update`. Every number below comes from the record the step itself writes
(`landing-queue` rows, `deploy: [phase]` lines, `installed.txt`, the remote-update record); nothing is
estimated.

Every rehearsal lands a docs-only or comment-only carrier through `scripts/landing-queue.mjs`.

## The cycle, start and end

`wasm_the_first` (Windows x86_64, no published prebuilt for this host, so the deploy builds):

| step | baseline `b9cf0879` | cycle 3 `7e22b994d270` |
| --- | --- | --- |
| land (docs-only carrier) | 27 s | 23 s |
| release, both Linux targets | covered, 20 s | covered, 17 s |
| deploy: preflight | 14.7 s | 6.5 s |
| deploy: fetching | 1.2 s | 0.7 s |
| **deploy: compiling** | **336.2 s** | **32.8 s** |
| deploy: proving | 2.2 s | 3.6 s |
| deploy: installing | 123.7 s | 96.0 s |
| **deploy total** | **481 s** | **139.6 s** |
| **cycle total** | **~528 s** | **~180 s** |

The land of a *script* change costs more than a docs-only one, and it is the release that decides how
much: `337 s` when the release had to build and publish both Linux targets (fast path 199 s + publish
131 s), `218 s` when it was covered (fast path 182 s + 29 s).

`work` (Linux x86_64, takes the published prebuilt):

| step | measured |
| --- | --- |
| `wa update work` (the call itself) | 25 s |
| peer install, `binary_source=prebuilt-release` | started detached, installed within ~2.5 min |
| verify | `scripts/verify-deployed.sh` PASS (11 checks), `/health` ok |

`openclaw` was **not** updated: its install refuses on a malformed `graph.db`
(`backup_failed`) with 2.7 GiB free, and no supported non-destructive path cleared that tonight.

## What changed, and why compiling fell 10x

A deploy pins a fresh worktree per commit and used to build into **that pin's** `rust/target`, so the
workspace was compiled from cold on every deploy - 336 s for a landing that changed nothing but a docs
file. The target directory is build output, not state: it now lives in `<data>/build-cache/target`
(`WA_DEPLOY_BUILD_TARGET` names another) and is reused, and `codemode-build.mjs` honours
`WA_CODEMODE_TARGET_DIR` and reports the binary it produced. A directory that cannot be created or
written falls back to the pin's own target, which is the old behaviour and never a failed deploy.

The measured path: 336.2 s cold (baseline) -> 295.3 s on the first deploy through the new path (the
cache held a dead build's artifacts) -> **32.8 s** once the cache held the previous commit's build. A
no-Rust landing now recompiles nothing.

## What running the cycle found (and fixed)

1. **A deploy poisoned the next deploy's source tree.** `deploy.sh` exported `WA_DEPLOY_ROOT` for its
   children and then restarted `wa-sentinel`, which inherited it; the next deploy resolved its source to
   the previous deploy's *detached build pin*, waited the whole 600 s tree-wait and refused
   `canonical_busy` (646 s, nothing built). Fixed by starting the supervisor with the deploy-scoped
   variables removed, and by refusing a detached source behind `origin/main` at once (`source_pin_stale`).
2. **A watcher started from inside a run does not survive the run.** A hand `wa-sentinel restart` looked
   healthy for eight minutes, was reaped at 07:41:15Z, and took the deploy it had spawned with it
   mid-compile - no phase line, no exit line, no marker. Restored through the sanctioned OS-owned task
   path (`restore-sentinel-task.ps1 -RestoreOnly`), which proves watcher readiness and preserves pending
   requests: watcher pid 20152, task/launcher backup written.
3. **The sentinel's own idle gate has no pause signal.** A deploy request written at 07:03:01Z was
   spawned at 07:14:18Z because the node was busy with two long turns; the deploy-pending marker is
   written by `upgrade.sh` only *after* the build. The bound (1800 s) was not exceeded and no false
   `deploy silent` was reported - but the pause path was not exercised by those turns, and that gate is
   where the remaining wait lives.
4. **A POSIX path is not a Windows path.** The first version of the reusable target handed cargo
   `/c/Users/...`, which a native cargo reads as `C:\c\Users\...`; the deploy would then have looked for
   the binary in the real directory and found nothing. Converted with `cygpath -m`.
