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
case "$(CDPATH= cd -- "$SCRATCH/home/.wasm-agent" && pwd)" in
  "$(CDPATH= cd -- "${HOME:-/nonexistent}" && pwd)"/.wasm-agent)
    echo 'test-build-env: refused(real_node_home): the scratch home is the operator'"'"'s own' >&2; exit 2 ;;
esac
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
mkdir -p "$SCRATCH/tools/mytool"
cat > "$SCRATCH/home/.wasm-agent/build.env" <<EOF
WA_BUILD_PATH=$SCRATCH/tools/mytool
WA_BUILD_ZIG=/opt/zig
WASI_SDK_PATH=/opt/wasi-sdk-24
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

echo 'test-build-env: ok (absent is not a refusal, an unread key is named with its remedy and stops fast.sh, allowed keys reach PATH, the record is data and never sourced)'
