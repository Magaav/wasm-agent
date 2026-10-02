#!/usr/bin/env bash
# Does the deploy path ship a script WITHOUT rewriting the file the running shell is reading?
#
# The failure this exists for (measured 2026-10-02 19:30, in the sentinel's own capture of the deploy it
# started: `~/.wasm-agent/sentinel/deploy.out`). A deploy installed the node, replaced the sentinel, and then
# reached the step that ships its own copy into the install - the sentinel's `deploy` verb resolves
# `<install>/scripts/deploy.sh`, so the running script IS the file being replaced. `cp -f` truncated it under
# the interpreter, bash resumed reading at a stale byte offset, and the run ended on
#
#     /…/wasm-agent/scripts/deploy.sh: line 534: syntax error near unexpected token `('
#
# after having already printed `deploy: sentinel pid 16712 -> 2904`. Everything after that line was skipped,
# and nothing was written to deploy.log, because a parse error reaches none of the script's own `fail`
# paths: the pipeline and wave scripts were never shipped (two of them stayed at the 5b1ffdc build while the
# tree was 2f02b4c), installed.txt kept upgrade.sh's interim record (`commit=unknown`), the recorded
# sentinel_sha256 was the pre-replacement sentinel's, deploy-result.json kept the previous deploy's verdict,
# and the session waiting for the wake was never told. `verify-install.sh --json` reported the damage as
# `installed unknown is not an ancestor of tree 2f02b4c`.
#
# What is asserted here, by running the REAL `ship_file()` out of `scripts/deploy.sh` against a script that
# ships itself while it runs:
#   1. the rename form runs the rest of the script - the fix;
#   2. the fix is what makes the difference: the same fixture with `cp -f` in place of `ship_file` is run too,
#      and its outcome is reported (it lost the rest of the script in the measurement above; the loss is not
#      asserted because it is a buffering artifact and a guarantee has to be deterministic);
#   3. no `.ship.*` staging file survives, and no partial file is left at the destination.
#
# Hermetic: a temp directory per run, no cargo, no network, no node, no sentinel, no live install.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"

checks=0
fail() { echo "test-deploy-self-ship: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }
check() { # condition label [detail]
  if [ "$1" = "1" ]; then ok "$2" "${3:-}"; else fail "$2${3:+ - $3}"; fi
}

[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-self-ship-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# The real helper, read out of deploy.sh. If it stops staging and renaming, this test is the alarm.
awk '/^ship_file\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$DEPLOY" > "$WORK/ship.sh"
grep -q 'mv -f' "$WORK/ship.sh" || fail "the extracted self-ship does not rename (the marker moved?)"
grep -q 'cmp -s' "$WORK/ship.sh" || fail "the extracted self-ship has no up-to-date check anymore"

# A victim that replaces ITSELF with different bytes and then has more of itself to run - the shape of
# deploy.sh shipping deploy.sh. 40 filler lines on each side, because bash reads in blocks and seeks: the
# point is that it has to read the file again after the replacement.
write_victim() { # strategy(cp|ship) destination
  local strategy="$1" destination="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "SELF=\"$destination\""
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    cat "$WORK/ship.sh"
    echo 'echo "before the self-ship"'
    local i
    for i in $(seq 1 40); do echo "# filler before the self-ship $i"; done
    case "$strategy" in
      cp)   echo 'cp -f "$NEW" "$SELF"' ;;
      ship) echo 'ship_file "$NEW" "$SELF" "this script"' ;;
      *)    fail "unknown strategy $strategy" ;;
    esac
    for i in $(seq 1 40); do echo "# filler after the self-ship $i"; done
    echo 'echo "after the self-ship: the rest of this script ran"'
  } > "$destination"
}

# The new bytes, longer than the victim so every later byte offset in the file shifts - which is what makes
# an in-place rewrite visible to a reader that tracks offsets.
{
  echo '#!/usr/bin/env bash'
  echo 'echo "the shipped replacement"'
  printf '# replacement padding %s\n' $(seq 1 60)
} > "$WORK/new.sh"

run_victim() { # strategy destination -> output; the script's own exit status in $VICTIM_STATUS
  write_victim "$1" "$2"
  cp -f "$WORK/new.sh" "$WORK/new-bytes"
  OUT="$(NEW="$WORK/new-bytes" bash "$2" 2>&1)"; VICTIM_STATUS=$?
}

# 1. The fix: the running script survives replacing itself.
run_victim ship "$WORK/victim-ship.sh"
[ "$VICTIM_STATUS" = "0" ] || fail "the rename form did not exit 0 (status $VICTIM_STATUS): $OUT"
check "$([ "$(printf '%s\n' "$OUT" | grep -c '^after the self-ship: the rest of this script ran$')" = "1" ] && echo 1)" \
  "the rename form runs the rest of the script it just replaced" "status $VICTIM_STATUS"
check "$(cmp -s "$WORK/new-bytes" "$WORK/victim-ship.sh" && echo 1)" \
  "the destination holds the new bytes afterwards" "the install gets the shipped script"
check "$([ "$(ls "$WORK"/victim-ship.sh.ship.* 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && echo 1)" \
  "no staging file survives the rename" "no victim-ship.sh.ship.* left in $WORK"

# 2. The old form, same fixture: report what it does here. In the 2026-10-02 measurement it lost everything
#    after the replacement (and a `cp` over a running script can also stop with status 0, which is worse).
run_victim cp "$WORK/victim-cp.sh"
if [ "$(printf '%s\n' "$OUT" | grep -c '^after the self-ship: the rest of this script ran$')" = "0" ]; then
  ok "the in-place cp form is reproduced as losing the rest of the script" \
    "status $VICTIM_STATUS, no line after the replacement - the shape that killed the 2026-10-02 deploy"
else
  ok "the in-place cp form happened to survive this shape on this machine" \
    "status $VICTIM_STATUS - buffering-dependent, which is why the rename form is the guarantee and this is only reported"
fi

# 3. Neither form leaves a partial file at the destination: after both runs the destination is one of the two
#    complete scripts, never a prefix of one.
check "$([ "$(wc -c < "$WORK/victim-ship.sh")" = "$(wc -c < "$WORK/new-bytes")" ] && echo 1)" \
  "the shipped script is complete, not truncated" "destination $(wc -c < "$WORK/victim-ship.sh") bytes, source $(wc -c < "$WORK/new-bytes") bytes"

echo "test-deploy-self-ship: ALL PASS ($checks checks)"
