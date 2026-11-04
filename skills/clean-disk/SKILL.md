---
name: clean-disk
description: >-
  How to reclaim disk on any device - this node (Windows, Linux or macOS), a Linux/Docker server
  reached over SSH (a Nextcloud box, for example), or a VM behind a virtual disk. Measure first with
  cheap probes, delete only what this file names for that platform, never touch state (databases,
  node data, git worktrees, Docker volumes, installed builds), and report what was removed and what
  was skipped and why. Use it for /clean disk, for any device above ~85%, when a build fails with no
  space, or when temp/scratch/evidence has grown without bound.
---

# Reclaiming disk on any device

The rule that makes this safe is the same on every device, so it comes first; the targets differ per
platform and each one is measured, never assumed.

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
   work; a deploy needs the node idle.

## 1. Identify the device and what "the disk" is

```bash
uname -s; uname -m                 # Darwin, Linux, or (Git Bash) MINGW*/MSYS*
df -hT | sort -k5 -h | tail -8     # worst-used mounts first; -T shows fs type
```

- **Remote**: prefix every probe with `ssh <host> '…'`; measure `df -h /` *there*.
- **Plain volume / LVM**: `df -h` is the answer; `sudo vgs`, `sudo lvs` when a volume group is thin.
- **Container**: the host volume is what matters; `docker system df` and `du -sh /var/lib/docker`.
- **Virtual disk image** (`*.vhdx`, `*.qcow2`): deleting inside the guest frees guest blocks, not the
  host file. Only the gap between guest usage and image size is reclaimable, and only by compaction.

Measure only the targets named below, one `du -sm` per area. A full-tree `du` is the expensive part:
measured on this Windows node, `du -sm` across 169 worktrees took **14.5 minutes**.

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
| `~/.wasm-agent/benchmarks/*` | **not deletable as directories** - measured 2026-10-21: each run dir holds 3 registered worktrees; release through git or leave |
| `rust/target/{debug,incremental,*/deps}` | `cargo clean` is **opt-in**; say the rebuild cost out loud |
| `/_clean-disk-report.sh` (this node) | `bash scripts/clean-disk-report.sh` is the Windows dry run as one block; other devices use section 1's probes |

### Tier 3 - a service stops, or a virtual disk is rewritten

| Device | Item | Action | Risk |
| --- | --- | --- | --- |
| Docker (any) | dangling images | `docker image prune` | safe |
| Docker (any) | unused tagged images | `docker image prune -a` | safe only after `docker system df` and after naming what would be re-pulled |
| Docker (any) | build cache | `docker builder prune` | safe |
| Docker (any) | **volumes** | **never** `docker system prune --volumes` unasked | a volume is data |
| Windows | `docker_data.vhdx` | quit Docker Desktop, then compact | never while the engine runs |
| Windows | WSL `ext4.vhdx` | export backup, `--set-sparse true`, else compact | holds real work; back up first |

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

```bash
git worktree list
git branch --no-merged origin/main
git -C <worktree> status --porcelain     # dirty = keep
```

Release only worktrees that are **clean, inactive and merged**; report the rest with sizes so the
operator can decide. An unlanded draft is evidence, not clutter.

## 5. Remote devices

- Every command is `ssh <host> '<cmd>'`; print before and after **from the same host**, and put the
  host name beside every number.
- Nothing destructive without an explicit go for that host and that exact target list. A capability
  probe (`hostname`, `whoami`, `df -h`) is not authority to delete.
- Passwordless sudo changes what is *possible*, not what is *allowed*: still list the targets first.
- Do not run tier 3 there while a deploy or an agent turn is active on that device.

## 6. The report

One block, and it is the deliverable:

```
disk: <device> 89% used, 5.3G free  ->  ?% used, ?G free
deleted:  docker images (dangling, 13) 4.6G · journal >200M 1.2G · apt cache 85M
skipped:  docker volumes (154, 6.8G - 2 in use: nextcloud, mysql data)
          /var/lib/docker/overlay2 (live containers)
          git worktree <path> (branch not merged)
not touched: databases, volumes, installed build, sentinel evidence, repo trees
```

Every number comes from a command that was actually run. If a size was not measured, say
`not measured` rather than guessing.

## 7. Traps that have already produced wrong answers

- **`0.0 MB` from PowerShell with `-ErrorAction SilentlyContinue` means "unreadable", not "empty".**
  `C:\Windows\Temp` reports 0.0 MB that way and is in fact denied; use `-ErrorAction Stop` with a
  `catch` that says `UNREADABLE`, or report no number.
- **`du` cannot read per-user ACL directories** such as `C:\$Recycle.Bin`; use the shell's own API.
- **Git Bash rewrites guest paths**: a remote/WSL `df: '…': No such file or directory` is usually the
  host's path conversion, not a broken guest. `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`.
- **A `.vhdx`/`.qcow2` keeps its size** after in-guest deletion until compaction; "prune 30 GB and get
  30 GB back" is false.
- **A size that did not change after a cleanup is a result to report**, never a cue to retry harder.
