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
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }

if [ ! -x "$WABIN" ]; then
  echo "SKIP test-node-pins: no binary at $WABIN (build it: cd rust && cargo build -p wa-host)"
  exit 0
fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR"
# WASM_AGENT_LUA_ROOT: the Lua under test is THIS tree's, not the copy compiled into whatever binary happens to
# be built here. A pins test that ran the binary's embedded core would pass about the code of an older commit.
wa() { WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_HOME="$HOME_DIR" "$WABIN" --db "$HOME_DIR/probe.db" "$@"; }
echo "test-node-pins: $WABIN (store under $HOME_DIR)"

echo "test-node-pins: the store"
OUT="$(cd "$ROOT" && WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_HOME="$HOME_DIR" WA_SCRIPT="$ROOT/scripts/fixtures/pins-probe.lua" "$WABIN" --db "$HOME_DIR/probe.db" 2>&1)"
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

echo "test-node-pins: the pin is found by the name OR the node id (aliases resolve before the gate)"
same "a pin set under a name and an id" "$(value edge_set)" "ok"
same "it is found by the name" "$(value edge_by_name)" "true"
same "it is found by the node id alone" "$(value edge_by_id)" "true"
same "and by both" "$(value edge_by_name_and_id)" "true"
same "a different id does not match it" "$(value edge_by_other_id)" "false"
same "...and the record carries the id it was written for" "$(value edge_record_carries_id)" "aabbccddeeff0011"

echo "test-node-pins: a target that CONTAINS the awaited commit releases the pin"
same "the fixture repository is there" "$(value contain_repo)" "yes"
same "a rollback pin records the commit it went back from as its await" "$(value contain_pin_await)" "$(value contain_pin_from)"
same "a descendant of the awaited commit releases it" "$(value released_by_containment)" "true"
shows "...and says so by containment" "$(value released_by_containment_why)" "contains"
same "the awaited commit itself releases it" "$(value released_by_the_awaited_commit_itself)" "true"
same "with no checkout the answer is unknown, never released" "$(value no_tree_is_unknown)" "unknown"
same "the escape hatch names --unpin" "$(value escape_mentions_unpin)" "yes"

echo "test-node-pins: a rollback pin releases on what the OPERATOR named, not on what it rolled back from (item 2)"
same "a rollback pin carries no awaited commit by default" "$(value rollback_has_no_default_await)" "yes"
same "...it keeps what it went back from, for the reader" "$(value rollback_keeps_rolled_back_from)" "$(value contain_pin_from)"
same "a target that CONTAINS the commit it went back from does NOT release it" "$(value rollback_not_released_by_the_commit_it_went_back_from)" "false"
same "the pinned commit itself still releases it" "$(value rollback_released_by_its_own_commit)" "true"
same "the way out of a pin with no await does not promise a deploy" "$(value escape_no_await_does_not_promise_a_deploy)" "yes"
same "...and names --unpin" "$(value escape_no_await_names_unpin)" "yes"
same "a pin that HAS an await names the commit that releases it" "$(value escape_with_await_names_it)" "yes"

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

echo "test-node-pins: --force without a reason does not move a pinned node"
wa update mail --force > "$WORK/force-bare.out" 2>&1
rc=$?
[ "$rc" != 0 ] && ok "it refused (exit $rc)" || bad "a bare --force moved a pinned node"
shows "the refusal is by name" "$(cat "$WORK/force-bare.out")" "override_reason_required"
shows "...and says the override has to be readable later" "$(cat "$WORK/force-bare.out")" "why"
wa update mail --force --reason "the operator means it" > "$WORK/force-ok.out" 2>&1
shows "with --force --reason the gate is satisfied (the request reaches the transport)" "$(cat "$WORK/force-ok.out")" "unknown_node"
shows "...and the force is recorded in the pin history" "$(cat "$PINFILE")" "FORCED PAST: the operator means it"
case "$(cat "$WORK/deploy.out")" in
  *"no_prebuilt_binary"*|*"sentinel"*|*"mesh"*) bad "the gate let the request through to the transport" ;;
  *) ok "nothing reached the transport: the gate refused first" ;;
esac

echo "test-node-pins: --unpin names what it released, and needs a reason (items 5 and 6)"
wa update mail --unpin > "$WORK/unpin-bare.out" 2>&1
rc=$?
[ "$rc" != 0 ] && ok "an unpin with no reason is refused (exit $rc)" || bad "an unpin with no reason released a pin"
shows "the refusal is by name" "$(cat "$WORK/unpin-bare.out")" "unpin_reason_required"
same "and the pin is still in force" "$(value edge_by_name)" "true"
wa update mail --unpin --reason "release-glibc landed" > "$WORK/unpin.out" 2>&1
rc=$?
unpin_out="$(cat "$WORK/unpin.out")"
shows "the answer names this coordinator's store" "$unpin_out" "this coordinator's store"
shows "...and says whether the node's own pin was released" "$unpin_out" "its own pin"
hides "...without promising the node may move when its own pin stands" "$unpin_out" "may move it again"
shows "the store records the clear, not a deletion" "$(cat "$PINFILE")" "state=cleared"
shows "...with its reason" "$(cat "$PINFILE")" "reason=release-glibc landed"
if [ "$(printf '%s' "$unpin_out" | grep -c 'node_pin_not_released')" != 0 ]; then
  # There is no peer called "mail" in this fixture, so the node's own copy could not be reached - and the answer
  # says exactly that instead of claiming the node is free.
  [ "$rc" != 0 ] && ok "a release that could not reach the node fails, and says so" || bad "an unreachable node was reported as released"
  shows "...naming the rule" "$unpin_out" "node_pin_not_released"
  shows "...and how to release it there" "$unpin_out" "ON that node"
else
  bad "the answer did not report whether the node's own pin was released"
fi

printf 'test-node-pins: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
