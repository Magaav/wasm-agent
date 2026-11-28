#!/bin/bash
# ONE TEST FOR reboot-snapshot.sh, and it can fail.
#
# The snapshot is what survives a POWER CUT: no "before" ran, so this file is the only record of what each
# mission was doing and which orch units were up. It must therefore (a) classify every mission that has a brief
# and a worktree, (b) skip one that has not, (c) list the active orch units but not itself, and (d) write
# ATOMICALLY - the state is read by a human after a crash, so a half-written row is worse than a stale file.
#
# WHAT IT CAN CATCH: a missing state (landed/running/paused/review/retired/idle), a mission with no brief still
# listed, the snapshot unit listing itself, a non-atomic write (a reader can see a truncated file), and a stale
# `.at` stamp.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/wa-snap.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-reboot-snapshot: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
# \t is not a POSIX ERE escape: %b turns it into a real tab so the patterns match the TSV columns.
has() { checks=$((checks + 1)); local p; p=$(printf %b "$1"); grep -qE "$p" "$2" || fail "$3 (no line matching $p in $2)"; }
hasnt() { checks=$((checks + 1)); local p; p=$(printf %b "$1"); if grep -qE "$p" "$2"; then fail "$3 (line matching $p in $2)"; fi; }

H="$WORK/home"; B="$WORK/bin"
M="$H/Work/missions"; O="$M/_orch"; C="$H/wasm-agent/checkout"
mkdir -p "$O" "$B" "$C"
# five missions: landed, running, paused, review, retired - and one that must be skipped.
for n in landed run paused review retired nobrief; do mkdir -p "$M/$n/wt"; done
for n in landed run paused review retired; do printf 'a brief\n' > "$M/$n/brief.md"; done
printf 'what it did\n' > "$M/review/done"; printf 'gone\n' > "$M/retired/retired.txt"; : > "$M/paused/paused"
printf 'wa: session 11111111-2222-3333-4444-555555555555\n' > "$M/run/err.log"

cat > "$B/git" <<'STUB'
#!/bin/bash
# rev-parse --short change/<n>: every mission's branch exists except nobrief's; merge-base asks landed only.
case "$*" in
  *rev-parse*) echo "abc1234"; exit 0;;
  *merge-base*) case "$*" in *change/landed*) exit 0;; *) exit 1;; esac;;
  *) exit 0;;
esac
STUB
cat > "$B/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
  *is-active*mission-run*) exit 0;;
  *is-active*) exit 1;;
  *list-units*orch-*) printf 'orch-a.service loaded active running a\norch-snapshot.timer loaded active running s\n';;
  *show*ExecStart*) echo '{ path=/usr/bin/orch-a ; argv[]=/usr/bin/orch-a --go ; ignore_errors=no }';;
  *) exit 0;;
esac
STUB
chmod +x "$B/git" "$B/systemctl"

HOME="$H" PATH="$B:/usr/bin:/bin" timeout 20 bash "$HERE/reboot-snapshot.sh"; rc=$?
ok "$rc" "0" "the snapshot completes"
S="$O/reboot-state.tsv"; U="$O/reboot-units.tsv"
[ -f "$S" ] || { echo "FAIL test-reboot-snapshot: no $S" >&2; exit 1; }
ok "$(head -1 "$S")" "$(printf 'mission\tstate\tbranch_tip\tsession\tdetail')" "the header is the documented five columns"
has '^landed\tlanded\tabc1234' "$S" "a branch merged into origin/main is LANDED"
has '^run\trunning\tabc1234\t11111111-2222-3333-4444-555555555555' "$S" "a mission with an active unit is RUNNING, with its session id"
has '^paused\tpaused' "$S" "a paused mission is PAUSED"
has '^review\treview\tabc1234\t-\twhat it did' "$S" "a done file is REVIEW, and its first line is the detail"
has '^retired\tretired' "$S" "a retired mission is RETIRED"
hasnt 'nobrief' "$S" "a mission with no brief.md is not in the snapshot"

has '^orch-a\t/usr/bin/orch-a --go' "$U" "an active orch unit is listed with its command line"
hasnt 'orch-snapshot' "$U" "the snapshot unit does not list itself"

ok "$(grep -c . "$O/reboot-snapshot.at")" "1" "the .at stamp was written"
checks=$((checks + 1))
case "$(cat "$O/reboot-snapshot.at")" in ????-??-??T??:??:??Z) ;; *) fail "the stamp is not ISO-8601 UTC: $(cat "$O/reboot-snapshot.at")";; esac
checks=$((checks + 1))
if ls "$O"/.reboot-state.* "$O"/.reboot-units.* >/dev/null 2>&1; then fail "a temporary file was left behind (the write must be atomic AND clean)"; fi

# A SECOND run must replace the file, not append to it: a stale row would misreport a mission forever.
printf 'a brief\n' > "$M/nobrief/brief.md"
HOME="$H" PATH="$B:/usr/bin:/bin" timeout 20 bash "$HERE/reboot-snapshot.sh"
ok "$(grep -c '^nobrief' "$S")" "1" "a mission that gained a brief appears once on the next run"
ok "$(grep -c '^mission' "$S")" "1" "and the header is still written once"

if [ "$failed" -gt 0 ]; then echo "test-reboot-snapshot: $failed failed of $checks checks"; exit 1; fi
echo "test-reboot-snapshot ok ($checks checks)"
