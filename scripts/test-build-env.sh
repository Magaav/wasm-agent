#!/usr/bin/env bash
# The node owns ONE record of its build environment, and a key no build reads is a refusal (item 3 of the
# node-ops round, #17).
#
#   bash scripts/test-build-env.sh
#
# MEASURED 19/11: work's node printed "installed tree ignored" all day while each entry point - fast.sh,
# wa land, deploy.sh, a mission - read the toolchain from its own ambient environment. A toolchain
# directory, zig, the target-dir policy, the code-mode assets and the wasi-sdk had no one place to be
# written down, so a machine could set a value nothing ever looked at and no command said so.
#
# What this proves, in order:
#   * a node with NO record is not refused: it builds from its ambient environment exactly as before,
#     and the audit says the record is absent rather than failing;
#   * a record with a key no build reads is REFUSED by name (build_env_key_unknown:<KEY>), with the
#     line that fixes it, and scripts/fast.sh exits 2 before running a single row;
#   * every key in the allow-list is ACCEPTED, and WA_BUILD_PATH actually reaches PATH through the same
#     reader deploy.sh uses;
#   * a value that is there but empty is reported as empty, not as absent;
#   * the record is READ, never sourced: a line that would run a command is not executed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-build-env-$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/home/.wasm-agent" "$SCRATCH/tools" || exit 2
cleanup() { local s=$?; set +e; rm -rf "$SCRATCH"; exit $s; }
trap cleanup EXIT
# This test writes only under its own scratch root, and says so in the checkable way.
# The scratch home is compared against the RIGHT side (item 4 of the node-ops round):
# WASM_AGENT_HOME is the USER home (rust/wa-host-support/src/paths.rs:12), and the node store
# hangs off it as <home>/.wasm-agent. The guard refuses the real $HOME, the real store, anything
# inside it and anything above it - the measurements are in scripts/lib/scratch-home.sh.
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$SCRATCH/home" || exit 2
fail() { echo "test-build-env: $*" >&2; exit 1; }

. scripts/lib/build-requirements.sh

# (1) No record: absent, and not a refusal.
out="$(wa_build_env_audit "$SCRATCH/home" 2>&1)" || fail "an absent record was refused: $out"
case "$out" in *'record  absent'*) ;; *) fail "an absent record was not reported as absent: $out" ;; esac

# (2) A key no build reads: refused by name, with the remedy, and fast.sh stops before any row.
printf 'WA_NOT_A_BUILD_KEY=1\n' > "$SCRATCH/home/.wasm-agent/build.env"
out="$(wa_build_env_audit "$SCRATCH/home" 2>&1)"
code=$?
[ "$code" = 1 ] || fail "an unknown key exited $code, not 1: $out"
case "$out" in *'unknown WA_NOT_A_BUILD_KEY'*) ;; *) fail "the unknown key was not named: $out" ;; esac
case "$out" in *'remove it'*) ;; *) fail "the refusal does not say what to do: $out" ;; esac
set +e
fast_out="$(WASM_AGENT_HOME="$SCRATCH/home" bash scripts/fast.sh --binary 2>&1)"
fast_code=$?
set -e
[ "$fast_code" = 2 ] || fail "scripts/fast.sh with an unknown record key exited $fast_code, not 2"
case "$fast_out" in *build_env_key_unknown*) ;; *) fail "scripts/fast.sh did not name the unknown key as build_env_key_unknown: $(printf '%s' "$fast_out" | tail -3)" ;; esac

# (3) Every allowed key is accepted, and WA_BUILD_PATH reaches PATH through the shared reader.
mkdir -p "$SCRATCH/tools/mytool" "$SCRATCH/tools/wasi-sdk/share/wasi-sysroot"
printf '#!/bin/sh\necho zig\n' > "$SCRATCH/tools/zig"; chmod +x "$SCRATCH/tools/zig"
cat > "$SCRATCH/home/.wasm-agent/build.env" <<EOF
WA_BUILD_PATH=$SCRATCH/tools/mytool
WA_BUILD_ZIG=$SCRATCH/tools/zig
WASI_SDK_PATH=$SCRATCH/tools/wasi-sdk
WA_BUILD_CARGO_TARGET=oneroot
CARGO_BUILD_JOBS=4
EOF
out="$(wa_build_env_audit "$SCRATCH/home" 2>&1)" || fail "a record with only allowed keys was refused: $out"
for key in WA_BUILD_PATH WA_BUILD_ZIG WASI_SDK_PATH WA_BUILD_CARGO_TARGET CARGO_BUILD_JOBS; do
  case "$out" in *"entry   $key"*) ;; *) fail "the audit did not report $key as accepted: $out" ;; esac
done
path_now="$(WASM_AGENT_HOME="$SCRATCH/home" bash -c '. scripts/lib/build-requirements.sh; wa_build_env; printf %s "$PATH"')"
case "$path_now" in *"$SCRATCH/tools/mytool"*) ;; *) fail "WA_BUILD_PATH from the record did not reach PATH: $path_now" ;; esac

# (4) A key present with no value says empty, not absent.
printf 'WASI_SDK_PATH=\n' > "$SCRATCH/home/.wasm-agent/build.env"
out="$(wa_build_env_audit "$SCRATCH/home" 2>&1)" || fail "an empty value was refused"
case "$out" in *'(empty)'*) ;; *) fail "an empty value was not reported as empty: $out" ;; esac

# (5) The record is DATA, never sourced: a line that would create a file must not run.
printf 'WA_BUILD_PATH=$(touch %s/sourced-marker)\n' "$SCRATCH" > "$SCRATCH/home/.wasm-agent/build.env"
wa_build_env_audit "$SCRATCH/home" >/dev/null 2>&1 || true
WASM_AGENT_HOME="$SCRATCH/home" bash -c '. scripts/lib/build-requirements.sh; wa_build_env' >/dev/null 2>&1 || true
[ ! -e "$SCRATCH/sourced-marker" ] || fail 'the record was SOURCED: a command substitution in it ran'


# (6) EVERY KEY THE AUDIT ACCEPTS IS A KEY wa_build_env APPLIES (item 6 of the node-ops round). Measured
# 19/11: the audit listed WA_BUILD_ZIG, WASI_SDK_PATH and WA_BUILD_CARGO_TARGET as read entries while
# wa_build_env exported none of them, so a node set a toolchain directory nothing looked at - the exact
# defect the audit exists to catch, one level deeper. The record here names a zig that exists and a
# wasi-sdk root with a sysroot, and both must arrive in the environment a build sees.
mkdir -p "$SCRATCH/zig" "$SCRATCH/wasi-sdk/share/wasi-sysroot" "$SCRATCH/wasi-sdk/bin"
printf '#!/bin/sh\necho zig\n' > "$SCRATCH/zig/zig"; chmod +x "$SCRATCH/zig/zig"
cat > "$SCRATCH/home/.wasm-agent/build.env" <<EOF
WA_BUILD_ZIG=$SCRATCH/zig/zig
WASI_SDK_PATH=$SCRATCH/wasi-sdk
WA_BUILD_CARGO_TARGET=oneroot
CARGO_BUILD_JOBS=4
EOF
applied="$(WASM_AGENT_HOME="$SCRATCH/home" bash -c '. scripts/lib/build-requirements.sh; wa_build_env || exit $?; for k in WA_BUILD_ZIG WASI_SDK_PATH WA_BUILD_CARGO_TARGET CARGO_BUILD_JOBS; do eval "v=\${$k:-<unset>}"; printf "%s=%s\n" "$k" "$v"; done' 2>&1)" || fail "a record with every key present was refused by wa_build_env: $applied"
for pair in "WA_BUILD_ZIG=$SCRATCH/zig/zig" "WASI_SDK_PATH=$SCRATCH/wasi-sdk" "WA_BUILD_CARGO_TARGET=oneroot" "CARGO_BUILD_JOBS=4"; do
  case "$applied" in *"$pair"*) ;; *) fail "wa_build_env accepted $pair in the audit but did not export it: $applied" ;; esac
done
# The directories the record names are searched by a build: zig's directory and the sdk's bin.
dirs="$(WASM_AGENT_HOME="$SCRATCH/home" bash -c '. scripts/lib/build-requirements.sh; wa_build_env || exit $?; printf %s "$PATH"')"
case "$dirs" in *"$SCRATCH/zig"*) ;; *) fail "WA_BUILD_ZIG's directory did not reach PATH: $dirs" ;; esac
case "$dirs" in *"$SCRATCH/wasi-sdk/bin"*) ;; *) fail "WASI_SDK_PATH's bin did not reach PATH: $dirs" ;; esac

# (7) A MISSING ENTRY IS REFUSED BY NAME, with the one line that fixes it - and wa_build_env_refuse is
# the printer, so every entry point says the same thing (item 6: "wa_build_env_refuse called on a missing
# entry with the one-line fix").
printf 'WA_BUILD_ZIG=%s/not-there\n' "$SCRATCH" > "$SCRATCH/home/.wasm-agent/build.env"
set +e
msg="$(WASM_AGENT_HOME="$SCRATCH/home" bash -c '. scripts/lib/build-requirements.sh; wa_build_env' 2>&1)"; code=$?
set -e
[ "$code" = 2 ] || fail "a record naming a missing zig exited $code, not 2: $msg"
case "$msg" in *'refused(WA_BUILD_ZIG)'*) ;; *) fail "a missing zig was not refused by name: $msg" ;; esac
case "$msg" in *'Fix: set WA_BUILD_ZIG='*) ;; *) fail "the refusal carries no one-line fix: $msg" ;; esac
printf 'WASI_SDK_PATH=%s/no-sysroot\n' "$SCRATCH" > "$SCRATCH/home/.wasm-agent/build.env"
mkdir -p "$SCRATCH/no-sysroot"
set +e
msg="$(WASM_AGENT_HOME="$SCRATCH/home" bash -c '. scripts/lib/build-requirements.sh; wa_build_env' 2>&1)"; code=$?
set -e
[ "$code" = 2 ] || fail "a record naming a wasi-sdk with no sysroot exited $code, not 2: $msg"
case "$msg" in *'refused(WASI_SDK_PATH)'*) ;; *) fail "a wasi-sdk without a sysroot was not refused by name: $msg" ;; esac
# The same refusal reaches scripts/fast.sh and scripts/deploy.sh: both call wa_build_env, and both stop.
set +e
fast_bad="$(WASM_AGENT_HOME="$SCRATCH/home" bash scripts/fast.sh --binary 2>&1)"; code=$?
set -e
[ "$code" = 2 ] || fail "scripts/fast.sh with a missing WASI_SDK_PATH exited $code, not 2: $(printf '%s' "$fast_bad" | tail -3)"
case "$fast_bad" in *build_env_incomplete*) ;; *) fail "scripts/fast.sh did not refuse by name on an incomplete record: $(printf '%s' "$fast_bad" | tail -3)" ;; esac
grep -q 'wa_build_env' scripts/deploy.sh || fail 'scripts/deploy.sh does not call wa_build_env, so it reads a different record than fast.sh'
grep -q 'wa_build_env' scripts/mission.sh || fail 'scripts/mission.sh does not read the build record, so a mission builds with a different toolchain than deploy.sh'
grep -q 'build-requirements.sh' lua/core/land.lua || fail 'lua/core/land.lua does not read the build record, so wa land builds with a different toolchain'

echo 'test-build-env: ok (absent is not a refusal, an unread key is named with its remedy and stops fast.sh, allowed keys reach PATH, the record is data and never sourced, every audited key is APPLIED, and a missing entry is refused by name with its fix)'
