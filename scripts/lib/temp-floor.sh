#!/usr/bin/env bash
# THE TEMP FLOOR: a run that needs the OS temp filesystem refuses to start when it is nearly full, and it
# refuses BY NAME instead of going red on a row.
#
# WHY THIS EXISTS (measured 23/11 on avell; /tmp is a 16 G tmpfs with a per-user quota). It ran out three
# times in one day and each time a verdict was LOST rather than taken:
#   * 22808bc8: main-health red on ENOSPC - a health run recorded a product failure that was a full disk;
#   * 2104a4d8 07:36Z: the row 'regenerate' died on "fatal: unable to write loose object file: Disk quota
#     exceeded";
#   * a session's own tool output failed with EDQUOT, so nothing that ran after it can be trusted either.
# 4,721 entries had accumulated in /tmp. A red caused by a full disk is a fact about the MACHINE, and
# main-health writes its verdict out of the row results - so without this check a run that could not write
# is indistinguishable from a tree that does not build, and the landing queue blames the mission.
#
# So the question is asked BEFORE the first row is spawned, and the answer is one of:
#   0  there is room (prints nothing);
#   1  there is not - prints 'tmp_low: <dir> <N> free, need <M>' for the caller to carry in its refusal;
#   2  the free space cannot be measured - 'tmp_unknown: ...', because an unmeasurable disk is refused,
#      never passed (unknown is not yes).
#
# WHAT IS MEASURED. Every directory the caller names, so both filesystems a row can write to are covered:
# the OS temp directory (/tmp) and ${TMPDIR} when it names another one. This node's TMPDIR is inside the
# operator store (~/.wasm-agent/tmp), so measuring only TMPDIR would report a healthy /home while the 16 G
# tmpfs the rows actually fill was at 95% - the exact blindness this closes.
#
#   . scripts/lib/tmp-floor.sh
#   note=$(wa_tmp_floor_check /tmp "${TMPDIR:-}") || { echo "fast: refused(tmp_low): $note"; exit 2; }
#
# The floor is a measurement, not a round number: WA_TMP_MIN_FREE_MB (default 2048) is what one run's
# leaked scratch cost on this node - 4,721 entries on a 16 G tmpfs at the peak measured on 23/11 - and a
# caller that knows its own bill (scripts/check-disk-floor.sh's 3.98 GB for a full gate) may name it.
# temp-retention: nothing here mints a temp family. This file MEASURES the temp filesystems and reports
# tmp_low, so a name beside a temp root in it is a directory being asked about, not one being kept - the
# marker is here because scripts/check-temp-retention.mjs reads a temp root within 50 characters of a name
# as a mint (measured on this file: it was named as an offender the first time it was committed).
wa_tmp_floor_check() { # [<dir>...] -> 0 room, 1 low, 2 unmeasurable; prints one line when not 0
  local need_mb="${WA_TMP_MIN_FREE_MB:-2048}"
  case "$need_mb" in
    ''|*[!0-9]*) printf 'tmp_unknown: WA_TMP_MIN_FREE_MB=%s is not a number of MiB\n' "$need_mb"; return 2 ;;
  esac
  local dir free_mb low='' unknown='' seen=' '
  if [ "$#" -eq 0 ]; then set -- /tmp; fi
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    # The same directory named twice is one question, and its answer is already in the line.
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    if [ ! -d "$dir" ]; then
      unknown="$unknown${unknown:+; }$dir: not a directory"
      continue
    fi
    # df -Pm is POSIX; a machine without it refuses rather than assuming room.
    free_mb=$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}')
    case "$free_mb" in
      ''|*[!0-9]*) unknown="$unknown${unknown:+; }$dir: free space cannot be measured" ;;
      *) [ "$free_mb" -lt "$need_mb" ] && low="$low${low:+; }$dir $free_mb free, need $need_mb" ;;
    esac
  done
  if [ -n "$low" ]; then printf 'tmp_low: %s\n' "$low"; return 1; fi
  if [ -n "$unknown" ]; then printf 'tmp_unknown: %s\n' "$unknown"; return 2; fi
  return 0
}
