#!/usr/bin/env bash
# IS THIS INSTALL RUN ISOLATED FROM THE NODE THE OPERATOR LIVES ON? - six answers, and a scratch run refuses
# unless all six are scratch.
#
# WHY (Fable, 25/11, after a night of scratch runs that were not scratch). A harness that runs
# scripts/linux/bootstrap.sh, scripts/deploy.sh, scripts/upgrade.sh or scripts/release-install.sh inherits the
# environment of whatever started it. On a machine whose operator runs a node, that environment names the
# operator's OWN install and, through it, the live systemd user unit:
#
#   * WA_INSTALL_DIR unset defaults to <home>/.local/bin - the live install;
#   * the unit dir default is $XDG_CONFIG_HOME/systemd/user, and XDG_CONFIG_HOME inherited from a desktop
#     session is where the LIVE wa-sentinel.service lives: an upgrade.sh run from such a shell rewrites the
#     service that keeps the operator's node alive (measured 25/11 on this machine);
#   * WA_SENTINEL_UNIT_SYSTEMCTL inherited as the real systemctl lets a scratch run restart a real unit;
#   * WASM_AGENT_DB inherited points a scratch process at the operator's ledger;
#   * WASM_AGENT_PORT 8799/8800 is the live node's port, and a scratch node that binds it fights the live one;
#   * the operator store <home>/.wasm-agent, reached through WASM_AGENT_HOME, is refused by
#     scripts/lib/scratch-home.sh already - this file adds the six things that surround it.
#
# Each check names what is wrong and how to fix it, and the guard prints the whole list rather than stopping at
# the first: a harness author needs the complete clean prefix to paste.
#
#   . "$ROOT/scripts/lib/install-isolation.sh"
#   wa_install_isolation_guard "$SCRATCH_ROOT" "$HOME_FOR_THE_RUN" || exit 2
#
# It writes nothing. It answers one question about the environment it is called in - so a harness that runs an
# installer must call it AFTER it has set its own environment and BEFORE the installer starts.

# <scratch-root> <home-the-run-will-use> -> 0 isolated; 1 not isolated (the reasons on stderr); 2 cannot tell.
wa_install_isolation_guard() {
  local root="${1-}" home="${2-}"
  if [ -z "$root" ] || [ -z "$home" ]; then
    printf 'refused(isolation_unknown): this run did not name its scratch root and the home it will use, so nothing can show it is isolated\n' >&2
    return 2
  fi
  local real
  real="$(CDPATH= cd -- "$root" 2>/dev/null && pwd -P)" || real=
  if [ -z "$real" ]; then
    printf 'refused(isolation_unknown): the scratch root %s does not exist, so where this run writes cannot be compared with anything\n' "$root" >&2
    return 2
  fi
  local bad=0
  under() { # <what> <path>
    case "$2" in
      "$real"|"$real"/*) return 0 ;;
      *) printf 'not_isolated: %s = %s is not under the scratch root %s\n' "$1" "$2" "$real" >&2; return 1 ;;
    esac
  }
  # 1. THE DATA DIR the run will write (the operator's store is the one thing that must never be named).
  local data="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$home}/.wasm-agent}"
  under "the data dir" "$data" || bad=1
  # 2. THE INSTALL DIR the installer will write into. Unset is the live default, so unset is a refusal.
  if [ -z "${WA_INSTALL_DIR:-}" ]; then
    printf 'not_isolated: WA_INSTALL_DIR is unset, so the installer would write %s/.local/bin (the live install)\n' "$home" >&2
    bad=1
  else
    under "WA_INSTALL_DIR" "$WA_INSTALL_DIR" || bad=1
  fi
  # 3. THE UNIT DIR the install wrote the sentinel service into, and 4. THE SYSTEMCTL it would talk to.
  local units="${WA_SENTINEL_UNIT_DIR:-${XDG_CONFIG_HOME:-$home/.config}/systemd/user}"
  under "WA_SENTINEL_UNIT_DIR" "$units" || bad=1
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then under XDG_CONFIG_HOME "$XDG_CONFIG_HOME" || bad=1; fi
  local sudo="${WA_SENTINEL_UNIT_SYSTEMCTL:-systemctl}"
  case "$sudo" in
    systemctl|*/systemctl)
      printf 'not_isolated: WA_SENTINEL_UNIT_SYSTEMCTL is %s, the real systemctl: a scratch run may restart the operator service\n' "$sudo" >&2
      bad=1 ;;
    *) under WA_SENTINEL_UNIT_SYSTEMCTL "$sudo" || bad=1 ;;
  esac
  # 5. THE LEDGER.
  if [ -n "${WASM_AGENT_DB:-}" ]; then under WASM_AGENT_DB "$WASM_AGENT_DB" || bad=1; fi
  # 6. THE PORT. The live node's, and the ports one command away from it, are not a scratch node's.
  local var port
  for var in WASM_AGENT_PORT WASM_AGENT_CLIENT_PORT; do
    port="${!var:-}"
    case "$port" in
      '') printf 'not_isolated: %s is unset, so the node would take its live default (8799/8800)\n' "$var" >&2; bad=1 ;;
      8799|8800|8801|8810) printf 'not_isolated: %s = %s is a live port\n' "$var" "$port" >&2; bad=1 ;;
    esac
  done
  # A VAULT IS NOT THIS RUN'S: a scratch installer must not be able to reach the operator's secrets.
  if [ -n "${WASM_AGENT_VAULT_URL:-}${WASM_AGENT_OPENCODE_GO_VAULT_URL:-}" ]; then
    printf 'not_isolated: a vault URL is set (WASM_AGENT_VAULT_URL/WASM_AGENT_OPENCODE_GO_VAULT_URL), so this run could reach the operator secrets\n' >&2
    bad=1
  fi
  [ "$bad" = 0 ] || return 1
  return 0
}
