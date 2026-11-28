#!/usr/bin/env bash
# /health NAMES WHAT THE NODE IS INSTALLED FROM AND WHO SUPERVISES IT (installer-refuses-a-target, item 4 - 25/11)
#
# Two measured facts had no answer anywhere:
#   * `runtime-worktree.txt` named a path that no longer existed (24/11) and nothing said so;
#   * the live unit was rewritten to a scratch binary and port, so the live node had NO supervisor for 38 minutes while
#     every endpoint it served looked healthy.
#
# This row starts a scratch node (its own HOME and `--port`) whose install dir carries the 24/11 shape, and asserts the
# `install` object of `/health` names it: `runtime_worktree_state: missing`, `supervisor: watching_another_home`, and - the
# other direction - `ok`/`watching` once the tree exists and the record names this home with a live pid.
#
# Fences: HOME and WASM_AGENT_HOME are the scratch dir, the only port bound is this row's, no manager is touched, and the
# node is killed by the pid this row started.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "health-names-its-install: SKIP (no wa binary: set WA_BIN)" >&2; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "health-names-its-install: SKIP (curl is not on PATH)" >&2; exit 0; }
S="$(mktemp -d "${TMPDIR:-/tmp}/wa-health-install.XXXXXX")"
PORT="$(( 24000 + ($$ % 800) ))"
SP=""
cleanup() { [ -n "$SP" ] && kill "$SP" 2>/dev/null; [ -n "$SP" ] && wait "$SP" 2>/dev/null; chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }

serve() {
  HOME="$S/home" WASM_AGENT_HOME="$S/home" WASM_AGENT_MANAGED=0 "$BIN" serve --port "$PORT" >"$S/serve.log" 2>&1 & SP=$!
  for _ in $(seq 1 80); do curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0; sleep 0.25; done
  return 1
}
stop() { [ -n "$SP" ] && { kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; SP=""; }; }
install_block() { curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("install") or {}))'; }

mkdir -p "$S/home/.local/bin" "$S/home/.wasm-agent/sentinel"
# THE 24/11 SHAPE: a worktree record naming a path that no longer exists, and a supervisor record naming ANOTHER home.
printf '/does/not/exist/any/more\n' > "$S/home/.local/bin/runtime-worktree.txt"
printf '{"home":"/some/other/home","pid":999999,"schema":1}\n' > "$S/home/.wasm-agent/sentinel/node.json"
serve || { echo "health-names-its-install: SKIP (the scratch node did not answer: $(tail -1 "$S/serve.log"))" >&2; exit 0; }
block="$(install_block)"
case "$block" in
  *'"runtime_worktree_state": "missing"'*) ok "a worktree record naming a path that does not exist is named: missing" ;;
  *) bad "the install block does not name the missing worktree: $block" ;;
esac
case "$block" in
  *'"supervisor": "watching_another_home"'*) ok "a supervisor record naming another home is named: watching_another_home" ;;
  *) bad "the install block does not name a foreign supervisor record: $block" ;;
esac
stop

# ---- the other direction: an existing tree and a live supervisor record -------------------------------------------------
mkdir -p "$S/home/.local/bin" "$S/tree"
printf '%s\n' "$S/tree" > "$S/home/.local/bin/runtime-worktree.txt"
printf '{"home":"%s","pid":%s,"schema":1}\n' "$S/home" "$$" > "$S/home/.wasm-agent/sentinel/node.json"
serve || { bad "the scratch node did not answer on the second run"; }
block="$(install_block)"
case "$block" in
  *'"runtime_worktree_state": "ok"'*) ok "an existing worktree is named: ok" ;;
  *) bad "the install block does not report an existing worktree: $block" ;;
esac
case "$block" in
  *'"supervisor": "watching"'*) ok "a record naming this home with a live pid is named: watching" ;;
  *) bad "the install block does not report a live supervisor: $block" ;;
esac
stop

if [ "$failed" -gt 0 ]; then echo "health-names-its-install: FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "health-names-its-install ok ($checks checks)"
