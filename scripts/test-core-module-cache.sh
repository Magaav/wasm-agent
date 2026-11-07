#!/usr/bin/env bash
# A2.7: the compiled-module cache, checked by behaviour and by where the crossings went, not by timing
# (docs/KERNEL.md, "A2.7"). The guest keeps each module's compiled chunk keyed by the module's digest,
# so a boot loads bytecode instead of text - as long as the file has not changed. Two things have to be
# true, and this script is both of them:
#
#   1. the cache is *used*: loading the same, unchanged module a second time crosses `__digest` and no
#      `__source` at all (the text never enters the guest again);
#   2. the cache cannot go stale: a module rewritten between two loads is compiled again from its new
#      text, and the core sees the new module - the digest is a check on the file, not a memory of it.
#
# The probe script is the only thing that runs, so the profile's counts are exactly its loads. Native
# has no cache; it has to answer the same way, which is the parity half of the check.
#
#   bash scripts/test-core-module-cache.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "module-cache: no wa binary (set WA_BIN)" >&2; exit 2; }
core="${AGENT_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}"
[ -f "$core" ] || { echo "module-cache: no agent-core at $core (run bash scripts/build-agent-core.sh, set AGENT_CORE)" >&2; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
bin="$(native "$bin")"; core="$(native "$core")"
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-module-cache-XXXXXX")"
trap '[ "${KEEP:-0}" = 1 ] && echo "module-cache: kept $work" >&2 || rm -rf "$work"' EXIT

# A lua root per mode: one marker module, so a module is a file the kernel reads (`__source`) and
# digests (`__digest`) and nothing about the checkout's own tree is in the answer. Each mode gets its
# own copy, because the probe rewrites the marker as part of what it checks.

# Three loads: the first compiles and caches, the second follows a rewrite (so it must not use the
# chunk compiled from the old text), the third is the same bytes again (so it must use the cache).
cat > "$work/probe.lua" <<'LUA'
local root = host.getenv('WASM_AGENT_LUA_ROOT')
local first = dofile('probe/marker.lua')
assert(host.write_file(root .. '/probe/marker.lua', 'return "v2, rewritten and longer"\n'))
local second = dofile('probe/marker.lua')
local third = dofile('probe/marker.lua')
print('first=' .. tostring(first))
print('second=' .. tostring(second))
print('third=' .. tostring(third))
print('loaded=' .. tostring(LOADED_SOURCES['probe/marker.lua'] == host.sha256('return "v2, rewritten and longer"\n')))
LUA

run_mode() { # run_mode <native|component>
  local mode=$1 home="$work/$1/home" root="$work/$1/lua-root"
  mkdir -p "$home" "$root/probe"
  printf 'return "v1"\n' > "$root/probe/marker.lua"
  if [ "$mode" = native ]; then
    env -u WASM_AGENT_DB WASM_AGENT_LUA_ROOT="$(native "$root")" WASM_AGENT_HOME="$(native "$home")" \
      WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT="$(native "$work/probe.lua")" \
      timeout 180 "$bin" --db "$(native "$home/t.db")" > "$work/$mode/out" 2>&1
  else
    env -u WASM_AGENT_DB WASM_AGENT_LUA_ROOT="$(native "$root")" WASM_AGENT_HOME="$(native "$home")" \
      WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_CORE_CALL_PROFILE=1 \
      timeout 300 "$bin" --db "$(native "$home/t.db")" --core-component "$core" "$(native "$work/probe.lua")" > "$work/$mode/out" 2>&1
  fi
  echo "$?" > "$work/$mode/code"
}
mkdir -p "$work/native" "$work/component"
run_mode native
run_mode component

fail=0
note() { echo "module-cache: $*"; }
bad() { echo "module-cache: FAIL $*" >&2; fail=1; }

for mode in native component; do
  [ "$(cat "$work/$mode/code")" = 0 ] || bad "$mode exited $(cat "$work/$mode/code"): $(tail -3 "$work/$mode/out")"
done
want='first=v1
second=v2, rewritten and longer
third=v2, rewritten and longer
loaded=true'
got="$(grep -E '^(first|second|third|loaded)=' "$work/component/out")"
[ "$got" = "$want" ] || bad "the component answered: $(printf '%s' "$got" | tr '\n' ' ')"
got="$(grep -E '^(first|second|third|loaded)=' "$work/native/out")"
[ "$got" = "$want" ] || bad "native answered: $(printf '%s' "$got" | tr '\n' ' ')"

# Where the crossings went: three loads, exactly one whose text had to enter the guest for each of the
# two distinct texts, and one that was answered from the compiled chunk.
block="$work/component/out"
sources="$(grep -o '__source calls=[0-9]*' "$block" | head -1 | grep -o '[0-9]*$')"
digests="$(grep -o '__digest calls=[0-9]*' "$block" | head -1 | grep -o '[0-9]*$')"
[ "${sources:-x}" = 2 ] || bad "__source crossings were '${sources:-none}', expected 2 (the two texts)"
[ "${digests:-x}" = 3 ] || bad "__digest crossings were '${digests:-none}', expected 3 (one per load)"

if [ "$fail" = 0 ]; then
  note "pass: 3 loads, 2 texts, $sources __source / $digests __digest crossings; a rewritten module was recompiled"
fi
exit "$fail"
