#!/usr/bin/env bash
# The ONE way a Lua row is executed: the watchdog owns the process group, `env` builds the row's
# environment, and the binary is the last command in the chain.
#
# MEASURED 19/11 on avell (fast.sh:472-478 before this file): the chain ended in
# `env ... wa_fast_watchdog ...`, and `env` execs a PROGRAM, never a shell function - exit 127,
# `env: 'wa_fast_watchdog': No such file or directory`, on EVERY Lua row. A runner that reports 127
# for the whole suite reads like a broken tree and is a broken call: no row ever reached the node.
# The watchdog has to be the OUTERMOST command (`wa_fast_watchdog N LABEL -- env ... BIN --db ...`),
# or a row that hangs leaves its children behind - the leak this watchdog exists to close.
#
# The second half of the same call: `env "${cleared_flags[@]:-}" ...` with an EMPTY array expands the
# `:-` default to one empty word, so env is asked to run the empty string as a program - exit 127
# again, on any machine whose process has no WASM_AGENT_*/WA_MESH* variable to clear (a fresh CI shell).
# The array is therefore expanded as '${arr[@]+"${arr[@]}"}', which is empty when the array is empty
# and identical to the plain expansion when it is not (bash 3.2 through 5.x).
#
#   . scripts/lib/fast-watchdog.sh
#   . scripts/lib/fast-row-exec.sh
#   wa_fast_row_exec 120 "test-x.lua" /path/wa /path/t.db -- WASM_AGENT_HOME=/h WA_SCRIPT=/s
#   -> the row's own exit (124 when it hung and its group was killed)

# fast.sh defines this; a caller that sources this file alone (a test) still gets a path.
command -v native >/dev/null 2>&1 || native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf %s "$1"; fi; }

wa_fast_row_exec() { # <seconds> <label> <binary> <db> [-- <env-argument>...]
  local seconds=${1-} label=${2-} bin=${3-} db=${4-}
  shift 4 2>/dev/null || true
  [ "${1-}" = "--" ] && shift
  if [ -z "$bin" ] || [ -z "$db" ]; then
    printf 'watchdog: refused(watchdog_command_missing): no binary/db for %s\n' "${label:-a row}" >&2
    return 2
  fi
  # The watchdog first, env second, the binary last: env cannot exec a function, and a function cannot
  # own a process group it was not started in.
  wa_fast_watchdog "$seconds" "$label" -- env "$@" "$bin" --db "$db"
}

# One definition of "run this test hermetically", used by the parallel batch AND by the serial retry,
# so the retry measures exactly what the first attempt measured. WA_COMPONENTS_DIR is inside the row's own
# home (see "the components the Lua rows need" above): a component the test installs lands there, and a
# test that never installs one sees an empty directory rather than an unset variable.
lua_run() { # <script> <home>
  local home_native components name upper base env_file
  home_native=$( (command -v cygpath >/dev/null && cygpath -w "$2") || echo "$2")
  components=$( (command -v cygpath >/dev/null && cygpath -w "$2/.wasm-agent/components") || echo "$2/.wasm-agent/components")
  mkdir -p "$2/.wasm-agent/components" 2>/dev/null || true
  # The component this row's own text names, if the runner built it: installed (pinned, with its manifest)
  # into the row's own directory AND handed to the host through the development override the suites read.
  # Both halves are needed and neither is a guess - `WA_<NAME>_COMPONENT_WASM` is the variable the suite's
  # skip message used to print, so the file says which one it needs.
  local -a overrides=()
  if [ -n "${FAST_COMPONENT_SOURCE:-}" ]; then
    for name in $FAST_COMPONENT_NAMES; do
      [ -f "$FAST_COMPONENT_SOURCE/$name.wasm" ] || continue
      upper=$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')
      grep -q "WA_${upper}_COMPONENT_WASM" "$1" 2>/dev/null || continue
      cp "$FAST_COMPONENT_SOURCE/$name.json" "$FAST_COMPONENT_SOURCE/$name.wasm" \
         "$FAST_COMPONENT_SOURCE/$name.wasm.sha256" "$2/.wasm-agent/components/" 2>/dev/null || continue
      overrides+=("WA_${upper}_COMPONENT_WASM=$( (command -v cygpath >/dev/null && cygpath -w "$2/.wasm-agent/components/$name.wasm") || echo "$2/.wasm-agent/components/$name.wasm")")
      overrides+=("WA_${upper}_COMPONENT=1")
    done
  fi
  # Every variable this row is given, on ONE line each, for the probe row that checks they arrived
  # (`scripts/test-fast-row-environment.lua`): a variable the runner sets and the row never sees is the
  # failure this table exists to catch, and it is caught from inside the row, not from here.
  # A row is hermetic, and that has to be enforced here rather than trusted in each test: this node's
  # ambient environment exports the operator's real vault (`WASM_AGENT_VAULT_URL=http://192.168.1.27:8765`,
  # `WASM_AGENT_VAULT_DIR=...`), and a row that merely *pins the provider* reaches it. The chain was
  # measured 11/12 on this machine with host.http wrapped: `agent.lua` -> `provider.pin`
  # (`lua/core/provider.lua`) -> `vault.base` -> `vault.status` (`lua/core/vault.lua`, a GET
  # `<url>/status`) - a real HTTP request inside a row whose own header promises "no node, no network".
  # Three rows failed because of it and went green with these variables removed and nothing else
  # changed: test-vault-routing (1 of 6), test-context-usage (line 23: "no actual summary, and no
  # attempted request, at threshold equality") and test-done-gate (20 of 58). A row that needs a vault
  # sets its own (`scripts/test-vault-routing.lua` points WASM_AGENT_VAULT_URL at a stub it starts).
  # The whole credential lane goes, not just the URL: the per-route override and the local store are two
  # more ways for a test to read the machine it happens to run on.
  # And the node's own identity and mode (17/11 on avell: a run started THROUGH a node inherits that node's
  # WASM_AGENT_DB - its real ledger -, WASM_AGENT_IN_TURN, WASM_AGENT_RAW_CODE and WA_MESH; eight rows failed
  # there and passed everywhere else). A row that tests one of these sets it itself.
  # The list is main's fixed one (review r3 MUST 1): the computed allow-list that stood here was out of
  # scope for this split and it overwrote WA_FAST_CLEARED - the vault names fast.sh exports for
  # scripts/test-fast-row-environment.lua - with whatever ambient names it found, so the probe row either
  # failed (empty list) or passed without checking a single vault variable. WA_FAST_CLEARED is fast.sh's,
  # and this function passes it through unchanged.
  cleared_flags=(-u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE
    -u WASM_AGENT_VAULT_PASSPHRASE -u WASM_AGENT_VAULT_OPERATOR_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL
    -u WASM_AGENT_DB -u WASM_AGENT_IN_TURN -u WASM_AGENT_RAW_CODE -u WASM_AGENT_PROVENANCE
    -u WA_MESH -u WA_MESH_COMPONENT)
  # THE TABLE IS WRITTEN AFTER THE CLEARED LIST, NOT BEFORE (measured 19/11 on this branch: the table was
  # built above this point, so it recorded the PREVIOUS row's WA_FAST_CLEARED and the probe row read an
  # empty list for the very variables it exists to report). Every value in the table must be final at the
  # moment it is written; the order is the guarantee.
  base=$(basename "$1")
  env_file=$(native "$FAST_WORK/env/$base.env")
  mkdir -p "$FAST_WORK/env" 2>/dev/null || true
  {
    printf 'WASM_AGENT_LUA_ROOT=%s\n' "$FAST_ROOT"
    printf 'WASM_AGENT_HOME=%s\n' "$home_native"
    printf 'WA_COMPONENTS_DIR=%s\n' "$components"
    printf 'WA_FAST_COMPONENT_SOURCE=%s\n' "${FAST_COMPONENT_SOURCE:-}"
    printf 'WASM_AGENT_RENDEZVOUS=\n'
    printf 'WASM_AGENT_RELAY=\n'
    printf 'WASM_AGENT_MANAGED=0\n'
    printf 'WA_SCRIPT=%s\n' "$1"
    for name in "${overrides[@]}"; do printf '%s\n' "$name"; done
    printf 'WA_FAST_CLEARED=%s\n' "$WA_FAST_CLEARED"
    printf 'WA_FAST_ROW_ENV=%s\n' "$env_file"
    # The binary this run is about, for a row that has to run it as a program of its own rather than as the
    # node it is already inside (`scripts/test-release-sign.lua` asks it to verify the same six releases the
    # shell verifier is judged by). Native path, like every other path handed to a row.
    printf 'WA_FAST_BIN=%s\n' "$FAST_BIN"
  } > "$env_file" 2>/dev/null || true
  # The row: the watchdog outermost (it owns the process group), env second (it builds the row's
  # environment), the binary last. MEASURED 19/11: this ended in 'env ... wa_fast_watchdog ...', and env
  # execs a PROGRAM, never a shell function - exit 127, no row reached the node. The order, and why, is
  # in scripts/lib/fast-row-exec.sh; scripts/test-fast-watchdog.sh runs a row through it.
  wa_fast_row_exec "${WA_FAST_ROW_SECONDS:-120}" "$base" "$FAST_BIN" "$2/t.db" -- \
    ${cleared_flags[@]+"${cleared_flags[@]}"} \
    ${overrides[@]+"${overrides[@]}"} \
    WASM_AGENT_LUA_ROOT="$FAST_ROOT" WASM_AGENT_HOME="$home_native" \
    WA_COMPONENTS_DIR="$components" WA_FAST_COMPONENT_SOURCE="$FAST_COMPONENT_SOURCE" \
    WA_FAST_ROW_ENV="$env_file" WA_FAST_CLEARED="$WA_FAST_CLEARED" WA_FAST_BIN="$FAST_BIN" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT="$1"
}
