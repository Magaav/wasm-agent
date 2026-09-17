#!/usr/bin/env bash
# Syntax-check the edited Lua modules the same way scripts/test.sh does:
# load() every file, report each failure. No Rust, no build.
set -uo pipefail
# Git Bash rewrites /work into C:/Program Files/Git/work before docker sees it.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
cd /c/Users/Victor/orca/workspaces/foundation/wasm-node-v2

docker run --rm -v "/c/Users/Victor/orca/workspaces/foundation/wasm-node-v2:/work:ro" -w /work \
  alpine:latest sh -c '
    apk add --no-cache lua5.4 >/dev/null 2>&1 || apk add --no-cache lua >/dev/null 2>&1
    echo "lua: $(lua -v 2>&1 || lua5.4 -v 2>&1)"
    LUA=$(command -v lua || command -v lua5.4)
    bad=0
    for f in lua/core/*.lua lua/vendor/*.lua; do
      if ! "$LUA" -e "assert(load(io.open(\"$f\"):read(\"a\"), \"@$f\"))" 2>/tmp/err; then
        echo "FAIL $f"
        cat /tmp/err
        bad=$((bad+1))
      else
        echo "ok   $f"
      fi
    done
    echo "---"
    echo "failures: $bad"
    exit $((bad > 0))
  '
