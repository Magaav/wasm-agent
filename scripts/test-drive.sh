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
[ -f "$drive" ] || { echo "test-drive: refused(no_script): $drive is missing"; exit 2; }

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
  printf 'rc=0 at %s\n' "$(date -u +%FT%TZ)" > "$d/done"
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

# ---- 7. a mission whose preflight is RED never lands ---------------------------------------------------
make_mission m4 5 red ok
git_c checkout -q -B change/m4 main && printf 'm4\n' > m4.txt && git_c add -A >/dev/null && git_c commit -q -m m4 && git_c checkout -q main count >/dev/null 2>&1 || true
# m2 is still red at landing, so it stays out of this run by name; the queue's next mission is m4.
out=$(run_drive --skip m2) && fail "a mission whose preflight is red landed: $out"
ok
grep -q 'drive: ATTENTION written for m4' <<< "$out" || fail "the red preflight did not stop the queue: $out"
ok
grep -q 'preflight red' "$missions/ATTENTION" || fail "ATTENTION does not say the preflight was red: $(cat "$missions/ATTENTION")"
ok
git -C "$repo" merge-base --is-ancestor change/m4 main 2>/dev/null && fail "m4 landed with a red preflight"
ok

echo "test-drive ok ($checks checks)"
