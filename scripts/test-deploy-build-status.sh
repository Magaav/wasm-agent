#!/usr/bin/env bash
# The rebuild's progress file and its requirement check (scripts/lib/build-status.sh, build-requirements.sh).
#
# What is pinned, and why (29/10). The sentinel owns the one rebuild path, so the progress a `wa chat` draws
# (rust/wa-host/src/build_status.rs) is written by deploy.sh, not by an operator's script: the format must be
# the renderer's, the follower must count cargo's `Compiling` lines without forking per line and die with its
# deploy, and a failed status write must never fail a deploy. The requirement check must be stats, not runs:
# it is on every deploy's path, so it is timed here, and a missing or too-old toolchain must be NAMED - by
# reading rustup's manifest, never by invoking cargo. build.env is data: only its whitelisted keys are read.
# No network, no cargo, no node required: every tool is a stub in a private HOME.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
checks=0
fail() { echo "test-deploy-build-status: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-build-status-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT
json() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(process.argv[2].split(",").map(k=>s[k]).join("|"))' "$1" "$2"; }
command -v node >/dev/null 2>&1 || { echo "test-deploy-build-status: SKIPPED (node reads the JSON)"; exit 0; }

# --- the status file -------------------------------------------------------------------------------------
TREE="$WORK/tree"; mkdir -p "$TREE/rust/wa-sentinel"
printf '[[package]]\nname="a"\n[[package]]\nname="b"\n[[package]]\nname="c"\n' > "$TREE/rust/Cargo.lock"
printf '[[package]]\nname="d"\n[[package]]\nname="e"\n' > "$TREE/rust/wa-sentinel/Cargo.lock"
export WASM_AGENT_DATA="$WORK/data"
( . "$ROOT_DIR/scripts/lib/build-status.sh"
  wa_status building preflight 0 ""   # before begin: a no-op, never an error
  [ ! -f "$WASM_AGENT_DATA/build-status.json" ] || exit 7
  wa_status_begin "$TREE" 0123456789abcdef0123
  wa_phase preflight >/dev/null
) || fail "status before begin wrote a file (or begin failed)"
STATUS="$WASM_AGENT_DATA/build-status.json"
[ "$(json "$STATUS" state,phase,done,total,commit)" = "building|preflight|0|5|0123456789ab" ] \
  || fail "the status is not the renderer's format: $(cat "$STATUS")"
[ -n "$(json "$STATUS" started_at)" ] && [ -n "$(json "$STATUS" at)" ] || fail "no clock fields: $(cat "$STATUS")"
ok "status JSON is build_status.rs's format" "total = both lockfiles' packages (5), commit = sha12"

# --- the follower --------------------------------------------------------------------------------------------
LOG="$WORK/cargo.log"
( . "$ROOT_DIR/scripts/lib/build-status.sh"
  wa_status_begin "$TREE" fedcba9876543210
  wa_status_follow "$LOG" compiling
  echo "$WA_STATUS_FOLLOWER" > "$WORK/follower.pid"
  printf '   Compiling serde v1.0.219\nwarning: unused\n   Compiling ring v0.17.8\n' >> "$LOG"
  sleep 1.3
  printf '   Compiling wa-host v0.1.0 (/src/rust/wa-host)\n' >> "$LOG"
  sleep 1.3
  [ "$(json "$STATUS" phase,done,crate)" = "compiling|3|wa-host" ] || { echo "status: $(cat "$STATUS")" >&2; exit 3; }
  [ "$(wa_status_compiled "$LOG")" = 3 ] || exit 4
  wa_status_unfollow
  kill -0 "$(cat "$WORK/follower.pid")" 2>/dev/null && exit 5
  exit 0
) || fail "the follower did not count the Compiling lines or did not stop (exit $?)"
ok "the follower counts cargo's Compiling lines live and stops when asked" "3 crates, last wa-host"
# A deploy that dies (SIGKILL) takes its follower with it: the loop checks its parent.
{ bash -c ". '$ROOT_DIR/scripts/lib/build-status.sh'; wa_status_begin '$TREE' abc; wa_status_follow '$LOG' compiling; echo \$WA_STATUS_FOLLOWER > '$WORK/orphan.pid'; kill -9 \$\$"; } 2>/dev/null
sleep 1
kill -0 "$(cat "$WORK/orphan.pid")" 2>/dev/null && { kill "$(cat "$WORK/orphan.pid")"; fail "a follower outlived its killed deploy"; }
ok "a follower does not outlive a killed deploy"
# A status write that cannot happen is not an error.
( . "$ROOT_DIR/scripts/lib/build-status.sh"; WA_STATUS_FILE=/nonexistent/dir/status.json
  wa_status_begin "$TREE" abc; wa_status building compiling 1 x ) || fail "an unwritable status failed the caller"
ok "an unwritable status file never fails the deploy"

# --- the requirement check ----------------------------------------------------------------------------------
H="$WORK/home"; BIN="$WORK/bin"; TOOLS="$WORK/tools"; mkdir -p "$H" "$BIN" "$TOOLS"
# Only the system tools the check uses: no cargo, node, cc or rg on this PATH unless a stub puts them there.
for t in bash sh git sed awk grep sort head tail tr cut uname dirname df cat mkdir mv rm date wc find env basename; do
  p="$(command -v "$t")" && ln -s "$p" "$BIN/$t"
done
# MSYS `ln -s` copies, and a copied bash.exe cannot load msys-2.0.dll away from /usr/bin (wasm_the_first,
# 30/10): there the system directory itself stays on PATH, once it is shown to hold none of the tools
# this check must not find there.
SYS_PATH=
if command -v cygpath >/dev/null 2>&1; then
  sysdir=$(dirname "$(command -v bash)")
  for t in cargo node cc gcc rg rustc; do [ -e "$sysdir/$t" ] || [ -e "$sysdir/$t.exe" ] && fail "$sysdir holds $t; this fixture cannot run here"; done
  SYS_PATH=":$sysdir"
fi
stub() { printf '#!/bin/sh\necho "%s"\n' "$2" > "$1"; chmod +x "$1"; }
mkdir -p "$H/.cargo/bin" "$H/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib" "$H/.wasm-agent/node/bin"
stub "$H/.cargo/bin/cargo" "cargo 9.9.9"
printf 'version = "12"\ndefault_toolchain = "stable-x86_64-unknown-linux-gnu"\n' > "$H/.rustup/settings.toml"
manifest() { printf 'manifest-version = "2"\n[pkg.cargo]\nversion = "%s (x 2026-10-13)"\n[pkg.rustc]\nversion = "%s (58cf8f9c3 2026-10-13)"\n' "$1" "$1" \
  > "$H/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/multirust-channel-manifest.toml"; }
manifest 1.99.1
stub "$H/.wasm-agent/node/bin/node" "v22.23.4"
stub "$TOOLS/cc" "cc"; stub "$TOOLS/rg" "ripgrep 14"
printf 'WA_BUILD_PATH=%s\nCARGO_INCREMENTAL=1\nLD_PRELOAD=/evil.so\nPATH=/evil\n' "$TOOLS" > "$H/.wasm-agent/build.env"
git -C "$TREE" init -q && mkdir -p "$TREE/.git/codemode-assets/pi-1.2.0-quickjs-3.6.2" && echo '{}' > "$TREE/.git/codemode-assets/pi-1.2.0-quickjs-3.6.2/receipt.json"
check() { env -i HOME="$H" PATH="$BIN$SYS_PATH" bash -c ". '$ROOT_DIR/scripts/lib/build-requirements.sh'; wa_build_env
  echo \"env CARGO_INCREMENTAL=\${CARGO_INCREMENTAL:-} LD_PRELOAD=\${LD_PRELOAD:-}\"
  start=\${EPOCHREALTIME/./}; wa_build_check '$TREE'; rc=\$?; end=\${EPOCHREALTIME/./}
  echo \"took \$(( (end - start) / 1000 ))ms\"; echo \"missing:\$WA_BUILD_MISSING\"; exit \$rc"; }
OUT="$(check)" || fail "everything present was not ok: $OUT"
printf '%s\n' "$OUT" | grep -q 'ok      cargo     rustc 1.99.1 (needs >= 1.89)' || fail "rustc's version was not read from rustup's manifest: $OUT"
printf '%s\n' "$OUT" | grep -q "ok      cc        $TOOLS/cc" || fail "WA_BUILD_PATH did not reach PATH: $OUT"
printf '%s\n' "$OUT" | grep -q 'env CARGO_INCREMENTAL=1 LD_PRELOAD=$' || fail "build.env's whitelist leaked or dropped a key: $OUT"
ms="$(printf '%s\n' "$OUT" | sed -n 's/^took \([0-9]*\)ms/\1/p')"
[ "${ms:-9999}" -lt 1000 ] || fail "the check took ${ms}ms; it must be stats, not runs"
ok "all present: ok, read from files" "${ms}ms; rustc from rustup's manifest, cc via WA_BUILD_PATH, build.env whitelisted"
manifest 1.80.0
OUT="$(check)" && fail "a toolchain older than the tree needs passed: $OUT"
printf '%s\n' "$OUT" | grep -q 'missing cargo     rustc 1.80.0 is older than 1.89' || fail "the old toolchain was not named: $OUT"
manifest 1.99.1; rm "$H/.wasm-agent/node/bin/node" "$TREE/.git/codemode-assets/pi-1.2.0-quickjs-3.6.2/receipt.json"
OUT="$(check)" && fail "missing node and assets passed: $OUT"
printf '%s\n' "$OUT" | grep -q '^missing: node assets$' || fail "the missing pieces were not listed in order (node before assets): $OUT"
ok "an old toolchain, a missing node and missing assets are named" "provisioning order: node, then the assets that need it"

echo "test-deploy-build-status: ALL PASS ($checks checks)"
