#!/bin/bash
# ONE TEST FOR paused-watchdog.sh, and it can fail.
#
# The watchdog resumes a mission whose 'paused' marker the NODE never came back for. It deletes that marker and
# starts a resume unit, so a wrong decision is a mission resumed against a live deploy - which is why it checks
# four things first: no deploy waiting, the marker at least 15 minutes old, the session quiet 10 minutes, and the
# session's LAST word a pause notice. Every one of those is a reason to stay away, and every one is tested here
# against a mission that would otherwise be resumed.
#
# WHAT IT CAN CATCH: resuming while a deploy waits, resuming a marker younger than 15 min, resuming a session
# that is still talking, resuming a session whose last word is not a pause notice, resuming a mission a young
# resume unit already owns, and a resume that starts no unit or leaves the marker behind.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/wa-pw.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-paused-watchdog: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }

H="$WORK/home"; B="$WORK/bin"; M="$H/Work/missions"
mkdir -p "$B" "$M" "$H/.wasm-agent"
SID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
mission() { # <name> <marker-age-minutes>
  local d="$M/$1"
  mkdir -p "$d"; printf 'paused by an install\n' > "$d/paused"
  touch -d "$2 minutes ago" "$d/paused"
  printf 'wa: session %s ok\n' "$SID" > "$d/err.log"
}
# wa-sentinel: how many requests wait, from a file.
# wa-sentinel: prints the line the test wrote into $WORK/reqline, so each scenario chooses the answer.
printf '#!/bin/bash\ncat %s/reqline\n' "$WORK" > "$B/wa-sentinel"
reqline() { printf "requests: %s waiting\n" "$1" > "$WORK/reqline"; }
waiting() { reqline "$1"; }
quiet() { printf "$1" > "$WORK/quiet"; }
lastword() { printf "$1" > "$WORK/lastword"; }
# wa-sentinel: prints the line the test wrote into $WORK/reqline, so each scenario chooses the answer.
printf '#!/bin/bash\ncat %s/reqline\n' "$WORK" > "$B/wa-sentinel"
reqline() { printf "requests: %s waiting\n" "$1" > "$WORK/reqline"; }
cat > "$B/systemctl" <<'EOS'
#!/bin/bash
case "$*" in *is-active*) exit 1;; *show*ActiveEnterTimestamp*) date -u +%FT%TZ;; *) exit 0;; esac
EOS
# sqlite3: the quiet seconds for one query, the last-word predicate for the other.
cat > "$B/sqlite3" <<EOS
#!/bin/bash
sql=\${@: -1}
case "\$sql" in
  *max\(created_at\)*) cat $WORK/quiet;;
  *'deploy pending:'*) cat $WORK/lastword;;
  *) echo '';;
esac
EOS
printf '#!/bin/bash\nexit 0\n' > "$B/journalctl"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/systemd-run.calls\n' "$WORK" > "$B/systemd-run"
chmod +x "$B/"*

# The watcher loops forever with a 300 s sleep; 3 s is enough for one pass of its body.
run() { WORK="$WORK" HOME="$H" PATH="$B:/usr/bin:/bin" timeout 3 bash "$HERE/paused-watchdog.sh" >/dev/null 2>&1; }

# 1. THE CASE IT EXISTS FOR: 20 min paused, session quiet 15 min, pause notice last, nothing waiting.
mission orphan 20
printf 900 > "$WORK/quiet"; printf 1 > "$WORK/lastword"; waiting 0; rm -f "$WORK/systemd-run.calls"
run
ok "$(test -f "$M/orphan/paused" && echo present || echo gone)" "gone" "a mission the node forgot is resumed"
like "$(cat "$M/orphan/continue-auto.txt" 2>/dev/null)" "Continue exactly where you stopped" "and given the instruction to continue"
like "$(cat "$WORK/systemd-run.calls" 2>/dev/null)" "resume-when-idle.sh orphan" "and a resume unit is started, by name"
like "$(cat "$M/HANDOVER.md" 2>/dev/null)" "orch(watchdog): orphan paused" "and the operator is told"

# 2-5. each of the four guards, one mission at a time: a scenario must not be rescued by the run before it.
#      Every case starts from an empty missions dir, so the only reason it can be left alone is the guard under test.
clean() { rm -rf "$M"/*; }
all_idle_units() {
cat > "$B/systemctl" <<'EOS'
#!/bin/bash
case "$*" in *is-active*) exit 1;; *show*ActiveEnterTimestamp*) date -u +%FT%TZ;; *) exit 0;; esac
EOS
chmod +x "$B/systemctl"
}

# a marker younger than 15 min.
clean; all_idle_units; mission young 5; waiting 0; quiet 900; lastword 1; run
ok "$(test -f "$M/young/paused" && echo present || echo gone)" "present" "a marker younger than 15 min is left alone"

# a session that spoke recently.
clean; mission talking 20; quiet 120; lastword 1; run
ok "$(test -f "$M/talking/paused" && echo present || echo gone)" "present" "a session that spoke 2 min ago is left alone"

# a last word that is not a pause notice.
clean; mission notpaused 20; quiet 900; lastword 0; run
ok "$(test -f "$M/notpaused/paused" && echo present || echo gone)" "present" "a last word that is NOT a pause notice is left alone"

# a mission a YOUNG resume unit already owns.
clean; lastword 1; rm -f "$WORK/systemd-run.calls"
cat > "$B/systemctl" <<'EOS'
#!/bin/bash
case "$*" in *is-active*orch-pw-owned*) exit 0;; *is-active*) exit 1;; *show*ActiveEnterTimestamp*) date -u +%FT%TZ;; *) exit 0;; esac
EOS
chmod +x "$B/systemctl"
mission owned 20; run
ok "$(test -f "$M/owned/paused" && echo present || echo gone)" "present" "a mission a YOUNG resume unit owns is left alone"
n=$(grep -c 'resume-when-idle.sh owned' "$WORK/systemd-run.calls" 2>/dev/null); ok "${n:-0}" "0" "and no second resume unit is started"

# 6. a deploy waiting means NOBODY is resumed, whatever the missions look like.
clean; all_idle_units; rm -f "$WORK/systemd-run.calls"
mission waiting-deploy 20; quiet 900; lastword 1; waiting 2; run
ok "$(test -f "$M/waiting-deploy/paused" && echo present || echo gone)" "present" "with requests waiting nothing is resumed"
ok "$(test -f "$WORK/systemd-run.calls" && echo started || echo none)" "none" "and no resume unit is started"

if [ "$failed" -gt 0 ]; then echo "test-paused-watchdog: $failed failed of $checks checks"; exit 1; fi
echo "test-paused-watchdog ok ($checks checks)"
