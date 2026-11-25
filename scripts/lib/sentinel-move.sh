#!/usr/bin/env bash
# THE SENTINEL'S MOVE to a new version, and what a failed start leaves in charge (slice (b), requirement 8).
#
# THE ORDER, and why it is this order:
#   1. the version is sealed and current points at it   (scripts/version-install.sh steps 4-5)
#   2. the NODE is restarted, and it must answer healthy before anything else moves
#   3. the SENTINEL is restarted, so that it runs the new version too
# A sentinel that moves first would watch a node it cannot start; a node that moves without a supervisor is one
# crash away from a node nobody restarts. So step 3 REFUSES to run until it is told the node answered
# (sentinel_move_before_node), which is a refusal by name rather than a comment.
#
# A FAILED SENTINEL START LEAVES THE OLD ONE SUPERVISING. The unit's ExecStart runs the sentinel through the
# pointer, so "the previous version" is not a path anything names any more - the fallback writes a drop-in that
# repoints ExecStart at the PREVIOUS version's absolute path (exactly the operator's own repair in the 24/11
# incident), reloads, restarts, and says so. If even that does not come back, the failure is named
# (sentinel_move_failed_nothing_supervising) instead of silently leaving a node with no watcher.
#
# Every systemctl call goes through WA_SENTINEL_UNIT_SYSTEMCTL (a stub under the row runner) and the unit and its
# drop-in live in WA_SENTINEL_UNIT_DIR, so the whole move is drivable on a scratch root with no live unit in reach.

wa_sentinel_move_unit() { printf '%s' "${WA_SENTINEL_UNIT_NAME:-wa-sentinel.service}"; }
wa_sentinel_move_dir()  { wa_sentinel_unit_dir 2>/dev/null || printf '%s' "${WA_SENTINEL_UNIT_DIR:-$HOME/.config/systemd/user}"; }
wa_sentinel_move_systemctl() { printf '%s' "${WA_SENTINEL_UNIT_SYSTEMCTL:-systemctl}"; }

# <install> <current-version-dir> <previous-version-dir> -> the three absolute paths, no side effects.
wa_sentinel_move_plan() {
  local install="${1:?install}" current="${2:-}" previous="${3:-}"
  printf 'sentinel_move_plan install=%s/wa-sentinel current=%s/wa-sentinel previous=%s drop_in=%s/%s.d/version-fallback.conf\n' \
    "$install" "${current:-?}" "${previous:-?}" "$(wa_sentinel_move_dir)" "$(wa_sentinel_move_unit)"
}

wa_sentinel_move_active() { # <timeout-seconds>
  local limit="${1:-15}" waited=0 systemctl_bin
  systemctl_bin="$(wa_sentinel_move_systemctl)"
  while [ "$waited" -lt $((limit * 10)) ]; do
    if [ "$("$systemctl_bin" --user is-active "$(wa_sentinel_move_unit)" 2>/dev/null | head -1)" = "active" ]; then
      return 0
    fi
    sleep 0.1; waited=$((waited + 1))
  done
  return 1
}

# <previous-version-dir> -> 0 when the old sentinel is supervising again, 1 when it is not.
wa_sentinel_move_fallback() {
  local previous="${1:?previous version dir}" dir unit systemctl_bin dropin
  unit="$(wa_sentinel_move_unit)"; dir="$(wa_sentinel_move_dir)"; systemctl_bin="$(wa_sentinel_move_systemctl)"
  [ -x "$previous/wa-sentinel" ] || { printf 'sentinel_fallback_no_binary: %s/wa-sentinel\n' "$previous" >&2; return 1; }
  dropin="$dir/$unit.d"; mkdir -p "$dropin" || return 1
  {
    printf '# Written by version-install: the new sentinel did not start, so this unit runs the version before it.\n'
    printf '# The repair the operator made in the 24/11 incident, made explicit and reported.\n'
    printf '[Service]\nExecStart=\nExecStart=%s/wa-sentinel watch\n' "$previous"
  } > "$dropin/version-fallback.conf" || return 1
  "$systemctl_bin" --user daemon-reload >/dev/null 2>&1 || true
  "$systemctl_bin" --user restart "$unit" >/dev/null 2>&1 || true
  wa_sentinel_move_active 15 || return 1
  printf 'sentinel_kept_old_version %s\n' "$previous"
  return 0
}

# <install> <previous-version-dir> [<timeout>] -> 0 moved, 3 kept the old one, 4 nothing supervising.
# The caller sets WA_SENTINEL_NODE_HEALTHY=1 only after the node answered on the new version.
wa_sentinel_move() {
  local install="${1:?install}" previous="${2:-}" limit="${3:-15}" systemctl_bin
  [ "${WA_SENTINEL_NODE_HEALTHY:-}" = 1 ] || {
    printf 'sentinel_move_before_node: the node has not been shown healthy on the new version; the sentinel moves AFTER it\n' >&2
    return 5
  }
  systemctl_bin="$(wa_sentinel_move_systemctl)"
  "$systemctl_bin" --user restart "$(wa_sentinel_move_unit)" >/dev/null 2>&1 || true
  if wa_sentinel_move_active "$limit"; then
    printf 'sentinel_moved %s\n' "$(readlink -f "$(wa_share_root)/current/wa-sentinel" 2>/dev/null || printf '%s' "$install/wa-sentinel")"
    return 0
  fi
  printf 'sentinel_move_failed: the new sentinel did not come up; putting the previous version back in charge\n' >&2
  if [ -n "$previous" ] && wa_sentinel_move_fallback "$previous"; then
    return 3
  fi
  printf 'sentinel_move_failed_nothing_supervising: neither the new nor the previous sentinel is active\n' >&2
  return 4
}

