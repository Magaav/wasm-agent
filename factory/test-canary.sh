#!/bin/bash
# ONE TEST FOR canary.sh, and it can fail.
#
# canary.sh is read-only on the install and has ONE damaging failure mode: alarming on a single red. A change
# outside a landing must reach ATTENTION, but only after TWO reds in a row, because a half-written file or a
# restarting unit is not an incident. The opposite mode - never alarming - is silent.
#
# It also guards a subtle thing: a sentinel process that is NOT the MainPID but holds the LIVE home/db is a
# non-live sentinel watching the live node, and that is a red of its own.
#
# WHAT IT CAN CATCH: alarming on the first red, never alarming on the second, a landing that still alarms, a
# red message that does not name what is wrong, and a missed non-live sentinel.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-canary.XXXXXX")
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
checks=0; failed=0
fail() { echo "FAIL test-canary: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }

H="$WORK/home"; B="$WORK/bin"
M="$H/Work/missions"; O="$M/_orch"; L="$H/.local/bin"
mkdir -p "$O" "$B" "$L" "$H/.config/systemd/user" "$H/.wasm-agent" "$H/.local/share/mise/shims" "$H/wasm-agent"
# The canary asks the CHECKOUT for the product unit text, so the sandbox home points at the real one.
ln -sfn /home/victor/wasm-agent/checkout "$H/wasm-agent/checkout"
printf 'the runtime worktree\n' > "$L/wa"
printf '#!/bin/bash\necho "node: up port 8799"\necho "sentinel: up watching"\n' > "$L/wa-sentinel"
chmod +x "$L/wa-sentinel"
printf '/w/tree\n' > "$L/runtime-worktree.txt"
printf 'source_worktree=/w/tree\nsha256=HASH_WA\nsentinel_sha256=HASH_SENT\n' > "$L/installed.txt"

# The unit text must be the PRODUCT's, asked with the same PATH the canary passes.
WANT_PATH="$L:$H/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin"
want=$(HOME="$H" bash -c 'source $HOME/wasm-agent/checkout/scripts/lib/sentinel-unit.sh; wa_sentinel_unit_text '"$L"' '"$H"'/.wasm-agent/env 8799 8800 0 '"'"$WANT_PATH"'"'' 2>/dev/null)
[ -n "$want" ] || { echo "FAIL test-canary: could not obtain the product unit text" >&2; exit 1; }
printf '%s\n' "$want" > "$H/.config/systemd/user/wa-sentinel.service"

# The sentinel process: a real one, with the sandbox home, so the canary's environ check has something to read.
env -i HOME="$H" WASM_AGENT_PORT=8799 /usr/bin/sleep 60 & MAINPID=$!; PIDS+=("$MAINPID")
# A second process that IS the bug the canary exists to catch: a non-MainPID sentinel with the LIVE home.
env -i HOME=/home/victor WASM_AGENT_PORT=8799 /usr/bin/sleep 60 & LIVEHOME_PID=$!; PIDS+=("$LIVEHOME_PID")
sleep 0.2
printf '%s\n' "$MAINPID" > "$WORK/mainpid"

printf '#!/bin/bash\ncase "$*" in *list-units*orch-land-*) exit 0;; *show*MainPID*) cat %s;; *) exit 0;; esac\n' "$WORK/mainpid" > "$B/systemctl"
# readlink: the MainPID's exe IS the installed sentinel (we cannot own /proc, so we own readlink).
printf '#!/bin/bash\necho %s\n' "$L/wa-sentinel" > "$B/readlink"
printf '#!/bin/bash\ncat %s\n' "$WORK/pgrep.out" > "$B/pgrep"
cat > "$B/sha256sum" <<STUB
#!/bin/bash
inp=\$(cat)
if [ "\$inp" = "\$(cat $L/wa)" ]; then echo "\$HASH_WA  -"; else echo "\$HASH_SENT  -"; fi
STUB
chmod +x "$B/systemctl" "$B/readlink" "$B/pgrep" "$B/sha256sum"
printf '%s\n' "$MAINPID" > "$WORK/pgrep.out"

run_canary() {
  HOME="$H" PATH="$B:/usr/bin:/bin" HASH_WA="${1:-HASH_WA}" HASH_SENT="HASH_SENT" \
    bash "$HERE/canary.sh" >/dev/null 2>&1
}
alarms() { if [ -f "$M/ATTENTION" ]; then grep -c . "$M/ATTENTION"; else echo 0; fi; }

# 1. everything matches: GREEN, nothing in ATTENTION.
run_canary HASH_WA
like "$(cat "$O/canary.state")" "green" "all checks matching is GREEN"
ok "$(alarms)" "0" "a green run writes no alarm"

# 2. ONE red (the wa hash no longer matches installed.txt): red recorded, NO alarm yet.
run_canary HASH_OTHER
like "$(cat "$O/canary.state")" "red" "one mismatch is recorded as red"
ok "$(alarms)" "0" "ONE red must not reach ATTENTION (two in a row do)"

# 3. second red in a row: ATTENTION, the log, and a message that names the mismatch.
run_canary HASH_OTHER
ok "$(alarms)" "1" "two reds in a row reach ATTENTION, once"
line=$(tail -1 "$M/ATTENTION" 2>/dev/null)
like "$line" "CANARY RED" "the message announces itself"
like "$line" "wa sha256 != installed.txt" "and names the mismatch"
like "$(cat "$O/canary.log" 2>/dev/null)" "CANARY RED" "and the same line goes to canary.log"

# 4. a landing in progress is skipped, and the skip ALONE is not an alarm.
printf '{}\n' > "$H/.wasm-agent/deploy-alive.json"
run_canary HASH_OTHER
like "$(cat "$O/canary.state")" "skip" "a live deploy is skipped"
ok "$(alarms)" "1" "and the skip adds no alarm"
rm -f "$H/.wasm-agent/deploy-alive.json"

# 5. the skip overwrote the red state, so after a landing it takes two FRESH reds (a stale red must not fire).
run_canary HASH_OTHER
ok "$(alarms)" "1" "the first red after a landing does not alarm"
run_canary HASH_OTHER
ok "$(alarms)" "2" "the second one does"

# 6. the bug the canary exists for: a non-MainPID sentinel holding the LIVE home.
printf '%s\n%s\n' "$MAINPID" "$LIVEHOME_PID" > "$WORK/pgrep.out"
run_canary HASH_WA
like "$(tail -1 "$O/canary.state")" "non-live sentinel with the live HOME/DB" "a non-MainPID sentinel with the live home is RED even when everything else matches"
like "$(tail -1 "$O/canary.state")" "$LIVEHOME_PID" "and the message names the pid"

if [ "$failed" -gt 0 ]; then echo "test-canary: $failed failed of $checks checks"; exit 1; fi
echo "test-canary ok ($checks checks)"
