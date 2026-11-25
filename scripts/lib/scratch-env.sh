#!/usr/bin/env bash
# THE SCRATCH ENVIRONMENT, checked and applied in one place (Fable 25/11, binding).
#
# WHY. Another worker's scratch runs rewrote the LIVE wa-sentinel.service and runtime-worktree.txt, ran scratch
# sentinels on the LIVE ledger, and an unreviewed upgrade.sh waited 729 s to replace the LIVE program - all
# because a scratch install inherited HOME, XDG_CONFIG_HOME and WASM_AGENT_DB from the session that started it.
# A run that can reach the live install does not land. So every run of an installer-shaped thing (version-install,
# upgrade.sh, deploy.sh, bootstrap.sh, wa-sentinel) asks THIS file first, in the environment it will run with,
# and stops unless every path is under one scratch root.
#
#   wa_scratch_env_check <root>    -> prints "ok"/"FAIL" lines, returns 0 only when every dimension is scratch
#   wa_scratch_env_apply <root>    -> the clean prefix: unset every inherited live variable, set them all to scratch
#
# The dimensions are Fable's: HOME, WASM_AGENT_HOME, the data dir, WA_INSTALL_DIR, the unit dir
# (WA_SENTINEL_UNIT_DIR), WASM_AGENT_DB, XDG_CONFIG_HOME, WA_RUNTIME_WORKTREE, WA_SENTINEL_SCRIPTS, the systemctl
# stub (never the real one), the ports (never 8799/8800/8801/8810) and the vault URLs (never set).
#
# It is a pure reader: it starts nothing, writes nothing, and reads only the environment and the filesystem.

wa_scratch_env_real() { realpath -m "${1:-}" 2>/dev/null || printf '%s' "${1:-}"; }

# <path> <root> -> 0 when path is under root.
wa_scratch_under() {
  case "$(wa_scratch_env_real "${1:-}")/" in
    "$(wa_scratch_env_real "${2:?root}")"/*) return 0 ;;
    *) return 1 ;;
  esac
}

wa_scratch_env_check() { # <root>
  local root bad=0 name value
  root="${1:?usage: wa_scratch_env_check <root>}"
  root="$(wa_scratch_env_real "$root")"
  printf 'scratch-env: root %s\n' "$root"
  case "$root/" in
    /home/*/.local/*|/home/*/.wasm-agent/*|/home/*/.config/*|*/wasm-agent/checkout/*)
      printf '  FAIL the scratch root is inside a live path: %s\n' "$root"; bad=1 ;;
  esac
  # HOME is the one a child inherits without being asked; WASM_AGENT_HOME defaults from it, so both are checked.
  local home="${HOME:-}"
  if [ -z "$home" ] || ! wa_scratch_under "$home" "$root"; then
    printf '  FAIL HOME = %s (not under %s)\n' "${home:-<unset>}" "$root"; bad=1
  else printf '  ok   HOME = %s\n' "$home"; fi
  for name in WASM_AGENT_HOME WASM_AGENT_DATA WA_INSTALL_DIR WA_SENTINEL_UNIT_DIR WA_SENTINEL_UNIT_SYSTEMCTL \
              WA_RUNTIME_WORKTREE WA_SENTINEL_SCRIPTS; do
    value="${!name:-}"
    if [ -z "$value" ]; then
      case "$name" in
        # These have a LIVE default when unset: the unit dir falls back to ~/.config/systemd/user, the data dir to
        # ~/.wasm-agent, the install dir to ~/.local/bin, systemctl to the real one. Unset is a FAIL for them.
        WASM_AGENT_HOME|WA_INSTALL_DIR|WA_SENTINEL_UNIT_DIR)
          printf '  FAIL %s unset (defaults to a live path)\n' "$name"; bad=1 ;;
        *) printf '  ok   %s unset\n' "$name" ;;
      esac
    elif wa_scratch_under "$value" "$root"; then
      printf '  ok   %s = %s\n' "$name" "$value"
    else
      printf '  FAIL %s = %s (not under %s)\n' "$name" "$value" "$root"; bad=1
    fi
  done
  # The systemctl must be a stub, never the real binary, whatever its path says.
  value="${WA_SENTINEL_UNIT_SYSTEMCTL:-}"
  if [ -n "$value" ] && [ "$(basename "$value")" = systemctl ] && [ "$(wa_scratch_env_real "$value")" = /usr/bin/systemctl ]; then
    printf '  FAIL WA_SENTINEL_UNIT_SYSTEMCTL is the real systemctl\n'; bad=1
  fi
  for name in WASM_AGENT_DB XDG_CONFIG_HOME WASM_AGENT_PORT WASM_AGENT_CLIENT_PORT \
              WASM_AGENT_VAULT_URL WASM_AGENT_OPENCODE_GO_VAULT_URL WASM_AGENT_VAULT_OPERATOR_URL; do
    value="${!name:-}"
    case "$name" in
      WASM_AGENT_DB|XDG_CONFIG_HOME)
        if [ -n "$value" ]; then printf '  FAIL %s = %s (must be unset for an installer run)\n' "$name" "$value"; bad=1
        else printf '  ok   %s unset\n' "$name"; fi ;;
      *PORT)
        case "$value" in
          '') printf '  FAIL %s unset (defaults to a live port)\n' "$name"; bad=1 ;;
          8799|8800|8801|8810) printf '  FAIL %s = %s (a live port)\n' "$name" "$value"; bad=1 ;;
          *) printf '  ok   %s = %s\n' "$name" "$value" ;;
        esac ;;
      *)
        if [ -n "$value" ]; then printf '  FAIL %s is set\n' "$name"; bad=1
        else printf '  ok   %s unset\n' "$name"; fi ;;
    esac
  done
  [ "$bad" = 0 ] || { printf 'scratch-env: NOT ISOLATED - do not run\n'; return 1; }
  printf 'scratch-env: ISOLATED\n'
  return 0
}

# The clean prefix Fable named, in one call: unset every inherited live variable, then set them all to scratch.
wa_scratch_env_apply() { # <root>
  local root name
  root="${1:?usage: wa_scratch_env_apply <root>}"
  unset WASM_AGENT_DB XDG_CONFIG_HOME WASM_AGENT_VAULT_URL WASM_AGENT_OPENCODE_GO_VAULT_URL WASM_AGENT_VAULT_OPERATOR_URL
  for name in $(compgen -e 2>/dev/null | grep -E '^(WASM_AGENT_|WA_INSTALL_DIR|WA_SENTINEL_)' || true); do unset "$name"; done
  export HOME="$root/home"
  export WASM_AGENT_HOME="$root/home"
  export WA_INSTALL_DIR="$root/install"
  export WA_SENTINEL_UNIT_DIR="$root/units"
  export WA_SENTINEL_UNIT_SYSTEMCTL="$root/bin/systemctl-stub"
  export WASM_AGENT_PORT="${WASM_AGENT_PORT:-19799}"
  export WASM_AGENT_CLIENT_PORT="${WASM_AGENT_CLIENT_PORT:-19800}"
  mkdir -p "$root/home" "$root/install" "$root/units" "$root/bin" 2>/dev/null || true
  printf 'scratch-env: applied (HOME, WASM_AGENT_HOME, WA_INSTALL_DIR, unit dir, systemctl stub, ports) under %s\n' "$root"
}

