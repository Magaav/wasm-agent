#!/usr/bin/env bash
# Live check of POST /update against a scratch node whose install dir is a fixture.
#
# `/update` deploys now, so the cases are the gate's preconditions rather than a build's: an unbuilt
# tree (which queues - the gate builds it), the tree already at the installed commit (which also
# queues, because the commit does not describe the install), uncommitted work (which is refused,
# because the gate refuses a dirty tree), a newer installed commit (which queues and reports the
# request the sentinel named), and a sentinel that refuses (which must not read as success).
#
# The sentinel here is a stub shell script with the platform's sentinel name. The operator's real
# sentinel is never invoked: a fixture that dropped a request
# into the real request box could install a placeholder over a running node.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
PORT="${1:-8941}"
W="$(mktemp -d /tmp/wa-upd-XXXXXX)"
INST="$W/install"
TREE="$W/tree"
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"
  else printf '%s' "$1"
  fi
}
case "$(uname -s 2>/dev/null)" in
  CYGWIN*|MINGW*|MSYS*) WA_NAME=wa.exe; SENTINEL_NAME=wa-sentinel.exe ;;
  *) WA_NAME=wa; SENTINEL_NAME=wa-sentinel ;;
esac
mkdir -p "$INST" "$TREE/rust/target/release"
printf 'rust/target/\n' > "$TREE/.gitignore"
( cd "$TREE" && echo fixture > file.txt && git init -q --initial-branch=main . && git add file.txt .gitignore \
  && git -c user.email=fixture@local -c user.name=fixture commit -qm 'fixture' \
  && git init -q --bare "$W/origin.git" \
  && git remote add origin "$W/origin.git" && git push -q origin main \
  && git checkout -q -b tree )
COMMIT="$(git -C "$TREE" rev-parse --short HEAD)"
# Native form, because runtime-worktree.txt is consumed by a native git process.
printf '%s\n' "$(native_path "$TREE")" > "$INST/runtime-worktree.txt"
printf 'commit=%s\nsource_commit_hint=%s\n' "$COMMIT" "$COMMIT" > "$INST/installed.txt"
REQUESTS="$HOME/.wasm-agent/sentinel/requests"
BEFORE="$(ls "$REQUESTS" 2>/dev/null | wc -l)"
STUB="$INST/$SENTINEL_NAME"
ARGS="$W/sentinel-args.txt"
cat > "$STUB" <<STUB
#!/bin/sh
if [ "\$1" = "preflight" ]; then
  echo '{"schema":1,"watcher":"running","watcher_pid":4242,"ownership":"watcher_lifetime_lock","stop_file":false,"pending_deploys":[],"inventory_verified":true,"capabilities":{"health_free":true,"atomic_deploy_dedupe":true}}'
  exit 0
fi
printf '%s\n' "\$@" > "$ARGS"
echo "  requested deploy: $W/requests/1789987058-0000.json"
echo "  the sentinel performs it - it is only a stub"
STUB
chmod +x "$STUB"

# The watcher this fixture claims, and its own application home. `/update` refuses before queueing when
# no watcher can perform the request - a request that sat in the box for over an hour while the install
# stayed on the old commit is what that answers - so the fixture has to show one. The pid is a real
# process, held for the length of this run, written into the fixture's own `sentinel.pid`: the file
# `update.lua` reads and `wa-sentinel status` reports from. A pid that was only *written* would prove
# nothing about a probe that asks the OS. WASM_AGENT_HOME keeps all of it - pid file, request box,
# config - inside the fixture, so the operator's sentinel state is not read or written.
WATCHER_STATE="$W/home/.wasm-agent/sentinel"
mkdir -p "$WATCHER_STATE/requests"
case "$(uname -s 2>/dev/null)" in
  CYGWIN*|MINGW*|MSYS*)
    powershell -NoProfile -Command "\$p = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile','-Command','Start-Sleep 900' -WindowStyle Hidden -PassThru; \$p.Id" 2>/dev/null | tr -d '\r' > "$W/watcher.pid" ;;
  *) sleep 900 & echo $! > "$W/watcher.pid" ;;
esac
WATCHER="$(cat "$W/watcher.pid" 2>/dev/null | tr -d '\r\n')"
[ -n "$WATCHER" ] || { echo "FAIL: the fixture could not start the watcher process it needs"; exit 1; }
printf '%s\n' "$WATCHER" > "$WATCHER_STATE/sentinel.pid"
kill_watcher() {
  [ -n "$WATCHER" ] || return 0
  case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*) powershell -NoProfile -Command "Stop-Process -Id $WATCHER -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 ;;
    *) kill "$WATCHER" 2>/dev/null ;;
  esac
}

echo "fixture: tree=$TREE commit=$COMMIT watcher=$WATCHER"
WASM_AGENT_HOME="$(native_path "$W/home")" WA_INSTALL_DIR="$(native_path "$INST")" \
  "$BIN" --db "$W/node.db" serve --port "$PORT" \
  --client-port $((PORT + 1)) --ui "$(native_path "$ROOT/ui")" > "$W/node.log" 2>&1 &
NODE=$!
trap 'kill $NODE 2>/dev/null; kill_watcher; sleep 0.3; rm -rf "$W"' EXIT
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { echo "FAIL: fixture node did not come up"; tail -5 "$W/node.log"; exit 1; }
ask() { curl -s -m 30 -X POST -H 'content-type: application/json' -d '{"thread":"fixture-session"}' "http://127.0.0.1:$PORT/update"; }
show() { echo "$1" | tr ',' '\n' | grep -E "\"$2\"" | head -"${3:-4}"; }

echo "--- 1. a tree with nothing built in it ---"
A="$(ask)"; show "$A" "status|queued|message"
case "$A" in *'"queued":true'*) echo "  ok: an unbuilt tree queues - the gate builds it" ;;
  *) echo "  FAIL: expected a queued deploy, got: $A"; exit 1 ;; esac
grep -qx -- '--if-no-pending' "$ARGS" || { echo "FAIL: update bypassed atomic deploy admission"; exit 1; }
grep -qx -- '--session' "$ARGS" && grep -qx -- 'fixture-session' "$ARGS" \
  && grep -qx -- '--prompt' "$ARGS" \
  && echo "  ok: the replacement carries a durable session continuation" \
  || { echo "  FAIL: the sentinel request lost its session continuation: $(tr '\n' ' ' < "$ARGS")"; exit 1; }

echo "--- 2. the tree is clean and at the installed commit ---"
echo placeholder > "$TREE/rust/target/release/$WA_NAME"
B="$(ask)"; show "$B" "status|queued|commit"
case "$B" in *'"queued":true'*) echo "  ok: it still queues - the commit does not describe the install" ;;
  *) echo "  FAIL: expected a queued deploy, got: $B"; exit 1 ;; esac
case "$B" in *'"already_current"'*) echo "  FAIL: the commit alone must not answer nothing-to-do"; exit 1 ;;
  *) echo "  ok: it does not claim there is nothing to do" ;; esac

echo "--- 3. uncommitted work is refused, because the gate refuses a dirty tree ---"
echo scratch > "$TREE/scratch.lua"
C="$(ask)"; show "$C" "status|error|next"
case "$C" in *'"tree_dirty"'*) echo "  ok: a dirty tree is refused, not queued" ;;
  *) echo "  FAIL: expected tree_dirty, got: $C"; exit 1 ;; esac
case "$C" in *'"queued":true'*) echo "  FAIL: a request certain to fail must not be written"; exit 1 ;;
  *) echo "  ok: no request was written for it" ;; esac
rm -f "$TREE/scratch.lua"

echo "--- 4. a newer installed commit is behind, so it queues ---"
printf 'commit=deadbee\nsource_commit_hint=deadbee\n' > "$INST/installed.txt"
D="$(ask)"; show "$D" "status|queued|request|reason" 5
case "$D" in *'"queued":true'*) echo "  ok: it queues" ;;
  *) echo "  FAIL: expected a queued request, got: $D"; exit 1 ;; esac
case "$D" in *'not done yet'*) echo "  ok: the answer says queued, not done" ;;
  *) echo "  FAIL: a queued request must not read as done: $D"; exit 1 ;; esac
case "$D" in *'"request":"'*'1789987058-0000.json'*) echo "  ok: the request the sentinel named is reported" ;;
  *) echo "  FAIL: the request path must come from the sentinel's own output: $D"; exit 1 ;; esac

echo "--- 5. a sentinel that refuses is not a success ---"
cat > "$STUB" <<'STUB'
#!/bin/sh
if [ "$1" = "preflight" ]; then
  echo '{"schema":1,"watcher":"running","watcher_pid":4242,"ownership":"watcher_lifetime_lock","stop_file":false,"pending_deploys":[],"inventory_verified":true,"capabilities":{"health_free":true,"atomic_deploy_dedupe":true}}'
  exit 0
fi
echo "unknown verb" >&2
exit 2
STUB
E="$(ask)"; show "$E" "status|error|observed"
case "$E" in *'"sentinel_refused"'*) echo "  ok: a refusal by the sentinel refuses the command" ;;
  *) echo "  FAIL: expected sentinel_refused, got: $E"; exit 1 ;; esac

AFTER="$(ls "$REQUESTS" 2>/dev/null | wc -l)"
[ "$BEFORE" = "$AFTER" ] && echo "  ok: the real sentinel's request box is untouched ($BEFORE file(s))" \
  || { echo "  FAIL: the real request box changed ($BEFORE -> $AFTER)"; exit 1; }
