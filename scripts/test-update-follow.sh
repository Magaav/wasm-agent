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
# the sentinel's record, `write_result` in `scripts/deploy.sh` for deploy-result.json). Nothing here is
# the operator's node: WASM_AGENT_HOME is a scratch directory, and the row refuses to run if it is not.
#
# What it asserts, in the order a person reads it:
#   1. the FIRST line names the target and says download-or-build - here: "no published binary for <sha>
#      on <triple>: building from source, minutes" (the release list this node holds names an older
#      commit, and local ancestry proves the target is newer);
#   2. each phase prints once, with its elapsed time ("building 48/456 compiling wa-host · 2s");
#   3. the final line names the commit installed, and the command exits 0;
#   4. a deploy that FAILS prints the phase, the reason, the elapsed time and the next step, and exits 1;
#   5. `--detach` returns at once and names the one command that re-attaches;
#   6. `--follow` attaches to the deploy already in flight and prints its final line.
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
# `no published binary for <sha> ...: building from source` is only an honest sentence when the release
# list really does hold an older commit and local ancestry proves the target is newer than it. So the
# fixture is a real repository with exactly that shape: O is published (the release-list fixture names
# it), T is main's tip and O's child.
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
#   * build-status.json  - scripts/lib/build-status.sh: state/phase/done/total/crate/commit/started_at/at
#   * queue/<id>.json    - rust/wa-sentinel/src/queue.rs:  state/phase/detail/queued_at/updated_at
#   * deploy-result.json - scripts/deploy.sh write_result: ok/commit/detail/at/request_id
STUBDEPLOY="$W/stub-deploy.sh"
cat > "$STUBDEPLOY" <<'DEPLOY'
#!/bin/sh
id="$1"; outcome="$2"
STATUS="$FIXTURE_STATUS"; QUEUE="$FIXTURE_QUEUE"; RESULT="$FIXTURE_RESULT"; INSTALLED="$FIXTURE_INSTALLED"
started=$(date +%s)
write_status() { # state phase done crate
  printf '{"state":"%s","phase":"%s","done":%s,"total":456,"crate":"%s","commit":"%s","started_at":%s,"at":%s}\n' \
    "$1" "$2" "$3" "$4" "$T12" "$started" "$(date +%s)" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
}
write_queue() { # state phase detail
  printf '{"schema":1,"id":"%s","verb":"deploy","state":"%s","phase":"%s","detail":"%s","queued_at":%s,"updated_at":%s,"attempts":1}\n' \
    "$id" "$1" "$2" "$3" "$started" "$(date +%s)" > "$QUEUE/$id.json.tmp" && mv -f "$QUEUE/$id.json.tmp" "$QUEUE/$id.json"
}
sleep "${FIXTURE_LEAD:-1}"
write_status building preflight 0 ""
write_queue running spawned "deploy started detached"
sleep 1
write_status building compiling 12 "provisioning"
sleep 1
write_status building compiling 48 "wa-host"
sleep 1
if [ "$outcome" = "fail" ]; then
  write_status failed "compiling: no built binary at $FIXTURE_BUILD/release/wa" 48 ""
  write_queue failed spawned "deploy ended"
  exit 1
fi
write_status building proving 456 ""
sleep 1
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

# ---- 1. `wa update --check` answers for BOTH commits, locally -------------------------------------
# (b)(i), Fable 24/11: "is there a published artifact for the commit I am on, and for the one I am behind
# by". The node's record is set to the PUBLISHED commit, the tree to the unpublishable one, so both
# answers are different facts and neither can be produced by accident.
printf 'commit=%s\nsource_commit_hint=%s\n' "$P12" "$P12" > "$INST/installed.txt"
run_update --check
[ "$CODE" = 0 ] || fail "--check is a question and must exit 0 (it exited $CODE)"
grep -q "this node ($P12): published binary for $P12 on x86_64-unknown-linux-gnu" "$W/out.txt" \
  || fail '--check must say what the commit this node RUNS is published as'
grep -q "behind by ($T12): no published binary for $T12 on x86_64-unknown-linux-gnu" "$W/out.txt" \
  || fail '--check must say what the commit it is BEHIND BY is published as'
grep -q 'release list: 1 entries, read ' "$W/out.txt" || fail '--check must date the list it answered from'
[ -f "$SANDBOX/sentinel/requests" ] && [ -n "$(ls -A "$SANDBOX/sentinel/requests" 2>/dev/null)" ] \
  && fail '--check wrote a deploy request; it is a question'
echo '  ok: --check answered for the installed commit and for the one behind it, from the local list'

# ---- 2. the first line names the target and the way it will install -------------------------------
export FIXTURE_OUTCOME=ok FIXTURE_LEAD=1
START=$(date +%s)
run_update
ELAPSED=$(( $(date +%s) - START ))
[ "$CODE" = 0 ] || fail "a deploy that installed must exit 0 (it exited $CODE)"
FIRST="$(head -1 "$W/out.txt")"
EXPECT="no published binary for $TSHORT on x86_64-unknown-linux-gnu: building from source, minutes"
[ "$FIRST" = "$EXPECT" ] || fail "the first line must name the target and download-or-build, got: $FIRST"
grep -q 'queued: the sentinel will deploy' "$W/out.txt" || fail 'the queued line is gone'
# The separator is U+00B7 (\302\267 in octal): built once here, because GNU grep -E does not decode \x
# escapes in a pattern and would silently match nothing.
MID="$(printf '\302\267')"
grep -Eq "building [0-9]+/456 compiling wa-host $MID [0-9]+m?[0-9]*s" "$W/out.txt" \
  || fail 'a building phase with n/m and its elapsed time was not printed'
grep -Eq "installed $T12 $MID [0-9]+m?[0-9]*s" "$W/out.txt" || fail "the final line must name the installed commit and the time it took"
grep -q 'proving' "$W/out.txt" || fail 'the later phases were not printed'
[ "$ELAPSED" -le 60 ] || fail "the follow took $ELAPSED s for a 5 s fixture deploy"
echo "  ok: the first line named the target and the build, every phase printed with its clock, the final line named $T12, exit 0"

# ---- 3. a deploy that FAILS is reported: phase, reason, elapsed, next step, exit 1 -----------------
rm -f "$SANDBOX/build-status.json" "$INST/deploy-result.json"
export FIXTURE_OUTCOME=fail
run_update
[ "$CODE" = 1 ] || fail "a deploy that failed must exit 1 (it exited $CODE)"
grep -Eq "failed: compiling: no built binary at .*/release/wa $MID [0-9]+m?[0-9]*s" "$W/out.txt" \
  || fail 'the failure must print its phase, its reason and the time it took'
grep -q "next: this node still runs" "$W/out.txt" || fail 'a failure must say what this node still runs'
grep -q "$SENTINEL/deploy.out" "$W/out.txt" || fail "a failure must name the installer's own output"
echo '  ok: the failure printed its phase, reason, elapsed time and next step, and exited 1'

# ---- 4. --detach returns at once and names the one command that re-attaches -----------------------
rm -f "$SANDBOX/build-status.json" "$INST/deploy-result.json"
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

# ---- 5. --follow attaches to the deploy already in flight ------------------------------------------
run_update --follow
[ "$CODE" = 0 ] || fail "--follow over a deploy that installed must exit 0 (it exited $CODE)"
grep -q 'following the newest deploy on this node' "$W/out.txt" || fail '--follow must say which deploy it attached to'
grep -Eq "installed $T12 $MID [0-9]+m?[0-9]*s" "$W/out.txt" || fail '--follow must print the final line of the deploy it attached to'
echo '  ok: --follow attached to the deploy in flight and printed its final line'

echo 'update follow ok'
