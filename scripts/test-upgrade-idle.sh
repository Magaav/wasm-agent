#!/usr/bin/env bash
# The idle wait is bounded by *lack of progress*, not by wall time.
#
# The failure this exists for: a legitimate 40-minute turn made every queued upgrade
# wait `IDLE_TIMEOUT` (900s), fail, and be retried while the node stayed busy. A run
# whose worker is alive is doing work; only a worker that has stopped reporting may be
# given up on.
#
# `health()` is stubbed through PATH (upgrade.sh asks the node with `curl`), and the
# candidate is pre-proved by hash so the scratch-port step is skipped. So this exercises
# the wait loop in a second or two, with no node, no network, and no touch of the
# operator's install or the real sentinel.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/wa-upgidle-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

INST="$WORK/install"
mkdir -p "$INST/scripts"
case "$(uname -s 2>/dev/null)" in
  CYGWIN*|MINGW*|MSYS*) WA_NAME=wa.exe ;;
  *) WA_NAME=wa ;;
esac
NEW="$WORK/candidate-${WA_NAME}"
printf '#!/bin/sh\nexit 0\n' > "$NEW"
chmod +x "$NEW"
cp -f "$NEW" "$INST/$WA_NAME"
HASH="$(sha256sum < "$NEW" | awk '{print $1}')"
# `commit=unknown` skips the downgrade guard, which cannot compare against an unknown commit.
printf 'commit=unknown\nsource_commit_hint=unknown\nsha256=%s\n' "$HASH" > "$INST/installed.txt"
# The proof cache is the candidate's hash: a build that already answered is not proved again, so the
# wait is reached immediately instead of after a scratch node starts.
printf '%s\n' "$HASH" > "$INST/.upgrade-proof"

# Stub `curl`: the wait loop's only source of truth about the node.
STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/curl" <<'SH'
#!/bin/sh
printf '%s' "$WA_TEST_HEALTH"
SH
chmod +x "$STUB/curl"

run() { # state idle_timeout idle_max
  WA_TEST_HEALTH="$1" WA_INSTALL_DIR="$INST" WA_PORT=1 \
    WA_IDLE_TIMEOUT="$2" WA_IDLE_MAX_SECONDS="$3" \
    PATH="$STUB:$PATH" bash "$ROOT/scripts/upgrade.sh" "$NEW" 2>&1
}

echo "--- a live worker: waited on, stopped only by the wall-clock cap ---"
alive="$(run '{"current":{"label":"POST /chat"},"worker":"alive","queue":1}' 1 2)"
printf '%s\n' "$alive" | sed 's/^/    /'
case "$alive" in
  *"WA_IDLE_MAX_SECONDS"*) echo "  ok: a live worker is waited on past the stall deadline" ;;
  *) echo "  FAIL: expected the wall-clock cap to stop it, got the above"; exit 1 ;;
esac
case "$alive" in
  *"has not reported progress"*) echo "  FAIL: a live worker was mistaken for a stalled one"; exit 1 ;;
  *) echo "  ok: it was not mistaken for a stalled worker" ;;
esac

echo "--- a stalled worker: given up on after the stall deadline ---"
stalled="$(run '{"current":{"label":"POST /chat"},"worker":"stalled","queue":1}' 1 0)"
printf '%s\n' "$stalled" | sed 's/^/    /'
case "$stalled" in
  *"has not reported progress"*) echo "  ok: a stalled worker is given up on" ;;
  *) echo "  FAIL: expected the stall deadline, got the above"; exit 1 ;;
esac

echo "upgrade idle-wait ok"
