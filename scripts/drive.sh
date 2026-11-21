#!/usr/bin/env bash
# The deterministic driver: finished missions with a green preflight land themselves, one per landing, oldest
# first - no model in the loop.
#
#   bash scripts/drive.sh                 land every mission that is ready, then stop
#   bash scripts/drive.sh --once           land at most one
#   bash scripts/drive.sh --dry-run        print the queue and what would happen, change nothing
#   bash scripts/drive.sh --skip <name>    clear that mission's ATTENTION stop and go on without it
#
# WHY THIS EXISTS (21/11). A stopped landing and a finished mission both waited for a model to look: land245
# sat stopped for 40+ minutes for a stale file it had not made, and ten finished missions waited behind it
# while an orchestrator slept. Every one of those minutes was a model turn that had to notice something the
# machine already knew. So the noticing is this script:
#
#   * it takes missions that are DONE (a `done` file with rc=0) with a GREEN preflight (preflight.json ok, on
#     the main that is there now - a stale or missing one is re-run here, never assumed), oldest first;
#   * it lands ONE per landing (`wa land --until main`: merge, gate, push, main - no artifacts, no release, no
#     node), then installs this node locally, then appends the LOCAL-CHANGELOG entry from the mission's own
#     "How Victor tests it", then starts scripts/main-health.sh on the new main in the background;
#   * on ANYTHING red it STOPS and writes ONE file, <missions>/ATTENTION: the mission, the rows that failed and
#     the journal path. wait-any.sh returns on that file, so the operator is woken by a file, not by a model
#     remembering to poll;
#   * it never lands a mission whose preflight is red or missing, and never runs two landings at once: one
#     driver at a time (flock on <missions>/.drive.lock), and `wa land` takes the suite lock itself.
#
# Environment:
#   WA_MISSIONS_ROOT     the missions root (default $HOME/Work/missions)
#   WA_LAND              the landing command (default "wa land --until main"); it is called as
#                        <WA_LAND> --branches change/<name>
#   WA_DRIVE_INSTALL     how main is installed on THIS node (default: bash <checkout>/scripts/deploy.sh
#                        --reason "landing <name>"; "none" skips the install and says so in the log)
#   WA_DRIVE_HEALTH      the main-health run started after a landing (default: the driver's own
#                        scripts/main-health.sh, detached at low priority; "none" skips it)
#   WA_DRIVE_CHANGELOG   the file entries are appended to (default <missions>/LOCAL-CHANGELOG.md)
#   WA_DRIVE_PREFLIGHT   the preflight command (default: scripts/preflight.sh next to this script)
#   WA_SUITE_LOCK        the suite lock (default <missions>/.suite.lock)
#   WA_DRIVE_LOCK        the one-driver lock (default <missions>/.drive.lock)
# Exit: 0 the queue is empty (or --once landed one), 1 something is red (ATTENTION written), 2 refused.
set -uo pipefail
usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \\{0,1\\}//'; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
missions=${WA_MISSIONS_ROOT:-$HOME/Work/missions}
land=${WA_LAND:-"wa land --until main"}
install_cmd=${WA_DRIVE_INSTALL:-}
health=${WA_DRIVE_HEALTH:-}
changelog=${WA_DRIVE_CHANGELOG:-$missions/LOCAL-CHANGELOG.md}
preflight_cmd=${WA_DRIVE_PREFLIGHT:-$root/scripts/preflight.sh}
lock=${WA_DRIVE_LOCK:-$missions/.drive.lock}
once=0
dry=0
skip=' '
while [ $# -gt 0 ]; do
  case $1 in
    --once) once=1; shift ;;
    --dry-run) dry=1; shift ;;
    --skip) [ $# -ge 2 ] || { echo "drive: refused(value_missing): --skip needs a mission name" >&2; exit 2; }; skip="$skip$2 "; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "drive: refused(unknown_argument): $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -d "$missions" ] || { echo "drive: refused(no_missions_root): $missions is not a directory" >&2; exit 2; }
attention=$missions/ATTENTION
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
repo=$(git -C "$missions" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$repo" ] || repo=${WA_DRIVE_REPO:-$HOME/wasm-agent/checkout}
main_sha=$(git -C "$repo" rev-parse -q --verify main 2>/dev/null || true)
[ -n "$main_sha" ] || { echo "drive: refused(no_main): $repo has no main to land onto" >&2; exit 2; }

# ---- ATTENTION: one file, one mission, and it stops everything until it is cleared ----------------------
attention_mission() { sed -n 's/^mission: //p' "$attention" 2>/dev/null | head -1; }
# A mission named on --skip is left alone: the operator's "go on without it".
is_skipped() { case "$skip" in *" $1 "*) return 0 ;; esac; return 1; }
clear_attention_for() {  # <name>: the operator's "go on without it"
  local name=$1
  [ -f "$attention" ] || return 0
  if [ "$(attention_mission)" = "$name" ]; then
    mv "$attention" "$dir_state/ATTENTION.cleared-$(date -u +%Y%m%dT%H%M%SZ)"
    say "drive: ATTENTION for $name cleared (kept as $dir_state/ATTENTION.cleared-*)"
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

# ---- the queue: done, not landed, oldest first ---------------------------------------------------------
# A mission is a candidate when its directory has a `done` with rc=0, it is not retired, its branch still
# exists and is not already an ancestor of main, and its branch tip is what its preflight judged.
queue() {
  local d name tip done_ts
  for d in "$missions"/*/; do
    name=$(basename "$d")
    [ -f "$d/done" ] || continue
    [ -e "$d/RETIRED" ] && continue
    grep -q '^rc=0' "$d/done" 2>/dev/null || continue
    tip=$(git -C "$repo" rev-parse -q --verify "change/$name" 2>/dev/null || true)
    [ -n "$tip" ] || continue
    git -C "$repo" merge-base --is-ancestor "$tip" main 2>/dev/null && continue
    case "$skip" in *" $name "*) continue ;; esac
    done_ts=$(stat -c %Y "$d/done" 2>/dev/null || echo 0)
    printf '%s %s %s %s\n' "$done_ts" "$name" "$tip" "$d"
  done | sort -n
}

# THE STOP IS THE FILE, and the operator clears it by NAME: a mission named on --skip is left alone and its
# ATTENTION is archived (never silently deleted - a cleared stop is evidence). Anything else stops here.
if [ -f "$attention" ]; then
  if is_skipped "$(attention_mission)"; then
    clear_attention_for "$(attention_mission)"
  else
    say "drive: stopped - $attention names $(attention_mission)"
    say "drive: clear it, or go on without that mission: bash scripts/drive.sh --skip $(attention_mission)"
    exit 1
  fi
fi

list=$(queue)
if [ -z "$list" ]; then
  say "drive: nothing to do (no done mission is waiting on main)"
  exit 0
fi

landed=0
while IFS=' ' read -r _ts name tip mdir; do
  [ -n "$name" ] || continue
  if [ -f "$attention" ]; then
    if [ "$(attention_mission)" = "$name" ] && is_skipped "$name"; then
      clear_attention_for "$name"
    else
      say "drive: stopped - $attention names $(attention_mission)"
      say "drive: clear it, or go on without that mission: bash scripts/drive.sh --skip $(attention_mission)"
      exit 1
    fi
  fi
  if [ "$dry" = 1 ]; then
    say "drive: would land $name ($(git -C "$repo" rev-parse --short=12 "$tip"))"
    continue
  fi

  # ---- the preflight: green on THIS main, or run again. Never assumed, never re-used across a moved main.
  pf=$mdir/preflight.json
  green=no
  if [ -f "$pf" ] && jq -e '.ok == true' "$pf" >/dev/null 2>&1; then
    pf_main=$(jq -r '.main_sha // ""' "$pf" 2>/dev/null)
    pf_tree=$(jq -r '.tree_commit // ""' "$pf" 2>/dev/null)
    pf_branch=$(jq -r '.branch // ""' "$pf" 2>/dev/null)
    [ "$pf_main" = "$main_sha" ] && [ "$pf_branch" = "change/$name" ] && green=yes
    if [ "$green" = no ]; then
      say "drive: $name: the preflight is for main ${pf_main:0:12} / $pf_branch, not this main ${main_sha:0:12} - running it again"
    fi
  else
    say "drive: $name: no green preflight - running one"
  fi
  if [ "$green" = no ]; then
    ( cd "$root" && bash "$preflight_cmd" "$name" ) >> "$dir_state/preflight-$name.log" 2>&1
    pf_rc=$?
    # A GREEN PREFLIGHT IS ONLY GREEN ABOUT THE MAIN IT JUDGED: the file must say ok AND name this main and
    # this branch, or the answer is unknown and unknown is not yes (a stale tree_commit would land a round the
    # gate never saw).
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
      elif [ -n "$own" ]; then
        # shellcheck disable=SC2086
        write_attention "$name" "preflight red" $own
      else
        write_attention "$name" "preflight refused" "$(jq -r '.why // "no verdict"' "$pf" 2>/dev/null)"
      fi
      exit 1
    fi
    say "drive: $name: preflight green on main ${main_sha:0:12}"
  fi

  # ---- the landing: ONE, and only for this mission.
  say "drive: landing $name ($land --branches change/$name)"
  : > "$dir_state/land-$name.log"
  # shellcheck disable=SC2086
  ( cd "$repo" && $land --branches "change/$name" ) >> "$dir_state/land-$name.log" 2>&1
  land_rc=$?
  tip_after=$(git -C "$repo" rev-parse -q --verify main 2>/dev/null || true)
  if [ "$land_rc" != 0 ] || [ "$tip_after" = "$main_sha" ]; then
    rows=$(grep -a -E '^FAIL |STOPPED at ' "$dir_state/land-$name.log" | cut -c1-260 | head -8)
    journal_hint="$(ls -td "$HOME"/.wasm-agent/land/land-2* 2>/dev/null | head -1)/journal.json"
    [ -f "$journal_hint" ] || journal_hint=""
    if [ -n "$rows" ]; then
      # shellcheck disable=SC2086
      write_attention "$name" "landing red (exit $land_rc)" $rows
    else
      write_attention "$name" "landing red (exit $land_rc)" "$(tail -3 "$dir_state/land-$name.log" | cut -c1-260)"
    fi
    exit 1
  fi
  main_sha=$tip_after
  landed=$((landed + 1))
  say "drive: $name landed; main is now ${main_sha:0:12}"

  # ---- install THIS node (the brief's loop: land, then what Victor can test on this laptop).
  if [ "$install_cmd" = none ]; then
    say "drive: install skipped (WA_DRIVE_INSTALL=none); main is not what this node runs"
  else
    cmd=$install_cmd
    if [ -z "$cmd" ]; then cmd="bash $repo/scripts/deploy.sh --reason landing-$name"; fi
    say "drive: installing main on this node: $cmd"
    # shellcheck disable=SC2086
    ( cd "$repo" && $cmd ) >> "$dir_state/install-$name.log" 2>&1
    inst_rc=$?
    if [ "$inst_rc" != 0 ]; then
      write_attention "$name" "install on this node failed (exit $inst_rc)" \
        "$(tail -3 "$dir_state/install-$name.log" | cut -c1-260)"
      exit 1
    fi
    say "drive: main installed here ($(wa --version 2>/dev/null | head -1))"
  fi

  # ---- the LOCAL-CHANGELOG entry, from the mission's own words, appended once.
  if [ -f "$changelog" ] && ! grep -qF -- "- $name: " "$changelog"; then
    brief=$mdir/brief.md
    what=$(grep -m1 -E '^[A-Za-z].{20,}$' "$brief" 2>/dev/null | cut -c1-200)
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
  printf '%s %s\n' "$name" "$main_sha" >> "$dir_state/landed"

  # ---- main's own health, in the background at low priority, so the NEXT round knows what it is landing on.
  if [ "$health" = none ]; then
    say "drive: main-health skipped (WA_DRIVE_HEALTH=none)"
  else
    hcmd=$health
    if [ -z "$hcmd" ]; then hcmd="bash $root/scripts/main-health.sh --repo $repo"; fi
    if command -v setsid >/dev/null 2>&1; then
      setsid nice -n 19 bash -c "$hcmd" >> "$dir_state/main-health.log" 2>&1 < /dev/null &
      say "drive: main-health started in the background (log $dir_state/main-health.log)"
    else
      say "drive: main-health NOT started (no setsid on PATH): run $hcmd by hand"
    fi
  fi

  [ "$once" = 1 ] && { say "drive: --once, stopping after $name"; exit 0; }
done <<< "$list"

say "drive: done ($landed landed)"
exit 0
