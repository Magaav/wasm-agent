#!/usr/bin/env bash
# Independent reviewer harness: force the disk floor to refuse (floor raised above the real free space,
# in a COPY of the delivered tree - the delivered file is never edited), then show
#   (a) the named refusal and the exit code of the real gate,
#   (b) that it is the gate's FIRST act and nothing is built or retried,
#   (c) what the merge lane (c78ab731) makes of that gate: verdict, exit, retained clone.
# Usage: bash verify/refusal-chain.sh <tree-with-both-deliveries> <workdir>
set -uo pipefail
tree="${1:?usage: refusal-chain.sh <tree> <workdir>}"
work="${2:?usage: refusal-chain.sh <tree> <workdir>}"
rm -rf "$work"; mkdir -p "$work/temp" "$work/repo/scripts"
export TMPDIR="$work/temp" TMP="$work/temp" TEMP="$work/temp"
gate="$work/repo"; lane="$tree/scripts/merge-lane.mjs"

printf '== the delivered files are only ever COPIED: hashes ==\n'
sha256sum "$tree/scripts/check-disk-floor.sh" "$tree/scripts/test.sh"

cp "$tree/scripts/check-disk-floor.sh" "$tree/scripts/test.sh" "$gate/scripts/"
# The one deliberate way past the floor is --floor-bytes; for the gate path the floor is this file's
# constant, so the copy's constant is raised above the real free space (~70 GiB -> 1 TiB).
sed -i 's/^FLOOR_BYTES=3987386368$/FLOOR_BYTES=1099511627776/' "$gate/scripts/check-disk-floor.sh"
grep -n '^FLOOR_BYTES=' "$gate/scripts/check-disk-floor.sh"
df -Pk "$work" | tail -1

(cd "$gate" && git init -q --initial-branch=main . && git -c user.email=f@x -c user.name=f add -A \
  && git -c user.email=f@x -c user.name=f commit -q -m base \
  && git -c user.email=f@x -c user.name=f switch -q -c change/one \
  && echo one > change.txt && git -c user.email=f@x -c user.name=f add -A \
  && git -c user.email=f@x -c user.name=f commit -q -m one \
  && git -c user.email=f@x -c user.name=f switch -q main)

printf '\n== (a) the gate, first act, with the floor above the real free space ==\n'
start=$(date +%s%N)
( cd "$gate" && timeout 300 bash scripts/test.sh ) >"$work/gate.out" 2>"$work/gate.err"; rc=$?
end=$(date +%s%N)
printf 'exit code: %s   elapsed: %s ms\n' "$rc" "$(( (end - start) / 1000000 ))"
printf 'gate stdout (first 4 lines):\n'; sed -n '1,4p' "$work/gate.out" | sed 's/^/    /'
printf 'gate stderr (the refusal):\n'; sed -n '1,4p' "$work/gate.err" | sed 's/^/    /'
printf 'refusal lines on stderr: %s (one refusal, not a retry loop)\n' "$(grep -c 'refused to start' "$work/gate.err")"
printf 'cargo/build started? %s\n' "$(grep -c 'cargo' "$work/gate.out" "$work/gate.err" | paste -sd, -)"
printf 'gate homes left behind: %s\n' "$(ls "$work/temp" 2>/dev/null | wc -l)"
printf 'last line of the gate output: %s\n' "$(tail -n 1 "$work/gate.out")"

printf '\n== (b) is the refusal distinguishable from a red gate? ==\n'
printf 'the gate'"'"'s own normal failure exit (a failing test) is also 1, so the exit code alone does not tell them apart:\n'
printf '  grep in scripts/test.sh for the exits the gate uses:\n'
grep -n '^\s*exit [0-9]' "$tree/scripts/test.sh" | head -6 | sed 's/^/    /'

printf '\n== (c) what the merge lane (c78ab731) makes of a gate that refused ==\n'
( cd "$gate" && timeout 600 node "$lane" --repo "$gate" --base main --gate-command 'bash scripts/test.sh' \
    --json "$work/lane.json" change/one ) >"$work/lane.out" 2>"$work/lane.err"; lrc=$?
node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
console.log("  lane exit:                "+process.argv[2]);
console.log("  verdict:                  "+j.verdict+" (exit_code "+j.exit_code+")");
console.log("  gate:                     exit="+j.gate.exit+" ("+(j.gate.detail||"no detail")+")");
console.log("  clone retained:           "+(j.clone.removed===true?"no, removed":"yes, kept"));
console.log("  clone at:                 "+j.clone.path);
console.log("  retention sweeps:         "+JSON.stringify((j.retention.sweeps||[]).map(s=>({keep:s.keep,removed:s.removed.length,kept:s.kept.length,live:s.live.length}))));
console.log("  last line of gate output: "+JSON.stringify((j.gate.log_last_line||j.gate.last_line||"(the lane records the log path: "+j.gate.log+")")));
' "$work/lane.json" "$lrc"
printf 'lane stderr (tail):\n'; tail -3 "$work/lane.err" | sed 's/^/    /'
printf '\nfree space now: %s\n' "$(df -Pk "$work" | tail -1)"
printf 'delivered files unchanged: '; sha256sum -c <<<"$(sha256sum "$tree/scripts/check-disk-floor.sh" | sed 's| .*| '"$(echo $tree | sed 's|/|\\/|g')"'/scripts/check-disk-floor.sh|')" 2>/dev/null || true
sha256sum "$tree/scripts/check-disk-floor.sh" "$tree/scripts/test.sh"
