#!/usr/bin/env bash
# THE TWO DOORS A SCRATCH RUN CAN OPEN ONTO THE LIVE INSTALL (factory-small-items item 4, 25/11).
#
# THE DEFECT, found by the gba worker on 25/11. A deploy run inside a scratch environment is supposed to see the
# scratch node only, and two lines let it see the operator's:
#
#   1. scripts/lib/service-target.sh asked `systemctl show <unit> -p ExecStart` with a PLAIN `systemctl`, while
#      every other caller in this tree goes through `WA_SENTINEL_UNIT_SYSTEMCTL` (sentinel-unit.sh,
#      install-isolation.sh) - so the probe answered the LIVE unit and the deploy reported the operator's install
#      as "the service runs";
#   2. scripts/deploy.sh read `WA_PORT`/`WA_CLIENT_PORT`, while the node's own spelling is `WASM_AGENT_PORT`
#      (what rust/wa-sentinel reads and scripts/lib/sentinel-unit.sh writes). A runner exporting only the node's
#      spelling left the deploy on the historical 8799 - the LIVE node.
#
# What this row holds, on the real files and the real scripts:
#   A. the systemctl door: service-target.sh asks the systemctl it was given, for ExecStart AND MainPID;
#   B. the port door: the port helpers honour both spellings, WA_PORT first;
#   C. the deploy's own refusal names the SCRATCH install and the SCRATCH port when only the node's variables are
#      set - never the operator's unit, never 8799.
#
#   bash scripts/test-installer-doors.sh
#
# Scratch only: its own HOME, data and install directories, and scripts/lib/scratch-home.sh refuses the operator's
# node home. Nothing is built and nothing is installed: both deploy runs stop at the first precondition (a missing
# install directory) before any write, and the listener this row starts is its own child, stopped and waited for
# before the row returns.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
. "$ROOT/scripts/lib/scratch-home.sh"
if [ -n "${WA_ROW_SCRATCH_ROOT:-}" ]; then WORK="$WA_ROW_SCRATCH_ROOT/row-installer-doors"; else WORK="$(TMPDIR=/tmp mktemp -d /tmp/wa-installer-doors.XXXXXX)"; fi
mkdir -p "$WORK/home" "$WORK/data" "$WORK/bin" "$WORK/unit-install" "$WORK/listen" || exit 1
wa_scratch_home_guard "$WORK/home" || { echo 'installer-doors REFUSED: the scratch home is the operator node home' >&2; exit 2; }
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home" WASM_AGENT_DATA="$WORK/data"
export WA_SENTINEL_UNIT_DIR="$WORK/units"
mkdir -p "$WA_SENTINEL_UNIT_DIR"

HOLD=""
cleanup() {
  if [ -n "$HOLD" ]; then kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

checks=0
ok() { checks=$((checks + 1)); }
bad() { echo "installer-doors FAILED: $*" >&2; exit 1; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3: '$2' is not in: $(printf '%s' "$1" | head -c 400)" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3: '$2' IS in: $(printf '%s' "$1" | head -c 400)" ;; *) ok ;; esac; }

# THE SHIM IS THE ONE VARIABLE THIS TREE ALREADY USES, and it answers with a scratch install - not with "nothing",
# because the row has to see WHICH install a caller resolved.
DUMP="$WORK/bin/systemctl-dump"
cat > "$DUMP" <<'SHIM'
#!/bin/sh
case "$*" in
  *"-p ExecStart"*) printf '{ path=%s ; argv[]=%s serve ; ignore_errors=no ; pid=0 ; status=0/0 }\n' "$WA_SHIM_BIN" "$WA_SHIM_BIN" ;;
  *"-p MainPID"*) printf '4242\n' ;;
  *) exit 1 ;;
esac
SHIM
NONE="$WORK/bin/systemctl-none"
printf '#!/bin/sh\nexit 1\n' > "$NONE"
chmod +x "$DUMP" "$NONE"
export WA_SHIM_BIN="$WORK/unit-install/wa"
printf 'x' > "$WA_SHIM_BIN"; chmod +x "$WA_SHIM_BIN"

# ---- A. THE SYSTEMCTL DOOR ----------------------------------------------------------------------
. "$ROOT/scripts/lib/service-target.sh"
command -v wa_node_port >/dev/null 2>&1 || bad 'scripts/lib/service-target.sh defines no wa_node_port, so a deploy cannot honour WASM_AGENT_PORT'
ok
EXEC="$(WA_SENTINEL_UNIT_SYSTEMCTL="$DUMP" wa_service_exec_start wa-serve.service)"
has "$EXEC" "$WA_SHIM_BIN" 'the ExecStart probe asks the systemctl it was given, not the machine own'
CLAIM="$(WA_SENTINEL_UNIT_SYSTEMCTL="$DUMP" wa_service_install_dir wa-serve.service)"
has "$CLAIM" "$WORK/unit-install" 'so the install it resolves is the scratch one'
has "$CLAIM" "runs $WA_SHIM_BIN" 'naming the binary that systemctl reported'
PID="$(WA_SENTINEL_UNIT_SYSTEMCTL="$DUMP" wa_service_pid wa-serve.service)"
[ "$PID" = "4242" ] || bad "the MainPID probe did not ask the given systemctl (got '$PID')"
ok

# ---- B. THE PORT DOOR ---------------------------------------------------------------------------
# ALL FOUR PORT VARIABLES ARE CLEARED, THEN THE CASE'S OWN ARE NAMED (measured in the orchestrator's runner, row
# 20261125T222843Z-13846): the runner exports WA_PORT, WASM_AGENT_PORT and WASM_AGENT_CLIENT_PORT, the row inherits
# them, and a check that names only one of them reads another and reports the fallback as broken. Each case therefore
# starts from nothing and states exactly what it is about - the same isolation the deploy itself gets in part C.
port_case() { # <function> <expected> <description> [NAME=value ...]
  local fn=$1 want=$2 what=$3 got kv
  shift 3
  got=$( set -u
    unset WA_PORT WA_CLIENT_PORT WASM_AGENT_PORT WASM_AGENT_CLIENT_PORT
    for kv in "$@"; do export "$kv"; done
    "$fn"
  )
  [ "$got" = "$want" ] || bad "$what (got '$got', wanted '$want')"
  ok
}
port_case wa_node_port 19799 'wa_node_port honours WASM_AGENT_PORT, the spelling the node itself reads' \
  WASM_AGENT_PORT=19799 WASM_AGENT_CLIENT_PORT=19800
port_case wa_node_client_port 19800 'wa_node_client_port honours WASM_AGENT_CLIENT_PORT' \
  WASM_AGENT_PORT=19799 WASM_AGENT_CLIENT_PORT=19800
port_case wa_node_port 18001 'an explicit WA_PORT outranks WASM_AGENT_PORT' \
  WA_PORT=18001 WASM_AGENT_PORT=19799
port_case wa_node_client_port 19800 'with no client port named, the client port follows the node port' \
  WASM_AGENT_PORT=19799
port_case wa_node_port 8799 'with nothing named, the historical 8799 is still the answer'

# ---- C. THE DEPLOY ITSELF, AS A SCRATCH RUN SEES IT --------------------------------------------
# The refusal at deploy.sh's first precondition names the install it resolved AND the source of that answer. Both
# doors are visible in its one line, and nothing is written: the install directory named here does not exist.
DEPLOY="$ROOT/scripts/deploy.sh"
# THE SAME ISOLATION AS PART B, for the deploy process: the four port variables are cleared and only the ones the case
# names are exported, because a runner exports all of them and the deploy would then read the runner's port instead of
# the one this row is proving (measured in row 20261125T222843Z-13846). `env` cannot call a shell function, so the
# clearing is a subshell - that was the second mistake this row made on its way to the runner.
deploy_out() { # [NAME=value ...] -> the deploy's output, port variables as named and nothing else
  local kv
  ( set -u
    unset WA_PORT WA_CLIENT_PORT WASM_AGENT_PORT WASM_AGENT_CLIENT_PORT
    for kv in "$@"; do export "$kv"; done
    timeout 20 bash "$DEPLOY" 2>&1 )
}
OUT="$(deploy_out WA_INSTALL_DIR="$WORK/nope" WA_SENTINEL_UNIT_SYSTEMCTL="$DUMP" WASM_AGENT_PORT=19799 WASM_AGENT_CLIENT_PORT=19800)"
has "$OUT" 'refused(install_dir_missing)' 'the scratch deploy stops at its first precondition'
has "$OUT" "$WORK/unit-install" 'naming the SCRATCH install its unit claims'
hasnt "$OUT" ':8799' 'and never the live node port'

# AND THE PORT DOOR THROUGH THE DEPLOY: no unit answers, so the claim falls to whoever holds the port - and with
# only the node spelling set that must be this row's own listener, never 8799.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
[ -n "$PORT" ] || bad 'could not take a free port for the scratch listener'
python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',$PORT));s.listen(1);time.sleep(60)" &
HOLD=$!
sleep 1
OUT="$(deploy_out WA_INSTALL_DIR="$WORK/nope" WA_SENTINEL_UNIT_SYSTEMCTL="$NONE" WASM_AGENT_PORT="$PORT" WASM_AGENT_CLIENT_PORT="$((PORT + 1))")"
has "$OUT" "on port $PORT" 'the deploy asked for the port the node own spelling named'
hasnt "$OUT" ':8799' 'and never the live node port'
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""

echo "installer doors ok ($checks checks): a scratch run reads its own unit and its own port, never the operator's"

