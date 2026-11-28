#!/usr/bin/env bash
# A REFUSED DEPLOY DOES NOT WRITE THE RUNNING DEPLOY'S RESULT (installer-refuses-a-target, item 6 - 25/11)
#
# MEASURED: a deploy refused before it touched anything (deploy_alive_held, the deploy lock, a preflight refusal) still
# called fail(), which rewrote $INSTALL_DIR/deploy-result.json. The follower of the FIRST deploy claims that record by its
# timestamp, so a hand-run second deploy could make a running install say "failed".
#
# This row does it on a fixture install dir: a sentinel `deploy-result.json` is planted, the deploy is started in a way that
# refuses BEFORE it can take the running-state record, and the file must come back **byte for byte** unchanged - while the
# refusal is still printed, logged, and exits non-zero.
#
# Fences: INSTALL_DIR, log, protocol and the alive directory are all under one scratch dir; nothing on the live node is read
# or written; no manager is touched (no systemd-run in this path at all).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
S="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-refusal.XXXXXX")"
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }

INSTALL="$S/install"; mkdir -p "$INSTALL"
RESULT="$INSTALL/deploy-result.json"
printf '%s\n' '{"verdict":"installed","problems":0,"ok":true,"commit":"the-first-deploy","detail":"the install that is running"}' > "$RESULT"
BEFORE="$(sha256sum "$RESULT" | cut -d' ' -f1)"
ok "a fixture install dir holds the running deploy's result"

# A deploy that is turned away before it can take the running-state record: the alive directory already holds another
# deploy's record, which is the measured refusal (deploy_alive_held).
ALIVE="$S/alive"; mkdir -p "$ALIVE"
printf '{"pid":999999,"commit":"the-first-deploy","at":%s}\n' "$(date +%s)" > "$ALIVE/alive.json" 2>/dev/null || true

# THE TURN GUARD IS THE MEASURED REFUSAL (25/11): a turn on the node it would replace cannot deploy - and that refusal
# happens BEFORE the deploy can take the running-state record, which is exactly the case item 6 is about.
out=$(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE \
  HOME="$S/home" WASM_AGENT_HOME="$S/home" WASM_AGENT_MANAGED=0 WASM_AGENT_IN_TURN=1 \
  WA_INSTALL_DIR="$INSTALL" WA_DEPLOY_ALIVE_DIR="$ALIVE" \
  timeout 60 bash scripts/deploy.sh --reason 'row: a refused deploy' 2>&1); rc=$?

if [ "$rc" -ne 0 ]; then ok "the refused deploy exits non-zero (rc=$rc)"; else bad "the refused deploy exited 0"; fi
AFTER="$(sha256sum "$RESULT" | cut -d' ' -f1)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "the running deploy's result is byte-identical after the refusal"
else
  bad "the refused deploy rewrote the running deploy's result ($BEFORE -> $AFTER): $(head -c 140 "$RESULT")"
fi
if printf '%s' "$out" | grep -qiE 'cannot deploy|needs a sentinel|refused|held'; then
  ok "and it says why: $(printf '%s' "$out" | grep -iE 'cannot deploy|needs a sentinel|refused|held' | head -1 | cut -c1-90)"
else
  bad "the refusal was silent: $(printf '%s' "$out" | head -c 120)"
fi

if [ "$failed" -gt 0 ]; then echo "deploy-refusal-keeps-the-result: FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "deploy-refusal-keeps-the-result ok ($checks checks)"
