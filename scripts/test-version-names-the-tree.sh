#!/usr/bin/env bash
# THE VERSION LINE NAMES WHAT THIS NODE RUNS (Fable, 24/11).
#
# MEASURED on this node after a scripts-only landing (fe108a8c): ~/.local/bin/installed.txt said
# `commit=fe108a8c` - the Lua tree that deploy installed (`scripts/deploy.sh`, the fast path, 21/11) - while
# `wa --version` and /health said `v9a0c589a`, the binary's COMPILE-TIME commit, because a fast-path deploy
# keeps the older binary beside the newer tree. The one command Victor is told to check named a commit that
# does not hold what he runs.
#
# What this row proves, with a real binary, a scratch home, a scratch install and a real node:
#   1. `wa --version` names the bytes AND the tree when the install is newer than the binary;
#   2. /health names the same string - one composer (rust/wa-host/src/build_info.rs install_label), so the
#      two surfaces cannot drift;
#   3. the follow's final line (`wa update --follow`) names the TREE commit as well;
#   4. a record that names the binary's own commit adds no tree: the line does not become noise;
#   5. a record that names nothing still answers a name, never an empty label.
#
# The record is the shape `scripts/deploy.sh` writes on a fast-path install (commit= is the Lua tree's,
# `lua_tree=` the same, `lua_fast_path=1`, `build_info=yes`). It is written by hand on purpose: producing it
# with a real deploy would build the tree and run the gate, and this row is about what a READER makes of it.
# Nothing outside the scratch tree is read or written: HOME, WASM_AGENT_HOME and WA_INSTALL_DIR are the
# directories below, the vault environment is cleared (the brief's rule), and the node is stopped by the pid
# this script started, never by a name pattern.
#
# Prints `version names the tree: ok (N checks)`; any failed check exits 1.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0; failed=0
ok()  { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }

. "$ROOT/scripts/lib/scratch-home.sh"
scratch_root="$(wa_scratch_root wa-version-tree)" || exit 2
mkdir -p "$scratch_root"
WORK="$(mktemp -d "$scratch_root/work.XXXXXX")" || { echo 'REFUSED version-tree: no scratch work dir' >&2; exit 2; }
SCRATCH_HOME="$WORK/home"
mkdir -p "$SCRATCH_HOME"
wa_scratch_home_guard "$SCRATCH_HOME" || { rm -rf "$WORK"; exit 2; }
INSTALL="$WORK/install"
mkdir -p "$INSTALL"
NODE_PID=""
cleanup() { [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

BIN="${WA_BIN:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  for candidate in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" "$ROOT/rust/target/release/wa"; do
    [ -x "$candidate" ] && BIN="$candidate" && break
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo 'SKIP version-tree: no wa binary to run (build it, or set WA_BIN)'
  exit 0
fi
cp -f "$BIN" "$INSTALL/wa" && chmod +x "$INSTALL/wa" || { echo 'FAIL version-tree: the binary could not be placed' >&2; exit 1; }
cp -R "$ROOT/ui" "$INSTALL/ui" 2>/dev/null || true

# The environment every call in this row runs with: scratch home, scratch install, no vault, no relay.
# `install-record.sh` scrubs the same variables for the same reason - a probe must not reach a real store.
node_env() {
  env -u WASM_AGENT_DB -u WASM_AGENT_LUA_ROOT -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY \
      -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE -u WASM_AGENT_VAULT_PASSPHRASE \
      HOME="$SCRATCH_HOME" WASM_AGENT_HOME="$SCRATCH_HOME" WA_INSTALL_DIR="$INSTALL" "$@"
}
the_version() { node_env "$INSTALL/wa" --version 2>&1 | head -1; }

# ---- the two commits: what the bytes are, and what the install says it runs -----------------------
BIN_COMMIT="$(node_env "$INSTALL/wa" --build-info 2>/dev/null | sed -n 's/^commit=//p' | head -1)"
if [ -z "$BIN_COMMIT" ] || [ "$BIN_COMMIT" = unknown ]; then
  echo 'SKIP version-tree: this binary cannot name its own commit (--build-info), so the question cannot be asked'
  exit 0
fi
TREE_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
[ -n "$TREE_COMMIT" ] || TREE_COMMIT="$(git -C "$ROOT" rev-parse HEAD~1 2>/dev/null)"
[ -n "$TREE_COMMIT" ] || { echo 'SKIP version-tree: no git commit to name as the tree' ; exit 0; }
case "$TREE_COMMIT" in "$BIN_COMMIT"*) TREE_COMMIT="$(git -C "$ROOT" rev-parse HEAD~1 2>/dev/null)" ;; esac
case "$BIN_COMMIT" in "$TREE_COMMIT"*) TREE_COMMIT="$(git -C "$ROOT" rev-parse HEAD~1 2>/dev/null)" ;; esac
[ -n "$TREE_COMMIT" ] || { echo 'SKIP version-tree: the binary IS this tree, so there is no newer tree to name'; exit 0; }
T12="$(printf '%s' "$TREE_COMMIT" | cut -c1-12)"
B8="$(printf '%s' "$BIN_COMMIT" | cut -c1-8)"
BIN_SHA="$(sha256sum "$INSTALL/wa" 2>/dev/null | cut -d' ' -f1)"
MID="$(printf '\302\267')"

# THE FAST-PATH RECORD exactly as scripts/deploy.sh writes it for a Lua-only install.
write_record() { # <commit>
  {
    printf 'commit=%s\n' "$1"
    printf 'branch=main\n'
    printf 'dirty=false\n'
    printf 'sha256=%s\n' "${BIN_SHA:-unknown}"
    printf 'install_dir=%s\n' "$INSTALL"
    printf 'source_provenance=clean-built-by-deploy\n'
    printf 'via=deploy.sh\n'
    printf 'at=2026-11-24T18:03:23Z\n'
    printf 'tree=7fe2d09baef0002b1d211da7f12d40f779739765\n'
    printf 'build_info=yes\n'
    printf 'lua_tree=%s\n' "$1"
    printf 'lua_fast_path=1\n'
  } > "$INSTALL/installed.txt"
}

echo '--- 1. a scripts-only install: --version names the bytes AND the tree ---'
write_record "$TREE_COMMIT"
LINE="$(the_version)"
case "$LINE" in *"tree $T12"*) ok "--version names the tree this install runs: $LINE" ;; *) bad "--version does not name the tree $T12 (it said: $LINE)" ;; esac
case "$LINE" in *"$B8"*) ok 'and it still names the bytes that are executing' ;; *) bad "--version stopped naming the bytes ($B8): $LINE" ;; esac

# ---- 2. /health names the same string, from a REAL node ------------------------------------------
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
if [ -z "$PORT" ]; then
  bad '/health: no free port could be measured'
else
  ( cd "$WORK" && exec env -u WA_UI_DIR -u WASM_AGENT_LUA_ROOT -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY \
      -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE -u WASM_AGENT_VAULT_PASSPHRASE \
      HOME="$SCRATCH_HOME" WASM_AGENT_HOME="$SCRATCH_HOME" WA_INSTALL_DIR="$INSTALL" \
      "$INSTALL/wa" --db "$SCRATCH_HOME/node.db" serve --port "$PORT" --client-port "$((PORT + 1))" \
      --ui "$INSTALL/ui" >"$WORK/serve.log" 2>&1 ) &
  NODE_PID=$!
  READY=0
  for _ in $(seq 1 200); do
    if curl -s -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then READY=1; break; fi
    sleep 0.1
  done
  if [ "$READY" != 1 ]; then
    bad "/health: the scratch node did not answer; its log: $(tail -3 "$WORK/serve.log" 2>/dev/null)"
  else
    HEALTH="$(curl -s -m 2 "http://127.0.0.1:$PORT/health" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p')"
    case "$HEALTH" in *"tree $T12"*) ok "/health names the same tree: $HEALTH" ;; *) bad "/health says '$HEALTH' and not the tree $T12" ;; esac
  fi
fi

# ---- 3. the follow's final line names the tree commit too ------------------------------------
SANDBOX="$SCRATCH_HOME/.wasm-agent"
mkdir -p "$SANDBOX/sentinel/requests" "$SANDBOX/sentinel/queue"
ID="1795500000000000000-1-1"
printf '{"verb":"deploy","reason":"fixture","queued_at":%s,"session":"","prompt":""}\n' "$(date +%s)" > "$SANDBOX/sentinel/requests/$ID.json"
printf '{"schema":1,"id":"%s","verb":"deploy","state":"running","phase":"spawned","detail":"deploy started detached","queued_at":%s,"updated_at":%s,"attempts":1}\n' \
  "$ID" "$(date +%s)" "$(date +%s)" > "$SANDBOX/sentinel/queue/$ID.json"
printf '{"ok":true,"commit":"%s","branch":"main","detail":"installed %s; watcher 4242","reason":"fixture","at":"%s","request_id":"%s"}\n' \
  "$T12" "$T12" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" > "$INSTALL/deploy-result.json"
FOLLOW_OUT="$WORK/follow.txt"
node_env WASM_AGENT_LUA_ROOT="$ROOT" "$INSTALL/wa" --db "$SCRATCH_HOME/follow.db" update --follow > "$FOLLOW_OUT" 2>&1
FOLLOW_CODE=$?
[ "$FOLLOW_CODE" = 0 ] || bad "wa update --follow exited $FOLLOW_CODE (it read a finished install): $(tail -2 "$FOLLOW_OUT")"
grep -Eq "installed $T12 $MID [0-9]+m?[0-9]*s" "$FOLLOW_OUT" \
  && ok "the follow's final line names the tree commit $T12" \
  || bad "the follow's final line does not name $T12: $(tail -2 "$FOLLOW_OUT")"
rm -f "$INSTALL/deploy-result.json" "$SANDBOX/sentinel/requests/$ID.json" "$SANDBOX/sentinel/queue/$ID.json"

# ---- 4. a record naming these very bytes adds no tree -------------------------------------------
echo '--- 4. one commit is not two: no tree suffix when the record names the bytes ---'
write_record "$BIN_COMMIT"
SAME="$(the_version)"
case "$SAME" in *'tree '*) bad "a record naming the binary's own commit still added a tree: $SAME" ;; *) ok "no tree suffix when the install IS the bytes: $SAME" ;; esac
write_record "${BIN_COMMIT:0:8}"
SHORT="$(the_version)"
case "$SHORT" in *'tree '*) bad "the same commit spelled short was read as another: $SHORT" ;; *) ok 'and the same commit spelled short is still one commit' ;; esac

# ---- 5. a record that names nothing still answers a name ---------------------------------------
: > "$INSTALL/installed.txt"
EMPTY="$(the_version)"
if [ -n "$EMPTY" ] && [ "${#EMPTY}" -gt 12 ]; then ok "an empty record still answers a name: $EMPTY"; else bad "/health/--version answered an empty label for an empty record ('$EMPTY')"; fi

[ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null
NODE_PID=""
if [ "$failed" -eq 0 ]; then echo "version names the tree: ok ($checks checks)"; exit 0; fi
echo "version names the tree: FAILED ($checks checks, $failed failed)"
exit 1
