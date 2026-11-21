#!/usr/bin/env bash
# "wa release trust-key": the trust set written by the command that reads it, and the fleet door to it.
#
# THE DEFECT THIS PINS (21/11, hand fix 2 of the node-7ddbfa98036a rollout). Nothing in wa wrote a
# trusted-keys file. An operator added a release key BY HAND, and a hand-written file without the
# "wa-trusted-keys v1" header made every release on that node refuse as release_unsigned_or_forged - the
# correct refusal (a key file a reader partly understands trusts something else) reached by the worst path.
#
# WHAT RUNS HERE. The REAL binary's own verb, as a separate process, against a scratch HOME - never the
# operator's trust file. Each case asserts an observable fact about the file or the exit status: the header
# is there, the file reads back through the parser a release verification uses, the replaced file is kept,
# a file this node cannot read is not overwritten, a retire removes the key, a named id cannot be re-pointed
# at different bytes, and the fleet form refuses an unknown node by name instead of reporting success.
#
# Usage: bash scripts/test-release-trust.sh [<wa binary>]
# Exit 0 all checks hold; 1 a check failed. SKIPs (exit 0) when no binary has been built on this machine,
# the same arrangement as scripts/test-release-signing.sh.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s %s\n' "$2" "${3:-}"; fi; }
fail_hard() { echo "test-release-trust: $*" >&2; exit 1; }

BIN="${1:-${WA_BIN:-$ROOT_DIR/rust/target/release/wa}}"
[ -x "$BIN" ] || { echo "SKIP test-release-trust: no built wa binary at $BIN (build it, or pass one)"; exit 0; }

# The scratch-home rule: this test gives a node a home, so it must prove the home is not the operator's.
. "$ROOT_DIR/scripts/lib/scratch-home.sh" || fail_hard "no scripts/lib/scratch-home.sh to prove the scratch home"
# A node puts TMPDIR inside its own root (docs/ONEROOT.md), so the store is where a bare mktemp would land -
# and the guard above is right to refuse that. Move this test's own scratch root out of the store instead.
SCRATCH_ROOT="${TMPDIR:-/tmp}"
case "$SCRATCH_ROOT" in
  "${HOME:-/nonexistent}"|"${HOME:-/nonexistent}"/*) SCRATCH_ROOT=/tmp ;;
esac
W="$(mktemp -d "$SCRATCH_ROOT/wa-release-trust-XXXXXX")" || fail_hard "no scratch directory"
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT

HOME_DIR="$W/home"
mkdir -p "$HOME_DIR"
wa_scratch_home_guard "$HOME_DIR" || fail_hard "this test would act on the operator's own node home"
KEY_FILE="$HOME_DIR/release-keys.txt"
HEX="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
HEX2="ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"

# One invocation of the node, with a home of its own and nothing else from this machine's environment.
run_wa() {
  LAST_OUT="$(env -i HOME="$HOME_DIR" USERPROFILE="$HOME_DIR" WASM_AGENT_HOME="$HOME_DIR" \
      PATH=/usr/local/bin:/usr/bin:/bin "$BIN" "$@" 2>&1)"
  LAST=$?
}

# ---- (a) the command writes the header, and the file reads back -----------------------------------------
run_wa release trust-key release-signing-test-a "$HEX"
ok "$([ "$LAST" = "0" ] && echo 1 || echo 0)" "a key is trusted and the command answers 0" "exit $LAST: $LAST_OUT"
ok "$(grep -q 'read back through the same parser' <<<"$LAST_OUT" && echo 1 || echo 0)" \
  "the answer says the file was read back through the parser a verification uses" "$LAST_OUT"
ok "$([ -f "$KEY_FILE" ] && head -1 "$KEY_FILE" | grep -qx 'wa-trusted-keys v1' && echo 1 || echo 0)" \
  "the file carries the 'wa-trusted-keys v1' header (the stanza whose absence refused every release)"
ok "$(grep -qx "key release-signing-test-a $HEX" "$KEY_FILE" && echo 1 || echo 0)" \
  "and the key line names the id and its public hex"

# ---- (b) the key is accepted by a RELEASE VERIFICATION --------------------------------------------------
# The point of the file is that a verification reads it, so this asks the binary itself: a sums file signed
# by nobody must refuse for being unsigned, and the run must not fail because the key file is unreadable.
SIGDIR="$W/release"
mkdir -p "$SIGDIR"
printf 'aaaa  wa-x86_64-unknown-linux-gnu-0123456789ab\n' > "$SIGDIR/SHA256SUMS"
run_wa release verify "$SIGDIR" --key "$KEY_FILE"
ok "$(grep -q 'release_unsigned_or_forged' <<<"$LAST_OUT" && echo 1 || echo 0)" \
  "a verification reads the written file: an unsigned release refuses for being unsigned" "$LAST_OUT"
ok "$([ "$LAST" = "2" ] && echo 1 || echo 0)" "and a missing signature is release.rs's own code 2" "exit $LAST"

# ---- (c) the file it replaced is kept ----------------------------------------------------------------
cp -f "$KEY_FILE" "$W/before.txt"
run_wa release trust-key release-signing-test-b "$HEX2"
ok "$([ "$LAST" = "0" ] && echo 1 || echo 0)" "a second key is added" "exit $LAST: $LAST_OUT"
ok "$([ -f "$KEY_FILE.bak" ] && cmp -s "$KEY_FILE.bak" "$W/before.txt" && echo 1 || echo 0)" \
  "the file it replaced is kept as <path>.bak, byte for byte"
ok "$([ "$(grep -c '^key ' "$KEY_FILE")" = "2" ] && echo 1 || echo 0)" \
  "and the key that was already trusted is still there"

# ---- (d) a file this node cannot read is NOT overwritten ------------------------------------------------
# The exact shape of the hand-written file the rollout used: keys, no header.
printf 'key handwritten $HEX\n' > "$KEY_FILE"
cp -f "$KEY_FILE" "$W/handwritten.txt"
run_wa release trust-key release-signing-test-c "$HEX2"
ok "$([ "$LAST" != "0" ] && echo 1 || echo 0)" "a trust file this node cannot read is refused" "exit $LAST: $LAST_OUT"
ok "$(cmp -s "$KEY_FILE" "$W/handwritten.txt" && echo 1 || echo 0)" \
  "and it is left exactly as it was: the operator has to see its error before anything is added"
printf 'wa-trusted-keys v1\n' > "$KEY_FILE"
run_wa release trust-key release-signing-test-a "$HEX"
ok "$([ "$LAST" = "0" ] && [ "$(head -1 "$KEY_FILE")" = "wa-trusted-keys v1" ] && echo 1 || echo 0)" \
  "a readable file is extended, and the header the parser needs is still the first line"

# ---- (e) a named id cannot be re-pointed at different bytes ---------------------------------------------
run_wa release trust-key release-signing-test-a "$HEX2"
ok "$([ "$LAST" = "2" ] && grep -q 'release_trust_conflict' <<<"$LAST_OUT" && echo 1 || echo 0)" \
  "the same id with different bytes is refused (a key id names one key)" "exit $LAST: $LAST_OUT"
ok "$(grep -q "key release-signing-test-a $HEX" "$KEY_FILE" && echo 1 || echo 0)" \
  "and the trusted bytes are unchanged"
run_wa release trust-key release-signing-test-a "$HEX"
ok "$([ "$LAST" = "0" ] && [ "$(grep -c '^key release-signing-test-a' "$KEY_FILE")" = "1" ] && echo 1 || echo 0)" \
  "the same id with the same bytes is a no-op, not a second line"

# ---- (f) retire ------------------------------------------------------------------------------------------
run_wa release trust-key release-signing-test-a --retire
ok "$([ "$LAST" = "0" ] && echo 1 || echo 0)" "a key can be retired" "exit $LAST: $LAST_OUT"
ok "$(! grep -q 'release-signing-test-a' "$KEY_FILE" && head -1 "$KEY_FILE" | grep -qx 'wa-trusted-keys v1' && echo 1 || echo 0)" \
  "the retired key is gone and the file is still one this node can read"
run_wa release trust-key release-signing-test-a --retire
ok "$([ "$LAST" = "2" ] && grep -q 'release_trust_unknown_key' <<<"$LAST_OUT" && echo 1 || echo 0)" \
  "retiring a key that is not there is refused by name, not accepted silently" "exit $LAST: $LAST_OUT"

# ---- (g) bad input is refused before anything is written --------------------------------------------------
cp -f "$KEY_FILE" "$W/before-bad.txt"
run_wa release trust-key release-signing-test-d "zz"
ok "$([ "$LAST" = "2" ] && grep -q 'release_trust_bad_key' <<<"$LAST_OUT" && echo 1 || echo 0)" \
  "a non-hex key is refused" "exit $LAST: $LAST_OUT"
run_wa release trust-key release-signing-test-d "0011"
ok "$([ "$LAST" = "2" ] && grep -q 'release_trust_bad_key' <<<"$LAST_OUT" && echo 1 || echo 0)" \
  "a key that is not 32 bytes is refused" "exit $LAST: $LAST_OUT"
ok "$(cmp -s "$KEY_FILE" "$W/before-bad.txt" && echo 1 || echo 0)" "neither refusal touched the trust file"

# ---- (h) the fleet door: an unknown node is a named refusal, never a success ------------------------------
# The local writer must not answer a --node request, and the fleet door must not report success when the peer
# does not exist. No fleet node is contacted: an unknown name is refused by the mesh's own roster lookup.
run_wa release trust-key release-signing-test-e "$HEX" --node definitely-not-a-node-in-this-fleet
ok "$([ "$LAST" != "0" ] && echo 1 || echo 0)" "a --node trust-key for an unknown node fails" "exit $LAST: $LAST_OUT"
ok "$(grep -q 'node_refused\|node_unreachable\|unknown_node' <<<"$LAST_OUT" && echo 1 || echo 0)" \
  "and names why (the peer refused or could not be reached)" "$LAST_OUT"
ok "$(! grep -q 'release-signing-test-e' "$KEY_FILE" && echo 1 || echo 0)" \
  "and nothing was written to THIS node's trust file for it"

# ---- (i) the door is wired where a fleet verb is answered ------------------------------------------------
INIT="$ROOT_DIR/lua/core/init.lua"
ok "$(grep -q 'lua/core/release_trust.lua' "$INIT" && echo 1 || echo 0)" \
  "the CLI reaches the fleet door (lua/core/init.lua)"
ok "$(grep -q 'command == "release"' "$INIT" && echo 1 || echo 0)" \
  "and only for the release word: no other command pays for reading it"
ok "$(grep -q 'fn trust_key' "$ROOT_DIR/rust/wa-host/src/release.rs" && echo 1 || echo 0)" \
  "the writer is in the binary's own release module (rust/wa-host/src/release.rs)"
ok "$(grep -q 'Some("trust-key")' "$ROOT_DIR/rust/wa-host/src/release.rs" && echo 1 || echo 0)" \
  "and the verb is dispatched there, next to verify"
ok "$(grep -q 'parse_trusted_keys(&written' "$ROOT_DIR/rust/wa-host/src/release.rs" && echo 1 || echo 0)" \
  "and it reads its own file back through parse_trusted_keys, not through a second parser"
ok "$([ -f "$ROOT_DIR/lua/core/release_trust.lua" ] && echo 1 || echo 0)" "lua/core/release_trust.lua is in the tree"

echo "test-release-trust: $checks checks, $failed failed"
[ "$failed" = "0" ]
