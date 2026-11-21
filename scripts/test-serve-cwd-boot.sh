#!/usr/bin/env bash
# Does a node started in a huge working directory answer /health at boot?
#
#   bash scripts/test-serve-cwd-boot.sh [directories]
#
# MEASURED ON openclaw, 21/11 10:50 (node-bfad4f8fbe59): with cwd=$HOME (a home that links into a
# 713k-directory /local tree) the node answered /health only after 60-150 s, twice, A/B/A; from /tmp
# and from a small checkout it answered in 1-2 s. While it hung the log stopped after
# "[client] client-tools bridge" and "[serve] core = native", read_bytes did not grow, and the process
# held DIRECTORY fds deep inside the cwd tree.
#
# THE CAUSE (measured on avell, these are this file s numbers): the graph scheduler registered a
# recursive OS watch on the node s cwd on the boot path (rust/wa-host/src/main.rs ->
# graph::watch_configured -> Scheduler::entry -> notify Recursive). notify adds ONE inotify watch per
# directory, synchronously, on the caller s thread. With a synthetic 220,201-directory cwd the node
# before the fix held 220,201 inotify watches and answered in 1,384-4,912 ms; with WA_GRAPH_WATCH=0
# (no registration) it answered in 257 ms. The walk, not the interpreter, is what a huge cwd costs -
# and on openclaw s /local that walk costs a minute.
#
# SO THERE ARE TWO ASSERTIONS, and the SECOND is the one a fast machine cannot fake:
#   1. a node started in a 200k-directory cwd answers /health in under 5 s;
#   2. it holds NO per-directory inotify watch for that tree (the boot walk is gone).
# A timing assertion alone does NOT discriminate: on this node s disk the node before the fix also
# answered inside 5 s (1.4 s over 220,201 directories). The watch count is the effect the fix removes,
# and it is what fails on the code before it.
#
# The other direction is checked too: the same binary on a SMALL cwd still registers its watch, so
# "zero watches" cannot be reached by breaking the watcher altogether.
#
# Hermetic: a scratch HOME (scripts/lib/scratch-home.sh), a scratch tree under the system temp dir, no
# rendezvous, no relay, no mesh, no live fleet. Both nodes are children of this test and are stopped by
# PID, never by name.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
case "$BIN" in /*) ;; *) BIN="$ROOT/$BIN" ;; esac
DIRS="${1:-200000}"
BUDGET_MS=5000

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf "  ok   %s\n" "$2"; else failed=$((failed + 1)); printf "  FAIL %s%s\n" "$2" "${3:+ ($3)}"; fi; }
skip() { printf "SKIP test-serve-cwd-boot: %s\n" "$*"; exit 0; }
die() { printf "test-serve-cwd-boot: %s\n" "$*" >&2; exit 2; }

[ -x "$BIN" ] || skip "no wa binary at $BIN (build rust/wa-host, or set WA_BIN)"
command -v curl >/dev/null 2>&1 || skip "curl is needed to poll /health"
command -v python3 >/dev/null 2>&1 || skip "python3 builds the 200k-directory tree"
case "$DIRS" in ""|*[!0-9]*) die "the directory count must be a number, not $DIRS" ;; esac
[ "$DIRS" -ge 1 ] || die "the directory count must be at least 1"

. "$ROOT/scripts/lib/scratch-home.sh"

# WHERE THE TREE GOES. Not every temp directory can hold this tree, and one that cannot fails the
# test for a reason that has nothing to do with the node. Measured 21/11: the default TMPDIR here is
# ~/.wasm-agent/tmp, INSIDE the operator store, which the scratch-home rule refuses; and /tmp is a
# 16 GB tmpfs whose inode table a 200k-directory tree exhausts ("no space left on device" while every
# byte of it is small). So a base qualifies only when the scratch-home rule accepts it AND it has room
# in BOTH senses: 2 GiB of blocks and DIRS+5000 free inodes.
pick_scratch_base() {
  local cand resolved free_k free_i
  for cand in "${WA_SCRATCH_ROOT:-}" "${TMPDIR:-}" "${HOME:-}/.cache" /tmp "$ROOT/../.wa-scratch"; do
    [ -n "$cand" ] || continue
    mkdir -p "$cand" 2>/dev/null || continue
    resolved="$(cd "$cand" 2>/dev/null && pwd -P)" || continue
    wa_scratch_home_guard "$resolved/home" >/dev/null 2>&1 || continue
    free_k="$(df -Pk "$resolved" 2>/dev/null | awk 'NR==2{print $4}')"
    case "$free_k" in ""|*[!0-9]*) continue ;; esac
    [ "$free_k" -ge 2097152 ] || continue
    free_i="$(df -Pi "$resolved" 2>/dev/null | awk 'NR==2{print $4}')"
    case "$free_i" in ""|*[!0-9]*) continue ;; esac
    # 0 is "this filesystem reports no fixed inode table" (btrfs, xfs): not a full one. A tree the
    # filesystem truly cannot hold stops at the build below with its own error, named.
    [ "$free_i" -eq 0 ] || [ "$free_i" -ge $((DIRS + 5000)) ] || continue
    printf "%s\n" "$resolved"
    return 0
  done
  return 1
}
SCRATCH_BASE="$(pick_scratch_base)" || die "no scratch base outside the operator store with 2 GiB and $((DIRS + 5000)) free inodes (set WA_SCRATCH_ROOT)"
WORK="$(mktemp -d "$SCRATCH_BASE/wa-cwdboot-XXXXXX")" || die "no scratch directory under $SCRATCH_BASE"
NODE_PID=""; SMALL_PID=""
cleanup() {
  local status=$?
  # Only the PIDs this test started; wait so a locked database is never reported as a product failure.
  [ -n "$NODE_PID" ] && { kill "$NODE_PID" 2>/dev/null; wait "$NODE_PID" 2>/dev/null; }
  [ -n "$SMALL_PID" ] && { kill "$SMALL_PID" 2>/dev/null; wait "$SMALL_PID" 2>/dev/null; }
  if [ "$status" = "0" ] && [ "$failed" = "0" ]; then
    # 200k directories take a few seconds to unlink. That is done here, synchronously and bounded,
    # never as a background job: a test that leaves a process behind holds the suite lock (measured
    # 20/11) and this node refuses background descendants outright.
    timeout 120 rm -rf -- "$WORK" 2>/dev/null || printf "  scratch kept at %s (the removal ran out of time)\n" "$WORK" 
  else
    printf "  scratch kept at %s\n" "$WORK"
  fi
}
trap cleanup EXIT

wa_scratch_home_guard "$WORK/home" || exit 2
mkdir -p "$WORK/home" "$WORK/cwd/deep" || die "the scratch tree could not be made"

PORT=""
if command -v node >/dev/null 2>&1 && [ -f "$ROOT/scripts/free-test-port-block.cjs" ]; then
  PORT="$(node "$ROOT/scripts/free-test-port-block.cjs" 2>/dev/null)" || PORT=""
fi
if [ -z "$PORT" ]; then PORT=$((20000 + ($$ % 20000))); fi

printf "building a %s-directory cwd under %s\n" "$DIRS" "$WORK/cwd/deep"
PYOUT="$(python3 - "$WORK/cwd/deep" "$DIRS" <<'PY'
import os, sys
root, want = sys.argv[1], int(sys.argv[2])
made = 0
for a in range(0, 100000):
    for b in range(0, 100000):
        if made >= want:
            print(made); raise SystemExit(0)
        os.makedirs(os.path.join(root, "a%d" % a, "b%d" % b), exist_ok=True)
        made += 1
print(made)
PY
)" || die "the deep tree could not be built"
built=$(find "$WORK/cwd/deep" -type d | wc -l)
[ "$built" -ge "$DIRS" ] || die "the deep tree has $built directories, wanted $DIRS"
printf "built %s directories\n" "$built"

# One node run: answer time, and the inotify watches held at the instant it answered.
run_node() { # <cwd> <port> <log> -> ANSWER_MS WATCHES
  local cwd=$1 port=$2 log=$3 pid elapsed start_ms fd line
  ANSWER_MS=none; WATCHES=0
  (
    cd "$cwd" || exit 9
    # exec, so the PID below is the node itself and /proc/<pid>/fdinfo is its real set.
    exec env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY -u WA_MESH -u WA_MESH_COMPONENT \
      WASM_AGENT_MANAGED=0 WASM_AGENT_HOME="$WORK/home" \
      "$BIN" serve --port "$port" --client-port "$((port + 1))" --db "$WORK/home/serve.db"
  ) > "$log" 2>&1 &
  pid=$!
  start_ms=$(date +%s%N)
  while :; do
    elapsed=$(( ($(date +%s%N) - start_ms) / 1000000 ))
    [ "$elapsed" -ge "$BUDGET_MS" ] && break
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ANSWER_MS=$elapsed; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  # grep -c, not a bash read loop: a node that DID walk the tree holds one inotify line per
  # directory, and reading 200k lines one at a time in the shell took longer than the node (measured:
  # the base binary answered in seconds and the counter was still going 20 minutes later).
  WATCHES="$(grep -c '^inotify ' /proc/"$pid"/fdinfo/* 2>/dev/null | awk -F: '{n += $2} END {print n + 0}')"
  case "$WATCHES" in ""|*[!0-9]*) WATCHES=0 ;; esac
  NODE_PID=$pid
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  NODE_PID=""
}

# ---- 1. the huge cwd ---------------------------------------------------------------------------
run_node "$WORK/cwd/deep" "$PORT" "$WORK/deep.log"
if [ "$ANSWER_MS" != none ]; then
  ok 1 "a node started in a ${built}-directory cwd answers /health"
  [ "$ANSWER_MS" -lt "$BUDGET_MS" ] && ok 1 "it answers in under ${BUDGET_MS}ms" || ok 0 "it answers in under ${BUDGET_MS}ms" "took ${ANSWER_MS}ms"
else
  ok 0 "a node started in a ${built}-directory cwd answers /health" "no answer in ${BUDGET_MS}ms; log: $(tail -3 "$WORK/deep.log" | tr "\n" " ")"
fi
# THE discriminator. One inotify watch per directory is exactly the cost that held openclaw for a
# minute (measured 220,201 there), and it is present on the code before this fix on any machine.
[ "$WATCHES" -eq 0 ] && ok 1 "boot holds no per-directory inotify watch for the huge cwd" || ok 0 "boot holds no per-directory inotify watch for the huge cwd" "$WATCHES watch descriptors: the recursive watch walk is back on the boot path"
grep -q "graph_watch_skipped" "$WORK/deep.log" && ok 1 "the node names why that root runs unwatched" || ok 0 "the node names why that root runs unwatched" "no graph_watch_skipped line in the log"

# ---- 2. the same binary still watches a small tree ---------------------------------------------
mkdir -p "$WORK/small"
printf "function small() return 1 end\n" > "$WORK/small/a.lua"
run_node "$WORK/small" "$((PORT + 5000))" "$WORK/small.log"
[ "$WATCHES" -ge 1 ] && ok 1 "a small root still gets its OS watch ($WATCHES)" || ok 0 "a small root still gets its OS watch" "0 watch descriptors: registration itself is broken"

printf "test-serve-cwd-boot: %s checks, %s failed\n" "$checks" "$failed"
[ "$failed" = "0" ] || exit 1
printf "serve cwd boot ok\n"
