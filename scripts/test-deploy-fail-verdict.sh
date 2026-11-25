#!/usr/bin/env bash
# fail() IN TWO HALVES: main's body before the swap, and the same four writes with a verdict of its own after it
# (25/11, Fable's A, B and C).
#
# WHY THIS FILE EXISTS. This branch had replaced main's fail() with `printf; exit "${2:-2}"`, which lost four things a
# failed deploy owes its readers and read the second word of a message as an exit code. The far side of the swap needs
# the OPPOSITE of nothing: the same four writes, with a verdict that is neither "failed" (the build installed) nor a
# clean "installed" (the deploy did not finish) - "installed, with N problem(s)", exit 3.
#
# The four writes, named:
#   1. the status file   wa_status_unfollow + wa_status <state> "<what>"   (the row above the operator's input);
#   2. the evidence      <install>/deploy.log, one tab-separated line per outcome;
#   3. the answer        write_result <ok> <detail> [verdict] [problems] -> deploy-result.json, which the sentinel's
#                        deploy_outcome, `wa update`'s final line, the remote follow and verify-install read;
#   4. the exit status   1 before the swap (nothing was replaced), 3 after it (the node serves the new bytes).
#
# It runs the REAL functions, read out of scripts/deploy.sh by their own text - a copy would test the copy - and it
# starts nothing: no installer, no node, no systemctl.
#
#   bash scripts/test-deploy-fail-verdict.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"

root="$(wa_scratch_root wa-fail-verdict)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
trap 'rm -rf "$W"' EXIT

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }

# THE REAL BLOCKS, by their own text: post_swap_problem, record_post_swap_problems and fail.
HARNESS="$W/deploy-fail.sh"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'echo "DEPLOY-SOURCE %s"\n' "$(bash -n "$ROOT/scripts/deploy.sh" && echo parsed)"
  # THE THREE VARIABLES THE FAR SIDE USES, initialised the way deploy.sh initialises them - and defaulted, not
  # forced, so the harness can ask for SWAPPED=1 from its environment.
  printf 'SWAPPED="${SWAPPED:-0}"; POST_SWAP_PROBLEMS="${POST_SWAP_PROBLEMS:-0}"; POST_SWAP_LOG="${POST_SWAP_LOG:-}"\n' 
  sed -n '/^post_swap_problem() {/,/^}/p' scripts/deploy.sh
  sed -n '/^record_post_swap_problems() {/,/^}/p' scripts/deploy.sh
  sed -n '/^fail() {/,/^}/p' scripts/deploy.sh
  printf 'SWAPPED_SENTINEL=1\n'
} > "$HARNESS"
[ -s "$HARNESS" ] || { echo "FAIL cannot read fail() out of scripts/deploy.sh"; exit 1; }

# THE STUBS: the four things fail() writes, recorded instead of written.
runner() { # <swapped 0|1> <args...> -> prints the log lines and the exit status
  local swapped="$1"; shift
  local inst="$W/install-$RANDOM" log="$W/log-$RANDOM"
  mkdir -p "$inst"
  # A RECORD ALREADY EXISTS, because that is the state the far side of the swap is in: record_post_swap_problems
  # APPENDS to it and returns early when there is none (measured: the row's first form asserted a line that the
  # function is deliberately not written to create).
  printf 'commit=0123456789abcdef0123456789abcdef01234567\nrecord_role=final\n' > "$inst/installed.txt"
  : > "$log"
  (
    cd "$W" || exit 9
    SWAPPED="$swapped" INSTALL_DIR="$inst" COMMIT=0123456789abcdef0123456789abcdef01234567 BRANCH=main \
    WA_STATUS_PHASE=proving \
    bash -c '
      . "$1"
      LOG="$2"
      WA_STATUS_FOLLOWER=""
      wa_status_unfollow() { echo "UNFOLLOW" >> "$LOG"; }
      wa_status() { echo "STATUS $*" >> "$LOG"; }
      write_result() { local v="${3:-}"; [ -n "$v" ] || { [ "$1" = true ] && v=installed || v=failed; }; echo "RESULT ok=$1 verdict=$v problems=${4:-0} detail=$2" >> "$LOG"; }
      note() { echo "NOTE $*" >> "$LOG"; }
      shift 2
      fail "$@"
    ' _ "$HARNESS" "$log" "$@"
  ) >/dev/null 2>&1
  local rc=$?
  printf 'RC=%s\n' "$rc"
  cat "$log" 2>/dev/null
  echo "--- record"
  cat "$inst/installed.txt" 2>/dev/null
  echo "--- deploy.log"
  cat "$inst/deploy.log" 2>/dev/null
  echo "--- rc=$rc"
}

# ---- A. BEFORE THE SWAP: main's body, exit 1, and not a word about an install ----------------
OUT="$(runner 0 'refused(build_commit_mismatch): the bytes are not the commit they were taken for')"
ok "$(printf '%s' "$OUT" | grep -q '^RC=1$' && echo 1)" "a refusal before the swap exits 1 (main's status, not a message's second word)" "$(printf '%s' "$OUT" | grep '^RC=' )"
ok "$(printf '%s' "$OUT" | grep -q '^UNFOLLOW$' && echo 1)" "and it stops the status follower (the row above the input stops drawing a build that is gone)" ""
ok "$(printf '%s' "$OUT" | grep -q "^STATUS failed proving: " && echo 1)" "and marks the status failed, in the phase it died in" "$(printf '%s' "$OUT" | grep '^STATUS')"
ok "$(printf '%s' "$OUT" | grep -q '^RESULT ok=false verdict=failed' && echo 1)" "and writes the result every reader of a refusal reads" "$(printf '%s' "$OUT" | grep '^RESULT')"
ok "$(printf '%s' "$OUT" | grep -q '^--- deploy.log' && [ "$(printf '%s' "$OUT" | sed -n '/^--- deploy.log/,$p' | grep -c 'refused(build_commit_mismatch)')" -ge 1 ] && echo 1)" \
  "and appends the evidence line to deploy.log" ""
ok "$(printf '%s' "$OUT" | grep -q 'installed' && echo 0 || echo 1)" "and says nothing about an install" "$(printf '%s' "$OUT" | grep 'installed' | head -2)"

# ---- B. AFTER THE SWAP: the same four writes, a verdict of its own, exit 3 --------------------
OUT="$(runner 1 'the sentinel would not start (no watcher is running)')"
ok "$(printf '%s' "$OUT" | grep -q '^RC=3$' && echo 1)" "a problem after the swap exits 3, not 1 and not 2" "$(printf '%s' "$OUT" | grep '^RC=')"
ok "$(printf '%s' "$OUT" | grep -q '^UNFOLLOW$' && echo 1)" "and it still stops the status follower" ""
ok "$(printf '%s' "$OUT" | grep -q '^STATUS installed installed, with 1 problem(s)' && echo 1)" \
  "and the status says installed with a problem - never 'failed', never a clean 'installed'" "$(printf '%s' "$OUT" | grep '^STATUS')"
ok "$(printf '%s' "$OUT" | grep -q '^RESULT ok=false verdict=installed_with_problems problems=1 detail=the sentinel would not start' && echo 1)" \
  "and the result names the verdict, the count and the problem" "$(printf '%s' "$OUT" | grep '^RESULT')"
ok "$(printf '%s' "$OUT" | sed -n '/^--- record/,$p' | grep -q '^post_swap_problem=the sentinel would not start' && echo 1)" \
  "and the record holds the problem, in the record's own field" "$(printf '%s' "$OUT" | sed -n '/^--- record/,$p' | grep '^post_swap_problem')"
ok "$(printf '%s' "$OUT" | grep -q '^post_swap_problem_count=1' && echo 1)" "and counts it" "$(printf '%s' "$OUT" | grep '^post_swap_problem_count')"
ok "$(printf '%s' "$OUT" | sed -n '/^--- deploy.log/,$p' | grep -q 'installed, with 1 problem(s): the sentinel would not start' && echo 1)" \
  "and deploy.log carries the verdict sentence, not the bare problem" ""

# ---- C. ONE SENTENCE IN, ONE SENTENCE RECORDED -------------------------------------------------
OUT="$(runner 1 'the installed binary reports commit abc but this deploy proved def')"
ok "$(printf '%s' "$OUT" | grep -q '^post_swap_problem=the installed binary reports commit abc but this deploy proved def' && echo 1)" \
  "the record holds the WHOLE sentence (the two-argument call sites kept only the word 'recording')" "$(printf '%s' "$OUT" | grep '^post_swap_problem=')"

printf 'test-deploy-fail-verdict: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
