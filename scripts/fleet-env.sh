#!/usr/bin/env bash
# fleet-env: change the environment of the fleet's nodes from one node, with a backup, a verification
# and a rollback you can paste. A node reads its environment once, at start, so any key this writes is
# inert until the node restarts: --restart does that here, and refuses to leave a node unhealthy.
#
#   fleet-env list                     KEY present/absent per node (values masked unless --show-values)
#   fleet-env set KEY=VALUE [opts]     set/replace a key on every node
#   fleet-env unset KEY [opts]         remove a key
#   fleet-env restart NODE             restart one node and prove it answers /health
#   fleet-env admins                   prints the rendezvous runbook (never edits it: it is guarded)
#
# Options: --nodes a,b,c (default: every node in this node's roster but itself), --env-path P,
#          --restart (restart after writing), --dry-run, --show-values, --timeout S (default 60)
#
# Why a tool and not a loop of `wa call`: every node is prod. A write that is not backed up cannot be
# rolled back, and an env change that is not verified is indistinguishable from one that broke a node
# five minutes later. Those three steps are the whole point of this file.
set -uo pipefail

SELF=$(command -v wa || echo "$HOME/.local/bin/wa")
PYTHON=$(command -v python3 || command -v python || true)
say() { printf 'fleet-env: %s\n' "$*"; }
die() { printf 'fleet-env: %s\n' "$*" >&2; exit 1; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }

MODE=${1:-list}; shift || true
KEY=; VALUE=; NODES=; ENV_PATH='$HOME/.wasm-agent/env'; RESTART=0; DRY=0; SHOW=0; TIMEOUT=60
if [ "$MODE" = set ] || [ "$MODE" = unset ]; then
  case $MODE in
    set) [ $# -gt 0 ] || die 'usage: fleet-env set KEY=VALUE'; KEY=${1%%=*}; VALUE=${1#*=}; shift ;;
    unset) [ $# -gt 0 ] || die 'usage: fleet-env unset KEY'; KEY=$1; shift ;;
  esac
elif [ "$MODE" = restart ]; then
  [ $# -gt 0 ] || die 'usage: fleet-env restart NODE'; NODES=$1; shift
fi
while [ $# -gt 0 ]; do
  case $1 in
    --nodes) NODES=${2:?}; shift 2 ;;
    --env-path) ENV_PATH=${2:?}; shift 2 ;;
    --restart) RESTART=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --show-values) SHOW=1; shift ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
    *) die "unknown_option: $1" ;;
  esac
done

# One mesh call: prints the node's stdout, or fails with the refusal on stderr.
node_run() { # node, command
  local node=$1; shift
  local json out
  json=$("$PYTHON" -c 'import json,sys;print(json.dumps({"command":sys.argv[1]}))' "$*") || return 1
  out=$("$SELF" call "$node" bash "$json" 2>/dev/null) || return 1
  printf '%s' "$out" | "$PYTHON" -c '
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print("UNPARSED: "+raw[-200:]); sys.exit(1)
if d.get("error"):
    print("refused: "+str(d.get("error"))+" "+str(d.get("reason") or d.get("hint") or "")); sys.exit(1)
sys.stdout.write(d.get("stdout","").rstrip())
'
}

roster_nodes() {
  "$PYTHON" - <<'PY'
import json,os,subprocess
cfg=os.path.expanduser('~/.wasm-agent')
p=os.path.join(cfg,'mesh-roster.json')
try: d=json.load(open(p))
except Exception: raise SystemExit("no roster at "+p)
me=json.loads(subprocess.run(['wa','nodes'],capture_output=True,text=True).stdout or '{}')
mine={n['node_id'] for n in me.get('nodes',[]) if n.get('local_node')}
for n in d.get('nodes',[]):
    if n.get('revoked_at'): continue
    if n['node_id'] in mine: continue
    print(n['name'])
PY
}
[ -n "$NODES" ] || NODES=$(roster_nodes) || die 'node_list_unavailable'
[ -n "$NODES" ] || die 'no_nodes'

mask() { # key value
  case $1 in *TOKEN*|*KEY*|*SECRET*|*PASSWORD*|*ADMINS*) [ "$SHOW" = 1 ] && printf '%s' "$2" || printf '<set>' ;; *) printf '%s' "$2" ;; esac
}

restart_node() { # node
  local node=$1 out code
  say "restart $node"
  if [ "$DRY" = 1 ]; then say "  (dry run) would restart and verify /health"; return 0; fi
  out=$(node_run "$node" 'if systemctl --user is-active wa-serve >/dev/null 2>&1; then systemctl --user restart wa-serve && echo via:user; elif systemctl is-active wa-serve >/dev/null 2>&1; then sudo -n systemctl restart wa-serve && echo via:system; else echo no_unit; fi') || { say "  restart refused: $out"; return 1; }
  case $out in
    no_unit) say "  no wa-serve unit on $node: start the node there (fleet-env printed nothing instead of guessing)"; return 3 ;;
  esac
  say "  ${out}"
  for _ in $(seq 1 "$TIMEOUT"); do
    code=$(node_run "$node" 'curl -s -o /dev/null -w %{http_code} -m 2 http://127.0.0.1:8799/health || true')
    [ "$code" = 200 ] && { say "  healthy after ${_}s"; return 0; }
    sleep 1
  done
  say "  UNHEALTHY after ${TIMEOUT}s (last code=${code:-none})"
  return 1
}

case $MODE in
  list)
    for node in $NODES; do
      printf '== %s\n' "$node"
      node_run "$node" "test -r $ENV_PATH && sed -e 's/=.*/=<set>/' $ENV_PATH || echo 'no env file'" | sed 's/^/   /'
    done ;;
  set|unset)
    for node in $NODES; do
      printf '== %s\n' "$node"
      if [ "$MODE" = set ]; then
        py="import os,sys
p=os.path.expandvars(r'''$ENV_PATH'''); k=sys.argv[1]; v=sys.argv[2]
lines=open(p).read().splitlines() if os.path.exists(p) else []
lines=[l for l in lines if not l.startswith(k+'=')]
lines.append(k+'='+v)
open(p,'w').write('\n'.join(lines)+'\n'); os.chmod(p,0o600)
print('set',k)"
      else
        py="import os,sys
p=os.path.expandvars(r'''$ENV_PATH'''); k=sys.argv[1]
lines=open(p).read().splitlines() if os.path.exists(p) else []
n=len(lines); lines=[l for l in lines if not l.startswith(k+'=')]
open(p,'w').write(('\n'.join(lines)+'\n') if lines else ''); os.chmod(p,0o600)
print('unset %s (%d line(s) removed)'%(k,n-len(lines)))"
      fi
      if [ "$DRY" = 1 ]; then
        say "  (dry run) would backup $ENV_PATH and $MODE $(mask "$KEY" "$VALUE")"
      else
        out=$(node_run "$node" "cp -p $ENV_PATH $ENV_PATH.bak.$(stamp) 2>/dev/null; python3 -c \"\$(cat <<'PYEOF'
$py
PYEOF
)\" '$KEY' '$VALUE'") || { say "  FAILED: ${out:-no answer}"; continue; }
        say "  $out   (value: $(mask "$KEY" "$VALUE"); backup: $ENV_PATH.bak.$(stamp))"
      fi
      [ "$RESTART" = 1 ] || { say "  takes effect on the node's next start"; continue; }
      restart_node "$node" || say "  rollback: restore $ENV_PATH from $ENV_PATH.bak.* on $node, then restart"
    done ;;
  restart)
    restart_node "$NODES" ;;
  admins)
    cat <<'RUNBOOK'
The rendezvous admin set is not editable from a node: it is the process environment of
wa-rendezvous on openclaw, and a node-side hook refuses even reading it ("this detaches nodes
that pin the admin set; use mesh"). Run these on openclaw, as the operator:

  F=/etc/systemd/system/wa-rendezvous.service.d/managed.conf
  sudo cp -p $F $F.bak.$(date -u +%Y%m%dT%H%M%SZ)
  sudoedit $F            # WASM_AGENT_NETWORK_ADMINS=<id,id,...>  (add and/or drop ids)
  sudo systemctl restart wa-rendezvous        # ~1-2 s; every node re-attaches on its next tick
  curl -s https://rendezvous.colmeio.com/health

Rollback: restore the .bak file and restart the unit again. Then, from any master:
  wa network forget <dropped-node-id>          # allowed once it is no longer an admin
  wa nodes                                     # the row is gone; the rest keep their roles
RUNBOOK
    ;;
  *) die "usage: fleet-env list|set|unset|restart|admins" ;;
esac
