#!/bin/bash
# ONE TEST FOR run-row.sh, and it can fail.
#
# The runner is the answer to the 27/11 incident (a row started without the runner wrote over
# ~/.wasm-agent/policy.json and the node lost its mesh). So the test asserts the two halves of the rule: the row
# it starts gets a SCRATCH home and cannot see the operator's store, and a caller who brings the real store in
# through WASM_AGENT_HOME is REFUSED BY NAME instead of being run.
#
# WHAT IT CAN CATCH: a runner that passes the caller's real HOME through to the row (the incident), one that
# refuses every row, a refusal that does not name the row, a row name escaping scripts/ as a path, and a
# scratch home that still contains the operator's state dir.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/wa-runrow.XXXXXX)  # never under the real home: that is the thing under test
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-run-row: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }

# A small tree: the runner and its lib, plus one row that only reports the environment it was given.
mkdir -p "$WORK/factory/lib" "$WORK/scripts"
cp "$HERE/run-row.sh" "$WORK/factory/run-row.sh"; cp "$HERE/lib/scratch-home.sh" "$WORK/factory/lib/"
cat > "$WORK/scripts/row-says-env" <<'EOS'
#!/bin/bash
echo "HOME=$HOME"
echo "WASM_AGENT_HOME=${WASM_AGENT_HOME:-unset}"
echo "TMPDIR=${TMPDIR:-unset}"
echo "ARG=${1:-none}"
EOS
chmod +x "$WORK/factory/run-row.sh" "$WORK/scripts/row-says-env"
REAL=$(bash -c '. "$1/lib/scratch-home.sh"; wa_real_home' _ "$WORK/factory")

# 1. THE FIX: started from the real home (and with the session's real TMPDIR), the row nevertheless gets scratch.
OUT=$(env -i PATH=/usr/bin:/bin HOME="$REAL" TMPDIR="$REAL/.wasm-agent/tmp" bash "$WORK/factory/run-row.sh" row-says-env one 2>&1); rc=$?
ok "$rc" "0" "the runner runs the row"
like "$OUT" "ARG=one" "and passes its arguments through"
H=$(printf '%s\n' "$OUT" | sed -n 's/^HOME=//p')
checks=$((checks + 1)); [ -n "$H" ] && [ "$H" != "$REAL" ] || fail "the row must get a scratch HOME, not the real one (got ${H:-empty})"
case "$H" in "$REAL"*) fail "the row's HOME is under the real home ($H)";; esac
like "$OUT" "WASM_AGENT_HOME=$H/.wasm-agent" "and a WASM_AGENT_HOME inside that scratch home"
like "$OUT" "TMPDIR=$H/tmp" "and a TMPDIR inside it too"
checks=$((checks + 1)); [ ! -e "$H/policy.json" ] || fail "the scratch home already holds a policy"

# 2. a caller who BRINGS the operator's store is refused, by name, and nothing runs.
REF=$(env -i PATH=/usr/bin:/bin HOME="$WORK/scratch" WASM_AGENT_HOME="$REAL/.wasm-agent" bash "$WORK/factory/run-row.sh" row-says-env 2>&1); rc2=$?
ok "$rc2" "3" "an inherited real WASM_AGENT_HOME is refused"
like "$REF" "REFUSED (scratch-home)" "the refusal says what it is"
like "$REF" "row-says-env" "and names the row"
checks=$((checks + 1)); case "$REF" in *"ARG="*) fail "the row must not have run at all";; esac

# 3. a name that is a path is refused: scripts/ is not a directory to wander out of.
REF2=$(env -i PATH=/usr/bin:/bin HOME="$WORK/scratch" bash "$WORK/factory/run-row.sh" ../etc/passwd 2>&1); rc3=$?
ok "$rc3" "3" "a row name with a path is refused"
like "$REF2" "is not a row name" "and says why"

# 4. a row that does not exist is refused by name.
REF3=$(env -i PATH=/usr/bin:/bin HOME="$WORK/scratch" bash "$WORK/factory/run-row.sh" row-does-not-exist 2>&1); rc4=$?
ok "$rc4" "3" "an unknown row is refused"
like "$REF3" "no row named row-does-not-exist" "and names it"

if [ "$failed" -gt 0 ]; then echo "test-run-row: $failed failed of $checks checks"; exit 1; fi
echo "test-run-row ok ($checks checks)"
