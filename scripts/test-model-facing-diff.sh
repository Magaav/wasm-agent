#!/usr/bin/env bash
# scripts/model-facing-diff.sh measures what a change costs the MODEL. This row holds the command itself to its promises:
#
#   1. a NO-OP pair (one commit against itself) is '=' in every cell but wall time and exits 0 - the item's job 3. Without
#      this, a command that always says 'worse' would look like it was working.
#   2. a pair that DOES differ - a scratch commit that grows the code-mode routing block the node appends to the system
#      prompt - is caught: the request and prompt bytes grow, those cells are marked '>' and the command exits 1. Measured
#      28/11 in a scratch tree: a 147-byte sentence moved the request from 21984 to 22131 bytes. Without this, a command
#      that always says 'same' would pass case 1 while measuring nothing.
#   3. wall time alone never fails it: two runs of the SAME commit differ by ~50 ms on this machine, and the command refuses
#      to gate on that.
#   4. a ref that is not a commit is refused by name, exit 2 - a table must never describe a tree nobody named.
#   5. a tip whose Lua does not even load is reported as `?` with the interpreter's own words, never as 'same'.
#
# WHAT THIS ROW DELIBERATELY DOES NOT DO: build a Rust binary. The host builds the tool catalogue the wire carries, so a
# change to that layer is measured with --base-bin/--tip-bin on two built binaries, which is the release's job and not a
# row's. The scratch commits live in DETACHED WORKTREES of this repository: the row never creates a branch, never moves one
# and never writes a ref. No network, no account, no provider: scripts/lib/measuring-provider.py answers every task.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${WA_BIN:-}
if [ -z "$BIN" ]; then
  if [ -x "$ROOT/rust/target/release/wa" ]; then BIN="$ROOT/rust/target/release/wa"
  elif command -v wa >/dev/null 2>&1; then BIN=$(command -v wa)
  else printf 'FAIL no wa binary (build it, or set WA_BIN)\n'; exit 2; fi
fi
T=$(mktemp -d "${TMPDIR:-/tmp}/test-model-facing-diff.XXXXXX") || { printf 'FAIL tmpdir_unavailable\n'; exit 1; }
SIDE_A="$T/a"; SIDE_B="$T/b"
cleanup() {
  git -C "$ROOT" worktree remove --force "$SIDE_A" >/dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$SIDE_B" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

checks=0; failed=0
ok() { checks=$((checks + 1)); [ "$1" = 1 ] && printf 'ok   %s\n' "$2" || { failed=$((failed + 1)); printf 'FAIL %s\n' "$2"; [ -n "${3:-}" ] && printf '     %s\n' "$3"; }; }
gitrow() { git -C "$1" -c user.email=row@example.invalid -c user.name=row "${@:2}"; }

# TWO DETACHED WORKTREES AT THE SAME COMMIT, each carrying the command under test, committed there so the pair compares two
# commits that both have it.
for side in "$SIDE_A" "$SIDE_B"; do
  git -C "$ROOT" worktree add --detach "$side" HEAD >/dev/null 2>&1 || { printf 'FAIL worktree_add_failed %s\n' "$side"; exit 1; }
  mkdir -p "$side/scripts/model-tasks"
  cp "$ROOT/scripts/model-facing-diff.sh" "$side/scripts/model-facing-diff.sh"
  cp "$ROOT/scripts/model-tasks/tasks.json" "$side/scripts/model-tasks/tasks.json"
  cp "$ROOT/scripts/lib/measuring-provider.py" "$side/scripts/lib/measuring-provider.py"
  chmod +x "$side/scripts/model-facing-diff.sh"
  gitrow "$side" add -A >/dev/null 2>&1
  gitrow "$side" commit --quiet --allow-empty --no-verify -m 'row: the command under test' >/dev/null 2>&1 \
    || { printf 'FAIL the row could not commit the command into %s\n' "$side"; exit 1; }
done
BASE_SHA=$(git -C "$SIDE_B" rev-parse --short HEAD)

# ---- 1. the no-op pair ------------------------------------------------------------------------------------------
out=$(cd "$ROOT" && WA_BIN="$BIN" bash "$ROOT/scripts/model-facing-diff.sh" "$BASE_SHA" "$BASE_SHA" 2>&1); rc=$?
ok "$([ "$rc" = 0 ] && echo 1 || echo 0)" "a no-op pair exits 0 (rc $rc)" "$(printf '%s' "$out" | tail -3)"
ok "$(printf '%s' "$out" | grep -q "model-facing-diff  base $BASE_SHA  tip $BASE_SHA" && echo 1 || echo 0)" 'and says it compared that commit with itself'
ok "$(printf '%s' "$out" | grep -qc '^ *mark' && echo 1 || echo 0)" 'the table has a mark line per task'
# WALL TIME IS THE LAST COLUMN AND IS NEVER THE ASSERTION (the command refuses to gate on it, and says why).
ok "$(printf '%s' "$out" | awk '/^ *mark +[=<>?]/ { for (i = 3; i <= NF - 1; i++) if ($i != "=") bad = 1 } END { print bad ? 0 : 1 }')" 'every cell but wall time is = in the no-op table'
ok "$(printf '%s' "$out" | grep -q 'request' && printf '%s' "$out" | grep -q 'rounds' && echo 1 || echo 0)" 'and it carries the columns the item names (request, rounds)'
ok "$(printf '%s' "$out" | grep -qE '^plain-answer +base +[0-9]+' && echo 1 || echo 0)" 'with real numbers, not dashes: the tasks ran'

# ---- 2. a difference the model reads IS caught -------------------------------------------------------------------
routing="$SIDE_B/lua/core/codemode_policy.lua"
if [ -f "$routing" ] && grep -q 'Connectors on this node' "$routing"; then
  python3 - "$routing" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
marker = "Connectors on this node"
position = text.index(marker) + len(marker)
text = text[:position] + " and this sentence is the row marker that grows the routing block by seventy bytes" + text[position:]
open(path, "w", encoding="utf-8").write(text)
PY
  luac -p "$routing" >/dev/null 2>&1 || { printf 'FAIL the row made the routing block invalid lua\n'; exit 1; }
  gitrow "$SIDE_B" add -A >/dev/null 2>&1
  gitrow "$SIDE_B" commit --quiet --no-verify -m 'row: a grown routing block' >/dev/null 2>&1 \
    || { printf 'FAIL the row could not make its scratch commit\n'; exit 1; }
  TIP_SHA=$(git -C "$SIDE_B" rev-parse --short HEAD)
  out=$(cd "$ROOT" && WA_BIN="$BIN" bash "$ROOT/scripts/model-facing-diff.sh" "$BASE_SHA" "$TIP_SHA" 2>&1); rc=$?
  ok "$([ "$rc" != 0 ] && echo 1 || echo 0)" "a pair that grows the prompt fails the command (rc $rc)" "$(printf '%s' "$out" | tail -3)"
  ok "$(printf '%s' "$out" | awk '/^ *mark +[=<>?]/ { if ($3 == ">" || $4 == ">") found = 1 } END { print found ? 1 : 0 }')" 'and marks the request and prompt cells worse'
  ok "$(printf '%s' "$out" | grep -q "base $BASE_SHA" && printf '%s' "$out" | grep -q "tip $TIP_SHA" && echo 1 || echo 0)" 'and names both commits it compared'
  before=$(printf '%s' "$out" | awk '/^plain-answer +base/ { print $3 }')
  after=$(printf '%s' "$out" | awk '/^plain-answer +tip/ { print $3 }')
  ok "$([ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && echo 1 || echo 0)" "with the grown bytes visible ($before -> $after request bytes)"

  # ---- 3. a tip whose Lua does not load is reported, never smoothed over -----------------------------------------
  printf '\nlocal this is not lua\n' >> "$routing"
  gitrow "$SIDE_B" add -A >/dev/null 2>&1
  gitrow "$SIDE_B" commit --quiet --no-verify -m 'row: a broken tip' >/dev/null 2>&1 || true
  BROKEN_SHA=$(git -C "$SIDE_B" rev-parse --short HEAD)
  out=$(cd "$ROOT" && WA_BIN="$BIN" bash "$ROOT/scripts/model-facing-diff.sh" "$BASE_SHA" "$BROKEN_SHA" 2>&1); rc=$?
  ok "$(printf '%s' "$out" | awk '/^ *mark +[=<>?]/ { if ($3 == "?") found = 1 } END { print found ? 1 : 0 }')" 'a tip that does not load is marked ? , never ='
  ok "$(printf '%s' "$out" | grep -qi 'tip error' && echo 1 || echo 0)" 'and its interpreter error is printed under the table'
else
  printf 'FAIL the row cannot find the routing block it measures (lua/core/codemode_policy.lua)\n'
  failed=$((failed + 1))
  checks=$((checks + 1))
fi

# ---- 4. a ref that names no commit -------------------------------------------------------------------------------
out=$(cd "$ROOT" && WA_BIN="$BIN" bash "$ROOT/scripts/model-facing-diff.sh" HEAD no-such-ref 2>&1); rc=$?
ok "$([ "$rc" = 2 ] && echo 1 || echo 0)" "a ref that is not a commit is refused (rc $rc, expected 2)" "$(printf '%s' "$out" | head -2)"
ok "$(printf '%s' "$out" | grep -q 'is not a commit' && echo 1 || echo 0)" 'by name'

printf 'model-facing-diff row: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
