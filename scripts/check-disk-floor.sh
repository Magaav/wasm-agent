#!/usr/bin/env bash
# The disk floor: a build refuses to start when the free space it can measure is below what a run costs.
#
# WHY. On 2026-09-30 the disk on this node reached 1.9 GB of 477 GB and nothing refused. A gate died 10.6
# seconds into its build with `There is not enough space on the disk. (os error 112)` - after its clone,
# its turn and its resolution had been paid for - and the only signal was a cargo error deep in a log. The
# same commit passed in 21.4 minutes once 16 GB was freed. The gate is a reserved serial resource with a
# queue; the disk it writes into was reserved by nobody and reported nowhere. This is the refusal: one
# number, one floor, and a refusal that names both.
#
# THE FLOOR IS A MEASUREMENT, NOT A ROUND NUMBER. One run of `scripts/test.sh` on this node, on commit
# ab827c8, in a worktree with no `rust/target` when it started (2026-09-30T10:45-11:04Z), measured on both
# sides of the run:
#
#   free space    3.98 GB   `df -Pk .` before 83,350,092 KiB and after 79,456,160 KiB: the run's own
#                            footprint end to end - the number this floor is, because it is the one that
#                            was actually consumed by a gate that then passed (`smoke ok (3 skipped)`,
#                            exit 0, 1119 s, WA_GATE_JOBS=2).
#   rust/target   0.97 GiB   measured after the run (1,045,916,377 B, 1862 files) against 0.87 GiB after
#                            `cargo build --release --offline` alone (930,446,579 B, 1672 files, 192 s):
#                            the test binaries are the difference. Cross-checked against 11 lane trees
#                            that already hold one: 0.48-4.77 GiB, median 0.97 GiB (all 11 measured, not
#                            sampled; the 4.77 GiB one is `codex`, the largest seen).
#   clone         37 MiB     working tree + .git: 9 MiB of tracked source (`du --exclude=rust/target`)
#                            plus the 28 MiB object database a `git clone` copies. The merge lane's
#                            ~1.1 GB clones measured elsewhere are *this* plus a built target, so that
#                            target is counted once, above - not twice.
#   gate home     21 MiB     the gate's own retained home (`wa-gate-home-*`) measured after this run.
#   temp families 1.2 GiB    `wa-*` entries under the OS temp directory younger than 12 h, after the run
#                            (1,288,467,244 B across 3533 entries): the run's own scratch, which the
#                            suites never remove (`scripts/check-temp-retention.mjs`).
#   -----------
#   one run       3.98 GB    the free-space delta above; the components overlap it and sum to more,
#                            because the temp entries and the target are both part of it.
#
# So the floor is 3.98 GB: the smallest number a measurement on this machine supports. It is not a round
# number, and it is not a claim about the total the node should keep - 11 lane trees holding targets and
# 13079 stale temp entries are a retention question (`scripts/reclaim-disk.mjs`), not a question about
# whether one run can finish.
#
# WHAT THIS MEASUREMENT DOES NOT SETTLE, SAID PLAINLY. It is ONE run, and it is an upper bound for a lone
# run rather than a median: two other gate runs were on the box while it ran (two fresh `wa-gate-home-*`
# beside this one), so the delta includes their writes too. The spread of a lone run is therefore
# unmeasured, and the floor errs towards refusing a run that might have squeezed in - the right direction
# for a reserved resource, and the direction the observed failure needs: the gate that died on
# 2026-09-30 did so with 1.9 GB free, and 1.9 < 3.98, so this floor refuses it. A floor below the measured
# need would not have: that is why the constant is the delta and not the target it leaves behind.
#
# WHERE IT IS READ. `scripts/test.sh` calls this before it unsets its environment and before the first
# `cargo` line, so a refusal happens before any work is paid for, and it is printed to the gate's own log
# - the same place a gate failure is visible (`skills/parallel-evolution/scripts/finish.mjs` records the
# gate's exit and its output; `scripts/gate-lane.mjs` records the run that asked).
#
#   bash scripts/check-disk-floor.sh                # the check, as the gate runs it
#   bash scripts/check-disk-floor.sh --json          # the same numbers for an alarm to read
#   bash scripts/check-disk-floor.sh --floor-bytes N # a deliberate, different floor (see --help)
#   bash scripts/check-disk-floor.sh --path DIR      # measure the filesystem a tree is on
#
# Exit code 0 when the free space is at or above the floor, 1 when it is below it (with the numbers), 2 on
# a bad argument, 3 when the free space cannot be measured at all - an unmeasurable disk is refused, never
# assumed healthy.
set -uo pipefail
cd "$(dirname "$0")/.."

# The derived floor, in bytes. Change this only with a measurement in the header.
FLOOR_BYTES=3987386368
FLOOR_METHOD="measured 2026-09-30 on ab827c8: free space fell 3,893,932 KiB across one run of scripts/test.sh, which then passed (smoke ok, 1119 s); target after 1,045,916,377 B, clone 37 MiB, gate home 21 MiB, run temp 1.2 GiB"

mode=plain
path="."
while [ $# -gt 0 ]; do
  case "$1" in
    --json) mode=json; shift ;;
    --floor-bytes) FLOOR_BYTES="${2:-}"; shift 2 ;;
    --path) path="${2:-}"; shift 2 ;;
    --help|-h)
      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "check-disk-floor: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$FLOOR_BYTES" in
  ''|*[!0-9]*) echo "check-disk-floor: --floor-bytes needs a number of bytes, got '$FLOOR_BYTES'" >&2; exit 2 ;;
esac
[ -d "$path" ] || { echo "check-disk-floor: --path is not a directory: $path" >&2; exit 2; }

# One line from `df -Pk`, in 1024-byte blocks. The fields are located from the *Capacity* field - the
# only field that is a percentage - and counted from it. `df -Pk` prints `Filesystem 1024-blocks Used
# Available Capacity Mounted on`, and the Filesystem field may itself contain spaces: this machine's
# root mount is `C:/Program Files/Git`, so a positional parse reads `$2` = `Files/git` and refuses a
# disk with 69 GiB free (`cannot measure free space at /`, exit 3). The numbers are the same ones;
# only the way they are found changes. A line whose capacity field cannot be found, or is not unique,
# is still refused rather than assumed: this file exists because "it looked fine" was wrong.
df_line="$(df -Pk "$path" 2>/dev/null | tail -n 1)"
# total is three fields before the capacity, avail the field before it, and the mount everything after
# it - so a space in the Filesystem name (or in the mount) cannot shift the numbers.
df_field() {
  printf '%s' "$1" | awk -v want="$2" '
    { cap = 0; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { if (cap) exit 1; cap = i } }
    cap < 5 { exit 1 }
    want == "total" { print $(cap - 3) }
    want == "avail" { print $(cap - 1) }
    want == "mount" { s = ""; for (i = cap + 1; i <= NF; i++) s = s (s == "" ? "" : " ") $i; print s }
  '
}
total_kb="$(df_field "$df_line" total)"
avail_kb="$(df_field "$df_line" avail)"
mount="$(df_field "$df_line" mount)"
[ -n "$mount" ] || mount="$path"
case "${total_kb}:${avail_kb}" in
  ''|*[!0-9:]*|:*|*:) echo "check-disk-floor: cannot measure free space at $path (df said: '${df_line:-nothing}')" >&2; exit 3 ;;
esac

avail_bytes=$((avail_kb * 1024))
total_bytes=$((total_kb * 1024))
gib() { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1073741824 }'; }
floor_gib="$(gib "$FLOOR_BYTES")"
avail_gib="$(gib "$avail_bytes")"
total_gib="$(gib "$total_bytes")"

if [ "$mode" = json ]; then
  ok=true; [ "$avail_bytes" -lt "$FLOOR_BYTES" ] && ok=false
  printf '{"floor_bytes":%s,"available_bytes":%s,"total_bytes":%s,"mount":"%s","path":"%s","ok":%s,"method":"%s"}\n' \
    "$FLOOR_BYTES" "$avail_bytes" "$total_bytes" "$mount" "$path" "$ok" "$FLOOR_METHOD"
  [ "$ok" = true ] || exit 1
  exit 0
fi

echo "disk floor check"
echo "  floor: ${floor_gib} GiB (${FLOOR_BYTES} B) - ${FLOOR_METHOD}"
echo "  free:  ${avail_gib} GiB of ${total_gib} GiB on ${mount}"
if [ "$avail_bytes" -ge "$FLOOR_BYTES" ]; then
  echo "  ok:    ${avail_gib} GiB >= the ${floor_gib} GiB a run needs"
  exit 0
fi
echo "FAIL: the build refused to start: it needs ~${floor_gib} GiB free space and has ${avail_gib} GiB (${FLOOR_BYTES} B needed, ${avail_bytes} B available on ${mount})." >&2
echo "FAIL: the disk refused this run, not a compiler half way through it - see the floor above for what it" >&2
echo "      measured and 'bash scripts/reclaim-disk.sh --report' for what can be freed." >&2
exit 1
