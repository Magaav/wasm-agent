set -euo pipefail
gate_home_release() { echo "      [gate_home_release RAN]"; exit "$1"; }
trap 'gate_home_release $?' EXIT
echo "  (main line 153: trap gate_home_release EXIT)"
echo "  (main line 277/287: trap rm -f DB ... EXIT is set next)"
trap 'echo "      [the rm -f DB trap RAN - this is main own later trap]"; exit "$?"' EXIT
echo "  (now a failure AFTER the second trap, as a passing/cli-region exit is)"
false
