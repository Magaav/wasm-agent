---
name: clean-disk
description: >-
  How to reclaim disk on any device - this node (Windows, Linux or macOS), a Linux/Docker server
  reached over SSH (a Nextcloud box, for example), or a VM behind a virtual disk. Measure first with
  cheap probes, delete only what this file names for that platform, never touch state (databases,
  node data, git worktrees, Docker volumes, installed builds), and report what was removed and what
  was skipped and why. Use it for /clean disk, for any device above ~85%, when a build fails with no
  space, when a deploy is refused for disk, or when build output, finished worktrees or virtual disk
  images have grown without bound.
---

# Reclaiming disk on any device

The rule that makes this safe is the same on every device, so it comes first; the targets differ per
platform and each one is measured, never assumed. Most of the space on a working machine is **build
output, finished worktrees and virtual disk images**, not caches: on this Windows node, `rust/target`
dirs held **16.0 GiB** (canonical 2,408 MiB + worktree targets 3,155 MiB + job-clone targets 10,869
MiB) and benchmark `cargo-target` dirs another **4.8 GiB**, while the two vhdx files held **68.7 GiB**;
the tier-1 caches this file names are much smaller (measured 2026-11-10, sections 2.1 and 5). Read the
moments in section 6 *before* the disk refuses a build - the failure mode is `os error 112` in the
middle of a gate, not a clean refusal.

## 0. The rules

1. **Name the device before the first number.** "Local" is this node's machine; "ssh <host>" is
   another machine, and its numbers must come from `ssh <host> '…'`, never from the local disk.
2. **Dry run first.** Produce the plan (device, path, size, why it is safe), delete nothing until it
   has been shown. A second invocation with an explicit go deletes.
3. **Delete only what this file names for that platform.** A path that is merely "surprisingly big"
   is not a target.
4. **Never touch state**: databases (`memory.db*`, `graph.db`, MySQL/Nextcloud data), `installed.txt`,
   `deploy-result.json`, `serve.pid`, `sentinel/requests|claimed|done|failed`, `sentinel/stop`,
   `~/.wasm-agent/archive/`, the repo working trees, **Docker volumes**, and any git worktree whose
   branch is not an ancestor of `origin/main`.
5. **Never `rm -rf` a git worktree.** `git worktree remove` (or `session_worktree release`) is the
   only supported path; a plain delete loses drafts and leaves metadata pointing at nothing.
6. **A skipped thing is reported as skipped**, with the reason. "Nothing to do" and "I did not look"
   must not read the same.
7. **Tier 3 (something stops, or a virtual disk is rewritten) never runs in the same operation as a
   deploy or an agent turn on that device.** Stopping Docker or a distro under a model call fails the
   work; a deploy needs the node idle. Tier 3 is **ask-first**: show the exact image, its before size
   and the idle window, then wait for an explicit go.
8. **Build output is not state, but the tree around it is.** A cargo target dir is disposable when no
   build holds it; a branch, a commit, a worktree, a session store and a benchmark report are not.
   `cargo clean` is opt-in, the rebuild cost is said out loud, and a target with a live
   `.cargo-lock` or a cargo/rustc process naming it is never cleaned.

## 1. Identify the device and what "the disk" is

```bash
uname -s; uname -m                 # Darwin, Linux, or (Git Bash) MINGW*/MSYS*
df -hT | sort -k5 -h | tail -8     # worst-used mounts first; -T shows fs type
bash scripts/check-disk-floor.sh   # free vs the 3.71 GiB a build needs (section 6)
```

- **Remote**: prefix every probe with `ssh <host> '…'`; measure `df -h /` *there*.
- **Plain volume / LVM**: `df -h` is the answer; `sudo vgs`, `sudo lvs` when a volume group is thin.
- **Container**: the host volume is what matters; `docker system df` and `du -sh /var/lib/docker`.
- **Virtual disk image** (`*.vhdx`, `*.qcow2`): deleting inside the guest frees guest blocks, not the
  host file. Only the gap between guest usage and image size is reclaimable, and only by compaction
  (section 5).

Measure only the targets named below, one `du -sm` per area. A full-tree `du` is the expensive part:
measured on this Windows node, `du -sm` across 169 worktrees took **14.5 minutes**. `du -sm` over all
of `C:/Users/Victor/wa-pi` also exceeded 60 s on 2026-11-10; measure its `target-*` dirs instead.

## 2. Safe targets by platform (tiered)

### Tier 1 - caches, nothing stops

| Platform | Target | Command | Note |
| --- | --- | --- | --- |
| Linux | apt package cache | `sudo apt-get clean` | re-downloads on demand; measured 85 MB on the Nextcloud box |
| Linux | systemd journal | `sudo journalctl --vacuum-size=200M` | keeps recent entries; measured **4.1 GB** of `/var/log` there |
| Linux | `/tmp` old entries | `sudo find /tmp -maxdepth 1 -mtime +7 -exec rm -rf {} +` | only with `-mtime`; never the whole directory |
| Linux | user caches | `rm -rf ~/.cache/<tool>` | pip/npm/cargo caches rebuild |
| Linux | snap old revisions | `sudo snap list --all`, `snap set system refresh.retain=2` | never `snap remove` a live revision |
| Windows | `$LOCALAPPDATA/Temp/wa-*`, `wa-ui-test-*`, `ui-*`, `fa-*` | check no `test-ui.ps1` runs, then delete | measured 2.8 GB; the rest of Temp belongs to other tools |
| Windows | Explorer thumbnail cache | delete `…/Explorer/thumbcache_*.db` | Windows rebuilds it |
| Windows | npm / pip / cargo cache | `npm cache clean --force`, delete `~/.cargo/registry` | re-downloads; measured 731 MB (cargo) |
| Windows | Recycle Bin | `Clear-RecycleBin -Force` | **ask first** - nothing is restorable afterwards; measured 9.5 GB |
| macOS | `~/Library/Caches`, Xcode `DerivedData` | - | **not measured by this file**: measure before claiming any number |

### Tier 2 - this node's build and evidence areas

| Target | Rule |
| --- | --- |
| `~/.wasm-agent/session-scratch/*` | delete per session, oldest first, keep the newest N (default 5) and any open session; measured 29 GB on this node |
| `~/.wasm-agent/operations/*` | per-call stdout/stderr; keep the newest N days (default 3) so a recent failure stays diagnosable |
| `~/.wasm-agent/sentinel/{deploy.out,deploy.log,sentinel.log}` | rotate, keep the last ~50 MB each; **never** `requests/`, `done/`, `failed/`, `protocol-effect.json` |
| `~/.wasm-agent/benchmarks/*` | **not deletable as directories** - a run dir is evidence. Its per-arm `cargo-target` is build output (section 2.1); its `worktrees/` entries are released through git (section 4). Measured 2026-11-10 13:59 -0300: 7,504 MiB in 10 run dirs, of which 21 `cargo-target` dirs total 4,937 MiB (avg 235 MiB) and `whisper-wasm` models 2,143 MiB + corpus-cache 402 MiB (inputs, keep unless the benchmark is retired) |
| `rust/target` (canonical, worktrees, job clones) | `cargo clean` is **opt-in** and only when no build holds it; say the rebuild cost out loud (section 2.1) |
| `/_clean-disk-report.sh` (this node) | `bash scripts/clean-disk-report.sh` is the Windows dry run as one block, and it now reports worktree/job-clone targets, benchmark `cargo-target`s and the floor; other devices use section 1's probes |
| git worktrees | release only clean + inactive + merged, through `git worktree remove`; never delete (section 4) |

### 2.1 Build output: cargo target dirs

Cargo target dirs are the biggest *disposable* thing on a working machine. Measured 2026-11-10, local
times are -0300 on this Windows node (`wasm_the_first`), remote time is UTC on `openclaw`:

| Where | Measured | Disposable? | Supported command |
| --- | --- | --- | --- |
| canonical checkout, `C:/Users/Victor/orca/projects/wasm-agent/rust/target` | **2,408 MiB** at 13:59 | yes, if no build holds it | `cargo clean --manifest-path rust/Cargo.toml` |
| a worktree's `rust/target` | **3,155 MiB across 2 dirs** (`wt-relay` 3,153 + `int-memtx` 2) at 14:00 | yes; the worktree, branch and drafts are **not** | `cargo clean --manifest-path <worktree>/rust/Cargo.toml` |
| job-clone targets `C:/Users/Victor/wa-pi/target-*` (each job sets `CARGO_TARGET_DIR`), only two of the five names in the job scripts still exist | `target-int` **7,084 MiB**, `target-pub` **3,785 MiB** at 14:00 | yes; the job clone's source is not | `cargo clean --target-dir <dir>` from that clone's `rust/` |
| benchmark arm `cargo-target` (`~/.wasm-agent/benchmarks/<run>/<arm>/cargo-target`) | **21 dirs, 4,937 MiB total, avg 235 MiB** (7 edit-workflow runs x 3 arms) inside the 7,504 MiB above, at 14:00 | yes; `manifest.json`, `report.json` and logs are evidence and stay | `cargo clean --target-dir <run>/<arm>/cargo-target` |
| `openclaw:/local/projects/wasm-agent/rust/target` | **5,567 MiB** at 17:00 UTC | yes | same command on that host |
| `openclaw` node worktree `/local/projects/wasm-agent-managed/rust/target` | **597 MiB** at 17:05 UTC | yes; the worktree is not | `cargo clean --manifest-path <worktree>/rust/Cargo.toml` |
| macOS `rust/target`, Xcode `DerivedData` | not measured | - | measure first; no number from this file |

Rules for every row:

- **Keep the target an active build uses.** A target is in use when `.cargo-lock` exists inside it, or
  a live cargo/rustc process names it. Check before cleaning, and skip + report if either is true:
  ```bash
  ls rust/target/.cargo-lock 2>/dev/null                 # present while cargo builds
  ps -eo pid,args | grep -E '[c]argo|[r]ustc'           # Linux / macOS
  powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object Name -match 'cargo|rustc' | Select-Object ProcessId,CommandLine"
  ```
- **Prefer `cargo clean --target-dir <dir>` to deleting the directory by hand.** Cargo takes its own
  lock while cleaning; a hand `rm -rf` under a live build is how a half-written target becomes a
  wrong error later.
- **What a rebuild costs** (documented measurement, not re-run today): one `cargo build --release
  --offline` left **930,446,579 B (0.87 GiB)** of target in **192 s**; one full `scripts/test.sh` left
  **1,045,916,377 B (0.97 GiB)** and took **1119 s (~19 min)**, measured 2026-09-30 on `ab827c8` and
  recorded in `scripts/check-disk-floor.sh`. Rebuilding a 2-5 GiB target is a gate, not a probe: clean
  `debug`/`incremental` first and state the cost before the release target.
- **`scripts/reclaim-disk.mjs` is the repository's report-first pass** for managed session worktrees'
  `rust/target` and bounded temp families. Run it (report) before a hand clean; `--apply` removes only
  the subset it proves ended and never touches the canonical checkout or a live session's tree.

### Tier 3 - a service stops, or a virtual disk is rewritten

| Device | Item | Action | Risk |
| --- | --- | --- | --- |
| Docker (any) | dangling images | `docker image prune` | safe; measured 2026-11-10 14:02 -0300 on this node: 5.353 GB images, **4.221 GB reclaimable (78 %)**; `-a` only after naming what would be re-pulled |
| Docker (any) | unused tagged images | `docker image prune -a` | safe only after `docker system df` and after naming what would be re-pulled |
| Docker (any) | build cache | `docker builder prune` | safe |
| Docker (any) | **volumes** | **never** `docker system prune --volumes` unasked | a volume is data |
| Windows | `docker_data.vhdx` | quit Docker Desktop, then compact (section 5) | **ask first**; never while the engine runs |
| Windows | WSL `ext4.vhdx` | stop the distro, compact, `--set-sparse true` (section 5) | **ask first**; holds real work; back up only if there is room |
| Any KVM host | `*.qcow2` | shut the VM down, then `qemu-img convert` (section 5) | **ask first**; not measured here |

## 3. Docker hosts, which is what a server usually is

Measured 2026-11-03 on `nextcloud.colmeio` (Ubuntu 20.04, aarch64, `/` 45 G, **89 % used, 5.3 G
free**):

| Item | Measured | Verdict |
| --- | --- | --- |
| `/var/lib/docker` | 19 GB | the bulk of the disk |
| images | 5.1 GB total, **4.6 GB reclaimable (90 %)**; 13 dangling | `docker image prune` is the win |
| build cache | 424 kB | nothing to win |
| volumes | 6.8 GB across 154, **2 in use** | **not deletable** - Nextcloud and MySQL data live there |
| `/var/log` | 4.1 GB | journal vacuum + rotated logs |
| apt cache | 85 MB | `apt-get clean` |

Order: `docker system df` → `docker image prune` (dangling) → `docker builder prune` → re-measure
with `df -h /`. `-a` (unused tagged images) only when the operator accepts a re-pull, and never for
an image a running container uses.

What must survive on such a host: running containers' images, named volumes, `docker-compose.yml` and
its `.env`, and the certificate/config mounts.

## 4. Worktrees: list, then release, never delete

A worktree is a checkout with its own branch and drafts; its size is mostly its `rust/target`, which
is replaceable, but the tree is not. Measured 2026-11-10 14:00 -0300 on this node:
**62 registered worktrees, 32 of them prunable** (the directory is gone; `git worktree prune` clears
the metadata and frees no bytes), and **25 live worktrees under `C:/Users/Victor/wa-build` that were
clean and had a branch already an ancestor of `origin/main`, totalling 10,498 MiB**. The live but
unmerged ones (`change/int-meshc2`, `change/relay-attach`, `change/session-watch`) are **not**
releasable even when clean.

```bash
git fetch origin                                    # the ancestor test is against fresh origin/main
git worktree list --porcelain
git -C <worktree> status --porcelain                # empty = clean
git -C <worktree> rev-parse --abbrev-ref HEAD       # the branch to test
git merge-base --is-ancestor <branch> origin/main    # exit 0 = merged = releasable
git worktree remove <worktree>                      # no --force; it refuses a dirty tree
git worktree prune                                  # stale registrations only
```

Release only worktrees that are **clean, inactive and merged**; report the rest with sizes so the
operator can decide. An unlanded draft is evidence, not clutter. A managed session worktree uses
`session_worktree release` (or `scripts/reap-worktrees.mjs`), which applies the same proof. Removing
a merged worktree keeps its branch, which is fine; do not `git branch -D` as part of a disk cleanup
unless the operator asks. A `git worktree remove` that refuses is the safety working - report the
path and the first lines of `git status --porcelain`, never `--force` it away.

**Benchmark run dirs are released through git, not deleted.** If a run dir's `worktrees/` holds a
registered worktree (`git worktree list | grep <run dir>`), release it with `git worktree remove` from
the repository that registers it; the run dir's `manifest.json`, `report.json` and logs stay. Measured
2026-11-10: no benchmark path is a registered worktree of this repo and the `worktrees/` dirs are empty
(1 MiB), so the only removable part of those runs is each arm's `cargo-target` (section 2.1).

## 5. Tier 3: virtual disk images (ask first)

A `.vhdx`/`.qcow2` is a container: deleting inside the guest frees guest blocks, not the host file.
The only reclaimable part is the gap between what the guest uses and the size of the image, and only
compaction returns it. Measured on this node, 2026-11-10 13:58 -14:03 -0300:

| Image | Size on the host | What is inside | Upper bound of the gap |
| --- | --- | --- | --- |
| `%LOCALAPPDATA%/Docker/wsl/disk/docker_data.vhdx` | **32,221,691,904 B (30.0 GiB)** | `docker system df`: images 5.353 GB (4.221 GB reclaimable), volumes 568.3 MB, build cache 1.32 kB; `Containers 2, 0 active` | ~24 GiB (30.0 GiB file minus ~6 GiB of Docker data) |
| `%LOCALAPPDATA%/Packages/CanonicalGroupLimited.Ubuntu_*/LocalState/ext4.vhdx` | **41,576,038,400 B (38.7 GiB)** | guest `/`: **15 G used of 1007 G (2 %)** | ~23.7 GiB (38.7 GiB minus 15 G used); ext4 metadata makes the real gain smaller |

The gap is an **upper bound**, not a promise: the file will not shrink below the guest's used blocks,
and a compaction that returns less than the gap is a result to report.

**What must be stopped.** Docker Desktop (and its `com.docker.backend` processes), the docker-desktop
distro and the Ubuntu distro. `wsl.exe --shutdown` stops both distros; `wsl.exe --terminate Ubuntu`
stops only the guest. Verified on this node at 14:02 -0300: Docker Desktop and two
`com.docker.backend` processes were running, so this procedure always starts by quitting them, never
by compacting an attached image (`Optimize-VHD` fails on an attached vhdx).

**The idle window (rule 7).** Never under a deploy, a gate/build, or an agent turn on that device:

```bash
# /health of the node that owns the device: no live "runs" entry
ls ~/.wasm-agent/sentinel/requests       # nothing pending; no deploy in flight
ls rust/target/.cargo-lock 2>/dev/null   # no build holding a target
ps -eo pid,args | grep -E '[c]argo|[r]ustc'   # Linux; PowerShell equivalent in section 2.1 on Windows
docker ps                                # no container whose work you would stop
```

Show the exact image, its before size and that window, then **wait for an explicit go** (rule 7).
If any check is not clean, stop and say which one.

**Docker Desktop vhdx** (the `disk` directory name differs by Docker Desktop version - list it rather
than assuming)

```bash
# before, from the host that owns the file
VHDX="$(cygpath -u "$LOCALAPPDATA")/Docker/wsl/disk/docker_data.vhdx"
stat -c '%n %s' "$VHDX"
df -h /c
# 1. Quit Docker Desktop from its tray menu; confirm nothing remains:
powershell -NoProfile -Command "Get-Process 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue"
# 2. Stop the WSL distros (this is what detaches the vhdx):
MSYS_NO_PATHCONV=1 wsl.exe --shutdown
```

```powershell
# 3. Compact, elevated PowerShell (Optimize-VHD is present on this node, verified 14:02):
$vhdx = "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
Optimize-VHD -Path $vhdx -Mode Full
```

```bash
# 4. after, from the same host
stat -c '%n %s' "$VHDX"; df -h /c
# 5. start Docker Desktop again; docker system df must show the same images/volumes as before
```

**WSL Ubuntu `ext4.vhdx`**

```bash
VHDX="$(ls -1 "$(cygpath -u "$LOCALAPPDATA")"/Packages/CanonicalGroupLimited.Ubuntu_*/LocalState/ext4.vhdx 2>/dev/null | head -1)"
printf 'image: %s\n' "$VHDX"
stat -c '%n %s' "$VHDX"
MSYS_NO_PATHCONV=1 wsl.exe --terminate Ubuntu        # or --shutdown if Docker is also down
```

```powershell
# elevated PowerShell:
$vhdx = (Get-ChildItem "$env:LOCALAPPDATA\Packages\CanonicalGroupLimited.Ubuntu_*\LocalState\ext4.vhdx").FullName
Optimize-VHD -Path $vhdx -Mode Full
```

```bash
# keep it from growing back to full size:
wsl.exe --manage Ubuntu --set-sparse true            # WSL 2.6.1.0 here documents --set-sparse (wsl --help, 14:02)
```

`--set-sparse true` enables automatic reclaim for **future** growth; it is not the compaction of the
bytes already allocated - `Optimize-VHD -Mode Full` is what returns those. If `Optimize-VHD` is not
available (no Hyper-V PowerShell module), the fallback is elevated `diskpart`: `select vdisk
file="<path>"`, `attach vdisk readonly`, `compact vdisk`, `detach vdisk`, with the distro stopped.

**qcow2** (a Linux/KVM host, not this Windows node): shut the VM down, then
`qemu-img convert -O qcow2 in.qcow2 out.qcow2`, boot the guest on `out` and verify its data, then
replace `in`. **Not measured here**; say `not measured` until it is. If the guest holds work and there
is no room to export a backup (`wsl --export Ubuntu <backup>.tar`, or a qcow2 copy), **do not
compact**: a backup that cannot be written is not a backup.

**Verify the reclaimed bytes**, and report both sides: `stat -c %s` after must be smaller than
before; `df -h /c` free must rise by about the difference; the guest's `df -h /` must show the same
used bytes as before. A file that did not shrink is a result to report, never a cue to run the
procedure again harder.

## 6. When it must run before trouble

Nothing in this section runs by itself: no scheduler, watcher or job is added by this skill. These are
the moments a person or a run checks, and the numbers that say "now":

| Moment | What to run | Threshold and where it comes from | What to do |
| --- | --- | --- | --- |
| **before a build** | `bash scripts/check-disk-floor.sh` | **3.71 GiB** (3,987,386,368 B), measured 2026-09-30 and read by `scripts/test.sh` before its first cargo line | below it: do not start; run the report, free target dirs (2.1), recheck |
| **before a deploy** | the same check; the deploy's fallback-to-build reads `WA_NODE_DISK_FLOOR_BYTES` | the same 3.71 GiB default; below it a publish-less deploy refuses `refused(no_prebuilt_binary_and_disk_floor)` | below it: free first. A deploy with a matching published binary does not need the floor; one that must build does |
| **a deploy was refused for disk** | `deploy-result.json` or the Sentinel notice, looking for `refused(no_prebuilt_binary_and_disk_floor)` | the refusal names the floor and the free bytes | run the report, free build output, retry **once**; never retry unchanged |
| **a session sees `low disk: N MiB free (floor 1024 MiB)`** | `lua/core/agent.lua` emits it at run start | **1 GiB** (`WASM_AGENT_DISK_FLOOR_BYTES`, default 1024 MiB) | say it in the next message, run the report, do not start a build or a worktree; ask before tier 3 |
| **the device is at 95 %+ used, or free is below twice the floor (7.4 GiB, derived from the one-run 3.71 GiB cost)** | `df -h /` | measured today: `C:` **11.81 GiB free of 476.83 GiB (98 %)** at 14:02 -0300, floor ok; `openclaw` **2.10 GiB free of 96 GiB (98 %)** at 17:02 UTC, **below the floor** | run the report before the next build/deploy; the openclaw number already refuses a build, so the next step there is section 2.1, not a retry |

- **A node that refuses a deploy for disk** should name the report as well as the refusal:
  `scripts/clean-disk-report.sh` on Windows, `scripts/reclaim-disk.sh --report` on any tree check.
- **A session that sees a low-disk status or a refusal** should put the report's block in its answer,
  free only the build output it owns (its own worktree's target), and ask before tier 3. It must not
  delete another lane's target or worktree, and must not retry the deploy hoping the number changed.
- **A node about to start a gate** (`scripts/test.sh`) already gets the refusal at 3.71 GiB; the point
  of checking before the clone, the turn and the resolution is that those are paid for first.

## 7. Remote devices

- Every command is `ssh <host> '<cmd>'`; print before and after **from the same host**, and put the
  host name beside every number.
- Nothing destructive without an explicit go for that host and that exact target list. A capability
  probe (`hostname`, `whoami`, `df -h`) is not authority to delete.
- Passwordless sudo changes what is *possible*, not what is *allowed*: still list the targets first.
- Do not run tier 3 there while a deploy or an agent turn is active on that device.

## 8. The report

One block, and it is the deliverable:

```
disk: <device> 98% used, 2.1G free  ->  ?% used, ?G free   (floor 3.71G: REFUSED before / ok after)
deleted:  cargo target <canonical> 2.4G (rebuild ~19 min/gate) · job clone target-int 6.9G
          merged worktrees (25, wa-build) 10.2G · docker dangling images 4.2G
skipped:  wt-relay rust/target 3.1G (branch change/relay-attach not merged; target not cleaned)
          docker_data.vhdx 30.0G (tier 3: Docker Desktop not stopped, no idle window yet)
          benchmark run dirs (evidence; only their cargo-target dirs are candidates)
          docker volumes (568.3M, 1 active)
          git worktree <path> (branch not merged)
not touched: databases, volumes, installed build, sentinel evidence, repo trees
```

Every number comes from a command that was actually run. If a size was not measured, say
`not measured` rather than guessing. A tier-3 image is reported with its before size even when it is
skipped, so the next run knows what is waiting.

## 9. Traps that have already produced wrong answers

- **`0.0 MB` from PowerShell with `-ErrorAction SilentlyContinue` means "unreadable", not "empty".**
  `C:\Windows\Temp` reports 0.0 MB that way and is in fact denied; use `-ErrorAction Stop` with a
  `catch` that says `UNREADABLE`, or report no number.
- **`du` cannot read per-user ACL directories** such as `C:\$Recycle.Bin`; use the shell's own API.
- **Git Bash rewrites guest paths**: a remote/WSL `df: '…': No such file or directory` is usually the
  host's path conversion, not a broken guest. `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`.
- **A `.vhdx`/`.qcow2` keeps its size** after in-guest deletion until compaction; "prune 30 GB and get
  30 GB back" is false. `--set-sparse true` prevents future growth, it does not shrink the file.
- **`.cargo-lock` present means a build holds the target.** `cargo clean` then removes a live build's
  output; skip and report instead.
- **A worktree whose branch is merged can still be dirty.** `git worktree remove` refuses it, and that
  refusal is the answer: report the path and `git status --porcelain`, never `--force`.
- **32 of 62 registered worktrees were "prunable" on 2026-11-10**: `git worktree prune` clears dead
  metadata and frees no bytes; it is not a substitute for releasing a live merged tree.
- **A size that did not change after a cleanup is a result to report**, never a cue to retry harder.
