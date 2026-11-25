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
esac
if [ "${FIXTURE_DECLARE:-none}" != "published" ]; then
  write_status building preflight 0 ""
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
  FIXTURE_PIDS="$W/pids" FIXTURE_STUBDEPLOY="$STUBDEPLOY" FIXTURE_BUILD="$SANDBOX/build/target/deploy-$T12" \
  T12="$T12" FIXTURE_OUTCOME="ok"
: > "$W/pids"

kill_stubs() {
  [ -s "$W/pids" ] || return 0
  while read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done < "$W/pids"
}
trap 'kill_stubs; rm -rf "$W"' EXIT

run_update() { # <args...> -> output in $W/out.txt, exit code in $CODE
  # WASM_AGENT_DATA is pinned as well as WASM_AGENT_HOME: `paths.data()` prefers it when a caller's
  # environment exports it, and a row that inherited it would read and write a REAL store while every
  # other path in it was a fixture (the class of accident the orchestrator's 24/11 note names).
  WASM_AGENT_DATA="$SANDBOX" WASM_AGENT_HOME="$HOMEDIR" WA_INSTALL_DIR="$INST" WASM_AGENT_LUA_ROOT="$ROOT" \
    "$BIN" --db "$W/node.db" update "$@" > "$W/out.txt" 2>&1
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

# ---- 2. the first line names the target and only says what the installer does ---------------------
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=1 FIXTURE_DECLARE=build
reset_fixture
START=$(date +%s)
run_update
ELAPSED=$(( $(date +%s) - START ))
[ "$CODE" = 0 ] || fail "a deploy that installed must exit 0 (it exited $CODE)"
FIRST="$(head -1 "$W/out.txt")"
EXPECT="no published binary is named for $TSHORT here: the installer looks for one built from the same inputs, and builds from source only if there is none (minutes)"
[ "$FIRST" = "$EXPECT" ] || fail "the first line must name the target and say only what the installer does, got: $FIRST"
grep -q 'queued: the sentinel will deploy' "$W/out.txt" || fail 'the queued line is gone'
# Text #2 is the INSTALLER's claim, so it may only appear once the installer has said so - and once.
DECLARED="$(grep -c "no published binary for $TSHORT on x86_64-unknown-linux-gnu: building from source, minutes" "$W/out.txt")"
[ "$DECLARED" = 1 ] || fail "the installer's own build declaration must be printed exactly once, got $DECLARED"
grep -Eq "building [0-9]+/456 compiling wa-host .*from source, on this machine.* $MID [0-9]+m?[0-9]*s" "$W/out.txt" \
  || fail 'a building phase with n/m, its source and its elapsed time was not printed'
grep -Eq "installed $T12 $MID [0-9]+m?[0-9]*s" "$W/out.txt" || fail "the final line must name the installed commit and the time it took"
grep -q 'proving' "$W/out.txt" || fail 'the later phases were not printed'
[ "$ELAPSED" -le 60 ] || fail "the follow took $ELAPSED s for a 5 s fixture deploy"
echo "  ok: the first line named the target and the installer's search; the build was declared once and named the source; every phase printed with its clock; the final line named $T12, exit 0"

# ---- 3. the published path says it is installing a binary, with no bar at all (item B) -----------
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=1 FIXTURE_DECLARE=published
reset_fixture
run_update
[ "$CODE" = 0 ] || fail "a published install must exit 0 (it exited $CODE)"
grep -q 'installing the published binary (no build)' "$W/out.txt" \
  || fail 'the published path must say it is installing the published binary'
grep -q 'published binary, no build' "$W/out.txt" && fail 'the old self-contradicting suffix (a bar plus "no build") is back'
grep -q '/456' "$W/out.txt" && fail 'a published install printed a build bar; there is no build to count'
grep -q "building from source, minutes" "$W/out.txt" && fail 'the published path claimed a build'
grep -Eq "installed $T12 $MID [0-9]+m?[0-9]*s" "$W/out.txt" || fail 'the published install must print its final line'
echo '  ok: the published path printed "installing the published binary (no build)" and no bar'

# ---- 4. a deploy that FAILS: phase, reason, elapsed, the installer's own lines, next, exit 1 ------
export FIXTURE_OUTCOME=fail FIXTURE_DECLARE=build
reset_fixture
run_update
[ "$CODE" = 1 ] || fail "a deploy that failed must exit 1 (it exited $CODE)"
grep -Eq "failed: compiling: no built binary at .*/release/wa $MID [0-9]+m?[0-9]*s" "$W/out.txt" \
  || fail 'the failure must print its phase, its reason and the time it took'
grep -q 'refused(no_built_binary)' "$W/out.txt" \
  || fail "the installer's own last line must be printed above the advice"
grep -q 'deploy: installing the node' "$W/out.txt" && fail 'lines the failing deploy never printed were shown'
NEXT_LINE="$(grep -n '^next: ' "$W/out.txt" | tail -1 | cut -d: -f1)"
EVIDENCE_LINE="$(grep -n 'refused(no_built_binary)' "$W/out.txt" | head -1 | cut -d: -f1)"
[ -n "$NEXT_LINE" ] && [ -n "$EVIDENCE_LINE" ] && [ "$EVIDENCE_LINE" -lt "$NEXT_LINE" ] \
  || fail "the installer's lines must come BEFORE the next: line (evidence $EVIDENCE_LINE, next $NEXT_LINE)"
grep -q "next: this node still runs" "$W/out.txt" || fail 'a failure must say what this node still runs'
grep -q "$SENTINEL/deploy.out" "$W/out.txt" || fail "a failure must name the installer's own output"
TOLD="$(grep -c '^  deploy: ' "$W/out.txt")"
[ "$TOLD" -ge 1 ] && [ "$TOLD" -le 8 ] || fail "the installer's own lines must be at most 8, got $TOLD"
echo '  ok: the failure printed its phase, reason, elapsed time, the installer own lines (above next:) and exited 1'

# ---- 5. a request the sentinel never starts is not followed forever -------------------------------
export FIXTURE_OUTCOME=ok FIXTURE_DECLARE=build FIXTURE_NO_START=1
reset_fixture
WA_UPDATE_FOLLOW_BOUND=2 run_update
unset FIXTURE_NO_START
[ "$CODE" = 1 ] || fail "a follow that gives up must exit 1 (it exited $CODE)"
grep -q 'stopped following after ' "$W/out.txt" || fail 'the bound must say it stopped following'
grep -q 'the sentinel has not started this request' "$W/out.txt" || fail 'the bound must say what did not happen'
grep -q 'wa update --follow picks it up again' "$W/out.txt" || fail 'the bound must name the command that picks it up'
echo '  ok: a request the sentinel never started stopped the follow at the bound, with the command that resumes it'

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
grep -q 'following the newest deploy on this node' "$W/out.txt" || fail '--follow must say which deploy it attached to'
grep -Eq "installed $T12 $MID [0-9]+m?[0-9]*s" "$W/out.txt" || fail '--follow must print the final line of the deploy it attached to'
echo '  ok: --follow attached to the deploy in flight and printed its final line'

echo 'update follow ok'
