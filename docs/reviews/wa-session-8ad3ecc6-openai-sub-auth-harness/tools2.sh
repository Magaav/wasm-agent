#!/usr/bin/env bash
# The reviewer's taxonomy and login tests. Each case prints what the module answered and what the
# fixture counted. Modes: absent | reject401 | spent | flowexpired | device | browser
set -u
W="C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch2ae38a56-f124-4b25-8732-cdeaf05f09d1"
S="$W/.review-scratch"
BIN="$W/rust/target/release/wa.exe"
MODE="${1:-absent}"
D="$S/run-$MODE"; rm -rf "$D"; mkdir -p "$D/home"
node -e 'console.log("SEED-"+require("crypto").randomUUID())' > "$D/seed.txt"

start_mock() { # extra args -> echo "pid port"
  node "$S/mock.mjs" --dir "$D" "$@" > "$D/mock.out" 2>&1 &
  local pid=$! port="" waited=0
  while [ -z "$port" ] && [ "$waited" -lt 20000 ]; do
    port="$(sed -n 's/^ready \([0-9]*\).*/\1/p' "$D/mock.out" 2>/dev/null | head -1)"
    [ -z "$port" ] && { sleep 0.2; waited=$((waited + 200)); }
  done
  echo "$pid $port"
}
stop_mock() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
worker() { # $1 port  $2 store
  env -u WASM_AGENT_LUA_ROOT \
    WASM_AGENT_HOME="$D/home" \
    WASM_AGENT_OPENAI_SUB_STORE="$2" \
    WASM_AGENT_OPENAI_SUB_AUTH_BASE="http://127.0.0.1:$1" \
    VERIFY_LOCK_WAIT_MS=8000 \
    WA_SCRIPT="$S/worker.lua" "$BIN" --db "$D/w.db" 2>&1
}
loginscript() { # $1 port extra env...
  env -u WASM_AGENT_LUA_ROOT \
    WASM_AGENT_HOME="$D/home" \
    WASM_AGENT_OPENAI_SUB_STORE="$D/store.json" \
    WASM_AGENT_OPENAI_SUB_AUTH_BASE="http://127.0.0.1:$1" \
    WA_SCRIPT="$S/login.lua" "$BIN" --db "$D/login.db" 2>&1
}
posts() { cat "$D/posts.jsonl" 2>/dev/null; }

case "$MODE" in
absent)
  read -r MOCK PORT <<<"$(start_mock --delay-ms 0)"
  echo "--- absent store (path does not exist) ---"
  worker "$PORT" "$D/nowhere/credentials.json" | grep -h "^VERIFY"
  stop_mock "$MOCK"
  echo "--- fixture saw ---"; posts
  node "$S/check.mjs" "$D" "$D/nowhere/credentials.json" "$D/seed.txt"
  ;;
reject401)
  node "$S/mkstore.mjs" "$D/store.json" "$D/seed.txt" acct-reject >/dev/null
  read -r MOCK PORT <<<"$(start_mock --fail-refresh 401)"
  echo "--- refresh refused with 401 ---"
  worker "$PORT" "$D/store.json" | grep -h "^VERIFY"
  stop_mock "$MOCK"
  echo "--- posts (must be one, not a retry) ---"; posts
  node "$S/check.mjs" "$D" "$D/store.json" "$D/seed.txt"
  echo "--- does any output echo the hostile body? ---"
  if grep -rq "eyJhbGciOiJIUzI1NiJ9" "$D" 2>/dev/null; then
    echo "LEAK: the provider body was echoed somewhere"; else echo "no hostile-body echo in $D"; fi
  ;;
spent)
  node "$S/mkstore.mjs" "$D/store.json" "$D/seed.txt" acct-spent >/dev/null
  echo "OTHER-TOKEN-NEVER-SEEDED" > "$D/seed.txt"   # the fixture now considers our token already spent
  read -r MOCK PORT <<<"$(start_mock --delay-ms 0)"
  echo "--- an already-spent rotating token ---"
  worker "$PORT" "$D/store.json" | grep -h "^VERIFY"
  stop_mock "$MOCK"
  echo "--- posts ---"; posts
  ;;
flowexpired)
  read -r MOCK PORT <<<"$(start_mock --pending-polls 100000)"
  echo "--- device flow nobody finishes (timeout_seconds=1) ---"
  VERIFY_LOGIN_MODE=device VERIFY_LOGIN_TIMEOUT=1 loginscript "$PORT"
  stop_mock "$MOCK"
  echo "--- posts ---"; posts
  echo "--- pending flow kept for a resume? ---"
  node -e 'const fs=require("fs");const p=process.argv[1]+"/login-flow.json";
    try{const j=JSON.parse(fs.readFileSync(p,"utf8"));console.log("flow pending="+j.pending+" keys="+Object.keys(j).join(","));}
    catch(e){console.log("no flow file: "+e.message);}' "$D"
  ;;
device)
  read -r MOCK PORT <<<"$(start_mock --pending-polls 2)"
  echo "--- device login (two pending answers, then authorized) ---"
  VERIFY_LOGIN_MODE=device VERIFY_LOGIN_TIMEOUT=20 loginscript "$PORT"
  stop_mock "$MOCK"
  echo "--- posts ---"; posts
  echo "--- store after login ---"
  node "$S/check.mjs" "$D" "$D/store.json" "$D/seed.txt"
  ;;
browser)
  read -r MOCK PORT <<<"$(start_mock --delay-ms 0)"
  echo "--- browser login, phase 1 (pending) ---"
  VERIFY_LOGIN_MODE=browser VERIFY_LOGIN_TIMEOUT=5 loginscript "$PORT" | tee "$D/browser1.out"
  STATE="$(sed -n 's/.*state=\([0-9a-f]\{32\}\).*/\1/p' "$D/browser1.out" | head -1)"
  echo "STATE=$STATE"
  echo "--- browser login, phase 2 (the pasted callback, complete+wrong-state) ---"
  VERIFY_LOGIN_MODE=browser VERIFY_LOGIN_TIMEOUT=5 \
    VERIFY_LOGIN_CALLBACK="http://localhost:1455/auth/callback?code=REVIEWER-B&state=deadbeef" \
    loginscript "$PORT" | grep -h "^LOGIN"
  VERIFY_LOGIN_MODE=browser VERIFY_LOGIN_TIMEOUT=5 \
    VERIFY_LOGIN_CALLBACK="http://localhost:1455/auth/callback?code=REVIEWER-B&state=$STATE" \
    loginscript "$PORT" | grep -h "^LOGIN"
  stop_mock "$MOCK"
  echo "--- posts ---"; posts
  ;;
*) echo "unknown mode $MODE"; exit 2;;
esac
