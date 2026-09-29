#!/usr/bin/env bash
# The module route on a real node, over real HTTP.
#
#   bash scripts/test-modules-route.sh
#
# Why this exists: `scripts/test-modules.lua` pins the route's behaviour *inside the interpreter* and
# the removal proof deletes a directory and asserts the listing - but neither would notice the route
# not being registered at all. A missing dispatch entry answers 404 with a page that renders a broken
# host, and the Lua side stays green: a previous landing lost a route exactly this way, with every
# test passing. So this starts two scratch nodes - one with the module enabled, one with nothing
# enabled - and asks them the five questions the design is about:
#
#   the listing (200 JSON, the module mounted, its capability refused, its entry a sibling URL)
#   a module's entry served byte-for-byte (200), and by id alone
#   a path that tries to leave the module directory (400)
#   a module that does not exist (404)
#   the same entry with nothing enabled (403), listed but off
#
# It names no module: the subject is the first directory under `modules/` that carries a manifest, and
# its entry and declared capabilities come from that manifest.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Never inherit a node's provider, home or rendezvous: WA_* here are this script's own inputs.
while IFS= read -r variable; do
  case "$variable" in
    WA_BIN|WA_PORT) ;;
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)

BIN="${WA_BIN:-}"
if [ -n "$BIN" ] && [ ! -x "$BIN" ] && [ -x "$BIN.exe" ]; then BIN="$BIN.exe"; fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  BIN=""
  for candidate in rust/target/release/wa.exe rust/target/release/wa; do
    if [ -x "$candidate" ]; then BIN="$candidate"; break; fi
  done
fi
if [ -z "$BIN" ]; then
  echo "  no node binary: build it first (cargo build --release --offline --manifest-path rust/Cargo.toml)" >&2
  exit 1
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

if [ ! -f "$ROOT/ui/index.html" ]; then echo "  no UI at $ROOT/ui" >&2; exit 1; fi

# The module under test, found rather than named - the same rule the removal proof uses.
MODULE_DIR=""
for candidate in "$ROOT"/modules/*/; do
  if [ -f "${candidate}module.json" ]; then MODULE_DIR="${candidate%/}"; break; fi
done
if [ -z "$MODULE_DIR" ]; then
  echo "  FAIL: no directory under modules/ carries a module.json - there is no module to ask for" >&2
  exit 1
fi
ID="$(basename "$MODULE_DIR")"
ENTRY="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).entry||""))' "$MODULE_DIR/module.json")"
DECLARED="$(node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).capabilities||[]).join(","))' "$MODULE_DIR/module.json")"
if [ -z "$ENTRY" ]; then echo "  FAIL: $ID declares no entry point" >&2; exit 1; fi
echo "module under test: $ID (entry $ENTRY, declares ${DECLARED:-nothing})"

PORT="${WA_PORT:-$(node scripts/free-test-port-block.cjs 2)}"
CLIENT_PORT=$((PORT + 1))
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-modules-http-XXXXXX")"
SERVER=""
cleanup() {
  local status=$?
  stop_node
  if [ "$status" != "0" ]; then
    echo "  fixture logs retained at $WORK" >&2
  else
    case "$WORK" in */wa-modules-http-??????) rm -rf -- "$WORK" 2>/dev/null || true ;; esac
  fi
  return "$status"
}
trap cleanup EXIT

stop_node() {
  [ -n "$SERVER" ] || return 0
  kill "$SERVER" 2>/dev/null
  for _ in $(seq 1 40); do kill -0 "$SERVER" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$SERVER" 2>/dev/null
  wait "$SERVER" 2>/dev/null
  SERVER=""
}

# One node, one database, one home, one ask. WASM_AGENT_LUA_ROOT makes this checkout's Lua the Lua
# under test, and the modules directory is then that checkout's own `modules/` - the ordinary path, not
# an override, so what is being tested is what a node in this tree actually serves.
start_node() { # start_node <name> <ask>
  local name="$1" ask="$2"
  mkdir -p "$WORK/home-$name"
  WASM_AGENT_HOME="$(native "$WORK/home-$name")" \
  WASM_AGENT_LUA_ROOT="$(native "$ROOT")" \
  WASM_AGENT_MODULES="$ask" \
  WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0 \
  WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1 WASM_AGENT_LLM_API_KEY=fixture-only \
  "$BIN" --db "$(native "$WORK/$name.db")" serve --port "$PORT" --client-port "$CLIENT_PORT" \
    --ui "$(native "$ROOT/ui")" > "$WORK/$name.log" 2>&1 &
  SERVER=$!
  local code=""
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
    [ "$code" = "200" ] && break
    sleep 0.25
  done
  if [ "${code:-}" != "200" ]; then
    echo "  FAIL: the node did not come up for ask '$ask' (see $WORK/$name.log)" >&2
    tail -5 "$WORK/$name.log" >&2
    return 1
  fi
}

FAILED=0
CHECKS=0
verdict() { # verdict <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    echo "  ok   $1: $3"
  else
    echo "  FAIL $1: expected $2, got $3" >&2
    FAILED=1
  fi
}

# `--path-as-is` keeps curl from collapsing `..` before the request is sent: the point of that case is
# what the *node* does with it, not what a client normalises away.
http() { # http <path> -> status code, body in $WORK/body, headers in $WORK/head
  curl -s --path-as-is -m 20 -D "$WORK/head" -o "$WORK/body" -w '%{http_code}' "http://127.0.0.1:$PORT$1"
}

json_get() { # json_get <file> <expression over `data`>
  node -e 'const data=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    process.stdout.write(String(eval(process.argv[2])))' "$1" "$2"
}

echo
echo "node A: WASM_AGENT_MODULES=$ID"
if start_node enabled "$ID"; then
  # `/modules` without the slash is a redirect: the page's module URLs are relative to it, and served
  # as a page at both depths it would resolve every panel outside the tree that holds it.
  status="$(http /modules)"
  verdict "the slashless route redirects" "301" "$status"
  verdict "and says where to" "Location: /modules/" "$(grep -i '^location:' "$WORK/head" | tr -d '\r')"

  status="$(http /modules/)"
  verdict "the host page is served at the module root" "200" "$status"
  verdict "it is html" "text/html; charset=utf-8" "$(grep -i '^content-type:' "$WORK/head" | tr -d '\r' | cut -d' ' -f2-)"
  verdict "and it is the page that mounts modules" "true" "$(grep -q 'waHostReady' "$WORK/body" && echo true || echo false)"

  status="$(http /modules/index.json)"
  verdict "the listing is served beside the page" "200" "$status"
  cp "$WORK/body" "$WORK/listing.json"
  verdict "the module is available" "true" "$(json_get "$WORK/listing.json" 'data.available >= 1')"
  verdict "and mounted, because it was asked for" "$ID" "$(json_get "$WORK/listing.json" 'data.mounted.join(",")')"
  verdict "discovery reports no issue" "true" "$(json_get "$WORK/listing.json" 'data.issues.length === 0')"
  verdict "the entry is a sibling of the page" "$ID/$ENTRY" \
    "$(json_get "$WORK/listing.json" 'data.modules.filter(m => m.id === "'"$ID"'")[0].entry_url')"
  if [ -n "$DECLARED" ]; then
    verdict "a declared capability this host does not grant is refused in the listing" "true" \
      "$(json_get "$WORK/listing.json" 'data.modules.filter(m => m.id === "'"$ID"'")[0].refused.length > 0')"
  fi

  status="$(http "/modules/$ID/$ENTRY")"
  verdict "the module's entry is served" "200" "$status"
  verdict "as html" "text/html; charset=utf-8" "$(grep -i '^content-type:' "$WORK/head" | tr -d '\r' | cut -d' ' -f2-)"
  if cmp -s "$WORK/body" "$MODULE_DIR/$ENTRY"; then
    verdict "byte-for-byte the file on disk" "identical" "identical"
  else
    verdict "byte-for-byte the file on disk" "identical" "differs"
  fi

  status="$(http "/modules/$ID")"
  verdict "the module's entry point is served by id alone" "200" "$status"
  if cmp -s "$WORK/body" "$MODULE_DIR/$ENTRY"; then
    verdict "and it is the same bytes" "identical" "identical"
  else
    verdict "and it is the same bytes" "identical" "differs"
  fi

  status="$(http "/modules/$ID/module.json")"
  verdict "the module's own manifest is served" "200" "$status"
  verdict "as json" "application/json; charset=utf-8" "$(grep -i '^content-type:' "$WORK/head" | tr -d '\r' | cut -d' ' -f2-)"

  status="$(http "/modules/$ID/../index.html")"
  verdict "a path that tries to leave the module directory is refused" "400" "$status"
  # This one never reaches the route: `static_reply` answers a ".." path on the accept thread, before
  # the interpreter, for every route alike. The route's own refusal (400 `bad_path`) is what the case
  # below pins, and `scripts/test-modules.lua` pins it inside the interpreter.
  status="$(http "/modules/$ID/C:/Windows/win.ini")"
  verdict "a path a module may not reach is refused by the route" "400" "$status"
  verdict "and says why" "true" "$(grep -q 'bad_path' "$WORK/body" && echo true || echo false)"

  status="$(http "/modules/no-such-module-in-this-tree/index.html")"
  verdict "a module that does not exist is a 404" "404" "$status"
  verdict "and says why" "true" "$(grep -q 'module_not_found' "$WORK/body" && echo true || echo false)"

  status="$(http /modules/not-a-page-in-this-route.html)"
  verdict "the module system serves its page and its files, not anything else" "404" "$status"
fi
stop_node

echo
echo "node B: nothing asked for"
if start_node disabled "nothing-is-asked-for-in-this-run"; then
  status="$(http "/modules/$ID/$ENTRY")"
  verdict "the files of a module nobody enabled are refused" "403" "$status"
  verdict "and say why" "true" "$(grep -q 'module_not_enabled' "$WORK/body" && echo true || echo false)"

  status="$(http /modules/index.json)"
  verdict "the listing is still served" "200" "$status"
  cp "$WORK/body" "$WORK/listing-off.json"
  verdict "the module is still listed" "true" "$(json_get "$WORK/listing-off.json" 'data.available >= 1')"
  verdict "and nothing is mounted" "" "$(json_get "$WORK/listing-off.json" 'data.mounted.join(",")')"
  verdict "with no error for a node that has a module switched off" "true" \
    "$(json_get "$WORK/listing-off.json" 'data.ok === true && data.issues.length === 0')"

  status="$(http /modules/)"
  verdict "the host page is still served with nothing mounted" "200" "$status"
fi
stop_node

echo
if [ "$FAILED" = "0" ]; then
  echo "module route over http ok ($CHECKS checks)"
else
  echo "module route over http FAILED ($CHECKS checks)" >&2
fi
exit "$FAILED"
