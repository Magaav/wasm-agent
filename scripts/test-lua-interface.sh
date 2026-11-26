#!/usr/bin/env bash
# THE HOST DECLARES ITS LUA INTERFACE, AND SAYS WHICH TREE RUNS (Fable 25/11, lua-core-is-a-signed-part 3 and 4).
#
# `wa --interface` is the declaration a Lua part is checked against before any pointer moves, and `wa --build-info`
# names the tree in force and a digest of its bytes. Both are answered by the binary, before the interpreter and the
# database, so a part check needs nothing running.
#
# It runs the suite's own binary: on a branch older than these two verbs it says SKIPPED by name rather than
# pretending to have checked them.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-lua-interface: $*" >&2; exit 1; }
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "FAIL test-lua-interface: WA_BIN is not an executable (the suite sets it)" >&2; exit 2; }

IFACE="$("$BIN" --interface 2>/dev/null | head -1)"
case "$IFACE" in
  *[!0-9a-f]*|'')
    # A binary older than these two verbs answers something that is not a digest ("unknown command: --interface").
    # SKIP only when the OTHER verb is missing too, so an old binary says so by name and a broken new one fails.
    if "$BIN" --build-info 2>/dev/null | grep -q '^lua_tree='; then
      fail "--interface answered '$IFACE' but --build-info has the new fields: the verb is broken"
    fi
    echo "  SKIPPED: this binary predates wa --interface and wa --build-info's lua_tree fields"
    exit 0 ;;
esac
case "$IFACE" in *[!0-9a-f]*|'') fail "--interface is not a hex digest: $IFACE";; esac
[ "${#IFACE}" = 64 ] || fail "--interface answered ${#IFACE} characters, not 64: $IFACE"
ok

INFO="$("$BIN" --build-info 2>/dev/null)"
printf '%s\n' "$INFO" | grep -q '^lua_tree=' || fail "--build-info does not name the tree in force"
printf '%s\n' "$INFO" | grep -q '^lua_tree_digest=' || fail "--build-info does not give the tree digest"
ok
TREE="$(printf '%s\n' "$INFO" | sed -n 's/^lua_tree=//p' | head -1)"
DIGEST="$(printf '%s\n' "$INFO" | sed -n 's/^lua_tree_digest=//p' | head -1)"
case "$TREE" in
  embedded) [ "$DIGEST" = '-' ] || fail "embedded must carry no digest, got $DIGEST";;
  *) case "$TREE" in *[!0-9a-f]*) fail "lua_tree is neither embedded nor a commit: $TREE";; esac
     case "$DIGEST" in *[!0-9a-f]*|'') fail "lua_tree_digest is not a digest: $DIGEST";; esac
     [ "${#DIGEST}" = 64 ] || fail "lua_tree_digest is ${#DIGEST} characters, not 64";;
esac
ok

# The declaration must BE the interface the tree manifest carries: a tree cannot claim to match a host whose
# digest differs, and the tree in force is the one this binary runs. Read-only, and only when there is one.
TREE_DIR="${WA_LUA_TREE:-$(dirname "$BIN")/lua-core}"
if [ -f "$TREE_DIR/manifest.txt" ]; then
  WANTS="$(sed -n 's/^capabilities //p' "$TREE_DIR/manifest.txt" | head -1)"
  [ "$WANTS" = "$IFACE" ] || fail "the tree in force wants $WANTS, the host declares $IFACE"
  ok
fi

echo "lua interface ok ($n checks)"
