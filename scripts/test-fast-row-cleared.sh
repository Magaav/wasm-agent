#!/usr/bin/env bash
# A Lua row gets fast.sh's WA_FAST_CLEARED unchanged and never sees the vault/node variables
# (review r3 MUST 1 of the test-runner-hygiene split): lua_run used to RECOMPUTE WA_FAST_CLEARED from
# whatever WASM_AGENT_* names happened to be ambient, so with none it was empty (the probe row
# scripts/test-fast-row-environment.lua errors) and with an unrelated one it named only that one (the
# probe passes without checking a single vault variable).
#
#   bash scripts/test-fast-row-cleared.sh
#
# A fake binary stands in for wa and prints what it received; no node, no network, scratch only.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
fail() { printf 'test-fast-row-cleared: %s\n' "$*" >&2; exit 1; }
. "$ROOT/scripts/lib/scratch-home.sh"
scratch_root="$(wa_scratch_root wa-fast-row-cleared)" || exit 2
WORK="$(mktemp -d "$scratch_root/wa-fast-row-cleared-XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/fake-wa" <<'BIN'
#!/usr/bin/env bash
printf 'CLEARED=%s\n' "${WA_FAST_CLEARED-<unset>}"
printf 'VAULT_URL=%s\n' "${WASM_AGENT_VAULT_URL-<unset>}"
printf 'DB=%s\n' "${WASM_AGENT_DB-<unset>}"
printf 'FOO=%s\n' "${WASM_AGENT_FOO-<unset>}"
BIN
chmod +x "$WORK/fake-wa"
mkdir -p "$WORK/home" "$WORK/work"
row() { # extra env assignments for the ambient process
  env -i PATH="$PATH" HOME="$WORK/home" "$@" bash -c '
    . "$1/scripts/lib/fast-watchdog.sh"; . "$1/scripts/lib/fast-row-exec.sh"
    FAST_WORK="$2/work" FAST_BIN="$2/fake-wa" FAST_ROOT="$1" FAST_COMPONENT_SOURCE= FAST_COMPONENT_NAMES=
    WA_FAST_CLEARED=WASM_AGENT_VAULT_URL,WASM_AGENT_VAULT_DIR,WASM_AGENT_VAULT_KEYSTORE,WASM_AGENT_VAULT_PASSPHRASE
    export WA_FAST_CLEARED
    lua_run "$1/scripts/test-fast-row-cleared.sh" "$2/home"' _ "$ROOT" "$WORK"
}
want=WASM_AGENT_VAULT_URL,WASM_AGENT_VAULT_DIR,WASM_AGENT_VAULT_KEYSTORE,WASM_AGENT_VAULT_PASSPHRASE
# 1. a clean process: the list is fast.sh's, not empty
out=$(row) || fail "clean row exited $?: $out"
printf '%s\n' "$out" | grep -qx "CLEARED=$want" || fail "clean process: WA_FAST_CLEARED changed: $out"
# 2. ambient node/vault variables plus an unrelated one: the list is still fast.sh's, and the row sees none of
#    the cleared variables
out=$(row WASM_AGENT_VAULT_URL=http://192.0.2.1:8765 WASM_AGENT_DB=/real/memory.db WASM_AGENT_FOO=1) || fail "ambient row exited $?: $out"
printf '%s\n' "$out" | grep -qx "CLEARED=$want" || fail "ambient process: WA_FAST_CLEARED changed: $out"
printf '%s\n' "$out" | grep -qx 'VAULT_URL=<unset>' || fail "the vault URL reached the row: $out"
printf '%s\n' "$out" | grep -qx 'DB=<unset>' || fail "the node DB reached the row: $out"
echo "fast row cleared ok (2 cases)"
