---
name: clean-disk
description: >-
  How to reclaim disk on this machine safely: measure first with cheap probes, delete only what this
  file names, never touch the node's state, the databases, live worktrees, unmerged drafts or the
  installed build, and report what was removed and what was skipped and why. Use it for `/clean disk`,
  when the disk is above ~85%, when a build fails with no space, or when temp/scratch/evidence has
  grown without bound.
---

# Reclaiming disk on this machine

Disk here is a single volume: `C:` ~477 GB, and it has been at **92% used (42 GB free)** with 169
session worktrees. Measuring is the expensive part, not deleting: a `du -sm` across
`.wasm-agent/wa-worktree-*` took **14.5 minutes**. Never start with a full-tree `du`.

## 0. The rules that make this safe

1. **Dry run first, always.** Produce the plan (path, size, why it is safe) and delete nothing until
   the plan has been shown. `/clean disk` runs the dry run; a second invocation with `--apply` deletes.
2. **Delete only what this file names.** A path that is merely "surprisingly big" is not a target.
3. **Never `rm -rf` a git worktree.** `git worktree remove` (and `session_worktree release` for
   managed ones) is the only supported path — a plain delete loses uncommitted drafts and leaves the
   repo's worktree metadata pointing at nothing.
4. **Never touch state**: `~/.wasm-agent/memory.db*`, `graph.db`, `installed.txt`,
   `deploy-result.json`, `serve.pid`, `sentinel/requests|claimed|done|failed` (that is evidence),
   `sentinel/stop`, `~/.wasm-agent/archive/` (deliberate archives), the repo working trees, and any
   worktree whose branch is **not** an ancestor of `origin/main`.
5. **A skipped thing is reported as skipped**, with the reason. "Nothing to do" and "I did not look"
   must not read the same.

## 1. Measure cheaply (do this, not `du -sh *`)

```bash
df -h /c                                             # the only number that decides urgency
du -sm ~/.wasm-agent/session-scratch ~/.wasm-agent/benchmarks \
       ~/.wasm-agent/operations ~/.wasm-agent/sentinel \
       "$LOCALAPPDATA/Temp" rust/target | sort -rn     # targeted, ~1 min
```
Per-worktree sizes are the exception, and they are slow. Ask for them only when the plan needs them,
one directory at a time, and cap the number of samples.

## 2. What is safe here, by measured size

| Target | Measured | Rule |
| --- | --- | --- |
| `~/.wasm-agent/session-scratch/*` | 29 GB | delete **per session**, oldest first, keeping the newest N (default 5) and any session that is still open; these are screenshots, probes and evidence copies |
| `~/.wasm-agent/benchmarks/*` | 7.7 GB | benchmark worktrees from finished runs; delete only runs not referenced by a delivery record, oldest first |
| `rust/target/{debug,incremental,*/deps}` | 4.8 GB | `cargo clean` is **opt-in** — say the rebuild cost out loud; prefer `target/debug` before `release` |
| `$LOCALAPPDATA/Temp/wa-*`, `wa-ui-test-*`, `ui-*`, `fa-*` | 2.8 GB | test harness output, safe anytime; check no `test-ui.ps1` is running first (the harness refuses a second instance) |
| `~/.wasm-agent/operations/*` | 2.7 GB | per-call stdout/stderr; keep the newest N days (default 3) so a recent failure is still diagnosable |
| `~/.wasm-agent/sentinel/deploy.out`, `deploy.log`, `sentinel.log` | 2.6 GB | rotate, keep the last ~50 MB each; **never** delete `requests/`, `done/`, `failed/`, `protocol-effect.json` |
| images/screenshots in the above | inside their areas | they are the bulk of session-scratch and Temp; deleting the containing area covers them |

## 3. Worktrees: list, then release, never delete

The 169 worktrees dominate the disk, and they are the one thing this skill must not improvise:

```bash
git worktree list                                      # all of them
git branch --no-merged origin/main                     # what may not be released
git -C <worktree> status --porcelain                   # dirty = keep
```
Release only worktrees that are **clean, inactive, and merged** (`session_worktree release`), and
leave the rest. Report the candidates with sizes so the operator can decide; a worktree holding an
unlanded draft is evidence, not clutter.

## 4. Docker and virtual disks (tier 3 — a service stops, never silently)

Measured on this machine, 2026-10-21:

| item | measured | action | risk |
| --- | --- | --- | --- |
| Docker images | **10.34 GB** reclaimable (22 images, 1 active) | `docker image prune -a` | safe — pulled or rebuilt on demand |
| Docker build cache | **5.52 GB** | `docker builder prune` | safe |
| `AppData/Local/Docker/wsl/disk/docker_data.vhdx` | **30.7 GB** | compaction only (below) | needs Docker Desktop stopped |
| `…/CanonicalGroupLimited.Ubuntu_*/LocalState/ext4.vhdx` | **39.0 GB** | compaction only (below) | **holds real work — back up first** |

### The VHDX rule (the one that bites)

Deleting files *inside* a distro or a Docker image frees blocks in the guest, **not** space on `C:`.
The `.vhdx` keeps its allocated size until it is compacted. "Prune 30 GB and expect 30 GB back" is
false; recent Docker Desktop compacts its own store, a WSL distro does not.

### Docker, in order

1. `docker system df` — read `RECLAIMABLE` before deleting anything.
2. `docker image prune -a`, then `docker builder prune`. Safe: images and cache are rebuilt.
   **Never** `docker system prune --volumes` unasked — a volume may hold data, not cache.
3. For `docker_data.vhdx`, quit Docker Desktop first, then compact. **Never compact while the engine
   runs**: the file is open and the result is a corrupt virtual disk.

### Tier 1-2: caches that re-download (no service stops, no elevation)

| item | measured | action | note |
| --- | --- | --- | --- |
| **Recycle Bin** | **9.5 GB** | `Clear-RecycleBin -Force` | the probe that failed with `du`: read it with PowerShell (`Get-ChildItem -LiteralPath "C:\$Recycle.Bin"`). **Ask first** - nothing in it is restorable afterwards |
| `~/.cargo/registry` | 731 MB | `cargo cache -a` or delete `registry/` | re-downloads on the next build |
| Explorer thumbnail/icon cache | 327 MB | delete `…/Explorer/thumbcache_*.db` | Windows rebuilds it; needs the Explorer window closed, not the service |
| Chrome `User Data/Default/Cache` | 58 MB | delete the `Cache` dir | never touch the profile directory itself |
| npm cache | 34 MB | `npm cache clean --force` | |
| pip cache | 1 MB | nothing to win | |
| `C:\Windows\SoftwareDistribution\Download` | **0.0 MB, 0 entries** | nothing to win | genuinely empty here |
| `C:\Windows\Temp`, `WinSxS` | **unreadable (access denied)**, 8.9 GB when read | needs elevation | see the traps below |

### The WSL distro: report-only unless the operator says otherwise

This distro holds real work (`/local/colmeio` and its evidence), so the default is **measure and
report, do not compact**:

```bash
wsl.exe -l -v                                        # what exists and what is running
wsl.exe -d Ubuntu -- df -h /                         # guest usage: the only number that says what frees
wsl.exe -d Ubuntu -- du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -15
```

**Measured on this machine (2026-10-21): the distro's `ext4.vhdx` is 39.0 GB on disk and the guest uses
13 GB** (`df -h /` → 14 G used of 1007 G; `du -xh --max-depth=1 /` → 13 G total). The gap is therefore
**~26 GB reclaimable** — this is the case where compaction *is* worth it. The rule is the shape, not a
fixed verdict: only the gap between guest usage and file size is reclaimable, and it must be measured,
never assumed in either direction.

From Git Bash the guest command needs path conversion OFF, or the guest receives a Windows path:
`df: 'C:/Program Files/Git/': No such file or directory` is what this looks like (measured here).

```bash
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' wsl.exe -d Ubuntu -- df -h /
```

When the operator does ask, this order is what makes it defensible rather than risky:

1. **Prove nothing is running inside** — no build, no agent, no database, no long job. Ask; do not
   infer it from `wsl.exe -l -v` alone: `Running` can be an idle shell, and an idle shell can hide a job.
2. **Back up first, and keep it**: `wsl.exe --export Ubuntu <backup.tar>` (a full, restorable image;
   `wsl.exe --import Ubuntu <dir> <backup.tar>` restores it). Verify the exit code **and** a non-trivial
   file size before touching the disk. This is the step that makes it non-risky — the rest is recovery.
3. **Prefer the reversible switch**: `wsl.exe --manage Ubuntu --set-sparse true` makes the disk
   TRIM-backed, so freed blocks return as they are freed. It does not rewrite the filesystem, and
   `wsl.exe --manage Ubuntu --set-sparse false` reverses it. Check `wsl.exe --version` first (sparse
   needs WSL 2.0+).
4. **Only if sparse is unavailable**, stop the distro (`wsl.exe --terminate Ubuntu`) and compact the
   file with `Optimize-VHD -Mode Full` (Hyper-V module) or `diskpart`'s `compact vdisk`. That rewrites
   the file; an interrupt can corrupt it. Hence step 2 is not optional.
5. **Verify before calling it done**: `wsl.exe -d Ubuntu -- echo ok`, a known work path still answers
   (`ls /local/colmeio`), and the `.vhdx` size actually dropped. A size that did not drop is a result
   to report, not a step to retry blindly.
6. Keep the export for N days (default 7) and say where it is.

**Never run tier 3 in the same operation as a node deploy or any run that is mid-turn**: stopping the
Docker engine or the distro under a model call fails the work, and the deploy needs the node idle.

### Measurement traps that have already produced wrong answers here

- **`0.0 MB` from PowerShell with `-ErrorAction SilentlyContinue` means "unreadable", not "empty".**
  `C:\Windows\Temp` reports 0.0 MB that way and is in fact denied; measure with `-ErrorAction Stop`
  and a `catch` that says `UNREADABLE`, or do not report a number at all.
- **`du` cannot read per-user ACL directories** like `$Recycle.Bin`; use the shell's own API.
- **Git Bash rewrites guest paths** (`MSYS_NO_PATHCONV=1` above), so a "the distro has no df" error is
  usually the host's path conversion, not a broken distro.
- A size that did not change after a cleanup is a **result to report**, never a cue to retry harder.

## 5. The report

One block, and it is the deliverable:

```
disk: 92% used, 42G free (before)  ->  ?% used, ?G free (after)
deleted:  session-scratch/2026-10-14-* 4.1 GB · Temp/wa-ui-test-* 0.8 GB
skipped:  session-scratch/6c2a… (open session) · wa-worktree-… (branch not merged)
          rust/target/release (cargo clean not requested - rebuild is ~7 min)
not touched: databases, installed build, sentinel evidence, archive/
```

Every number comes from a command that was actually run. If a size was not measured, say
`not measured` rather than guessing.
