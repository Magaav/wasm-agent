#!/usr/bin/env bash
# VERSION FOLDERS ON A SCRATCH NODE, WITH THE REAL upgrade.sh (Fable 27/11: the gate before the switch).
#
# WHAT IS REAL: scripts/versions-adopt.sh, scripts/lib/versions.sh, scripts/version-sequence.sh and the **real
# scripts/upgrade.sh** - not the stub `test-version-sequence.sh` uses. THE OPEN BLOCKER NAMED HERE IS NOW CLOSED: the
# sequence needs upgrade.sh, upgrade.sh refuses unless `sentinel_supervises` is true, and until now no sentinel could be
# started inside a node turn - it said "inside <unit>, which cannot be shown to own this watcher". That refusal names its
# own settlement, and the row uses it: `WA_SENTINEL_SUPERVISOR=none` (nothing outside owns the watcher, so the stop file
# is a real stop). Measured on this node: `start rc=0`, `sentinel: up watching (pid N)`,
# and the predicate `^ *sentinel: *up` matches.
#
# Deliberately NOT here yet: the restart half, which needs a live node the installer starts and waits on. The row says so
# by name instead of pretending (SKIP version-folders-restart: ...).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/scratch-env.sh

n=0
ok()  { n=$((n+1)); printf '  ok   %s\n' "$*"; }
fail(){ echo "FAIL test-version-folders-real-upgrade: $*" >&2; exit 1; }

WA_BIN="${WA_TEST_BINARY:-${HOME}/.local/bin/wa}"
SENTINEL="${WA_SENTINEL_BINARY:-${HOME}/.local/bin/wa-sentinel}"
if [ ! -x "$WA_BIN" ] || [ ! -x "$SENTINEL" ]; then
  echo 'SKIP version-folders-real-upgrade: needs an installed wa and wa-sentinel (WA_TEST_BINARY / WA_SENTINEL_BINARY)'; exit 0
fi

BASE="${WA_ROW_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W=$(mktemp -d "$BASE/wa-vfreal-XXXXXX") || { echo 'FAIL: no scratch' >&2; exit 2; }
cleanup() {
  WA_SENTINEL_SUPERVISOR=none "$SENTINEL" stop >/dev/null 2>&1
  WA_SENTINEL_SUPERVISOR=none "$SENTINEL" stop >/dev/null 2>&1
  chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"
}
trap cleanup EXIT
wa_scratch_env_apply "$W" >/dev/null
wa_scratch_env_check "$W" >/dev/null || fail 'the row environment is NOT isolated'
ok 'scratch node isolated (scratch_env)
'
# THE INSTALL: a real program and a record, which the conversion refuses to do without
INSTALL="$W/install"; mkdir -p "$INSTALL"
cp "$WA_BIN" "$INSTALL/wa"; cp "$WA_BIN" "$INSTALL/wa-term"
cp "$SENTINEL" "$INSTALL/wa-sentinel"
COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'commit=%s\nbranch=main\nvia=linux-bootstrap\n' "$COMMIT" > "$INSTALL/installed.txt"
SHARE="$W/share"; mkdir -p "$SHARE"
export WA_SHARE_ROOT="$SHARE"

# 1 CONVERT, by the real script
bash scripts/versions-adopt.sh --install "$INSTALL" >"$W/adopt.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok 'step 1 the real versions-adopt converted the install' \
  || fail "versions-adopt exited $rc: $(tail -2 "$W/adopt.log" | tr '\n' ' ')"
[ -d "$SHARE/versions/aaaaaaaaaaaa" ] && ok 'and the version folder is there' || fail 'no version folder after the conversion'
CUR="$(readlink "$SHARE/versions/current" 2>/dev/null || readlink "$SHARE/current" 2>/dev/null)"
case "$CUR" in *aaaaaaaaaaaa*) ok "and current names it ($CUR)" ;; *) fail "current does not name the version: '${CUR:-<none>}'" ;; esac

# 2 THE GATE upgrade.sh enforces, and the standard that satisfies it on a scratch node
export WA_SENTINEL_SUPERVISOR=none
"$SENTINEL" start >"$W/sentinel-start.log" 2>&1 || fail "the sentinel did not start: $(tail -2 "$W/sentinel-start.log")"
STATUS="$("$SENTINEL" status 2>&1)"
printf '%s\n' "$STATUS" | grep -qE '^ *sentinel: *up' && ok 'step 2 the real sentinel says up on the scratch node' \
  || fail "the sentinel is not up: $(printf '%s' "$STATUS" | head -2 | tr '\n' ' ')"
printf '%s\n' "$STATUS" | grep -qE 'supervisor: *none' && ok 'and it records that nothing outside owns it' \
  || fail 'the supervisor line does not say none'
# the SAME predicate upgrade.sh tests, read from its own library
. scripts/lib/turn-guard.sh
if declare -F sentinel_supervises >/dev/null; then
  sentinel_supervises "$INSTALL" && ok "and upgrade.sh's own predicate accepts it (no refusal at :842)" \
    || fail 'sentinel_supervises still refuses the scratch node'
else
  fail 'sentinel_supervises is not in scripts/lib/turn-guard.sh any more: this row tests a predicate that moved'
fi

# 3 STAGING, by the REAL upgrade.sh (no swap, no restart in this mode)
STAGE="$SHARE/versions/.stage-aaaaaaaaaaaa"; mkdir -p "$STAGE"
CANDIDATE="$W/candidate/wa" CAND_TERM="$W/candidate/wa-term"
mkdir -p "$W/candidate"; cp "$WA_BIN" "$CANDIDATE"; cp "$WA_BIN" "$CAND_TERM"
# THE PAIR RULE, refusing as designed: upgrade.sh will not stage a wa whose operations supervisor is missing
# (operations_supervisor_missing), so the candidate carries one. This row met that refusal before it met the gate.
SUPERVISOR="${WA_SUPERVISOR_BINARY:-${HOME}/.local/bin/wa-operations-supervisor}"
# A working tree keeps it under a cargo target directory, not on PATH: the newest one wins.
if [ ! -x "$SUPERVISOR" ]; then
  for candidate_sup in "$(dirname "$0")/../rust/target/release/wa-operations-supervisor"                        $(ls -t "$(dirname "$0")"/../rust/target/*/release/wa-operations-supervisor 2>/dev/null | head -1); do
    [ -x "$candidate_sup" ] && SUPERVISOR="$candidate_sup" && break
  done
fi
if [ -x "$SUPERVISOR" ]; then cp "$SUPERVISOR" "$W/candidate/wa-operations-supervisor"
else echo 'SKIP version-folders-real-upgrade: no wa-operations-supervisor to pair with the candidate'; exit 0; fi
WA_INSTALL_DIR="$INSTALL" WA_UPGRADE_TERM="$CAND_TERM" WA_VERSION_STAGING="$STAGE" timeout 180   bash scripts/upgrade.sh "$CANDIDATE" >"$W/stage.log" 2>&1
src=$?
HELD=$(ls -A "$STAGE" 2>/dev/null | tr '\n' ' ')
echo "  stage rc=$src; staged: ${HELD:-<nothing>}"
# THE EXIT CODE MATTERS: a staged tree that exits non-zero is a HALF-STAGED version, and the sequence would seal it
# while looking complete. So the row names the reason rather than accepting the files.
[ "$src" = 0 ] && ok 'step 3 the real upgrade.sh staged AND exited 0' \
  || fail "staging exited $src with '${HELD}' staged: $(grep -v '^$' "$W/stage.log" | tail -3 | tr '\n' ' ')"
case "$HELD" in *wa*) ok 'and the staged tree holds the program' ;; *) fail "nothing was staged (rc $src): $(tail -3 "$W/stage.log" | tr '\n' ' ')" ;; esac
grep -qi 'sentinel_supervises\|cannot be shown to own' "$W/stage.log" \
  && fail 'the staging run still hit the sentinel gate - the settlement did not take' \
  || ok 'and it got past the sentinel gate (no refusal in its log)'

printf 'version folders, real upgrade.sh: %d checks\n' "$n"
echo 'version folders, real upgrade.sh ok'
