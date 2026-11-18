#!/usr/bin/env bash
# Per-build wall clock, printed once in the fast path's summary.
#
# WHY. ARCHITECTURE.md ("Modules over the monolith") keeps a seam only for a measured win, and the
# first one it names is build time: a module is worth being a module because a change to it compiles
# and ships without rebuilding the core. "Modules compile faster" is a claim about a number, so the
# runner that already compiles every crate a change touches and every component the rows need prints
# what each of those builds cost, in its summary, next to the verdict.
#
# WHAT IT IS NOT. A gate. There is no threshold, no comparison with a previous run and nothing fails
# on it: a slow crate is a fact to read, not a build to block. A number that could fail a landing
# would be tuned against, and then it would stop meaning anything.
#
# WHAT IT MEASURES, exactly. The wall clock of the cargo invocation that compiled that crate or
# component in THIS run. A crate that nothing changed compiles nothing and reports a couple of
# tenths of a second, and that is the honest reading of an incremental build: the cost of the change,
# not of a cold tree. The two are never confused because the note says how many units the compiler
# actually built (0 = nothing to do, a warm row).
wa_build_times_file=
wa_build_times_init() { # <path>
  wa_build_times_file=$1
  [ -n "$wa_build_times_file" ] || return 0
  : > "$wa_build_times_file" 2>/dev/null || wa_build_times_file=
}
wa_build_time_record() { # <kind> <name> <ms> <note>
  [ -n "${wa_build_times_file:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "${4:-}" | tr '\t\n' '  ')" >> "$wa_build_times_file" 2>/dev/null || true
}
wa_build_time_units() { # <cargo log> -> units the compiler built (0 = nothing to do)
  local count
  count=$(grep -c '^ *Compiling ' "${1:-/nonexistent}" 2>/dev/null) || count=0
  printf '%s' "${count:-0}"
}
wa_build_time_note() { # <cargo log>
  local units
  units=$(wa_build_time_units "${1:-/nonexistent}")
  if [ "$units" = 0 ]; then printf 'warm, nothing to compile'; else printf '%s unit(s) compiled' "$units"; fi
}
# Printed even when the ledger is empty: a run that compiled nothing says so, because a summary that is
# silently absent reads like a summary that was not implemented.
wa_build_time_summary() {
  if [ ! -s "${wa_build_times_file:-/nonexistent}" ]; then
    echo "fast: build times: nothing was compiled in this run, so there is nothing to measure (no crate touched; components skipped or warm)"
    return 0
  fi
  local count
  count=$(wc -l < "$wa_build_times_file" 2>/dev/null || echo 0)
  echo "fast: build times, measured in this run ($count build(s), slowest first; no gate - ARCHITECTURE.md, 'Modules over the monolith'):"
  sort -t"$(printf '\t')" -k3,3nr "$wa_build_times_file" | awk -F"$(printf '\t')" '{ printf "fast:   %-9s %-30s %8.1fs  %s\n", $1, $2, $3/1000, $4 }'
}

