# One row per child command, without intercepting PATH or handing POSIX paths to Node.
# Bash functions keep Windows executable arguments unchanged. Exit and output are untouched.
GATE_TIMINGS_TSV="${GATE_TIMINGS_TSV:-$(git rev-parse --git-path wa-gate-check-timings.tsv)}"
: > "$GATE_TIMINGS_TSV"
gate_command_clock() {
  local value="${EPOCHREALTIME:-}"
  if [ -n "$value" ]; then printf '%s' "${value/./}"; else printf '%s000' "$(date +%s%3N)"; fi
}
gate_run() {
  local begin end status
  begin="$(gate_command_clock)"
  if command "$@"; then status=0; else status=$?; fi
  end="$(gate_command_clock)"
  printf '%s\t%s\t%s\n' "$(( (end - begin) / 1000 ))" "$status" "$*" >> "$GATE_TIMINGS_TSV"
  return "$status"
}
