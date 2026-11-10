#!/usr/bin/env bash
# clean-disk-report.sh - the DRY RUN of skills/clean-disk/SKILL.md, as one block.
#
#   bash scripts/clean-disk-report.sh
#
# It measures and reports. It deletes NOTHING: no rm, no prune, no cargo clean, no recycle-bin
# clear, no prune of a worktree. The skill's section 1 points here, so the numbers a plan is made
# from and the numbers this file prints cannot drift apart. It also names the build-output targets
# (canonical, worktree and job-clone cargo targets, benchmark cargo-targets), the worktrees git could
# release, and the disk floor - sections 2.1, 4 and 6 of the skill.
#
# NOT EVERY MEASURED BYTE IS FREED BY A DELETE. `du` counts each inode once per invocation; a file
# whose second hard link is outside the tree is counted and frees nothing when the tree is removed.
# `measure_files` prints `apparent, reclaimable` from `stat -c %h`; every directory row is a `du`
# upper bound, not a promise. Measured 2026-11-10 on openclaw: 12/12 snap files link count 2,
# `du` 1,429 MiB, link rule 0.0 MiB (skill section 1.1).
#
# The two traps the skill records are encoded here, in the code that can get them wrong:
#
#   * a directory the measuring process was DENIED prints `UNREADABLE (access denied)` and never
#     `0 MB` (PowerShell with `-ErrorAction SilentlyContinue` reported 0.0 MB for C:\Windows\Temp,
#     which is in fact access-denied);
#   * the guest command keeps `MSYS_NO_PATHCONV=1` (and MSYS2_ARG_CONV_EXCL), or Git Bash rewrites
#     `/` into a Windows path and `wsl.exe -d Ubuntu -- df -h /` fails for the wrong reason.
#
# Every measurement is bounded (CLEAN_DISK_MEASURE_SECONDS, default 60 per measurement). There is
# no full-tree `du` over the home directory and no per-worktree `du`: worktrees are counted, not
# sized, because sizing 169 of them took 14.5 minutes when this machine was measured.
set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOME_DIR="${HOME:-/c/Users/${USERNAME:-$(id -un)}}"
WASM="${WASM_STATE_HOME:-}"
if [ -z "$WASM" ]; then
  # The state root the skill names is ~/.wasm-agent. A runtime may export WASM_AGENT_HOME pointing
  # at the home directory itself, so only trust it when that is where the state actually lives.
  if [ -d "$HOME_DIR/.wasm-agent" ]; then WASM="$HOME_DIR/.wasm-agent"
  elif [ -n "${WASM_AGENT_HOME:-}" ] && [ -d "$WASM_AGENT_HOME" ]; then WASM="$WASM_AGENT_HOME"
  else WASM="$HOME_DIR/.wasm-agent"; fi
fi
LIMIT="${CLEAN_DISK_MEASURE_SECONDS:-60}"
# A lane worktree may never have been built; rust/target then lives in the primary checkout, and
# that is the tree whose target directory the skill's numbers describe.
MAIN_TREE="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
TARGET_DIR="$REPO/rust/target"
if [ ! -d "$TARGET_DIR" ] && [ -n "$MAIN_TREE" ]; then TARGET_DIR="$MAIN_TREE/rust/target"; fi

# Windows environment paths arrive in native form; Git Bash's tools want the /c/... form.
unix_path() { cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; }
LOCAL="${LOCALAPPDATA:-$HOME_DIR/AppData/Local}"
TEMP_DIR="$(unix_path "${TEMP:-$LOCAL/Temp}")"
EXPLORER_DIR="$(unix_path "$LOCAL/Microsoft/Windows/Explorer")"
CHROME_CACHE="$(unix_path "$LOCAL/Google/Chrome/User Data/Default/Cache")"
CARGO_REGISTRY="$HOME_DIR/.cargo/registry"
# Job clones set CARGO_TARGET_DIR to $WA_PI_DIR/target-<job>; the clones' source is not a target.
PI_DIR="${WA_PI_DIR:-$HOME_DIR/wa-pi}"

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
    else if (b >= 1048576) printf "%.0f MB", b / 1048576;
    else printf "%.1f MB", b / 1048576;
  }'
}

# One named directory, measured with the skill's own targeted `du -sm` and a hard time bound. This is
# an upper bound on what a delete frees: du counts each inode once per invocation, so a hard link
# outside the tree is counted here and frees nothing when the tree is deleted (`measure_files` is the
# link-aware path, skill section 1.1).
measure_dir() {
  local path="$1" err out rc mb
  if [ ! -d "$path" ]; then printf 'absent\n'; return; fi
  err="$(mktemp)"
  out="$(timeout "$LIMIT" du -sm -- "$path" 2>"$err")"
  rc=$?
  if [ "$rc" -eq 124 ]; then printf 'TIMEOUT (%ss) - not measured\n' "$LIMIT"
  elif grep -qiE 'permission denied|access is denied' "$err"; then
    # The trap: never turn a denial into a number. A denied tree is not an empty tree.
    printf 'UNREADABLE (access denied)\n'
  elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'UNREADABLE (du exit %s)\n' "$rc"
  else
    mb="${out%%[[:space:]]*}"
    printf '%s\n' "$(human_bytes $((mb * 1048576)))"
  fi
  rm -f "$err"
}

# A named set of files (no directory walk): sentinel logs, Explorer's cache files. A file whose
# `stat -c %h` is > 1 has another hard link; deleting this name frees 0 until that link goes too, so
# report apparent bytes and reclaimable bytes separately (skill section 1.1).
measure_files() {
  local total=0 reclaim=0 found=0 f bytes links
  for f in "$@"; do
    [ -f "$f" ] || continue
    found=1
    bytes="$(stat -c %s -- "$f" 2>/dev/null)" || continue
    links="$(stat -c %h -- "$f" 2>/dev/null)" || links=1
    total=$((total + bytes))
    if [ "$links" -eq 1 ]; then reclaim=$((reclaim + bytes)); fi
  done
  if [ "$found" -eq 0 ]; then printf 'absent\n'
  elif [ "$reclaim" -eq "$total" ]; then printf '%s\n' "$(human_bytes "$total")"
  else printf '%s apparent, %s reclaimable\n' "$(human_bytes "$total")" "$(human_bytes "$reclaim")"; fi
}

# A list of named directories, each measured with the same bound, summed into one number and a count.
# Used for worktree and job-clone cargo targets: never a walk of the whole tree.
measure_dirs_sum() {
  local total=0 found=0 d out mb
  for d in "$@"; do
    [ -d "$d" ] || continue
    out="$(timeout "$LIMIT" du -sm -- "$d" 2>/dev/null)" || continue
    mb="${out%%[[:space:]]*}"
    case "$mb" in ''|*[!0-9]*) continue ;; esac
    total=$((total + mb)); found=$((found + 1))
  done
  if [ "$found" -eq 0 ]; then printf 'absent\n'
  else printf '%s (%s dirs)\n' "$(human_bytes $((total * 1048576)))" "$found"; fi
}

# The same for every directory called NAME under ROOT (benchmark arm cargo-target dirs).
measure_named_dirs_sum() {
  local root="$1" name="$2" total=0 found=0 d out mb
  if [ ! -d "$root" ]; then printf 'absent\n'; return; fi
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    out="$(timeout "$LIMIT" du -sm -- "$d" 2>/dev/null)" || continue
    mb="${out%%[[:space:]]*}"
    case "$mb" in ''|*[!0-9]*) continue ;; esac
    total=$((total + mb)); found=$((found + 1))
  done < <(find "$root" -maxdepth 3 -type d -name "$name" 2>/dev/null)
  if [ "$found" -eq 0 ]; then printf 'absent\n'
  else printf '%s (%s dirs)\n' "$(human_bytes $((total * 1048576)))" "$found"; fi
}

# A Windows directory that du cannot read but PowerShell can (WinSxS, Recycle Bin). `-ErrorAction
# Stop` plus a real catch is the whole point: a denial must not print a size.
measure_powershell_dir() {
  local path="$1" limit="$2" out rc
  if [ ! -e "$path" ]; then printf 'absent\n'; return; fi
  # WHY the error variable, not `-ErrorAction Stop`: a single per-user ACL entry (the Recycle Bin has
  # them) would abort the whole walk and hide the megabytes that ARE readable, while Plain
  # `-ErrorAction SilentlyContinue` is the recorded trap that prints `0.0 MB` for a denied tree. So:
  # collect the errors, and call the tree UNREADABLE only when nothing at all could be read.
  out="$(timeout "$limit" powershell -NoProfile -NonInteractive -Command "
    try {
      \$errors = @()
      \$items = @(Get-ChildItem -LiteralPath '$path' -Force -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable +errors)
      if (\$items.Count -eq 0 -and \$errors.Count -gt 0) { 'UNREADABLE (access denied)'; return }
      \$sum = (\$items | Measure-Object -Property Length -Sum).Sum
      if (\$null -eq \$sum) { '0' } else { [string][long]\$sum }
    } catch { 'UNREADABLE (access denied)' }
  " 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 124 ]; then printf 'TIMEOUT (%ss) - not measured\n' "$limit"
  elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then printf 'UNREADABLE (access denied)\n'
  elif printf '%s' "$out" | grep -qE '^[0-9]+$'; then printf '%s\n' "$(human_bytes "$out")"
  else printf '%s\n' "$out"
  fi
}

# The Recycle Bin has per-SID ACLs that a recursive walk cannot enter (the skill's other recorded
# trap: `du` cannot read it). The shell's own API reads the bin's flat item list, which is what the
# skill says to use; a denial throws, and then the answer is UNREADABLE, never a number.
measure_recycle_bin() {
  local out rc
  out="$(timeout "$LIMIT" powershell -NoProfile -NonInteractive -Command "
    try {
      \$shell = New-Object -ComObject Shell.Application
      \$items = @(\$shell.Namespace(10).Items())
      \$sum = 0
      foreach (\$item in \$items) { \$sum += [long]\$item.Size }
      [string]\$sum
    } catch { 'UNREADABLE (access denied)' }
  " 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 124 ]; then printf 'TIMEOUT (%ss) - not measured\n' "$LIMIT"
  elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then printf 'UNREADABLE (access denied)\n'
  elif printf '%s' "$out" | grep -qE '^[0-9]+$'; then printf '%s\n' "$(human_bytes "$out")"
  else printf '%s\n' "$out"
  fi
}

file_size() {
  local path="$1" bytes
  if [ ! -f "$path" ]; then printf 'absent'; return; fi
  bytes="$(stat -c %s -- "$path" 2>/dev/null)" || { printf 'UNKNOWN'; return; }
  human_bytes "$bytes"
}

row() { printf '%s | %s | %s\n' "$1" "$2" "$3"; }

# ---- free space: the one number that decides urgency -------------------------------------------
free_line="$(df -h /c 2>/dev/null | awk 'NR==2 {printf "%s used, %s free (%s)", $5, $4, $1}')"
if [ -n "$free_line" ]; then
  printf 'disk: %s\n' "$free_line"
else
  printf 'disk: UNREADABLE (df /c produced no row)\n'
fi

printf 'clean-disk: DRY RUN - nothing is deleted, pruned or cleaned by this script\n'
printf 'path | size | verdict\n'
floor_state="absent (scripts/check-disk-floor.sh not found)"
if [ -f "$REPO/scripts/check-disk-floor.sh" ]; then
  floor_out="$(bash "$REPO/scripts/check-disk-floor.sh" 2>&1)"; floor_rc=$?
  if [ "$floor_rc" -eq 0 ]; then
    floor_state="ok - $(printf '%s\n' "$floor_out" | awk '/^  free:/{sub(/^  free:  */,""); print; exit}')"
  elif [ "$floor_rc" -eq 1 ]; then
    floor_state="REFUSED - $(printf '%s\n' "$floor_out" | awk '/^FAIL:/{sub(/^FAIL: /,""); print; exit}')"
  else
    floor_state="UNMEASURABLE (exit $floor_rc)"
  fi
fi
row 'disk floor (3.71 GiB)' "$floor_state" \
  'below it a build or a deploy fallback is refused; free target dirs first'
row 'hard-link accounting' 'du = inode-once upper bound; stat -c %h > 1 is apparent, not reclaimable' \
  'measure_files prints apparent vs reclaimable; no directory size here promises freed bytes'
row 'session-scratch' "$(measure_dir "$WASM/session-scratch")" \
  'per session, oldest first (keep newest 5 + any open session)'
row 'benchmarks' "$(measure_dir "$WASM/benchmarks")" \
  'run dir is evidence; per-arm cargo-target is build output; worktrees via git'
row 'rust/target (canonical)' "$(measure_dir "$TARGET_DIR")" \
  'cargo clean is opt-in - say the rebuild cost out loud; debug before release'
worktree_targets=()
while IFS= read -r wt; do
  [ "$(unix_path "$wt")" = "$REPO" ] && continue
  [ -n "$MAIN_TREE" ] && [ "$wt" = "$MAIN_TREE" ] && continue
  [ -d "$wt/rust/target" ] && worktree_targets+=("$wt/rust/target")
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
row 'worktree rust/targets' "$(measure_dirs_sum "${worktree_targets[@]:-}")" \
  'build output; disposable when no .cargo-lock - the worktree and its drafts are not'
job_targets=()
for d in "$PI_DIR"/target-*; do [ -d "$d" ] && job_targets+=("$d"); done
row 'job-clone targets (wa-pi/target-*)' "$(measure_dirs_sum "${job_targets[@]:-}")" \
  'CARGO_TARGET_DIR build output; the clone source is not'
row 'benchmark cargo-target dirs' "$(measure_named_dirs_sum "$WASM/benchmarks" cargo-target)" \
  'per-arm build output; the run dir (manifest/report/logs) is evidence - worktrees via git'
row '%TEMP%' "$(measure_dir "$TEMP_DIR")" \
  'harness output; safe when no test-ui.ps1 is running'
row 'operations' "$(measure_dir "$WASM/operations")" \
  'per-call stdout/stderr; keep the newest N days (default 3)'
row 'sentinel logs' "$(measure_files "$WASM/sentinel/deploy.out" "$WASM/sentinel/deploy.log" "$WASM/sentinel/sentinel.log")" \
  'rotate, keep the last ~50 MB each; NEVER delete requests/done/failed evidence'

worktree_list="$(git -C "$REPO" worktree list --porcelain 2>/dev/null)"
worktree_count="$(printf '%s\n' "$worktree_list" | grep -c '^worktree ')"
prunable_count="$(printf '%s\n' "$worktree_list" | grep -c '^prunable')"
releasable_count=0
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  [ "$(unix_path "$wt")" = "$REPO" ] && continue
  [ -n "$MAIN_TREE" ] && [ "$wt" = "$MAIN_TREE" ] && continue
  [ -d "$wt" ] || continue
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || continue
  git -C "$wt" merge-base --is-ancestor "$branch" origin/main 2>/dev/null || continue
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
  releasable_count=$((releasable_count + 1))
done < <(printf '%s\n' "$worktree_list" | awk '/^worktree /{print substr($0,10)}')
row 'worktrees' "${worktree_count:-unknown} registered, ${prunable_count:-0} prunable, ${releasable_count} clean+merged (count only)" \
  'inactivity NOT measured; release only an idle clean+merged tree via git worktree remove'

# Docker: `docker system df` is the authority, and RECLAIMABLE is the delete candidate.
docker_df=""
docker_state="not available (docker not on PATH)"
if command -v docker >/dev/null 2>&1; then
  docker_df="$(timeout "$LIMIT" docker system df 2>/dev/null)"
  if [ -n "$docker_df" ]; then docker_state='see "docker system df" below - read RECLAIMABLE before pruning'
  else docker_state='not available (engine stopped or refused the query)'; fi
fi
row 'Docker (docker system df)' "$docker_state" 'never `docker system prune --volumes` unasked'

DOCKER_VHDX="$LOCAL/Docker/wsl/disk/docker_data.vhdx"
row 'Docker docker_data.vhdx' "$(file_size "$(unix_path "$DOCKER_VHDX")")" \
  'compaction only; Docker Desktop must be stopped first'

UBUNTU_VHDX="$(ls -1 "$(unix_path "$LOCAL")"/Packages/CanonicalGroupLimited.Ubuntu*/LocalState/ext4.vhdx 2>/dev/null | head -1)"
row 'Ubuntu ext4.vhdx' "$(file_size "${UBUNTU_VHDX:-/nonexistent}")" \
  'compaction only; back up first - it holds real work'

guest="not available (wsl.exe missing)"
if command -v wsl.exe >/dev/null 2>&1; then
  guest_out="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' timeout "$LIMIT" \
    wsl.exe -d Ubuntu -- df -h / 2>/dev/null | awk 'NR==2 {print $3 " used of " $2 " (" $5 ")"}')"
  if [ -n "$guest_out" ]; then guest="$guest_out"; else guest='UNREADABLE (no df row; wrong path, stopped distro, or no such distro)'; fi
fi
row 'Ubuntu guest / (wsl df -h /)' "$guest" \
  'the gap between guest usage and ext4.vhdx size is the only reclaimable part'

row 'Recycle Bin' "$(measure_recycle_bin)" \
  'ASK FIRST - nothing in it is restorable afterwards'
row 'WinSxS' "$(measure_powershell_dir 'C:\Windows\WinSxS' "$LIMIT")" \
  'needs elevation; report-only here'
row 'cargo registry' "$(measure_dir "$CARGO_REGISTRY")" \
  're-downloads on the next build'
row 'Explorer cache' "$(measure_files "$EXPLORER_DIR"/thumbcache_*.db "$EXPLORER_DIR"/iconcache_*.db)" \
  'Windows rebuilds it; close the Explorer window, not the service'
row 'Chrome cache' "$(measure_dir "$CHROME_CACHE")" \
  'delete the Cache dir only; never the profile directory'

if [ -n "$docker_df" ]; then
  printf '\ndocker system df (RECLAIMABLE is the delete candidate, not total):\n'
  printf '%s\n' "$docker_df"
fi
