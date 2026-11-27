#!/bin/bash
# ONE TEST FOR throughput-watch.sh, and it can fail.
#
# This is the script that says "the train has stopped" and "an item has been waiting on Fable for an hour". Two
# failure modes matter more than its messages: crying wolf (it runs every 10 minutes, so a raised alarm must hold
# for an HOUR) and staying silent (a stopped train with READY branches and no alarm is how a day is lost).
#
# WHAT IT CAN CATCH: an alarm that fires on every run instead of once an hour, a stopped train that is not
# reported, a dead health loop that is not reported, a stale Fable item that raises no nudge, a nudge that is not
# cleared when nothing is waiting any more, and a sample that is not appended.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/wa-thru.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-throughput-watch: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }

H="$WORK/home"; B="$WORK/bin"
M="$H/Work/missions"; O="$M/_orch"
mkdir -p "$O" "$B" "$M/some-mission" "$H/wasm-agent/checkout"
printf 'a ready file\n' > "$M/some-mission/ready-x.md"
# The age matters: the script only names the OLDEST branch when its ready file is older than 0 minutes.
touch -d '30 minutes ago' "$M/some-mission/ready-x.md"
printf '# a comment\n\nready-branch some-mission deadbeefcafe why it waits\n' > "$O/train.list"
printf 'land\n' > "$WORK/landed"
cat > "$B/git" <<'STUB'
#!/bin/bash
case "$*" in
  *fetch*) exit 0;;
  *"log --first-parent"*) cat "$LANDED_FILE"; exit 0;;
  *merge-base*) exit 1;;   # the waiting branch is not landed
  *) exit 0;;
esac
STUB
# systemctl: which units are active is driven by two files, so a scenario can stop the train or the health loop.
cat > "$B/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
  *is-active*orch-q-runner*) [ -f "$TRAIN_UP" ] && exit 0 || exit 1;;
  *is-active*orch-health-loop*) [ -f "$HEALTH_UP" ] && exit 0 || exit 1;;
  *) exit 0;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$B/notify-send"
chmod +x "$B/git" "$B/systemctl" "$B/notify-send"

train_up() { : > "$WORK/train.up"; }
train_down() { rm -f "$WORK/train.up"; }
runs() {
  HOME="$H" PATH="$B:/usr/bin:/bin" LANDED_FILE="$WORK/landed" TRAIN_UP="$WORK/train.up" HEALTH_UP="$WORK/health.up" \
    bash "$HERE/throughput-watch.sh" >/dev/null 2>&1
}
alarms() { if [ -f "$M/ATTENTION" ]; then grep -c . "$M/ATTENTION"; else echo 0; fi; }
: > "$WORK/health.up"; train_up

# 1. nothing landed for an hour while a READY branch waits -> ONE alarm, naming the branch and its age.
runs
ok "$(alarms)" "1" "0 landings with a READY branch waiting raises an alarm"
like "$(cat "$M/ATTENTION")" "0 landings in the last hour" "and says what it is"
like "$(cat "$M/ATTENTION")" "ready-branch" "and names the oldest waiting branch"
like "$(cat "$M/HANDOVER.md")" "WATCHDOG" "the same line reaches HANDOVER"
ok "$(grep -c . "$O/throughput-samples.tsv")" "1" "a sample row is appended"

# 2. the very next run (10 minutes later in real life) must NOT repeat it.
runs
ok "$(alarms)" "1" "the alarm holds for an hour rather than repeating every run"

# 3. the train is down while branches wait -> its own alarm.
train_down; runs
ok "$(alarms)" "2" "a stopped train with READY branches is an alarm of its own"
like "$(tail -1 "$M/ATTENTION")" "no train is running" "the train alarm says what is not running"

# 4. the health loop is down -> its own alarm.
train_up; rm -f "$WORK/health.up"; runs
ok "$(alarms)" "3" "a dead health loop is an alarm"
like "$(tail -1 "$M/ATTENTION")" "health loop" "the health alarm says which loop is missing"

: > "$WORK/health.up"
# 5. an item waiting on Fable for more than an hour -> a NUDGE (not an alarm), once.
# Real landing subjects: the script counts `land-quick: merge`, `Merge` and `batch` - not the word land.
printf 'land-quick: merge abc1234\nMerge branch x\n' > "$WORK/landed"
old=$(date -u -d '2 hours ago' +%FT%TZ); young=$(date -u +%FT%TZ)
printf '%s\titem-old\topen\n%s\titem-young\topen\n%s\titem-done\tdone\n' "$old" "$young" "$old" > "$O/awaiting-fable.tsv"
runs
ok "$(alarms)" "3" "a Fable nudge is not an ATTENTION alarm"
like "$(cat "$O/FABLE-NUDGE" 2>/dev/null)" "item-old" "an item open for two hours is in the nudge"
checks=$((checks + 1)); grep -q 'item-young' "$O/FABLE-NUDGE" 2>/dev/null && fail "a young item must not be nudged"
checks=$((checks + 1)); grep -q 'item-done' "$O/FABLE-NUDGE" 2>/dev/null && fail "a done item must not be nudged"

# 6. nothing stale any more -> the nudge is CLEARED, not left to be sent twice.
printf '%s\titem-young\topen\n' "$young" > "$O/awaiting-fable.tsv"
runs
checks=$((checks + 1)); [ ! -f "$O/FABLE-NUDGE" ] || fail "a stale nudge must be removed when nothing waits"
checks=$((checks + 1)); [ ! -f "$O/FABLE-NUDGE.new" ] || fail "no temporary nudge file may be left behind"

# 7. landings are happening -> no throughput alarm even with a branch waiting.
rm -f "$O/.alarm-throughput" "$M/ATTENTION"; : > "$O/throughput-samples.tsv"
runs
ok "$(alarms)" "0" "with landings in the last hour nothing is raised"

if [ "$failed" -gt 0 ]; then echo "test-throughput-watch: $failed failed of $checks checks"; exit 1; fi
echo "test-throughput-watch ok ($checks checks)"
