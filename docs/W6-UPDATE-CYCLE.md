# The fleet update cycle, measured (night wave 6)

One cycle is: land a commit on `origin/main` -> its release is published for both Linux targets ->
the node that must build (`wasm_the_first`) deploys it -> a peer that can take a prebuilt (`work`) is
updated with `wa update`. Every number below comes from the record the step itself writes
(`landing-queue` rows, `deploy: [phase]` lines, `installed.txt`, the remote-update record); nothing is
estimated.

Every rehearsal lands a docs-only or comment-only carrier through `scripts/landing-queue.mjs`.

## Baseline (before any change)

Deploy of `b9cf0879` on `wasm_the_first` (Windows x86_64, no published prebuilt for this host, so the
deploy builds):

| phase | time |
| --- | --- |
| preflight | 14.7 s |
| fetching | 1.2 s |
| **compiling** | **336.2 s** |
| proving | 2.2 s |
| installing | 123.7 s |
| **deploy total** | **481 s** |

Compiling dominated because the pin is a fresh worktree per commit and the build used that pin's own
`rust/target`: every deploy compiled the workspace from cold, even when the landing changed no Rust.

The other steps of the baseline cycle: land docs-only 27 s (release covered in 20 s of it), land of a
script change 337 s (fast path 199 s + release **published** for both Linux targets 131 s),
`wa update work` 25 s for the call, peer installed with `binary_source=prebuilt-release`.

## What the cycle found (all of it by running it)

1. **A deploy poisoned the next deploy's source tree.** `deploy.sh` exported `WA_DEPLOY_ROOT` for its
   children and then restarted `wa-sentinel`, which inherited it; the next deploy resolved its source to
   the previous deploy's *detached build pin*, waited the whole 600 s tree-wait and refused
   `canonical_busy` (646 s, nothing built). Fixed by starting the supervisor with the deploy-scoped
   variables removed, and by refusing a detached source behind `origin/main` at once (`source_pin_stale`).
2. **A watcher started from inside a run does not survive the run.** A hand `wa-sentinel restart` looked
   healthy for eight minutes, was reaped at 07:41:15Z, and took the deploy it had spawned with it
   mid-compile -- no phase line, no exit line, no marker. Restored through the sanctioned OS-owned task
   path (`restore-sentinel-task.ps1 -RestoreOnly`), which skips the historical protocol precondition by
   design and proves watcher readiness: pid 20152, task/launcher backup, pending requests preserved.
3. **The sentinel's own idle gate has no pause signal.** A deploy request written at 07:03:01Z was
   spawned at 07:14:18Z because the node was busy with two long turns; the deploy-pending marker is
   written by `upgrade.sh` only *after* the build. The bound (1800 s) was not exceeded and no false
   `deploy silent` was reported, but the pause path was not exercised by those turns.
4. **A POSIX path is not a Windows path.** The first version of the reusable target handed cargo
   `/c/Users/...`, which a native cargo reads as `C:\c\Users\...`; the deploy then looked for the binary
   in the real directory and would have found nothing. Converted with `cygpath -m`.

## After the change

| cycle | land | release | compiling | installing | deploy total |
| --- | --- | --- | --- | --- | --- |
| baseline `b9cf0879` | 27 s | covered, 20 s | 336.2 s | 123.7 s | 481 s |
| `4636e37a14d4` (first deploy through the reusable target) | 218 s | covered, 29 s | 295.3 s | 98.1 s | 414 s |
