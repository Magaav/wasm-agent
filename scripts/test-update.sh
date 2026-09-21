#!/usr/bin/env bash
# Live check of POST /update against a scratch node whose install dir is a fixture.
#
# Cases: nothing built, already current (which must write *no* request), dirty (which queues and says
# the gate would refuse it), a newer commit (which queues and reports the request the sentinel named),
# and a sentinel that refuses (which must not read as success).
#
# The sentinel here is a stub shell script named wa-sentinel.exe - Git Bash runs a script whose exec
# fails as a script. The operator's real sentinel is never invoked: a fixture that dropped a request
# into the real request box could install a placeholder over a running node.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
PORT="${1:-8941}"
W="$(mktemp -d /tmp/wa-upd-XXXXXX)"
INST="$W/install"
TREE="$W/tree"
mkdir -p "$INST" "$TREE/rust/target/release"
printf 'rust/target/\n' > "$TREE/.gitignore"
( cd "$TREE" && echo fixture > file.txt && git init -q . && git add file.txt .gitignore \
  && git -c user.email=fixture@local -c user.name=fixture commit -qm 'fixture' )
COMMIT="$(git -C "$TREE" rev-parse --short HEAD)"
# Windows form, because that is what runtime-worktree.txt holds on this machine.
printf '%s\n' "$(cygpath -w "$TREE")" > "$INST/runtime-worktree.txt"
printf 'commit=%s\nsource_commit_hint=%s\n' "$COMMIT" "$COMMIT" > "$INST/installed.txt"
REQUESTS="$HOME/.wasm-agent/sentinel/requests"
BEFORE="$(ls "$REQUESTS" 2>/dev/null | wc -l)"
STUB="$INST/wa-sentinel.exe"
printf '#!/bin/sh\necho "  requested upgrade: %s/requests/1789987058-0000.json"\necho "  the sentinel performs it - it is only a stub"\n' "$W" > "$STUB"
chmod +x "$STUB"

echo "fixture: tree=$TREE commit=$COMMIT"
WA_INSTALL_DIR="$(cygpath -w "$INST")" "$BIN" --db "$W/node.db" serve --port "$PORT" \
  --client-port $((PORT + 1)) --ui "$ROOT/ui" > "$W/node.log" 2>&1 &
NODE=$!
trap 'kill $NODE 2>/dev/null; sleep 0.3; rm -rf "$W"' EXIT
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { echo "FAIL: fixture node did not come up"; tail -5 "$W/node.log"; exit 1; }
ask() { curl -s -m 30 -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/update"; }
show() { echo "$1" | tr ',' '\n' | grep -E "\"$2\"" | head -"${3:-4}"; }

echo "--- 1. a tree with nothing built in it ---"
A="$(ask)"; show "$A" "status|error|next"
case "$A" in *'"nothing_built"'*) echo "  ok: an unbuilt tree is refused, not queued" ;;
  *) echo "  FAIL: expected nothing_built"; exit 1 ;; esac

echo "--- 2. the tree is clean and at the installed commit ---"
echo placeholder > "$TREE/rust/target/release/wa.exe"
B="$(ask)"; show "$B" "status|changed|commit"
case "$B" in *'"already_current"'*) echo "  ok: it says there is nothing to do" ;;
  *) echo "  FAIL: expected already_current, got: $B"; exit 1 ;; esac
case "$B" in *'"queued"'*) echo "  FAIL: a no-op must not queue an install"; exit 1 ;;
  *) echo "  ok: no request was written for the sentinel" ;; esac

echo "--- 3. uncommitted work queues, and says the gate would refuse it ---"
echo scratch > "$TREE/scratch.lua"
C="$(ask)"; show "$C" "status|queued|warning|dirty"
case "$C" in *'"queued":true'*) echo "  ok: a dirty tree still queues - that is what an uncommitted build is for" ;;
  *) echo "  FAIL: a dirty tree must queue, got: $C"; exit 1 ;; esac
case "$C" in *'would refuse it'*) echo "  ok: it says scripts/deploy.sh would refuse this tree" ;;
  *) echo "  FAIL: a dirty tree must carry that warning: $C"; exit 1 ;; esac
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
printf '#!/bin/sh\necho "unknown verb" >&2\nexit 2\n' > "$STUB"
E="$(ask)"; show "$E" "status|error|observed"
case "$E" in *'"sentinel_refused"'*) echo "  ok: a refusal by the sentinel refuses the command" ;;
  *) echo "  FAIL: expected sentinel_refused, got: $E"; exit 1 ;; esac

AFTER="$(ls "$REQUESTS" 2>/dev/null | wc -l)"
[ "$BEFORE" = "$AFTER" ] && echo "  ok: the real sentinel's request box is untouched ($BEFORE file(s))" \
  || { echo "  FAIL: the real request box changed ($BEFORE -> $AFTER)"; exit 1; }
