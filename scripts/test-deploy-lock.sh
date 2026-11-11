#!/usr/bin/env bash
# The deploy build lock (scripts/lib/deploy-lock.sh): a lock is one holder, and a holder that is gone must
# not block the machine. Measured on wasm_the_first: a killed installer's `.deploy.lock` with a dead pid
# refused every deploy for 1h44 because the only test was `mkdir`. The opposite failure - reclaiming a
# LIVE build - is what the pid/host/boot evidence exists to prevent, so both directions are tested here.
# No node, no build, no install: a temp directory and real processes only.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/deploy-lock.sh"
[ -f "$LIB" ] || { echo "FAIL no $LIB"; exit 1; }
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t wa-deploy-lock)"
LOG="$WORK/deploy-lock.log"
LOCK="$WORK/.deploy.lock"
passed=0
check() { # <name> <condition-result> <detail>
  if [ "$2" = "0" ]; then passed=$((passed + 1)); echo "ok - $1"; else echo "FAIL $1: $3"; exit 1; fi
}
clean() { rm -rf "$LOCK" "$LOCK".stale-* 2>/dev/null || true; : > "$LOG"; }
. "$LIB"

# 1. no lock: claim writes the holder's four facts and release removes the lock.
clean
wa_deploy_lock_claim "$LOCK" "$LOG" "/fixture/tree"
check "an unheld lock is taken" $? ""
check "the holder is recorded with its pid" "$( [ -n "$(wa_deploy_lock_field "$LOCK" pid)" ] && echo 0 || echo 1 )" "no pid"
if [ -f /proc/sys/kernel/random/boot_id ]; then
  check "the holder records the boot it was taken on" "$( [ -n "$(wa_deploy_lock_field "$LOCK" boot)" ] && echo 0 || echo 1 )" "no boot"
else
  passed=$((passed + 1)); echo "ok - this platform has no kernel boot id; the lock records host and pid instead"
fi
check "the holder records where it builds" "$( [ "$(wa_deploy_lock_field "$LOCK" worktree)" = "/fixture/tree" ] && echo 0 || echo 1 )" "wrong worktree"
wa_deploy_lock_release "$LOCK" "$LOG"
check "release removes the lock" "$( [ ! -d "$LOCK" ] && echo 0 || echo 1 )" "lock still there"

# 2. a dead holder: reclaimed, evidence kept and logged, never silently deleted.
clean
mkdir -p "$LOCK"
printf '999999\n' > "$LOCK/pid"
hostname > "$LOCK/host"
wa_deploy_lock_boot > "$LOCK/boot"
printf '2026-11-11T02:00:00Z\n' > "$LOCK/started_at"
printf '/fixture/killed\n' > "$LOCK/worktree"
OUT="$(wa_deploy_lock_claim "$LOCK" "$LOG" "/fixture/new")" 2>&1
check "a dead holder's lock is reclaimed" $? "$OUT"
check "the reclaim names the dead pid and the reason" "$( printf '%s' "$OUT" | grep -q 'reclaimed a stale deploy lock: holder pid 999999 .* is gone' && echo 0 || echo 1 )" "$OUT"
check "the evidence directory is kept, not deleted" "$( ls -d "$LOCK".stale-* >/dev/null 2>&1 && echo 0 || echo 1 )" "no evidence dir"
check "the evidence log has the four facts and the verdict" "$( grep -q 'reclaimed_stale_deploy_lock pid=999999 .*boot=.*started_at=2026-11-11T02:00:00Z worktree=/fixture/killed verdict=reclaimed reason=.*is gone' "$LOG" && echo 0 || echo 1 )" "$(cat "$LOG" 2>/dev/null)"
check "the new holder owns the lock" "$( [ "$(wa_deploy_lock_field "$LOCK" worktree)" = "/fixture/new" ] && echo 0 || echo 1 )" "not the new holder"
wa_deploy_lock_release "$LOCK" "$LOG"

# 3. a live holder: refused, untouched, and nothing is stolen.
clean
mkdir -p "$LOCK"
sleep 30 &
LIVE=$!
printf '%s\n' "$LIVE" > "$LOCK/pid"
hostname > "$LOCK/host"
wa_deploy_lock_boot > "$LOCK/boot"
printf '2026-11-11T02:00:00Z\n' > "$LOCK/started_at"
OUT="$(wa_deploy_lock_claim "$LOCK" "$LOG" "/fixture/new" 2>&1)"
RC=$?
check "a live holder is refused" "$( [ "$RC" != "0" ] && echo 0 || echo 1 )" "rc=$RC $OUT"
check "the refusal names the live pid" "$( printf '%s' "$OUT" | grep -q "holds $LOCK (pid $LIVE on" && echo 0 || echo 1 )" "$OUT"
check "a live holder's lock is not moved" "$( [ -d "$LOCK" ] && [ -z "$(ls -d "$LOCK".stale-* 2>/dev/null)" ] && echo 0 || echo 1 )" "lock moved"
check "a refused claim writes no reclaim evidence" "$( [ ! -s "$LOG" ] && echo 0 || echo 1 )" "$(cat "$LOG" 2>/dev/null)"
kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true

# 4. a holder from another boot: reclaimed, because a pid from a previous boot names nothing on this one.
clean
mkdir -p "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
hostname > "$LOCK/host"
printf 'a-different-boot\n' > "$LOCK/boot"
printf '2026-11-11T02:00:00Z\n' > "$LOCK/started_at"
OUT="$(wa_deploy_lock_claim "$LOCK" "$LOG" "/fixture/new" 2>&1)"
check "a holder from another boot is reclaimed" $? "$OUT"
check "the reclaim names the boot" "$( printf '%s' "$OUT" | grep -q 'was recorded on another boot (a-different-boot)' && echo 0 || echo 1 )" "$OUT"
wa_deploy_lock_release "$LOCK" "$LOG"

# 5. a holder from another host: same rule, and it says which host.
clean
mkdir -p "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
printf 'another-machine\n' > "$LOCK/host"
wa_deploy_lock_boot > "$LOCK/boot"
printf '2026-11-11T02:00:00Z\n' > "$LOCK/started_at"
OUT="$(wa_deploy_lock_claim "$LOCK" "$LOG" "/fixture/new" 2>&1)"
check "a holder from another host is reclaimed" $? "$OUT"
check "the reclaim names the other host" "$( printf '%s' "$OUT" | grep -q 'was recorded on host another-machine' && echo 0 || echo 1 )" "$OUT"
wa_deploy_lock_release "$LOCK" "$LOG"

rm -rf "$WORK"
echo "deploy lock: $passed checks passed"
