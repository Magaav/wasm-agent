#!/usr/bin/env bash
# Does a branch's own tests actually catch the branch's own change?
#
#   bash scripts/test-discriminates.sh [<base-ref>] [--repo <dir>] [--json] [--keep]
#                                      [--timeout <s>] [--allow-unclassified]
#
# WHY IT IS NOT "run the test on the base". That check is vacuous for a new feature: a test for a module
# the base does not have "fails" on the base because the module is missing, which is not evidence that any
# assertion can tell the fix from the bug. It is also wrong for a pure refactor, whose behaviour is
# deliberately unchanged.
#
# WHAT IT DOES INSTEAD. It puts the BASE's non-test code under the branch's new and changed tests: a
# scratch worktree at the merge base, then the branch's own test files checked out on top.
#
# EVERY changed test gets exactly one row, and only two outcomes BLOCK:
#
#   discriminates       an assertion failed on the old code: this test catches the change
#   does-not            BLOCKS: a test the branch ADDS passes on the old code - it proves nothing
#   unclassified        BLOCKS: it failed and no marker matched, so its failure must be named
#   unchanged-verdict   a test the branch MODIFIES still passes: not evidence, but not a failure either
#   new-symbol          it died on a missing symbol/file: the base has no such code, so it proves nothing
#   not-applicable      another changed test runs it as its subject, or the branch deletes it
#   skipped             the test skipped itself on this machine, or its platform is not this one
#   timeout             it did not finish; a timeout is a named verdict, never a failure of the change
#   environment         the machine could not run it
#
# A branch that only refactors is exempt: put a line "Refactor-only: <reason>" in the report the branch
# adds under docs/missions/reports/ and every test it touches must instead stay GREEN on the base code.
# wa land refuses such a declaration in a round of more than one branch: one line cannot speak for
# several changes.
#
# Hermetic: a scratch worktree under ~/.wasm-agent/tmp, a scratch HOME and ledger per test, no
# rendezvous, no relay, no network, no live fleet. One line per test on stdout.
#
# Exit codes: 0 nothing blocks; 1 named blockers; 3 nothing could be judged (every row environment or
# skipped); 76 the script could not answer at all. A refusal is never a pass.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P)
BASE=origin/main
TEST_TIMEOUT=180
JSON=0
KEEP=0
ALLOW_UNCLASSIFIED=0
BRANCHES=""
REPO=$ROOT

refuse() { printf 'test-discriminates: refused: %s\n' "$*" >&2; exit 76; }
say() { printf 'test-discriminates: %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case $1 in
    --repo) shift; [ $# -gt 0 ] || refuse "--repo needs a directory"; REPO=$1; shift ;;
    --json) JSON=1; shift ;;
    --keep) KEEP=1; shift ;;
    --allow-unclassified) ALLOW_UNCLASSIFIED=1; shift ;;
    --timeout) shift; [ $# -gt 0 ] || refuse "--timeout needs seconds"; TEST_TIMEOUT=$1; shift ;;
    --branches) shift; [ $# -gt 0 ] || refuse "--branches needs a comma-separated list"; BRANCHES=$1; shift ;;
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# A TEST is a path a RUNNER can execute: test-* with a runner's extension, or anything under a tests/
# directory with one. A report or a snapshot whose name starts with test- (docs/.../test-x.md,
# tests/snapshots/wakes-80x24.txt) is data, and counting it produced two rows that could never run.
is_test_path() {
  case $1 in
    */test-*|test-*) ;;
    tests/*|*/tests/*) ;;
    *) return 1 ;;
  esac
  case $1 in
    *.lua|*.sh|*.cjs|*.mjs|*.js|*.py|*.ps1|*.rs) return 0 ;;
  esac
  return 1
}

# <target> <other-test> <tree> -> 0 when <other-test> looks like it RUNS <target>: the mention sits on a
# line that also names a runner. A bare mention in a comment ("see test-x.lua") is a reference, not a
# subject, and must not turn a real test into not-applicable.
looks_executed_by() {
  local target=$1 other=$2 tree=$3 line
  while IFS= read -r line; do
    case $line in
      *"$target"*)
        case $line in
          *" wa "*|wa\ *|*bash\ *|*"bash "*|*node\ *|*"node "*|*sh\ *|*"sh "*|*dofile*|*require*|*execFile*|*spawnSync*|*spawn\ *|*"python3 "*|*"timeout "*|*WA_SCRIPT*)
            return 0 ;;
        esac
        ;;
    esac
  done < "$tree/$other"
  return 1
}

changed_count=$(git diff --name-only "$MERGE_BASE" "$HEAD_SHA" | grep -c . || true)
test_count=$(git diff --name-only "$MERGE_BASE" "$HEAD_SHA" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  is_test_path "$p" && printf '%s\n' "$p"
done | grep -c . || true)

if [ "$changed_count" = 0 ]; then
  say "HEAD $HEAD_SHA changes nothing against $BASE ($MERGE_BASE): nothing to discriminate"
  exit 0
fi
if [ "$test_count" = 0 ]; then
  say "the branch changes $changed_count path(s) and adds or changes no test: nothing to discriminate"
  exit 0
fi

REFACTOR_REASON=$(git diff "$MERGE_BASE" "$HEAD_SHA" -- docs/missions/reports/ 2>/dev/null \
  | sed -n 's/^+Refactor-only: *//p' | head -1)
if [ -n "$REFACTOR_REASON" ]; then
  # One line in one branch's report cannot speak for a round of several changes: the other branches
  # are not refactors, and the tool would strip their tests of the check they owe.
  branch_count=$(printf "%s" "$BRANCHES" | tr ',' '\n' | grep -c . || true)
  if [ "$branch_count" -gt 1 ]; then
    refuse "a round of $branch_count branches carries a Refactor-only line: one declaration cannot speak for several changes - land the refactor alone, or drop the line"
  fi
  say "refactor-only: $REFACTOR_REASON"
fi

# --- the scratch worktree: base code, branch tests ---------------------------------------------------
# Never git stash (shared by every worktree of this repo - the 19/11 incident). The scratch tree lives
# under the node's own temp root, never beside the checkout (docs/ONEROOT.md): a directory beside a
# repository is one more thing that looks like a second root.
TMP_ROOT=${WASM_AGENT_TMPDIR:-$HOME/.wasm-agent/tmp}
mkdir -p "$TMP_ROOT" 2>/dev/null || TMP_ROOT=${TMPDIR:-/tmp}
WORKROOT=$(mktemp -d "$TMP_ROOT/discriminates-XXXXXX" 2>/dev/null) \
  || refuse "a scratch directory under $TMP_ROOT could not be made"
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
on_signal() { cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM
[ "$KEEP" = 1 ] && KEEP_ON_EXIT=1

git -C "$REPO" worktree add --detach --quiet "$WORKTREE" "$MERGE_BASE" 2>"$WORKROOT/error" \
  || { cat "$WORKROOT/error" >&2; refuse "a worktree of $MERGE_BASE could not be made"; }
[ -d "$WORKTREE" ] || refuse "the scratch worktree is not a directory: $WORKTREE"

# --- which changed paths are tests, and which are a test's SUBJECT ------------------------------------
# A file that another changed test EXECUTES is code, not a test: it is laid over the base as a non-test
# change and reverted with them, so the test that runs it is judged against the old code. The test's own
# path is never a subject, and a second test named in the same runner line is another row, not a subject.
: > "$WORKROOT/tests.list"
: > "$WORKROOT/subjects.list"
: > "$WORKROOT/deleted.list"
ALL_TESTS=$WORKROOT/all-tests.list
git diff --name-only "$MERGE_BASE" "$HEAD_SHA" | while IFS= read -r q; do
  [ -n "$q" ] || continue
  is_test_path "$q" && printf '%s\n' "$q"
done > "$ALL_TESTS"
# The test files as the BRANCH has them, so a runner line the branch just added is seen.
while IFS= read -r q; do
  [ -n "$q" ] || continue
  git cat-file -e "$HEAD_SHA:$q" 2>/dev/null || continue
  mkdir -p "$WORKTREE/$(dirname "$q")" 2>/dev/null
  git show "$HEAD_SHA:$q" > "$WORKTREE/$q" 2>/dev/null
done < "$ALL_TESTS"

for t in $(cat "$ALL_TESTS"); do
  status=$(git diff --name-status "$MERGE_BASE" "$HEAD_SHA" -- "$t" | cut -f1)
  if [ "$status" = D ]; then
    printf '%s\n' "$t" >> "$WORKROOT/deleted.list"
  else
    printf '%s\n' "$t" >> "$WORKROOT/tests.list"
  fi
done

# --- running one test on the base code ---------------------------------------------------------------
ROWS=$WORKROOT/rows.tsv
: > "$ROWS"
TOUCHED_RUST=$WORKROOT/touched-rust.list
git diff --name-only "$MERGE_BASE" "$HEAD_SHA" -- rust/ | grep . > "$TOUCHED_RUST" 2>/dev/null || : > "$TOUCHED_RUST"

# The binary a Lua row runs. It must be THIS tree's build, never a PATH wa: a PATH binary is another
# tree's code, so a row judged with it says nothing about this diff.
# The RUNTIME a Lua row executes on. Never a PATH wa: that is another tree's code, and a row judged
# with it says nothing about this diff. The Lua a row runs always comes from the scratch worktree
# (WASM_AGENT_LUA_ROOT), so the binary only has to be a node of THIS build - the one built for the
# tree this script lives in, or for the repository being judged.
LUA_BIN=""
for candidate_root in "$ROOT" "$REPO"; do
  [ -n "$LUA_BIN" ] && break
  [ -f "$candidate_root/scripts/lib/build-target.sh" ] || continue
  TARGET=$(. "$candidate_root/scripts/lib/build-target.sh" >/dev/null 2>&1; wa_build_target "$candidate_root" 2>/dev/null)
  [ -n "$TARGET" ] && [ -x "$TARGET/release/wa" ] && LUA_BIN=$TARGET/release/wa
done
if [ -z "$LUA_BIN" ] && [ -n "${WA_BIN:-}" ] && [ -x "${WA_BIN:-}" ]; then
  LUA_BIN=$WA_BIN
fi

# Markers, in the order they are consulted. An ASSERTION that fired is evidence of a test doing its job,
# so it is looked for FIRST: a message that says "the new value is missing" is an assertion, not a
# missing symbol, and the old order read it the wrong way round.
ASSERT_RE='assertion failed|lua error:|FAIL|AssertionError|panicked at|not ok|check failed|assert'
# "The code under test does not exist on the base" - the only shape that means the base has no such code.
# A nil INDEX or COMPARE on the old code is a real symptom of the change and is deliberately NOT here.
LOAD_RE='attempt to call a nil value|attempt to call method .* \(a nil value\)|module .* not found|Cannot find module|ERR_MODULE_NOT_FOUND|ModuleNotFoundError|command not found|not an executable|error while loading shared libraries|undefined reference|cannot find crate|no such file or directory'
ENV_RE='cannot fork|CreateProcessW failed|Resource temporarily unavailable|Killed|Out of memory|cannot allocate'

runner_for() {
  case $1 in
    *.lua) printf 'lua' ;;
    *.sh) printf 'bash' ;;
    *.cjs|*.mjs|*.js) printf 'node' ;;
    *.py) command -v python3 >/dev/null 2>&1 && printf 'python3' ;;
    *.ps1) command -v pwsh >/dev/null 2>&1 && printf 'pwsh' ;;
  esac
}

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ROWS"; }
in_list() { grep -qxF "$1" "$2" 2>/dev/null; }

run_one() { # <path> <added|modified>
  path=$1
  origin=$2
  runner=$(runner_for "$path")
  if [ -z "$runner" ]; then
    record skipped "$path" "this platform has no runner for it"
    return
  fi
  if in_list "$path" "$WORKROOT/deleted.list"; then
    record not-applicable "$path" "the branch deletes it, so its subject is gone"
    return
  fi

  # A Lua row is judged by the base's code, and the base's code is what the base BINARY compiled. When
  # the diff touches rust/, no binary here is the base's binary, so the row cannot be judged: it is
  # named, and non-blocking, because the limitation is this script's and not the branch's.
  if [ "$runner" = lua ] && [ -s "$TOUCHED_RUST" ]; then
    record unrevertable "$path" "this branch changes rust/, and the Lua rows would run against this tree's binary, not the base's: build the base binary to judge it"
    return
  fi
  if [ "$runner" = lua ] && [ -z "$LUA_BIN" ]; then
    record environment "$path" "this tree has no wa binary, so a Lua row cannot run the base code"
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
        env -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN -u WA_MESH \
          HOME="$home" WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$WORKTREE" \
          WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
          timeout "$TEST_TIMEOUT" bash "$path" ;;
      node)
        env -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN -u WA_MESH \
          HOME="$home" WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$WORKTREE" \
          WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
          timeout "$TEST_TIMEOUT" node "$path" ;;
      python3|pwsh)
        HOME="$home" WASM_AGENT_HOME="$home" timeout "$TEST_TIMEOUT" "$runner" "$path" ;;
    esac
  ) > "$out" 2>&1
  code=$?
  last=$(tail -c 2000 "$out" 2>/dev/null)

  # A timeout is the machine's answer, not the branch's: a named verdict, never a failure.
  if [ "$code" = 124 ] || [ "$code" = 137 ]; then
    record timeout "$path" "it did not finish in \${TEST_TIMEOUT}s on this machine"
    return
  fi
  # A skip is a hole the test itself names, never a pass and never a failure of the change.
  if grep -q '^SKIP ' "$out" 2>/dev/null; then
    record skipped "$path" "the test skipped itself: $(grep -m1 '^SKIP ' "$out" | cut -c6-140)"
    return
  fi
  if [ "$code" = 0 ] && grep -q 'test-discriminates: .*nothing to discriminate' "$out" 2>/dev/null; then
    record skipped "$path" "it judged nothing here: the tree it ran in has nothing to compare"
    return
  fi
  if [ "$code" = 0 ]; then
    if [ "$origin" = added ]; then
      record passed-added "$path" "it passed on the old code, and the branch ADDS it: it does not catch this change"
    else
      record passed-modified "$path" "it still passes; its verdict did not change, so it is not evidence of the fix"
    fi
    return
  fi
  # A process killed by a SIGNAL (128+N) died with no verdict of its own: the machine or an abort did
  # that, not the change. Named, never a blocker (measured: exit 134 on a napi/js abort).
  if [ "$code" -gt 128 ] && [ "$code" -lt 160 ]; then
    record environment "$path" "it was killed by signal $((code - 128)), so it reached no verdict of its own"
    return
  fi
  if printf '%s' "$last" | grep -Eqi "$ENV_RE"; then
    record environment "$path" "the machine could not run it: $(printf '%s' "$last" | grep -Eo "$ENV_RE" | head -1)"
    return
  fi
  # ASSERTIONS FIRST (the review's order): "the new value is missing" is an assertion that fired.
  if printf '%s' "$last" | grep -Eqi "$ASSERT_RE"; then
    record asserted "$path" "$(printf '%s' "$last" | grep -E "$ASSERT_RE" | tail -1 | cut -c1-160 | tr '\t' ' ')"
    return
  fi
  if printf '%s' "$last" | grep -Eqi "$LOAD_RE"; then
    record new-symbol "$path" "it died on code the base does not have: $(printf '%s' "$last" | grep -Eo "$LOAD_RE" | head -1)"
    return
  fi
  if [ "$ALLOW_UNCLASSIFIED" = 1 ]; then
    record unclassified-allowed "$path" "exit $code, no marker (allowed): $(printf '%s' "$last" | tail -1 | cut -c1-140 | tr '\t' ' ')"
    return
  fi
  record unclassified "$path" "exit $code and no marker matched; name the failure or its marker: $(printf '%s' "$last" | tail -1 | cut -c1-140 | tr '\t' ' ')"
}

# --- the driver ---------------------------------------------------------------------------------------
say "HEAD $HEAD_SHA vs base $BASE ($MERGE_BASE); scratch worktree $WORKTREE"
if [ -s "$TOUCHED_RUST" ]; then
  say "this branch changes rust/: its Lua rows cannot be judged against the base binary and are named unrevertable"
fi

while IFS= read -r t; do
  [ -n "$t" ] || continue
  status=$(git diff --name-status "$MERGE_BASE" "$HEAD_SHA" -- "$t" | cut -f1)
  case $status in
    A) run_one "$t" added ;;
    *) run_one "$t" modified ;;
  esac
done < "$WORKROOT/tests.list"

# A test the branch DELETES, and a file another changed test runs, are reported too: silence about
# either reads as "nothing to check".
while IFS= read -r t; do
  [ -n "$t" ] || continue
  record deleted "$t" "the branch deletes it, so its subject is gone"
done < "$WORKROOT/deleted.list"


[ -s "$ROWS" ] || refuse "no row was produced: the branch changes tests but none could be classified"

# --- the verdict --------------------------------------------------------------------------------------
# The same raw outcome means different things per ORIGIN and per MODE:
#   added     a test the branch adds that passes on the old code BLOCKS: it cannot catch the change;
#   modified  a test it changes that still passes is unchanged-verdict, not evidence and not a failure
#             (a test-only fix of a test's own bug is exactly this shape);
#   refactor  behaviour is deliberately unchanged, so a test that still passes is the evidence, and a
#             failure it did not ask for blocks.
VERDICTS=$WORKROOT/verdicts.tsv
if [ -n "$REFACTOR_REASON" ]; then
  awk -F'\t' 'BEGIN{OFS="\t"} {
    if ($1=="passed-added"||$1=="passed-modified") {print "green",$2,"it stays green on the base code"}
    else if ($1=="asserted") {print "does-not",$2,("a refactor must keep every test green, and this one failed an assertion: " $3)}
    else if ($1=="unchanged-verdict") {print "green",$2,"it stays green on the base code"}
    else if ($1=="new-symbol") {print "new-symbol",$2,$3}
    else if ($1=="deleted"||$1=="subject") {print "not-applicable",$2,$3}
    else {print $1,$2,$3}
  }' "$ROWS" > "$VERDICTS"
else
  awk -F'\t' 'BEGIN{OFS="\t"} {
    if ($1=="passed-added") {print "does-not",$2,$3}
    else if ($1=="passed-modified") {print "unchanged-verdict",$2,("a modified test that still passes proves nothing about the fix, and does not block: " $3)}
    else if ($1=="asserted") {print "discriminates",$2,$3}
    else if ($1=="unclassified-allowed") {print "unclassified",$2,$3}
    else if ($1=="deleted"||$1=="subject") {print "not-applicable",$2,$3}
    else {print $1,$2,$3}
  }' "$ROWS" > "$VERDICTS"
fi

if [ "$JSON" = 1 ]; then
  printf '{"rows":['
  first=1
  while IFS=$(printf '\t') read -r verdict path reason; do
    [ -n "$verdict" ] || continue
    esc_path=$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_reason=$(printf '%s' "$reason" | tr '\t' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"verdict":"%s","test":"%s","reason":"%s"}' "$verdict" "$esc_path" "$esc_reason"
  done < "$VERDICTS"
  printf ']}\n'
else
  while IFS=$(printf '\t') read -r verdict path reason; do
    printf '%s\t%s\t%s\n' "$verdict" "$path" "$reason"
  done < "$VERDICTS"
fi

counts=$(cut -f1 "$VERDICTS" | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
blockers=$(cut -f1 "$VERDICTS" | grep -c -E '^(does-not|unclassified)$')
unjudged=$(cut -f1 "$VERDICTS" | grep -c -E '^(environment|skipped|timeout|unrevertable)$')
evidence=$(cut -f1 "$VERDICTS" | grep -c -E '^(discriminates|green)$')
say "rows: $counts"
if [ -n "$REFACTOR_REASON" ]; then
  say "$evidence test(s) still green on the base code, $blockers blocking, $unjudged not judged by this machine"
else
  say "$evidence discriminating, $blockers blocking, $unjudged not judged by this machine"
fi

# Nothing could be judged at all: that is a refusal, never a pass (unknown is not yes).
judged=$(cut -f1 "$VERDICTS" | grep -c -E '^(discriminates|green|unchanged-verdict|new-symbol|does-not|unclassified)$' || true)
if [ "$judged" = 0 ]; then
  say "refused: no test could be judged on this machine; that is not a pass"
  exit 3
fi
if [ "$blockers" -gt 0 ]; then
  if [ -n "$REFACTOR_REASON" ]; then
    say "BLOCKED: $blockers test(s) are no longer green - named above"
  else
    say "BLOCKED: $blockers test(s) do not discriminate - named above"
  fi
  exit 1
fi
exit 0
