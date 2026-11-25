#!/usr/bin/env bash
# A REFUSED DEPLOY LEAVES NO RUNNING RECORD AND PAUSES NOBODY (Fable 25/11, change/guards-before-alive).
#
# THE HOLE THIS CLOSES. deploy.sh wrote its alive record at the very top (97e201d5), and then REFUSED for
# reasons that need no network at all - "cannot deploy from a turn running on the node it would replace",
# "deploying from a CLI turn needs a sentinel supervising the node", refused(install_dir_missing). Measured
# that day (deploy.log 09:48Z-10:00Z): a deploy that was never going to run had already taken the live record
# and paused sessions. The record now moves BELOW those guards (33f41834) and this row holds that: for each
# refusal, a 0.1 s watcher runs from before the start to after the exit and must never see the record, and the
# pause store must never gain a row.
#
# IT ALSO CHECKS THE ORDER, read off the script itself, because a later edit could move the block back up
# without any refusal changing its words: the write must come AFTER each of the three guards and BEFORE the
# components question (0e), which is the first thing that touches the network.
#
#   bash scripts/test-deploy-guards-before-alive.sh
#
# Scratch only: its own root, its own HOME, and the scratch-home guard refuses the operator's. Nothing is
# installed and no deploy ever gets past the guards.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
DEPLOY="$ROOT/scripts/deploy.sh"
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/deploy-alive.sh"
# THE ROW S OWN ROOT, in one piece (measured 25/11: the first shape concatenated two expansions and HOME became
# <root>/tmp<root>/home, so the scratch-home guard refused by name - which is how it should fail, but the row
# was the thing at fault).
if [ -n "${WA_ROW_SCRATCH_ROOT:-}" ]; then
  WORK="$WA_ROW_SCRATCH_ROOT/row-work"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-guards-before-alive.XXXXXX")"
fi
mkdir -p "$WORK" "$WORK/home" "$WORK/data" "$WORK/install"
# THE GUARD RUNS BEFORE THE SCRATCH HOME IS EXPORTED (measured 25/11, row 20261125T113637Z-14951): it resolves the
# OPERATOR home from \$HOME, so with \$HOME already pointing at the (still empty) scratch home it answers
# refused(real_node_home) - could not be resolved - which is the guard being right again. Candidate first, guard
# second, export third.
wa_scratch_home_guard "$WORK/home" || { echo 'guards-before-alive REFUSED: the scratch home is the operator node home' >&2; exit 2; }
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home"
# THE RECORD'S OWN DIRECTORY: deploy.sh reads DEPLOY_ALIVE_DIR from WASM_AGENT_DATA first (deploy.sh:318), so the
# row exports that and asks the library for the path - the watcher then looks exactly where the deploy would write.
export WASM_AGENT_DATA="$WORK/data"
DATA="$WORK/data"
ALIVE="$(wa_deploy_alive_path "$DATA")"
# THE PAUSE STORE IS THE ONE THE PRODUCT READS (lua/core/deploy_pause.lua:567: <dir>/pauses.jsonl, dir being the
# data dir this row already exported), never a path guessed here - a guessed path that does not exist would
# make this check pass for the wrong reason (measured: the first shape of this row named
# $HOME/.wasm-agent/deploy-pauses.jsonl).
PAUSES="$WASM_AGENT_DATA/pauses.jsonl"

checks=0; failed=0
ok() { checks=$((checks+1)); }
fail() { echo "guards-before-alive FAILED: $*" >&2; exit 1; }
has() { case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | head -3 | tr '\n' ' ')" ;; esac; }

# THE WATCHER. 0.1 s, from BEFORE the command starts to AFTER it exits, so a record that exists for one tick is
# caught; it records only when the file EXISTS (silence means it never did).
watch_start() {
  : > "$WORK/watch.log"
  ( while :; do
      [ -f "$ALIVE" ] && echo "$(date +%s%3N) present" >> "$WORK/watch.log"
      sleep 0.1
    done ) &
  WATCH_PID=$!
}
watch_stop() {
  kill "$WATCH_PID" 2>/dev/null
  wait "$WATCH_PID" 2>/dev/null
  if [ -s "$WORK/watch.log" ]; then
    fail "the alive record existed during a REFUSED deploy ($(wc -l < "$WORK/watch.log") sample(s); first $(head -1 "$WORK/watch.log")); the record must be written only after the guards"
  fi
  ok
  rm -f "$ALIVE"
  if [ -s "$PAUSES" ]; then
    fail "a REFUSED deploy wrote a pause row ($(head -1 "$PAUSES")); nothing may be paused by a deploy that never ran"
  fi
  ok
}

run_deploy() { # <label> <expected sentence> <env...>
  local label="$1" expect="$2"; shift 2
  watch_start
  OUT="$(env "$@" bash "$DEPLOY" 2>&1)"; RC=$?
  watch_stop
  [ "$RC" = 1 ] || fail "$label: a pre-swap refusal exits 1, got $RC"
  has "$OUT" "$expect" "$label names its refusal"
}

# 1. A turn on the node it would replace: the guard reads the ancestors (none named wa here) and treats
#    WASM_AGENT_IN_TURN=1 with no node ancestry as `unknown`, the same arm as `node` - measured, not assumed.
run_deploy 'node turn' 'cannot deploy from a turn running on the node it would replace' \
  WASM_AGENT_IN_TURN=1 WA_INSTALL_DIR="$WORK/install" WA_DEPLOY_ROOT="$ROOT"

# 2. A CLI turn with no sentinel: `turn_owner` reads argv, so the row gives it the argv a CLI turn really has -
#    an ancestor whose basename is `wa` with the subcommand `chat` (a copy of this shell under that name; it is
#    the shape the guard reads, not a claim that a chat is running).
cp -f "$(command -v bash)" "$WORK/wa" 2>/dev/null || fail 'could not place the argv stand-in'
WATCH_PID=; watch_start
OUT="$(env WASM_AGENT_IN_TURN=1 WA_INSTALL_DIR="$WORK/install" WA_DEPLOY_ROOT="$ROOT" "$WORK/wa" chat -c "bash '$DEPLOY'" 2>&1)"; RC=$?
watch_stop
[ "$RC" = 1 ] || fail "cli turn: a pre-swap refusal exits 1, got $RC"
has "$OUT" 'deploying from a CLI turn needs a sentinel supervising the node (wa-sentinel start); none is watching' 'cli turn names its refusal'

# 3. No install directory and no record: nothing may be written, and no session may be paused.
run_deploy 'install dir missing' 'refused(install_dir_missing)' \
  WA_INSTALL_DIR="$WORK/no-such-install" WA_DEPLOY_ROOT="$ROOT"

# THE ORDER, off the script itself: the write is AFTER the three guards, BEFORE 0e (the first network question).
line_of() { grep -n -- "$1" "$DEPLOY" | head -1 | cut -d: -f1; }
WRITE=$(line_of 'wa_deploy_alive_write "$DEPLOY_ALIVE_DIR"')
G_TURN=$(grep -n 'cannot deploy from a turn running on the node it would replace' "$DEPLOY" | grep -v '^\s*#' | head -1 | cut -d: -f1)
G_CLI=$(grep -n 'deploying from a CLI turn needs a sentinel supervising the node' "$DEPLOY" | grep -v '^\s*#' | head -1 | cut -d: -f1)
G_INSTALL=$(grep -n 'refused(install_dir_missing)' "$DEPLOY" | grep -v '^\s*#' | head -1 | cut -d: -f1)
G_0E=$(grep -n '^# 0e\.' "$DEPLOY" | head -1 | cut -d: -f1)
SWEEP=$(line_of 'sweep_stale_staging')
[ -n "$WRITE" ] || fail 'the alive write is not in deploy.sh any more'
for pair in "node-turn:$G_TURN" "cli-turn:$G_CLI" "install-dir:$G_INSTALL"; do
  name=${pair%%:*}; line=${pair#*:}
  [ -n "$line" ] || fail "the $name guard is not in deploy.sh any more"
  [ "$WRITE" -gt "$line" ] || fail "the alive record (line $WRITE) must be written AFTER the $name guard (line $line)"
  ok
done
[ -n "$G_0E" ] || fail '0e is not in deploy.sh any more'
[ "$WRITE" -lt "$G_0E" ] || fail "the alive record (line $WRITE) must be written BEFORE 0e (line $G_0E)"
ok
[ "$SWEEP" -gt "$WRITE" ] || fail "the stale-staging sweep (line $SWEEP) must run AFTER the record (line $WRITE)"
ok

echo "deploy guards before alive: $checks checks, $failed failed"
[ "$failed" = 0 ] || exit 1
