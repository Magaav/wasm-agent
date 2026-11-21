#!/usr/bin/env bash
# scripts/drive.sh, judged against a SCRATCH missions root, a scratch repository and a stub landing.
#
# WHY A ROW FOR THIS. 21/11: a stopped landing and a finished mission both waited for a model to notice. The
# driver is the mechanism that replaces that waiting, so the three things that make it worth having are proved
# here, in seconds, with no model and no real landing:
#
#   * a done mission with a green preflight LANDS (oldest first), and its LOCAL-CHANGELOG entry is written
#     without anybody asking for it;
#   * a red landing STOPS the whole queue and writes ONE file, ATTENTION, naming the mission and the rows -
#     and the mission behind it does not land;
#   * the stop is cleared by name (--skip), and then the queue goes on with mission 3 instead of waiting for
#     somebody to fix mission 2 first.
#
# What is real: the script itself, its locks (flock), its queue rules (a `done` with rc=0, a branch not yet on
# main, a preflight green on THIS main), and the files it writes. What is scripted: the landing (`WA_LAND` is a
# stub that merges the branch into main and can be made to fail), the install (`WA_DRIVE_INSTALL=none`), the
# post-landing health run (`WA_DRIVE_HEALTH=none`) and the preflight (`WA_DRIVE_PREFLIGHT` is a stub that
# writes the preflight.json its case needs).
#
#   bash scripts/test-drive.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
drive=$root/scripts/drive.sh
# A tree without drive.sh has nothing to judge, and the row says so instead of failing in a way the
# discrimination check has to guess at (see scripts/test-main-health.sh).
[ -f "$drive" ] || { echo "SKIP test-drive: this tree has no scripts/drive.sh (nothing to judge)"; exit 0; }

# ITS OWN HOME, and it refuses the operator's (rule 2): the driver writes ATTENTION, a changelog and a queue.
work=$(TMPDIR=/tmp mktemp -d) || { echo "SKIP test-drive: mktemp failed"; exit 0; }
trap 'rm -rf "$work"' EXIT
export HOME=$work/user WASM_AGENT_HOME=$work/node TMPDIR=$work/tmp
mkdir -p "$HOME" "$WASM_AGENT_HOME" "$TMPDIR"
operator_home=${OPERATOR_NODE_HOME:-/home/$(id -un)/.wasm-agent}
case "$work" in
  "$operator_home"|"$operator_home"/*) echo "test-drive: refused(real_node_home): $work is the operator's node home" >&2; exit 2 ;;
esac
command -v git >/dev/null 2>&1 || { echo "SKIP test-drive: git is not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP test-drive: jq is not on PATH"; exit 0; }

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "test-drive FAILED: $*" >&2; exit 1; }
git_c() { git -c user.email=test@example.invalid -c user.name=Test -c commit.gpgsign=false "$@"; }

missions=$work/missions
repo=$work/repo
mkdir -p "$missions" "$repo"
cd "$repo" || fail "cannot enter the scratch repo"
git_c init -q -b main . && printf 'base\n' > a.txt && git_c add -A >/dev/null && git_c commit -q -m base \
  || fail "the scratch repository did not initialise"
for n in m1 m2 m3; do
  git_c checkout -q -B "change/$n" main || fail "branch change/$n"
  printf '%s\n' "$n" > "$n.txt"
  git_c add -A >/dev/null && git_c commit -q -m "$n" || fail "commit $n"
  git_c checkout -q main || fail "back to main"
done

# ---- three finished missions, each with its brief and (for two of them) a green preflight ---------------
main_sha=$(git_c rev-parse main)
make_mission() {  # <name> <minutes-ago> <preflight: green|red|none> <land outcome: ok|red>
  local name=$1 age=$2 pf=$3 outcome=$4 d=$missions/$1
  mkdir -p "$d"
  printf 'a mission that changed %s\n\n## How Victor tests it\nrun `wa --version` and look at %s: it says %s\n' \
    "$name" "$name.txt" "$name" > "$d/brief.md"
  printf 'rc=0 preflight=green rounds=0 %s\n' "$(date -u +%FT%TZ)" > "$d/done"
  printf '%s\n' "$outcome" > "$d/land-outcome"
  # The mission's preflight VERDICT, which the stub preflight below turns into a preflight.json about the main
  # that is there when it runs (that is what a real preflight does, and what the driver insists on).
  printf '%s\n' "$pf" > "$d/preflight-outcome"
  # `done` older for the earlier missions: the queue is OLDEST FIRST, not alphabetical.
  touch -d "$age minutes ago" "$d/done"
}
make_mission m1 30 green ok
make_mission m2 20 green red
make_mission m3 10 green ok

# ---- the stub landing: it merges the branch into main, or fails with the rows a real one would print ----
cat > "$work/land" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
branch=""
while [ $# -gt 0 ]; do case $1 in --branches) branch=$2; shift 2 ;; *) shift ;; esac; done
name=${branch#change/}
outcome="$MISSIONS_DIR/$name/land-outcome"
echo "stub land $branch (outcome $(cat "$outcome" 2>/dev/null))"
if [ "$(cat "$outcome" 2>/dev/null)" = red ]; then
  echo "FAIL scripts/test-beta.lua (exit 1): beta is red"
  echo "land: STOPPED at gate: 1 row(s) failed"
  exit 1
fi
git -c user.email=test@example.invalid -c user.name=Test -c commit.gpgsign=false merge -q --no-ff --no-edit -m "land $name" "$branch" || exit 1
exit 0
STUB
chmod +x "$work/land"

# ---- the stub preflight: writes the verdict the mission's own file already says ------------------------
cat > "$work/preflight" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
name=$1
main=$(git -C "$REPO_DIR" rev-parse main)
outcome=$(cat "$MISSIONS_DIR/$name/preflight-outcome" 2>/dev/null || echo none)
if [ "$outcome" = green ]; then
  jq -n --arg main "$main" --arg branch "change/$name" \
    '{ok:true, run:"preflight-fake", branch:$branch, main_sha:$main, tree_commit:"deadbeef", failed:[], main_red:[]}' \
    > "$MISSIONS_DIR/$name/preflight.json"
  exit 0
fi
if [ "$outcome" = red ]; then
  jq -n --arg main "$main" --arg branch "change/$name" \
    '{ok:false, run:"preflight-fake", branch:$branch, main_sha:$main, failed:[{row:"scripts/test-beta.lua", first_lines:["beta is red"]}], main_red:[]}' \
    > "$MISSIONS_DIR/$name/preflight.json"
  exit 1
fi
jq -n --arg main "$main" --arg branch "change/$name" \
  '{ok:false, branch:$branch, main_sha:$main, failed:[], main_red:[], why:"the stub has no verdict for this mission"}' \
  > "$MISSIONS_DIR/$name/preflight.json"
exit 2
STUB
chmod +x "$work/preflight"

export MISSIONS_DIR="$missions" REPO_DIR="$repo"
changelog=$missions/LOCAL-CHANGELOG.md
printf '# what is installed\n\n---\n' > "$changelog"
drive_cmd=(bash "$drive" --dry-run)
run_drive() {  # <extra args...>
  ( cd "$missions" && WA_MISSIONS_ROOT="$missions" WA_DRIVE_REPO="$repo" WA_LAND="$work/land" \
    WA_DRIVE_INSTALL=none WA_DRIVE_HEALTH=none WA_DRIVE_CHANGELOG="$changelog" \
    WA_DRIVE_PREFLIGHT="$work/preflight" bash "$drive" "$@" )
}

# ---- 1. the queue: done, branch not on main, oldest first ------------------------------------------------
out=$(run_drive --dry-run) || fail "a dry run failed: $out"
grep -q 'would land m1' <<< "$out" || fail "the dry run does not offer m1: $out"
ok
first=$(printf '%s\n' "$out" | grep 'would land' | head -1)
case "$first" in *m1*) ok ;; *) fail "the queue is not oldest first: $out" ;; esac
[ -z "$(ls "$missions"/*/land-outcome.done 2>/dev/null)" ] || fail "a dry run changed the queue"
ok

# ---- 2. --once lands the OLDEST mission, and writes the changelog entry without being asked ------------
out=$(run_drive --once) || fail "--once failed: $out"
grep -q 'drive: landing m1' <<< "$out" || fail "m1 was not landed first: $out"
ok
git_c merge-base --is-ancestor "$repo/.git" HEAD >/dev/null 2>&1 || true
git -C "$repo" merge-base --is-ancestor change/m1 main || fail "m1 is not on main after --once"
ok
grep -q '^- m1: ' "$changelog" || fail "the LOCAL-CHANGELOG has no entry for m1: $(cat "$changelog")"
ok
grep -q 'test: run .wa --version. and look at m1.txt' "$changelog" || fail "the entry does not carry the brief's How Victor tests it: $(cat "$changelog")"
ok
grep -q 'state: untested' "$changelog" || fail "the entry does not say the state: $(cat "$changelog")"
ok

# ---- 3. m2 is red: the driver stops, writes ONE ATTENTION file, and it never reaches m3 ----------------
out=$(run_drive) && fail "the driver exited 0 although m2 is red: $out"
ok
grep -q 'drive: ATTENTION written for m2' <<< "$out" || fail "no ATTENTION was written for m2: $out"
ok
[ -f "$missions/ATTENTION" ] || fail "the ATTENTION file does not exist"
ok
grep -q '^mission: m2$' "$missions/ATTENTION" || fail "ATTENTION does not name m2: $(cat "$missions/ATTENTION")"
ok
grep -q 'scripts/test-beta.lua' "$missions/ATTENTION" || fail "ATTENTION does not name the row: $(cat "$missions/ATTENTION")"
ok
git -C "$repo" merge-base --is-ancestor change/m3 main 2>/dev/null && fail "m3 landed although m2 was red"
ok

# ---- 4. a second run does not go on either: the file is the stop ----------------------------------------
out=$(run_drive) && fail "a driver with an uncleared ATTENTION exited 0"
ok
grep -q 'ATTENTION names m2' <<< "$out" || fail "the second run does not point at ATTENTION: $out"
ok

# ---- 5. --skip m2 clears it by name, and the queue goes on with m3 -------------------------------------
out=$(run_drive --skip m2) || fail "--skip m2 did not get the queue moving: $out"
ok
grep -q 'drive: landing m3' <<< "$out" || fail "m3 was not landed after m2 was skipped by name: $out"
ok
git -C "$repo" merge-base --is-ancestor change/m3 main || fail "m3 is not on main"
ok
[ ! -f "$missions/ATTENTION" ] || fail "ATTENTION survived the skip"
ok
grep -q '^- m3: ' "$changelog" || fail "the changelog has no entry for m3"
ok

# ---- 6. two drivers never run at once ------------------------------------------------------------------
# The one-driver lock is the kernel's: a second drive.sh refuses BY NAME instead of starting a second landing.
(
  exec 9>"$missions/.drive.lock"
  flock 9
  out=$(run_drive --dry-run 2>&1)
  rc=$?
  [ "$rc" = 2 ] || { echo "test-drive FAILED: a second driver did not refuse (exit $rc): $out"; exit 1; }
  grep -q 'refused(another_driver)' <<< "$out" || { echo "test-drive FAILED: the refusal is not named: $out"; exit 1; }
) || exit 1
ok

# ---- 7. green in `done`, RED on the main that moved: set aside, and the line goes on ---------------------
# The worker's gate loop said green; main moved; the preflight on THIS main is red on the mission's own rows.
# That is the worker's to fix and it must not stop the queue: with no `again` hook the mission is PARKED and
# becomes one line in DECISIONS.md, no ATTENTION is written, and it never lands.
add_branch() {  # <name>
  git_c checkout -q -B "change/$1" main && printf '%s\n' "$1" > "$1.txt" && git_c add -A >/dev/null \
    && git_c commit -q -m "$1" && git_c checkout -q main || fail "branch change/$1"
}
make_mission m4 5 red ok; add_branch m4
out=$(run_drive --skip m2) || fail "a mission's own red stopped the line: $out"
ok
[ ! -f "$missions/ATTENTION" ] || fail "a mission's own red wrote ATTENTION: $(cat "$missions/ATTENTION")"
ok
[ -f "$missions/m4/PARKED" ] || fail "m4 was not parked: $out"
ok
grep -q '^m4: its gate is red on the current main' "$missions/DECISIONS.md" || fail "DECISIONS.md has no line for m4: $(cat "$missions/DECISIONS.md" 2>/dev/null)"
ok
git -C "$repo" merge-base --is-ancestor change/m4 main 2>/dev/null && fail "m4 landed with a red preflight"
ok
# a parked mission is not asked again every round
out=$(run_drive --skip m2) || fail "the round after a park failed: $out"
grep -q 'landing m4\|running one' <<< "$out" && fail "a parked mission was taken again: $out"
ok

# ---- 8. with an `again` hook the mission goes back to its own worker once, by itself --------------------
cat > "$work/again" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$MISSIONS_DIR/again.calls"
STUB
chmod +x "$work/again"
make_mission m5 4 red ok; add_branch m5
out=$(WA_DRIVE_AGAIN="$work/again" run_drive --skip m2) || fail "the again round failed: $out"
grep -q '^m5|\[drive\] Your branch change/m5 was green' "$missions/again.calls" || fail "the hook was not called with the rows: $(cat "$missions/again.calls" 2>/dev/null)"
ok
grep -q 'scripts/test-beta.lua' "$missions/again.calls" || fail "the hook's text does not name the red row"
ok
[ ! -f "$missions/m5/PARKED" ] || fail "m5 was parked although the hook took it"
ok
# the second time it is still red: no second automatic send, it is parked and asked
out=$(WA_DRIVE_AGAIN="$work/again" run_drive --skip m2) || fail "the second again round failed: $out"
[ "$(grep -c '^m5|' "$missions/again.calls")" = 1 ] || fail "the mission was sent back twice by itself"
ok
[ -f "$missions/m5/PARKED" ] || fail "m5 was not parked after its one automatic again"
ok

# ---- 9. nothing approved it = it never lands; a person's LAND file approves it ---------------------------
# An old `done` with no gate verdict (the missions of 20/11 that waited on a land-or-retire answer) is NOT
# the driver's to land on its own: the first version of this script would have landed them oldest first.
make_mission m6 3 green ok; add_branch m6
printf 'rc=0 %s\n' "$(date -u +%FT%TZ)" > "$missions/m6/done"
out=$(run_drive --skip m2) || fail "the round failed: $out"
git -C "$repo" merge-base --is-ancestor change/m6 main 2>/dev/null && fail "a mission nothing approved was landed"
ok
# ... after the stale limit it is one line a person answers
out=$(WA_DRIVE_STALE_HOURS=0 run_drive --skip m2) || fail "the stale round failed: $out"
grep -q '^m6: finished 0 h ago' "$missions/DECISIONS.md" || fail "no DECISIONS line for the unapproved m6: $(cat "$missions/DECISIONS.md")"
ok
[ "$(grep -c '^m6: ' "$missions/DECISIONS.md")" = 1 ] || fail "more than one line for m6"
ok
# ... and the answer `land` approves it: the line goes, the gate is asked, it lands
sed -i 's/^m6: .*/m6: land/' "$missions/DECISIONS.md"
out=$(run_drive --skip m2) || fail "the land answer did not land m6: $out"
git -C "$repo" merge-base --is-ancestor change/m6 main || fail "m6 is not on main after the land answer: $out"
ok
grep -q '^m6: ' "$missions/DECISIONS.md" && fail "the answered line for m6 is still there"
ok

# ---- 10. the answer `retire` takes a mission out, and keeps its directory -------------------------------
sed -i 's/^m4: .*/m4: retire/' "$missions/DECISIONS.md"
out=$(run_drive --skip m2) || fail "the retire round failed: $out"
[ -f "$missions/m4/RETIRED" ] || fail "m4 was not retired: $out"
ok
grep -q '^m4: ' "$missions/DECISIONS.md" && fail "the answered line for m4 is still there"
ok
[ -d "$missions/m4" ] || fail "retire deleted the mission directory"
ok
# a HOLD file keeps a ready mission back, by name
make_mission m7 2 green ok; add_branch m7; echo "waits for something" > "$missions/m7/HOLD"
out=$(run_drive --skip m2) || fail "the hold round failed: $out"
git -C "$repo" merge-base --is-ancestor change/m7 main 2>/dev/null && fail "a held mission was landed"
ok
rm -f "$missions/m7/HOLD"; echo x > "$missions/m7/RETIRED"

# ---- 11. the queue launches itself ----------------------------------------------------------------------
cat > "$work/launch" <<'STUB'
#!/usr/bin/env bash
[ -f "$MISSIONS_DIR/$1/brief.md" ] || { echo "no brief for $1"; exit 1; }
[ "$1" = qfail ] && { echo "the launcher broke"; exit 7; }
echo "$1" >> "$MISSIONS_DIR/launch.calls"
STUB
chmod +x "$work/launch"
printf 'q-running-1\nq-running-2\n' > "$work/running.list"
mkdir -p "$missions/_queue"
brief() {  # <file> <header lines...>
  local f=$missions/_queue/$1; shift
  { for h in "$@"; do printf '%s\n' "$h"; done; printf '\n# a queued brief\n\n## How Victor tests it\nlook at it\n'; } > "$f"
}
brief qa.md 'priority: 2' 'after: m1'
brief qb.md 'priority: 1' 'after: m1, notyet'
brief qc.md 'after: m1'
brief qd.md 'priority: 1' 'hold: waits for a person'
brief qe.md 'priority: 3'
printf 'priority: 4\n\n# a brief with no test section\n' > "$missions/_queue/qf.md"
brief qfail.md 'priority: 5'
brief qg.md 'priority: 0' 'name: m1'
run_launch() {  # <max workers> <extra args...>
  local max=$1; shift
  ( cd "$missions" && WA_MISSIONS_ROOT="$missions" WA_DRIVE_REPO="$repo" WA_LAND="$work/land" \
    WA_DRIVE_INSTALL=none WA_DRIVE_HEALTH=none WA_DRIVE_CHANGELOG="$changelog" \
    WA_DRIVE_PREFLIGHT="$work/preflight" WA_DRIVE_LAUNCH="$work/launch" \
    WA_DRIVE_RUNNING="cat $work/running.list" WA_DRIVE_MAX_WORKERS="$max" bash "$drive" --skip m2 "$@" )
}
# no free slot: nothing is launched, nothing is moved
out=$(run_launch 2) || fail "the launch round failed: $out"
[ ! -f "$missions/launch.calls" ] || fail "a brief was launched with no free slot: $(cat "$missions/launch.calls")"
ok
[ -f "$missions/_queue/qa.md" ] || fail "a brief left the queue with no free slot"
ok
# a dry run says what it would do and moves nothing
out=$(run_launch 9 --dry-run) || fail "the launch dry run failed: $out"
grep -q 'would launch qa' <<< "$out" || fail "the dry run does not offer qa: $out"
ok
grep -q 'qb waits for: notyet' <<< "$out" || fail "the dry run does not say what qb waits for: $out"
ok
[ -f "$missions/_queue/qa.md" ] || fail "a dry run moved a brief"
ok
# one free slot: the lowest priority number that is ready goes, and only that one
out=$(run_launch 3) || fail "the one-slot round failed: $out"
[ "$(cat "$missions/launch.calls")" = qa ] || fail "with one slot, not exactly qa was launched: $(cat "$missions/launch.calls" 2>/dev/null) / $out"
ok
[ -f "$missions/qa/brief.md" ] && [ ! -f "$missions/_queue/qa.md" ] || fail "qa's brief was not MOVED (one copy)"
ok
# plenty of slots: qe goes; qb (after not on main), qc (no priority), qd (hold) stay; qf and qg and qfail are asked
out=$(run_launch 9) || fail "the many-slot round failed: $out"
grep -q '^qe$' "$missions/launch.calls" || fail "qe was not launched: $out"
ok
for kept in qb qc qd; do [ -f "$missions/_queue/$kept.md" ] || fail "$kept left the queue: $out"; done
ok
grep -q '^qb$\|^qc$\|^qd$\|^qf$\|^m1$' "$missions/launch.calls" && fail "something that must wait was launched: $(cat "$missions/launch.calls")"
ok
grep -q "^qf: the queued brief .* has no '## How Victor tests it' section" "$missions/DECISIONS.md" || fail "no DECISIONS line for the brief without a test section: $(cat "$missions/DECISIONS.md")"
ok
grep -q '^m1: the queued brief .* already exists' "$missions/DECISIONS.md" || fail "no DECISIONS line for a brief naming an existing mission"
ok
grep -q '^qfail: its launch failed (exit 7' "$missions/DECISIONS.md" || fail "no DECISIONS line for the failed launch: $(cat "$missions/DECISIONS.md")"
ok
# `after:` is satisfied the round its mission is on main: qb waits for "notyet", which lands now
make_mission notyet 1 green ok; add_branch notyet
out=$(run_launch 9) || fail "the round that lands notyet failed: $out"
grep -q '^qb$' "$missions/launch.calls" || fail "qb was not launched in the round its after: landed: $out"
ok
[ -f "$missions/.drive/heartbeat" ] || fail "no heartbeat was written"
ok

# ---- 12. a landing is judged by ORIGIN's main, and the checkout follows it ------------------------------
# `wa land` pushes to origin and never moves the checkout's own main (measured 21/11). The first version of
# this script read the checkout's main and would have called every real landing red.
git_c init -q --bare -b main "$work/origin.git" && git_c remote add origin "$work/origin.git" \
  && git_c push -q origin main && git_c fetch -q origin || fail "the scratch origin did not set up"
cat > "$work/land-push" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
branch=""
while [ $# -gt 0 ]; do case $1 in --branches) branch=$2; shift 2 ;; *) shift ;; esac; done
g() { git -c user.email=test@example.invalid -c user.name=Test -c commit.gpgsign=false "$@"; }
tmp=$(mktemp -d); g clone -q "$ORIGIN_DIR" "$tmp/c" && cd "$tmp/c" || exit 1
g fetch -q "$REPO_DIR" "$branch" && g merge -q --no-ff --no-edit -m "land ${branch#change/}" FETCH_HEAD && g push -q origin HEAD:main || exit 1
[ "${branch#change/}" = m9 ] && { echo "land: STOPPED at sign: the vault did not answer"; exit 1; }
exit 0
STUB
chmod +x "$work/land-push"
make_mission m8 1 green ok; add_branch m8
local_before=$(git_c rev-parse main)
STUBPF=$work/preflight-origin
cat > "$STUBPF" <<'STUB'
#!/usr/bin/env bash
main=$(git -C "$REPO_DIR" rev-parse origin/main)
jq -n --arg main "$main" --arg branch "change/$1" '{ok:true, branch:$branch, main_sha:$main, failed:[], main_red:[]}' > "$MISSIONS_DIR/$1/preflight.json"
STUB
chmod +x "$STUBPF"
run_origin() {
  ( cd "$missions" && ORIGIN_DIR="$work/origin.git" WA_MISSIONS_ROOT="$missions" WA_DRIVE_REPO="$repo" \
    WA_LAND="$work/land-push" WA_DRIVE_INSTALL=none WA_DRIVE_HEALTH=none WA_DRIVE_CHANGELOG="$changelog" \
    WA_DRIVE_PREFLIGHT="$STUBPF" bash "$drive" --skip m2 "$@" )
}
out=$(run_origin) || fail "a landing that only moved origin's main was called red: $out $(cat "$missions/ATTENTION" 2>/dev/null)"
ok
grep -q 'drive: m8 landed' <<< "$out" || fail "m8 is not reported landed: $out"
ok
[ "$(git_c rev-parse main)" != "$local_before" ] && git_c merge-base --is-ancestor change/m8 main || fail "the checkout was not fast-forwarded to origin's main"
ok
grep -q '^- m8: ' "$changelog" || fail "the changelog has no entry for m8"
ok

# ---- 13. main moved and THEN a release step stopped: landed, and one line for a person ------------------
make_mission m9 1 green ok; add_branch m9
out=$(run_origin) || fail "a landing that moved main and stopped at a release step was called red: $out"
ok
grep -q 'drive: m9 landed' <<< "$out" || fail "m9 is not reported landed: $out"
ok
[ ! -f "$missions/ATTENTION" ] || fail "a release stop wrote ATTENTION"
ok
grep -q '^release-after-m9: the landing moved main and then stopped (exit 1: land: STOPPED at sign' "$missions/DECISIONS.md" || fail "no DECISIONS line for the stopped release: $(cat "$missions/DECISIONS.md")"
ok

# ---- 14. the site file sets the defaults and the environment wins ---------------------------------------
printf 'WA_DRIVE_MAX_WORKERS=0\nWA_LAND=/nonexistent/land\n' > "$missions/drive.conf"
brief qz.md 'priority: 1'
out=$(run_launch 9 --dry-run) || fail "the conf round failed: $out"
grep -q 'would launch qz' <<< "$out" || fail "the environment did not win over drive.conf: $out"
ok
out=$( cd "$missions" && WA_MISSIONS_ROOT="$missions" WA_DRIVE_REPO="$repo" WA_DRIVE_LAUNCH="$work/launch" \
  WA_DRIVE_RUNNING="cat $work/running.list" bash "$drive" --skip m2 --dry-run ) || fail "the conf-only round failed: $out"
grep -q 'qz is ready and waits for a worker slot' <<< "$out" || fail "drive.conf was not read: $out"
ok

echo "test-drive ok ($checks checks)"
