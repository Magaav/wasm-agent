#!/usr/bin/env bash
# Gate phase timing - instrumentation, not a redesign.
#
# WHY THIS EXISTS. A 21-minute gate log carried verdicts and no durations at all (checked), so the only
# way to say where a cold gate spends its time was to guess, and the guess was wrong: the merge lane's
# gate recompiles a fresh clone's tree on every landing (docs/EVOLUTION.md, "Gate parallelism" - a solo
# cold gate measured 1145.9 s against 528.1 s warm on the same tree, with 253.0 CPU-s charged inside the
# cold gate's own process tree against 11.2 warm). Sourced by scripts/test.sh, which calls
# `gate_phase_begin <name>` at each phase boundary; this file prints the phase table into that log and
# writes the same table as JSON.
#
# THE CONTRACT THAT MAKES IT SAFE IN A GATE THAT LANDS DELIVERIES:
#   * It changes WHEN nothing and WHAT nothing. No check is added, removed, reordered, skipped,
#     short-circuited or made parallel: the verdict line, the skip count and every exit code are the
#     ones scripts/test.sh already produced. A phase boundary is a call between two existing commands.
#   * The table is printed BEFORE the verdict line. The verdict line must stay the log's last content -
#     `scripts/merge-lane.mjs` and `skills/parallel-evolution/scripts/finish.mjs` both anchor `smoke ok`
#     to the end of the log (a trailing line would read as "no verdict" and fail a passing gate).
#   * Timing never fails the gate. A clock that cannot be read reads 0, visibly broken, rather than
#     exiting; the EXIT trap only reports, and reports once.
#   * The JSON is also written to a file, so a holder that dies mid-gate still leaves the phases it
#     reached. `GATE_PHASES_JSON` names the file; the name is deliberately not `WA_*`, because
#     scripts/test.sh's own environment fence unsets every `WA_*` variable it did not ask for - the same
#     reason the gate lane's admission marker is spelled `GATE_LANE_HELD`.
#
# Read the table as: each row is the wall time of the segment that STARTS at that marker and ends at the
# next one. `total_ms` is the sum of the rows, which is the gate from the first marker onward - the
# environment fence and the isolated home above the first marker are not timed.

GATE_PHASE_NAMES=()
GATE_PHASE_MS=()
GATE_PHASE_NAME=""
GATE_PHASE_MARK=0
GATE_PHASE_TOTAL=0
GATE_PHASE_WRITTEN=""

# Milliseconds since the epoch, or 0 when this `date` cannot say. `%3N` is GNU; a `date` that prints it
# literally yields 0 rather than an arithmetic error under `set -e`.
gate_phase_clock() {
  local stamp=""
  stamp="$(date +%s%3N 2>/dev/null)" || stamp=""
  case "$stamp" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$stamp" ;;
  esac
}

# gate_phase_begin <name>: close the segment that is open and open the one that starts here.
gate_phase_begin() {
  local now=""
  now="$(gate_phase_clock)"
  if [ -n "$GATE_PHASE_NAME" ]; then
    GATE_PHASE_NAMES+=("$GATE_PHASE_NAME")
    GATE_PHASE_MS+=("$(( now - GATE_PHASE_MARK ))")
  fi
  GATE_PHASE_NAME="$1"
  GATE_PHASE_MARK="$now"
}

gate_phase_json() {
  local index pairs=""
  for (( index = 0; index < ${#GATE_PHASE_NAMES[@]}; index++ )); do
    pairs="${pairs}${pairs:+,}{\"name\":\"${GATE_PHASE_NAMES[index]}\",\"ms\":${GATE_PHASE_MS[index]}}"
  done
  printf '{"schema":1,"gate":"scripts/test.sh","phases":[%s],"total_ms":%s,"skipped":%s,"cargo_jobs":"%s","test_threads":"%s"}' \
    "$pairs" "$GATE_PHASE_TOTAL" "${SKIPPED:-0}" "${CARGO_BUILD_JOBS:-cargo default}" "${RUST_TEST_THREADS:-harness default}"
}

# Print the table and the machine-readable line, and write the JSON beside the gate's retained home.
# Called once, explicitly, before the verdict; the EXIT trap calls it only when a run died before that,
# so a red gate says where it got to instead of leaving an empty phase list.
gate_phase_summary() {
  local index total=0 json="" target=""
  [ -n "$GATE_PHASE_WRITTEN" ] && return 0
  if [ -n "$GATE_PHASE_NAME" ]; then
    GATE_PHASE_NAMES+=("$GATE_PHASE_NAME")
    GATE_PHASE_MS+=("$(( $(gate_phase_clock) - GATE_PHASE_MARK ))")
    GATE_PHASE_NAME=""
  fi
  for (( index = 0; index < ${#GATE_PHASE_MS[@]}; index++ )); do
    total=$(( total + GATE_PHASE_MS[index] ))
  done
  GATE_PHASE_TOTAL="$total"
  GATE_PHASE_WRITTEN=1
  printf 'gate phases (ms, in order; each row is the segment that starts at its marker):\n'
  for (( index = 0; index < ${#GATE_PHASE_NAMES[@]}; index++ )); do
    printf '  %-16s %10s\n' "${GATE_PHASE_NAMES[index]}" "${GATE_PHASE_MS[index]}"
  done
  printf '  %-16s %10s\n' 'total' "$total"
  json="$(gate_phase_json)"
  printf 'gate phases json: %s\n' "$json"
  target="${GATE_PHASES_JSON:-}"
  if [ -z "$target" ] && [ -n "${GATE_HOME:-}" ]; then target="$GATE_HOME/gate-phases.json"; fi
  if [ -n "$target" ]; then
    printf '%s\n' "$json" > "$target" 2>/dev/null || printf 'gate phases: could not write %s\n' "$target" >&2
  fi
  return 0
}
