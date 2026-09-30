set -euo pipefail
gate_home_release() { echo "      [gate_home_release RAN, exit $1]"; exit "$1"; }
trap 'gate_home_release $?' EXIT
echo "  (main's line 153 trap is set: trap gate_home_release EXIT)"
. "$1/scripts/lib/gate-phases.sh"
trap gate_phase_summary EXIT
echo "  (the delivery's line 162 trap is set: trap gate_phase_summary EXIT)"
gate_phase_begin build
echo "  (gate_phase_begin build called; now a command in the build phase fails)"
false
