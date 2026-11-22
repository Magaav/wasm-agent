#!/usr/bin/env bash
# The sentinel's systemd --user unit (scripts/lib/sentinel-unit.sh): the bytes, the decision to install one,
# and the deploy's "no watcher is running" plan.
#
# WHY THIS TEST EXISTS. On 21-22/11 every deploy on the laptop installed the node correctly and then ended
# `failed` with "node installed, but the sentinel would not start": there was no unit outside owning the
# watcher, so `wa-sentinel start` from inside the deploy's own transient unit refused or spawned a child of
# the deploy. The unit is the fix, and it is a FILE: what it says, where it lands, which manager verb starts
# it, and the fact that the front door (scripts/linux/bootstrap.sh) writes the same text are all checkable
# here, with no systemd, no node and no deploy.
#
# SELF-CONTAINED BY CONSTRUCTION: it writes a systemd unit, so it makes its own HOME and XDG_CONFIG_HOME,
# refuses to run without them, and every systemctl call goes to a stub on PATH that records its argv.
#
#   bash scripts/test-sentinel-unit.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/sentinel-unit.sh"
FRONT_DOOR="$ROOT/scripts/linux/bootstrap.sh"
[ -f "$LIB" ] || { echo "test-sentinel-unit: no such file or directory: $LIB (the unit writer this test is about)" >&2; exit 2; }
[ -f "$FRONT_DOOR" ] || { echo "test-sentinel-unit: front_door_missing: $FRONT_DOOR" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-sentinel-unit-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
HOME="$WORK/home"; export HOME
XDG_CONFIG_HOME="$HOME/.config"; export XDG_CONFIG_HOME
mkdir -p "$HOME"
unset WA_SENTINEL_UNIT_DIR WA_SENTINEL_UNIT_NAME WA_DEPLOY_SENTINEL_UNIT WA_SERVICE_UNIT_FILE \
      WA_SENTINEL_SYSTEM_UNIT_FILE STUB_FAIL
case "$XDG_CONFIG_HOME" in
  "$WORK"/*) ;;
  *) echo 'test-sentinel-unit: scratch_home_required: XDG_CONFIG_HOME is not inside this test directory' >&2; exit 2 ;;
 esac
case "$HOME" in
  "$WORK"/*) ;;
  *) echo 'test-sentinel-unit: scratch_home_required: HOME is not inside this test directory' >&2; exit 2 ;;
 esac

fail() { echo "test-sentinel-unit: $*" >&2; exit 1; }
checks=0
check() { checks=$((checks + 1)); }
contains() { # <text> <needle> <label>
  check
  case "$1" in *"$2"*) return 0 ;; esac
  fail "$3: expected to find [$2] in [$1]"
}
absent() { # <text> <needle> <label>
  check
  case "$1" in *"$2"*) fail "$3: did not expect [$2] in [$1]" ;; esac
}
equal() { check; [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }

# The systemctl stub: records every argv and can fail one verb on request.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ -n "${STUB_FAIL:-}" ]; then
  case "$*" in
    *"$STUB_FAIL"*) echo "stub: $STUB_FAIL refused" >&2; exit 1 ;;
  esac
fi
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
STUB_LOG="$WORK/calls.log"; export STUB_LOG
export PATH="$WORK/bin:$PATH"

. "$LIB"
. "$ROOT/scripts/lib/service-target.sh"

PREFIX="$HOME/.local/bin"
mkdir -p "$PREFIX"
printf '#!/bin/sh\nexit 0\n' > "$PREFIX/wa-sentinel"
chmod +x "$PREFIX/wa-sentinel"
CONFIG="$HOME/.wasm-agent"
mkdir -p "$CONFIG"
UNIT_PATH="$PREFIX:$PREFIX/node/bin:/usr/local/bin:/usr/bin:/bin"

# ---- 1. what the unit says ---------------------------------------------------------------------------
text="$(wa_sentinel_unit_text "$PREFIX" "$CONFIG/env" 8799 8800 1 "$UNIT_PATH")"
contains "$text" 'ExecStart='"$PREFIX"'/wa-sentinel watch' 'the unit runs the installed watcher verb'
contains "$text" 'Environment=WA_SENTINEL_SUPERVISOR=user:wa-sentinel.service' 'the supervisor is named the way wa-sentinel asks'
contains "$text" 'Environment=WA_INSTALL_DIR='"$PREFIX" 'the unit names the install it watches'
contains "$text" 'Environment=WA_SENTINEL_SCRIPTS='"$PREFIX"'/scripts' 'run scripts are allowed from the install'
contains "$text" 'Environment=WASM_AGENT_PORT=8799' 'the port is the one this deploy installed on'
contains "$text" 'Environment=WASM_AGENT_CLIENT_PORT=8800' 'the client port likewise'
contains "$text" 'Environment=WASM_AGENT_PORT=8799' 'port'
contains "$text" 'Restart=always' 'a watcher that dies is brought back'
contains "$text" 'WantedBy=default.target' 'the unit is enabled for the user session'
contains "$text" 'EnvironmentFile=-'"$CONFIG"'/env' 'the env file is optional, not a hard requirement'
equal "$(wa_sentinel_unit_supervisor)" 'user:wa-sentinel.service' 'the supervisor spelling'
equal "$(wa_sentinel_unit_restart_command)" 'systemctl --user restart wa-sentinel.service' 'the one command that starts it'
equal "$(wa_sentinel_unit_path)" "$XDG_CONFIG_HOME/systemd/user/wa-sentinel.service" 'the unit lands in the user manager directory'

# ---- 2. the front door writes the same text ----------------------------------------------------------
# bootstrap.sh must keep working from a fetched bundle that carries no scripts/lib, so it keeps its own copy.
# This is what makes that duplication safe: the two texts are compared byte for byte, and a change to one
# that is not made to the other names the line that differs.
front="$(sed -n '/cat > "$unit_dir\/wa-sentinel.service.new" <<UNIT/,/^UNIT$/p' "$FRONT_DOOR" | sed '1d;$d')"
[ -n "$front" ] || fail 'front_door_unit_not_found: bootstrap.sh no longer writes its unit where this test reads it'
front="$(printf '%s\n' "$front" \
  | sed -e "s|\$prefix|$PREFIX|g" -e "s|\$env_file|$CONFIG/env|g" \
        -e "s|\$port|8799|g" -e "s|\$cport|8800|g" -e "s|\$node_dir|$PREFIX/node|g")"
if [ "$front" != "$text" ]; then
  printf '%s\n' "$front" > "$WORK/front.diff"
  printf '%s\n' "$text" > "$WORK/lib.diff"
  fail "front_door_text_differs: $(diff -u "$WORK/front.diff" "$WORK/lib.diff" | sed -n '3,12p' | tr '\n' ' ')"
fi
check

# ---- 3. installing it: written, reloaded, enabled, and unchanged on a second run ----------------------
unit_file="$XDG_CONFIG_HOME/systemd/user/wa-sentinel.service"
: > "$STUB_LOG"
out="$(wa_sentinel_unit_ensure "$PREFIX" "$CONFIG/env" 8799 8800 1 "$UNIT_PATH" 2>&1)" || fail "ensure failed: $out"
contains "$out" 'unit_written' 'a first ensure writes the unit'
contains "$out" 'unit_enabled' 'a first ensure enables the unit'
[ -f "$unit_file" ] || fail "unit_not_written: $unit_file"
check
equal "$(cat "$unit_file")" "$(wa_sentinel_unit_text "$PREFIX" "$CONFIG/env" 8799 8800 1 "$UNIT_PATH")" 'the file on disk is the text the lib renders'
calls="$(cat "$STUB_LOG")"
contains "$calls" '--user daemon-reload' 'the manager is told about the new file'
contains "$calls" '--user enable wa-sentinel.service' 'the unit is enabled, so a reboot keeps the watcher'
absent "$calls" 'restart' 'ensure does not perform a lifecycle verb: starting is wa-sentinel own decision'
: > "$STUB_LOG"
out="$(wa_sentinel_unit_ensure "$PREFIX" "$CONFIG/env" 8799 8800 1 "$UNIT_PATH" 2>&1)" || fail "second ensure failed: $out"
contains "$out" 'unit_unchanged' 'the same bytes are not rewritten'

# ---- 4. the refusals, each by name --------------------------------------------------------------------
out="$(wa_sentinel_unit_ensure "/opt/not-a-prefix" "$CONFIG/env" 8799 8800 1 "$UNIT_PATH" 2>&1)" && fail 'a prefix with no sentinel was accepted'
contains "$out" 'no_sentinel_at_prefix' 'a unit that would start nothing is refused by name'
out="$(wa_sentinel_unit_ensure relative/prefix "$CONFIG/env" 8799 8800 1 "$UNIT_PATH" 2>&1)" && fail 'a relative prefix was accepted'
contains "$out" 'prefix_not_absolute' 'a relative prefix is refused'
export STUB_FAIL=show-environment
out="$(wa_sentinel_unit_ensure "$PREFIX" "$CONFIG/env" 8799 8800 1 "$UNIT_PATH" 2>&1)" && fail 'a machine with no user manager was accepted'
contains "$out" 'no_user_manager' 'no session bus is refused by name, not guessed past'
export STUB_FAIL=daemon-reload
out="$(wa_sentinel_unit_ensure "$PREFIX" "$CONFIG/env" 8799 8800 1 "$UNIT_PATH" 2>&1)" && fail 'a refused daemon-reload was reported as success'
contains "$out" 'daemon_reload_failed' 'a manager that refuses the reload is reported'
unset STUB_FAIL

# ---- 5. the decision: when this machine should get a unit, and why not ---------------------------------
verdict="$(wa_sentinel_unit_verdict "$PREFIX")"
equal "$(printf '%s\n' "$verdict" | sed -n 1p)" 'yes' 'a user-local install with a user manager gets a unit'
WA_DEPLOY_SENTINEL_UNIT=0
verdict="$(wa_sentinel_unit_verdict "$PREFIX")"
equal "$(printf '%s\n' "$verdict" | sed -n 1p)" 'no' 'the operator can refuse the unit'
contains "$verdict" 'WA_DEPLOY_SENTINEL_UNIT=0' 'and the reason is the operator own word'
WA_DEPLOY_SENTINEL_UNIT=2
verdict="$(wa_sentinel_unit_verdict "$PREFIX")"
equal "$(printf '%s\n' "$verdict" | sed -n 1p)" 'no' 'an invalid knob is not a yes'
contains "$verdict" 'must be 0 or 1' 'an invalid knob is refused by name'
WA_DEPLOY_SENTINEL_UNIT=1
verdict="$(wa_sentinel_unit_verdict /opt/elsewhere)"
equal "$(printf '%s\n' "$verdict" | sed -n 1p)" 'no' 'a system-wide prefix does not get a --user unit'
contains "$verdict" 'not under' 'and the reason names the prefix rule'
printf '[Service]\n' > "$WORK/system-wa-sentinel.service"
WA_SENTINEL_SYSTEM_UNIT_FILE="$WORK/system-wa-sentinel.service"
verdict="$(wa_sentinel_unit_verdict "$PREFIX")"
equal "$(printf '%s\n' "$verdict" | sed -n 1p)" 'no' 'a system unit for the watcher is not competed with'
contains "$verdict" 'not adding a second owner' 'and the reason says why'
WA_SENTINEL_SYSTEM_UNIT_FILE="$WORK/absent.service"
# No systemctl anywhere: the verdict must say so instead of installing a unit nothing reads.
mkdir -p "$WORK/minbin"
for tool in sed tr dirname uname cat cmp mv mkdir rm; do
  [ -n "$(command -v "$tool" 2>/dev/null)" ] && ln -sf "$(command -v "$tool")" "$WORK/minbin/$tool"
done
verdict="$(PATH="$WORK/minbin" wa_sentinel_unit_verdict "$PREFIX")"
equal "$(printf '%s\n' "$verdict" | sed -n 1p)" 'no' 'a machine with no systemctl gets no unit'
contains "$verdict" 'no systemctl on PATH' 'and the reason names the missing tool'

# ---- 6. the deploy plan: which command starts the watcher, and which supervisor is handed down ---------
plan="$(wa_sentinel_watcher_prepare "$PREFIX/wa-sentinel" "$PREFIX" "$CONFIG" 8799 8800)"
equal "$(printf '%s\n' "$plan" | sed -n 's/^supervisor=//p' | tail -1)" 'user:wa-sentinel.service' \
  'the deploy hands the unit own supervisor to wa-sentinel start'
equal "$(printf '%s\n' "$plan" | sed -n 's/^watcher=//p' | tail -1)" 'systemctl --user restart wa-sentinel.service' \
  'the one command is the manager verb'
contains "$(printf '%s\n' "$plan" | sed -n 's/^unit=//p' | tail -1)" 'yes:' 'the plan says a unit was installed'
# ...and the node own unit, where there is one, is not duplicated by an autostarting sentinel.
printf '[Service]\n' > "$WORK/wa-serve.service"
WA_SERVICE_UNIT_FILE="$WORK/wa-serve.service"
plan="$(wa_sentinel_watcher_prepare "$PREFIX/wa-sentinel" "$PREFIX" "$CONFIG" 8799 8800)"
contains "$(cat "$unit_file")" 'Environment=WA_SENTINEL_AUTOSTART=0' \
  'a machine whose node has its own unit gets a watcher that does not start a second one'
# ...and a machine that must not have a unit keeps the command it always had, with no supervisor claimed.
WA_DEPLOY_SENTINEL_UNIT=0
plan="$(wa_sentinel_watcher_prepare "$PREFIX/wa-sentinel" "$PREFIX" "$CONFIG" 8799 8800)"
equal "$(printf '%s\n' "$plan" | sed -n 's/^supervisor=//p' | tail -1)" '' \
  'with no unit, no supervisor is claimed on the machine behalf'
equal "$(printf '%s\n' "$plan" | sed -n 's/^watcher=//p' | tail -1)" "$PREFIX/wa-sentinel start" \
  'with no unit, the command is the one the deploy always ran'
contains "$(printf '%s\n' "$plan" | sed -n 's/^unit=//p' | tail -1)" 'no:' 'and the plan says so'

printf 'sentinel unit ok (%s checks)\n' "$checks"
