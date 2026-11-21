#!/usr/bin/env bash
# A line typed while a script runs is QUEUED, and the script finishes as if nothing had been typed
# (21/11; docs/HOST.md, "A line typed during a run: queued or now").
#
# End to end, through a real `wa chat` and a real (stub) model on loopback, because the claim is about
# the whole route: the reader thread takes the line, the REPL does not read stdin during a run, the
# script that is running is not interrupted, and the line reaches the model right after it.
#
# The evidence is the marker file the script appends to and the stub's own record of the prompts:
#   * two lines  -> every planned call of the script executed;
#   * a later prompt containing the typed line -> it was delivered, and delivered after the script.
#
# THIS ROW CANNOT FAIL ON 93168d96 FOR THE QUEUED HALF, and that is deliberate: plain Enter already was
# queued in this tree (no submitted line raised the run's interrupt - agent.lua drains the reader only
# at a model round boundary), so what it protects is the ROUTE, end to end, against a future change that
# makes a typed line end a script. What is new and therefore discriminating is that a line carries a
# kind at all, held by scripts/test-cli-input.lua (the real host answers `now`) and by the two Rust unit
# rows, and the wake on settlement, held by scripts/test-handle-wake*.lua.
#
#   bash scripts/test-cli-queued.sh            (WA_BIN names the binary; defaults to the tree's)
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${WA_BIN:-$root/rust/target/release/wa}
[ -x "$bin" ] || { echo "cli queued SKIP: no binary at $bin (set WA_BIN)"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/wa-queued.XXXXXX") || { echo "cli queued FAIL: no scratch dir"; exit 1; }
mock=""
cleanup() {
  [ -n "$mock" ] && kill "$mock" 2>/dev/null
  wait 2>/dev/null || true
}
trap cleanup EXIT

port=$(node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
mkdir -p "$work/home"
marker="$work/marker.txt"
: > "$marker"
WA_QUEUED_MARKER="$marker" node "$root/scripts/mock-provider-queued.cjs" "$port" > "$work/mock.log" 2>&1 &
mock=$!
ready=0
for _ in $(seq 1 60); do
  if curl -fsS -m 1 "http://127.0.0.1:$port/calls" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "cli queued FAIL: the stub model did not start: $(tail -3 "$work/mock.log")"; exit 1; }

# The first line asks for the script; the second is typed three seconds in, while the script is
# sleeping, which is the only arrangement that tells a queued line from a read between turns.
# A HERMETIC ENVIRONMENT, not this shell's: the node exports its own provider and vault (a real
# credential lane), and inheriting them here sent the request to a real endpoint instead of the stub
# (measured: provider_http_400 "Model stub-model isn't included in OpenCode Go"). `env -i` keeps the
# four variables this row means and nothing else.
( printf 'run the script\n'; sleep 3; printf 'hi there\n'; sleep 20 ) \
  | env -i PATH="$PATH" TERM="${TERM:-xterm-256color}" TMPDIR="${TMPDIR:-/tmp}" \
      HOME="$work/home" WASM_AGENT_HOME="$work/home" WASM_AGENT_LUA_ROOT="$root" \
      WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$port" WASM_AGENT_LLM_API_KEY=test-only \
      WASM_AGENT_LLM_MODEL=stub-model WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= \
      "$bin" --db "$work/t.db" chat > "$work/chat.log" 2>&1
status=$?

calls=$(curl -fsS -m 2 "http://127.0.0.1:$port/calls" 2>/dev/null || echo '{}')
lines=$(wc -l < "$marker" | tr -d ' ')
count=$(printf '%s' "$calls" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).count||0)}catch{console.log(0)}})')
delivered=$(printf '%s' "$calls" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s).prompts||[];console.log(p.some(t=>String(t).includes("hi there"))?1:0)}catch{console.log(0)}})')

echo "cli queued: chat exit=$status, script calls=$lines, model calls=$count, line delivered=$delivered"
if [ "$lines" = "2" ] && [ "$count" -ge 2 ] && [ "$delivered" = "1" ]; then
  echo "cli queued ok (the script ran every call, and the line typed during it reached the model after it)"
else
  echo "cli queued FAIL: marker=$lines (want 2), model calls=$count (want >=2), delivered=$delivered (want 1)"
  echo "  chat log: $(tail -6 "$work/chat.log" | tr '\n' '|')"
  echo "  prompts: $(printf '%s' "$calls" | cut -c1-400)"
  exit 1
fi

# ---- Ctrl+Enter (NOW) is NOT covered here, and the reason is measured.
# The chord needs a terminal that reports it (the kitty keyboard protocol's CSI 13;5u) and an editor that
# parses it. This harness (`script -qec`, a pty with a size set by `stty`) produced a chat whose run
# COMPLETED with the whole line delivered as text - the marker had both of the script's calls and the
# footer said `2 rounds`, i.e. the bytes arrived as a line and never as a send-now key (measured
# 21/11). A phase that cannot tell the two apart cannot hold the rule, so it is not shipped: Ctrl+Enter
# is covered by the two unit rows (`rust/wa-term` parses the chord, `rust/wa-capabilities` raises the
# interrupt for a send-now line and only while a run is in flight) and by the queue kind in
# `scripts/test-cli-input.lua`. What is missing, and named in docs/missions/reports/always-available.md,
# is an end-to-end row for it.
exit 0
