#!/usr/bin/env bash
# The sentinel's systemd --user unit: ONE writer for the bytes, so a deploy and the install front door
# cannot describe the same watcher differently.
#
# WHY A UNIT AT ALL (measured on the laptop, 22/11). On a machine whose install lives under $HOME the
# sentinel ran as whatever started it - a nohup, or a transient `systemd-run` unit - and `deploy.sh`
# brought it back with `wa-sentinel start` from inside its own transient unit. With nothing outside
# owning the role, `start` has three legal answers and none of them is "a watcher on the new bytes":
# a detached child of the deploy (which the deploy's own exit can take with it), a refusal
# (`Owner::Unrecognised` - "which cannot be shown to own this watcher"), or the manager of a unit that
# is not the watcher's. Seven deploys of one night installed the node and then reported "node installed,
# but the sentinel would not start". A unit is the shape the other nodes already run
# (deploy/wa-sentinel.service on the servers), and with one the same `start` is a `systemctl --user
# restart` of the watcher's own unit - from a deploy that lives in its own transient unit, so the
# restart does not signal the thing performing it (`role::placement`).
#
# WHY THE TEXT ALSO LIVES IN THE FRONT DOOR (scripts/linux/bootstrap.sh). bootstrap.sh writes this unit
# for a release install and must keep working from a fetched bundle, which carries no scripts/lib
# (scripts/install.sh fetches a named few). So the front door keeps its heredoc and
# scripts/test-sentinel-unit.sh proves the two texts identical, line for line: the duplication is
# checked, not trusted, and a change to one that is not made to the other fails a test that names the
# line which differs.
#
# WHAT THE UNIT SAYS, and why each line is load-bearing:
#   * WA_SENTINEL_SUPERVISOR=user:wa-sentinel.service - the "named the way wa-sentinel asks" half
#     (`role::stated_owner`: "none", "user:<unit>", or a unit name). A stated fact beats inference, so a
#     deploy's `start`/`stop` asks THIS unit's manager instead of guessing from a control group.
#   * Restart=always + RestartSec=5: a watcher that is a deploy's child dies with the deploy. The unit
#     is what makes "the supervisor is not a child of the node" true on a machine with one user.
#   * EnvironmentFile=-<env>: '-' because a node with no env file is normal, not an error.
#   * StandardOutput is inherited (the journal): an `append:` file grew without bound before.
#
# Sourced, never executed, and side-effect free: functions only.

wa_sentinel_unit_name() { printf '%s' "${WA_SENTINEL_UNIT_NAME:-wa-sentinel.service}"; }

# The user manager's unit directory. XDG_CONFIG_HOME is honoured because a session may have moved it, and
# a caller that sets WA_SENTINEL_UNIT_DIR (a fixture, an operator) is asking for that directory by name.
wa_sentinel_unit_dir() {
  if [ -n "${WA_SENTINEL_UNIT_DIR:-}" ]; then printf '%s' "$WA_SENTINEL_UNIT_DIR"; return 0; fi
  printf '%s/systemd/user' "${XDG_CONFIG_HOME:-${HOME:-.}/.config}"
}

wa_sentinel_unit_path() { printf '%s/%s' "$(wa_sentinel_unit_dir)" "$(wa_sentinel_unit_name)"; }

# The value the unit hands its own watcher, in the syntax `role::stated_owner` reads back.
wa_sentinel_unit_supervisor() { printf 'user:%s' "$(wa_sentinel_unit_name)"; }

# The one command an operator runs when the unit exists but no watcher is: it is the manager's verb, not a
# `wa-sentinel start` (which would ask this same manager and is not what an operator types at a shell).
wa_sentinel_unit_restart_command() { printf 'systemctl --user restart %s' "$(wa_sentinel_unit_name)"; }

# Is there a user manager to install into? The same probe bootstrap.sh makes: `systemctl --user` exists
# AND answers. A shell with no session bus (a root cron, an ssh session without a login shell) has the
# binary and no manager, and installing a unit there would write a file nothing reads.
wa_sentinel_unit_manager_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

# wa_sentinel_unit_text <prefix> <env_file> <port> <client_port> <autostart 0|1> <path>
#   The unit's bytes. Pure: prints the text, touches nothing, so a test can diff it against the front
#   door's copy without a systemd anywhere.
wa_sentinel_unit_text() {
  local prefix="$1" env_file="$2" port="$3" client_port="$4" autostart="$5" path_value="$6"
  cat <<UNIT
# Written by wasm-agent (scripts/lib/sentinel-unit.sh and scripts/linux/bootstrap.sh write the same text).
# The sentinel (autostart) starts and supervises wa serve.
[Unit]
Description=wasm-agent sentinel (starts, restarts and upgrades the node from outside)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$prefix/wa-sentinel watch
Restart=always
RestartSec=5
WorkingDirectory=$prefix
EnvironmentFile=-$env_file
Environment=WA_INSTALL_DIR=$prefix
Environment=WA_SENTINEL_AUTOSTART=$autostart
Environment=WA_SENTINEL_SUPERVISOR=$(wa_sentinel_unit_supervisor)
Environment=WA_SENTINEL_SCRIPTS=$prefix/scripts
Environment=WA_SENTINEL_WAKE_BUDGET=6
Environment=WASM_AGENT_PORT=$port
Environment=WASM_AGENT_CLIENT_PORT=$client_port
Environment=PATH=$path_value

[Install]
WantedBy=default.target
UNIT
}

# wa_sentinel_unit_ensure <prefix> <env_file> <port> <client_port> <autostart> <path>
#
# Writes the unit when its bytes differ, asks the manager to reload, and enables it. It does NOT start or
# restart the watcher: that is a lifecycle verb, and the one party that may perform it is `wa-sentinel`
# (which decides from who owns the watcher's role and asks the manager itself). A deploy that restarted
# the unit here would be a second answer to "who owns the watcher".
#
# Prints one line per action on stdout (`unit_written`, `unit_unchanged`, `unit_enabled`), and refuses by
# name on stderr with a non-zero status: `sentinel_unit: no_user_manager` / `unit_write_failed: <path>` /
# `daemon_reload_failed` / `enable_failed`. Every systemctl call goes through WA_SENTINEL_UNIT_SYSTEMCTL
# (default `systemctl`) so a fixture can watch the calls instead of asking a real manager.
wa_sentinel_unit_ensure() {
  local prefix="$1" env_file="$2" port="$3" client_port="$4" autostart="$5" path_value="$6"
  local dir path tmp systemctl_bin="${WA_SENTINEL_UNIT_SYSTEMCTL:-systemctl}" name out
  name="$(wa_sentinel_unit_name)"
  dir="$(wa_sentinel_unit_dir)"
  path="$(wa_sentinel_unit_path)"
  case "$prefix" in
    /*) ;;
    *) printf 'sentinel_unit: prefix_not_absolute: %s\n' "${prefix:-<empty>}" >&2; return 2 ;;
  esac
  if [ ! -x "$prefix/wa-sentinel" ]; then
    printf 'sentinel_unit: no_sentinel_at_prefix: %s/wa-sentinel is not executable, so a unit would start nothing\n' "$prefix" >&2
    return 2
  fi
  if ! command -v "$systemctl_bin" >/dev/null 2>&1; then
    printf 'sentinel_unit: no_user_manager: no %s on PATH\n' "$systemctl_bin" >&2
    return 2
  fi
  if ! "$systemctl_bin" --user show-environment >/dev/null 2>&1; then
    printf 'sentinel_unit: no_user_manager: %s --user has no session to talk to\n' "$systemctl_bin" >&2
    return 2
  fi
  mkdir -p "$dir" 2>/dev/null || { printf 'sentinel_unit: unit_write_failed: %s could not be created\n' "$dir" >&2; return 3; }
  tmp="$path.new.$$"
  if ! wa_sentinel_unit_text "$prefix" "$env_file" "$port" "$client_port" "$autostart" "$path_value" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    printf 'sentinel_unit: unit_write_failed: %s\n' "$tmp" >&2
    return 3
  fi
  if cmp -s "$tmp" "$path"; then
    rm -f "$tmp" 2>/dev/null
    printf 'unit_unchanged\n'
  else
    # Staged beside the destination and renamed, the same rule as every other write in this project: a
    # reader (systemd) either sees the previous unit or the whole new one.
    if ! mv -f "$tmp" "$path" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      printf 'sentinel_unit: unit_write_failed: %s\n' "$path" >&2
      return 3
    fi
    printf 'unit_written\n'
  fi
  if ! out="$("$systemctl_bin" --user daemon-reload 2>&1)"; then
    printf 'sentinel_unit: daemon_reload_failed: %s\n' "$(printf '%s' "$out" | tr '\r\n' '  ')" >&2
    return 4
  fi
  if ! out="$("$systemctl_bin" --user enable "$name" 2>&1)"; then
    printf 'sentinel_unit: enable_failed: %s\n' "$(printf '%s' "$out" | tr '\r\n' '  ')" >&2
    return 4
  fi
  printf 'unit_enabled\n'
}

# Does a UNIT start the node - the system manager's or this user's? That is the question the unit's
# WA_SENTINEL_AUTOSTART answers, and asking only the system directories got it wrong on the laptop, where the
# node is the USER unit wa-serve.service: the sentinel would then also start a node ten seconds after any
# outage, which is a second answer to "who starts this node". WA_SENTINEL_NODE_UNIT names the node's unit
# (default WA_SERVICE_UNIT, else wa-serve.service).
wa_sentinel_node_unit_present() {
  local unit="${WA_SENTINEL_NODE_UNIT:-${WA_SERVICE_UNIT:-wa-serve.service}}"
  local systemctl_bin="${WA_SENTINEL_UNIT_SYSTEMCTL:-systemctl}" state
  if command -v wa_service_unit_file >/dev/null 2>&1 && [ -n "$(wa_service_unit_file 2>/dev/null)" ]; then
    return 0
  fi
  command -v "$systemctl_bin" >/dev/null 2>&1 || return 1
  case "$("$systemctl_bin" --user is-enabled "$unit" 2>/dev/null | head -1)" in
    enabled|enabled-runtime|static|indirect|generated|alias) return 0 ;;
  esac
  [ "$("$systemctl_bin" --user is-active "$unit" 2>/dev/null | head -1)" = active ] && return 0
  return 1
}

# Is there a SYSTEM unit for the watcher already? The unit directories are the ones
# scripts/lib/service-target.sh searches, and the rule is the same; WA_SENTINEL_SYSTEM_UNIT_FILE is this
# function's own seam for a fixture, because WA_SERVICE_UNIT_FILE answers about the NODE's unit and setting it
# must not silently answer this question too.
wa_sentinel_system_unit_file() {
  local name unit
  name="$(wa_sentinel_unit_name)"
  if [ -n "${WA_SENTINEL_SYSTEM_UNIT_FILE:-}" ]; then
    [ -f "$WA_SENTINEL_SYSTEM_UNIT_FILE" ] && printf '%s' "$WA_SENTINEL_SYSTEM_UNIT_FILE"
    return 0
  fi
  for unit in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system \
              /lib/systemd/system /usr/lib/systemd/system; do
    if [ -f "$unit/$name" ]; then printf '%s' "$unit/$name"; return 0; fi
  done
  printf ''
}

# Should this deploy install the unit here? The decisions, in one place, so the deploy's step is a call and
# a note rather than a paragraph of policy. Prints `yes`/`no` and the reason on the second line; the caller
# reports the reason when it is `no`.
#
#   * Windows: never (a logon task or the SCM owns the watcher there; scripts/install-sentinel-service.ps1).
#   * an explicit WA_DEPLOY_SENTINEL_UNIT=0: no, by the operator's own word.
#   * an install outside $HOME: no - a system-wide prefix is run by a system unit, and a `--user` unit
#     pointing at /usr/local/bin would be a second owner for a role the system manager already holds.
#   * a system unit for the watcher that is already there: no - that unit is somebody's, and this deploy
#     must not add a competitor (role.rs: never a second watcher beside the unit's own).
#   * no user manager: no, and the reason names it so the deploy can print the truth instead of a guess.
wa_sentinel_unit_verdict() {
  local prefix="$1" systemctl_bin="${WA_SENTINEL_UNIT_SYSTEMCTL:-systemctl}"
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) printf 'no\nwindows: the watcher is a logon task or the SCM there\n'; return 0 ;;
  esac
  case "${WA_DEPLOY_SENTINEL_UNIT:-1}" in
    0) printf 'no\nWA_DEPLOY_SENTINEL_UNIT=0: the operator asked for no unit\n'; return 0 ;;
    1) ;;
    *) printf 'no\nWA_DEPLOY_SENTINEL_UNIT must be 0 or 1, not %s\n' "$WA_DEPLOY_SENTINEL_UNIT"; return 0 ;;
  esac
  case "$prefix" in
    "${HOME:-/nonexistent}"/*) ;;
    *) printf 'no\nthe install is not under $HOME (%s): a system-wide prefix belongs to a system unit\n' "$prefix"; return 0 ;;
  esac
  if [ -n "$(wa_sentinel_system_unit_file)" ]; then
    printf 'no\na system unit for this watcher is already installed (%s): not adding a second owner\n' \
      "$(wa_sentinel_system_unit_file)"
    return 0
  fi
  if ! command -v "$systemctl_bin" >/dev/null 2>&1; then
    printf 'no\nno %s on PATH: there is no user manager to install a unit into\n' "$systemctl_bin"; return 0
  fi
  if ! "$systemctl_bin" --user show-environment >/dev/null 2>&1; then
    printf 'no\n%s --user has no session to talk to: no user manager to install a unit into\n' "$systemctl_bin"; return 0
  fi
  printf 'yes\n'
}

# wa_sentinel_watcher_prepare <sentinel-binary> <install_dir> <config_dir> <port> <client_port>
#
# A deploy's "no watcher is running" step, as one callable function, so the decision is tested without a
# deploy (scripts/test-sentinel-unit.sh). It installs or refreshes the user unit when this machine should
# have one and prints the facts its caller acts on, one per line:
#
#   supervisor=<the value `wa-sentinel start` must be handed, empty when there is no unit>
#   watcher=<the ONE command that starts the watcher: the unit's manager verb, or the direct start>
#   unit=<yes|no>: <detail>
#
# It never refuses. A machine with no user manager, a system unit that already owns the watcher, or a
# prefix outside $HOME gets `unit=no: <why>` and the direct start command - the deploy then tries the path
# it always had, and its own refusal (fail_installed) names the command the operator needs. A deploy that
# installed the node must not be failed by the absence of a supervisor it was never going to own.
wa_sentinel_watcher_prepare() {
  local sentinel="$1" install_dir="$2" config_dir="$3" port="$4" client_port="$5"
  local verdict first why autostart node_dir out
  verdict="$(wa_sentinel_unit_verdict "$install_dir" 2>/dev/null)"
  first="$(printf '%s\n' "$verdict" | sed -n 1p)"
  why="$(printf '%s\n' "$verdict" | sed -n 2p)"
  if [ "$first" != yes ]; then
    # No unit: no supervisor is claimed on the machine's behalf, and the command is the one the deploy
    # always ran. Exactly one line per key, so a caller reading the last of a key cannot pick the wrong one.
    printf 'supervisor=\n'
    printf 'watcher=%s start\n' "$sentinel"
    printf 'unit=no: %s\n' "${why:-no reason given}"
    return 0
  fi
  # The node's own unit (wa-serve.service on the laptop) already starts the node: a sentinel that also
  # autostarted one would be a second answer to "who starts this node", so the unit says which it is.
  autostart=1
  wa_sentinel_node_unit_present && autostart=0
  node_dir=""
  command -v wa_node_bin >/dev/null 2>&1 && node_dir="$(dirname "$(wa_node_bin 2>/dev/null)" 2>/dev/null)"
  case "$node_dir" in /*) ;; *) node_dir="" ;; esac
  if out="$(wa_sentinel_unit_ensure "$install_dir" "$config_dir/env" "$port" "$client_port" "$autostart" \
        "$install_dir${node_dir:+:$node_dir}:/usr/local/bin:/usr/bin:/bin" 2>&1)"; then
    # The stated fact, spelled by the unit itself: `wa-sentinel start` then asks that unit's manager
    # (role::Step::Manager) instead of guessing an owner from a control group.
    printf 'supervisor=%s\n' "$(wa_sentinel_unit_supervisor)"
    printf 'watcher=%s\n' "$(wa_sentinel_unit_restart_command)"
    printf 'unit=yes: %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"
    return 0
  fi
  printf 'supervisor=\n'
  printf 'watcher=%s start\n' "$sentinel"
  printf 'unit=no: %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"
}
