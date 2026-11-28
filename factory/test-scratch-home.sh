#!/bin/bash
# ONE TEST FOR lib/scratch-home.sh, and it can fail.
#
# The guard exists because a row with the real home reached ~/.wasm-agent/policy.json and deleted the node's
# mesh. So the test is built the way the incident happened: it asks the guard about test-features-defaults with
# the REAL home and requires a refusal that NAMES the row, and it asks with a scratch home and requires a pass.
#
# WHAT IT CAN CATCH: a guard that passes everything (the incident), one that refuses everything (it would stop
# a correct row), a refusal that does not name what was refused, and a helper that leaves WASM_AGENT_HOME or
# TMPDIR pointing at the real home.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-sh-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-scratch-home: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }

# The guard is asked in a CLEAN environment: env -i, so nothing this session has exported can make the answer
# look right. That is the whole point - the incident was an inherited environment.
cat > "$WORK/ask" <<'EOS'
#!/bin/bash
. "$1/lib/scratch-home.sh"; shift
wa_require_scratch_home "$@"
EOS
cat > "$WORK/hand-out" <<'EOS'
#!/bin/bash
. "$1/lib/scratch-home.sh"; shift
wa_scratch_home wa-row-test && { wa_require_scratch_home test-features-defaults && echo "accepted:$WA_SCRATCH"; }
EOS
chmod +x "$WORK/ask" "$WORK/hand-out"
ask() { env -i PATH=/usr/bin:/bin "$@" bash "$WORK/ask" "$HERE" 2>&1; }

REAL=$(env -i PATH=/usr/bin:/bin bash -c '. "$1/lib/scratch-home.sh"; wa_real_home' _ "$HERE")
ok "$(basename "$(dirname "$REAL")")" "home" "the real home is resolved from the account, not from HOME ($REAL)"

# 1. THE INCIDENT: test-features-defaults with the real home must be refused, by name.
REF=$(ask HOME="$REAL" bash "$WORK/ask" "$HERE" test-features-defaults); rc=$?
ok "$rc" "3" "a row with the real home is refused"
like "$REF" "REFUSED (scratch-home)" "the refusal announces itself"
like "$REF" "test-features-defaults" "and names the row that would have run"
like "$REF" "HOME is the real home" "and the variable at fault"

# 2. an explicit WASM_AGENT_HOME at the real state dir is refused even with a scratch HOME.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/wa-sh-scratch.XXXXXX")
REF2=$(env -i PATH=/usr/bin:/bin HOME="$SCRATCH" WASM_AGENT_HOME="$REAL/.wasm-agent" TMPDIR="$SCRATCH/tmp" bash "$WORK/ask" "$HERE" test-features-gate 2>&1); rc2=$?
ok "$rc2" "3" "WASM_AGENT_HOME at the real state dir is refused"
like "$REF2" "WASM_AGENT_HOME is the real state dir" "and the refusal says so"

# 3. HOME unset is refused too: a row that inherits nothing writes wherever it happens to be.
REF3=$(env -i PATH=/usr/bin:/bin bash "$WORK/ask" "$HERE" land-health-program 2>&1); rc3=$?
ok "$rc3" "3" "HOME unset is refused"
like "$REF3" "HOME is unset" "with the reason"

# 4. a TMPDIR under the real home is refused (where those wa-outbox-* dirs came from).
REF4=$(env -i PATH=/usr/bin:/bin HOME="$SCRATCH" WASM_AGENT_HOME="$SCRATCH/.wasm-agent" TMPDIR="$REAL/.wasm-agent/tmp" bash "$WORK/ask" "$HERE" turn-signal 2>&1); rc4=$?
ok "$rc4" "3" "TMPDIR under the real home is refused"
like "$REF4" "TMPDIR is under the real home" "with the reason"

# 5. the scratch home the helper hands out is accepted, and it points nowhere real.
OUT=$(env -i PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" bash "$WORK/hand-out" "$HERE" 2>&1); rc5=$?
ok "$rc5" "0" "a scratch home is accepted"
like "$OUT" "accepted:" "and the row may run"
SD=${OUT#*accepted:}
checks=$((checks + 1)); case "$SD" in "$REAL"*) fail "the helper handed out a dir under the real home ($SD)";; esac
checks=$((checks + 1)); { [ -d "$SD/.wasm-agent" ] && [ -d "$SD/tmp" ]; } || fail "the helper must create its state dir and tmp ($SD)"
rm -rf "$SD" "$SCRATCH"

if [ "$failed" -gt 0 ]; then echo "test-scratch-home: $failed failed of $checks checks"; exit 1; fi
echo "test-scratch-home ok ($checks checks)"
