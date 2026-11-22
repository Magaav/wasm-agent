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
#     the TEN parts of the landing machine's own row (`scripts/test-land-*.lua`). A narrowed run that dropped
#     the probe - or one land part - could go green saying less than a full run, which is the failure the
#     fast path's own header exists to prevent;
#   * a requested row that is not a candidate (excluded by scripts/fast-path.exclude, misspelled, or gone) is
#     a REFUSAL by name, never a silent omission: a plan that asks for a row the runner cannot run has to be
#     fixed, not quietly obeyed;
#   * the contract checks inside `scripts/fast.sh` (`prompt-docs`, `instructions`, `landing-queue`,
#     `landing-baseline`, `fast-binary`, `fast-environment`, `fast-result`, `install-front-door`, the
#     component-provisioning assertions) are not narrowable at all - they are lines in the runner, so a
#     narrowed run still executes every one of them.
#
# Sourced by scripts/fast.sh; exercised by scripts/test-fast-rows.sh (no node, no cargo, seconds).
# THE NEVER-DROPPED ROWS. Two kinds, and a third entry is only added with the evidence for it:
#
#   * the row-environment probe and the ten `test-land-*.lua` parts: the run's own correctness and the landing
#     machine's own row. A narrowed run that lost any of them would go green saying less than a full one;
#   * WHOLE-TREE ROWS: a row whose verdict depends on files it does not name, because the set it judges is
#     enumerated from the repository - "every reachable module's refusal codes", "every tool's declared
#     schema". Path-based narrowing cannot map such a row to a change made somewhere else in its set, so a
#     round that adds one member never selects it, and main goes red in a row that round did not run: 21/11,
#     change/wa-fonts added lua/core/agent_control.lua and its refusal codes, its gate ran "121 of 294 Lua
#     rows", scripts/test-refusal-contract.lua was not one of them, and main was red from bfad4f8f - the
#     next innocent mission whose rows included that row paid for it twice (855 s) and then sat stopped.
#
# HOW THESE WERE FOUND, so the list can be extended the same way (21/11): the Lua rows were scanned for the
# two shapes that enumerate the tree rather than a named file - (1) a shell/directory listing of the repo
# (`ls lua`, `find lua`, `rg --files`, `git ls-files` without a pathspec, a `%w+/*` glob over lua/), which
# found scripts/test-refusal-contract.lua reading the generated lua/core/refusal_codes.lua; and (2) a check
# quantified over a NAMESPACE whose members other rounds add ("every tool", "each tool", "the whole
# catalogue"), which found scripts/test-tool-schema-fidelity.lua and scripts/test-codemode-parity.lua.
# scripts/test-fast-rows.sh proves the pairing in the other direction too: any row that reads a path
# scripts/generators.txt declares as generated MUST be in this list, or the row fails and names it.
wa_fast_core_rows() {
  # THE LAND ROW IS TEN rows since 22/11 (mission main-green-2, item 2): it was 655 checks and 55 s in ONE
  # row, which the fast path may never drop, so every narrowed run paid it - and on a busy machine it grew
  # past the 120 s watchdog ("no verdict within 120s", land261 and main-health, 8 rows in parallel). The
  # cases were already independent fixtures, so they are ten rows by subject now (the harness they share is
  # scripts/lib/land-row.lua), each under 11 s alone. EVERY part is listed: dropping one would go green
  # saying less than a full run, which is the failure this list exists to prevent.
  printf '%s\n' scripts/test-fast-row-environment.lua \
    scripts/test-land-plan.lua scripts/test-land-resume.lua scripts/test-land-sign.lua \
    scripts/test-land-review.lua scripts/test-land-rows.lua scripts/test-land-resume-19-11.lua \
    scripts/test-land-marks.lua scripts/test-land-release.lua scripts/test-land-gate-rows.lua \
    scripts/test-land-until.lua \
    scripts/test-refusal-contract.lua scripts/test-tool-schema-fidelity.lua scripts/test-codemode-parity.lua
}

# The rows this tree's fast path would run, one repo-relative path per line, cwd = the tree root: every
# scripts/test-*.lua except the ones scripts/fast-path.exclude declares not run. This is the ONE row
# inventory - scripts/fast.sh builds its lua.list with it, and wa land's planner (lua/core/land.lua,
# M.row_inventory) draws every row it requests from it. A planner that keeps its own idea of "runnable" asks
# for a row this runner refuses, which is a whole round gated on zero tests (fast_narrow:unknown_row,
# measured land-20261118T172243Z-666a59cf and land-20261118T173351Z-2a481142).
wa_fast_row_candidates() {
  local excluded f
  excluded=$(sed -n 's/^\(scripts\/test-[^ #]*\.lua\).*/\1/p' scripts/fast-path.exclude 2>/dev/null)
  for f in scripts/test-*.lua; do
    [ -f "$f" ] || continue
    # A HERE-STRING, NOT A PIPE (measured 19/11: under `set -o pipefail` this read is a race - `grep -q`
    # exits at the first match, the printf on the other end of the pipe dies of SIGPIPE, and the PIPELINE
    # then reports failure, so an excluded row was printed as a CANDIDATE. It fired in 4 of 12 concurrent
    # runs and read as a corrupt inventory; the inventory was correct all along. `<<<` gives grep the same
    # words with no second process to signal.
    grep -qxF "$f" <<< "$excluded" || printf '%s\n' "$f"
  done
}

# The complement of wa_fast_row_candidates as 'row<TAB>why': every row scripts/fast-path.exclude keeps out of
# the run, with the comment that says why (the same sed pattern, so the two lists cannot disagree). wa land
# prints these in its plan as "not a gate row: <reason>" instead of requesting them.
wa_fast_row_skips() {
  local row line
  while IFS= read -r line; do
    row="${line%%	*}"
    [ -f "$row" ] || continue
    printf '%s\n' "$line"
  done < <(sed -n 's/^\(scripts\/test-[^ #]*\.lua\)[[:space:]]*\(#\)\{0,1\}[[:space:]]*\(.*\)$/\1	\3/p' scripts/fast-path.exclude 2>/dev/null)
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
