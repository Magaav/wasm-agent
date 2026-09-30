#!/usr/bin/env bash
# Reviewer's falsification harness for scripts/check-embedded-lua-closure.mjs (I did not write the
# check).  Copies only the two things the check reads - main.rs and lua/ - into a throwaway dir, then
# mutates, runs, and restores between cases.  Nothing here touches the reviewed tree.
#
#   bash falsify-closure-check.sh <reviewed tree> <scratch dir>
set -uo pipefail

TREE="${1:?usage: falsify-closure-check.sh <reviewed tree> <scratch dir>}"
WORK="${2:?usage: falsify-closure-check.sh <reviewed tree> <scratch dir>}"

rm -rf "$WORK"
mkdir -p "$WORK/rust/wa-host/src" "$WORK/scripts"
cp "$TREE/rust/wa-host/src/main.rs" "$WORK/rust/wa-host/src/main.rs"
cp -r "$TREE/lua" "$WORK/lua"
cp "$TREE/scripts/check-embedded-lua-closure.mjs" "$WORK/scripts/"

INIT="$WORK/lua/core/init.lua"
WIRE="$WORK/lua/core/subscription_wire.lua"
cp "$INIT" "$WORK/init.orig"
cp "$WIRE" "$WORK/wire.orig"

run() { # run <label>
  echo "--- $1"
  ( cd "$WORK" && node scripts/check-embedded-lua-closure.mjs 2>&1 | tail -4 )
  echo "exit=${PIPESTATUS[0]}"
}

echo "=== baseline ==="
run "baseline (unmutated copy)"
# PIPESTATUS inside a function does not survive the subshell; re-run plainly for the exit code.
( cd "$WORK" && node scripts/check-embedded-lua-closure.mjs >/dev/null 2>&1 ); echo "baseline exit=$?"

echo
echo "=== M1: a real dofile target that is not embedded (the defect class) ==="
printf '\ndofile("lua/core/this_module_is_not_embedded.lua")\n' >> "$INIT"
run "M1 added dofile(\"lua/core/this_module_is_not_embedded.lua\") to lua/core/init.lua"
cp "$WORK/init.orig" "$INIT"
( cd "$WORK" && node scripts/check-embedded-lua-closure.mjs >/dev/null 2>&1 ); echo "M1 restored exit=$?"

echo
echo "=== M2: the same name only inside a comment (must NOT fail) ==="
printf '\n-- a comment that names dofile("lua/core/comment_only_target.lua") is not a call\n' >> "$INIT"
run "M2 comment naming dofile(\"lua/core/comment_only_target.lua\")"
cp "$WORK/init.orig" "$INIT"

echo
echo "=== M3: the same name inside a Lua long-bracket STRING (not a call) ==="
printf '\nlocal _doc = [[ dofile("lua/core/string_only_target.lua") ]]\n' >> "$INIT"
run "M3 long-bracket string containing dofile(\"lua/core/string_only_target.lua\")"
cp "$WORK/init.orig" "$INIT"

echo
echo "=== M4: the same name inside a levelled long-bracket COMMENT --[==[ ]==] (not a call) ==="
printf '\n--[==[ dofile("lua/core/levelled_comment_target.lua") ]==]\n' >> "$INIT"
run "M4 --[==[ ... ]==] comment naming dofile(\"lua/core/levelled_comment_target.lua\")"
cp "$WORK/init.orig" "$INIT"

echo
echo "=== M5: a NON-literal dofile target, wrong on purpose (the defect that started this) ==="
sed -i "s|M.CREDENTIAL_MODULE = 'lua/core/openai_sub_auth.lua'|M.CREDENTIAL_MODULE = 'lua/core/subscription_auth.lua'|" "$WIRE"
grep -n "M.CREDENTIAL_MODULE =" "$WIRE" | head -2
run "M5 subscription_wire.lua asks for the never-shipped lua/core/subscription_auth.lua"
cp "$WORK/wire.orig" "$WIRE"
( cd "$WORK" && node scripts/check-embedded-lua-closure.mjs >/dev/null 2>&1 ); echo "M5 restored exit=$?"
