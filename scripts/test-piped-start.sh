#!/usr/bin/env bash
# PIPED START: `printf 'hi\n' | wa chat` prints its first line without a terminal.
#
# WHY THIS ROW EXISTS. `scripts/speed/probe-cold-start.py` measures the prompt coming up in a PTY, and says why:
# a pipe has no window size and no tty reader, so the process takes a different path. That path is the one every
# worker, every `--once` call and every script that drives `wa` takes - and on 23/11 it printed nothing for over
# four seconds while the same command in a pty printed its header at 329 ms. Nothing in the tree timed the pipe,
# so nothing caught it.
#
# WHAT IS MEASURED, EXACTLY. Spawn `wa chat --once` with stdin and stdout on pipes - not a pty - and time the
# moment its FIRST line reaches the reader. `--once` is used because it ends on its own; the quantity is the
# start, not the turn.
#
# HOW THE NUMBER IS MADE STABLE (the discipline scripts/speed/speed-board.sh already uses, because a timing row
# that flakes is worse than no row):
#   * MEDIAN of the samples, never a single sample and never the mean;
#   * ONE WARM-UP DISCARDED, since the first run pays the process's own cold state;
#   * a LOAD GUARD: above 1.5 load units per core the row says `guarded` and passes without a number, because a
#     start measured at load 12 on 16 cores is a property of the machine and not of the commit;
#   * the BOUND is 2.5 s - well above the ~1.2 s this measured on main (28/11) and far below the 4 s that was
#     the 23/11 regression. A change that costs a second of piped start is a RED row, not a slow Tuesday.
set -u
BIN=${WA_BIN:-$(command -v wa || true)}
if [ -z "${BIN:-}" ] || [ ! -x "$BIN" ]; then echo "piped start: no wa binary (set WA_BIN)" >&2; exit 2; fi
SAMPLES=${WA_PIPED_SAMPLES:-5}
BOUND_MS=${WA_PIPED_BOUND_MS:-2500}
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
GUARD=$(awk -v l="${LOAD:-0}" -v c="$CORES" 'BEGIN { print (l > 1.5 * c) ? "yes" : "no" }')
if [ "$GUARD" = "yes" ]; then echo "piped start: guarded (load ${LOAD} on ${CORES} cores) - not measured"; exit 0; fi
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wa-piped-XXXXXX")
export HOME="$HOME_DIR" WASM_AGENT_HOME="$HOME_DIR" WA_GRAPH_WATCH=0 WASM_AGENT_MANAGED=0
now_ms() { date +%s%N | cut -c1-13; }
first_line_ms() {
  local s e
  s=$(now_ms)
  printf 'hi\n' | timeout 30 "$BIN" chat --once 2>/dev/null | { IFS= read -r _line || true; }
  e=$(now_ms)
  echo $(( e - s ))
}
# the warm-up, discarded on purpose
printf 'hi\n' | timeout 30 "$BIN" chat --once >/dev/null 2>&1 || true
SAMPLES_MS=()
for _ in $(seq 1 "$SAMPLES"); do SAMPLES_MS+=("$(first_line_ms)"); done
MEDIAN=$(printf '%s\n' "${SAMPLES_MS[@]}" | sort -n | awk '{ a[NR]=$1 } END { print (NR%2) ? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2) }')
rm -rf "$HOME_DIR"
echo "piped start: median ${MEDIAN} ms of ${SAMPLES} (samples: ${SAMPLES_MS[*]}), bound ${BOUND_MS} ms, load ${LOAD} on ${CORES} cores"
if [ "${MEDIAN:-0}" -gt "$BOUND_MS" ]; then echo "piped start: RED - ${MEDIAN} ms exceeds ${BOUND_MS} ms" >&2; exit 1; fi
echo "piped start: ok"
