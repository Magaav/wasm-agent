#!/usr/bin/env bash
# Does a deploy collect what a killed earlier deploy left staged - bounded, and only what is its own?
#
# THE FAILURE THIS PINS (finding F6 of the review of change/deploy-unbound). Every install here stages a file
# beside its destination and renames it into place: `ship_file` as `<name>.ship.<pid>`, upgrade.sh's own
# self-ship as `upgrade.sh.new.<pid>`, and the SENTINEL as a whole binary under `<name>.new.<pid>`. A SIGKILL
# between the copy and the rename leaves the staged file behind, and nothing ever looked for one - the review
# measured a single leftover at 248 MB.
#
# WHAT IS RUN: the REAL `sweep_stale_staging()`, read out of `scripts/deploy.sh`, against a private install
# directory holding exactly what a killed run could leave - and, next to it, the files it must NOT touch:
# a fresh staging file of a run that is still going, an operator's own `.new` note, and the installed scripts
# themselves. The bound is measured too (12 stale files, a cap of 8).
#
# Hermetic: temp directories only, no build, no model, no port, and the live install is never named.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"
checks=0
fail() { echo "test-deploy-staging-sweep: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }

[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-sweep-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

awk '/^sweep_stale_staging\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$DEPLOY" > "$WORK/sweep.sh"
[ -s "$WORK/sweep.sh" ] || fail "could not read sweep_stale_staging out of deploy.sh (the marker moved?): the residue sweep is gone"
grep -q 'find "\$INSTALL_DIR" -maxdepth 3' "$WORK/sweep.sh" || fail "the extracted sweep does not bound itself to the install directory"

# The sweep's own environment: `note` is the deploy's recorder, and its output is what this test reads.
LOG="$WORK/notes.log"
run_sweep() { # install-dir [extra env assignments...]
  local install="$1"; shift
  {
    echo 'set -uo pipefail'
    echo "INSTALL_DIR=\"$install\""
    echo "LOG=\"$LOG\""
    echo 'note() { printf "%s\n" "$*" >> "$LOG"; }'
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    cat "$WORK/sweep.sh"
    echo 'sweep_stale_staging'
  } > "$WORK/run-sweep.sh"
  rm -f "$LOG"
  env "$@" bash "$WORK/run-sweep.sh" 2>&1
}

aged() { touch -d '2 hours ago' "$1" 2>/dev/null || touch -t 197001020000 "$1"; }

INSTALL="$WORK/install"
mkdir -p "$INSTALL/scripts/lib" || fail "cannot stage the private install"
# Installed files that must never be touched.
printf '#!/usr/bin/env bash\necho deploy\n' > "$INSTALL/scripts/deploy.sh"
printf '#!/usr/bin/env bash\necho upgrade\n' > "$INSTALL/scripts/upgrade.sh"
printf 'the installed sentinel\n' > "$INSTALL/wa-sentinel.exe"
cp -f "$INSTALL/scripts/deploy.sh" "$WORK/deploy.sh.before"

# What a SIGKILL between stage and rename leaves: four staging files of a dead run, one of them the SIZE of
# a binary (the review measured 248 MB for exactly this one).
head -c 5242880 /dev/urandom > "$INSTALL/wa-sentinel.exe.new.8123456"
printf 'half a script\n' > "$INSTALL/scripts/deploy.sh.ship.777777"
printf 'half a helper\n' > "$INSTALL/scripts/lib/service-target.sh.ship.666666"
printf 'half an upgrade\n' > "$INSTALL/scripts/upgrade.sh.new.555555"
for f in "$INSTALL/wa-sentinel.exe.new.8123456" "$INSTALL/scripts/deploy.sh.ship.777777" \
         "$INSTALL/scripts/lib/service-target.sh.ship.666666" "$INSTALL/scripts/upgrade.sh.new.555555"; do
  aged "$f"
done

# What must survive: a run that is going RIGHT NOW (seconds old), an operator's own note, and the installed
# names themselves.
printf 'a live run\n' > "$INSTALL/scripts/live.sh.ship.444444"
printf 'not mine\n' > "$INSTALL/scripts/notes.new"; aged "$INSTALL/scripts/notes.new"

OUT="$(run_sweep "$INSTALL")"; STATUS=$?
[ "$STATUS" = "0" ] || fail "the sweep refused instead of collecting: status $STATUS - $OUT"
for f in "$INSTALL/wa-sentinel.exe.new.8123456" "$INSTALL/scripts/deploy.sh.ship.777777" \
         "$INSTALL/scripts/lib/service-target.sh.ship.666666" "$INSTALL/scripts/upgrade.sh.new.555555"; do
  [ -f "$f" ] && fail "the residue of a killed deploy survived the sweep: $f"
done
ok "a killed deploy's staged copies are collected" "$(grep -c 'staging residue swept' "$LOG") file(s), $(grep -o 'removed [0-9]* file(s), [0-9]* byte(s)' "$LOG" | tail -1)"
check_bytes="$(grep -o 'removed [0-9]* file(s), [0-9]* byte(s)' "$LOG" | tail -1 | grep -o '[0-9]* byte(s)' | head -1 | cut -d' ' -f1)"
[ "${check_bytes:-0}" -ge 5242880 ] || fail "the sweep did not account for the 5 MiB staged sentinel (it reported ${check_bytes:-0} byte(s))"
ok "the residue is accounted for in bytes, not only counted" "$check_bytes byte(s), including the staged sentinel image"
[ -f "$INSTALL/scripts/live.sh.ship.444444" ] || fail "the sweep ate a staging file that is still in use (seconds old)"
ok "a staging file younger than the age bound is left alone" "the run that owns it may still be going"
[ -f "$INSTALL/scripts/notes.new" ] || fail "the sweep removed a file that is not one of its staging names"
ok "a name that is not a staging pid-suffixed file is left alone" "notes.new survived"
cmp -s "$WORK/deploy.sh.before" "$INSTALL/scripts/deploy.sh" || fail "the sweep modified an installed file"
[ -f "$INSTALL/wa-sentinel.exe" ] || fail "the sweep removed the installed sentinel"
ok "the installed files are untouched" "deploy.sh and wa-sentinel.exe are byte-identical"
grep -q 'staging residue swept: wa-sentinel.exe.new.8123456 (5242880 byte(s))' "$LOG" \
  || fail "the sweep does not name what it removed and how large it was: $(cat "$LOG")"
ok "each removal is recorded in the deploy's own log, by name and size"

# The bound: 12 stale files, the default cap of 8.
BOUNDED="$WORK/bounded"
mkdir -p "$BOUNDED/scripts" || fail "cannot stage the bounded fixture"
for i in $(seq 1 12); do printf 'stale %s\n' "$i" > "$BOUNDED/scripts/stale-$i.sh.ship.$((700000 + i))"; aged "$BOUNDED/scripts/stale-$i.sh.ship.$((700000 + i))"; done
OUT="$(run_sweep "$BOUNDED")"; STATUS=$?
[ "$STATUS" = "0" ] || fail "the bounded sweep refused: status $STATUS - $OUT"
REMAINING="$(ls "$BOUNDED"/scripts/*.ship.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$REMAINING" = "4" ] || fail "the cap of 8 was not applied (12 stale files, $REMAINING left)"
ok "the sweep is bounded per deploy" "12 stale files, 8 collected, $REMAINING left, and the bound is said: $(grep -c 'stopped at its 8 file bound' "$LOG") note(s)"

echo "test-deploy-staging-sweep: ALL PASS ($checks checks; bounded collection, only its own staging names)"
