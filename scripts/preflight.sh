#!/usr/bin/env bash
# preflight.sh <mission> - "would the gate of this branch be green on the main that is there now?"
#
# THE QUESTION A MISSION HAS TO ANSWER BEFORE ANYBODY LANDS IT. `done` on a mission used to mean "the
# worker stopped talking"; the gate that decides whether it may land was run only at the landing, so a red
# one sent the round back by hand and the same minutes were paid again (measured: the gate failed in 10 of
# 16 landings on 20-21/11 and took 185 of ~225 landing minutes - ~/Work/missions/FACTORY.md). This runs
# that gate EARLY, on the branch, against the main that is there now, in the tree the landing would build.
#
# What it runs, exactly: `wa land --branches change/<NAME> --until gate`, i.e. collect, plan, review,
# merge, gate and the report - and no push, no main, no artifacts, no release, no node. The merged tree is
# created where a landing creates it (<land root>/<run>/tree), from the same base and by the same code, so
# a test that behaves differently in a landing tree behaves differently here too, and it is caught here.
#
# It writes <mission>/preflight.json:
#   {ok, run, branch, main_sha, tree_commit, tree_sha, seconds, gate_seconds, failed:[{row, first_lines}],
#    gate_evidence, log, result, why}
# ok is true only when the landing exited 0, the gate step is `done`, and no gate row failed - an unknown
# answer (no journal, no gate step, python missing) is false with a named `why`, never a pass.
#
# Exit: 0 green, 1 red, 2 refused (nothing was judged).
#
# Environment:
#   WA_BIN              the wa to run (default `wa`). Point it at a tree build to test an unlanded change.
#   WA_MISSIONS_ROOT    the missions root (default MISSION_ROOT, then ~/Work/missions)
#   WA_PREFLIGHT_BRANCH the branch to preflight (default change/<NAME>)
#   WA_PREFLIGHT_LAND_ROOT  the land root to read the journal from (default $WASM_AGENT_HOME/land)
#   WA_SUITE_LOCK       the suite lock (default <missions root>/.suite.lock)
#   WA_LAND_REPO / WA_LAND_INCOMING  passed through to `wa land` when set
#   WA_PYTHON           the interpreter that reads the journal (default python3)
#
# The canonical source of this file is scripts/preflight.sh in the wasm-agent tree; the operator's
# ~/Work/missions/preflight.sh is a symlink to the runtime tree's copy (see docs/missions/reports/
# factory-1.md), so `bash ~/Work/missions/preflight.sh <name>` and `wa mission preflight <name>` are the
# same script.
set -uo pipefail

NAME=${1:-}
if [ -z "$NAME" ] || [ "${NAME#-}" != "$NAME" ]; then
  echo "usage: preflight.sh <mission>    (a mission directory under the missions root)"
  exit 2
fi
MISSIONS=${WA_MISSIONS_ROOT:-${MISSION_ROOT:-$HOME/Work/missions}}
M=$MISSIONS/$NAME
if [ ! -d "$M" ]; then
  echo "preflight: refused(no_mission): $M is not a directory"
  exit 2
fi
# temp-retention: preflight mints no temp family. It asks the floor about /tmp and about TMPDIR; the trees
# it causes are the landing own, under <config>/land, and this file never creates one.
# THE TEMP FLOOR, ASKED BEFORE THE GATE IS PAID FOR (item 4 of the tests-clean-their-tmp round, 23/11).
#
# A preflight costs a full gate; a gate on a machine whose temp filesystem is full dies somewhere inside a row
# and the answer comes back as "this branch is red" - on 23/11 that happened three times in one day (/tmp is a
# 16 G tmpfs here, and the rows had left 4,721 entries in it). A full disk is a fact about the machine, so it
# is refused by name here, before the lock, before the landing and before any row: exit 2, nothing judged.
. "$(dirname -- "$0")/lib/temp-floor.sh"
if ! tmp_note=$(wa_tmp_floor_check /tmp "${TMPDIR:-}"); then
  case "$tmp_note" in
    tmp_unknown:*) tmp_code=tmp_unknown ;;
    *) tmp_code=tmp_low ;;
  esac
  echo "preflight: refused(${tmp_code:-tmp_low}): $tmp_note. Nothing was judged." >&2
  exit 2
fi
BRANCH=${WA_PREFLIGHT_BRANCH:-change/$NAME}
WA=${WA_BIN:-wa}
PY=${WA_PYTHON:-python3}
# THE LAND ROOT IS THE NODE OWN ANSWER, not a path this script guesses: "wa paths" prints the config
# directory the binary actually uses (it is <WASM_AGENT_HOME>/.wasm-agent when a scratch home is set, NOT
# <WASM_AGENT_HOME>), and the land root is <config>/land. Guessed, it was right for the default home and
# wrong for every other one - measured 21/11: the first replay wrote its journal where this script did not
# look, and it reported "the landing never started" about a landing that had run.
LAND_ROOT=${WA_PREFLIGHT_LAND_ROOT:-}
LOCK=${WA_SUITE_LOCK:-$MISSIONS/.suite.lock}
# MAIN'S OWN VERDICT, recorded by scripts/main-health.sh after every landing: a red row that is red there too
# is a fault this round did not make (21/11: land245 went red twice for lua/core/refusal_codes.lua being stale
# on main, 855 s, then sat stopped for 40+ minutes while ten finished missions waited).
HEALTH=${WA_MAIN_HEALTH:-$MISSIONS/main-health.json}
RUN=preflight-$(date -u +%Y%m%dT%H%M%SZ)-$$
LOG=$M/preflight.log
REPORT=$M/preflight.json

# THE TWO TOOLS THIS CANNOT DO WITHOUT, refused by name rather than half-done: without the lock the gate
# would share this machine with whatever else is running (19/11: load 105 on 16 cores, timing rows red at
# random), and without the interpreter the journal could be read but no answer written down.
command -v flock >/dev/null 2>&1 || { echo "preflight: refused(flock_missing): flock is not on PATH, so the suite lock cannot be taken"; exit 2; }
command -v "$PY" >/dev/null 2>&1 || { echo "preflight: refused(python_missing): $PY is not on PATH, so no preflight.json can be written"; exit 2; }
command -v "$WA" >/dev/null 2>&1 || { echo "preflight: refused(wa_missing): $WA is not on PATH (set WA_BIN)"; exit 2; }
if [ -z "$LAND_ROOT" ]; then
  # The FIRST line whose second word is an absolute path. `wa paths` also prints a "config file <path>" line,
  # and a reader that took any line starting with "config" took the word "file" for the directory - the
  # journal was then looked for under "<config>\nfile/land" and never found (measured 21/11, the second
  # replay: the answer was written and the report said no landing had run).
  config=$("$WA" paths 2>/dev/null | awk '$1 == "config" && $2 ~ /^\//{ print $2; exit }')
  if [ -z "$config" ]; then
    echo "preflight: refused(land_root_unknown): wa paths printed no config directory, so no journal can be found"
    exit 2
  fi
  LAND_ROOT=$config/land
fi

opts=(land --branches "$BRANCH" --until gate --run "$RUN")
[ -n "${WA_LAND_INCOMING:-}" ] && opts+=(--incoming "$WA_LAND_INCOMING")
[ -n "${WA_LAND_REPO:-}" ] && opts+=(--repo "$WA_LAND_REPO")

started=$(date +%s)
{
  echo "--- preflight $RUN $(date -u +%FT%TZ)"
  echo "    branch $BRANCH"
  echo "    wa $WA"
  echo "    lock $LOCK (flock -o)"
  echo "    land root $LAND_ROOT"
} >> "$LOG"
# THE GATE IS A SUITE: it takes the same lock every suite takes, -o included, so a preflight queues behind
# another heavy run instead of landing on top of it (and a child that keeps the fd cannot hold the lock
# after this command ends).
flock -o "$LOCK" "$WA" "${opts[@]}" >> "$LOG" 2>&1
rc=$?
elapsed=$(( $(date +%s) - started ))
echo "--- preflight $RUN ended rc=$rc in ${elapsed}s" >> "$LOG"

"$PY" - "$LAND_ROOT/$RUN/journal.json" "$REPORT" "$rc" "$elapsed" "$RUN" "$BRANCH" "$LOG" "$HEALTH" <<'PY'
import json, os, sys

journal_path, report_path, rc, elapsed, run, branch, log, health_path = sys.argv[1:9]
rc, elapsed = int(rc), int(elapsed)
report = {"schema": 1, "run": run, "branch": branch, "ok": False,
          "main_sha": None, "tree_commit": None, "tree_sha": None,
          "seconds": elapsed, "gate_seconds": None, "failed": [],
          "gate_evidence": None, "log": log, "result": None, "why": None}


def log_tail(row, journal_dir, limit=3):
    name = os.path.basename(str(row))
    path = os.path.join(journal_dir, "evidence", "fast-logs", name + ".log")
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return []
    return lines[-limit:]


if not os.path.exists(journal_path):
    report["why"] = "no journal at %s: the landing never started (read %s)" % (journal_path, log)
else:
    try:
        with open(journal_path, encoding="utf-8") as handle:
            journal = json.load(handle)
    except (OSError, ValueError) as problem:
        journal = None
        report["why"] = "the journal at %s cannot be read (%s)" % (journal_path, problem)
    if journal is not None:
        steps = journal.get("steps") or {}
        gate = steps.get("gate") or {}
        report["result"] = journal.get("result")
        report["main_sha"] = journal.get("base")
        report["tree_commit"] = journal.get("tree_commit")
        report["tree_sha"] = journal.get("tree_sha")
        report["gate_evidence"] = gate.get("evidence")
        report["gate_seconds"] = gate.get("seconds")
        journal_dir = os.path.dirname(journal_path)
        failed = []
        for row in journal.get("gate") or []:
            if not isinstance(row, dict) or row.get("ok") is True:
                continue
            named = row.get("failed") or []
            if not named:
                failed.append({"row": str(row.get("name") or "?"), "first_lines": []})
                continue
            for entry in named:
                if not isinstance(entry, dict):
                    continue
                name = str(entry.get("row") or row.get("name") or "?")
                first = [line for line in str(entry.get("first") or "").splitlines() if line.strip()]
                extra = log_tail(name, journal_dir)
                for line in extra:
                    if line not in first:
                        first.append(line)
                failed.append({"row": name, "first_lines": first[:3]})
        report["failed"] = failed

        # MAIN RED IS NOT THIS MISSION'S RED. A row that is red on main's own tip (scripts/main-health.sh,
        # written after every landing) is a fault nobody in this round made: main was red from bfad4f8f for
        # six landings on 21/11 and the first mission whose rows included the stale-file row paid twice for
        # it (855 s) and then sat stopped. The comparison needs the SAME COMMIT - a health file about another
        # sha proves nothing about this one, so it is named as stale and does NOT excuse a row (unknown is
        # not yes). While any row is MAIN RED the landing stays stopped: main has to be fixed first, by one
        # small landing whose only purpose is that fix.
        health, health_error = None, None
        try:
            with open(health_path, encoding="utf-8") as handle:
                health = json.load(handle)
        except OSError:
            health_error = "no main-health file at %s (scripts/main-health.sh writes it after a landing)" % health_path
        except ValueError as problem:
            health_error = "the main-health file at %s cannot be read (%s)" % (health_path, problem)
        health_sha = str((health or {}).get("sha") or "")
        same_commit = bool(health_sha) and bool(report.get("main_sha")) and health_sha == str(report["main_sha"])
        red_on_main = set()
        if health is not None and health.get("ok") is not True:
            for entry in health.get("failed") or []:
                if isinstance(entry, dict) and entry.get("row"):
                    red_on_main.add(str(entry["row"]))
        main_red, own = [], []
        for entry in failed:
            if same_commit and str(entry["row"]) in red_on_main:
                main_red.append(entry)
            else:
                own.append(entry)
        report["main_red"] = main_red
        report["failed"] = own
        report["main_health"] = {"path": health_path, "sha": health_sha or None,
                                 "ok": (health or {}).get("ok"), "same_commit": same_commit,
                                 "red_rows": sorted(red_on_main), "why": health_error}
        state = str(gate.get("state") or "missing")
        # The ROWS are the most useful sentence there is, so they win over the step's own state: a reader
        # who gets "the gate step is failed" has to open a file to learn what failed.
        # Inline short sha, not the lambda below: these lines run before it is defined (measured: NameError).
        main_short = str(report.get("main_sha") or "")[:12]
        if main_red and not own:
            report["why"] = "MAIN RED: %d row(s) are red on main %s itself, not on this branch (%s)" % (
                len(main_red), main_short, ", ".join(entry["row"] for entry in main_red))
        elif main_red:
            report["why"] = "%d row(s) failed here and %d are MAIN RED on %s (%s)" % (
                len(own), len(main_red), main_short, ", ".join(entry["row"] for entry in main_red))
        elif failed:
            report["why"] = "%d row(s) failed" % len(failed)
        elif state != "done":
            report["why"] = "the gate step is %s, not done (%s)" % (state, str(gate.get("detail") or gate.get("error") or ""))
        elif rc != 0:
            report["why"] = "the landing exited %d before the gate answered (%s)" % (
                rc, str(journal.get("stop_detail") or "no stop detail"))
        report["ok"] = rc == 0 and state == "done" and not failed

with open(report_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=1, sort_keys=True)
    handle.write("\n")

sha = lambda value: (value or "")[:12] or "-"
if report["ok"]:
    print("preflight green: %s on main %s, gate %ss of %ss, tree %s" % (
        branch, sha(report["main_sha"]), report["gate_seconds"], report["seconds"], sha(report["tree_sha"] or report["tree_commit"])))
    print("  preflight.json: %s" % report_path)
    print("  gate evidence: %s" % (report["gate_evidence"] or "-"))
    sys.exit(0)
if report.get("main_red"):
    print("preflight MAIN RED: %d row(s) are red on main %s itself, not on %s:" % (
        len(report["main_red"]), sha(report.get("main_sha")), branch))
    for entry in report["main_red"]:
        first = entry["first_lines"]
        print("  - %s: %s" % (entry["row"], first[0] if first else "(no first line was recorded)"))
    print("  the mission is NOT blamed, and no landing runs until main is fixed:")
    print("  one small landing whose only purpose is that fix, then this preflight again")
    if report["failed"]:
        print("  and %d row(s) failed on this branch too:" % len(report["failed"]))
        for entry in report["failed"]:
            first = entry["first_lines"]
            print("  - %s: %s" % (entry["row"], first[0] if first else "(no first line was recorded)"))
    print("  preflight.json: %s" % report_path)
    print("  main-health: %s" % (report["main_health"].get("path") or "-"))
    sys.exit(1)
if report["failed"]:
    print("preflight RED: %d row(s) failed for %s on main %s" % (
        len(report["failed"]), branch, sha(report["main_sha"])))
    for entry in report["failed"]:
        first = entry["first_lines"]
        print("  - %s: %s" % (entry["row"], first[0] if first else "(no first line was recorded)"))
        for line in first[1:]:
            print("      %s" % line)
    print("  preflight.json: %s" % report_path)
    print("  land log: %s" % log)
    print("  gate evidence: %s" % (report["gate_evidence"] or "-"))
    sys.exit(1)
print("preflight: refused(no_verdict): %s" % (report["why"] or "nothing was judged"))
print("  preflight.json: %s" % report_path)
print("  land log: %s" % log)
sys.exit(2)
PY
exit $?

