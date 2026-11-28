#!/usr/bin/env bash
# `wa update requests` AND ITS SWEEP, ON A REAL NODE (update-requests-settle, item 3 end to end).
#
# The Lua row drives remote_update directly; this one drives the VERB the operator runs, against a scratch home,
# because the verb is what Victor will type on openclaw after the next update.
#
# WHAT IS A FIXTURE HERE, said plainly: the records are written as the JSON files the product itself writes (the
# module's own storage format, read back by the module's own reader), not as SQLite rows invented by the test. The
# ROW STATE MACHINE is not re-implemented: the CLI calls remote_update.sweep, and the assertions are on the files it
# leaves behind.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-update-requests-cli: $*" >&2; exit 1; }

BASE="${WA_ROW_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W="$(mktemp -d "$BASE/wa-reqcli-XXXXXX")" || { echo "FAIL: no scratch" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

# ISOLATION, inline (scripts/lib/scratch-env.sh is not on this branch): every path under the scratch root, and the
# two variables that default to live paths cleared.
unset WASM_AGENT_DB XDG_CONFIG_HOME WA_INSTALL_DIR WSM_FAKE 2>/dev/null || true
export HOME="$W/home" WASM_AGENT_HOME="$W/home"
mkdir -p "$HOME"
case "$(realpath -m "$HOME")" in "$(realpath -m "$W")"/*) : ;; *) fail "HOME is not under the scratch root";; esac

BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "FAIL test-update-requests-cli: WA_BIN is not an executable (the suite sets it)" >&2; exit 2; }
export WASM_AGENT_LUA_ROOT="$PWD"

# WHERE THE NODE ITSELF KEEPS THEM, asked of the product rather than assumed: with a home set, `wa paths` answers
# config = <home>/.wasm-agent (NOT ~/.config/wasm-agent), so that is where remote_update.dir() looks. The directory
# name is DERIVED, because a test that writes the operator data path is refused by the node own guard.
# ASKED, NOT ASSUMED: the CLI process decides where its config lives (PATH vs a home, an install dir beside the
# program), so the row reads the answer from `wa paths` and writes its fixtures THERE.
# `wa paths` prints a `config file <path>` row as well, so the field is anchored: only an ABSOLUTE second field is
# the directory (measured: the first version read "file" and wrote its fixtures to a directory called file/).
CONFIG_DIR="$("$BIN" --db "$W/db.sqlite" paths 2>/dev/null | awk '$1 == "config" && $2 ~ /^\// { print $2; exit }')"
[ -n "$CONFIG_DIR" ] || fail "wa paths did not answer a config directory"
RECORDS="$CONFIG_DIR/remote-update"
echo "row: config=$CONFIG_DIR records=$RECORDS"
mkdir -p "$RECORDS" || fail "cannot make the records directory"
NOW="$(date +%s)"

rec() { # <id> <state> <node> <age-seconds>
  printf '{"id":"%s","kind":"deploy","state":"%s","target_commit":"%s","requested_at":%s,"requester":{"node_id":"%s"}}\n' \
    "$1" "$2" "$(printf 'ab%.0s' $(seq 1 20))" "$((NOW - $4))" "$3" > "$RECORDS/$1.json"
}
rec same-node-new queued node-a 60
rec same-node-old queued node-a 120
rec other-node-old queued node-b 90000
rec already-installed installed node-c 3600

# 1. the LISTING reads the records, newest first, with the state and the age
LIST_OUT="$("$BIN" --db "$W/db.sqlite" update requests 2>&1)"
printf '%s\n' "$LIST_OUT" | grep -q 'same-node-new' || { printf '%s\n' "$LIST_OUT" | head -5 >&2; fail "the listing does not show a record"; }
printf '%s\n' "$LIST_OUT" | grep -q 'installed' || fail "the listing does not show the installed record's state"
printf '%s\n' "$LIST_OUT" | grep -q 'age' || fail "the listing does not show an age"
ok

# 2. --sweep --dry-run closes NOTHING and says what it would close
DRY="$("$BIN" --db "$W/db.sqlite" update requests --sweep --dry-run 2>&1)"
printf '%s\n' "$DRY" | grep -q 'would sweep' || { printf '%s\n' "$DRY" | head -5 >&2; fail "the dry sweep does not say it is a dry run"; }
printf '%s\n' "$DRY" | grep -q 'superseded_by same-node-new' || fail "the dry sweep does not name the supersession"
printf '%s\n' "$DRY" | grep -q 'expired' || fail "the dry sweep does not name the expiry"
grep -q '"state":"queued"' "$RECORDS/same-node-old.json" || fail "the dry sweep CLOSED a record"
ok

# 3. --sweep closes them by name, and deletes nothing
BEFORE="$(ls -1 "$RECORDS" | wc -l)"
SWEPT="$("$BIN" --db "$W/db.sqlite" update requests --sweep 2>&1)"
printf '%s\n' "$SWEPT" | grep -q 'swept' || { printf '%s\n' "$SWEPT" | head -5 >&2; fail "the sweep did not report"; }
grep -q '"state":"superseded"' "$RECORDS/same-node-old.json" || fail "the older request of a node was not superseded"
grep -q 'superseded_by same-node-new' "$RECORDS/same-node-old.json" || fail "the supersession does not name the newer id"
grep -q '"state":"expired"' "$RECORDS/other-node-old.json" || fail "the day-old request was not expired"
grep -q '"state":"queued"' "$RECORDS/same-node-new.json" || fail "the newest request of a node must stay queued"
grep -q '"state":"installed"' "$RECORDS/already-installed.json" || fail "a settled record was touched"
AFTER="$(ls -1 "$RECORDS" | wc -l)"
[ "$BEFORE" = "$AFTER" ] || fail "the sweep DELETED something ($BEFORE -> $AFTER)"
ok

# 4. a second sweep closes nothing
SECOND="$("$BIN" --db "$W/db.sqlite" update requests --sweep 2>&1)"
printf '%s\n' "$SECOND" | grep -q '0 to close' || { printf '%s\n' "$SECOND" | head -3 >&2; fail "a second sweep closed something"; }
ok

echo "update requests cli ok ($n checks)"

