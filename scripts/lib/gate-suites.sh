#!/usr/bin/env bash
# The per-suite half of the gate's instrumentation. Sourced by scripts/test.sh; the record shape and the
# lower-bound caveat are in gate-suite.mjs, the declarations are in gate-suites.mjs.
#
# Why per suite: a phase table can say "subagents: 243 s" and still not say which of the suites inside it
# is compute-bound and which is waiting on a port, a lock or a model - and only the second kind is ever
# an argument for moving work around. Nothing here reschedules, batches or parallelises anything: every
# suite runs exactly where it ran before, through a wrapper that changes nothing but the measurement.
gate_suites_summary() {
  local out="${GATE_SUITES_JSON:-}"
  if [ -z "$out" ] && [ -n "${GATE_HOME:-}" ]; then out="$GATE_HOME/gate-suites.json"; fi
  if [ -z "$out" ]; then out="${GATE_SUITES_JSONL}.summary.json"; fi
  if [ ! -s "${GATE_SUITES_JSONL:-/nonexistent}" ]; then
    printf 'gate suites: no per-suite records were written (GATE_SUITES_JSONL=%s)\n' "${GATE_SUITES_JSONL:-unset}"
    return 0
  fi
  printf 'gate suites (wall time and CPU inside each suite own process tree, lower bound):\n'
  if node scripts/lib/gate-suites.mjs summarize "$GATE_SUITES_JSONL" "$out" "$(pwd)"; then
    printf 'gate suites json: %s\n' "$out"
  else
    printf 'gate suites: the summary could not be produced; the records are %s\n' "$GATE_SUITES_JSONL" >&2
  fi
  return 0
}
