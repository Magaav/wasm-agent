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

## 4. The report

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
