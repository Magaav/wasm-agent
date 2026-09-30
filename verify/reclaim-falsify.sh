#!/usr/bin/env bash
# Independent reviewer harness for D2's reclaim pass: what does it expire, and on what rule?
# Everything happens in temp roots of this harness's own, and the session store is a scratch path with no
# rows, so the rust/target half refuses every candidate and cannot touch anyone's worktree.
# Usage: bash verify/reclaim-falsify.sh <tree> <workdir>
set -uo pipefail
tree="${1:?usage: reclaim-falsify.sh <tree> <workdir>}"
work="${2:?usage: reclaim-falsify.sh <tree> <workdir>}"
rm -rf "$work"; mkdir -p "$work/temp" "$work/state"
temp="$work/temp"

mk() { # name, age-minutes
  local d="$temp/$1"; mkdir -p "$d/child"; printf 'x' > "$d/child/f"; printf 'y' > "$d/$1.marker"
  [ "${2:-0}" != 0 ] && touch -d "-$2 minutes" "$d" 2>/dev/null
  printf '%s' "$d"
}
# a real tracked-script family (the check names it), aged past the default 6 h, held OPEN by a live process
live_family=$(mk wa-subagent-test-Aged01 420)
node -e 'const fs=require("fs");const p=process.argv[1]+"/held.open";const h=fs.openSync(p,"w");fs.writeSync(h,"held by a live process\n");setTimeout(()=>{try{fs.closeSync(h)}catch{};process.exit(0)},60000);' "$live_family" &
livepid=$!
sleep 1
unknown=$(mk wa-not-a-tracked-family-SomeId 420)
clone=$(mk wa-merge-lane-Aged01 420)
home=$(mk wa-gate-home-Aged01 420)
sentinel=$(mk wa-sentinel-Aged01 420)
fresh=$(mk wa-subagent-test-Fresh1 10)
older=$(mk wa-subagent-test-Aged02 900)

echo "fixtures in $temp (age 420 min unless noted):"
printf '  %-34s %s\n' "wa-subagent-test-Aged01" "7 h, HELD OPEN by pid $livepid (a live process)"
printf '  %-34s %s\n' "wa-subagent-test-Aged02" "15 h, untouched"
printf '  %-34s %s\n' "unknown-family-SomeId" "7 h, not a family any script mints"
printf '  %-34s %s\n' "wa-merge-lane-Aged01" "7 h, D1's family"
printf '  %-34s %s\n' "wa-gate-home-Aged01" "7 h, D1's family"
printf '  %-34s %s\n' "wa-sentinel-Aged01" "7 h, never-expire rule"
printf '  %-34s %s\n' "wa-subagent-test-Fresh1" "10 min, fresh"

echo
echo "== report (nothing is removed) =="
timeout 300 node "$tree/scripts/reclaim-disk.mjs" --repo "$tree" --temp-dir "$temp" --state-dir "$work/state" \
  --db "$work/state/missing.db" 2>&1 | sed -n '1,40p'
echo "exit=$?"

echo
echo "== apply (the scratch temp root is the only thing it can reach) =="
timeout 300 node "$tree/scripts/reclaim-disk.mjs" --repo "$tree" --temp-dir "$temp" --state-dir "$work/state" \
  --db "$work/state/missing.db" --apply 2>&1 | sed -n '5,28p'
echo "exit=$?"
echo
echo "what is left in the temp root:"
for d in "$live_family" "$unknown" "$clone" "$home" "$sentinel" "$fresh" "$older"; do
  printf '  %-34s %s\n' "$(basename "$d")" "$([ -d "$d" ] && echo 'LEFT' || echo 'REMOVED')"
done
kill "$livepid" 2>/dev/null
