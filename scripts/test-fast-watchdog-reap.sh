#!/usr/bin/env bash
# A ROW THAT EXITS CLEANLY STILL HAS ITS CHILDREN RECLAIMED (item 0, the 19/11 OOM, growth C).
#
# MEASURED on this node at --jobs 2: the fast path reached 1,234 live wa processes and ~31 GB of RSS at
# row 45. The sampler named the parent of one: a run_lua child for scripts/test-session-vars.lua, a row
# that had already printed ok. Each such row alone peaked at 63 MB, so the crowd was not one big row: it
# was what nobody reclaimed. The watchdog killed a row's process group only when the row HUNG; a row that
# finished left every background child it had forked running, and the next row added more.
#
# This row proves the sweep: a row runs through the real watchdog, exits 0, and leaves a child alive in its
# group. That child must be gone afterwards, the sweep must say how many it killed, and a row that leaves
# nothing must print nothing.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
# THIS TEST OWNS ITS DIRECTORY AND NEVER DELETES THE ROOT IT WAS GIVEN (review item 2).
. scripts/lib/scratch-home.sh
# The shared scratch root, never the repo's parent: a land tree lives INSIDE the operator store
# (~/.wasm-agent/land/<id>/tree), and its parent is refused as the real node (gate 20/11, land65).
WA_ROOT="${WA_TEST_ROOT:-$(wa_scratch_root wa-fast-watchdog-reap)}" || exit 2
SCRATCH="$(wa_test_workdir "$WA_ROOT" test-fast-watchdog-reap)" || exit 2
mkdir -p "$SCRATCH/home" || exit 2
cleanup() { local s=$?; rm -rf "$SCRATCH"; exit $s; }
trap cleanup EXIT
wa_scratch_home_guard "$SCRATCH/home" || exit 2
. scripts/lib/fast-watchdog.sh
command -v wa_fast_watchdog >/dev/null 2>&1 || { echo 'test-fast-watchdog-reap: scripts/lib/fast-watchdog.sh defines no wa_fast_watchdog' >&2; exit 1; }

marker="$SCRATCH/child.pid"
row="$SCRATCH/row.sh"
cat > "$row" <<'ROW'
#!/usr/bin/env bash
sleep 300 &
printf '%s' "$!" > "$1"
exit 0
ROW
chmod +x "$row"

out="$(wa_fast_watchdog 30 reap-fixture -- "$row" "$marker" 2>&1)"
code=$?
[ "$code" = 0 ] || { echo "test-fast-watchdog-reap: a row that exits 0 came back $code: $out" >&2; exit 1; }
[ -f "$marker" ] || { echo 'test-fast-watchdog-reap: the fixture child never recorded a pid' >&2; exit 1; }
child="$(cat "$marker")"
[ -n "$child" ] || { echo 'test-fast-watchdog-reap: the fixture wrote an empty pid' >&2; exit 1; }

sleep 3
if kill -0 "$child" 2>/dev/null; then
  echo "test-fast-watchdog-reap: a child the finished row forked is STILL ALIVE (pid $child)" >&2
  echo '  that is the accumulation that reached 1,234 processes: each row adds one and nobody reclaims it' >&2
  kill -9 "$child" 2>/dev/null
  exit 1
fi
case "$out" in
  *process\(es\)\ in\ its\ group*) ;;
  *) echo "test-fast-watchdog-reap: the sweep killed the child but did not say so: $out" >&2; exit 1 ;;
esac

quiet="$SCRATCH/quiet.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$quiet"
chmod +x "$quiet"
clean_out="$(wa_fast_watchdog 30 quiet-fixture -- "$quiet" 2>&1)"
case "$clean_out" in
  *in\ its\ group*) echo "test-fast-watchdog-reap: a row that left nothing still printed the sweep line: $clean_out" >&2; exit 1 ;;
esac

echo 'test-fast-watchdog-reap: ok (a row that exits 0 leaves no child behind, the sweep names how many it killed, and a row that leaves nothing prints nothing)'
