#!/usr/bin/env bash
# Which Lua rows a NARROWED fast-path run executes, and which rows it may never drop.
#
# WHY. `wa land` plans a round from the paths that changed: a round that touches two Lua modules does not
# need all ~140 Lua rows, and a round that touches a document needs almost none of them. The narrowing is a
# request the planner makes, so it must not be able to weaken the run by accident - three rules, all
# enforced here rather than trusted from the caller:
#
#   * the ALWAYS-ON core rows run whatever the request says (`wa_fast_core_rows`): the row-environment probe,
#     which is the one row that can say whether the variables the runner sets arrive inside the node, and
#     `scripts/test-land.lua`, the landing machine's own row. A narrowed run that dropped the probe could go
#     green saying less than a full run, which is the failure the fast path's own header exists to prevent;
#   * a requested row that is not a candidate (excluded by scripts/fast-path.exclude, misspelled, or gone) is
#     a REFUSAL by name, never a silent omission: a plan that asks for a row the runner cannot run has to be
#     fixed, not quietly obeyed;
#   * the contract checks inside `scripts/fast.sh` (`prompt-docs`, `instructions`, `landing-queue`,
#     `landing-baseline`, `fast-binary`, `fast-environment`, `fast-result`, `install-front-door`, the
#     component-provisioning assertions) are not narrowable at all - they are lines in the runner, so a
#     narrowed run still executes every one of them.
#
# Sourced by scripts/fast.sh; exercised by scripts/test-fast-rows.sh (no node, no cargo, seconds).
wa_fast_core_rows() {
  printf '%s\n' scripts/test-fast-row-environment.lua scripts/test-land.lua
}

# <candidate-list-file> <request-file> -> the rows to run, one per line, core first, on stdout.
# 2 with `fast_narrow:<what>` on stderr when the request asks for a row this run cannot execute.
wa_fast_row_filter() {
  local candidates="${1:-}" request="${2:-}" row want
  [ -f "$candidates" ] || { printf 'fast_narrow:candidates_unreadable: %s\n' "$candidates" >&2; return 2; }
  [ -f "$request" ] || { printf 'fast_narrow:request_unreadable: %s\n' "$request" >&2; return 2; }
  if [ "$(grep -c . "$request" 2>/dev/null || true)" = 0 ]; then
    printf 'fast_narrow:empty_request: %s names no row, which would run nothing at all\n' "$request" >&2; return 2
  fi
  local selected=" "
  # The core rows first, and only when this tree actually has them (a fork of this runner may not).
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    grep -qxF "$row" "$candidates" || continue
    case "$selected" in *" $row "*) continue ;; esac
    selected="$selected$row "; printf '%s\n' "$row"
  done < <(wa_fast_core_rows)
  while IFS= read -r want; do
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    [ -n "$want" ] || continue
    grep -qxF "$want" "$candidates" || {
      printf 'fast_narrow:unknown_row: %s is not a row this run can execute (not a scripts/test-*.lua, or listed in scripts/fast-path.exclude)\n' "$want" >&2
      return 2
    }
    case "$selected" in *" $want "*) continue ;; esac
    selected="$selected$want "; printf '%s\n' "$want"
  done < "$request"
  return 0
}
