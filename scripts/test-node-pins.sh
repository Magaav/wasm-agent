#!/usr/bin/env bash
# Does a rollback write a record, and does the next ordinary deploy obey it?
#
# WHAT THIS EXISTS FOR. On 18/11 three rollbacks were made by hand - mail and nextcloud back to their glibc-2.30
# binaries, the node on "work" back to a build the operator wanted - and none was recorded anywhere. The next
# ordinary deploy had no way to know a node had been put somewhere on purpose, so it installed main over it.
# The pin (lua/core/pins.lua) is that record: node, commit, reason, who, when, an optional "until" (flagged
# OVERDUE once it passes) and an optional awaited commit whose landing releases it.
#
# The test drives the real binary: the store through a Lua probe, the CLI through "wa update <node> --pin" and
# "--unpin", the gate through "wa update <node>" on a pinned node, and the report through the fleet view. It
# uses a private HOME and config, so it cannot touch this machine's pins.
#
# Usage:  bash scripts/test-node-pins.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
WABIN="${WA_BIN:-$TARGET_DIR/debug/wa}"
[ -x "$WABIN" ] || WABIN="$TARGET_DIR/release/wa"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found" ;; esac; }

if [ ! -x "$WABIN" ]; then
  echo "SKIP test-node-pins: no binary at $WABIN (build it: cd rust && cargo build -p wa-host)"
  exit 0
fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR"
wa() { WASM_AGENT_HOME="$HOME_DIR" "$WABIN" --db "$HOME_DIR/probe.db" "$@"; }
echo "test-node-pins: $WABIN (store under $HOME_DIR)"

echo "test-node-pins: the store"
OUT="$(cd "$ROOT" && WASM_AGENT_HOME="$HOME_DIR" WA_SCRIPT="$ROOT/scripts/fixtures/pins-probe.lua" "$WABIN" --db "$HOME_DIR/probe.db" 2>&1)"
value() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
shows "the probe ran" "$OUT" "path="
same "a pin records the commit" "$(value active_commit)" "1111111111111111111111111111111111111111"
same "it records the reason" "$(value active_reason)" "held on the codeact build until it lands"
same "it records who" "$(value active_by_known)" "yes"
same "it records when" "$(value active_at_known)" "yes"
same "it keeps the until" "$(value active_until)" "2020-01-01"
same "a passed date is overdue" "$(value overdue)" "true"
same "the list has it" "$(value list_count)" "1"
same "the overdue list has it" "$(value overdue_count)" "1"
same "with no checkout and an awaited commit, the release question is unknown, never a silent yes" "$(value released_by_other)" "unknown"
same "the pinned commit itself is not a move forward" "$(value released_by_pinned_commit)" "true"
same "a second pin supersedes the first" "$(value second_supersedes)" "yes"
same "the history is kept" "$(value history_count)" "2"
same "the newest pin is in force" "$(value active_now)" "4444444444444444444444444444444444444444"
same "clearing works" "$(value clear)" "ok"
same "after clearing the node is not pinned" "$(value after_clear_active)" "none"
same "the clear carries its reason" "$(value clear_reason)" "the fix landed"
same "a pin without a reason is refused" "$(value no_reason)" "refused"
same "and the refusal is by name" "$(value no_reason_error)" "pin_reason_required"

echo "test-node-pins: the fleet view"
same "the report lists the pins" "$(value fleet_pins)" "1"
same "and flags the overdue ones" "$(value fleet_overdue)" "1"
same "a peer that does not carry the store says the field is absent" "$(value fleet_peer_pins_absent)" "yes"
same "...and does not report it as a fact it failed to read" "$(value fleet_peer_pins_not_missing)" "not-listed"

echo "test-node-pins: the CLI"
wa update mail --pin --commit 0123456789012345678901234567890123456789 --reason "glibc 2.30 binary until release-glibc lands" --until release-glibc > "$WORK/pin.out" 2>&1
same "wa update mail --pin records a pin -> 0" "$?" "0"
shows "it says nothing was deployed" "$(cat "$WORK/pin.out")" "Nothing was deployed"
PINFILE="$HOME_DIR/.wasm-agent/pins.txt"
[ -f "$PINFILE" ] || PINFILE="$(find "$HOME_DIR" -name pins.txt | head -1)"
shows "the store has mail" "$(cat "$PINFILE" 2>/dev/null)" "node=mail"
shows "...with the commit" "$(cat "$PINFILE" 2>/dev/null)" "commit=0123456789012345678901234567890123456789"
shows "...as a plain pin" "$(cat "$PINFILE" 2>/dev/null)" "kind=pin"

echo "test-node-pins: a normal deploy of a pinned node is refused"
wa update mail --commit 0123456789012345678901234567890123456780 --reason "an ordinary deploy" > "$WORK/deploy.out" 2>&1
rc=$?
[ "$rc" != 0 ] && ok "it refused (exit $rc)" || bad "a pinned node was deployed"
shows "the refusal is by name" "$(cat "$WORK/deploy.out")" "node_pinned"
shows "it quotes the pin" "$(cat "$WORK/deploy.out")" "glibc 2.30 binary until release-glibc lands"
shows "it names the ways out" "$(cat "$WORK/deploy.out")" "--unpin"
shows "...including the recorded override" "$(cat "$WORK/deploy.out")" "--force --reason"
case "$(cat "$WORK/deploy.out")" in
  *"no_prebuilt_binary"*|*"sentinel"*|*"mesh"*) bad "the gate let the request through to the transport" ;;
  *) ok "nothing reached the transport: the gate refused first" ;;
esac

echo "test-node-pins: --unpin"
wa update mail --unpin --reason "release-glibc landed" > "$WORK/unpin.out" 2>&1
same "wa update mail --unpin -> 0" "$?" "0"
shows "it says the node may move again" "$(cat "$WORK/unpin.out")" "may move it again"
shows "the store records the clear, not a deletion" "$(cat "$PINFILE")" "state=cleared"
shows "...with its reason" "$(cat "$PINFILE")" "reason=release-glibc landed"

printf 'test-node-pins: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
