#!/usr/bin/env bash
# wa-watchdog: the crate's own tests, plus the surfaces a script or an operator touches.
#
#   bash scripts/test-watchdog.sh
#
# What it proves, in this order (each step runs against a scratch home under /tmp; no node, no network, no
# installed binary, nothing of the operator's is read or written):
#
#   1. `cargo test -p wa-watchdog` - the unit tests (sha256 vectors, the JSON field reader, the config, the
#      backoff curve, the state table, the health probe against real sockets) and the integration tests
#      (a supervisor process starting two fake kernels, a swap that switches, a swap that rolls back, a
#      swap refused for a wrong pin, a kernel that dies inside the stability window).
#   2. the CLI contract `scripts/upgrade.sh` depends on under `WA_WATCHDOG=1`: `init` writes a config `run`
#      accepts, `verify` refuses a wrong pin with exit 1 (not 2), `status --json` is JSON, `swap` on a home
#      nobody supervises exits 3 and says the request is queued (never claims success), and a supervisor
#      started on a scratch port becomes healthy and stops when asked.
#
# The real kernel is NOT exercised: the fake kernel is `wa-watchdog selftest-kernel`, which binds one port and
# answers GET /health. A green run says the supervisor and its swap protocol work, not that the kernel binary
# it will supervise does.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2

if ! command -v cargo >/dev/null 2>&1; then
  echo "test-watchdog: SKIPPED (cargo is not on PATH; wa-watchdog has no prebuilt test runner)"
  exit 0
fi

# A POSIX path handed to a native Windows process is silently unusable (AGENTS.md): convert at the boundary.
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-watchdog-test-XXXXXX")" || exit 2
cleanup() {
  # A supervisor this script started must not outlive it: stop it the way an operator would.
  if [ -n "${SUP_PID:-}" ] && kill -0 "$SUP_PID" 2>/dev/null; then
    kill "$SUP_PID" 2>/dev/null
    wait "$SUP_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
step() { printf '\n== %s\n' "$*"; }

step "cargo test -p wa-watchdog (offline)"
# Threads left at their default: the crate's tests use their own scratch homes and their own ports, so they
# are safe in parallel, and running them in parallel is what catches a test that leaks a process.
if cargo test --offline --manifest-path rust/Cargo.toml -p wa-watchdog 2>&1 | tail -25; then
  echo "  ok: the crate's tests passed"
else
  echo "  FAIL: the crate's tests failed (see above)"
  fails=$((fails + 1))
fi

# `cargo test` built the binary; find it where cargo put it (`CARGO_TARGET_DIR` is honoured, and this checkout
# sets it). `.exe` is checked explicitly: MSYS `test -x` resolves `wa-watchdog` to `wa-watchdog.exe`, a native
# process does not.
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
BIN="${WA_WATCHDOG_BIN:-$TARGET_DIR/debug/wa-watchdog}"
if [ -x "$BIN.exe" ]; then BIN="$BIN.exe"; fi
if [ ! -x "$BIN" ]; then
  echo "  FAIL: no wa-watchdog binary to exercise (looked in $TARGET_DIR/debug)"
  exit 1
fi
BIN_NATIVE="$(native "$BIN")"
HOME_DIR="$(native "$WORK/home")"

step "init writes a config that run accepts"
if "$BIN" init --kernel "$BIN_NATIVE" --port 1 --home "$HOME_DIR" >"$WORK/init.out" 2>&1; then
  echo "  ok: $(sed -n '1p' "$WORK/init.out")"
else
  echo "  FAIL: init failed: $(cat "$WORK/init.out")"
  fails=$((fails + 1))
fi

step "verify refuses a wrong pin with exit 1, not a usage error"
out="$("$BIN" verify "$BIN_NATIVE" --sha256 "$(printf '00%.0s' $(seq 1 32))" 2>&1)"
code=$?
case "$code:$out" in
  1:*sha256_mismatch*) echo "  ok: exit 1 and the refusal names the mismatch" ;;
  *) echo "  FAIL: expected exit 1 with sha256_mismatch, got exit $code: $out"; fails=$((fails + 1)) ;;
esac
PIN="$(sha256sum < "$BIN" 2>/dev/null | awk '{print $1}')"
if [ -n "$PIN" ]; then
  if "$BIN" verify "$BIN_NATIVE" --sha256 "$PIN" >/dev/null 2>&1; then echo "  ok: the real pin verifies"; else
    echo "  FAIL: the real pin did not verify"; fails=$((fails + 1)); fi
fi

step "status --json is JSON even where no supervisor has run"
out="$("$BIN" status --json --home "$HOME_DIR" 2>&1)"
case "$out" in
  *'"supervisor_alive":false'*) echo "  ok: $out" ;;
  *) echo "  FAIL: expected supervisor_alive:false, got: $out"; fails=$((fails + 1)) ;;
esac

step "swap on an unsupervised home queues the request and says so (exit 3)"
# The candidate itself IS healthy, so the answer cannot be "the bytes are bad": no supervisor answered, and
# the command must not report success.
"$BIN" init --kernel "$BIN_NATIVE" --port 1 --home "$(native "$WORK/unsupervised")" >/dev/null 2>&1
cp -f "$BIN" "$WORK/candidate"
CAND_PIN="$(sha256sum < "$WORK/candidate" | awk '{print $1}')"
out="$("$BIN" swap "$(native "$WORK/candidate")" --sha256 "$CAND_PIN" --home "$(native "$WORK/unsupervised")" \
  --wait-ms 1500 --arg selftest-kernel --arg --port --arg '{port}' 2>&1)"
code=$?
case "$code:$out" in
  3:*queued*) echo "  ok: exit 3, and it says the request is queued" ;;
  *) echo "  FAIL: expected exit 3 and a queued request, got exit $code: $out"; fails=$((fails + 1)) ;;
esac
if ls "$WORK/unsupervised/requests"/*.json >/dev/null 2>&1; then
  echo "  ok: the request is on disk for the next pass"
else
  echo "  FAIL: no request file was written"; fails=$((fails + 1))
fi

step "a supervisor becomes healthy on a scratch port and stops when asked"
PORT="$((20000 + ($$ % 20000)))"
LIVE="$(native "$WORK/live")"
"$BIN" init --kernel "$BIN_NATIVE" --port "$PORT" --home "$LIVE" \
  --kernel-arg selftest-kernel --kernel-arg --port --kernel-arg '{port}' --kernel-arg --tag --kernel-arg live \
  >/dev/null 2>&1
"$BIN" run --home "$LIVE" >"$WORK/live.out" 2>&1 &
SUP_PID=$!
healthy=0
for _ in $(seq 1 200); do
  if "$BIN" status --home "$LIVE" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 0.1
done
if [ "$healthy" = 1 ]; then
  echo "  ok: $( "$BIN" status --home "$LIVE" )"
else
  echo "  FAIL: the supervisor never reported healthy: $(tail -3 "$WORK/live.out")"
  fails=$((fails + 1))
fi
"$BIN" stop --home "$LIVE" --wait-ms 15000 >"$WORK/stop.out" 2>&1
case "$(cat "$WORK/stop.out")" in
  *stopped*) echo "  ok: stop ended it and its kernel" ;;
  *) echo "  FAIL: stop did not settle: $(cat "$WORK/stop.out")"; fails=$((fails + 1)) ;;
esac
wait "$SUP_PID" 2>/dev/null
SUP_PID=""

printf '\n'
if [ "$fails" = 0 ]; then
  echo "test-watchdog: ok (crate tests + 5 CLI checks; no kernel binary was started)"
  exit 0
fi
echo "test-watchdog: FAILED ($fails step(s))"
exit 1
