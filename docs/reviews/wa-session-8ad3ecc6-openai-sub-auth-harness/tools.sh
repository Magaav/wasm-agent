#!/usr/bin/env bash
# The reviewer's decisive single-flight test: N processes, one store, one rotating token.
#   tools.sh singleflight <N> <delay_ms>
# Everything runs under a scratch WASM_AGENT_HOME so the live node's own resource store is untouched.
set -u
W="C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch2ae38a56-f124-4b25-8732-cdeaf05f09d1"
S="$W/.review-scratch"
BIN="$W/rust/target/release/wa.exe"
MODE="${1:-singleflight}"
N="${2:-6}"
DELAY="${3:-3000}"

run_mock() { # $1 = dir extra-args..., prints port
  local dir="$1"; shift
  node "$S/mock.mjs" --dir "$dir" "$@" > "$dir/mock.out" 2>&1 &
  local pid=$!
  local port="" waited=0
  while [ -z "$port" ] && [ "$waited" -lt 20000 ]; do
    port="$(sed -n 's/^ready \([0-9]*\).*/\1/p' "$dir/mock.out" 2>/dev/null | head -1)"
    [ -z "$port" ] && { sleep 0.2; waited=$((waited + 200)); }
  done
  echo "$pid $port"
}

case "$MODE" in
singleflight)
  D="$S/run-singleflight"; rm -rf "$D"; mkdir -p "$D/home"
  node -e 'console.log("SEED-"+require("crypto").randomUUID())' > "$D/seed.txt"
  node "$S/mkstore.mjs" "$D/store.json" "$D/seed.txt" acct-concurrent
  read -r MOCKPID PORT <<<"$(run_mock "$D" --delay-ms "$DELAY")"
  echo "MOCK pid=$MOCKPID port=$PORT delay_ms=$DELAY workers=$N"
  [ -z "$PORT" ] && { echo "no mock port"; exit 3; }
  PIDS=""
  for i in $(seq 1 "$N"); do
    env -u WASM_AGENT_LUA_ROOT \
      WASM_AGENT_HOME="$D/home" \
      WASM_AGENT_OPENAI_SUB_STORE="$D/store.json" \
      WASM_AGENT_OPENAI_SUB_AUTH_BASE="http://127.0.0.1:$PORT" \
      VERIFY_LOCK_WAIT_MS=25000 \
      WA_SCRIPT="$S/worker.lua" \
      "$BIN" --db "$D/w$i.db" > "$D/w$i.out" 2> "$D/w$i.err" &
    PIDS="$PIDS $!"
  done
  echo "launched $N workers: $PIDS"
  for p in $PIDS; do wait "$p"; done
  kill "$MOCKPID" 2>/dev/null
  wait "$MOCKPID" 2>/dev/null
  echo "--- worker lines ---"
  grep -h "^VERIFY" "$D"/w*.out
  echo "--- counts (reviewer's own instrument) ---"
  node "$S/check.mjs" "$D" "$D/store.json" "$D/seed.txt"
  ;;
locked)
  D="$S/run-locked"; rm -rf "$D"; mkdir -p "$D/home"
  node -e 'console.log("SEED-"+require("crypto").randomUUID())' > "$D/seed.txt"
  node "$S/mkstore.mjs" "$D/store.json" "$D/seed.txt" acct-locked
  read -r MOCKPID PORT <<<"$(run_mock "$D" --delay-ms 500)"
  echo "MOCK pid=$MOCKPID port=$PORT"
  # A live holder in its own process, holding the credential lock for 20 s.
  env -u WASM_AGENT_LUA_ROOT WASM_AGENT_HOME="$D/home" VERIFY_HOLD_MS=20000 \
    WA_SCRIPT="$S/holder.lua" "$BIN" --db "$D/holder.db" > "$D/holder.out" 2>&1 &
  HOLDER=$!
  for _ in $(seq 1 40); do grep -q "HOLDER claimed=true" "$D/holder.out" 2>/dev/null && break; sleep 0.25; done
  cat "$D/holder.out"
  # The caller: must meet `locked`, spend nothing.
  env -u WASM_AGENT_LUA_ROOT \
    WASM_AGENT_HOME="$D/home" \
    WASM_AGENT_OPENAI_SUB_STORE="$D/store.json" \
    WASM_AGENT_OPENAI_SUB_AUTH_BASE="http://127.0.0.1:$PORT" \
    VERIFY_LOCK_WAIT_MS=3000 \
    WA_SCRIPT="$S/worker.lua" "$BIN" --db "$D/caller.db" > "$D/caller.out" 2>&1
  grep -h "^VERIFY" "$D/caller.out"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  kill "$MOCKPID" 2>/dev/null; wait "$MOCKPID" 2>/dev/null
  echo "--- counts while the lock was held ---"
  node "$S/check.mjs" "$D" "$D/store.json" "$D/seed.txt"
  ;;
*)
  echo "unknown mode $MODE"; exit 2;;
esac
