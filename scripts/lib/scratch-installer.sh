#!/usr/bin/env bash
# THE ONE WAY A ROW GIVES AN INSTALLER ITS ENVIRONMENT (25/11).
#
# WHAT WENT WRONG WITHOUT IT (measured, landing-is-installable-by-download, 23:50Z and 00:01Z): a harness replaced
# HOME with a scratch directory and then ran the real scripts/deploy.sh. HOME is only ONE of the places an installer
# resolves state from, and every other one was still the operator's:
#
#   * the unit file:      scripts/lib/sentinel-unit.sh:41 takes ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user, and
#                         XDG_CONFIG_HOME was inherited as /home/victor/.config - so the deploy wrote and reloaded the
#                         LIVE ~/.config/systemd/user/wa-sentinel.service even though HOME was scratch;
#   * the user manager:   XDG_RUNTIME_DIR was inherited as /run/user/1000, so `systemctl --user` talked to the
#                         operator's manager and restarted the live sentinel;
#   * the ledger:         WASM_AGENT_DB was inherited as /home/victor/.wasm-agent/memory.db, so the sentinel that
#                         came up ran on the LIVE ledger;
#   * the port:           no WASM_AGENT_PORT, so the node it started defaulted to the live 8799;
#   * and the guard was stripped (`env -u WASM_AGENT_IN_TURN`), which is why the deploy did not refuse inside a turn.
#
# The row reported "ok (16 checks, 0 failed)" and left a wa-sentinel with HOME=/home/victor behind (pid 635976,
# killed 00:38:06Z). A harness that passes while reaching the live node is worse than a red one.
#
# SO: an installer is never started with the caller's environment filtered. It is started with an environment
# REBUILT from an allow-list (`env -i` plus the names below), every path under the caller's scratch root, the
# marker the turn guard reads PRESERVED (never stripped: a refusal inside a turn is the answer, not an obstacle),
# the vault URLs absent (nothing to inherit), and the live ports refused by name.
#
#   . "$ROOT/scripts/lib/scratch-installer.sh"
#   wa_installer_run --root "$W" --cd "$TREE" --port "$PORT" --install-dir "$W/install" \
#     --set WA_DEPLOY_FULL=1 -- bash scripts/deploy.sh --reason "a row"
#
# THIS LIBRARY IS THE HALF THAT BUILDS; scripts/lib/install-isolation.sh (mission release-node-updates) is the half
# that JUDGES. That guard asks the six questions of the environment a run will use; this library asks it about the
# environment it just built, before any child starts. A builder and a guard that disagree is a refusal here, not a
# surprise in the middle of an install.
#
# scripts/test-installer-data-isolation.sh proves the six dimensions on a child of this library and proves that a
# harness which only replaces HOME (tonight's) is caught.
#
# Pure bash, no jq, no python: the rows run under env -i with a bare PATH.

# THE LIVE PORTS: 8799/8800 are the node, 8801 its client, 8810 the launcher's. A child of this library may never
# point at one of them, because a probe on the live port is a probe of the live node.
wa_installer_live_port() {
  case "${1-}" in 8799|8800|8801|8810) return 0 ;; esac
  return 1
}

# THE SYSTEMCTL STUB. The runner gives a row its own (WA_SENTINEL_UNIT_SYSTEMCTL, ROW-CONTRACT); when a row is run
# anywhere else it must still not reach the operator's manager, so this library writes one under the scratch root
# and names it. It records the call and does nothing.
wa_installer_systemctl_stub() { # <root> -> prints the stub path
  local root="${1-}" bin path
  [ -n "$root" ] || { printf 'refused(installer_stub_no_root): the systemctl stub needs a scratch root\n' >&2; return 1; }
  bin="$root/bin"; path="$root/bin/systemctl-stub"
  mkdir -p "$bin" || { printf 'refused(installer_stub_mkdir): cannot create %s\n' "$bin" >&2; return 1; }
  cat > "$path" <<'STUB'
#!/bin/sh
# Written by scripts/lib/scratch-installer.sh: the stub a scratch installer gets for WA_SENTINEL_UNIT_SYSTEMCTL.
# It records the call beside the scratch root and never talks to an operator's user manager.
printf '%s\n' "$*" >> "$(dirname "$0")/../systemctl-calls.log"
exit 0
STUB
  chmod +x "$path" || { printf 'refused(installer_stub_chmod): cannot make %s executable\n' "$path" >&2; return 1; }
  printf '%s\n' "$path"
}

# THE ENVIRONMENT, as K=V lines (one per line; no value this library writes contains a newline). Callers that want
# to run something use wa_installer_run; the test asks for this list to check the six dimensions without running an
# installer at all.
#   wa_installer_env_prepare --root R [--port P] [--client-port P] [--install-dir D] [--set K=V]...
wa_installer_env_prepare() {
  local root="" port="" client="" install="" real_home real_store stub
  local -a sets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root="${2-}"; shift 2 ;;
      --port) port="${2-}"; shift 2 ;;
      --client-port) client="${2-}"; shift 2 ;;
      --install-dir) install="${2-}"; shift 2 ;;
      --set) sets+=("${2-}"); shift 2 ;;
      *) printf 'refused(installer_env_usage): unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  # --- REFUSALS FIRST: nothing below creates a directory until every question is answered ---
  [ -n "$root" ] || { printf 'refused(installer_env_no_root): a scratch root is required; an installer is never started in the caller environment\n' >&2; return 2; }
  case "$root" in /*) ;; *) printf 'refused(installer_env_relative): the scratch root %s is not absolute, so where it points depends on the cwd\n' "$root" >&2; return 2 ;; esac
  [ -d "$root" ] || { printf 'refused(installer_env_missing): the scratch root %s does not exist\n' "$root" >&2; return 2; }
  root="$(CDPATH= cd -- "$root" 2>/dev/null && pwd -P)" || { printf 'refused(installer_env_unresolved): the scratch root cannot be resolved\n' >&2; return 2; }
  real_home="$(CDPATH= cd -- "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || real_home=
  real_store="$real_home/.wasm-agent"
  local child_home="$root/home"
  # THE HOME THE CHILD WOULD GET MUST NOT BE THE OPERATOR'S OR ITS STORE (the shared rule, scripts/lib/scratch-home.sh).
  wa_scratch_home_guard "$child_home" || return 2
  case "$root/" in
    "$real_home/"|"$real_store/"*) printf 'refused(installer_env_real): the scratch root %s is the operator home or inside the operator store\n' "$root" >&2; return 2 ;;
  esac
  case "$child_home/" in "$root"/*) ;; *) printf 'refused(installer_env_escape): %s is not under the root %s\n' "$child_home" "$root" >&2; return 2 ;; esac
  if [ -n "$install" ]; then
    case "$install" in /*) ;; *) printf 'refused(installer_env_install_relative): --install-dir %s is not absolute\n' "$install" >&2; return 2 ;; esac
    case "$install/" in "$root"/*) ;; *) printf 'refused(installer_env_install_escape): --install-dir %s is not under the scratch root %s\n' "$install" "$root" >&2; return 2 ;; esac
  fi
  # THE PORT IS NEVER GUESSED: unset is the live 8799, which is the node.
  if [ -z "$port" ]; then printf 'refused(installer_env_no_port): WASM_AGENT_PORT was not given, and the default is the live 8799\n' >&2; return 2; fi
  case "$port" in ''|*[!0-9]*) printf 'refused(installer_env_port): %s is not a port number\n' "$port" >&2; return 2 ;; esac
  wa_installer_live_port "$port" && { printf 'refused(installer_env_live_port): %s is a live port (8799/8800/8801/8810)\n' "$port" >&2; return 2; }
  [ -n "$client" ] || client=$((port + 1))
  case "$client" in ''|*[!0-9]*) printf 'refused(installer_env_client_port): %s is not a port number\n' "$client" >&2; return 2 ;; esac
  wa_installer_live_port "$client" && { printf 'refused(installer_env_live_port): the client port %s is a live port\n' "$client" >&2; return 2; }
  local kv k v
  for kv in "${sets[@]:-}"; do
    [ -n "$kv" ] || continue
    case "$kv" in *=*) ;; *) printf 'refused(installer_env_set): --set %s is not K=V\n' "$kv" >&2; return 2 ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in ''|*[!A-Za-z0-9_]*) printf 'refused(installer_env_set_name): %s is not a variable name\n' "$k" >&2; return 2 ;; esac
    case "$k" in
      HOME|WASM_AGENT_HOME|USERPROFILE|WA_INSTALL_DIR|WASM_AGENT_DB|XDG_CONFIG_HOME|XDG_RUNTIME_DIR|WASM_AGENT_PORT|WASM_AGENT_CLIENT_PORT|WA_PORT|WA_CLIENT_PORT|WA_SENTINEL_UNIT_DIR|WA_SENTINEL_UNIT_SYSTEMCTL)
        # THE SENTINEL DIMENSIONS MAY BE NAMED ONLY INSIDE THE ROOT: a row that brings its own systemctl spy (the
        # runner's contract) keeps it, and the value is checked below like every other path.
        case "$k" in
          WA_SENTINEL_UNIT_DIR|WA_SENTINEL_UNIT_SYSTEMCTL) case "$v/" in "$root"/*) ;; *) printf 'refused(installer_env_set_dimension): --set %s=%s is not under the scratch root\n' "$k" "$v" >&2; return 2 ;; esac ;;
          *) printf 'refused(installer_env_set_dimension): --set %s would move a dimension this library owns; use the option for it\n' "$k" >&2; return 2 ;;
        esac ;;
    esac
    # A --set VALUE THAT NAMES THE OPERATOR HOME IS THE SAME ESCAPE AS AN UNSET VARIABLE.
    case "$v" in
      "$real_home"|"$real_home"/*)
        case "$v/" in "$root"/*) ;; *) printf 'refused(installer_env_set_real): --set %s=%s names the operator home\n' "$k" "$v" >&2; return 2 ;; esac ;;
    esac
  done
  # --- the dimensions. Nothing inherited survives except what is named here. ---
  mkdir -p "$child_home" "$root/tmp" "$root/units" "$root/config" "$root/run" "$root/data" "$root/cache" "$root/state" "$root/bin" \
    || { printf 'refused(installer_env_mkdir): cannot create the scratch tree under %s\n' "$root" >&2; return 2; }
  # THE STUB IS NOT NAMED systemctl, and that is deliberate: scripts/lib/install-isolation.sh refuses any
  # WA_SENTINEL_UNIT_SYSTEMCTL whose name ends in /systemctl, because a real one handed to a scratch run can
  # restart the operator's unit. A stub carrying that name would make the guard's own refusal unreadable.
  stub="$(wa_installer_systemctl_stub "$root")" || return 2
  [ -n "$install" ] || install="$root/install"
  mkdir -p "$install" || { printf 'refused(installer_env_mkdir): cannot create the install dir %s\n' "$install" >&2; return 2; }
  printf 'HOME=%s\n' "$child_home"
  printf 'USERPROFILE=%s\n' "$child_home"
  printf 'WASM_AGENT_HOME=%s\n' "$child_home"
  printf 'TMPDIR=%s\n' "$root/tmp"
  printf 'WA_INSTALL_DIR=%s\n' "$install"
  printf 'WASM_AGENT_DB=%s\n' "$root/ledger.db"
  printf 'XDG_CONFIG_HOME=%s\n' "$root/config"
  printf 'XDG_RUNTIME_DIR=%s\n' "$root/run"
  printf 'XDG_DATA_HOME=%s\n' "$root/data"
  printf 'XDG_CACHE_HOME=%s\n' "$root/cache"
  printf 'XDG_STATE_HOME=%s\n' "$root/state"
  printf 'WA_SENTINEL_UNIT_DIR=%s\n' "$root/units"
  printf 'WA_SENTINEL_UNIT_SYSTEMCTL=%s\n' "$stub"
  printf 'DBUS_SESSION_BUS_ADDRESS=unix:path=%s/no-bus\n' "$root"
  printf 'WASM_AGENT_PORT=%s\n' "$port"
  printf 'WASM_AGENT_CLIENT_PORT=%s\n' "$client"
  printf 'WA_PORT=%s\n' "$port"
  printf 'WA_CLIENT_PORT=%s\n' "$client"
  # THE GUARD'S OWN NAMES TRAVEL UNCHANGED. Present stays present with the same value; absent stays absent. A row
  # never decides what the guard may see.
  [ -n "${WASM_AGENT_IN_TURN+x}" ] && printf 'WASM_AGENT_IN_TURN=%s\n' "$WASM_AGENT_IN_TURN"
  [ -n "${WASM_AGENT_PROVENANCE+x}" ] && printf 'WASM_AGENT_PROVENANCE=%s\n' "$WASM_AGENT_PROVENANCE"
  # The caller's language and locale, because a row's own output is compared as text.
  [ -n "${LANG+x}" ] && printf 'LANG=%s\n' "$LANG"
  [ -n "${LC_ALL+x}" ] && printf 'LC_ALL=%s\n' "$LC_ALL"
  [ -n "${TZ+x}" ] && printf 'TZ=%s\n' "$TZ"
  printf 'TERM=%s\n' "${TERM:-dumb}"
  # PATH is the one inherited value an installer cannot do without (git, cargo, python3, node), and it is not a
  # location an installer WRITES to. The stub directory goes first so a row never reaches a real systemctl by PATH.
  printf 'PATH=%s:%s\n' "$root/bin" "${PATH:-/usr/local/bin:/usr/bin:/bin}"
  # AND THE CALLER'S OWN NAMES, after every dimension above (a --set of a dimension was refused above).
  for kv in "${sets[@]:-}"; do [ -n "$kv" ] && printf '%s\n' "$kv"; done
  return 0
}

# RUN SOMETHING WITH THAT ENVIRONMENT.
#   wa_installer_run --root R --cd DIR --port P [--client-port P] [--install-dir D] [--set K=V]... -- cmd...
wa_installer_run() {
  local root="" cwd="" port="" client="" install=""
  local -a sets=() args=() opts=() envlines=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root="${2-}"; shift 2 ;;
      --cd) cwd="${2-}"; shift 2 ;;
      --port) port="${2-}"; shift 2 ;;
      --client-port) client="${2-}"; shift 2 ;;
      --install-dir) install="${2-}"; shift 2 ;;
      --set) sets+=("${2-}"); shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) printf 'refused(installer_run_usage): unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ ${#args[@]} -gt 0 ] || { printf 'refused(installer_run_usage): no command given\n' >&2; return 2; }
  opts+=(--root "$root")
  [ -n "$port" ] && opts+=(--port "$port")
  [ -n "$client" ] && opts+=(--client-port "$client")
  [ -n "$install" ] && opts+=(--install-dir "$install")
  local kv line
  for kv in "${sets[@]:-}"; do [ -n "$kv" ] && opts+=(--set "$kv"); done
  while IFS= read -r line; do [ -n "$line" ] && envlines+=("$line"); done < <(wa_installer_env_prepare "${opts[@]}")
  [ ${#envlines[@]} -gt 0 ] || { printf 'refused(installer_run_env): the environment could not be built\n' >&2; return 2; }
  # THE REVIEWED GUARD (scripts/lib/install-isolation.sh, mission release-node-updates) ASKS THE SAME QUESTION OF
  # THE ENVIRONMENT THIS LIBRARY JUST BUILT. If the two ever disagree, this is the line that says so - by refusing.
  local repo_root guard_out
  repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" || repo_root=
  if [ -n "$repo_root" ] && [ -r "$repo_root/scripts/lib/install-isolation.sh" ]; then
    guard_out="$(env -i "${envlines[@]}" bash -c '. "$1/scripts/lib/install-isolation.sh"; wa_install_isolation_guard "$2" "$3"' _ "$repo_root" "$root" "$root/home" 2>&1)" || {
      printf 'refused(installer_env_guard): install-isolation.sh refuses the environment this library built: %s\n' "$(printf '%s' "$guard_out" | tr '\n' '|')" >&2
      return 2
    }
  else
    printf 'refused(installer_env_guard_missing): scripts/lib/install-isolation.sh is not beside this library, so the environment it built cannot be judged by the reviewed guard\n' >&2
    return 2
  fi
  if [ -n "$cwd" ]; then
    [ -d "$cwd" ] || { printf 'refused(installer_run_cwd): %s is not a directory\n' "$cwd" >&2; return 2; }
    ( cd "$cwd" && exec env -i "${envlines[@]}" "${args[@]}" )
  else
    env -i "${envlines[@]}" "${args[@]}"
  fi
}
