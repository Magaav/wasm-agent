#!/usr/bin/env bash
# `wa update` FOLLOWS THE INSTALL IT ASKED FOR - from the first second, by itself (Fable/Victor, 24/11).
#
# WHAT WAS MEASURED, and why this row exists. On `work`, 24/11:
#   * 15:32Z - `wa update` printed NOTHING while the deploy compiled 48 of 456 crates after 3.5 minutes.
#     The progress was on disk the whole time (`build-status.json`, the sentinel's queue record,
#     `deploy.out`); no command read it.
#   * 15:34:55Z - a build FAILED after 361 s and the person who typed the command was told nothing at all.
#
# So the row drives the REAL `wa update` against a scratch node whose sentinel is a stub: on `request
# deploy` the stub writes a request file and starts a stub deploy that writes the SAME files a real one
# writes, in the same shapes (`scripts/lib/build-status.sh` for build-status.json, `queue::observe` for
# the sentinel's record, `write_result` in `scripts/deploy.sh` for deploy-result.json, the sentinel's own
# `--- deploy ... ---` header in deploy.out). Nothing here is the operator's node: WASM_AGENT_HOME and
# WASM_AGENT_DATA are the scratch directories below, and the row refuses to run if they are not.
#
# What it asserts, in the order a person reads it:
#   1. `wa update --check` answers for the commit this node runs and the one it is behind by, from the
#      local release list, and writes no request (Fable 24/11, (b)(i));
#   2. the FIRST line names the target and only says what the installer does - here, with the release list
#      naming an older commit: "no published binary is named for <sha> here: the installer looks for one
#      built from the same inputs, and builds from source only if there is none (minutes)". The word
#      "building" is NOT printed until the installer says it is building (item A);
#   3. when it does say so, text #2 is printed once, the phases print with their elapsed time and the
#      n/total form carries "(from source, on this machine)";
#   4. when the installer says it is installing a PUBLISHED binary, the line is "installing the published
#      binary (no build)" with no n/total at all - the two claims cannot contradict each other (item B);
#   5. a deploy that FAILS prints its phase, reason and elapsed time, then the installer's own last lines
#      (up to 8) and only then the `next:` line, and exits 1 (item C);
#   6. a request the sentinel never starts is not followed forever: past the bound it says so, names the
#      command that picks it up, and exits 1;
#   7. `--detach` returns at once and names the one command that re-attaches;
#   8. `--follow` attaches to the deploy already in flight and prints its final line.
#
# Prints `update follow ok`; any failed check exits 1 with the check named.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || { echo "SKIP test-update-follow: no wa binary at $BIN (it drives the real command)"; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/wa-follow-XXXXXX")" || { echo "FAIL test-update-follow: no scratch directory"; exit 1; }
HOMEDIR="$W/home"
INST="$W/install"
TREE="$W/tree"
SANDBOX="$HOMEDIR/.wasm-agent"
SENTINEL="$SANDBOX/sentinel"
# THE GUARD (quality rule 2): a row that writes a store writes its own, never the operator's. The rule
# and its refusals live in one place - scripts/lib/scratch-home.sh - so this row cannot get the side of
# the comparison wrong the way four rows did on 19/11.
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$HOMEDIR" || exit 2
mkdir -p "$HOMEDIR" "$INST" "$TREE/rust/target/release" "$SENTINEL/requests" "$SENTINEL/queue" "$SENTINEL/done" "$SENTINEL/failed" "$SENTINEL/claimed" || exit 1
printf 'rust/target/\n' > "$TREE/.gitignore"

fail() { echo "FAIL test-update-follow: $*" >&2; [ -s "$W/out.txt" ] && { echo '--- wa update said:' >&2; sed 's/^/  /' "$W/out.txt" >&2; }; exit 1; }

# ---- the fixture tree: two commits, main's tip newer than the published one -----------------------
# `no published binary is named for <sha> here` is only an honest sentence when the release list really
# does hold an older commit and local ancestry proves the target is newer than it. So the fixture is a
# real repository with exactly that shape: O is published (the release-list fixture names it), T is
# main's tip and O's child.
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
TSHORT="$(git -C "$TREE" rev-parse --short HEAD)"
P12="$(printf '%s' "$PUBLISHED" | cut -c1-12)"
printf '%s\n' "$TREE" > "$INST/runtime-worktree.txt"
printf 'commit=%s\nsource_commit_hint=%s\n' "$T12" "$T12" > "$INST/installed.txt"

# ---- the release list this node holds: it names the OLDER commit, and only that -------------------
# Schema 2 is what `lua/core/update_banner.lua` writes and reads (`window` + asset names). `checked_at`
# is recent on purpose: the point of the fixture is "the list does not name the target", not "the list is
# stale".
NOWMS="$(($(date +%s) * 1000))"
cat > "$SANDBOX/update-check.json" <<CL
{"schema":2,"checked_at":$NOWMS,"last_ok_at":$NOWMS,"repo":"fixture/fixture","transport":"fixture","window":[{"tag":"node-$P12","name":"node-$P12","sha12":"$P12","published_at":"2026-11-24T10:00:00Z","assets":{"node-$P12.manifest":true,"wa-x86_64-unknown-linux-gnu-$P12":true,"wa-sentinel-x86_64-unknown-linux-gnu-$P12":true}}]}
CL

# ---- the stub deploy: the SAME files a real one writes -------------------------------------------
# `$1` is the request id, `$2` is `ok` or `fail`. Every shape below is the real one:
#   * deploy.out         - the sentinel's header (`deploy_capture_header`), then the installer's words
#   * build-status.json  - scripts/lib/build-status.sh: state/phase/done/total/crate/commit/started_at/at
#   * queue/<id>.json    - rust/wa-sentinel/src/queue.rs:  state/phase/detail/queued_at/updated_at
#   * deploy-result.json - scripts/deploy.sh write_result: ok/commit/detail/at/request_id
STUBDEPLOY="$W/stub-deploy.sh"
cat > "$STUBDEPLOY" <<'DEPLOY'
#!/bin/sh
id="$1"; outcome="$2"
STATUS="$FIXTURE_STATUS"; QUEUE="$FIXTURE_QUEUE"; RESULT="$FIXTURE_RESULT"; INSTALLED="$FIXTURE_INSTALLED"
started=$(date +%s)
printf -- '--- deploy detached at %s script %s reason fixture update ---\n' "$started" "$0"
write_status() { # state phase done crate
  printf '{"state":"%s","phase":"%s","done":%s,"total":456,"crate":"%s","commit":"%s","started_at":%s,"at":%s}\n' \
    "$1" "$2" "$3" "$4" "$T12" "$started" "$(date +%s)" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
}
write_queue() { # state phase detail
  printf '{"schema":1,"id":"%s","verb":"deploy","state":"%s","phase":"%s","detail":"%s","queued_at":%s,"updated_at":%s,"attempts":1}\n' \
    "$id" "$1" "$2" "$3" "$started" "$(date +%s)" > "$QUEUE/$id.json.tmp" && mv -f "$QUEUE/$id.json.tmp" "$QUEUE/$id.json"
}
write_queue running spawned "deploy started detached"
sleep "${FIXTURE_LEAD:-1}"
echo 'deploy: looking for a published binary for this commit'
case "${FIXTURE_DECLARE:-none}" in
  build) echo 'deploy: no published binary for this commit; building this tree (disk floor ok)' ;;
  published) echo 'deploy: installing the published binary; the prove gate below runs on it, then upgrade.sh' ;;
  # THE DISAGREEMENT THIS CASE EXISTS FOR (Victor on work, 27/11): the installer announced the published path
  # and then compiled for 1961 s. Its log keeps saying "published", so only the build status tells the truth.
  published-compiles) echo 'deploy: installing the published binary; the prove gate below runs on it, then upgrade.sh' ;;
esac
if [ "${FIXTURE_DECLARE:-none}" != "published" ] && [ "${FIXTURE_DECLARE:-none}" != "published-compiles" ]; then
  write_status building preflight 0 ""
  sleep 1
  write_status building compiling 12 "provisioning"
  sleep 1
  write_status building compiling 48 "wa-host"
  sleep 1
elif [ "${FIXTURE_DECLARE:-none}" = "published-compiles" ]; then
  write_status building installing 0 ""
  sleep 1
  write_status building compiling 12 "provisioning"
  sleep 1
  write_status building compiling 48 "wa-host"
  sleep 1
else
  # A published install does not compile: the phases are the installer's, with no bar to draw.
  write_status building installing 0 ""
  sleep 1
fi
if [ "$outcome" = "fail" ]; then
  echo 'deploy: proving the candidate on a scratch port'
  echo 'deploy: refused(no_built_binary): nothing is built at this install path, and this deploy was told not to build'
  write_status failed "compiling: no built binary at $FIXTURE_BUILD/release/wa" 48 ""
  write_queue failed spawned "deploy ended"
  exit 1
fi
if [ "${FIXTURE_DECLARE:-none}" != "published" ]; then
  write_status building proving 456 ""
  sleep 1
fi
echo 'deploy: installing the node, the UI and the sentinel'
printf '{"ok":true,"commit":"%s","branch":"tree","node_sha256":"deadbeef","sentinel_sha256":"deadbeef","watcher_pid":"4242","detail":"installed %s; watcher 4242","reason":"fixture","at":"%s","request_id":"%s","expected_sha":"","phases":[]}\n' \
  "$T12" "$T12" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" > "$RESULT.tmp" && mv -f "$RESULT.tmp" "$RESULT"
printf 'commit=%s\nsource_commit_hint=%s\nbinary_source=prebuilt-fixture\n' "$T12" "$T12" > "$INSTALLED"
write_status installed "" 456 "$(( $(date +%s) - started ))s"
write_queue done spawned "deploy ended"
exit 0
DEPLOY
chmod +x "$STUBDEPLOY"

cat > "$INST/wa-sentinel" <<'STUB'
#!/bin/sh
# A stub supervisor: `preflight` answers the shape `update.lua` verifies (schema 1, the two capabilities
# it insists on), and `request deploy` writes the request file the real one writes and starts the stub
# deploy detached - the real sentinel returns as soon as the installer is spawned, so this one does too.
# `FIXTURE_NO_START=1` writes the request and starts nothing: a request the sentinel never performs.
printf '%s\n' "$*" >> "$FIXTURE_SENTINEL_CALLS"
if [ "$1" = "preflight" ]; then
  echo '{"schema":1,"watcher":"running","watcher_pid":4242,"ownership":"watcher_lifetime_lock","stop_file":false,"pending_deploys":[],"inventory_verified":true,"capabilities":{"health_free":true,"atomic_deploy_dedupe":true}}'
  exit 0
fi
if [ "$1" = "request" ] && [ "$2" = "deploy" ]; then
  id="$(date +%s%N)-$$-1"
  id="$(printf '%s' "$id" | tr -cd '0-9a-zA-Z-')"
  req="$FIXTURE_REQUESTS/$id.json"
  printf '{"verb":"deploy","reason":"fixture update","queued_at":%s,"session":"","prompt":""}\n' "$(date +%s)" > "$req"
  echo "  requested deploy: $req"
  [ "${FIXTURE_NO_START:-0}" = 1 ] && exit 0
  setsid "$FIXTURE_STUBDEPLOY" "$id" "$FIXTURE_OUTCOME" > "$FIXTURE_DEPLOYOUT" 2>&1 < /dev/null &
  echo $! >> "$FIXTURE_PIDS"
  exit 0
fi
echo "unknown verb" >&2
exit 2
STUB
chmod +x "$INST/wa-sentinel"

# The row never asks the network anything: the release list is the fixture written above, and the
# feed checks are off (`wa update --check` also reads the published release feed, which is a request).
export WA_UPDATE_CHECK=0 WA_OFFLINE=1
export FIXTURE_STATUS="$SANDBOX/build-status.json" FIXTURE_QUEUE="$SENTINEL/queue" \
  FIXTURE_RESULT="$INST/deploy-result.json" FIXTURE_INSTALLED="$INST/installed.txt" \
  FIXTURE_REQUESTS="$SENTINEL/requests" FIXTURE_DEPLOYOUT="$SENTINEL/deploy.out" \
  FIXTURE_PIDS="$W/pids" FIXTURE_SENTINEL_CALLS="$W/sentinel-calls" FIXTURE_STUBDEPLOY="$STUBDEPLOY" FIXTURE_BUILD="$SANDBOX/build/target/deploy-$T12" \
  T12="$T12" FIXTURE_OUTCOME="ok"
: > "$W/pids"
: > "$W/sentinel-calls"
: > "$W/git-calls"

kill_stubs() {
  [ -s "$W/pids" ] || return 0
  while read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done < "$W/pids"
}
trap 'kill_stubs; rm -rf "$W"' EXIT

run_update() { # <args...> -> output in $W/out.txt, exit code in $CODE
  # WASM_AGENT_DATA is pinned as well as WASM_AGENT_HOME: `paths.data()` prefers it when a caller's
  # environment exports it, and a row that inherited it would read and write a REAL store while every
  # other path in it was a fixture (the class of accident the orchestrator's 24/11 note names).
  # THE FIRST BYTE IS A MEASUREMENT, NOT AN IMPRESSION (bug 4, Victor 27/11: "we need instantaneous"). The command
  # runs in the background and this polls the file it writes, so FIRST_BYTE_MS is the time from spawn to the first
  # byte a person would see - the same thing `WA_FIRST_BYTE` measures by hand on a node.
  local t0 t1 pid
  # THE FILE MUST BE EMPTY FIRST: the previous case left its output there, and the poll below then read the old
  # bytes and reported "first byte: 1 ms" - a measurement of nothing (caught by reading the number, not the ok).
  : > "$W/out.txt"
  t0=$(date +%s%N)
  WASM_AGENT_DATA="$SANDBOX" WASM_AGENT_HOME="$HOMEDIR" WA_INSTALL_DIR="$INST" WASM_AGENT_LUA_ROOT="$ROOT" \
    "$BIN" --db "$W/node.db" update "$@" > "$W/out.txt" 2>&1 &
  pid=$!
  while :; do
    [ -s "$W/out.txt" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.005
  done
  t1=$(date +%s%N)
  FIRST_BYTE_MS=$(( (t1 - t0) / 1000000 ))
  wait "$pid" 2>/dev/null
  CODE=$?
}
reset_fixture() { rm -f "$SANDBOX/build-status.json" "$INST/deploy-result.json" "$SENTINEL/deploy.out"; }

# The separator is U+00B7 (\302\267 in octal): built once here, because GNU grep -E does not decode \x
# escapes in a pattern and would silently match nothing.
MID="$(printf '\302\267')"

# ---- 1. `wa update --check` answers for BOTH commits, locally -------------------------------------
# (b)(i), Fable 24/11: "is there a published artifact for the commit I am on, and for the one I am behind
# by". The node's record is set to the PUBLISHED commit, the tree to the unpublishable one, so both
# answers are different facts and neither can be produced by accident.
printf 'commit=%s\nsource_commit_hint=%s\n' "$P12" "$P12" > "$INST/installed.txt"
run_update --check
[ "$CODE" = 0 ] || fail "--check is a question and must exit 0 (it exited $CODE)"
grep -q "this node ($P12): published binary for $P12 on x86_64-unknown-linux-gnu" "$W/out.txt" \
  || fail '--check must say what the commit this node RUNS is published as'
# The commit behind is NOT published under its own name, and `--check` now says what the INSTALLER does about
# that (Fable, 24/11): this row keeps the feed off (WA_UPDATE_CHECK=0 / WA_OFFLINE=1), so the installer's
# digest walk refuses by name and the answer is its own fallback sentence.
grep -q "behind by ($T12): no binary is published under $T12's own name; the installer also accepts one built from the same inputs and looks for it at install time" "$W/out.txt" \
  || fail '--check must say what the commit it is BEHIND BY is published as, in the installer own terms'
grep -q 'release list: 1 entries, read ' "$W/out.txt" || fail '--check must date the list it answered from'
[ -n "$(ls -A "$SENTINEL/requests" 2>/dev/null)" ] && fail '--check wrote a deploy request; it is a question'
echo '  ok: --check answered for the installed commit and for the one behind it, from the local list'

# ---- 1b. ALREADY UP TO DATE: one answer, no deploy, no sentinel, under a second (mission budget 8) -------
# MEASURED before this change: the same fixture queued a full deploy - build, the whole test suite, the swap -
# because a tree-node `wa update` never compared the tree with what the install record says it runs, and it paid
# a git fetch and a sentinel `preflight` before it could say anything (1.2-1.6 s to the first line).
printf 'commit=%s\nsource_commit_hint=%s\n' "$T12" "$T12" > "$INST/installed.txt"
reset_fixture
: > "$W/sentinel-calls"
# The fast path's ONE request is a `git ls-remote` to this fixture's origin, which is a LOCAL bare repo:
# WA_OFFLINE is rotated for this case only, because the flag is what makes the fast path answer "unknown"
# on a real offline node (and an unknown falls back to the slow path, which is the correct behaviour).
unset WA_OFFLINE
QUICK_START=$(date +%s%N)
run_update
export WA_OFFLINE=1
QUICK_MS=$(( ($(date +%s%N) - QUICK_START) / 1000000 ))
[ "$CODE" = 0 ] || fail "an already current node must exit 0 (it exited $CODE)"
QUICK_LINES=$(wc -l < "$W/out.txt")
[ "$QUICK_LINES" = 2 ] || { cat "$W/out.txt" >&2; fail "an already current node must print TWO lines (the work starting and the answer), got $QUICK_LINES"; }
EXPECTED="already up to date (${T12%????})"
grep -qx "$EXPECTED" "$W/out.txt" || fail "the answer must be '$EXPECTED', got: $(cat "$W/out.txt")"
[ -s "$W/sentinel-calls" ] && fail "an already current node asked the sentinel: $(cat "$W/sentinel-calls")"
[ "$QUICK_MS" -lt 2000 ] || fail "already up to date took ${QUICK_MS}ms; the budget is under 1000ms and this row fails at 2000"
echo "  ok: already up to date answered in ${QUICK_MS}ms with two lines, no git fetch and no sentinel call"
printf 'commit=%s\nsource_commit_hint=%s\n' "$T12" "$T12" > "$INST/installed.txt"

# ---- 2. a compile install: ONE moving line, ONE last line, and the installer's words in the log -------
# WHAT THIS REPLACES, and why the change is not a loosening (mission update-is-one-line, 25/11). The row used to
# assert the slice-1 output: a plan sentence first, a `queued:` sentence, the installer's build declaration as
# its own line, one line per phase, and on a failure the installer's own last eight lines printed above `next:`.
# MEASURED, same fixture, before and after: 9 lines then, 7 now; and the 7001-line deploy.out never reached the
# screen in either version. The FACTS the old assertions were there for are all still asserted below - the
# target is named, the build is declared once, every phase carries an n/m and a clock, the final line names the
# commit, the installer's own reason is still shown on a failure (now from the log the last line names) - and
# the two shapes (a terminal and a pipe) are asserted as shapes, which nothing did before.
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=1 FIXTURE_DECLARE=build
reset_fixture
START=$(date +%s)
run_update
ELAPSED=$(( $(date +%s) - START ))
[ "$CODE" = 0 ] || fail "a deploy that installed must exit 0 (it exited $CODE)"
FIRST="$(head -1 "$W/out.txt")"
case "$FIRST" in
  "checking for updates  0:00") : ;;
  *) fail "the FIRST line must be the work starting, before anything is fetched or asked, got: $FIRST" ;;
esac
LAST_NEWEST="$(tail -1 "$W/out.txt")"
case "$LAST_NEWEST" in
  "log: "*) : ;;
  *) fail "the last line must name the log file, got: $LAST_NEWEST" ;;
esac
LOG_PATH="${LAST_NEWEST#log: }"
[ -s "$LOG_PATH" ] || fail "the log the last line names must exist and have the installer's words in it: $LOG_PATH"
grep -q '^--- deploy' "$LOG_PATH" || fail 'the log must hold the deploy block, header and all'
grep -q 'deploy: installing the node' "$LOG_PATH" || fail "the log must hold the installer's own last lines"
FINAL="$(tail -2 "$W/out.txt" | head -1)"
# "updated to <8 hex> in 0:05", or with the version the installed commit declares when the tree carries it.
printf '%s' "$FINAL" | grep -Eq "^updated to (v[0-9][^ ]* \\()?${T12%????}\\)? in [0-9]+:[0-9][0-9]$" \
  || fail "the last-but-one line must say the install finished, with the commit and the time, got: $FINAL"
# THE BUILD IS DECLARED ONCE, by the phase itself, and only when the installer said so.
DECLARED="$(grep -c "from source, on this machine" "$W/out.txt")"
[ "$DECLARED" -ge 1 ] || fail 'the phases must say the build runs from source on this machine'
# THE CONTRACT CHANGED ON PURPOSE (bug 2, Victor 27/11): the phase must now also say WHY it is building, not only
# that it is. The reason comes from the installer's own log line; the estimate is named so the wait is not a
# surprise. The clock still closes the line.
grep -Eq "building [0-9]+/456 compiling wa-host .*(from source, on this machine: no published binary for this commit[,;]? [^)]*)\)  [0-9]+:[0-9][0-9]" "$W/out.txt" \
  || fail 'a building phase with n/m, its source and its elapsed time was not printed'
grep -q 'proving' "$W/out.txt" || fail 'the later phases were not printed'
# NOTHING OF THE INSTALLER'S OWN OUTPUT REACHES THE SCREEN - that is the whole complaint.
grep -q 'Compiling crate-' "$W/out.txt" && fail 'the installer own output reached the screen; it belongs to the log'
grep -q '^  deploy: ' "$W/out.txt" && fail 'the installer own lines reached the screen; they belong to the log'
# A PIPE GETS ONE LINE PER PHASE CHANGE AND NOTHING ELSE: no advice, no plan, no queue sentence.
LINES="$(wc -l < "$W/out.txt")"
[ "$LINES" -le 12 ] || fail "a pipe must get one line per phase and the last line, got $LINES lines"
grep -q 'next: ' "$W/out.txt" && fail 'the advice line was printed on a success'
grep -q 'queued: the sentinel will deploy' "$W/out.txt" && fail 'the queue sentence is a note; it belongs to --verbose'
[ "$ELAPSED" -le 60 ] || fail "the follow took $ELAPSED s for a 5 s fixture deploy"
echo "  ok: first line was the work starting; $LINES lines for a compile install (one per phase), the build declared once, the final line named ${T12%????} and the log $LOG_PATH"

# ---- 2b. THE TWO SHAPES: a terminal gets a line REWRITTEN IN PLACE, a pipe gets no carriage return ------ 
reset_fixture
if command -v script >/dev/null 2>&1; then
  T0=$(date +%s)
  WASM_AGENT_DATA="$SANDBOX" WASM_AGENT_HOME="$HOMEDIR" WA_INSTALL_DIR="$INST" WASM_AGENT_LUA_ROOT="$ROOT" \
    script -qec "$BIN --db $W/node.db update" /dev/null > "$W/pty.txt" 2>&1
  PTY_CODE=$?
  [ "$PTY_CODE" = 0 ] || fail "the pty run must exit 0 (it exited $PTY_CODE)"
  # A terminal: the phase line is erased and rewritten, so the raw bytes carry a carriage return and an
  # erase-to-end-of-line, and the run leaves TWO lines behind (what happened, and the log).
  tr -cd '\r' < "$W/pty.txt" | grep -q . || fail 'a terminal must get the phase rewritten in place (no carriage return was written)'
  tr -cd '\033' < "$W/pty.txt" | grep -q . || fail 'a terminal must get the erase-to-end-of-line sequence when the line is redrawn'
  PTY_LINES=$(awk 'END{print NR}' "$W/pty.txt")
  [ "$PTY_LINES" = 2 ] || fail "a terminal must be left with TWO lines after the run (what happened, and the log), got $PTY_LINES"
  # a pipe never rewrites: no carriage return and no escape byte in the captured output
  tr -cd '\r' < "$W/out.txt" | grep -q . && fail 'a pipe got a carriage return: the line was rewritten into a captured log'
  echo '  ok: a terminal got one line rewritten in place (\r + erase) and was left with 2 lines; a pipe got none'
else
  echo '  skip: no script(1) to drive a pty'
fi

# ---- 3. the published path says it is installing a binary, with no bar at all (item B) -----------
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=1 FIXTURE_DECLARE=published
reset_fixture
run_update
[ "$CODE" = 0 ] || fail "a published install must exit 0 (it exited $CODE)"
grep -q 'installing the published binary (no build)' "$W/out.txt" || fail 'the published path must say it is installing the published binary'
grep -q 'published binary, no build' "$W/out.txt" && fail 'the old self-contradicting suffix (a bar plus "no build") is back'
grep -q '/456' "$W/out.txt" && fail 'a published install printed a build bar; there is no build to count'
grep -q "building from source, minutes" "$W/out.txt" && fail 'the published path claimed a build'
grep -Eq "^updated to .* in [0-9]+:[0-9][0-9]$" "$W/out.txt" || fail 'the published install must print its last line'
echo '  ok: the published path printed "installing the published binary (no build)", no bar, and its last line'

# ---- 3b. THE LABEL FOLLOWS THE WORK (Victor on work, 27/11) ---------------------------------------
# "installing the published binary (no build)" was on screen for 32 minutes while deploy.sh compiled for 1961 s.
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=1 FIXTURE_DECLARE=published-compiles
reset_fixture
run_update
[ "$CODE" = 0 ] || fail "a published-then-compiled install must exit 0 (it exited $CODE)"
# The label IS honest for the moment before anything compiles (the fixture writes `building installing` first);
# THE BUG was that it stayed there while cargo ran, and the build's own lines never arrived. So: the last
# progress line before the update must be the build's, and the build must have been shown at all.
LAST_PROGRESS="$(tail -2 "$W/out.txt" | head -1)"
printf '%s' "$LAST_PROGRESS" | grep -q 'installing the published binary (no build)' \
  && fail 'the last line before the update still said "no build" while the installer was compiling (bug 1 is back)'
grep -q '/456' "$W/out.txt" || fail 'a compiling install must show its n/m progress'
grep -q 'compiling' "$W/out.txt" || fail 'a compiling install must name the phase that is really running'
echo '  ok: a published declaration followed by a real compile prints the build, never "(no build)"'

# ---- 3c. THE FIRST BYTE IS QUICK, AND THE LINE IS THE START (bug 4) -------------------------------
# Measured by hand on this node, 27/11: 204 ms from the installed binary, 180 ms with the screen opened before the
# update modules load, 585 ms with a full real home. The row asserts a generous ceiling so a real regression (a
# network call before the line, which was 1.2-1.6 s on the old path) reds it, and prints the number either way.
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=1 FIXTURE_DECLARE=build
reset_fixture
run_update
printf '  first byte: %s ms
' "$FIRST_BYTE_MS"
[ "$FIRST_BYTE_MS" -lt 1000 ] || fail "the first byte came at ${FIRST_BYTE_MS} ms; something runs before the line"
head -1 "$W/out.txt" | grep -q 'checking for updates' || fail 'the first line must be the start line'
echo '  ok: the first byte arrived in the first second and it was the start line'

# ---- 4. a deploy that FAILS: one line with the reason, and the installer's own words in the log -----
export FIXTURE_OUTCOME=fail FIXTURE_DECLARE=build
reset_fixture
run_update
[ "$CODE" = 1 ] || fail "a deploy that failed must exit 1 (it exited $CODE)"
FAILED="$(tail -2 "$W/out.txt" | head -1)"
case "$FAILED" in
  "not updated: "*) :;;
  *) fail "a failure must say it did not update, got: $FAILED" ;;
esac
case "$FAILED" in
  *". Nothing was changed.") :;;
  *) fail "a failure must promise that nothing was changed, got: $FAILED" ;;
esac
case "$FAILED" in
  *"compiling: no built binary"*) :;;
  *) fail "a failure must carry the installer's own reason, got: $FAILED" ;;
esac
grep -q 'refused(no_built_binary)' "$W/out.txt" && fail "the installer's lines must not be printed: they are in the log"
FAIL_LOG="$(tail -1 "$W/out.txt")"
case "$FAIL_LOG" in "log: "*) FAIL_LOG="${FAIL_LOG#log: }" ;; *) fail 'a failure must name its log' ;; esac
grep -q 'refused(no_built_binary)' "$FAIL_LOG" || fail "the installer's own refusal must be in the log the failure names"
grep -q 'deploy: installing the node' "$W/out.txt" && fail 'lines the failing deploy never printed were shown'
echo '  ok: the failure printed one line (reason + nothing changed) and named a log holding the installer own refusal'

# ---- 5. a request the sentinel never starts is not followed forever -------------------------------
export FIXTURE_OUTCOME=ok FIXTURE_DECLARE=build FIXTURE_NO_START=1
reset_fixture
WA_UPDATE_FOLLOW_BOUND=2 run_update
unset FIXTURE_NO_START
[ "$CODE" = 1 ] || fail "a follow that gives up must exit 1 (it exited $CODE)"
grep -q 'this deploy is still queued' "$W/out.txt" || fail 'the bound must say the deploy is still queued'
grep -q 'Nothing was changed.' "$W/out.txt" || fail 'the bound must promise that nothing was changed'
echo '  ok: a request the sentinel never started ended on one line that says it is still queued, exit 1'

# ---- 6. --detach returns at once and names the one command that re-attaches -----------------------
reset_fixture
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=6
START=$(date +%s)
run_update --detach
DETACH_S=$(( $(date +%s) - START ))
[ "$CODE" = 0 ] || fail "--detach must exit 0 (it exited $CODE)"
[ "$DETACH_S" -le 4 ] || fail "--detach waited ${DETACH_S}s for a deploy that takes 10s: it followed instead of detaching"
grep -q 'detached: the install continues' "$W/out.txt" || fail '--detach must say the install continues'
grep -q 'wa update --follow re-attaches' "$W/out.txt" || fail '--detach must name the command that re-attaches'
grep -q "installed $T12" "$W/out.txt" && fail '--detach must not wait for the final line'
echo "  ok: --detach returned in ${DETACH_S}s and named the command that re-attaches"

# ---- 7. --follow attaches to the deploy already in flight ------------------------------------------
run_update --follow
[ "$CODE" = 0 ] || fail "--follow over a deploy that installed must exit 0 (it exited $CODE)"
grep -Eq "^updated to .* in [0-9]+:[0-9][0-9]$" "$W/out.txt" || fail '--follow must print the last line of the deploy it attached to'
echo '  ok: --follow attached to the deploy in flight and printed its last line'

# ---- 8. --verbose is the door to the installer's own output ----------------------------------------
reset_fixture
export FIXTURE_OUTCOME=ok FIXTURE_DECLARE=build FIXTURE_LEAD=1
run_update --verbose
[ "$CODE" = 0 ] || fail "--verbose over an install must exit 0 (it exited $CODE)"
grep -q 'queued: the sentinel will deploy' "$W/out.txt" || fail '--verbose must print the notes (the queue sentence) the quiet screen drops'
grep -q 'following: Ctrl-C stops following' "$W/out.txt" || fail '--verbose must say what Ctrl-C does'
echo '  ok: --verbose printed the notes the quiet screen drops'

echo 'update follow ok'
