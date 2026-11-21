#!/usr/bin/env bash
# A release install on a tree-less node: the asset that was verified must be INSTALLABLE.
#
# THE DEFECT THIS PINS (21/11, hand fix 3 of the node-7ddbfa98036a rollout). wa_node_binary_download
# (scripts/lib/node-binaries.sh) fetched a release's wa and wa-sentinel, verified the signature, every
# sha256 and every size - and left both files with the mode the upload carried, 0644. scripts/upgrade.sh
# refuses a candidate without the executable bit ("no new binary to install"), so scripts/release-install.sh
# - the ONE path that exists for a node with no tree and no toolchain, e.g. nextcloud - could never install
# what it had just verified. The same call also re-fetched the whole release into the same cache directory
# on every run, so a retried install paid for the download again.
#
# WHAT RUNS HERE, AND WHAT DOES NOT. The REAL scripts/lib/node-binaries.sh functions, in their own shell,
# against a fixture release served from a local directory (WA_NODE_BINARIES_URL) and signed with the
# committed TEST key - no network, no gh, no live fleet. The candidate is then handed to the REAL
# scripts/upgrade.sh as a separate process, because the refusal this pins is upgrade.sh's and not the
# library's. Nothing is installed: upgrade.sh is stopped by its own gates before any swap, and the
# assertion is that it is no longer stopped by the one this fix removes.
#
# Usage: bash scripts/test-release-install-exec.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/node-binaries.sh"
UPGRADE="$ROOT/scripts/upgrade.sh"
KEY="$ROOT/tests/fixtures/release-sign/keys.txt"
SIGNER="$ROOT/scripts/lib/release-fixture-sign.py"
checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s %s\n' "$2" "${3:-}"; fi; }
fail_hard() { echo "test-release-install-exec: $*" >&2; exit 1; }

[ -f "$LIB" ] || fail_hard "no $LIB to test"
[ -f "$UPGRADE" ] || fail_hard "no $UPGRADE to test"
[ -f "$KEY" ] || fail_hard "no committed test key at $KEY"
command -v python3 >/dev/null 2>&1 || { echo "SKIP test-release-install-exec: python3 is needed to sign the fixture release"; exit 0; }

# The scratch-home rule: this test gives a node an install and a home, so both are proven not to be the
# operator's before anything runs.
. "$ROOT/scripts/lib/scratch-home.sh" || fail_hard "no scripts/lib/scratch-home.sh"
SCRATCH_ROOT="${TMPDIR:-/tmp}"
case "$SCRATCH_ROOT" in
  "${HOME:-/nonexistent}"|"${HOME:-/nonexistent}"/*) SCRATCH_ROOT=/tmp ;;
esac
W="$(mktemp -d "$SCRATCH_ROOT/wa-release-install-exec-XXXXXX")" || fail_hard "no scratch directory"
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT
HOME_DIR="$W/home"
INSTALL="$W/install"
mkdir -p "$HOME_DIR" "$INSTALL"
wa_scratch_home_guard "$HOME_DIR" || fail_hard "this test would act on the operator's own node home"

# THE LIB FIRST: the fixture's own manifest needs wa_node_sha256, which is the same code the download uses,
# so the pins the fixture declares are the pins the library will compute.
# shellcheck source=/dev/null
. "$LIB" || fail_hard "cannot source $LIB"
export WA_RELEASE_KEYS="$KEY"

# ---- the fixture release: 0644 assets, signed, served from a local directory ---------------------------
COMMIT=3333333333333333333333333333333333333333
SHORT="${COMMIT:0:12}"
X64=x86_64-unknown-linux-gnu
RELEASE="$W/release"
mkdir -p "$RELEASE"
mkelf() { { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture-binary'; } > "$1"; }
mkelf "$RELEASE/wa-$X64-$SHORT" 3e
mkelf "$RELEASE/wa-sentinel-$X64-$SHORT" 3e
# THE MODE THE UPLOAD CARRIES. This is the whole fixture: the bytes are verified and the bit is absent.
chmod 0644 "$RELEASE/wa-$X64-$SHORT" "$RELEASE/wa-sentinel-$X64-$SHORT"
ok "$([ ! -x "$RELEASE/wa-$X64-$SHORT" ] && echo 1 || echo 0)" "the fixture asset arrives without the executable bit (0644)"
xsha="$(wa_node_sha256 "$RELEASE/wa-$X64-$SHORT")"; xbytes="$(wc -c < "$RELEASE/wa-$X64-$SHORT" | tr -d '[:space:]')"
ssha="$(wa_node_sha256 "$RELEASE/wa-sentinel-$X64-$SHORT")"; sbytes="$(wc -c < "$RELEASE/wa-sentinel-$X64-$SHORT" | tr -d '[:space:]')"
cat > "$RELEASE/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$COMMIT
source_tree=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rustc_version=fixture
zig_version=fixture
glibc_floor=2.31
codemode=embedded
built_utc=2026-11-21T00:00:00Z
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$X64 $xsha $xbytes $ssha $sbytes
MANIFEST
python3 "$SIGNER" "$RELEASE" --key A >/dev/null 2>&1 || fail_hard "could not sign the fixture release"
[ -f "$RELEASE/SHA256SUMS.sig" ] || fail_hard "the fixture release is not signed"

# ---- (a) the download makes the verified bytes executable --------------------------------------------
CACHE="$INSTALL/node-binaries"
DIR="$(WA_NODE_BINARIES_URL="$RELEASE" wa_node_binary_download "fixture/repo" "$COMMIT" "$X64" "$CACHE" 2>"$W/download.err")"
code=$?
ok "$([ "$code" = "0" ] && echo 1 || echo 0)" "a signed release downloads" "exit $code: $(cat "$W/download.err")"
ok "$([ -n "$DIR" ] && [ -d "$DIR" ] && echo 1 || echo 0)" "and the answer is the verified directory"
CAND="$DIR/wa-$X64-$SHORT"
ok "$([ -f "$CAND" ] && echo 1 || echo 0)" "the candidate is in it"
ok "$([ -x "$CAND" ] && echo 1 || echo 0)" \
  "the downloaded wa IS EXECUTABLE (the defect: 0644, so upgrade.sh refused it as 'no new binary to install')"
ok "$([ -x "$DIR/wa-sentinel-$X64-$SHORT" ] && echo 1 || echo 0)" \
  "and so is the sentinel beside it"
ok "$([ "$(wa_node_sha256 "$CAND")" = "$xsha" ] && echo 1 || echo 0)" \
  "the chmod did not change the bytes: the sha256 is still the pinned one"

# ---- (b) upgrade.sh no longer refuses it for its mode, as a separate process ----------------------------
# A scratch install: an executable 'wa' (what upgrade.sh insists a running node has) and a serve.pid that
# names this shell, so nothing is ever swapped and no real node is touched.
printf 'not a real node\n' > "$INSTALL/wa"
chmod +x "$INSTALL/wa"
printf '%s\n' "$$" > "$INSTALL/serve.pid"
out="$(cd "$INSTALL" && env -i HOME="$HOME_DIR" PATH=/usr/local/bin:/usr/bin:/bin \
    WA_INSTALL_DIR="$INSTALL" WA_PORT=24555 WA_SERVICE_UNIT_FILE="$W/no-unit" WA_SERVICE_PID=0 \
    WA_RELEASE_KEYS="$KEY" WA_SUPERVISED=1 WASM_AGENT_IN_TURN= \
    timeout 120 bash "$UPGRADE" "$CAND" --release "$DIR" 2>&1)"
case "$out" in
  *"no new binary to install"*)
    ok 0 "upgrade.sh accepts the verified candidate's mode" "it still refuses it: $(printf '%s' "$out" | head -2 | tr '\n' '|')" ;;
  *)
    ok 1 "upgrade.sh accepts the verified candidate's mode (it is stopped, if at all, by a later gate): $(printf '%s' "$out" | head -1)" ;;
esac

# ---- (c) a complete cache entry is not downloaded again -------------------------------------------------
# The release disappears: a second call can only answer from the cache it already holds.
rm -rf "$RELEASE"
: > "$W/download2.err"
DIR2="$(WA_NODE_BINARIES_URL="$RELEASE" wa_node_binary_download "fixture/repo" "$COMMIT" "$X64" "$CACHE" 2>"$W/download2.err")"
code2=$?
ok "$([ "$code2" = "0" ] && [ "$DIR2" = "$DIR" ] && echo 1 || echo 0)" \
  "a second install of the same commit reuses the complete cache entry instead of fetching again" \
  "exit $code2: $(cat "$W/download2.err")"
ok "$(! grep -q 'node_release_unavailable' "$W/download2.err" 2>/dev/null && echo 1 || echo 0)" \
  "and it does not report the release as unavailable while it holds the bytes"
ok "$([ -x "$DIR2/wa-$X64-$SHORT" ] && echo 1 || echo 0)" "the reused entry is executable too"

# ---- (d) an entry whose bytes no longer match its marker is NOT reused ---------------------------------
printf 'tampered\n' >> "$DIR2/wa-$X64-$SHORT"
DIR3="$(WA_NODE_BINARIES_URL="$W/empty-release" wa_node_binary_download "fixture/repo" "$COMMIT" "$X64" "$CACHE" 2>"$W/download3.err")"
code3=$?
ok "$([ "$code3" != "0" ] && echo 1 || echo 0)" \
  "a cache entry edited by hand is not an install: the download refuses instead of reusing it" \
  "exit $code3: $(cat "$W/download3.err")"

# ---- (e) the source says the chmod comes AFTER the verification --------------------------------------
verify_line="$(grep -n 'wa_node_verify_dir "$tmp" "$commit"' "$LIB" | head -1 | cut -d: -f1)"
chmod_line="$(grep -n 'chmod +x "$tmp/$file"' "$LIB" | head -1 | cut -d: -f1)"
ok "$([ -n "$verify_line" ] && [ -n "$chmod_line" ] && [ "$chmod_line" -gt "$verify_line" ] && echo 1 || echo 0)" \
  "in the source, the +x is after the verified download and not before it" \
  "verify=${verify_line:-none} chmod=${chmod_line:-none}"
ok "$(grep -q 'node_not_executable' "$LIB" && echo 1 || echo 0)" \
  "a chmod that cannot happen is a named refusal (node_not_executable)"
ok "$(grep -q 'A COMPLETE ENTRY IS NOT FETCHED AGAIN' "$LIB" && echo 1 || echo 0)" \
  "and the cache reuse is the download's own decision, in the lib"

echo "test-release-install-exec: $checks checks, $failed failed"
[ "$failed" = "0" ]
