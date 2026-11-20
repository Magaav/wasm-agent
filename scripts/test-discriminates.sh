#!/usr/bin/env bash
# Does a branch's own tests actually catch the branch's own change?
#
#   bash scripts/test-discriminates.sh [<base-ref>] [--repo <dir>] [--json] [--keep]
#                                      [--timeout <s>] [--allow-unclassified]
#
# WHY IT IS NOT "run the test on the base". That check is vacuous for a new feature: a test for a module
# the base does not have "fails" on the base because the module is missing, which is a load error and not
# evidence that any assertion can tell the fix from the bug. It is also wrong for a pure refactor, whose
# behaviour is deliberately unchanged. Three of ten hidden tests in the task A/B did not discriminate
# (19-20/11 reviews), and every review of that round carried a test MUST.
#
# WHAT IT DOES INSTEAD. It puts the BASE's non-test code under the branch's new and changed tests: a
# scratch worktree at the merge base, then the branch's own test files checked out on top. A test that
# still passes there would not have caught the bug, and it is named. Every failure is CLASSIFIED, because
# only some of them are evidence:
#
#   discriminates   the test ran and an assertion failed
#   does-not        the test ran green on the base code, or died on a missing symbol/file (proves nothing)
#   unclassified    it failed and no assertion marker was found: it blocks, naming the failure
#   not-applicable  its platform is not this one, or the branch deletes it
#   environment     the machine could not run it: refused, never counted as a pass
#
# A branch that only refactors is exempt: put a line "Refactor-only: <reason>" in the report the branch
# adds under docs/missions/reports/ and every EXISTING test must instead stay green.
#
# Hermetic: a scratch worktree, a scratch HOME and ledger per test, no rendezvous, no relay, no network,
# no live fleet. One line per test on stdout.
#
# Exit codes: 0 nothing blocks; 1 named blockers (does-not, unclassified); 3 the machine could not run
# some test; 76 the script could not answer at all. A refusal is never a pass.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P)
BASE=origin/main
TEST_TIMEOUT=180
JSON=0
KEEP=0
ALLOW_UNCLASSIFIED=0
REPO=$ROOT

refuse() { printf 'test-discriminates: refused: %s
' "$*" >&2; exit 76; }
say() { printf 'test-discriminates: %s
' "$*"; }

while [ $# -gt 0 ]; do
  case $1 in
    --repo) shift; [ $# -gt 0 ] || refuse "--repo needs a directory"; REPO=$1; shift ;;
    --json) JSON=1; shift ;;
    --keep) KEEP=1; shift ;;
    --allow-unclassified) ALLOW_UNCLASSIFIED=1; shift ;;
    --timeout) shift; [ $# -gt 0 ] || refuse "--timeout needs seconds"; TEST_TIMEOUT=$1; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) refuse "unknown option $1" ;;
    *) BASE=$1; shift ;;
  esac
done
REPO=$(cd -- "$REPO" 2>/dev/null && pwd -P) || refuse "no such repository directory"
cd "$REPO" || refuse "cannot enter $REPO"
git rev-parse --git-dir >/dev/null 2>&1 || refuse "not a git repository: $REPO"
BASE_SHA=$(git rev-parse --verify --quiet "$BASE^{commit}") || refuse "not a commit: $BASE"
HEAD_SHA=$(git rev-parse --verify --quiet 'HEAD^{commit}') || refuse "HEAD is not a commit"
MERGE_BASE=$(git merge-base "$HEAD_SHA" "$BASE_SHA") || refuse "no merge base between HEAD and $BASE"

# A test is a path named test-* anywhere, or anything under a tests/ directory.
is_test_path() {
  case $1 in
    */test-*|test-*) return 0 ;;
    tests/*|*/tests/*) return 0 ;;
  esac
  return 1
}

# --- a declared refactor is exempt, and must keep every existing test green ---------------------------
REFACTOR_REASON=$(git diff "$MERGE_BASE" "$HEAD_SHA" -- docs/missions/reports/ 2>/dev/null \
  | sed -n 's/^+Refactor-only: *//p' | head -1)
if [ -n "$REFACTOR_REASON" ]; then
  say "refactor-only: $REFACTOR_REASON"
fi

# --- the scratch worktree: base code, branch tests ---------------------------------------------------
# Never git stash (shared by every worktree of this repo - the 19/11 incident). A worktree of the merge
# base is the only safe way to get the old code beside the new tests.
WORKROOT=$(mktemp -d "$(dirname -- "$REPO")/.discriminates-XXXXXX" 2>/dev/null) \
  || refuse "a scratch directory beside $REPO could not be made"
WORKTREE=$WORKROOT/base
KEEP_ON_EXIT=0
cleanup() {
  if [ "$KEEP_ON_EXIT" = 1 ]; then
    say "kept: $WORKTREE (--keep)"
  else
    git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE" 2>/dev/null
    rm -rf "$WORKROOT" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM
[ "$KEEP" = 1 ] && KEEP_ON_EXIT=1

git -C "$REPO" worktree add --detach --quiet "$WORKTREE" "$MERGE_BASE" 2>"$WORKROOT/error" \
  || { cat "$WORKROOT/error" >&2; refuse "a worktree of $MERGE_BASE could not be made beside $REPO"; }
[ -d "$WORKTREE" ] || refuse "the scratch worktree is not a directory: $WORKTREE"

# The branch's test files, and only those, are laid over the base. A test the branch deletes stays
# deleted (its subject is gone, so it cannot discriminate); a test it changes or adds is run here.
: > "$WORKROOT/tests.list"
: > "$WORKROOT/deleted.list"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  is_test_path "$t" || continue
  status=$(git diff --name-status "$MERGE_BASE" "$HEAD_SHA" -- "$t" | cut -f1)
  case $status in
    D) printf '%s\n' "$t" >> "$WORKROOT/deleted.list" ;;
    A|M|R*|C*)
      if git cat-file -e "$HEAD_SHA:$t" 2>/dev/null; then
        mkdir -p "$WORKTREE/$(dirname "$t")" 2>/dev/null || refuse "cannot create $(dirname "$t") in the worktree"
        git show "$HEAD_SHA:$t" > "$WORKTREE/$t" 2>/dev/null || refuse "cannot write $t into the worktree"
        printf '%s\n' "$t" >> "$WORKROOT/tests.list"
      else
        refuse "the branch lists $t as changed but HEAD has no such file"
      fi
      ;;
    *) refuse "unexpected diff status for $t: $status" ;;
  esac
done < <(git diff --name-only "$MERGE_BASE" "$HEAD_SHA")

# --- running one test on the base code ---------------------------------------------------------------
ROWS=$WORKROOT/rows.tsv
: > "$ROWS"
LUA_BIN=""
if [ -n "${WA_BIN:-}" ] && [ -x "${WA_BIN}" ]; then
  LUA_BIN=$WA_BIN
elif [ -f "$REPO/scripts/lib/build-target.sh" ]; then
  TARGET=$(. "$REPO/scripts/lib/build-target.sh" >/dev/null 2>&1; wa_build_target "$REPO" 2>/dev/null)
  [ -n "$TARGET" ] && [ -x "$TARGET/release/wa" ] && LUA_BIN=$TARGET/release/wa
fi
[ -n "$LUA_BIN" ] || LUA_BIN=$(command -v wa 2>/dev/null)

# A missing symbol, a missing file or a runtime nil is not evidence about the change: the test could
# not reach its assertions. An assertion that fires IS evidence. Anything else is unclassified.
LOAD_RE='attempt to call a nil value|attempt to index a nil value|attempt to concatenate a nil|attempt to compare|module .* not found|Cannot find module|ERR_MODULE_NOT_FOUND|ModuleNotFoundError|No such file or directory|command not found|not an executable|error while loading shared libraries|undefined reference|cannot find crate'
ASSERT_RE='assertion failed|lua error:|FAIL|AssertionError|panicked at|not ok|check failed|assert'
# The MACHINE, not the tree: a spawn or fork failure, a killed process or an exhausted memory
# is never evidence about the change.
ENV_RE='cannot fork|CreateProcessW failed|Resource temporarily unavailable|Killed|Out of memory|cannot allocate'

runner_for() {
  case $1 in
    *.lua) printf 'lua' ;;
    *.sh) printf 'bash' ;;
    *.cjs|*.mjs|*.js) printf 'node' ;;
    *.py) command -v python3 >/dev/null 2>&1 && printf 'python3' ;;
    *.ps1) command -v pwsh >/dev/null 2>&1 && printf 'pwsh' ;;
    *.rs) printf 'rust' ;;
  esac
}

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ROWS"; }

in_list() { grep -qxF "$1" "$2" 2>/dev/null; }

run_one() { # <path> -> one row: verdict, path, reason
  path=$1
  runner=$(runner_for "$path")
  if [ -z "$runner" ]; then
    record not-applicable "$path" "no runner for this platform"
    return
  fi
  if ! in_list "$path" "$WORKROOT/tests.list"; then
    record not-applicable "$path" "the branch deletes it, so its subject is gone"
    return
  fi
  if [ "$runner" = rust ]; then
    record not-applicable "$path" "a Rust test outside a crate tests/ directory is run by cargo with its crate, not by this script"
    return
  fi
  if [ "$runner" = lua ] && [ -z "$LUA_BIN" ]; then
    record environment "$path" "no wa binary to run a Lua row"
    return
  fi
  home=$(mktemp -d "$WORKROOT/h.XXXXXX" 2>/dev/null) || { record environment "$path" 'a scratch home could not be made'; return; }
  out=$WORKROOT/out.$(printf '%s' "$path" | tr '/.' '__').log
  (
    cd "$WORKTREE" || exit 126
    case $runner in
      lua)
        env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE \
          -u WASM_AGENT_VAULT_PASSPHRASE -u WASM_AGENT_VAULT_OPERATOR_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL \
          -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN -u WASM_AGENT_RAW_CODE -u WASM_AGENT_PROVENANCE \
          -u WA_MESH -u WA_MESH_COMPONENT \
          HOME="$home" WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$WORKTREE" \
          WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT="$path" \
          timeout "$TEST_TIMEOUT" "$LUA_BIN" --db "$home/t.db" ;;
      bash)
        HOME="$home" WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$WORKTREE" \
          WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
          timeout "$TEST_TIMEOUT" bash "$path" ;;
      node)
        HOME="$home" WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$WORKTREE" \
          WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
          timeout "$TEST_TIMEOUT" node "$path" ;;
      python3|pwsh)
        HOME="$home" WASM_AGENT_HOME="$home" timeout "$TEST_TIMEOUT" "$runner" "$path" ;;
    esac
  ) > "$out" 2>&1
  code=$?
  last=$(tail -c 2000 "$out" 2>/dev/null)

  if [ "$code" = 124 ] || [ "$code" = 137 ]; then
    record environment "$path" "the test did not finish in ${TEST_TIMEOUT}s"
    return
  fi
  # A skip inside a green row is a hole, not a pass: the machine could not check what the test names.
  if [ "$code" = 0 ] && grep -q '^SKIP ' "$out" 2>/dev/null; then
    record environment "$path" "the base run skipped: $(grep -m1 '^SKIP ' "$out" | cut -c6-120)"
    return
  fi
  if [ "$code" = 0 ]; then
    record does-not "$path" "it passed on the reverted code, so it would not have caught this change"
    return
  fi
  if printf "%s" "$last" | grep -Eq "$ENV_RE"; then
    record environment "$path" "the machine could not run it: $(printf "%s" "$last" | grep -Eo "$ENV_RE" | head -1)"
    return
  fi
  if printf '%s' "$last" | grep -Eq "$LOAD_RE"; then
    record does-not "$path" "it died before its assertions on the old code: $(printf '%s' "$last" | grep -Eo "$LOAD_RE" | head -1)"
    return
  fi
  if printf '%s' "$last" | grep -Eq "$ASSERT_RE"; then
    record discriminates "$path" "$(printf '%s' "$last" | grep -E "$ASSERT_RE" | tail -1 | cut -c1-160 | tr '\t' ' ')"
    return
  fi
  # A Lua test signals a failed check by raising an error, and the message carries the
  # source position. That is an assertion that fired; a missing SYMBOL is caught above
  # and stays does-not.
  if [ "$runner" = lua ] && printf "%s" "$last" | grep -Eq ":[0-9]+: "; then
    record discriminates "$path" "$(printf "%s" "$last" | tail -1 | cut -c1-160 | tr "\t" " ")"
    return
  fi
  if [ "$ALLOW_UNCLASSIFIED" = 1 ]; then
    record unclassified-allowed "$path" "exit $code, no assertion marker (allowed): $(printf '%s' "$last" | tail -1 | cut -c1-140 | tr '\t' ' ')"
  else
    record unclassified "$path" "exit $code and no assertion marker; name the failure or its marker: $(printf '%s' "$last" | tail -1 | cut -c1-140 | tr '\t' ' ')"
  fi
}
export -f run_one record in_list runner_for

# --- the driver ---------------------------------------------------------------------------------------
say "HEAD $HEAD_SHA vs base $BASE ($MERGE_BASE); scratch worktree $WORKTREE"

if [ -n "$REFACTOR_REASON" ]; then
  # Exempt from discriminating, but a refactor must keep every test it runs green on the base code.
  # The tests it touches stand in for "existing" here: a refactor that changes tests still has to keep
  # them green, which is exactly the assertion a refactor owes.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    run_one "$t"
  done < "$WORKROOT/tests.list"
else
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    run_one "$t"
  done < "$WORKROOT/tests.list"
fi

# A test the branch DELETES is reported too: silence about a deleted test reads as "nothing to check".
while IFS= read -r t; do
  [ -n "$t" ] || continue
  record not-applicable "$t" "the branch deletes it, so its subject is gone"
done < "$WORKROOT/deleted.list"

# --- the verdict --------------------------------------------------------------------------------------
[ -s "$ROWS" ] || refuse "no row was produced: the branch changes tests but none could be classified"

if [ "$JSON" = 1 ]; then
  awk -F'\t' 'BEGIN{print "{\"rows\":["} {gsub(/"/,"\\\"",$2); gsub(/"/,"\\\"",$3); printf "%s{\"verdict\":\"%s\",\"test\":\"%s\",\"reason\":\"%s\"}", (NR>1?",":""), $1,$2,$3} END{print "]}"}' "$ROWS"
fi

if [ "$JSON" != 1 ]; then
  while IFS=$(printf '\t') read -r verdict path reason; do
    printf '%s\t%s\t%s\n' "$verdict" "$path" "$reason"
  done < "$ROWS"
fi

counts=$(cut -f1 "$ROWS" | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
blockers=$(cut -f1 "$ROWS" | grep -c -E '^(does-not|unclassified)$')
environment=$(cut -f1 "$ROWS" | grep -c '^environment$')
discriminating=$(cut -f1 "$ROWS" | grep -c '^discriminates$')
say "rows: $counts"
say "$discriminating discriminating, $blockers blocking, $environment not run by this machine"

if [ "$environment" -gt 0 ]; then
  say "refused: this machine could not run $environment test(s); that is not a pass"
  exit 3
fi
if [ "$blockers" -gt 0 ]; then
  say "BLOCKED: $blockers test(s) do not discriminate - named above"
  exit 1
fi
exit 0
