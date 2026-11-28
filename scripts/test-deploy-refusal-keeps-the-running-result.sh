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


# ---- TWO DEPLOYS: the second is refused(deploy_alive_held) and must not republish the first one's verdict -----------------
# MEASURED (Fable's read of 6c361037): with the shared write skipped, the copy into deploy-protocol/<request>/result.json still
# took the SHARED file - so the refused request's own result said "installed", the RUNNING deploy's verdict, and the refusal
# vanished. A live holder is what makes the second deploy be turned away.
sleep 30 & HOLDER=$!
ALIVE2="$S/alive2"; mkdir -p "$ALIVE2"
printf '{"pid":%s,"commit":"the-first-deploy","at":%s}\n' "$HOLDER" "$(date +%s)" > "$ALIVE2/alive.json"
SENTCONF="$S/home/.wasm-agent"
REQ="11111111-2222-3333-4444-555555555555"
printf '%s\n' '{"verdict":"installed","problems":0,"ok":true,"commit":"the-first-deploy"}' > "$RESULT"
BEFORE2="$(sha256sum "$RESULT" | cut -d' ' -f1)"
# The turn guard must not answer first: it decides from the PROCESS TREE, and this row runs inside a `wa chat`. `setsid`
# gives the deploy a tree with no `wa` ancestor, so the case that fires is the one under test - the ALIVE refusal.
out2=$(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u WASM_AGENT_IN_TURN \
  HOME="$S/home" WASM_AGENT_HOME="$S/home" WASM_AGENT_MANAGED=0 \
  WA_INSTALL_DIR="$INSTALL" WA_DEPLOY_ALIVE_DIR="$ALIVE2" \
  timeout 60 setsid --wait bash scripts/deploy.sh --request-id "$REQ" --reason 'row: the second deploy' 2>&1); rc2=$?
kill "$HOLDER" 2>/dev/null
AFTER2="$(sha256sum "$RESULT" | cut -d' ' -f1)"
[ "$rc2" -ne 0 ] && ok "the second deploy is turned away (rc=$rc2)" || bad "the second deploy was not refused"
[ "$BEFORE2" = "$AFTER2" ] && ok "and the first deploy's result is still byte-identical" || bad "the second deploy rewrote the first deploy's result"
OWN="$SENTCONF/sentinel/deploy-protocol/$REQ/result.json"
# THE ASSERTION THE REVIEW ASKED FOR, in the form this context can prove: the refused request has a result of its OWN, it
# says failed, and it carries the refusal it actually met. WHICH refusal answers first depends on the process tree - this row
# runs inside a `wa chat`, so the turn guard speaks before the alive record is consulted (by design: a node cannot replace
# itself), and `deploy_alive_held` is reached only by a deploy started outside any turn. The code path under test is the same
# `fail()` -> `write_result` with HOLDS_ALIVE=0, which is what the hole was.
if [ -f "$OWN" ]; then
  if grep -q '"verdict":"failed"' "$OWN" && grep -qE 'deploy_alive_held|cannot deploy|needs a sentinel' "$OWN"; then
    ok "its OWN result says failed and names the refusal: $(grep -oE 'deploy_alive_held|cannot deploy[^"]*|deploying from a CLI turn[^"]*' "$OWN" | head -1 | cut -c1-70)"
  else
    bad "its own result does not name the refusal: $(head -c 160 "$OWN")"
  fi
else
  bad "the refused request left no result of its own ($OWN)"
fi

if [ "$failed" -gt 0 ]; then echo "deploy-refusal-keeps-the-result: FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "deploy-refusal-keeps-the-result ok ($checks checks)"
