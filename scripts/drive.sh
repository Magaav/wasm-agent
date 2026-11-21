#!/usr/bin/env bash
# The deterministic driver: the factory's schedule, run by a script instead of remembered by a model.
#
#   bash scripts/drive.sh                 one round: answers, landings, launches - then stop
#   bash scripts/drive.sh --once           land at most one mission, launch nothing
#   bash scripts/drive.sh --dry-run        print what a round would do, change nothing
#   bash scripts/drive.sh --skip <name>    clear that mission's ATTENTION stop and go on without it
#   bash scripts/drive.sh --loop [seconds] a round every <seconds> (default 60), for ever (the service form)
#
# WHY THIS EXISTS (21/11). The schedule - what is ready to land, what runs after what, what waits on a person -
# lived in an orchestrator model's context, and a context is lost at every compact, handover and idle turn:
# land245 sat stopped for 40 minutes, ten finished missions waited behind it, two staged briefs were never
# launched for 4 and 6 hours, and five decisions waited 9-33 hours in a chat nobody was reading. Each was found
# by a person asking "is anything stale?". So the noticing and the remembering are this script, and a model is
# asked only for judgement.
#
# ONE ROUND, in this order:
#   1. ANSWERS. <missions>/DECISIONS.md is the one file of what waits on a person. A line a person rewrote as
#      `<mission>: land`, `<mission>: retire` or `<mission>: again: <text>` is acted on and removed.
#   2. LANDINGS. A mission is ready when its `done` says rc=0 AND (`preflight=green` - the worker's own gate
#      loop wrote that - OR a person approved it with a LAND file / a `land` answer), and it has no HOLD or
#      RETIRED file. Ready missions land one per landing, oldest first: the preflight is re-run when it is not
#      about the main that is there now, then the landing, then the local install, then the LOCAL-CHANGELOG
#      entry, then scripts/main-health.sh in the background.
#   3. LAUNCHES. A brief in <missions>/_queue/ that carries a `priority: <n>` header line is launched when a
#      worker slot is free and every mission on its `after:` line is on main. The brief is MOVED to
#      <missions>/<name>/brief.md, so one copy exists. A brief with no `priority:` line is never launched by
#      this script (that folder also holds notes and old briefs); `hold: <reason>` keeps one back by name.
#
# WHO IS TOLD WHAT:
#   * ATTENTION (one file) stops every landing until it is cleared: a landing that went red, MAIN RED, a
#     preflight that judged nothing, a local install that failed. wait-any.sh returns on it.
#   * DECISIONS.md gets one line for what does not stop the line but needs a person: a finished mission nobody
#     approved for 12 h, a mission whose gate went red on a main that moved (after one automatic `again`), a
#     brief that cannot be launched, a release step that stopped after main had moved.
#   * <missions>/.drive/heartbeat is touched every round, so status.sh can say when no driver is running.
#
# WHAT A LANDING IS JUDGED BY: the mission's branch tip being an ancestor of origin/main after the landing
# command returned (the local `main` when the repository has no origin). NOT by the checkout's own `main`
# moving: `wa land` pushes and never moves it (measured 21/11 - the first version of this script would have
# called every real landing red). The checkout is fast-forwarded here when it is on main and clean.
#
# Site settings live in <missions>/drive.conf (shell, sourced; the environment wins over it):
#   WA_LAND              the landing command, called as <WA_LAND> --branches change/<name>
#                        (default "wa land --until main")
#   WA_DRIVE_LAND_LOCK   1 (default): the landing runs under the suite lock; 0 when WA_LAND takes it itself
#   WA_DRIVE_INSTALL     how main is installed on THIS node (default: bash <checkout>/scripts/deploy.sh
#                        --reason landing-<name>; "none" skips it and says so)
#   WA_DRIVE_HEALTH      the main-health run after a landing (default scripts/main-health.sh; "none" skips)
#   WA_DRIVE_PREFLIGHT   the preflight command (default scripts/preflight.sh next to this script)
#   WA_DRIVE_LAUNCH      the launcher, called as <WA_DRIVE_LAUNCH> <name> (default: <missions>/launch.sh <name>
#                        origin/main && <missions>/start.sh <name>)
#   WA_DRIVE_AGAIN       the hook that sends a mission back to its own worker, called as <hook> <name> <text>
#                        (default <missions>/again.sh when it exists; without one the answer waits, by name)
#   WA_DRIVE_RUNNING     a command printing the names of the missions running now, one per line
#                        (default: the active systemd user units mission-<name>)
#   WA_DRIVE_MAX_WORKERS how many missions may run at once (default 3)
#   WA_DRIVE_STALE_HOURS a finished, unapproved mission gets its DECISIONS line after this (default 12)
#   WA_MISSIONS_ROOT, WA_DRIVE_REPO, WA_DRIVE_CHANGELOG, WA_SUITE_LOCK, WA_DRIVE_LOCK  the paths
# Exit (one round): 0 nothing is red, 1 ATTENTION is written or still there, 2 refused.
set -uo pipefail
usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
missions=${WA_MISSIONS_ROOT:-$HOME/Work/missions}
once=0; dry=0; loop=0; tick=60; skip=' '
while [ $# -gt 0 ]; do
  case $1 in
    --once) once=1; shift ;;
    --dry-run) dry=1; shift ;;
    --loop) loop=1; shift; case ${1:-} in ''|-*) ;; *[!0-9]*) echo "drive: refused(bad_value): --loop takes seconds, got $1" >&2; exit 2 ;; *) tick=$1; shift ;; esac ;;
    --skip) [ $# -ge 2 ] || { echo "drive: refused(value_missing): --skip needs a mission name" >&2; exit 2; }; skip="$skip$2 "; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "drive: refused(unknown_argument): $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -d "$missions" ] || { echo "drive: refused(no_missions_root): $missions is not a directory" >&2; exit 2; }

# THE SITE'S SETTINGS, and the environment wins: every name the file may set is saved first and put back.
conf=$missions/drive.conf
if [ -f "$conf" ]; then
  saved=$(for v in WA_LAND WA_DRIVE_LAND_LOCK WA_DRIVE_INSTALL WA_DRIVE_HEALTH WA_DRIVE_PREFLIGHT WA_DRIVE_LAUNCH \
                   WA_DRIVE_AGAIN WA_DRIVE_RUNNING WA_DRIVE_MAX_WORKERS WA_DRIVE_STALE_HOURS WA_DRIVE_REPO \
                   WA_DRIVE_CHANGELOG WA_SUITE_LOCK WA_DRIVE_LOCK; do
            [ -n "${!v+x}" ] && printf '%s=%q\n' "$v" "${!v}"; done)
  # shellcheck disable=SC1090
  . "$conf" || { echo "drive: refused(conf_unreadable): $conf did not load" >&2; exit 2; }
  eval "$saved"
fi
land=${WA_LAND:-"wa land --until main"}
land_lock=${WA_DRIVE_LAND_LOCK:-1}
install_cmd=${WA_DRIVE_INSTALL:-}
health=${WA_DRIVE_HEALTH:-}
changelog=${WA_DRIVE_CHANGELOG:-$missions/LOCAL-CHANGELOG.md}
preflight_cmd=${WA_DRIVE_PREFLIGHT:-$root/scripts/preflight.sh}
launch_cmd=${WA_DRIVE_LAUNCH:-}
again_cmd=${WA_DRIVE_AGAIN:-}
running_cmd=${WA_DRIVE_RUNNING:-}
max_workers=${WA_DRIVE_MAX_WORKERS:-3}
stale_hours=${WA_DRIVE_STALE_HOURS:-12}
lock=${WA_DRIVE_LOCK:-$missions/.drive.lock}
suite_lock=${WA_SUITE_LOCK:-$missions/.suite.lock}
attention=$missions/ATTENTION
decisions=$missions/DECISIONS.md
queue_dir=$missions/_queue
dir_state=$missions/.drive
mkdir -p "$dir_state" || { echo "drive: refused(root_unwritable): $dir_state" >&2; exit 2; }

say() { printf '%s\n' "$*"; }
stamp() { date -u +%FT%TZ; }

# ONE DRIVER AT A TIME, and it is the kernel's lock, not a file somebody has to clean up after a crash.
exec 9>"$lock"
flock -n 9 || { echo "drive: refused(another_driver): $lock is held by another drive.sh; two landings never run at once" >&2; exit 2; }

for tool in git jq flock; do
  command -v "$tool" >/dev/null 2>&1 || { echo "drive: refused(tool_missing): $tool is not on PATH" >&2; exit 2; }
done
repo=${WA_DRIVE_REPO:-}
[ -n "$repo" ] || repo=$(git -C "$missions" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$repo" ] || repo=$HOME/wasm-agent/checkout

# ---- main: origin's when there is an origin, and the checkout follows it ---------------------------------
# refresh_main sets main_ref and main_sha. With an origin it fetches (a failed fetch keeps the last known
# origin/main and says so: the next comparison is then about an older main, and the preflight's own main_sha
# check refuses a verdict that is not about it) and fast-forwards the checkout when it is on main and clean.
main_ref=main; main_sha=""
refresh_main() {
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    main_ref=origin/main
    if [ "$dry" = 0 ]; then
      git -C "$repo" fetch -q origin main 2>/dev/null || say "drive: git fetch origin main failed; using the last known origin/main"
      if [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] \
         && [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        git -C "$repo" merge -q --ff-only origin/main >/dev/null 2>&1 || true
      fi
    fi
  else
    main_ref=main
  fi
  main_sha=$(git -C "$repo" rev-parse -q --verify "$main_ref" 2>/dev/null || true)
}
on_main() {  # <mission>: its branch is on main, or this driver recorded its landing
  local tip
  tip=$(git -C "$repo" rev-parse -q --verify "change/$1" 2>/dev/null || true)
  if [ -n "$tip" ]; then git -C "$repo" merge-base --is-ancestor "$tip" "$main_ref" 2>/dev/null; return; fi
  grep -q "^$1 " "$dir_state/landed" 2>/dev/null
}

# ---- ATTENTION: one file, one mission, and it stops every landing until it is cleared -------------------
attention_mission() { sed -n 's/^mission: //p' "$attention" 2>/dev/null | head -1; }
is_skipped() { case "$skip" in *" $1 "*) return 0 ;; esac; return 1; }
clear_attention_for() {  # <name>: the operator's "go on without it"
  [ -f "$attention" ] || return 0
  if [ "$(attention_mission)" = "$1" ]; then
    mv "$attention" "$dir_state/ATTENTION.cleared-$(date -u +%Y%m%dT%H%M%SZ)"
    say "drive: ATTENTION for $1 cleared (kept as $dir_state/ATTENTION.cleared-*)"
  fi
}
write_attention() {  # <mission> <kind> <rows...> ; journal path in $journal_hint
  local name=$1 kind=$2; shift 2
  {
    echo "# ATTENTION - written by scripts/drive.sh at $(stamp); nothing lands until this is cleared."
    echo "# A person (or the orchestrator's model) reads this file and nothing else: it names the mission,"
    echo "# the rows that failed and the journal to open. wait-any.sh returns when this file appears."
    echo "mission: $name"
    echo "kind: $kind"
    echo "at: $(stamp)"
    echo "main: ${main_sha:0:12} ($repo)"
    echo "rows:"
    local row
    for row in "$@"; do echo "  - $row"; done
    [ -n "${journal_hint:-}" ] && echo "journal: $journal_hint"
    [ -f "$missions/$name/preflight.json" ] && echo "preflight: $missions/$name/preflight.json"
    [ -f "$dir_state/land-$name.log" ] && echo "land log: $dir_state/land-$name.log"
    echo "next: fix it, then \`bash scripts/drive.sh --skip $name\` (or delete this file) and run drive.sh again"
    echo "      a row that is MAIN RED is not this mission's fault: fix main first, by one landing whose only purpose it is"
  } > "$attention.tmp" && mv "$attention.tmp" "$attention"
  say "drive: ATTENTION written for $name ($kind) -> $attention"
}

# ---- DECISIONS.md: one line per open question, answered by rewriting the line ----------------------------
decisions_header='# What waits on Victor - rewrite a line as `<mission>: land`, `<mission>: retire` or `<mission>: again: <text>`'
has_decision() { grep -q "^$1: " "$decisions" 2>/dev/null; }
add_decision() {  # <mission> <question - recommended: answer>   (one line per mission, never a second)
  has_decision "$1" && return 0
  [ "$dry" = 1 ] && { say "drive: would ask in DECISIONS.md - $1: $2"; return 0; }
  [ -f "$decisions" ] || printf '%s\n\n' "$decisions_header" > "$decisions"
  printf '%s: %s\n' "$1" "$2" >> "$decisions"
  say "drive: asked in DECISIONS.md - $1: $2"
}
drop_decision() {  # <mission>
  [ -f "$decisions" ] || return 0
  grep -v "^$1: " "$decisions" > "$decisions.tmp"; mv "$decisions.tmp" "$decisions"
}
send_again() {  # <mission> <text> -> 0 sent, 1 no hook or the hook failed
  local hook=$again_cmd
  [ -n "$hook" ] || { [ -f "$missions/again.sh" ] && hook="bash $missions/again.sh"; }
  [ -n "$hook" ] || return 1
  # shellcheck disable=SC2086
  $hook "$1" "$2" >> "$dir_state/again-$1.log" 2>&1
}
answers() {
  [ -f "$decisions" ] || return 0
  local line name answer text
  while IFS= read -r line; do
    name=${line%%:*}; answer=${line#*: }
    case "$name" in ''|'#'*|*[!A-Za-z0-9_.-]*) continue ;; esac
    [ "$name" != "$line" ] || continue
    answer=$(printf '%s' "$answer" | sed 's/[[:space:]]*$//')
    case "$answer" in
      land)
        [ -d "$missions/$name" ] || { say "drive: DECISIONS.md says land $name, and there is no such mission - the line stays"; continue; }
        [ "$dry" = 1 ] && { say "drive: would approve $name for landing (DECISIONS.md)"; continue; }
        stamp > "$missions/$name/LAND"; drop_decision "$name"
        say "drive: $name approved for landing (DECISIONS.md); its gate is asked before it lands" ;;
      retire)
        [ -d "$missions/$name" ] || { say "drive: DECISIONS.md says retire $name, and there is no such mission - the line stays"; continue; }
        [ "$dry" = 1 ] && { say "drive: would retire $name (DECISIONS.md)"; continue; }
        printf 'retired %s by an answer in DECISIONS.md\n' "$(stamp)" > "$missions/$name/RETIRED"; drop_decision "$name"
        say "drive: $name retired (DECISIONS.md); its directory and branch are kept" ;;
      again|again:*)
        text=$(printf '%s' "${answer#again}" | sed 's/^:[[:space:]]*//')
        [ "$dry" = 1 ] && { say "drive: would send $name back to its worker (DECISIONS.md): ${text:-no text}"; continue; }
        if send_again "$name" "$text"; then
          drop_decision "$name"; say "drive: $name sent back to its worker (DECISIONS.md)"
        else
          say "drive: DECISIONS.md says again for $name, and no again hook answered (WA_DRIVE_AGAIN or $missions/again.sh) - the line stays"
        fi ;;
    esac
  done < <(cat "$decisions")
}

# ---- the queue of landings: done, approved, not landed, oldest first --------------------------------------
ready=""        # "ts name tip dir" lines
survey() {
  ready=""
  local d name tip done_ts now ageh
  now=$(date +%s)
  for d in "$missions"/*/; do
    name=$(basename "$d"); d=${d%/}
    [ -f "$d/done" ] || continue
    [ -e "$d/RETIRED" ] && continue
    [ -e "$d/HOLD" ] && continue
    tip=$(git -C "$repo" rev-parse -q --verify "change/$name" 2>/dev/null || true)
    [ -n "$tip" ] || continue
    git -C "$repo" merge-base --is-ancestor "$tip" "$main_ref" 2>/dev/null && continue
    is_skipped "$name" && continue
    done_ts=$(stat -c %Y "$d/done" 2>/dev/null || echo 0)
    if grep -q '^rc=0' "$d/done" 2>/dev/null && { grep -q 'preflight=green' "$d/done" 2>/dev/null || [ -e "$d/LAND" ]; }; then
      [ -e "$d/PARKED" ] && continue
      ready="$ready$done_ts $name $tip $d"$'\n'
      continue
    fi
    # NOT APPROVED BY ANYTHING: an old `done` with no gate verdict, a red one, a worker that failed. It is
    # never landed on a guess; after stale_hours it becomes one line a person answers.
    ageh=$(( (now - done_ts) / 3600 ))
    if [ "$ageh" -ge "$stale_hours" ]; then
      add_decision "$name" "finished ${ageh} h ago ($(cut -c1-40 "$d/done")), $(git -C "$repo" rev-list --count "$main_ref..$tip" 2>/dev/null || echo '?') commit(s) not on main, nothing approved it - recommended: ?"
    fi
  done
  ready=$(printf '%s' "$ready" | sort -n)
  # A DEAD WORKER: launched (run.sh and a `started` stamp), no `done`, and no unit running it. 21/11 the first
  # tui-fit worker died at 11:28 and nobody saw it for ten hours, because a mission with no `done` looks like
  # one that is still working. It becomes one line a person answers (`again` resumes its session).
  local alive; alive=$(running_names)
  for d in "$missions"/*/; do
    name=$(basename "$d"); d=${d%/}
    [ -f "$d/run.sh" ] && [ -f "$d/started" ] && [ ! -f "$d/done" ] || continue
    [ -e "$d/RETIRED" ] || [ -e "$d/HOLD" ] && continue
    printf '%s\n' "$alive" | grep -qx -- "$name" && continue
    # a launch or a resume is between its two steps for a moment: only a stamp older than 3 minutes counts
    [ $(( now - $(stat -c %Y "$d/started" 2>/dev/null || echo "$now") )) -ge 180 ] || continue
    add_decision "$name" "its worker is DEAD: launched $(cat "$d/started" 2>/dev/null | head -1), no done file, no unit running it - recommended: again"
  done
}

# ---- one landing ------------------------------------------------------------------------------------------
# -> 0 landed, 1 ATTENTION written (stop), 3 this mission was set aside and the line goes on
land_one() {  # <name> <tip> <dir>
  local name=$1 tip=$2 mdir=$3 pf=$3/preflight.json green=no pf_main pf_branch pf_rc pf_fresh rows own
  if [ -f "$pf" ] && jq -e '.ok == true' "$pf" >/dev/null 2>&1; then
    pf_main=$(jq -r '.main_sha // ""' "$pf" 2>/dev/null); pf_branch=$(jq -r '.branch // ""' "$pf" 2>/dev/null)
    [ "$pf_main" = "$main_sha" ] && [ "$pf_branch" = "change/$name" ] && green=yes
    [ "$green" = yes ] || say "drive: $name: the preflight is for main ${pf_main:0:12} / $pf_branch, not this main ${main_sha:0:12} - running it again"
  else
    say "drive: $name: no green preflight - running one"
  fi
  if [ "$green" = no ]; then
    ( cd "$root" && bash "$preflight_cmd" "$name" ) >> "$dir_state/preflight-$name.log" 2>&1
    pf_rc=$?
    # A GREEN PREFLIGHT IS ONLY GREEN ABOUT THE MAIN IT JUDGED: the file must say ok AND name this main and
    # this branch, or the answer is unknown and unknown is not yes.
    pf_fresh=no
    if jq -e '.ok == true' "$pf" >/dev/null 2>&1 \
       && [ "$(jq -r '.main_sha // ""' "$pf" 2>/dev/null)" = "$main_sha" ] \
       && [ "$(jq -r '.branch // ""' "$pf" 2>/dev/null)" = "change/$name" ]; then pf_fresh=yes; fi
    if [ "$pf_rc" != 0 ] || [ "$pf_fresh" = no ]; then
      rows=$(jq -r '(.main_red // [])[] | "MAIN RED " + .row + ": " + ((.first_lines // [""])[0] // "")' "$pf" 2>/dev/null)
      own=$(jq -r '(.failed // [])[] | .row + ": " + ((.first_lines // [""])[0] // "")' "$pf" 2>/dev/null)
      journal_hint=$(jq -r '.log // empty' "$pf" 2>/dev/null)
      if [ -n "$rows" ]; then
        # shellcheck disable=SC2086
        write_attention "$name" "preflight MAIN RED" $rows
        return 1
      elif [ -n "$own" ]; then
        # THE MISSION'S OWN ROWS, RED ON A MAIN THAT MOVED. That is the worker's to fix, and it does not stop
        # the line: once, the mission goes straight back to its own session with the rows; after that (or
        # with no hook) it is parked and becomes one line in DECISIONS.md. The next mission lands meanwhile.
        local first; first=$(printf '%s\n' "$own" | head -1 | cut -c1-160)
        if [ ! -e "$dir_state/again-$name.sent" ] && send_again "$name" "[drive] Your branch change/$name was green, then main moved, and its gate is now RED on main ${main_sha:0:12}. Fix these rows on your branch (merge or rebase onto main first) and do not weaken a test: $(printf '%s' "$own" | tr '\n' ';' | cut -c1-900) The whole report is $pf."; then
          stamp > "$dir_state/again-$name.sent"
          say "drive: $name: red on the new main ($first) - sent back to its own worker, the line goes on"
        else
          printf 'parked %s: red on main %s\n%s\n' "$(stamp)" "${main_sha:0:12}" "$own" > "$mdir/PARKED"
          add_decision "$name" "its gate is red on the current main ($first) - recommended: again"
          say "drive: $name: red on the new main ($first) - parked ($mdir/PARKED), the line goes on"
        fi
        return 3
      else
        write_attention "$name" "preflight refused" "$(jq -r '.why // "no verdict"' "$pf" 2>/dev/null)"
        return 1
      fi
    fi
    say "drive: $name: preflight green on main ${main_sha:0:12}"
  fi

  say "drive: landing $name ($land --branches change/$name)"
  : > "$dir_state/land-$name.log"
  local land_rc before=$main_sha
  if [ "$land_lock" = 1 ]; then
    # shellcheck disable=SC2086
    ( cd "$repo" && flock -o "$suite_lock" $land --branches "change/$name" ) >> "$dir_state/land-$name.log" 2>&1
  else
    # shellcheck disable=SC2086
    ( cd "$repo" && $land --branches "change/$name" ) >> "$dir_state/land-$name.log" 2>&1
  fi
  land_rc=$?
  refresh_main
  # LANDED MEANS THE BRANCH IS ON MAIN - whatever the command's exit code said. A landing that moved main and
  # then stopped at a release step (artifacts, sign, publish) HAS landed: the code is there, this node can
  # install it, and the release problem is one line for a person, never a reason to call the mission red.
  if ! git -C "$repo" merge-base --is-ancestor "$tip" "$main_ref" 2>/dev/null; then
    rows=$(grep -a -E '^FAIL |STOPPED at ' "$dir_state/land-$name.log" | cut -c1-260 | head -8)
    journal_hint="$(ls -td "$HOME"/.wasm-agent/land/land-2* 2>/dev/null | head -1)/journal.json"
    [ -f "$journal_hint" ] || journal_hint=""
    main_sha=$before
    if [ -n "$rows" ]; then
      local IFS=$'\n'
      # shellcheck disable=SC2086
      write_attention "$name" "landing red (exit $land_rc)" $rows
    else
      write_attention "$name" "landing red (exit $land_rc)" "$(tail -3 "$dir_state/land-$name.log" | cut -c1-260)"
    fi
    return 1
  fi
  say "drive: $name landed; main is now ${main_sha:0:12}"
  printf '%s %s %s\n' "$name" "$main_sha" "$(stamp)" >> "$dir_state/landed"
  rm -f "$mdir/LAND" "$dir_state/again-$name.sent"
  if [ "$land_rc" != 0 ]; then
    add_decision "release-after-$name" "the landing moved main and then stopped (exit $land_rc: $(grep -a -E 'STOPPED at ' "$dir_state/land-$name.log" | tail -1 | cut -c1-120)); nothing is wrong with the code - recommended: finish the release when one is wanted, then delete this line"
  fi

  # ---- install THIS node.
  if [ "$install_cmd" = none ]; then
    say "drive: install skipped (WA_DRIVE_INSTALL=none); main is not what this node runs"
  else
    local cmd=$install_cmd inst_rc
    [ -n "$cmd" ] || cmd="bash $repo/scripts/deploy.sh --reason landing-$name"
    say "drive: installing main on this node: $cmd"
    # shellcheck disable=SC2086
    ( cd "$repo" && $cmd ) >> "$dir_state/install-$name.log" 2>&1
    inst_rc=$?
    if [ "$inst_rc" != 0 ]; then
      journal_hint=""
      write_attention "$name" "install on this node failed (exit $inst_rc)" \
        "$(tail -3 "$dir_state/install-$name.log" | cut -c1-260)"
      return 1
    fi
    say "drive: main installed here ($(wa --version 2>/dev/null | head -1))"
  fi

  # ---- the LOCAL-CHANGELOG entry, from the mission's own words, appended once.
  if [ -f "$changelog" ] && ! grep -qF -- "- $name: " "$changelog"; then
    local brief=$mdir/brief.md what test_text default_test test_line
    what=$(grep -v -i -E '^(priority|after|hold|name):' "$brief" 2>/dev/null | grep -m1 -E '^[A-Za-z].{20,}$' | cut -c1-200)
    test_text=$(awk '/^## +How Victor tests it/{flag=1;next} /^## +/{flag=0} flag' "$brief" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-500)
    # No quotes inside a ${var:-word} default: bash parses the word again and an apostrophe there is a quote
    # character, which broke this script once (measured: "unexpected EOF while looking for matching `'`").
    default_test="the brief has no How Victor tests it section - read $mdir/brief.md"
    test_line=${test_text:-$default_test}
    {
      echo ""
      echo "## $(date -u '+%Y-%m-%d %H:%MZ') - local is ${main_sha:0:12}"
      echo "- $name: ${what:-landed}"
      echo "  test: $test_line"
      echo "  state: untested"
    } >> "$changelog"
    say "drive: appended the LOCAL-CHANGELOG entry for $name"
  fi

  # ---- main's own health, in the background at low priority, so the NEXT round knows what it is landing on.
  if [ "$health" = none ]; then
    say "drive: main-health skipped (WA_DRIVE_HEALTH=none)"
  else
    local hcmd=$health
    [ -n "$hcmd" ] || hcmd="bash $root/scripts/main-health.sh --repo $repo"
    if command -v setsid >/dev/null 2>&1; then
      # fd 9 is the one-driver lock: a detached child must not keep it, or no driver could start again
      # until the health run ended.
      setsid nice -n 19 bash -c "$hcmd" >> "$dir_state/main-health.log" 2>&1 < /dev/null 9>&- &
      say "drive: main-health started in the background (log $dir_state/main-health.log)"
    else
      say "drive: main-health NOT started (no setsid on PATH): run $hcmd by hand"
    fi
  fi
  return 0
}

# ---- the landings of one round -----------------------------------------------------------------------------
# -> 0 fine, 1 ATTENTION is there
landed=0
landings() {
  if [ -f "$attention" ]; then
    if is_skipped "$(attention_mission)"; then
      clear_attention_for "$(attention_mission)"
    else
      say "drive: stopped - $attention names $(attention_mission)"
      say "drive: clear it, or go on without that mission: bash scripts/drive.sh --skip $(attention_mission)"
      return 1
    fi
  fi
  survey
  if [ -z "$ready" ]; then
    say "drive: nothing to land (no finished mission is approved and waiting)"
    return 0
  fi
  local _ts name tip mdir rc
  while IFS=' ' read -r _ts name tip mdir; do
    [ -n "$name" ] || continue
    if [ "$dry" = 1 ]; then
      say "drive: would land $name ($(git -C "$repo" rev-parse --short=12 "$tip"))"
      continue
    fi
    # main may have moved under an earlier landing of this round: a branch that is on it now is done.
    git -C "$repo" merge-base --is-ancestor "$tip" "$main_ref" 2>/dev/null && continue
    land_one "$name" "$tip" "$mdir"; rc=$?
    [ "$rc" = 1 ] && return 1
    [ "$rc" = 0 ] && landed=$((landed + 1))
    [ "$once" = 1 ] && [ "$rc" = 0 ] && { say "drive: --once, stopping after $name"; return 0; }
  done <<< "$ready"
  return 0
}

# ---- the launches of one round ------------------------------------------------------------------------------
header() {  # <file> <key> -> the value of a "key: value" line among the first 15 lines
  sed -n '1,15p' "$1" 2>/dev/null | sed -n "s/^$2:[[:space:]]*//Ip" | head -1 | sed 's/[[:space:]]*$//'
}
running_names() {
  if [ -n "$running_cmd" ]; then
    # shellcheck disable=SC2086
    $running_cmd 2>/dev/null
  else
    systemctl --user list-units 'mission-*' --state=active,activating --no-legend --plain 2>/dev/null \
      | awk '{print $1}' | sed -n 's/^mission-\(.*\)\.service$/\1/p'
  fi
}
launches() {
  [ -d "$queue_dir" ] || return 0
  local f name prio hold after dep waits list="" running slots
  for f in "$queue_dir"/*.md; do
    [ -f "$f" ] || continue
    prio=$(header "$f" priority)
    case "$prio" in ''|*[!0-9]*) continue ;; esac     # no `priority:` line = not this script's to launch
    list="$list$prio $f"$'\n'
  done
  [ -n "$list" ] || return 0
  running=$(running_names | grep -c . || true)
  slots=$(( max_workers - running ))
  while IFS=' ' read -r prio f; do
    [ -n "$f" ] || continue
    name=$(header "$f" name); [ -n "$name" ] || name=$(basename "$f" .md)
    case "$name" in *[!A-Za-z0-9_.-]*|'') add_decision "queue-$(basename "$f" .md)" "the queued brief $f names a mission '$name' that is not a plain name - recommended: fix its name: line"; continue ;; esac
    hold=$(header "$f" hold)
    [ -n "$hold" ] && { [ "$dry" = 1 ] && say "drive: $name is held: $hold"; continue; }
    if [ -e "$missions/$name" ]; then
      add_decision "$name" "the queued brief $f wants to launch, and $missions/$name already exists - recommended: retire, or rename the brief"
      continue
    fi
    after=$(header "$f" after); waits=""
    for dep in $(printf '%s' "$after" | tr ',' ' '); do on_main "$dep" || waits="$waits $dep"; done
    [ -n "$waits" ] && { [ "$dry" = 1 ] && say "drive: $name waits for:$waits"; continue; }
    if ! grep -q -E '^## +How Victor tests it' "$f"; then
      add_decision "$name" "the queued brief $f has no '## How Victor tests it' section (FACTORY.md rule 5), so it is not launched - recommended: add the section"
      continue
    fi
    if [ "$slots" -le 0 ]; then
      [ "$dry" = 1 ] && say "drive: $name is ready and waits for a worker slot ($running of $max_workers running)"
      continue
    fi
    if [ "$dry" = 1 ]; then say "drive: would launch $name (priority $prio)"; slots=$((slots - 1)); continue; fi
    mkdir -p "$missions/$name" && mv "$f" "$missions/$name/brief.md" || { add_decision "$name" "could not move $f into $missions/$name - recommended: look at the disk"; continue; }
    say "drive: launching $name (priority $prio${after:+, after $after})"
    local lrc
    if [ -n "$launch_cmd" ]; then
      # shellcheck disable=SC2086
      $launch_cmd "$name" >> "$dir_state/launch-$name.log" 2>&1; lrc=$?
    else
      { bash "$missions/launch.sh" "$name" origin/main && bash "$missions/start.sh" "$name"; } >> "$dir_state/launch-$name.log" 2>&1; lrc=$?
    fi
    if [ "$lrc" != 0 ]; then
      add_decision "$name" "its launch failed (exit $lrc: $(tail -1 "$dir_state/launch-$name.log" 2>/dev/null | cut -c1-140)); the brief is in $missions/$name/brief.md - recommended: again"
      continue
    fi
    printf '%s %s\n' "$name" "$(stamp)" >> "$dir_state/launched"
    slots=$((slots - 1))
  done < <(printf '%s' "$list" | sort -n -k1,1 -k2,2)
}

# ---- one round ------------------------------------------------------------------------------------------------
round() {
  local rc=0
  refresh_main
  [ -n "$main_sha" ] || { echo "drive: refused(no_main): $repo has no $main_ref to land onto" >&2; return 2; }
  [ "$dry" = 1 ] || stamp > "$dir_state/heartbeat"
  answers
  landings || rc=1
  # A red landing stops LANDINGS. It is no reason to keep a worker slot empty, so launches go on - except
  # under --once, which is "land one and nothing else".
  [ "$once" = 1 ] || launches
  return $rc
}

if [ "$loop" = 1 ]; then
  say "drive: loop, one round every ${tick}s (missions $missions, repo $repo)"
  while :; do
    round > "$dir_state/round.log" 2>&1
    grep -v -E '^drive: (nothing to land|stopped - |clear it, or go on)' "$dir_state/round.log" | sed "s/^/$(stamp) /"
    sleep "$tick"
  done
fi
round; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$dry" = 1 ] || say "drive: done ($landed landed)"
exit $rc
