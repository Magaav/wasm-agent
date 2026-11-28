#!/usr/bin/env bash
# THE BUNDLE WINS OVER THE TREE (decision 27/11, law 17), proven on a real `wa update`.
#
# The channel row proves the probe accepts a plan. This one proves the DECISION: with a stub updater installed
# (`<install>/scripts/install.sh`, the single file `M.installed_updater` tests) and a tree also present, `wa update` takes
# the bundle path - the stub runs - instead of `scripts/deploy.sh`. No signing, no bundle, no network, no sentinel: the
# scratch home has none, so the deploy half refuses harmlessly if it is ever reached, which is itself the "wrong path"
# signal.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${WA_BIN:-$ROOT/rust/target/release/wa}
[ -x "$BIN" ] || { echo 'SKIP update-prefers-the-bundle: no wa binary (set WA_BIN)'; exit 0; }
case "${TMPDIR:-/tmp}" in /home/*/.wasm-agent/*) TMPBASE="${TMPDIR}" ;; *) TMPBASE="$ROOT/.tmp" ;; esac
mkdir -p "$TMPBASE"; W=$(mktemp -d "$TMPBASE/wa-pref.XXXXXX") || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
cleanup() { if [ "$failed" -gt 0 ]; then printf 'preference row: scratch kept at %s\n' "$W"; else rm -rf "$W"; fi; }
trap cleanup EXIT

HOME_DIR="$W/home"; mkdir -p "$HOME_DIR"
INSTALL="$W/install"; mkdir -p "$INSTALL/scripts"
# the tree: this checkout, so a deploy WOULD be possible if the decision went the other way
TREE="$W/tree"; git init -q "$TREE"; git -C "$TREE" config user.email row; git -C "$TREE" config user.name row
printf 'x\n' > "$TREE/f"; git -C "$TREE" add f; git -C "$TREE" commit -qm init; git -C "$TREE" branch -M main
SHORT=$(git -C "$TREE" rev-parse HEAD | cut -c1-12)
printf 'commit=%s\nbranch=main\nvia=linux-bootstrap\n' "$SHORT" > "$INSTALL/installed.txt"
# the stub updater: answers the plan, and leaves a marker when the INSTALL runs
cat > "$INSTALL/scripts/install.sh" <<SH
#!/bin/sh
touch "$W/stub-checked"
for a in "\$@"; do
  case "\$a" in
    --check) echo "bootstrap: install $INSTALL: update"; echo "would install node-$SHORT"; exit 0 ;;
  esac
done
touch "$W/stub-installing"   # the install half was reached
sleep 30                    # long enough that the row can see it chose the bundle and stop it
SH
chmod +x "$INSTALL/scripts/install.sh"

env HOME="$HOME_DIR" WASM_AGENT_HOME="$HOME_DIR" WASM_AGENT_DB="$HOME_DIR/.wasm-agent/memory.db" \
    WA_INSTALL_DIR="$INSTALL" WASM_AGENT_LUA_ROOT="$ROOT" \
    "$BIN" --db "$HOME_DIR/ledger.db" update --detach > "$W/out.txt" 2>&1
CODE=$?
# WITHOUT A SENTINEL THE UPDATE STOPS BEFORE SWAPPING - by design, and before it ever reaches the tree. What this row is
# about is WHICH CHANNEL WAS CHOSEN, so the refusal is expected; a deploy refusal would be the wrong answer.
[ "$CODE" != 0 ] && ok "wa update refused without a sentinel (exit $CODE), as it should" \
  || bad 'wa update did not refuse a node with no sentinel'
[ -f "$W/stub-checked" ] && ok 'the stub UPDATER was asked (the bundle channel is the one chosen)' \
  || bad "the stub updater was never asked: $(head -2 "$W/out.txt" | tr '\n' ' ')"
grep -qi 'sentinel' "$W/out.txt" && ok 'and the refusal names the sentinel precondition' \
  || bad "the refusal names no sentinel: $(head -2 "$W/out.txt" | tr '\n' ' ')"
# THE DECISION ITSELF: the deploy's own words must not appear, because the tree must not have been chosen.
grep -qiE 'installing through upgrade|deploy started|--- deploy ' "$W/out.txt" \
  && bad 'a deploy step was taken: the tree won over the bundle' \
  || ok 'and no deploy step was taken (the tree did not win)'

printf 'update prefers the bundle: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'update prefers the bundle ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
