#!/usr/bin/env bash
# handoff.sh - the gate that makes "done" mean *proven* rather than *claimed*.
#
# A handoff today is a branch plus a report written by the party being judged. This
# replaces the self-assessment with evidence: it proves the branch still merges, runs the
# suites it can run, and prints a one-screen report of counts, failures, skips and errors,
# with every command the reader could re-run.
#
# Four properties it is built to hold (from the task, and from this agent's own synthesis):
#
#   1. The verdict is a count, and it cannot silently drop. A word can be grepped and
#      faked; a sum can be recomputed. A count below the recorded baseline FAILS.
#   2. Facts with pointers, never adjectives. Hashes, exit codes, counts, paths, session.
#   3. The gate signs the handoff, not the agent. What the agent believes is input.
#   4. Endings are recorded - to the extent a gate can see them. See the `running` marker.
#
# It does not write to the branch under test. The only files it touches are its own report,
# its run marker, and (only with --accept-counts) the baseline. It never merges and never
# pushes, and it rebases only when asked with --rebase: rewriting the tip of a branch under
# review changes what is under review, which this gate is supposed to be measuring.
#
# Exit 0 only if: no stage failed, no suite errored, and no count dropped.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

HANDOFF_DIR=".handoff"
REPORT="$HANDOFF_DIR/last-report.txt"
MARKER="$HANDOFF_DIR/running"
COUNTS="$HANDOFF_DIR/expected-counts"
ACCEPT_COUNTS=0
SKIP_SUITES=""
DO_REBASE=0
for arg in "$@"; do
  case "$arg" in
    --accept-counts) ACCEPT_COUNTS=1 ;;
    --skip-suites)   SKIP_SUITES="1" ;;
    --rebase)        DO_REBASE=1 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "handoff: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$HANDOFF_DIR"

# ---- verdict bookkeeping ---------------------------------------------------
# Counted, never implied. `errors` is separate from `failures` on purpose: a suite that
# died without emitting a verdict is not a failure of the code under test, and calling it
# one would blame the wrong party. It is its own outcome because it must be its own word.
FAILED=0
ERRORED=0
SKIPPED=0
declare -a SUMMARY=()
declare -a COMMANDS=()

note()  { SUMMARY+=("$1"); }
fail()  { FAILED=$((FAILED + 1));  note "FAIL  $1"; }
err()   { ERRORED=$((ERRORED + 1)); note "ERROR $1"; }
skip()  { SKIPPED=$((SKIPPED + 1)); note "SKIP  $1"; }

# ---- property 4: endings ---------------------------------------------------
# A gate that is killed leaves the `running` marker behind, and the next run reports it.
# This does not instrument the harness - it makes an *unfinished* run detectable after the
# fact, which is the honest scope. Written before anything that can die.
PREVIOUS_UNFINISHED=0
if [ -f "$MARKER" ]; then
  PREVIOUS_UNFINISHED=1
  PREVIOUS_MARKER="$(cat "$MARKER" 2>/dev/null || echo '')"
fi
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "started=$STARTED_AT"
  echo "branch=$(git branch --show-current 2>/dev/null || echo detached)"
  echo "head=$(git rev-parse HEAD 2>/dev/null || echo none)"
} > "$MARKER"
trap 'rm -f "$MARKER"' EXIT

find_tool() { command -v "$1" >/dev/null 2>&1; }

# ---- the session id --------------------------------------------------------
# From the agent trailer on the newest commit. This is the pointer back to a transcript,
# which is the whole reason the convention exists (AGENTS.md, Commit provenance).
#
# When the trailer has no session id, the gate looks in the ledger the node already keeps,
# because "unknown" is a worse answer than a pointer: an unattributable handoff is the
# thing the convention was invented to prevent. The lookup is read-only.
SESSION=""
COMMIT_MSG="$(git log -1 --format='%B' 2>/dev/null || true)"
SESSION="$(printf '%s\n' "$COMMIT_MSG" | grep -oE 'session=[0-9a-fA-F-]+' | tail -1 | cut -d= -f2 || true)"
AGENT_LINE="$(printf '%s\n' "$COMMIT_MSG" | grep -E '^Agent:' | tail -1 || true)"

SESSION_SOURCE="trailer"

# Resolve the node binary once, unconditionally: both the session lookup below and the Lua
# suites further down need it, and it must be defined even when the trailer already names
# the session (otherwise `set -u` kills the run on a path that used to work).
WA_BIN="${HANDOFF_WA:-}"
if [ -z "$WA_BIN" ]; then
  for c in "$ROOT/rust/target/release/wa" "$LOCALAPPDATA/wasm-agent/wa.exe" "$(command -v wa 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { WA_BIN="$c"; break; }
  done
fi
: "${WA_BIN:=}"

if [ -z "$SESSION" ]; then
  # Ask the node for its sessions and take the newest; that is this run. Reported as
  # inferred, not as fact, because a guess presented as a pointer is worse than none.
  if [ -n "$WA_BIN" ]; then
    SESSION="$("$WA_BIN" sessions 2>/dev/null | head -1 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)"
    [ -n "$SESSION" ] && SESSION_SOURCE="inferred from $WA_BIN sessions (newest)"
  fi
fi
[ -z "$SESSION" ] && SESSION_SOURCE="none found"

# ---- rebase ----------------------------------------------------------------
# Drift is time, not skill. A branch that ran for hours meets whatever landed meanwhile.
#
# But a rebase is not a read: it rewrites the branch's history, and this gate's whole job is
# to report on a branch somebody else is reviewing. Ran by default, it silently rewrote the
# tip under a reviewer who was reading that tip - and it did: a `model-window` review found
# the branch's tip replaced mid-review, and the diff grew 238 deletions (docs/ORCHESTRATION.md,
# ui/style.css) that belonged to main, not to the branch. Nothing was lost, but "what did
# this agent change" stopped being answerable from the tip alone, which is the one question
# the branch exists to answer.
#
# So it is opt-in: `--rebase`. Default is to *report* how far behind the branch is and leave
# the history alone. Mergeability is still checked unconditionally below, which is the
# property the rebase was there to establish and does not need a rewrite to establish.
REMOTE_MAIN=""
did_rebase="no"
REBASE_FILES=""
if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
  REMOTE_MAIN="origin/main"
elif git rev-parse --verify -q main >/dev/null 2>&1; then
  REMOTE_MAIN="main"
fi

BEFORE_REBASE="$(git rev-parse HEAD)"
# An uncommitted tree cannot be rebased without losing it, and losing it silently is the
# exact failure AGENTS.md names. So: refuse, and say which files.
DIRTY="$(git status --porcelain | head -20)"
if [ -n "$DIRTY" ]; then
  fail "uncommitted work in the tree"
  note "      $(printf '%s' "$DIRTY" | wc -l | tr -d ' ') uncommitted path(s) - commit or stash first"
elif [ -z "$REMOTE_MAIN" ]; then
  skip "no origin/main or main to compare against"
elif [ "${DO_REBASE}" != "1" ]; then
  behind="$(git rev-list --count "HEAD..$REMOTE_MAIN" 2>/dev/null || echo 0)"
  ahead="$(git rev-list --count "$REMOTE_MAIN..HEAD" 2>/dev/null || echo 0)"
  note "ok    history left alone ($ahead ahead, $behind behind $REMOTE_MAIN)"
  note "      re-run with --rebase to bring it up to date; not done by default, because"
  note "      rewriting the tip of a branch under review changes what is being reviewed"
  REBASE_SKIPPED=1
else
  if git rebase "$REMOTE_MAIN" >/dev/null 2>&1; then
    did_rebase="yes"
    note "ok    rebased onto $REMOTE_MAIN ($BEFORE_REBASE -> $(git rev-parse --short HEAD))"
  else
    # On conflict: name the files, restore the branch, and call the task unfinished.
    REBASE_FILES="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
    git rebase --abort >/dev/null 2>&1 || true
    fail "rebase onto $REMOTE_MAIN conflicts; this branch is not finished work"
    if [ -n "$REBASE_FILES" ]; then
      while IFS= read -r f; do [ -n "$f" ] && note "      conflict: $f"; done <<< "$REBASE_FILES"
    fi
  fi
fi

# ---- mergeability ----------------------------------------------------------
# Reported, not assumed. merge-tree writes a tree and tells us whether it merged.
MERGE_VERDICT="not checked"
if [ -n "$REMOTE_MAIN" ]; then
  MERGE_OUT="$(git merge-tree --write-tree "$REMOTE_MAIN" HEAD 2>&1)"
  MERGE_STATUS=$?
  MERGE_OID="$(printf '%s' "$MERGE_OUT" | head -1)"
  if [ $MERGE_STATUS -eq 0 ]; then
    MERGE_VERDICT="merges"
    note "ok    merges with $REMOTE_MAIN (tree ${MERGE_OID:0:12})"
  else
    MERGE_VERDICT="CONFLICT"
    fail "does not merge with $REMOTE_MAIN"
    printf '%s\n' "$MERGE_OUT" | grep -iE 'conflict|CONFLICT' | head -5 | while IFS= read -r l; do
      note "      $l"
    done
  fi
  COMMANDS+=("git merge-tree --write-tree $REMOTE_MAIN HEAD")
fi

# ---- suites ----------------------------------------------------------------
# Three outcomes, never two. `pass` requires a verdict line *and* exit 0: the exit code
# alone is not enough (a script that dies early can be piped into a 0), and the verdict
# line alone is not enough either. Both, or it is not a pass.
declare -A SUITE_COUNT=()
declare -A SUITE_STATE=()

# Scratch space for suites that need a database. Removed on exit; in the system temp dir so
# it can never land in the tree the gate is judging (which is what dirtied the first run).
TMPLUA="$(mktemp -d 2>/dev/null || echo "${TEMP:-/tmp}/handoff-lua-$$")"
mkdir -p "$TMPLUA"
trap 'rm -f "$MARKER"; rm -rf "$TMPLUA"' EXIT

run_suite() {
  local key="$1" label="$2"; shift 2
  local out rc start end dur verdict count
  start="$(date +%s)"
  out="$( "$@" 2>&1 )"
  rc=$?
  end="$(date +%s)"
  dur=$((end - start))

  # The per-assertion evidence, when the suite emits it: one line per check.
  count="$(printf '%s\n' "$out" | grep -cE '^(ok|OK)\b' || true)"

  case "$key" in
    smoke)   verdict="$(printf '%s\n' "$out" | grep -E '^smoke (ok|FAILED)' | tail -1 || true)" ;;
    windows) verdict="$(printf '%s\n' "$out" | grep -E 'local suite (ok|FAILED)' | tail -1 || true)" ;;
    *)       verdict="$(printf '%s\n' "$out" | grep -E '^ALL PASS$' | tail -1 || true)" ;;
  esac

  # The Windows suite states its own count on the verdict line ("local suite ok (25
  # checks)") rather than printing a line per check. Prefer the suite's own number when it
  # gives one: it is the count the suite computed, so it is the count the reader can
  # recompute, and it does not depend on the gate's idea of what a check looks like.
  count_from="ok lines counted"
  stated="$(printf '%s\n' "$verdict" | grep -oE '\(([0-9]+) checks?\)' | grep -oE '[0-9]+' | head -1 || true)"
  if [ -n "$stated" ]; then
    count="$stated"
    count_from="stated by the suite"
  fi

  if [ -z "$verdict" ]; then
    # No verdict line at all. That is an ERROR, not a failure of the code: the suite
    # never got far enough to judge anything. Say which, and show the last line it printed.
    err "$label emitted no verdict (exit $rc, ${dur}s)"
    note "      last output: $(printf '%s\n' "$out" | tail -1 | cut -c1-120)"
    SUITE_STATE["$key"]="error"
  elif [ "$rc" -ne 0 ]; then
    fail "$label exited $rc after its verdict (${dur}s)"
    SUITE_STATE["$key"]="failed"
  else
    note "ok    $label -> $verdict (${dur}s)"
    SUITE_STATE["$key"]="passed"
  fi
  # Only report a count when the suite emits per-check lines; a fabricated 0 would be a
  # number the reader could not recompute, which is worse than no number.
  if [ "$count" -gt 0 ]; then
    SUITE_COUNT["$key"]="$count"
    note "      $count check(s) - $count_from"
  fi
}

JS_KEYS=()
# The Lua half of the smoke test, runnable without cargo. `wa` loads the Lua core from
# disk when WASM_AGENT_LUA_ROOT is set, so Lua assertions can run on a node with no Rust
# toolchain. Without this the gate SKIPs test.sh and reports OK on a tree where the Lua
# assertions never ran - which is how a context-window patch first appeared verified when
# nothing had checked it.
if [ -n "$WA_BIN" ] && [ "${SKIP_SUITES}" != "1" ]; then
  for spec in tests/image-roundtrip.lua tests/image-store.lua; do
    script="$ROOT/$spec"
    if [ ! -f "$script" ]; then
      skip "$spec (no such script)"
      continue
    fi
    # Same env test.sh uses, so the two cannot disagree on what they are measuring.
    out="$(WASM_AGENT_LUA_ROOT="$ROOT" \
           WASM_AGENT_LLM_CONTEXT="${WASM_AGENT_LLM_CONTEXT:-128000}" \
           WA_SCRIPT="$script" "$WA_BIN" --db "$TMPLUA/lua.db" 2>&1)"
    rc=$?
    verdict="$(printf '%s\n' "$out" | grep -E 'ALL PASS' | tail -1 || true)"
    lcount="$(printf '%s\n' "$out" | grep -cE '^ok\b' || true)"
    if [ -z "$verdict" ]; then
      err "$spec emitted no verdict (exit $rc)"
      note "      last output: $(printf '%s\n' "$out" | tail -1 | cut -c1-120)"
      SUITE_STATE["$spec"]="error"
    elif [ "$rc" -ne 0 ]; then
      fail "$spec exited $rc after its verdict"
      SUITE_STATE["$spec"]="failed"
    else
      # A suite that prints no per-check lines still asserted something: its verdict only
      # prints at the end, after every assert passed. Count it as 1 so a dropped suite is
      # visible in the baseline rather than silently zero.
      [ "$lcount" -eq 0 ] && lcount=1
      note "ok    $spec -> $verdict"
      note "      $lcount check(s) - ok lines counted"
      SUITE_COUNT["$spec"]="$lcount"
      SUITE_STATE["$spec"]="passed"
      COMMANDS+=("WASM_AGENT_LUA_ROOT=. WA_SCRIPT=$spec $WA_BIN --db /tmp/lua.db")
    fi
  done
elif [ "${SKIP_SUITES}" = "1" ]; then
  skip "lua suites (skipped by request)"
else
  skip "lua suites (no wa binary found)"
fi

if find_tool bash && find_tool cargo; then
  run_suite smoke "scripts/test.sh" bash scripts/test.sh
  COMMANDS+=("bash scripts/test.sh")
elif [ "${SKIP_SUITES}" = "1" ]; then
  skip "scripts/test.sh (skipped by request)"
  SUITE_STATE["smoke"]="skipped"
elif find_tool bash; then
  skip "scripts/test.sh (cargo not on PATH)"
  SUITE_STATE["smoke"]="skipped"
else
  skip "scripts/test.sh (bash not on PATH)"
  SUITE_STATE["smoke"]="skipped"
fi

if find_tool powershell || find_tool pwsh; then
  PS=powershell; find_tool pwsh && PS=pwsh
  run_suite windows "scripts/test-windows.ps1" "$PS" -NoProfile -File scripts/test-windows.ps1
  COMMANDS+=("$PS -NoProfile -File scripts/test-windows.ps1")
elif [ "${SKIP_SUITES}" = "1" ]; then
  skip "scripts/test-windows.ps1 (skipped by request)"
  SUITE_STATE["windows"]="skipped"
else
  skip "scripts/test-windows.ps1 (no powershell on PATH)"
  SUITE_STATE["windows"]="skipped"
fi

# The JS suites are visible to the gate directly, not only through test.sh, because on
# this platform test.sh cannot run at all - and a gate that can only see the smoke suite
# would report a clean handoff from a tree whose JS tests were never executed.
if find_tool node && [ "${SKIP_SUITES}" != "1" ]; then
  for t in tests/*.js; do
    [ -e "$t" ] || continue
    JS_KEYS+=("$t")
    run_suite "$t" "$t" node "$t"
    COMMANDS+=("node $t")
  done
else
  if [ "${SKIP_SUITES}" = "1" ]; then
    skip "tests/*.js (skipped by request)"
  else
    skip "tests/*.js (node not on PATH)"
  fi
fi

# ---- property 1: the count cannot silently drop ----------------------------
# The baseline is a committed file, because a count nobody reviewed means nothing. A
# decrease is an error; an increase is reported and written only with --accept-counts.
declare -A BASELINE=()
if [ -f "$COUNTS" ]; then
  while IFS='=' read -r k v; do
    [ -n "${k:-}" ] || continue
    case "$k" in \#*) continue ;; esac
    BASELINE["$k"]="${v//[[:space:]]/}"
  done < "$COUNTS"
fi

NEW_COUNTS=""
count_dropped=0
for key in "${!SUITE_COUNT[@]}"; do
  now="${SUITE_COUNT[$key]}"
  was="${BASELINE[$key]:-}"
  NEW_COUNTS+="$key=$now"$'\n'
  if [ -n "$was" ] && [ "$now" -lt "$was" ] 2>/dev/null; then
    if [ "$ACCEPT_COUNTS" = "1" ]; then
      note "warn  $key count dropped $was -> $now (accepted explicitly)"
    else
      fail "$key count dropped $was -> $now"
      count_dropped=1
    fi
  elif [ -n "$was" ] && [ "$now" -gt "$was" ]; then
    note "ok    $key count grew $was -> $now"
  fi
done

if [ "$ACCEPT_COUNTS" = "1" ] && [ -n "$NEW_COUNTS" ]; then
  { echo "# handoff.sh counts - committed so a drop is a visible decision, not a quiet one."
    echo "# Re-record with: bash scripts/handoff.sh --accept-counts"
    printf '%s' "$NEW_COUNTS" | sort
  } > "$COUNTS"
  note "ok    baseline rewritten (--accept-counts)"
elif [ -n "$NEW_COUNTS" ] && [ ! -f "$COUNTS" ]; then
  { echo "# handoff.sh counts - committed so a drop is a visible decision, not a quiet one."
    echo "# Re-record with: bash scripts/handoff.sh --accept-counts"
    printf '%s' "$NEW_COUNTS" | sort
  } > "$COUNTS"
  note "ok    baseline recorded for the first time"
fi

# ---- the report ------------------------------------------------------------
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo none)"
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
BRANCH="$(git branch --show-current 2>/dev/null || echo detached)"

if [ "$FAILED" -eq 0 ] && [ "$ERRORED" -eq 0 ]; then
  VERDICT="HANDOFF OK"
else
  VERDICT="HANDOFF NOT OK"
fi

{
  echo "handoff report"
  echo "=============="
  echo "verdict      : $VERDICT"
  echo "branch       : $BRANCH"
  echo "commit       : $HEAD_SHA"
  echo "session      : ${SESSION:-unknown}"
  echo "session from : $SESSION_SOURCE"
  [ -n "$AGENT_LINE" ] && echo "trailer      : $AGENT_LINE"
  if [ "$did_rebase" = "yes" ]; then
    echo "rebase       : yes (history rewritten onto $REMOTE_MAIN)"
  elif [ "${REBASE_SKIPPED:-0}" = "1" ]; then
    echo "rebase       : not run (history left alone; pass --rebase to bring it up to date)"
  else
    echo "rebase       : $did_rebase"
  fi
  echo "merge        : $MERGE_VERDICT"
  echo "counts       : ${#SUITE_COUNT[@]} suite(s) reported a count"
  echo "baseline     : $COUNTS"
  echo
  echo "results"
  echo "-------"
  echo "failures     : $FAILED"
  echo "errors       : $ERRORED"
  echo "skips        : $SKIPPED"
  echo
  for line in "${SUMMARY[@]}"; do echo "  $line"; done
  echo
  echo "suites"
  echo "------"
  for k in "${!SUITE_STATE[@]}"; do
    printf '  %-28s %s' "$k" "${SUITE_STATE[$k]}"
    [ -n "${SUITE_COUNT[$k]:-}" ] && printf ' (%s ok)' "${SUITE_COUNT[$k]}"
    printf '\n'
  done
  echo
  echo "counts (this run vs baseline)"
  echo "-----------------------------"
  for k in "${!SUITE_COUNT[@]}"; do
    printf '  %-28s %s (baseline %s)\n' "$k" "${SUITE_COUNT[$k]}" "${BASELINE[$k]:-none}"
  done
  echo
  echo "re-run these"
  echo "------------"
  for c in "${COMMANDS[@]}"; do echo "  $c"; done
  echo
  echo "endings"
  echo "-------"
  echo "  this run     : started $STARTED_AT, exited $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$PREVIOUS_UNFINISHED" = "1" ]; then
    echo "  previous run : DID NOT FINISH (marker left behind)"
    printf '%s\n' "$PREVIOUS_MARKER" | sed 's/^/                 /'
  else
    echo "  previous run : left no unfinished marker"
  fi
  echo "  scope        : the gate detects an unfinished run after the fact; it does not"
  echo "                 instrument the harness, so a death *within* a turn is not visible"
  echo "                 here - only that the run as a whole did not reach its own end."
} > "$REPORT"

cat "$REPORT"

if [ "$FAILED" -gt 0 ] || [ "$ERRORED" -gt 0 ]; then
  exit 1
fi
exit 0
