#!/usr/bin/env bash
# Claim 2(b) and attack 3: does an in-place `cp -f` over a running script lose the rest of
# it, and does the real `ship_file()` (staged + rename) survive the same shapes?
# Run from the repository root:  bash review/deploy-unbound/probe-self-ship.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$ROOT" || exit 1
awk '/^ship_file\(\) \{/{on=1} on{print} on && /^\}$/{exit}' scripts/deploy.sh > "$W/helper.sh"
cat > "$W/common.sh" <<EOF
set -uo pipefail
fail() { echo "REFUSED: \$*" >&2; exit 3; }
. "$W/helper.sh"
EOF
grep -q 'mv -f' "$W/helper.sh" || { echo "the helper no longer renames - re-read the fix"; exit 1; }

echo "===== (1) size sweep: a victim that replaces itself, then has more of itself to run ====="
{ echo '#!/usr/bin/env bash'; echo 'echo THE-SHIPPED-REPLACEMENT'
  for i in $(seq 1 60); do echo "# replacement padding $i"; done; } > "$W/new.sh"
mk_victim() { # n, strategy, path
  local n="$1" s="$2" p="$3" i
  { echo '#!/usr/bin/env bash'; echo 'set -uo pipefail'; echo "SELF=\"$p\""
    [ "$s" = ship ] && cat "$W/helper.sh"
    echo 'echo "before the self-ship"'
    for i in $(seq 1 "$n"); do echo "# filler before $i"; done
    if [ "$s" = cp ]; then echo 'cp -f "$NEW" "$SELF"'; else echo 'ship_file "$NEW" "$SELF" "this script"'; fi
    for i in $(seq 1 "$n"); do echo "# filler after $i"; done
    echo 'echo "T1 after the self-ship"'
    echo 'x="a token the parser must still reach (with a paren)"'
    echo 'echo "T2 the final line ran"'; } > "$p"
}
cp -f "$W/new.sh" "$W/new-bytes"
for n in 5 20 40 100 400; do
  for s in cp ship; do
    p="$W/victim-$s-$n.sh"; mk_victim "$n" "$s" "$p"
    out="$(NEW="$W/new-bytes" bash "$p" 2>&1)"; st=$?
    printf 'n=%-4s %-5s status=%-3s T1=%s T2=%s  last=[%s]\n' "$n" "$s" "$st" \
      "$(printf '%s\n' "$out" | grep -c '^T1 after the self-ship$')" \
      "$(printf '%s\n' "$out" | grep -c '^T2 the final line ran$')" \
      "$(printf '%s\n' "$out" | tail -1 | cut -c1-90)"
  done
done

echo "===== (2) the real helper against the hard shapes ====="
printf '#!/usr/bin/env bash\necho NEW-AND-LONGER\nexit 0\n' > "$W/newsrc"
shape() { # label, setup-cmd
  echo "-- $1"
  mkdir -p "$W/s"; rm -f "$W"/s/*
}
shape "destination is the running script"
printf '#!/usr/bin/env bash\necho OLD\n' > "$W/s/deploy.sh"
{ . "$W/common.sh"; ship_file "$W/newsrc" "$W/s/deploy.sh" "deploy.sh beside the binary"
  echo "   -> ok; content=[$(tr '\n' '/' < "$W/s/deploy.sh")] residue=[$(ls -a "$W/s" | tr '\n' ' ')]"; } 2>&1 | sed 's/^/   /'
shape "source missing (a write that cannot happen before the rename)"
printf 'ORIGINAL\n' > "$W/s/target.sh"
{ . "$W/common.sh"; ship_file "$W/nope" "$W/s/target.sh" "target.sh"; echo "   -> REACHED THE END"; } 2>&1 | sed 's/^/   /'
echo "   -> destination=[$(cat "$W/s/target.sh" | tr -d '\n')] residue=[$(ls -a "$W/s" | tr '\n' ' ')]"
shape "rename target exists as a directory (contrived)"
printf 'ORIGINAL\n' > "$W/s/target.sh"
{ . "$W/common.sh"; mkdir -p "$W/s/target.sh.ship.$$"
  ship_file "$W/newsrc" "$W/s/target.sh" "target.sh"; echo "   -> REACHED THE END"; } 2>&1 | sed 's/^/   /'
echo "   -> destination=[$(cat "$W/s/target.sh" | tr -d '\n')] residue=[$(find "$W/s" -mindepth 1 | tr '\n' ' ')]"

echo "===== (3) killed between the staged write and the rename (300 MB source) ====="
mkdir -p "$W/k"; printf 'ORIGINAL\n' > "$W/k/target.sh"
head -c 300000000 /dev/zero > "$W/big" 2>/dev/null || dd if=/dev/zero of="$W/big" bs=1M count=300 2>/dev/null
{ . "$W/common.sh"; ship_file "$W/big" "$W/k/target.sh" "target.sh"; echo "SHIPPED"; } > "$W/k.out" 2>&1 & RPID=$!
for _ in $(seq 1 400); do ls "$W/k/target.sh.ship."* >/dev/null 2>&1 && break; sleep 0.01; done
kill -9 $RPID 2>/dev/null; wait $RPID 2>/dev/null
echo "   staged+rename: DESTINATION bytes=$(wc -c < "$W/k/target.sh") (was 9) residue=[$(ls -a "$W/k" | tr '\n' ' ')] staged bytes=$(wc -c < "$W/k/target.sh.ship."* 2>/dev/null | tr -d ' ')"
mkdir -p "$W/k2"; printf 'ORIGINAL\n' > "$W/k2/target.sh"
{ cp -f "$W/big" "$W/k2/target.sh"; } & RPID2=$!
for _ in $(seq 1 400); do [ "$(wc -c < "$W/k2/target.sh")" -gt 1000 ] && break; sleep 0.01; done
kill -9 $RPID2 2>/dev/null; wait $RPID2 2>/dev/null
echo "   old in-place cp: DESTINATION bytes=$(wc -c < "$W/k2/target.sh") of 300000000 -> $(cmp -s "$W/big" "$W/k2/target.sh" && echo COMPLETE || echo PARTIAL)"
