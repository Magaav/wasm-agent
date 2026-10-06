#!/usr/bin/env bash
# Scoped registry installation, executed outside a node run through sentinel request run.
# No node/UI/job installation and no device enrollment or role grants.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="${1:-}"; REASON="${2:-}"; UNIT=wa-rendezvous.service
fail(){ printf 'rendezvous deploy: %s\n' "$*" >&2; exit 1; }
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] && [ -n "$REASON" ] || fail 'usage: deploy-rendezvous.sh <full-main-commit> <reason>'
[ -z "${WA_TOOL_INVOCATION:-}" ] && [ -z "${WASM_AGENT_RUN_ID:-}" ] || fail 'queue through the sentinel outside a run'
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$EXPECTED" ] || fail 'source moved'
[ -z "$(git -C "$ROOT" status --porcelain)" ] || fail 'source dirty'
git -C "$ROOT" fetch origin
[ "$(git -C "$ROOT" rev-parse origin/main)" = "$EXPECTED" ] || fail 'source is not origin/main'
[ "$(git -C "$ROOT" ls-remote origin refs/heads/main)" = "${EXPECTED}"$'\trefs/heads/main' ] || fail 'remote main moved'
PID="$(systemctl show "$UNIT" -p MainPID --value)"
[ "${PID:-0}" -gt 0 ] || fail 'registry not running; inspect instead of guessing target'
TARGET="$(readlink -f "/proc/$PID/exe")"; [ -f "$TARGET" ] && [ -w "$(dirname "$TARGET")" ] || fail 'actual registry executable unavailable/unwritable'
COMMAND="$(tr '\0' ' ' < "/proc/$PID/cmdline")"
[[ "$COMMAND" == *' rendezvous '* ]] || fail 'service PID is not a registry'
UNIT_USER="$(systemctl show "$UNIT" -p User --value)"; [ "$UNIT_USER" = "$(id -un)" ] || fail 'registry user differs; private restore permissions unverified'
# Binary is shared with a node only when the native service fact proves that; refuse instead of replacing it blindly.
NODE_TARGET="$(readlink -f "$HOME/.local/bin/wa" 2>/dev/null || true)"
[ "$TARGET" != "$NODE_TARGET" ] || fail 'registry shares node executable; use node deployment first'
[ ! "$TARGET" -ef "$NODE_TARGET" ] || fail 'registry/node are hard-linked; use coordinated installation'
sudo -n true || fail 'service restart authority unavailable before installation'
DB="$(python3 - "$PID" <<'PY'
import pathlib,sys
args=pathlib.Path('/proc/'+sys.argv[1]+'/cmdline').read_bytes().split(b'\0')
i=args.index(b'--db');print(args[i+1].decode())
PY
)"
[ -f "$DB" ] || fail 'exact service registry database unavailable'
CARGO_BUILD_JOBS=2 cargo build --release --offline --locked --manifest-path "$ROOT/rust/Cargo.toml" -p wa-host || fail 'canonical native build failed before installation'
[ -f "$ROOT/rust/target/release/wa" ] || fail 'canonical build produced no binary'
NEW="$ROOT/rust/target/release/wa"
DIR="$(dirname "$TARGET")"; EVIDENCE="$DIR/rendezvous-deploy-$EXPECTED"
umask 077
mkdir "$EVIDENCE" || fail 'existing deployment evidence; inspect outcome, never replay'
MUTATED=0; VERIFIED=0
trap 'status=$?; if [ "$MUTATED" = 1 ] && [ "$VERIFIED" != 1 ]; then printf "phase=unknown\nexit=%s\nreason=installation boundary crossed; inspect original backup and actual service before recovery\n" "$status" > "$EVIDENCE/state.txt"; fi' EXIT
printf 'source=%s\nreason=%s\nold_pid=%s\nold_target=%s\n' "$EXPECTED" "$REASON" "$PID" "$TARGET" > "$EVIDENCE/intent.txt"
cp -p "$TARGET" "$EVIDENCE/wa.before"
python3 - "$DB" "$EVIDENCE/registry.before.sqlite" <<'PY'
import sqlite3,sys
source=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); target=sqlite3.connect(sys.argv[2]);source.backup(target);target.close();source.close()
PY
sha256sum "$NEW" "$EVIDENCE/wa.before" > "$EVIDENCE/hashes.txt"
# Prove exact new protocol using a private registry and identity, never production requests.
node "$ROOT/scripts/test-binding.cjs" "$NEW" > "$EVIDENCE/focused.log" 2>&1 || fail 'private binding fixture failed; no service change'
node "$ROOT/scripts/test-binding-runtime.cjs" "$NEW" > "$EVIDENCE/runtime.log" 2>&1 || fail 'private recovery fixture failed; no service change'
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$EXPECTED" ] && [ -z "$(git -C "$ROOT" status --porcelain)" ] || fail 'source changed during checks'
OLD_SERVICE="$(curl -fsS --max-time 10 http://127.0.0.1:8890/service)"
printf '%s\n' "$OLD_SERVICE" > "$EVIDENCE/service.before.json"
[ "$(git -C "$ROOT" ls-remote origin refs/heads/main)" = "${EXPECTED}"$'\trefs/heads/main' ] || fail 'remote main changed before swap'
[ "$(systemctl show "$UNIT" -p MainPID --value)" = "$PID" ] && [ "$(readlink -f "/proc/$PID/exe")" = "$TARGET" ] || fail 'registry generation changed before swap'
cmp -s "$TARGET" "$EVIDENCE/wa.before" || fail 'old installed image changed before swap'
printf 'phase=swapping\n' > "$EVIDENCE/state.txt"
MUTATED=1
install -m 755 "$NEW" "$DIR/.wa.rendezvous.$EXPECTED"; mv -f "$DIR/.wa.rendezvous.$EXPECTED" "$TARGET"
if ! sudo -n systemctl restart "$UNIT"; then
  printf 'phase=unknown\nreason=restart refused after file swap; inspect actual process, no automatic replay\n' > "$EVIDENCE/state.txt"
  fail 'restart refused after swap; original binary/registry preserved for explicit recovery'
fi
sleep 1
NEW_PID="$(systemctl show "$UNIT" -p MainPID --value)"
[ "$NEW_PID" -gt 0 ] && [ "$NEW_PID" != "$PID" ] || fail 'new service process unconfirmed'
[ "$(readlink -f "/proc/$NEW_PID/exe")" = "$TARGET" ] || fail 'service executes a different target'
cmp -s "$NEW" "$TARGET" || fail 'installed bytes differ'
curl -fsS --max-time 10 http://127.0.0.1:8890/service > "$EVIDENCE/service.after.json"
python3 - "$EVIDENCE/service.before.json" "$EVIDENCE/service.after.json" <<'PY'
import json,sys
old,new=[json.load(open(p)) for p in sys.argv[1:]]
assert new['protocol']==1 and new['binding_protocol']==1 and new['enrollment_ready'] is True
pins=lambda x: sorted((p['node_id'],p['public_key']) for p in x['operators'])
assert pins(old)==pins(new),'operator pins changed during deployment'
PY
HASH="$(sha256sum "$TARGET" | cut -d' ' -f1)"
printf 'commit=%s\nsha256=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nservice=%s\npid=%s\nreason=%s\n' "$EXPECTED" "$HASH" "$UNIT" "$NEW_PID" "$REASON" > "$DIR/rendezvous-installed.txt"
VERIFIED=1
printf 'phase=verified\n' > "$EVIDENCE/state.txt"
printf 'rendezvous installed %s pid=%s sha=%s; evidence=%s\n' "$EXPECTED" "$NEW_PID" "$HASH" "$EVIDENCE"
