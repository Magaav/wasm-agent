#!/usr/bin/env bash
# A REFUSED SECOND DEPLOY NEVER SWEEPS A LIVE INSTALL'S STAGED FILES (Fable 25/11, change/guards-before-alive).
#
# THE CASE. `sweep_stale_staging` deletes what a killed deploy left staged (`*.new.*`, `*.ship.*`) in the install
# directory. It runs right after the running record is written, so a second deploy - one the first holds
# (`refused(deploy_alive_held)`) - is turned away BEFORE it can sweep, and the install that is still running keeps
# its staged files. A FIRST deploy alone still sweeps them: the sweep is the point.
#
# Both halves on the same 15-minute-old file:
#   1. record held  -> a deploy exits 1 with refused(deploy_alive_held) and the file is UNTOUCHED;
#   2. record clear -> a deploy takes the record, sweeps the file, and the file is GONE.
#
#   bash scripts/test-deploy-sweep-after-record.sh
#
# Scratch only (own root, own HOME, the scratch-home guard refuses the operator's). Nothing is installed: the
# second run is bounded by `timeout` and dies on its own after the sweep, and no network is reached before it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
DEPLOY="$ROOT/scripts/deploy.sh"
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/deploy-alive.sh"
if [ -n "${WA_ROW_SCRATCH_ROOT:-}" ]; then WORK="$WA_ROW_SCRATCH_ROOT/row-work"; else WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-sweep-after-record.XXXXXX")"; fi
mkdir -p "$WORK" "$WORK/home" "$WORK/data" "$WORK/install"
wa_scratch_home_guard "$WORK/home" || { echo 'sweep-after-record REFUSED: the scratch home is the operator node home' >&2; exit 2; }
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home"
export WASM_AGENT_DATA="$WORK/data"
# NO SERVICE IS PROBED, because this scratch install has none (measured 25/11, row 20261125T115123Z-1461):
# scripts/lib/service-target.sh asks the machine with plain `systemctl show ... ExecStart` (line 117), NOT
# through WA_SENTINEL_UNIT_SYSTEMCTL, so inside the runner it read the LIVE unit - "/home/victor/.local/bin ...
# they are different installs" - and the deploy refused before the record, which is the wrong refusal for this
# row. The shim below is the same answer a scratch `systemctl --user` would give (no such unit), not a stub that
# accepts something: it makes the probe find nothing, which is true here.
SHIM="$WORK/bin"
mkdir -p "$SHIM" || exit 1
printf '#!/bin/sh
exit 1
' > "$SHIM/systemctl"
chmod +x "$SHIM/systemctl"
export PATH="$SHIM:$PATH"
DATA="$WORK/data"
INSTALL="$WORK/install"
ALIVE="$(wa_deploy_alive_path "$DATA")"

checks=0; failed=0
ok() { checks=$((checks+1)); }
fail() { echo "sweep-after-record FAILED: $*" >&2; exit 1; }
has() { case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | head -4 | tr '\n' ' ')" ;; esac; }

# A STAGED FILE WITH AGE: the sweep is about leftovers, so the row does not rely on the file being new.
STAGED="$INSTALL/wa.new.1234"
printf 'staged bytes\n' > "$STAGED" || fail 'could not place the staged file'
touch -d '15 minutes ago' "$STAGED" 2>/dev/null || true
AGE="$(( $(date +%s) - $(stat -c %Y "$STAGED") ))"
[ "$AGE" -gt 600 ] || fail "the staged file is only ${AGE}s old; this row wants an old one"
ok

deploy() { env WA_INSTALL_DIR="$INSTALL" WA_DEPLOY_ROOT="$ROOT" timeout 20 bash "$DEPLOY" 2>&1; }

# 1. THE RECORD IS HELD by someone else (written here by the row, pid ours, then the deploy is a different pid
#    by construction - it is a child). A held deploy must stop BEFORE the sweep.
wa_deploy_alive_write "$DATA" 1800 held-by-the-row >/dev/null 2>&1 || fail 'could not write the holding record'
[ -f "$ALIVE" ] || fail 'the holding record was not written'
OUT="$(deploy)"; RC=$?
[ "$RC" = 1 ] || fail "a deploy a live record holds exits 1, got $RC"
has "$OUT" 'refused(deploy_alive_held)' 'the second deploy is refused by name'
[ -f "$STAGED" ] || fail 'THE DEFECT: a refused second deploy swept the staged file of the install that is still running'
ok

# 2. THE RECORD IS CLEAR: a first deploy alone takes the record and sweeps the leftover.
wa_deploy_alive_clear "$DATA" >/dev/null 2>&1 || true
OUT="$(deploy)"; RC=$?
[ -f "$STAGED" ] && fail "a first deploy alone did not sweep the staged file (exit $RC): $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
ok
# ...and the sweep is OURS to prove: the run was not refused for another reason before it got there.
has "$(printf '%s' "$OUT")" 'staging residue' 'the sweep said what it removed (or the run reached it)'

if [ -f "$ALIVE" ]; then wa_deploy_alive_clear "$DATA" >/dev/null 2>&1 || true; fi
echo "deploy sweep after record: $checks checks, $failed failed"
[ "$failed" = 0 ] || exit 1
