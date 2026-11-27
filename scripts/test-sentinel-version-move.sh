#!/usr/bin/env bash
# THE SENTINEL'S MOVE, AND WHAT A FAILED START LEAVES IN CHARGE (slice (b), requirement 8).
#
# Requirement 8 has three parts and this row pins all three:
#   - the ORDER: the sentinel moves only after the node has been shown healthy on the new version; asked to move
#     first it REFUSES by name (sentinel_move_before_node) and touches nothing;
#   - the MOVE: one restart through the pointer, and "active" is checked, not assumed;
#   - the FALLBACK: a sentinel that does not come up leaves the PREVIOUS version supervising, through a drop-in
#     that repoints ExecStart at the previous version's absolute path (the operator's own repair in the 24/11
#     incident); if even that fails, the failure is NAMED (nothing supervising) instead of silent.
#
# It runs with a stub systemctl (WA_SENTINEL_UNIT_SYSTEMCTL) and a scratch unit dir, so no live unit is in reach,
# and it starts nothing that outlives it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/scratch-env.sh

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-sentinel-version-move: $*" >&2; exit 1; }

BASE="${WA_ROW_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W="$(mktemp -d "$BASE/wa-sentinel-move-XXXXXX")" || { echo "FAIL: no scratch" >&2; exit 2; }
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

wa_scratch_env_apply "$W" >/dev/null
export WA_SENTINEL_UNIT_NAME=wa-sentinel.service

# The stub systemctl: it records every call and obeys $W/restart-mode (ok | fail-new | never).
mkdir -p "$W/bin" "$W/units" "$WA_SENTINEL_UNIT_DIR" 2>/dev/null || true
export WA_SENTINEL_UNIT_DIR="$W/units"
STUB="$WA_SENTINEL_UNIT_SYSTEMCTL"
cat > "$STUB" <<STUBEOF
#!/bin/sh
printf '%s\n' "\$*" >> "$W/systemctl.calls"
unit="${3:-}"
case "\$1 \$2" in
  "--user daemon-reload") exit 0 ;;
  "--user is-active") [ "\$(cat "$W/state" 2>/dev/null)" = active ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
  "--user restart")
    mode="\$(cat "$W/restart-mode" 2>/dev/null)"
    case "\$mode" in
      ok) echo active > "$W/state" ;;
      fail-new) if [ -f "$WA_SENTINEL_UNIT_DIR/wa-sentinel.service.d/version-fallback.conf" ]; then echo active > "$W/state"; else echo inactive > "$W/state"; fi ;;
      *) echo inactive > "$W/state" ;;
    esac
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

. scripts/lib/sentinel-move.sh
scratch_check="$(wa_scratch_env_check "$W" 2>&1)" || { printf '%s\n' "$scratch_check" >&2; fail "the row's environment is NOT ISOLATED: nothing was run"; }

# The previous version, as a version folder the fallback can name by absolute path.
PREV="$W/versions/previous"
mkdir -p "$PREV"
printf '#!/bin/sh\nexit 0\n' > "$PREV/wa-sentinel"; chmod +x "$PREV/wa-sentinel"
INSTALL="$W/install"; mkdir -p "$INSTALL"

# 1. The plan names all three paths, and changes nothing.
PLAN="$(wa_sentinel_move_plan "$INSTALL" "$W/versions/current" "$PREV")"
printf '%s\n' "$PLAN" | grep -q "previous=$PREV" || fail "the plan does not name the previous version"
printf '%s\n' "$PLAN" | grep -q 'drop_in=' || fail "the plan does not name the drop-in it would write"
[ ! -e "$WA_SENTINEL_UNIT_DIR/wa-sentinel.service.d" ] || fail "the plan wrote a drop-in"
[ ! -s "$W/systemctl.calls" ] || fail "the plan called systemctl"
ok

# 2. Before the node is healthy the sentinel must not move - and must say why.
if WA_SENTINEL_NODE_HEALTHY= wa_sentinel_move "$INSTALL" "$PREV" 5 > "$W/early.log" 2>&1; then
  fail "the sentinel moved before the node was shown healthy"
fi
grep -q 'sentinel_move_before_node' "$W/early.log" || { sed -n '1,3p' "$W/early.log" >&2; fail "the refusal is not named sentinel_move_before_node"; }
[ ! -s "$W/systemctl.calls" ] || fail "a refused move still called systemctl"
ok

# 3. The move: one restart, then active.
echo ok > "$W/restart-mode"
WA_SENTINEL_NODE_HEALTHY=1 wa_sentinel_move "$INSTALL" "$PREV" 10 > "$W/move.log" 2>&1 || { sed -n '1,3p' "$W/move.log" >&2; fail "the move failed on a stub that comes up"; }
grep -q 'sentinel_moved' "$W/move.log" || fail "the move does not say it moved"
grep -q -- '--user restart' "$W/systemctl.calls" || fail "the move never asked for a restart"
ok

# 4. A new sentinel that does not come up leaves the PREVIOUS version supervising, by absolute path.
: > "$W/systemctl.calls"; rm -f "$W/state"; echo fail-new > "$W/restart-mode"
WA_SENTINEL_NODE_HEALTHY=1 wa_sentinel_move "$INSTALL" "$PREV" 3 > "$W/fallback.log" 2>&1
rc=$?
[ "$rc" = 3 ] || { sed -n '1,4p' "$W/fallback.log" >&2; fail "a failed move must keep the old sentinel (rc 3), got $rc"; }
grep -q 'sentinel_kept_old_version' "$W/fallback.log" || fail "the fallback does not say who is supervising"
DROPIN="$WA_SENTINEL_UNIT_DIR/wa-sentinel.service.d/version-fallback.conf"
[ -f "$DROPIN" ] || fail "no drop-in was written, so nothing repoints the unit at the previous version"
grep -q "^ExecStart=$PREV/wa-sentinel watch$" "$DROPIN" || { sed -n '1,6p' "$DROPIN" >&2; fail "the drop-in does not run the PREVIOUS version's absolute path"; }
grep -q -- '--user daemon-reload' "$W/systemctl.calls" || fail "the fallback did not reload the manager"
ok

# 5. Nothing comes up at all: the failure is NAMED, not silent.
: > "$W/systemctl.calls"; echo never > "$W/restart-mode"; rm -f "$W/state"
rm -rf "$WA_SENTINEL_UNIT_DIR/wa-sentinel.service.d"
WA_SENTINEL_NODE_HEALTHY=1 wa_sentinel_move "$INSTALL" "$PREV" 1 > "$W/never.log" 2>&1
rc=$?
[ "$rc" = 4 ] || { sed -n '1,4p' "$W/never.log" >&2; fail "with nothing supervising the result must be rc 4, got $rc"; }
grep -q 'sentinel_move_failed_nothing_supervising' "$W/never.log" || fail "the nothing-supervising failure is not named"
ok

echo "sentinel version move ok ($n checks)"

