#!/usr/bin/env bash
# MEASUREMENT (mission update-is-one-line, step 1): WHAT DOES "wa update" PRINT, VERBATIM AND TIMED?
#
# Not a test: it produces evidence. It builds a scratch node (own HOME, own WASM_AGENT_DATA, own install
# directory, stub sentinel, stub deploy) and drives the REAL `wa update` through it. Every line is
# timestamped the moment it arrives on the pipe, so "ms to the first byte" is measurable.
#
# Usage: measure/update-lines.sh <case> [lines-in-deploy-out]
#   case: build | published | fail | problems | release-current | release-queued
set -uo pipefail
CASE="${1:?case}"
DEPLOY_LINES="${2:-7000}"
WT=/home/victor/Work/missions/update-is-one-line/wt
BIN=${WA_BIN:-/home/victor/.local/bin/wa}
[ -x "$BIN" ] || { echo "no wa at $BIN"; exit 1; }
OUTROOT=/home/victor/Work/missions/update-is-one-line/measure/evidence
mkdir -p "$OUTROOT" || exit 1
. "$WT/scripts/lib/scratch-home.sh"

W="$(mktemp -d /home/victor/Work/missions/update-is-one-line/measure/run-"$CASE"-XXXXXX)" || exit 1
HOME_DIR="$W/home"; INST="$W/install"; TREE="$W/tree"; SANDBOX="$HOME_DIR/.wasm-agent"; SENT="$SANDBOX/sentinel"
wa_scratch_home_guard "$HOME_DIR" || exit 2
mkdir -p "$HOME_DIR" "$INST" "$TREE/rust/target/release" "$SENT"/{requests,queue,done,failed,claimed} || exit 1
printf 'rust/target/\n' > "$TREE/.gitignore"

# ---- the runtime tree: two commits, main's tip newer than the published one -------------------------
(
  cd "$TREE" || exit 1
  echo fixture > file.txt
  git init -q --initial-branch=main . || exit 1
  git add file.txt .gitignore || exit 1
  git -c user.email=fixture@local -c user.name=fixture commit -qm 'published fixture' || exit 1
  git init -q --bare "$W/origin.git" || exit 1
  git remote add origin "$W/origin.git" || exit 1
  git push -q origin main || exit 1
  echo second > second.txt
  git add second.txt || exit 1
  git -c user.email=fixture@local -c user.name=fixture commit -qm 'unpublished fixture' || exit 1
  git push -q origin main || exit 1
  git checkout -q -b tree || exit 1
)
PUBLISHED="$(git -C "$TREE" rev-parse HEAD~1)"
TARGET="$(git -C "$TREE" rev-parse HEAD)"
T12="$(printf '%s' "$TARGET" | cut -c1-12)"
P12="$(printf '%s' "$PUBLISHED" | cut -c1-12)"
printf '%s\n' "$TREE" > "$INST/runtime-worktree.txt"
printf 'commit=%s\nsource_commit_hint=%s\n' "$T12" "$T12" > "$INST/installed.txt"

# ---- the release list: in the "published" case it names the TARGET with this triple's assets --------
NOWMS="$(($(date +%s) * 1000))"
if [ "$CASE" = published ]; then NAMED="$T12"; else NAMED="$P12"; fi
cat > "$SANDBOX/update-check.json" <<CL
{"schema":2,"checked_at":$NOWMS,"last_ok_at":$NOWMS,"repo":"fixture/fixture","transport":"fixture","window":[{"tag":"node-$NAMED","name":"node-$NAMED","sha12":"$NAMED","published_at":"2026-11-25T10:00:00Z","assets":{"node-$NAMED.manifest":true,"wa-x86_64-unknown-linux-gnu-$NAMED":true,"wa-sentinel-x86_64-unknown-linux-gnu-$NAMED":true}}]}
CL

# ---- the stub deploy: writes the SAME files a real one writes, and a REAL-SIZED deploy.out ---------
# work's real deploy.out held 7571 lines, 225 of them matching error|warn|refused|fail (Fable 25/11
# 09:11Z). This fixture writes that many lines with that kind of alarming word, so "does any of it reach
# the screen" is answered against a log of the real shape.
STUBDEPLOY="$W/stub-deploy.sh"
cat > "$STUBDEPLOY" <<'DEPLOY'
#!/bin/sh
id="$1"; outcome="$2"
started=$(date +%s)
printf -- '--- deploy detached at %s script %s reason fixture update ---\n' "$started" "$0"
write_status() {
  printf '{"state":"%s","phase":"%s","done":%s,"total":456,"crate":"%s","commit":"%s","started_at":%s,"at":%s}\n' \
    "$1" "$2" "$3" "$4" "$T12" "$started" "$(date +%s)" > "$FIXTURE_STATUS.tmp" && mv -f "$FIXTURE_STATUS.tmp" "$FIXTURE_STATUS"
}
write_queue() {
  printf '{"schema":1,"id":"%s","verb":"deploy","state":"%s","phase":"%s","detail":"%s","queued_at":%s,"updated_at":%s,"attempts":1}\n' \
    "$id" "$1" "$2" "$3" "$started" "$(date +%s)" > "$FIXTURE_QUEUE/$id.json.tmp" && mv -f "$FIXTURE_QUEUE/$id.json.tmp" "$FIXTURE_QUEUE/$id.json"
}
write_queue running spawned "deploy started detached"
i=0
while [ "$i" -lt "$FIXTURE_LOG_LINES" ]; do
  i=$((i + 1))
  case $((i % 34)) in
    0) printf 'warning: unused variable at crate %s\n' "$i" ;;
    3) printf 'error: could not compile some-crate (lib) due to 1 previous error\n' ;;
    5) printf '   Compiling wa-host v0.1.2\n' ;;
    *) printf '   Compiling crate-%s v0.1.0\n' "$i" ;;
  esac
done >> "$FIXTURE_DEPLOYOUT"
if [ "${FIXTURE_DECLARE:-none}" = "build" ]; then
  echo 'deploy: no published binary for this commit; building this tree (disk floor ok)' >> "$FIXTURE_DEPLOYOUT"
  write_status building preflight 0 ""
  sleep "${FIXTURE_STEP:-0}"
  write_status building compiling 12 "provisioning"
  sleep "${FIXTURE_STEP:-0}"
  write_status building compiling 48 "wa-host"
  sleep "${FIXTURE_STEP:-0}"
  write_status building proving 456 ""
  sleep "${FIXTURE_STEP:-0}"
else
  echo 'deploy: installing the published binary; the prove gate below runs on it, then upgrade.sh' >> "$FIXTURE_DEPLOYOUT"
  write_status building installing 0 ""
  sleep "${FIXTURE_STEP:-0}"
fi
if [ "$outcome" = "fail" ]; then
  echo 'deploy: refused(no_built_binary): nothing is built at this install path, and this deploy was told not to build' >> "$FIXTURE_DEPLOYOUT"
  printf '{"ok":false,"verdict":"failed","commit":"","detail":"compiling: no built binary at %s/release/wa","at":"%s","request_id":"%s"}\n' \
    "$FIXTURE_BUILD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" > "$FIXTURE_RESULT.tmp" && mv -f "$FIXTURE_RESULT.tmp" "$FIXTURE_RESULT"
  write_status failed "compiling: no built binary at $FIXTURE_BUILD/release/wa" 48 ""
  write_queue failed spawned "deploy ended"
  exit 1
fi
if [ "${FIXTURE_PROBLEM:-0}" = 1 ]; then
  printf '{"ok":false,"verdict":"installed_with_problems","problems":1,"commit":"%s","detail":"the sentinel could not be restarted after the swap","at":"%s","request_id":"%s"}\n' \
    "$T12" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" > "$FIXTURE_RESULT.tmp" && mv -f "$FIXTURE_RESULT.tmp" "$FIXTURE_RESULT"
else
  printf '{"ok":true,"verdict":"installed","commit":"%s","branch":"tree","node_sha256":"deadbeef","sentinel_sha256":"deadbeef","watcher_pid":"4242","detail":"installed %s; watcher 4242","reason":"fixture","at":"%s","request_id":"%s","expected_sha":"","phases":[]}\n' \
    "$T12" "$T12" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" > "$FIXTURE_RESULT.tmp" && mv -f "$FIXTURE_RESULT.tmp" "$FIXTURE_RESULT"
fi
printf 'commit=%s\nsource_commit_hint=%s\nbinary_source=prebuilt-fixture\n' "$T12" "$T12" > "$FIXTURE_INSTALLED"
write_status installed "" 456 ""
write_queue done spawned "deploy ended"
exit 0
DEPLOY
chmod +x "$STUBDEPLOY"

cat > "$INST/wa-sentinel" <<'STUB'
#!/bin/sh
if [ "$1" = "preflight" ]; then
  echo '{"schema":1,"watcher":"running","watcher_pid":4242,"ownership":"watcher_lifetime_lock","stop_file":false,"pending_deploys":[],"inventory_verified":true,"capabilities":{"health_free":true,"atomic_deploy_dedupe":true}}'
  exit 0
fi
if [ "$1" = "request" ] && [ "$2" = "deploy" ]; then
  id="$(date +%s%N)-$$-1"
  id="$(printf '%s' "$id" | tr -cd '0-9a-zA-Z-')"
  printf '{"verb":"deploy","reason":"fixture update","queued_at":%s,"session":"","prompt":""}\n' "$(date +%s)" > "$FIXTURE_REQUESTS/$id.json"
  echo "  requested deploy: $FIXTURE_REQUESTS/$id.json"
  setsid "$FIXTURE_STUBDEPLOY" "$id" "$FIXTURE_OUTCOME" >> "$FIXTURE_DEPLOYOUT" 2>&1 </dev/null &
  echo $! >> "$FIXTURE_PIDS"
  exit 0
fi
echo "unknown verb" >&2
exit 2
STUB
chmod +x "$INST/wa-sentinel"

# ---- a git wrapper: every git call this command makes is recorded, so "before the first line" is countable
mkdir -p "$W/bin"
cat > "$W/bin/git" <<'GIT'
#!/bin/sh
printf '%s\n' "$*" >> "$MEASURE_GIT_LOG"
exec /usr/bin/git "$@"
GIT
chmod +x "$W/bin/git"

# ---- a release-installed node: no runtime tree, an install record, install.sh as the updater --------
if [ "$CASE" = release-current ] || [ "$CASE" = release-queued ]; then
  rm -f "$INST/runtime-worktree.txt"
  printf 'commit=%s\nrelease=node-%s\nvia=linux-bootstrap\n' "$P12" "$P12" > "$INST/installed.txt"
  STATE=current; [ "$CASE" = release-queued ] && STATE=update
  mkdir -p "$INST/scripts"
  {
    echo '#!/bin/sh'
    echo 'if [ "$1" = "--check" ]; then echo "bootstrap: install '"$INST"': '$STATE' (would install node-'"$T12"')"; exit 0; fi'
    echo 'sleep 5'
    echo 'exit 0'
  } > "$INST/scripts/install.sh"
  chmod +x "$INST/scripts/install.sh"
  # systemd-run is stubbed so this measurement starts no unit on the operator's machine: it answers the
  # way a successful start does (exit 0) and records its arguments.
  cat > "$W/bin/systemd-run" <<'SR'
#!/bin/sh
printf '%s\n' "$*" >> "$SR_LOG"
printf 'Running timer as unit: %s\n' "$*"
exit 0
SR
  chmod +x "$W/bin/systemd-run"
fi

export WA_UPDATE_CHECK=0 WA_OFFLINE=1
# the "current" case measures the fast path: its origin is a LOCAL bare repo, so the ONE request it makes
# (git ls-remote) is real and local. Every other case keeps the network off.
[ "$CASE" = current ] && unset WA_OFFLINE
[ "$CASE" = release-current ] || [ "$CASE" = release-queued ] && export WA_UPDATE_FOLLOW_BOUND="${FOLLOW_BOUND:-5}"
export FIXTURE_STATUS="$SANDBOX/build-status.json" FIXTURE_QUEUE="$SENT/queue" \
  FIXTURE_RESULT="$INST/deploy-result.json" FIXTURE_INSTALLED="$INST/installed.txt" \
  FIXTURE_REQUESTS="$SENT/requests" FIXTURE_DEPLOYOUT="$SENT/deploy.out" FIXTURE_PIDS="$W/pids" \
  FIXTURE_STUBDEPLOY="$STUBDEPLOY" FIXTURE_BUILD="$SANDBOX/build/target/deploy-$T12" T12="$T12" \
  FIXTURE_LOG_LINES="$DEPLOY_LINES" FIXTURE_STEP="${STEP:-1.2}"
: > "$W/pids"
FIXTURE_DECLARE=published; FIXTURE_OUTCOME=ok; FIXTURE_PROBLEM=0
case "$CASE" in
  current) FIXTURE_DECLARE=published; printf 'commit=%s\nsource_commit_hint=%s\n' "$T12" "$T12" > "$INST/installed.txt" ;;
  build) FIXTURE_DECLARE=build ;;
  fail) FIXTURE_DECLARE=build; FIXTURE_OUTCOME=fail ;;
  problems) FIXTURE_DECLARE=build; FIXTURE_PROBLEM=1 ;;
esac
export FIXTURE_DECLARE FIXTURE_OUTCOME FIXTURE_PROBLEM

# ---- the runner: argv, then every line timestamped the moment it arrives ----------------------------
cat > "$W/tap.py" <<'PY'
import sys, time
t0 = float(sys.argv[1])
while True:
    line = sys.stdin.readline()
    if not line:
        break
    sys.stdout.write("%9.3f  %s" % (time.monotonic() - t0, line if line.endswith("\n") else line + "\n"))
    sys.stdout.flush()
PY

printf '%s\n' "env WASM_AGENT_DATA=$SANDBOX WASM_AGENT_HOME=$HOME_DIR WA_INSTALL_DIR=$INST WASM_AGENT_LUA_ROOT=$WT $BIN --db $W/node.db update" > "$OUTROOT/$CASE.argv.txt"
T0="$(python3 -c 'import time; print(repr(time.monotonic()))')"
env WASM_AGENT_DATA="$SANDBOX" WASM_AGENT_HOME="$HOME_DIR" WA_INSTALL_DIR="$INST" \
  WASM_AGENT_LUA_ROOT="$WT" PATH="$W/bin:$PATH" SR_LOG="$OUTROOT/.sr.log" MEASURE_GIT_LOG="$W/git.log" \
  "$BIN" --db "$W/node.db" update 2>&1 | python3 "$W/tap.py" "$T0" > "$W/timed.txt"
CODE=${PIPESTATUS[0]}
LAST_AT="$(awk 'END{print $1}' "$W/timed.txt")"
LINES=$(wc -l < "$W/timed.txt")
PLAIN="$W/plain.txt"; sed -E 's/^ *[0-9]+\.[0-9]{3}  //' "$W/timed.txt" > "$PLAIN"
ALARM=$(grep -Eic 'error|warn|refus|fail|problem' "$PLAIN" || true)
GIT_CALLS=$(wc -l < "$W/git.log" 2>/dev/null || echo 0)
MEASURE_GIT_LOG_DUMP=$(tr '\n' '|' < "$W/git.log" 2>/dev/null || true)
DEPLOYOUT_LINES=$(wc -l < "$SENT/deploy.out" 2>/dev/null || echo 0)
DEPLOYOUT_ALARM=$(grep -Eic 'error|warn|refus|fail|problem' "$SENT/deploy.out" 2>/dev/null || true)
echo "case=$CASE deploy_out_lines=$DEPLOYOUT_LINES deploy_out_alarming_lines=$DEPLOYOUT_ALARM"
echo "printed_lines=$LINES printed_alarming_lines=$ALARM exit=$CODE last_line_at_s=$LAST_AT git_calls=$GIT_CALLS [$MEASURE_GIT_LOG_DUMP]"
echo '--- verbatim (arrival time in seconds from Enter, then the line) ---'
cat "$W/timed.txt"
echo '--- end ---'
cp "$PLAIN" "$OUTROOT/$CASE.printed.txt"
cp "$W/timed.txt" "$OUTROOT/$CASE.timed.txt"
cp "$SENT/deploy.out" "$OUTROOT/$CASE.deploy.out" 2>/dev/null || true
echo "case=$CASE deploy_out_lines=$DEPLOYOUT_LINES deploy_out_alarming_lines=$DEPLOYOUT_ALARM printed_lines=$LINES printed_alarming_lines=$ALARM exit=$CODE last_line_at_s=$LAST_AT" > "$OUTROOT/$CASE.summary.txt"

# ---- the same command on a PTY: what a person at a terminal sees, byte for byte ----------------------
: > "$W/pids"; : > "$W/git.log"
T0="$(python3 -c 'import time; print(repr(time.monotonic()))')"
env WASM_AGENT_DATA="$SANDBOX" WASM_AGENT_HOME="$HOME_DIR" WA_INSTALL_DIR="$INST" \
  WASM_AGENT_LUA_ROOT="$WT" PATH="$W/bin:$PATH" SR_LOG="$OUTROOT/.sr.log" MEASURE_GIT_LOG="$W/git.log" \
  script -qec "$BIN --db $W/node.db update" /dev/null > "$W/pty.txt" 2>&1
PTY_CODE=$?
T1="$(python3 -c 'import time; print(repr(time.monotonic()))')"
PTY_TOTAL=$(python3 -c "print('%.3f' % (float('$T1') - float('$T0')))")
PTY_LINES=$(wc -l < "$W/pty.txt")
PTY_CR=$(tr -cd '\r' < "$W/pty.txt" | wc -c)
PTY_ESC=$(tr -cd '\033' < "$W/pty.txt" | wc -c)
PTY_GIT=$(tr '\n' '|' < "$W/git.log" 2>/dev/null || true)
echo "pty: lines=$PTY_LINES carriage_returns=$PTY_CR escape_bytes=$PTY_ESC exit=$PTY_CODE wall_s=$PTY_TOTAL git=[$PTY_GIT]"
cp "$W/pty.txt" "$OUTROOT/$CASE.pty.txt"
echo "case=$CASE deploy_out_lines=$DEPLOYOUT_LINES deploy_out_alarming_lines=$DEPLOYOUT_ALARM printed_lines=$LINES printed_alarming_lines=$ALARM exit=$CODE last_line_at_s=$LAST_AT pty_lines=$PTY_LINES pty_cr=$PTY_CR pty_esc=$PTY_ESC pty_exit=$PTY_CODE pty_wall_s=$PTY_TOTAL git_calls=$GIT_CALLS git=[$MEASURE_GIT_LOG_DUMP]" > "$OUTROOT/$CASE.summary.txt"

# stop only the PIDs this script started (quality rule 17)
if [ -s "$W/pids" ]; then while read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done < "$W/pids"; fi
echo "workdir=$W"
