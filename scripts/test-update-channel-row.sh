#!/usr/bin/env bash
# WHICH PATH AN UPDATE TAKES, PROVEN WITH A STUB UPDATER (decision 27/11, law 17).
#
# A published bundle for this commit+target wins over a tree install; with no bundle the source path is taken; and the
# refusal says which. No signing, no bundle, no network: `M.installed_updater` tests exactly one file -
# `<install>/scripts/install.sh` - so a stub in that place answers the plan the update reads.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${WA_BIN:-$ROOT/rust/target/release/wa}
[ -x "$BIN" ] || { echo 'SKIP update-channel-row: no wa binary (set WA_BIN)'; exit 0; }
case "${TMPDIR:-/tmp}" in /home/*/.wasm-agent/*) TMPBASE="${TMPDIR}" ;; *) TMPBASE="$ROOT/.tmp" ;; esac
mkdir -p "$TMPBASE"; W=$(mktemp -d "$TMPBASE/wa-chan.XXXXXX") || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
cleanup() { if [ "$failed" -gt 0 ]; then printf 'channel row: scratch kept at %s\n' "$W"; else rm -rf "$W"; fi; }
trap cleanup EXIT

# a scratch tree, so BOTH paths are available and the choice is real
git init -q "$W/tree"; cd "$W/tree"
git config user.email row; git config user.name row
echo x > f; git add f; git commit -qm init; git branch -M main
TARGET=$(git rev-parse HEAD)
SHORT=$(printf %s "$TARGET" | cut -c1-12)

stub() { # <install dir> <state>
  mkdir -p "$1/scripts"
  cat > "$1/scripts/install.sh" <<SH
#!/bin/sh
# the plan the update parses, and a marker so the row can see this file ran
touch "$W/stub-ran"
for a in "\$@"; do case "\$a" in --check) echo "bootstrap: install $1: $2"; echo "would install node-$SHORT"; exit 0 ;; esac; done
exit 0
SH
  chmod +x "$1/scripts/install.sh"
}
run_update() { # <home> <install>
  : > "$W/out.txt"
  env HOME="$1" WASM_AGENT_HOME="$1" WASM_AGENT_DB="$1/.wasm-agent/memory.db" \
      WA_INSTALL_DIR="$2" WASM_AGENT_LUA_ROOT="$ROOT" \
      "$BIN" --db "$1/ledger.db" update --check > "$W/out.txt" 2>&1
  CODE=$?
}

# ---- 1. a published bundle (state update) is asked, with a tree present -------------------------
H1="$W/h1"; mkdir -p "$H1"; I1="$W/i1"; mkdir -p "$I1"
printf 'commit=%s\nbranch=main\nvia=linux-bootstrap\n' "$SHORT" > "$I1/installed.txt"
stub "$I1" update
run_update "$H1" "$I1"
[ -f "$W/stub-ran" ] && ok 'the stub updater was asked (the bundle path is reachable on a real plan)' \
  || bad 'the stub updater was never asked: the probe did not accept a "update" plan'
rm -f "$W/stub-ran"

# ---- 2. no bundle (state current): the source path is the answer, and it is named ---------------
H2="$W/h2"; mkdir -p "$H2"; I2="$W/i2"; mkdir -p "$I2"
printf 'commit=%s\nbranch=main\nvia=linux-bootstrap\n' "$SHORT" > "$I2/installed.txt"
stub "$I2" current
run_update "$H2" "$I2"
[ -f "$W/stub-ran" ] && ok 'with a "current" plan the updater is still asked (it answered: nothing to install)' \
  || bad 'the updater was not asked at all'
grep -qiE 'current|up to date|already' "$W/out.txt" && ok 'and the answer says there is nothing to install' \
  || bad "the answer names neither: $(head -2 "$W/out.txt" | tr '\n' ' ')"

printf 'update channel row: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'update channel row ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
