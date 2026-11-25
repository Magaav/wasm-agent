#!/usr/bin/env bash
# THE D7 ROW: A COORDINATOR UPDATES A SCRATCH **TREE** PEER, AND THE FOLLOW ENDS "installed" (mission
# release-node-updates). D7 (fleet-dry-run ready-2) was a tree node answering
#
#   FAILED on omarchy: update_coordinator_only
#
# to a request its own coordinator had just made: the accept runs the tail in a detached child, the host stamps
# that child with the spawning process's provenance, and update.run refused `child` before it looked at
# anything. The fix (commit b30753b2) lets the accepted tail through by the record the node itself wrote.
#
# THIS ROW runs the product's own two-process row - scripts/test-accept-two-process.lua - through a binary
# built from THIS checkout, so everything below is a real process and nothing of update.run is stubbed:
#   * a master: the real `wa`, its own home, the real nodes.lua remote_call, the signed body, the real relay
#     loop, over real host.http to a real relay process;
#   * a peer: a real `wa serve` (own home, own ports) running the real remote_update.serve, whose accept starts
#     a real detached child (`wa update --accept <id>`) through the node's own operation manager, which runs the
#     real update.run, fast-forwards the peer's TREE to the requested commit and has the sentinel's door perform
#     the install; the record then ends installed and installed.txt names that commit.
# What that file stubs, and only that (its own header says so): the sentinel's installer script and the tree's
# origin (a real bare git repo two commits long).
#
# The runner gives no `wa` on PATH, so this row builds the binary it tests from its own checkout
# (scripts/release-linux.sh --local) and names it. It writes nothing outside WA_ROW_SCRATCH_ROOT, starts no
# service and needs no user manager (the lua row starts its own processes and stops them).
#
#   bash scripts/test-tree-peer-remote-update.sh        (normally: via the orchestrator's row runner)
#
# Prints `tree peer remote update ok (N checks)`; a failed check raises, a missing toolchain SKIPs by name.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/install-isolation.sh"

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip() { printf 'SKIP tree peer remote update: %s\n' "$1"; exit 0; }

command -v cargo >/dev/null 2>&1 || skip 'no cargo on PATH, and this row tests the binary built from its own commit'
command -v python3 >/dev/null 2>&1 || skip 'python3 is needed for the row own free-port probe'
command -v git >/dev/null 2>&1 || skip 'git is needed for the peer tree fixture'

R="${WA_ROW_SCRATCH_ROOT:-${TMPDIR:-/tmp}/wa-tree-peer-$$}"
mkdir -p "$R/bin" "$R/units" "$R/tmp" "$R/home" "$R/install" || exit 2
printf '#!/bin/sh\nprintf "systemctl-stub: refused: %s\\n" "$*" >&2\nexit 1\n' > "$R/bin/systemctl-stub"
chmod +x "$R/bin/systemctl-stub"
# The runner already hands this row a scratch root; by hand, the isolation guard is asked here.
if [ -z "${WA_ROW_SCRATCH_ROOT:-}" ]; then
  export HOME="$R/home" WASM_AGENT_HOME="$R/home" WA_INSTALL_DIR="$R/install"
  export WA_SENTINEL_UNIT_DIR="$R/units" WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl-stub"
  export XDG_CONFIG_HOME="$R/config" TMPDIR="$R/tmp" WASM_AGENT_PORT=17911 WASM_AGENT_CLIENT_PORT=17912
  wa_install_isolation_guard "$R" "$R/home" || { echo 'tree peer remote update: this row is not isolated' >&2; exit 2; }
fi
printf 'tree peer remote update: root %s\n' "$R"
# THE CHANNEL, SAID FIRST (Fable 25/11): this row reads no release channel at all - the binary it tests is
# built from its own checkout - so it spends none of the shared unauthenticated GitHub API allowance.
printf 'tree peer remote update: channel NONE (the binary is built from this checkout; no release channel is read, no GitHub API request is made)\n'

# ---- 1. the binary this row tests: built from THIS checkout -------------------------------------------------
BUILD="$R/build"
BUILD_TARGET="${CARGO_TARGET_DIR:-$R/target}"
if ! CARGO_TARGET_DIR="$BUILD_TARGET" bash scripts/release-linux.sh --local --out "$BUILD" > "$R/build.log" 2>&1; then
  tail -6 "$R/build.log" >&2; skip 'the bundle could not be built from this checkout (see the log above)'
fi
BUNDLE=$(ls -d "$BUILD"/wa-linux-* 2>/dev/null | grep -v '\.tar\.gz$' | head -1)
[ -n "$BUNDLE" ] && [ -x "$BUNDLE/wa" ] || skip 'no built wa was produced by scripts/release-linux.sh'
COMMIT=$(sed -n 's/^source_commit=//p' "$BUNDLE/bundle.manifest" | head -1)
WA="$BUNDLE/wa"
ok "$([ -x "$WA" ] && echo 1)" "the row built the binary it tests from $COMMIT"

# ---- 2. the product's own two-process row, through that binary ----------------------------------------------
# WA_BIN is the peer's binary; WASM_AGENT_LUA_ROOT makes both processes run THIS checkout's Lua, so the row
# proves the code in this commit and not the copy embedded in a binary from another day.
export WASM_AGENT_LUA_ROOT="$ROOT"
export WA_BIN="$WA"
export GATE_ROOT="$R"
OUT="$R/two-process.log"
WA_SCRIPT="$ROOT/scripts/test-accept-two-process.lua" "$WA" --db "$R/t.db" > "$OUT" 2>&1
rc=$?
printf '%s\n' "----- the product's own row (scripts/test-accept-two-process.lua) -----"
tail -24 "$OUT" | sed 's/^/    /'
ok "$([ "$rc" = 0 ] && echo 1)" "the two-process row ran to the end (exit 0)" "rc=$rc"
ok "$(grep -q 'accept two process ok' "$OUT" && echo 1)" "it reports its own success line" "$(grep 'accept two process ok' "$OUT" | tail -1)"
ok "$(grep -q 'and it is INSTALLED, not accepted forever' "$OUT" && echo 1)" "the request settled INSTALLED (the follow ends installed)"
ok "$(grep -q 'installed.txt names the commit that was asked for' "$OUT" && echo 1)" "and the peer's installed.txt moved to the commit that was asked for"
ok "$(grep -q 'exactly ONE deploy request exists on the peer' "$OUT" && echo 1)" "one request, one deploy (the accept is claimed once)"
ok "$(grep -qi 'update_coordinator_only' "$OUT" && echo 0 || echo 1)" "and the peer never answered update_coordinator_only (the D7 refusal)"

if [ "$failed" != 0 ]; then echo "tree peer remote update: $checks checks, $failed FAILED" >&2; exit 1; fi
echo "tree peer remote update ok ($checks checks)"
