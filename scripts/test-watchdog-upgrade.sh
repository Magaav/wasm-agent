#!/usr/bin/env bash
# upgrade.sh under WA_WATCHDOG=1: the switch is the watchdog's, and the old restart path is not used.
#
#   bash scripts/test-watchdog-upgrade.sh
#
# A scratch install, a scratch watchdog home, two fake kernels and a stubbed `curl` for the node's own
# `/health` (the idle gate and the post-install wait read it). Nothing of the operator's install, sentinel,
# home or node is read or written, and nothing is deployed.
#
# What it proves:
#   1. WA_WATCHDOG=1 with no wa-watchdog installed is a REFUSAL (exit 2), not a silent fall back to the old
#      restart path.
#   2. With a watchdog supervising on a scratch port, the upgrade switches through `wa-watchdog swap`: the
#      new kernel is serving, `serve.pid` names the pid that listens, and the install record is written.
#   3. The default (WA_WATCHDOG unset) never calls the watchdog at all.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
BIN="${WA_WATCHDOG_BIN:-$TARGET_DIR/debug/wa-watchdog}"
if [ -x "$BIN.exe" ]; then BIN="$BIN.exe"; fi
if [ ! -x "$BIN" ] || ! command -v cargo >/dev/null 2>&1; then
  echo "test-watchdog-upgrade: SKIPPED (needs cargo and a built wa-watchdog; run scripts/test-watchdog.sh first)"
  exit 0
fi
cargo build --offline --manifest-path rust/Cargo.toml -p wa-watchdog >/dev/null 2>&1 || {
  echo "test-watchdog-upgrade: SKIPPED (the crate did not build)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-watchdog-upg-XXXXXX")" || exit 2
cleanup() {
  if [ -n "${SUP_PID:-}" ] && kill -0 "$SUP_PID" 2>/dev/null; then
    "$BIN" stop --home "$(native "$WD_HOME")" --wait-ms 10000 >/dev/null 2>&1 || kill "$SUP_PID" 2>/dev/null
    wait "$SUP_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "  ok: $*"; }

INST="$WORK/install"
WD_HOME="$WORK/watchdog"
PORT="$((20000 + (($$ + 7) % 20000)))"
mkdir -p "$INST" "$WORK/kernels"

# The installed node and the candidate are copies of the watchdog binary: what matters here is the swap
# protocol, and the fake kernel inside it is what answers /health.
cp -f "$BIN" "$INST/wa.exe"
cp -f "$BIN" "$INST/wa-watchdog.exe"
cp -f "$BIN" "$WORK/candidate.exe"
cp -f "$BIN" "$WORK/kernels/wa-kernel"
chmod +x "$INST/wa.exe" "$INST/wa-watchdog.exe" "$WORK/candidate.exe" "$WORK/kernels/wa-kernel" 2>/dev/null
NEW_HASH="$(sha256sum < "$WORK/candidate.exe" | awk '{print $1}')"
# commit=unknown skips the downgrade guard; the proof cache marks the candidate as already answered on a
# scratch port, so upgrade.sh skips its own 20s proof and reaches the switch.
printf 'commit=unknown\nsource_commit_hint=unknown\nsha256=%s\n' "$(sha256sum < "$INST/wa.exe" | awk '{print $1}')" > "$INST/installed.txt"
printf '%s\n' "$NEW_HASH" > "$INST/.upgrade-proof"

# The node's /health, stubbed: `curl` is upgrade.sh's only source of truth about the running node.
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'SH'
#!/bin/sh
printf '%s' '{"ok":true,"node_state":{"state":"idle","busy_threads":0,"queue":0,"subagents_running":0,"subagents_queued":0},"runs":[],"queue":0,"subagents":{"active":0,"running":0,"queued":0},"state":"alive"}'
SH
chmod +x "$STUB/curl"

echo "== 1. WA_WATCHDOG=1 without a watchdog is a refusal"
rm -f "$INST/wa-watchdog.exe"
out="$(env -u WASM_AGENT_IN_TURN WA_WATCHDOG=1 WA_INSTALL_DIR="$INST" WA_PORT="$PORT" PATH="$STUB:$PATH" \
  bash scripts/upgrade.sh "$WORK/candidate.exe" 2>&1)"
code=$?
case "$code:$out" in
  2:*"no wa-watchdog is installed"*) ok "exit 2 and it says why" ;;
  *) fail "expected exit 2 with a refusal, got exit $code: $out" ;;
esac
cp -f "$BIN" "$INST/wa-watchdog.exe"

echo "== 2. with a watchdog supervising, the upgrade switches through it"
"$BIN" init --kernel "$(native "$WORK/kernels/wa-kernel")" --port "$PORT" --home "$(native "$WD_HOME")" \
  --kernel-arg selftest-kernel --kernel-arg --port --kernel-arg '{port}' --kernel-arg --tag --kernel-arg live \
  >/dev/null 2>&1
"$BIN" run --home "$(native "$WD_HOME")" >"$WORK/supervisor.out" 2>&1 &
SUP_PID=$!
started=0
for _ in $(seq 1 200); do
  if "$BIN" status --home "$(native "$WD_HOME")" >/dev/null 2>&1; then started=1; break; fi
  sleep 0.1
done
[ "$started" = 1 ] || fail "the scratch supervisor never became healthy: $(tail -3 "$WORK/supervisor.out")"

out="$(env -u WASM_AGENT_IN_TURN WA_WATCHDOG=1 WA_INSTALL_DIR="$INST" WA_PORT="$PORT" \
  WA_WATCHDOG_HOME="$(native "$WD_HOME")" WA_UPGRADE_VIA=test-watchdog-upgrade \
  PATH="$STUB:$PATH" bash scripts/upgrade.sh "$WORK/candidate.exe" 2>&1)"
code=$?
printf '%s\n' "$out" | sed 's/^/    /'
case "$out" in
  *"the watchdog ("*"owns the switch"*) ok "the watchdog branch ran" ;;
  *) fail "the watchdog branch did not run (see above)" ;;
esac
case "$code" in
  0) ok "the upgrade reported success" ;;
  *) fail "expected exit 0, got $code" ;;
esac
case "$out" in
  *"the sentinel"*|*"stopping the node (pid"*) fail "the old restart path was taken as well as the watchdog" ;;
  *) ok "the old restart path was not taken" ;;
esac
if "$BIN" status --home "$(native "$WD_HOME")" >/dev/null 2>&1; then
  ok "the watchdog is still healthy after the swap: $( "$BIN" status --home "$(native "$WD_HOME")" )"
else
  fail "the watchdog is not healthy after the swap: $(tail -5 "$WORK/supervisor.out")"
fi
LISTENER_PID="$(tr -d '[:space:]' < "$WD_HOME/kernel.pid" 2>/dev/null)"
RECORDED_PID="$(tr -d '[:space:]' < "$INST/serve.pid" 2>/dev/null)"
if [ -n "$LISTENER_PID" ] && [ "$LISTENER_PID" = "$RECORDED_PID" ]; then
  ok "serve.pid names the listening kernel (pid $RECORDED_PID)"
else
  fail "serve.pid (${RECORDED_PID:-none}) does not match the watchdog's kernel.pid (${LISTENER_PID:-none})"
fi
if grep -q '^sha256=' "$INST/installed.txt" 2>/dev/null; then
  ok "the install record was written: $(sed -n 's/^sha256=//p' "$INST/installed.txt" | head -1 | cut -c1-12)..."
else
  fail "no install record was written"
fi
if [ -f "$WD_HOME/bin/$("$BIN" verify "$(native "$WORK/candidate.exe")" --sha256 "$NEW_HASH" >/dev/null 2>&1; echo "${NEW_HASH:0:12}")/candidate.exe" ]; then
  ok "the swapped-in bytes are staged by pin, and the previous binary is still on disk"
else
  # The staged name follows the file name the swap was given; the directory is the pin's first 12 characters.
  if ls "$WD_HOME/bin/${NEW_HASH:0:12}/" >/dev/null 2>&1; then
    ok "the swapped-in bytes are staged by pin ($(ls "$WD_HOME/bin/${NEW_HASH:0:12}/" | head -1))"
  else
    fail "nothing was staged under bin/${NEW_HASH:0:12}"
  fi
fi
if [ -f "$WORK/kernels/wa-kernel" ]; then ok "the previous kernel binary is still on disk"; else fail "the previous binary is gone"; fi
# The regression this exists for: upgrade.sh's own stop-the-node block ran before the watchdog branch and
# killed the watchdog's kernel, so the swap "worked" while the node had been down for the whole idle wait.
STATUS="$( "$BIN" status --json --home "$(native "$WD_HOME")" 2>/dev/null)"
case "$STATUS" in
  *'"restarts":0'*) ok "the script never stopped the watchdog's kernel (restarts 0)" ;;
  *) fail "the watchdog restarted its kernel during the upgrade: $STATUS" ;;
esac
case "$STATUS" in
  *'"last_exit":null'*) ok "the kernel that was serving when the upgrade began was still running at the swap" ;;
  *) fail "the kernel exited before the swap, so the upgrade took it down itself: $STATUS" ;;
esac
"$BIN" stop --home "$(native "$WD_HOME")" --wait-ms 15000 >/dev/null 2>&1
wait "$SUP_PID" 2>/dev/null
SUP_PID=""

echo "== 3. without WA_WATCHDOG the watchdog is not touched"
# Remove the binary again: if the default path strayed into the watchdog branch, this would fail loudly
# instead of silently "working".
rm -f "$INST/wa-watchdog.exe"
rm -f "$INST/installed.txt"; printf 'commit=unknown\nsource_commit_hint=unknown\nsha256=%s\n' "$(sha256sum < "$INST/wa.exe" | awk '{print $1}')" > "$INST/installed.txt"
out="$(env -u WASM_AGENT_IN_TURN -u WA_WATCHDOG WA_INSTALL_DIR="$INST" WA_PORT="$PORT" PATH="$STUB:$PATH" \
  timeout 120 bash scripts/upgrade.sh "$WORK/candidate.exe" 2>&1)"
case "$out" in
  *"owns the switch"*) fail "the default path used the watchdog" ;;
  *) ok "the default path does not use the watchdog" ;;
esac

printf '\n'
if [ "$fails" = 0 ]; then
  echo "test-watchdog-upgrade: ok"
  exit 0
fi
echo "test-watchdog-upgrade: FAILED ($fails check(s))"
exit 1
