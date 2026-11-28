#!/usr/bin/env bash
# A FACTORY LOOP REFRESHES THE CLONE BETWEEN ITERATIONS AND RE-EXECS WHEN ITS OWN SCRIPT CHANGED (27/11).
#
# WHAT HAPPENED: the units refresh the clone in ExecStartPre, which runs ONCE, at unit start. The health loop therefore
# kept running the code it started with: q#178 (budget 3600) sat unused for 45 minutes until the unit was restarted by hand.
# A loop is the one place where "refresh at start" is not enough, because the loop IS the long-lived thing.
#
# THE CONTRACT, and it is deliberately narrow:
#   * called at the TOP of an iteration (never mid-iteration): refresh the clone, then compare THIS script's content with
#     what is on disk now;
#   * if it changed, `exec` it with the same arguments - the next thing that runs is the new code, from byte one;
#   * a failed refresh does NOT stop the loop (the clone may be mid-landing): it returns non-zero and the caller keeps
#     going with the code it has, and the next iteration tries again.
#
# What it is not: a re-exec on every change to the tree. Only THIS script's bytes matter, so a landing that touches another
# factory file leaves a running loop alone.

# wa_factory_refresh_self <script-path> [args...]
wa_factory_refresh_self() {
  # WA_FACTORY_ORIG is set by the factory re-exec prologue (slots5, quarantine-watch): $0 is then a private COPY in
  # _orch/run-copies, and the file to compare and re-exec is the original in the clone.
  # An explicit argument wins: a factory-launched session already exports WA_FACTORY_ORIG, and preferring the
  # environment over the caller's argument made the helper compare somebody else's script (measured 27/11).
  local self="${1:-${WA_FACTORY_ORIG:-$0}}"
  shift 2>/dev/null || true
  [ -f "$self" ] || return 0
  local here
  here="$(cd "$(dirname "$self")" && pwd)"
  local before after
  before="$(sha256sum "$self" 2>/dev/null | cut -d' ' -f1)"
  # The clone is the script's own repository directory: <clone>/factory/<script>.sh
  # A REFRESH THAT FAILS MUST BE VISIBLE (28/11). It used to be `--quiet 2>/dev/null || return 1`: a clone that could not
  # fast-forward - local changes in it, an unreachable origin - left the loop running yesterday's code FOR HOURS with not one
  # line in the journal, which is exactly how "the refresh never took effect" was reported. The loop still is not stopped by
  # it (the next iteration retries), but the reason is now in the log with the iteration's own timestamp.
  local problem
  if ! problem="$(bash "$here/clone.sh" --refresh --quiet 2>&1)"; then
    printf '%s factory: refresh failed, still running %s: %s\n' "$(date -u +%FT%TZ)" "$self" \
      "$(printf '%s' "$problem" | tail -1)" >&2
    return 1
  fi
  after="$(sha256sum "$self" 2>/dev/null | cut -d' ' -f1)"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    echo "$(date -u +%FT%TZ) factory: $self changed (${before:0:8} -> ${after:0:8}); re-executing between iterations" >&2
    # `exec bash <script>`, not `exec <script>`: a factory script in the clone need not carry the executable bit (every
    # unit runs it as `/usr/bin/bash <path>`), and `exec` of a non-executable file fails with 126 (measured 27/11).
    exec /usr/bin/bash "$self" "$@"
  fi
  return 0
}
