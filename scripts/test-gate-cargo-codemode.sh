#!/usr/bin/env bash
# The gate's cargo-codemode check builds where the rest of the gate builds.
#
# MEASURED 21/11 (land-20261121T210239Z-fd11e699): scripts/gate-cargo-codemode.sh named no CARGO_TARGET_DIR,
# so cargo cold-built a second copy of the workspace into the landing tree's rust/target - 138 s of every
# landing, minutes after scripts/fast.sh had compiled the same crate into the tree's named build dir.
# This row holds the script to that directory with a stub cargo (no compile, seconds): the target it hands
# cargo is the one scripts/lib/build-target.sh names for this tree, for the build AND for the test run; a
# caller that names CARGO_TARGET_DIR keeps it; and the test output the gate counts still reaches stdout.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/wa-gate-codemode-XXXXXX") || { echo "FAIL test-gate-cargo-codemode: mktemp failed"; exit 1; }
trap 'rm -rf "$work"' EXIT
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }
mkdir -p "$work/bin" "$work/home" "$work/assets"
cat > "$work/bin/cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "${CARGO_TARGET_DIR:-<unset>}" "$*" >> "$STUB_LOG"
case " $* " in *" --no-run "*) exit 0 ;; esac
echo "test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"
STUB
chmod +x "$work/bin/cargo"
run() { # <log> [VAR=value...]
  local log=$1; shift
  env -u CARGO_TARGET_DIR -u WASM_AGENT_SHARED_BUILD_DIR HOME="$work/home" WASM_AGENT_HOME="$work/home" \
    PATH="$work/bin:$PATH" STUB_LOG="$log" WA_CODEMODE_BUILD_ASSETS="$work/assets" WA_BUILD_HOST_LOCK_WAIT=5 "$@" \
    bash "$ROOT/scripts/gate-cargo-codemode.sh"
}
expected=$(env HOME="$work/home" WASM_AGENT_HOME="$work/home" bash -c '. "$1/scripts/lib/build-target.sh"; wa_build_target "$1"' _ "$ROOT")

out=$(run "$work/named.log" 2>"$work/named.err"); code=$?
[ "$code" = 0 ] && ok "the check passes with a cargo that passes" || bad "the check exited $code: $(tail -3 "$work/named.err" | tr '\n' ' ')"
[ "$(wc -l < "$work/named.log" 2>/dev/null | tr -d '[:space:]')" = 2 ] && ok "cargo runs twice: the build, then the tests" \
  || bad "cargo was expected twice (build, tests): $(cat "$work/named.log" 2>/dev/null | tr '\n' ' ')"
case "$expected" in "$work/home/.wasm-agent/build/target/"?*) ok "the tree's build dir is under the node's one build root" ;;
  *) bad "the resolver named an unexpected build dir: $expected" ;; esac
if [ -n "$expected" ] && [ "$(cut -d'|' -f1 "$work/named.log" | sort -u)" = "$expected" ]; then
  ok "both cargo calls build into the tree's named build dir, never a second copy in rust/target"
else
  bad "cargo was given $(cut -d'|' -f1 "$work/named.log" | sort -u | tr '\n' ' '), expected $expected"
fi
sed -n 1p "$work/named.log" | grep -q -- '--no-run .*-p wa-capabilities' && ok "the first call is the test build (--no-run), the one that waits on the node build lock" \
  || bad "the first cargo call is not the --no-run build: $(sed -n 1p "$work/named.log")"
sed -n 2p "$work/named.log" | grep -q -- 'test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities codemode$' \
  && ok "the second call is the gate's own command, unchanged" || bad "the test command changed: $(sed -n 2p "$work/named.log")"
printf '%s\n' "$out" | grep -q '^test result: ok. 3 passed' && ok "the test result line the gate counts is on stdout" \
  || bad "no 'test result' line on stdout: $out"
[ "$(cat "$expected/tree" 2>/dev/null)" = "$(cd "$ROOT" && pwd -P)" ] && ok "the build dir carries the tree marker wa clean judges it by" \
  || bad "no tree marker in $expected"

run "$work/caller.log" CARGO_TARGET_DIR="$work/mine" >/dev/null 2>&1
[ "$(cut -d'|' -f1 "$work/caller.log" 2>/dev/null | sort -u)" = "$work/mine" ] && ok "a caller that names CARGO_TARGET_DIR keeps it" \
  || bad "a caller-named CARGO_TARGET_DIR was not kept: $(cat "$work/caller.log" 2>/dev/null | tr '\n' ' ')"
run "$work/tree.log" WASM_AGENT_SHARED_BUILD_DIR=0 >/dev/null 2>&1
[ "$(cut -d'|' -f1 "$work/tree.log" 2>/dev/null | sort -u)" = "$ROOT/rust/target" ] && ok "WASM_AGENT_SHARED_BUILD_DIR=0 still means the tree's rust/target" \
  || bad "WASM_AGENT_SHARED_BUILD_DIR=0 gave: $(cat "$work/tree.log" 2>/dev/null | tr '\n' ' ')"

if [ "$fails" = 0 ]; then echo "test-gate-cargo-codemode: ok"; exit 0; fi
echo "test-gate-cargo-codemode: $fails failed"; exit 1
