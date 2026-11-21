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
pids=()
cleanup() {
  local status=$?
  set +e
  [ -n "${LIVE_PID:-}" ] && kill -9 "$LIVE_PID" 2>/dev/null
  # Every fixture this test started is killed AND WAITED FOR: a test that leaves a process behind has a
  # background descendant, and a supervised operation refuses that (measured: the first run of the restart
  # case was killed as background_descendants while a fixture was still alive).
  local one
  for one in ${pids[@]+"${pids[@]}"}; do
    [ -n "$one" ] && kill -9 "$one" 2>/dev/null
  done
  wait 2>/dev/null
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
  # A tree names itself through the manifest a deploy writes (scripts/lib/lua-tree.sh). The CURRENT tree
  # names commit=current, so a rollback that restores the previous tree and leaves THIS manifest beside it
  # is caught as rollback_lua_not_effective - the defect item 5 exists to end.
  printf 'source_commit=current\nlua_inputs=currentdigest\n' > "$dir/lua-core/manifest.txt"
  if [ "$prev" = yes ]; then
    mkdir -p "$dir/lua-core.prev"; printf 'previous tree\n' > "$dir/lua-core.prev/MARK"
    printf 'source_commit=previous\nlua_inputs=previousdigest\n' > "$dir/lua-core.prev/manifest.txt"
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
# The identity is checked, not just the directory: the log must name the RESTORED tree's own manifest.
grep -q 'the Lua tree is the restored one (source_commit previous' "$SCRATCH/with-prev.log" || { echo 'test-rollback-verify: the rollback did not verify the restored Lua tree identity'; tail -3 "$SCRATCH/with-prev.log"; exit 1; }
# The tree that was replaced is KEPT ASIDE, never deleted (item 5): a bad rollback must have a way forward.
aside="$(ls -d "$install_with_prev"/lua-core.rolled-back-* 2>/dev/null | head -1)"
if [ -z "$aside" ] || ! grep -q 'current tree' "$aside/MARK" 2>/dev/null; then
  echo 'test-rollback-verify: the tree that was replaced was NOT kept aside, so a bad rollback has no way forward'; exit 1
fi
# A LUA TREE THAT DOES NOT MATCH THE BINARY IS A REFUSAL, not a 'rollback ok'. This is the 19/11 shape:
# the binary is restored and the tree beside it is the new one.
install_mismatch="$SCRATCH/install-mismatch"
fixture_install "$install_mismatch" yes
# The restored tree claims one identity and the file that lands at lua-core claims another: restage the
# previous tree with a manifest that cannot match what the script will find after its own move.
printf 'source_commit=previous\nlua_inputs=previousdigest\n' > "$install_mismatch/lua-core.prev/manifest.txt"
rm -f "$install_mismatch/lua-core.prev/manifest.txt"
WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$install_mismatch" --from "$install_mismatch/rollback" --no-restart --reason fixture \
  > "$SCRATCH/mismatch.log" 2>&1
code=$?
[ "$code" = 5 ] || { echo "test-rollback-verify: a rollback whose restored tree names no source_commit exited $code, not 5: $(tail -2 "$SCRATCH/mismatch.log")"; exit 1; }
grep -q 'rollback_lua_unverified' "$SCRATCH/mismatch.log" || { echo 'test-rollback-verify: a tree that cannot name itself was not refused by name'; exit 1; }

install_without="$SCRATCH/install-without-prev"
fixture_install "$install_without" no
WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$install_without" --from "$install_without/rollback" --no-restart --reason fixture \
  > "$SCRATCH/without-prev.log" 2>&1 || { echo 'test-rollback-verify: a rollback with no previous tree failed where it should have said so and carried on'; exit 1; }
grep -q 'no previous Lua tree was kept' "$SCRATCH/without-prev.log" || { echo 'test-rollback-verify: a rollback with no previous tree did not say so by name, so it reads as a matched pair'; exit 1; }


# THE RESTART PATH, with a fake serve and a fake systemctl (item 5: the restart path is tested with a
# scratch unit or a fake serve; a scratch user unit cannot be started here - measured: the user manager
# does not read a per-call XDG_CONFIG_HOME and answers 'Unit wa-rbtest.service not found'). Nothing of the
# operator's is touched: PATH holds a systemctl that answers only the four calls this path makes, and the
# node is a copy of a real program whose argv says serve.
fakebin="$SCRATCH/fakebin"
mkdir -p "$fakebin"
fake_install="$SCRATCH/restart-install"
fake_marker="$SCRATCH/restart-marker"
cat > "$fakebin/systemctl" <<'FAKESYSTEMCTL'
#!/bin/sh
# Only what scripts/rollback-node.sh asks a supervisor. Every other call fails by name, so a new
# dependency on systemd shows up here instead of passing by accident.
FAKE_SCRATCH=$FAKE_SCRATCH
FAKE_INSTALL=$FAKE_INSTALL
FAKE_MARKER=$FAKE_MARKER
FAKE_UNIT=$FAKE_UNIT
FAKE_WRONG=$FAKE_WRONG
FAKE_RESTART_BROKEN=$FAKE_RESTART_BROKEN
case "$1" in
  --user)
    shift
    case "$1" in
      show-environment) exit 0 ;;
      list-units) printf '  %s loaded active running fake node\n' "$FAKE_UNIT"; exit 0 ;;
      show)
        pid="$(cat "$FAKE_SCRATCH/serve.pid" 2>/dev/null)"
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || pid=0
        printf '%s\n' "$pid"; exit 0 ;;
      restart)
        old="$(cat "$FAKE_SCRATCH/serve.pid" 2>/dev/null)"
        [ -z "$old" ] || kill "$old" 2>/dev/null
        sleep 0.2
        # A restart that starts something OTHER than the restored file is the measured defect: the
        # script would compare /proc/<pid>/exe with the file it just wrote and find another binary.
        start_from="$FAKE_INSTALL/wa"
        [ "${FAKE_RESTART_BROKEN:-0}" = 1 ] && start_from="$FAKE_WRONG"
        bash -c 'exec -a "wa serve" "$0" 60' "$start_from" >/dev/null 2>&1 &
        printf '%s' "$!" > "$FAKE_SCRATCH/serve.pid"
        printf 'start\n' >> "$FAKE_MARKER"
        exit 0 ;;
    esac ;;
esac
echo "fake systemctl: unsupported call: $*" >&2
exit 1
FAKESYSTEMCTL
chmod +x "$fakebin/systemctl"
mkdir -p "$fake_install/rollback" "$fake_install/lua-core"
printf 'source_commit=current\nlua_inputs=currentdigest\n' > "$fake_install/lua-core/manifest.txt"
cp "$(command -v sleep)" "$fake_install/rollback/wa"
printf '#!/bin/sh\necho sentinel\n' > "$fake_install/rollback/wa-sentinel"
cp "$(command -v sleep)" "$fake_install/wa"
printf '#!/bin/sh\necho sentinel-current\n' > "$fake_install/wa-sentinel"
chmod +x "$fake_install/rollback/wa" "$fake_install/rollback/wa-sentinel" "$fake_install/wa" "$fake_install/wa-sentinel"
# The node is ALREADY serving, from the current file: that is the state the defect verified without
# ever restarting it. The fake supervisor's 'show' reports whichever pid this file names.
FAKE_SCRATCH="$SCRATCH" FAKE_INSTALL="$fake_install" FAKE_MARKER="$fake_marker" bash -c 'exec -a "wa serve" "$0" 60' "$fake_install/wa" >/dev/null 2>&1 &
old_serve=$!
printf '%s' "$old_serve" > "$SCRATCH/serve.pid"
pids+=("$old_serve")
sleep 0.3
FAKE_UNIT=wa-fixture.service FAKE_SCRATCH="$SCRATCH" FAKE_INSTALL="$fake_install" FAKE_MARKER="$fake_marker" PATH="$fakebin:$PATH" \
  WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$fake_install" --from "$fake_install/rollback" --reason fixture \
  > "$SCRATCH/restart.log" 2>&1
code=$?
new_serve="$(cat "$SCRATCH/serve.pid" 2>/dev/null || true)"
[ -n "$new_serve" ] && pids+=("$new_serve")
[ "$code" = 0 ] || { echo "test-rollback-verify: a rollback over a serving node failed (exit $code):"; tail -5 "$SCRATCH/restart.log"; exit 1; }
# 1. The RESTART really happened: a new serving pid, not the old process (a 'start' on an already-active
#    unit is the defect item 5 names, and it would leave the same pid serving).
case "$new_serve" in
  ''|"$old_serve") echo "test-rollback-verify: the restart did not start a new serving process (old $old_serve, new ${new_serve:-none})"; exit 1 ;;
esac
[ "$(readlink -f "/proc/$new_serve/exe" 2>/dev/null)" = "$(readlink -f "$fake_install/wa")" ] \
  || { echo "test-rollback-verify: the new serving process does not execute the restored file"; exit 1; }
# 2. The process it VERIFIED is the serving one, executing the restored file.
grep -q 'runs the restored binary' "$SCRATCH/restart.log" \
  || { echo 'test-rollback-verify: the rollback did not confirm the restored binary through the serving process'; tail -5 "$SCRATCH/restart.log"; exit 1; }
# 3. A supervisor that reports a process executing something ELSE is a named refusal, never ok.
# A second install of the SAME program under the SAME NAME: 'wrong' here means 'not the file the rollback
# restored', not 'not a wa binary' - a node serving another copy of wa is exactly the 19/11 shape, and a
# fixture named anything else would be a process that is not a node at all (and correctly ignored).
mkdir -p "$SCRATCH/other-install"
cp -p "$fake_install/wa" "$SCRATCH/other-install/wa"
chmod +x "$SCRATCH/other-install/wa"
printf '%s' "$old_serve" > "$SCRATCH/serve.pid"
FAKE_SCRATCH="$SCRATCH" FAKE_INSTALL="$fake_install" FAKE_MARKER="$fake_marker" bash -c 'exec -a "wa serve" "$0" 60' "$SCRATCH/other-install/wa" >/dev/null 2>&1 &
wrong_serve=$!
pids+=("$wrong_serve")
sleep 0.3
printf '%s' "$wrong_serve" > "$SCRATCH/serve.pid"
FAKE_UNIT=wa-fixture.service FAKE_WRONG="$SCRATCH/other-install/wa" FAKE_RESTART_BROKEN=1 \
  FAKE_SCRATCH="$SCRATCH" FAKE_INSTALL="$fake_install" FAKE_MARKER="$fake_marker" PATH="$fakebin:$PATH" \
  WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$fake_install" --from "$fake_install/rollback" --reason fixture \
  > "$SCRATCH/restart-wrong.log" 2>&1
code=$?
kill "$wrong_serve" 2>/dev/null
[ "$code" = 5 ] || { echo "test-rollback-verify: a node serving a DIFFERENT binary exited $code, not 5: $(tail -2 "$SCRATCH/restart-wrong.log")"; exit 1; }
grep -q 'rollback_not_effective' "$SCRATCH/restart-wrong.log" \
  || { echo 'test-rollback-verify: a node serving the wrong binary was not refused by name'; exit 1; }
# 4. With no unit reporting a process, the answer is a refusal, not a success.
rm -f "$SCRATCH/serve.pid"
FAKE_UNIT=wa-fixture.service FAKE_SCRATCH="$SCRATCH" FAKE_INSTALL="$fake_install" FAKE_MARKER="$fake_marker" PATH="$fakebin:$PATH" \
  WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$fake_install" --from "$fake_install/rollback" --reason fixture \
  > "$SCRATCH/restart-none.log" 2>&1
code=$?
[ "$code" = 5 ] || { echo "test-rollback-verify: a rollback with no unit to restart exited $code, not 5: $(tail -2 "$SCRATCH/restart-none.log")"; exit 1; }
grep -q 'rollback_unverified' "$SCRATCH/restart-none.log" \
  || { echo 'test-rollback-verify: a rollback with no unit did not refuse by name'; exit 1; }
grep -q 'start' "$fake_marker" 2>/dev/null || { echo 'test-rollback-verify: the fake supervisor never recorded a restart, so this case proved nothing'; exit 1; }


# 5. THE SENTINEL-SUPERVISED NODE (item 1 of the node-ops round). MEASURED 19/11: the script stopped
#    wa-sentinel.service and THEN asked which unit serves; wa_node_units lists only a unit whose MainPID
#    is non-zero, so the unit it had just stopped was invisible, UNIT came back empty and the rollback
#    failed WITHOUT restarting anything - the node stayed down with its binary already replaced.
#    Here the serving unit is ACTIVE at the start and INVISIBLE once stopped (exactly what a stopped
#    sentinel looks like): the unit must be recorded BEFORE the stop and that same unit restarted.
#    The fake supervisor answers is-active and hides its pid after 'stop' until 'restart' brings it back.
printf 'active\n' > "$SCRATCH/unit-active"
cat > "$fakebin/systemctl" <<'FAKESENTINEL'
#!/bin/sh
# A supervisor whose unit is only visible while it is running: the shape that turned a stopped node
# into 'rollback_unverified' on 19/11.
FAKE_SCRATCH=$FAKE_SCRATCH
FAKE_INSTALL=$FAKE_INSTALL
FAKE_MARKER=$FAKE_MARKER
FAKE_UNIT=$FAKE_UNIT
case "$1" in
  --user)
    shift
    case "$1" in
      show-environment) exit 0 ;;
      list-units) printf '  %s loaded active running fake node\n' "$FAKE_UNIT"; exit 0 ;;
      is-active)
        shift; shift
        [ -f "$FAKE_SCRATCH/unit-active" ] && exit 0
        exit 3 ;;
      show)
        [ -f "$FAKE_SCRATCH/unit-active" ] || { printf '0\n'; exit 0; }
        pid="$(cat "$FAKE_SCRATCH/serve.pid" 2>/dev/null)"
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || pid=0
        printf '%s\n' "$pid"; exit 0 ;;
      stop)
        rm -f "$FAKE_SCRATCH/unit-active"
        old="$(cat "$FAKE_SCRATCH/serve.pid" 2>/dev/null)"
        [ -z "$old" ] || kill "$old" 2>/dev/null
        printf 'stop %s\n' "${2:-}" >> "$FAKE_MARKER"
        exit 0 ;;
      restart)
        old="$(cat "$FAKE_SCRATCH/serve.pid" 2>/dev/null)"
        [ -z "$old" ] || kill "$old" 2>/dev/null
        sleep 0.2
        bash -c 'exec -a "wa serve" "$0" 60' "$FAKE_INSTALL/wa" >/dev/null 2>&1 &
        printf '%s' "$!" > "$FAKE_SCRATCH/serve.pid"
        printf 'active\n' > "$FAKE_SCRATCH/unit-active"
        printf 'restart %s\n' "${2:-}" >> "$FAKE_MARKER"
        exit 0 ;;
    esac ;;
esac
echo "fake systemctl: unsupported call: $*" >&2
exit 1
FAKESENTINEL
chmod +x "$fakebin/systemctl"
rm -f "$fake_marker"
[ -f "$SCRATCH/serve.pid" ] && kill "$(cat "$SCRATCH/serve.pid")" 2>/dev/null; rm -f "$SCRATCH/serve.pid"
# The node is serving before the rollback, under the unit the supervisor names.
FAKE_SCRATCH="$SCRATCH" bash -c 'exec -a "wa serve" "$0" 60' "$fake_install/wa" >/dev/null 2>&1 &
sentinel_serve=$!
pids+=("$sentinel_serve")
printf '%s' "$sentinel_serve" > "$SCRATCH/serve.pid"
sleep 0.3
FAKE_UNIT=wa-fixture.service FAKE_SCRATCH="$SCRATCH" FAKE_INSTALL="$fake_install" FAKE_MARKER="$fake_marker" PATH="$fakebin:$PATH" \
  WA_INSTALL_RECORD_LIB="$ROOT/scripts/lib/install-record.sh" WA_ROLLBACK_VERIFY_LIB="$ROOT/scripts/lib/rollback-verify.sh" \
  bash scripts/rollback-node.sh --install "$fake_install" --from "$fake_install/rollback" --reason fixture \
  > "$SCRATCH/restart-sentinel.log" 2>&1
code=$?
new_sentinel_serve="$(cat "$SCRATCH/serve.pid" 2>/dev/null || true)"
[ -n "$new_sentinel_serve" ] && pids+=("$new_sentinel_serve")
# A node left down under a success-or-failure line is the defect; a node brought back under the SAME unit
# is the fix. Both halves are asserted: it really restarted, and it named the unit it had stopped.
# THE UNIT IS WHATEVER THE SUPERVISOR REPORTS (wa_node_units looks at wa-serve.service first, then
# wa-sentinel.service, then list-units), and the ONE fact this case is about is that the unit STOPPED is
# the unit RESTARTED. Read both names out of the marker and require them to be the same, non-empty name.
stopped_unit="$(sed -n 's/^stop //p' "$fake_marker" 2>/dev/null | head -1)"
restarted_unit="$(sed -n 's/^restart //p' "$fake_marker" 2>/dev/null | head -1)"
[ -n "$stopped_unit" ] \
  || { echo 'test-rollback-verify: the serving unit was never stopped, so the sentinel case proved nothing'; exit 1; }
[ "$stopped_unit" = "$restarted_unit" ] \
  || { echo "test-rollback-verify: the unit stopped ($stopped_unit) is NOT the unit restarted (${restarted_unit:-none}) - a node left down (the 19/11 defect)"; tail -4 "$SCRATCH/restart-sentinel.log"; exit 1; }
[ "$code" = 0 ] || { echo "test-rollback-verify: a rollback over an ACTIVE sentinel-supervised node failed (exit $code):"; tail -5 "$SCRATCH/restart-sentinel.log"; exit 1; }
case "$new_sentinel_serve" in
  ''|"$sentinel_serve") echo "test-rollback-verify: the sentinel-supervised node did not come back on a new pid (old $sentinel_serve, new ${new_sentinel_serve:-none})"; exit 1 ;;
esac
[ "$(readlink -f "/proc/$new_sentinel_serve/exe" 2>/dev/null)" = "$(readlink -f "$fake_install/wa")" ] \
  || { echo 'test-rollback-verify: the node the supervisor restarted does not execute the restored file'; exit 1; }

# 6. THE LAST LINE SAYS WHAT WAS PROVEN (item 2, report text 10). A run under --no-restart never read a
#    serving pid, and an install that kept no previous tree never compared a tree: neither may end
#    'rollback ok'. The line must be rollback_unverified and must NAME each unproven half.
last_without="$(tail -1 "$SCRATCH/without-prev.log")"
case "$last_without" in
  *rollback_unverified:*) ;;
  *) echo "test-rollback-verify: a --no-restart rollback with no previous tree ended '${last_without}', which reads as a verified rollback"; exit 1 ;;
esac
case "$last_without" in
  *binary_not_read_by_this_run*no_previous_lua_tree_was_kept*) ;;
  *) echo "test-rollback-verify: the unverified line does not name both unproven halves: $last_without"; exit 1 ;;
esac
last_prev="$(tail -1 "$SCRATCH/with-prev.log")"
case "$last_prev" in
  *rollback_unverified:*binary_not_read_by_this_run*) ;;
  *) echo "test-rollback-verify: a --no-restart rollback with a matched tree ended '${last_prev}', which claims the binary was verified when no pid was read"; exit 1 ;;
esac
case "$last_prev" in
  *no_previous_lua_tree_was_kept*) echo "test-rollback-verify: a rollback that DID restore a tree was reported as having kept none: $last_prev"; exit 1 ;;
esac

# The fake supervisor started the restored node in a subshell of its own; its pid is in serve.pid and it
# is reaped here, so this test leaves no process behind (a supervised operation refuses a run whose shell
# has a background descendant, measured while writing this case).
[ -f "$SCRATCH/serve.pid" ] && pids+=("$(cat "$SCRATCH/serve.pid" 2>/dev/null)")
echo 'test-rollback-verify: ok (a live pid is identified by inode, mismatch and unknown are never ok, the Lua tree moves with the binary, the replaced tree is kept aside, a tree that cannot name itself is refused, the restart path is exercised with a fake serve and a fake supervisor, a sentinel-supervised node is stopped and restarted as the SAME unit, and the last line says rollback ok only when the binary and the Lua tree were both verified)'
