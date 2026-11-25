#!/usr/bin/env bash
# ALIVE DURING A SLOW DOWNLOAD, AND A SECOND DEPLOY TURNED AWAY (25/11, Fable's G - the row she asked for).
#
# THE CASE. The sentinel moves a deploy request to done/ the moment it starts the installer, and the installer then
# fetches for as long as the link takes (49 s on work, minutes on a slow one). If nothing says "a deploy is alive"
# during that stretch, lua/core/deploy_pause.lua releases every paused session into a paid turn that finds no install
# coming. And a second deploy that arrives now must NOT take the first one's record over or erase it.
#
# HOW, without a network and without a real release:
#   * a paced STUB CHANNEL: scripts/lib/http-stub.py serves a directory on 127.0.0.1, and a `.rate` sidecar beside a
#     file paces its body (the stub documents it: "the body is paced to that many bytes per second"). The manifest the
#     deploy fetches FIRST is 6 MB paced at 200 kB/s, so the download lasts ~30 s;
#   * the REAL scripts/deploy.sh runs against it, in a scratch root, through scripts/lib/scratch-installer.sh;
#   * while the download is in flight two things are asserted: the alive record EXISTS and names the deploy (it was
#     written before the download started), and a SECOND deploy is refused with refused(deploy_alive_held) and leaves
#     the record in place;
#   * when the first deploy ends, its record is gone.
#
# The deploy is expected to FAIL afterwards (the manifest is not a real one): this row is about the window, not the
# install. It says so instead of pretending otherwise.
#
#   bash scripts/test-deploy-alive-slow-download.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/scratch-installer.sh"
. "$ROOT/scripts/lib/node-binaries.sh"

root="$(wa_scratch_root wa-deploy-alive-slow)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
STUB_PID=""; DEPLOY_PID=""
cleanup() {
  [ -n "$DEPLOY_PID" ] && kill "$DEPLOY_PID" 2>/dev/null
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
REAL_HOME="${HOME:-}"
export HOME="$W/home"; mkdir -p "$HOME"
HOME="$REAL_HOME" wa_scratch_home_guard "$HOME" || exit 2
export WASM_AGENT_HOME="$HOME"
unset WASM_AGENT_RENDEZVOUS WASM_AGENT_RELAY WA_GRAPH_ROOT WA_GRAPH_DB

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip_all() { printf 'SKIP test-deploy-alive-slow-download: %s\n' "$1"; exit 3; }

command -v python3 >/dev/null 2>&1 || skip_all "python3 is needed for the paced stub server"
TRIPLE="$(wa_node_target_triple 2>/dev/null)" || skip_all "this host has no node-binary target triple"
# THE ROW'S OWN TREE IS ITS OWN origin/main (25/11, rows/20261125T092844Z-15279 and 20261125T093036Z-7284): on an
# UNLANDED branch the row's detached checkout is behind origin/main, and deploy.sh refuses it (refused(source_pin_stale))
# before it reaches anything this row measures - its pre-swap trap then clears the alive record, so the record checks
# read an empty file and the second deploy falls through to the pin refusal. This has to happen BEFORE the deploy is
# started (the first attempt put it after, where it changed nothing). It touches only this throwaway checkout, the way
# the covering row touches only its own fixture remote.
SHORT="$(git -C "$ROOT" rev-parse HEAD | cut -c1-12)"
# THE ROW DEPLOYS FROM A CLONE OF ITS OWN TREE (25/11, rows/20261125T093218Z-1824 ... rows/20261125T094028Z-26428).
# deploy.sh refuses a detached worktree whose origin/main is ahead (refused(source_pin_stale)) - correct behaviour,
# and on an UNLANDED branch the runner's shared checkout is exactly that, while a ref this row sets there does not
# stick (the runner's own fetch owns it). A throwaway clone of the row's tree has nothing to be behind: its
# origin/main IS its HEAD. Nothing outside the row is touched, and the deploy is told to use it.
DEPLOY_TREE="$W/tree"
env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git clone -q "$ROOT" "$DEPLOY_TREE" 2>/dev/null   || skip_all "cannot clone the row's tree into its scratch root"
# ON MAIN, NOT DETACHED. Measured in rows/20261125T103226Z-9393: deploy.sh refuses a tree that is not a checkout of
# main - "exactly one canonical main checkout is required; found 0 on branch refs/heads/main" - and a detached
# clone has refs/heads/main but no checkout ON it, so the deploy ended before it ever wrote a commit.
env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$DEPLOY_TREE" checkout -q -B main "$SHORT" 2>/dev/null   || skip_all "cannot check out $SHORT on main in the row's clone"
# AND THE CLONE IS ITS OWN REMOTE. A clone of the row's tree still names the real repository as origin, and
# deploy.sh fetches before it compares - so origin/main came back as the landed main (8d52b70f) while the row's
# tree sat at its own unlanded commit, and BOTH deploys refused with refused(source_pin_stale) before the
# alive record could carry a commit. Pointing origin at the clone makes every fetch a no-op that answers the
# clone's own main, which is the row's commit.
env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$DEPLOY_TREE" remote set-url origin "$DEPLOY_TREE" 2>/dev/null   || skip_all "cannot point the clone at itself"
env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$DEPLOY_TREE" update-ref refs/remotes/origin/main "$SHORT"   || skip_all "cannot make the clone its own origin/main"
echo "row: deploying from $DEPLOY_TREE, origin/main $(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$DEPLOY_TREE" rev-parse --short=12 origin/main) HEAD $SHORT"


# ---- the paced channel -------------------------------------------------------------------------------
CH="$W/channel"; mkdir -p "$CH/node-$SHORT" "$W/tmp"
# 6 MB at 200 kB/s: about thirty seconds of manifest, and the deploy asks for the manifest first.
head -c 6291456 /dev/zero | tr '\0' 'x' > "$CH/node-$SHORT/node-$SHORT.manifest"
printf '200000\n' > "$CH/node-$SHORT/node-$SHORT.manifest.rate"
cp -f "$CH/node-$SHORT/node-$SHORT.manifest" "$CH/node-$SHORT.manifest"
printf '200000\n' > "$CH/node-$SHORT.manifest.rate"
printf 'node-%s\n' "$SHORT" > "$CH/releases.txt"
python3 "$ROOT/scripts/lib/http-stub.py" "$CH" "$W/stub.port" > "$W/stub.log" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 100); do [ -s "$W/stub.port" ] && break; sleep 0.1; done
PORT="$(cat "$W/stub.port" 2>/dev/null)"
[ -n "$PORT" ] || skip_all "the stub server did not report a port: $(tail -2 "$W/stub.log")"
echo "slow channel: 127.0.0.1:$PORT, manifest 6 MB paced at 200 kB/s (~30 s)"

# ---- the first deploy, on the real script ------------------------------------------------------------
INSTALL="$HOME/install"; mkdir -p "$INSTALL/scripts"
DATA="$HOME/.wasm-agent"
OUT="$W/deploy.out"
wa_installer_run --root "$W" --cd "$DEPLOY_TREE" --port "$((30000 + RANDOM % 9000))" --install-dir "$INSTALL" --set WA_NODE_BINARIES_URL="http://127.0.0.1:$PORT" \
  --set WA_DEPLOY_FULL=1 --set WA_DEPLOY_TREE_WAIT=5 --set WA_DEPLOY_ROOT="$DEPLOY_TREE" \
  --set WA_SENTINEL_SUPERVISOR=none --set WA_SERVICE_UNIT_FILE="$W/no-such.unit" \
  -- bash scripts/deploy.sh --reason "test-deploy-alive-slow-download" > "$OUT" 2>&1 &
DEPLOY_PID=$!

ALIVE="$DATA/deploy-alive.json"
waited=0
while [ ! -f "$ALIVE" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
ok "$([ -f "$ALIVE" ] && echo 1)" "the alive record exists before the download is over" "after ~$((waited / 10))s, log: $(grep -c . "$OUT" 2>/dev/null) lines"
HOLDER="$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$ALIVE" 2>/dev/null | head -1)"
ok "$([ -n "$HOLDER" ] && echo 1)" "and it names the deploy that wrote it (pid ${HOLDER:-none})" "$(cat "$ALIVE" 2>/dev/null)"
ok "$(grep -q 'running state written (pid' "$OUT" && echo 1)" "and the deploy said so on its own output" "$(grep 'running state' "$OUT" | head -1)"
# THE RECORD NAMES THE COMMIT ONCE THE DEPLOY KNOWS IT (25/11, measured during the rc-cover install): alive-first
# writes the record before COMMIT is resolved, and it said "commit":"unknown" while the install ran - a held worker
# turn was told it waited for "the install of unknown". Same pid, same start time, and the commit appears.
alive_commit=""
for _ in $(seq 1 100); do
  alive_commit="$(sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' "$ALIVE" 2>/dev/null | head -1)"
  [ -n "$alive_commit" ] && [ "$alive_commit" != unknown ] && break
  sleep 0.1
done
ok "$([ -n "$alive_commit" ] && [ "$alive_commit" != unknown ] && echo 1)" \
  "the alive record names the deploy's commit once it is resolved, not 'unknown'" "commit=${alive_commit:-none} record=$(cat "$ALIVE" 2>/dev/null)"
# THE EVIDENCE HAS TO SURVIVE THE RUN (25/11): the runner deletes the scratch root, so a failing row left
# nothing to read - twice. The deploy's own output and the stub's log are printed HERE, in the row's log,
# whether or not the assertion above held: they say whether the paced manifest was the file the deploy
# fetched, and when the deploy ended.
if [ -z "$alive_commit" ] || [ "$alive_commit" = unknown ]; then
  echo "  -- diagnostics: no commit in the alive record"
  echo "  -- deploy.out tail:"
  tail -12 "$OUT" 2>/dev/null | sed "s/^/     /"
  echo "  -- stub.log tail:"
  tail -8 "$W/stub.log" 2>/dev/null | sed "s/^/     /"
  echo "  -- alive record now: $(cat "$ALIVE" 2>/dev/null || echo "(absent)")"
  echo "  -- deploy pid $DEPLOY_PID alive: $(kill -0 "$DEPLOY_PID" 2>/dev/null && echo yes || echo no)"
fi
ok "$([ "$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$ALIVE" | head -1)" = "$HOLDER" ] && echo 1)" \
  "and it is still the same deploy's record (same pid), not a new one" "holder=$HOLDER record=$(cat "$ALIVE" 2>/dev/null)"

# ---- the second deploy, which must be turned away ------------------------------------------------------
SECOND="$W/deploy2.out"
rc2=0
wa_installer_run --root "$W" --cd "$DEPLOY_TREE" --port "$((30000 + RANDOM % 9000))" --install-dir "$INSTALL" --set WA_NODE_BINARIES_URL="http://127.0.0.1:$PORT" \
  --set WA_DEPLOY_FULL=1 --set WA_DEPLOY_ROOT="$DEPLOY_TREE" --set WA_SENTINEL_SUPERVISOR=none \
  --set WA_SERVICE_UNIT_FILE="$W/no-such.unit" \
  -- bash scripts/deploy.sh --reason "a second deploy during the download" > "$SECOND" 2>&1 || rc2=$?
ok "$([ "$rc2" = 1 ] && echo 1)" "a second deploy while the first is downloading is refused as a PRE-SWAP refusal (exit 1, not 3)" "rc=$rc2 $(tail -2 "$SECOND" | tr '\n' ' ')"
ok "$(grep -q 'refused(deploy_alive_held)' "$SECOND" && echo 1)" "and it is refused BY NAME: refused(deploy_alive_held)" "$(grep -m1 'refused(' "$SECOND")"
ok "$([ -f "$ALIVE" ] && [ "$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$ALIVE" | head -1)" = "$HOLDER" ] && echo 1)" \
  "and the first deploy's record is still there, still naming it" "$(cat "$ALIVE" 2>/dev/null)"

# ---- and when the first deploy ends, its record goes ------------------------------------------------
kill "$DEPLOY_PID" 2>/dev/null; wait "$DEPLOY_PID" 2>/dev/null; DEPLOY_PID=""
for _ in $(seq 1 100); do [ ! -f "$ALIVE" ] && break; sleep 0.1; done
ok "$([ ! -f "$ALIVE" ] && echo 1)" "when the first deploy ends, it clears its own record" "$(cat "$ALIVE" 2>/dev/null)"
ok "$(grep -q 'refused\|error\|node_' "$OUT" && echo 1)" "the first deploy's own outcome is recorded (it fetched a manifest that is not a real one, so it refuses - the window is what this row measures)" "$(tail -1 "$OUT")"

printf 'test-deploy-alive-slow-download: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
