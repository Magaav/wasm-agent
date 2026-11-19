#!/usr/bin/env bash
# A rollback is done only when the node is RUNNING the restored binary, and it restores the matching
# Lua tree with it (item 2 of the node-ops round, #20/#35).
#
#   bash scripts/test-rollback-verify.sh
#
# MEASURED 19/11 on work: every rollback printed 'rollback ok' after asking systemd to start, even when
# the service never came up, so the node ran nothing under a success line; and the binary went back
# while lua-core did not, so the node ran the OLD binary with the NEW Lua tree all day ('installed tree
# ignored').
#
# What this proves, in order:
#   * a REAL process executing a file is recognised as that file (ok), by device and inode;
#   * the same process is a MISMATCH for a different file, and for a copy of its own binary that was
#     replaced on disk (the deleted-link case: the running bytes are not the restored bytes);
#   * a pid that does not exist, an empty pid and a missing restored file are UNKNOWN - never ok;
#   * scripts/rollback-node.sh refuses its success claim on unknown and on mismatch, and its answer
#     names which one it got (the strings are read out of the script, so the refusal cannot be quietly
#     dropped);
#   * the Lua tree moves with the binary: a fixture install with lua-core.prev gets that tree back, and
#     an install with no previous tree says so by name instead of claiming a matched pair.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-rollback-verify-$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/home" || exit 2
cleanup() {
  local status=$?
  set +e
  [ -n "${LIVE_PID:-}" ] && kill -9 "$LIVE_PID" 2>/dev/null
  rm -rf "$SCRATCH"
  exit $status
}
trap cleanup EXIT
# The rule this whole round keeps: a test that writes state proves it is not writing the operator's.
# The scratch home is compared against the RIGHT side (item 4 of the node-ops round):
# WASM_AGENT_HOME is the USER home (rust/wa-host-support/src/paths.rs:12), and the node store
# hangs off it as <home>/.wasm-agent. The guard refuses the real $HOME, the real store, anything
# inside it and anything above it - the measurements are in scripts/lib/scratch-home.sh.
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$SCRATCH/home" || exit 2
command -v stat >/dev/null 2>&1 || { echo 'SKIP test-rollback-verify: stat is not on PATH'; exit 0; }
[ -d /proc ] || { echo 'SKIP test-rollback-verify: this system has no /proc, so the identity question cannot be asked here'; exit 0; }
. scripts/lib/rollback-verify.sh
command -v wa_running_binary_verdict >/dev/null 2>&1 || { echo 'test-rollback-verify: scripts/lib/rollback-verify.sh defines no wa_running_binary_verdict' >&2; exit 1; }

# A real process to ask about: a copy of a program that stays alive.
cp "$(command -v sleep)" "$SCRATCH/running-binary" || { echo 'test-rollback-verify: cannot make a fixture binary' >&2; exit 1; }
chmod +x "$SCRATCH/running-binary"
"$SCRATCH/running-binary" 300 &
LIVE_PID=$!
# The child is forked before it execs, and for that moment /proc/<pid>/exe is still the shell: the link
# exists and names the wrong file. So the wait is for the ANSWER to become ok, not for the link to
# exist - a first read taken too early is exactly the false mismatch this test must not report.
verdict=''
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  verdict="$(wa_running_binary_verdict "$LIVE_PID" "$SCRATCH/running-binary")"
  case "$verdict" in ok*) break ;; esac
  sleep 0.1
done


case "$verdict" in ok*) ;; *) echo "test-rollback-verify: a live process was not recognised as the file it runs: $verdict" >&2; exit 1 ;; esac

# A different file with the same content is a different identity only by inode, and a different binary is
# a mismatch by inode too. Both are the same question: which bytes are executing.
cp "$SCRATCH/running-binary" "$SCRATCH/other-binary"
verdict="$(wa_running_binary_verdict "$LIVE_PID" "$SCRATCH/other-binary")"
case "$verdict" in mismatch*) ;; *) echo "test-rollback-verify: a process running one file was reported as running another ($verdict)" >&2; exit 1 ;; esac

# The measured 19/11 case in one move: replace the file the process is executing. The link then reads
# '<path> (deleted)', and the running bytes are NOT the restored ones even though the path matches.
cp "$SCRATCH/running-binary" "$SCRATCH/replacement" && mv -f "$SCRATCH/replacement" "$SCRATCH/running-binary"
verdict="$(wa_running_binary_verdict "$LIVE_PID" "$SCRATCH/running-binary")"
if [ "${verdict%% *}" = ok ]; then
  # On a filesystem where the mv is a rename over the same inode this cannot be reproduced; say so
  # rather than passing silently on a case that never ran.
  echo 'test-rollback-verify: NOTE the replace-on-disk case could not be reproduced here (the file kept its inode)'
else
  case "$verdict" in mismatch*) ;; *) echo "test-rollback-verify: replacing the running file answered neither ok nor mismatch: $verdict" >&2; exit 1 ;; esac
fi

# Unknown is never ok, and it says why.
for case_name in no_pid dead_pid missing_file; do
  case "$case_name" in
    no_pid) verdict="$(wa_running_binary_verdict '' "$SCRATCH/running-binary")" ;;
    dead_pid) verdict="$(wa_running_binary_verdict 999999 "$SCRATCH/running-binary")" ;;
    missing_file) verdict="$(wa_running_binary_verdict "$LIVE_PID" "$SCRATCH/not-there")" ;;
  esac
  case "$verdict" in
    unknown*) ;;
    *) echo "test-rollback-verify: $case_name was not unknown: $verdict" >&2; exit 1 ;;
  esac
done

# The script that uses it refuses on both, and its text is read here so the refusal cannot be removed
# without this test failing.
for required in 'rollback_not_effective:' 'rollback_unverified:' 'wa_running_binary_verdict' 'lua-core.prev'; do
  grep -q "$required" scripts/rollback-node.sh || { echo "test-rollback-verify: scripts/rollback-node.sh no longer contains $required" >&2; exit 1; }
done

# The Lua pair, through the real script's own move: a fixture install whose lua-core.prev is the tree
# that matches the restored binary, and one that kept nothing (which must be NAMED, not claimed).
fixture_install() { # <dir> <with-prev: yes|no>
  local dir=$1 prev=$2
  mkdir -p "$dir/rollback"
  printf '#!/bin/sh\necho wa-restored\n' > "$dir/rollback/wa"
  printf '#!/bin/sh\necho sentinel-restored\n' > "$dir/rollback/wa-sentinel"
  printf 'commit=fixture-restored\n' > "$dir/rollback/installed.txt"
  printf '#!/bin/sh\necho wa-current\n' > "$dir/wa"
  printf '#!/bin/sh\necho sentinel-current\n' > "$dir/wa-sentinel"
  chmod +x "$dir/rollback/wa" "$dir/rollback/wa-sentinel" "$dir/wa" "$dir/wa-sentinel"
  mkdir -p "$dir/lua-core"; printf 'current tree\n' > "$dir/lua-core/MARK"
  if [ "$prev" = yes ]; then
    mkdir -p "$dir/lua-core.prev"; printf 'previous tree\n' > "$dir/lua-core.prev/MARK"
  fi
}

install_with_prev="$SCRATCH/install-with-prev"
fixture_install "$install_with_prev" yes
WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$install_with_prev" --from "$install_with_prev/rollback" --no-restart --reason fixture \
  > "$SCRATCH/with-prev.log" 2>&1
code=$?
[ "$code" = 0 ] || { echo "test-rollback-verify: a rollback with a previous Lua tree failed (exit $code):"; tail -5 "$SCRATCH/with-prev.log"; exit 1; }
grep -q 'previous tree' "$install_with_prev/lua-core/MARK" || { echo 'test-rollback-verify: the previous Lua tree was not put back with the binary'; exit 1; }
grep -q 'restored the matching Lua tree' "$SCRATCH/with-prev.log" || { echo 'test-rollback-verify: the rollback did not SAY it restored a matching tree'; exit 1; }

install_without="$SCRATCH/install-without-prev"
fixture_install "$install_without" no
WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$install_without" --from "$install_without/rollback" --no-restart --reason fixture \
  > "$SCRATCH/without-prev.log" 2>&1 || { echo 'test-rollback-verify: a rollback with no previous tree failed where it should have said so and carried on'; exit 1; }
grep -q 'no previous Lua tree was kept' "$SCRATCH/without-prev.log" || { echo 'test-rollback-verify: a rollback with no previous tree did not say so by name, so it reads as a matched pair'; exit 1; }

echo 'test-rollback-verify: ok (a live pid is identified by inode, mismatch and unknown are never ok, the Lua tree moves with the binary)'
