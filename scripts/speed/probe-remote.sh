#!/usr/bin/env bash
# REMOTE ROUND TRIP: one signed peer call, end to end, between two SCRATCH nodes on this machine.
#
#   bash scripts/speed/probe-remote.sh --bin <wa> --root <tree> [--samples 5]
#
# The route is the shipped one, unchanged: caller (lua/core/nodes.lua) -> rendezvous -> the peer's serve
# loop -> the answer back. Three processes, two node identities, one loopback: nothing here is a stub, and
# nothing here is the fleet (rule 13 - a scratch home and a local rendezvous, never a live peer).
#
# WHY IT IS A ROW. The fabric is how this machine does its work, and every remote call pays whatever this
# route costs. It is also the row most likely to rot unnoticed, because no keypress goes through it.
#
# WHAT IS MEASURED. 'wa call <peer> bash {"command":"printf ok"}': the caller process itself, its identity,
# the signed envelope, the relay, the peer's serve thread and the answer. The caller process is INCLUDED on
# purpose: that is one remote round trip as this node performs it.
#
# BOTH NODES RUN 'serve', AND THAT IS NOT PADDING. Measured 23/11 on 8862b600: with only the peer serving,
# every call answered roster_unavailable - the rendezvous answers GET /nodes only to a node it can VERIFY,
# and it learns a node's key when that node registers. So a caller that never serves cannot be looked at,
# let alone call anybody. The measured process is still a short-lived CLI; the serve is what makes its
# signature verifiable.
#
# One warm-up call is discarded (the first call pays for the peer's admission of this caller), then one
# 'sample <n> <ms>' line per measured call; the median is the harness's (scripts/lib/speed-stats.lua).
#
# Everything this script starts is stopped by the PID it recorded, never by a name pattern (rule 17), and a
# fixture that cannot come up REFUSES with the reason and the caller's own words instead of printing a
# number it cannot stand behind (rule 1).
set -uo pipefail
bin=""; root=""; samples=5
while [ $# -gt 0 ]; do
  case "$1" in
    --bin) bin=${2:?}; shift 2 ;;
    --root) root=${2:?}; shift 2 ;;
    --samples) samples=${2:?}; shift 2 ;;
    *) echo "unavailable: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$bin" ] && [ -x "$bin" ] || { echo "unavailable: no runnable binary at ${bin:-<empty>}" >&2; exit 2; }
[ -n "$root" ] && [ -d "$root" ] || { echo "unavailable: --root is not a directory" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "unavailable: python3 is not on PATH (a free port and a millisecond clock need it)" >&2; exit 2; }
real="${HOME:-}/.wasm-agent"
work=$(mktemp -d /tmp/speed-remote-XXXXXX) || { echo "unavailable: no scratch directory" >&2; exit 2; }
case "$work" in "$real"*) rm -rf "$work"; echo "unavailable: the scratch directory is inside the operator's own home" >&2; exit 2 ;; esac
rendezvous_pid=""; peer_pid=""; caller_pid=""
cleanup() {
  local pid
  for pid in "$caller_pid" "$peer_pid" "$rendezvous_pid"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  rm -rf "$work"
}
trap cleanup EXIT

pick() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
rv=$(pick); port_a=$(pick); port_b=$(pick); client_a=$(pick); client_b=$(pick)
mkdir -p "$work/home-a" "$work/home-b" "$work/home-rv" "$work/a" "$work/peer"

identity() { # identity <home>
  env -i PATH="$PATH" HOME="$1" WASM_AGENT_HOME="$1" WASM_AGENT_MANAGED=0 WASM_AGENT_LUA_ROOT="$root" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WA_SCRIPT="$root/scripts/speed/fixture-identity.lua" \
    "$bin" --db "$work/$(basename "$1").db" 2>/dev/null | grep -o '"node_id":"[^"]*"' | head -1 | cut -d'"' -f4
}
id_a=$(identity "$work/home-a"); id_b=$(identity "$work/home-b")
[ -n "$id_a" ] && [ -n "$id_b" ] && [ "$id_a" != "$id_b" ] || {
  echo "unavailable: the two scratch homes did not give two node identities (${id_a:-none} / ${id_b:-none})" >&2; exit 2; }

env -i PATH="$PATH" HOME="$work/home-rv" WASM_AGENT_HOME="$work/home-rv" WASM_AGENT_MANAGED=0 \
  WASM_AGENT_NETWORK_ADMINS="$id_a,$id_b" \
  "$bin" --db "$work/rv.db" rendezvous --port "$rv" --bind 127.0.0.1 > "$work/rendezvous.log" 2>&1 &
rendezvous_pid=$!
up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for _ in $(seq 1 150); do up "$rv" && break; sleep 0.2; done
up "$rv" || { echo "unavailable: the rendezvous never listened on :$rv ($(tail -2 "$work/rendezvous.log" | tr '\n' ' '))" >&2; exit 2; }

serve_node() { # serve_node <work subdir> <home> <port> <client-port> <log>
  ( cd "$work/$1" && exec env -i PATH="$PATH" HOME="$2" WASM_AGENT_HOME="$2" WASM_AGENT_MANAGED=0 \
      WASM_AGENT_LUA_ROOT="$root" WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$rv" WASM_AGENT_RELAY= \
      WASM_AGENT_ENDPOINT="127.0.0.1:$3" \
      "$bin" --db "$2.db" serve --port "$3" --client-port "$4" --ui "$root/ui" > "$5" 2>&1 ) &
  echo $!
}
peer_pid=$(serve_node peer "$work/home-b" "$port_b" "$client_b" "$work/peer.log")
caller_pid=$(serve_node a "$work/home-a" "$port_a" "$client_a" "$work/caller.log")
sleep 1

caller() { # caller <node> <capability> <json>
  ( cd "$work/a" && env -i PATH="$PATH" HOME="$work/home-a" WASM_AGENT_HOME="$work/home-a" WASM_AGENT_MANAGED=0 \
      WASM_AGENT_LUA_ROOT="$root" WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$rv" WASM_AGENT_RELAY= \
      WASM_AGENT_ENDPOINT="127.0.0.1:$port_a" "$bin" --db "$work/home-a.db" call "$1" "$2" "$3" 2>&1 )
}
seen=0; last=""
for _ in $(seq 1 240); do
  last=$(caller peer bash '{"command":"printf ok"}')
  case "$last" in *'"ok":true'*) seen=1; break ;; esac
  sleep 0.5
done
[ "$seen" = 1 ] || {
  echo "unavailable: the scratch peer never answered a call in 120 s; the caller said: ${last:0:300} (peer log: $(tail -3 "$work/peer.log" | tr '\n' ' '))" >&2
  exit 2; }

# The warm-up: its number is discarded, its failure is not.
caller peer bash '{"command":"printf ok"}' >/dev/null || { echo "unavailable: the warm-up call failed" >&2; exit 2; }
values=()
for index in $(seq 1 "$samples"); do
  begin=${EPOCHREALTIME/./}
  answer=$(caller peer bash '{"command":"printf ok"}')
  end=${EPOCHREALTIME/./}
  case "$answer" in *'"ok":true'*) ;; *) echo "unavailable: sample $index failed: ${answer:0:160}" >&2; exit 2 ;; esac
  ms=$(( (end - begin) / 1000 ))
  echo "sample $index $ms"
  values+=("$ms")
done
[ "${#values[@]}" -ge 3 ] || { echo "unavailable: only ${#values[@]} sample(s) - three are the least a median can stand on" >&2; exit 2; }
