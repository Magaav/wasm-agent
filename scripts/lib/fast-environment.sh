#!/usr/bin/env bash
# "The machine, not the code" - how a check that could not run is told apart from a check that failed.
#
# Measured on wasm_the_first, 2026-11-10: under three or four concurrent sessions `scripts/fast.sh`
# produced `cannot fork: Input/output error`, `CreateProcessW failed ... errno 5` and exits 125/126.
# Those are the Windows fork limits, not a verdict on the tree, and they were indistinguishable from a
# regression in the log - one landing (queue row #8) was rolled back for one, and a `relay_busy`
# outage of about ten minutes is attributed to the same starvation.
#
# One implementation, two users:
#   * `scripts/fast.sh` - classifies a failing row here, and re-runs the environmental ones ONCE, one
#     at a time (`wa_environment_retry`), after the parallel batch has ended;
#   * `scripts/test-fast-environment.mjs` - runs `wa_environment_kind` and `wa_environment_retry`
#     against fixture commands that fail the way a starved machine fails, and checks that a real
#     failure is never classified as one.
#
# The rule is deliberately narrow. Only a system-level signature in the row's LAST line, or the shell's
# own "cannot execute" exits (125/126), count. A test's own assertion message almost never ends in
# `cannot fork`, so a real failure stays a real failure; and an environmental verdict is never a pass:
# `scripts/fast.sh` exits 3 and the landing queue treats it as "retry", not as "the code is good".

# The signatures, one per line as `pattern;;reason`. Extended regular expressions, matched against the
# failing row's last output line. `;;` is the separator because the patterns themselves use `|`.
WA_FAST_ENVIRONMENT_SIGNATURES='
cannot fork(\(|:|,|\.|$);;cannot fork
CreateProcessW failed;;CreateProcessW failed
Input/output error;;Input/output error (EIO from fork)
Resource temporarily unavailable;;fork refused (EAGAIN)
Cannot allocate memory;;out of memory
No space left on device;;no space left on device
Too many open files;;too many open files
mkdir -p .* -> nil;;a scratch home could not be made
'

# The reason a line is the machine rather than the code, or nothing (returns 1).
wa_environment_reason() { # <text>
  local text=${1-} pattern reason
  while IFS= read -r line; do
    [ -n "${line:-}" ] || continue
    pattern=${line%%;;*}; reason=${line#*;;}
    if printf '%s' "$text" | grep -qE "$pattern"; then printf '%s' "$reason"; return 0; fi
  done <<< "$WA_FAST_ENVIRONMENT_SIGNATURES"
  # `errno 5` alone is too common in ordinary output to accept as a signature; it is only the machine
  # when the line also names the syscall (CreateProcessW/exec) that returned it.
  if printf '%s' "$text" | grep -qE '(CreateProcessW|exec|spawn|posix_spawn)[^|]*errno 5\b|errno 5\b[^|]*CreateProcessW'; then
    printf 'spawn failed (errno 5)'; return 0
  fi
  return 1
}

# `environment` when this failing row never produced a verdict, `code` when the code is what failed.
wa_environment_kind() { # <exit code> <last line of the row's output>
  local code=${1-} text=${2-}
  if [ "$code" = 125 ] || [ "$code" = 126 ]; then printf 'environment'; return 0; fi
  if wa_environment_reason "$text" >/dev/null 2>&1; then printf 'environment'; return 0; fi
  printf 'code'
}

# Run a row once; if it failed in a way that is the machine, run it again ONCE, serially, and say which
# happened. The caller passes a command that writes the row's output to stdout; the second attempt runs
# with WA_FAST_SERIAL=1 and WA_FAST_JOBS=1 so a runner that reads them runs alone.
#
# Sets WA_FAST_RETRY to one of:
#   passed             - the first attempt succeeded
#   retried            - the first attempt was environmental, the serial retry passed
#   environment        - the first attempt was environmental, the serial retry was too (still blocked)
#   failed             - a check failed for a reason that is the code
# Returns the last exit code.
wa_environment_retry() { # <label> <log file> <command...>
  local label=$1 log=$2; shift 2
  local code kind last
  WA_FAST_RETRY=failed
  : > "$log"
  "$@" > "$log" 2>&1; code=$?
  if [ "$code" = 0 ]; then WA_FAST_RETRY=passed; return 0; fi
  last=$(last_line_of "$log")
  kind=$(wa_environment_kind "$code" "$last")
  if [ "$kind" != environment ]; then WA_FAST_RETRY=failed; return "$code"; fi
  printf 'fast: ENVIRONMENT %s (exit %s: %s) - retrying once, serially\n' \
    "$label" "$code" "$(wa_environment_reason "$last" || printf 'exit %s' "$code")"
  WA_FAST_SERIAL=1 WA_FAST_JOBS=1 "$@" > "$log" 2>&1; code=$?
  if [ "$code" = 0 ]; then WA_FAST_RETRY=retried; return 0; fi
  last=$(last_line_of "$log")
  if [ "$(wa_environment_kind "$code" "$last")" = environment ]; then
    WA_FAST_RETRY=environment
    printf 'fast: ENVIRONMENT %s still cannot run after the serial retry (exit %s: %s)\n' \
      "$label" "$code" "$(wa_environment_reason "$last" || printf 'exit %s' "$code")"
  else
    WA_FAST_RETRY=failed
  fi
  return "$code"
}

# The row's verdict line: runners print one summary line last, so the tail is the right window to look
# for a system-level signature in (and the wrong window for a test's own long output).
last_line_of() { # <file>
  # A file that is not there has no last line, and saying so on the runner's stderr would put a stray
  # `environment: ...: No such file or directory` in the middle of a verdict table (the shell names its
  # own exported-function frame `environment`). The caller reads an empty line and decides.
  [ -f "$1" ] || return 0
  tr -d '\000' < "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-400
}

# ---- the command line, for the test and for a session that wants a verdict on a log ---------------
#   bash scripts/lib/fast-environment.sh kind   <exit> <file|->   -> environment | code
#   bash scripts/lib/fast-environment.sh reason <file|->          -> a reason, or nothing (exit 1)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  command_name=${1-}; shift || true
  case "$command_name" in
    kind)
      code=${1-}; shift || true; source=${1:--}
      if [ "$source" = '-' ]; then text=$(cat); else text=$(last_line_of "$source"); fi
      wa_environment_kind "$code" "$text" ;;
    reason)
      source=${1:--}
      if [ "$source" = '-' ]; then text=$(cat); else text=$(last_line_of "$source"); fi
      wa_environment_reason "$text" || exit 1 ;;
    *)
      echo "usage: fast-environment.sh kind <exit> <file|-> | reason <file|->" >&2; exit 2 ;;
  esac
fi
