#!/usr/bin/env bash
# Is installed.txt the binary's own answer, on every install path that writes one?
#
# WHAT THIS EXISTS FOR. On 18/11 an installed.txt said commit=14963b6f while the node ran a binary built from
# 8 commits that were on no landed branch. The record was written by the party that MEANT to install, and every
# reader downstream believed it: a deploy compared itself against the belief, saw an ancestor, and replaced the
# node. So the rule is that installed.txt is written FROM \`wa --build-info\`, and the caller's commit is not an
# input. This test proves the writer behaves that way, and proves a real install path (rollback-node.sh) uses it.
#
# It needs no built node binary: a stub that answers --build-info is a binary as far as the writer is concerned,
# and the stub is what lets the test state a commit the checkout does not have.
#
# Usage:  bash scripts/test-install-record.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/install-record.sh"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not in '$(printf '%s' "$2" | head -3 | tr '\n' ' ')'" ;; esac; }
[ -f "$LIB" ] || { echo "test-install-record: missing $LIB" >&2; exit 1; }
. "$LIB"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A binary that answers --build-info. The commit is deliberately one the checkout does not have: that is the
# 18/11 shape, and the writer must record what the bytes say rather than correct it to HEAD.
STUB="$WORK/stub-wa"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
case "$1" in
  --build-info)
    printf 'version=9.9.9\ncommit=1111222233334444555566667777888899990000\ntree=aaaabbbbccccddddeeeeffff0000111122223333\ndirty=false\nsource=git\nbuilt_epoch=1795000000\nancestors=42\nancestors_complete=true\n' ;;
  --contains) [ "$2" = 1111222233334444555566667777888899990000 ] && exit 0; exit 1 ;;
  --version) echo 'wasm-agent 9.9.9' ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

echo "test-install-record: the writer"
INSTALL="$WORK/install"; mkdir -p "$INSTALL"
wa_record_install "$INSTALL" "$STUB" 'via=test' 'reason=fixture' 'commit=9999888877776666555544443333222211110000'
RECORD="$(cat "$INSTALL/installed.txt")"
same "commit is the binary's" "$(wa_build_field "$RECORD" commit)" "1111222233334444555566667777888899990000"
same "tree is the binary's" "$(wa_build_field "$RECORD" tree)" "aaaabbbbccccddddeeeeffff0000111122223333"
same "dirty is the binary's" "$(wa_build_field "$RECORD" dirty)" "false"
same "build_info says the binary answered" "$(wa_build_field "$RECORD" build_info)" "yes"
shows "a caller's commit= is dropped, and the drop is named" "$RECORD" "dropped_caller_field=commit"
case "$RECORD" in
  *"commit=9999888877776666555544443333222211110000"*) bad "the caller's commit reached the record" ;;
  *) ok "the caller's commit is nowhere in the record" ;;
esac
shows "the caller's other fields are kept" "$RECORD" "via=test"

echo "test-install-record: a binary that cannot answer"
DEAD="$WORK/dead-wa"
printf '#!/bin/sh\nexit 1\n' > "$DEAD"; chmod +x "$DEAD"
wa_record_install "$INSTALL" "$DEAD" 'via=test'
RECORD="$(cat "$INSTALL/installed.txt")"
same "commit is unknown, not a guess" "$(wa_build_field "$RECORD" commit)" "unknown"
same "and the record says the binary could not say" "$(wa_build_field "$RECORD" build_info)" "absent"

echo "test-install-record: a binary that does not know the flag does not hang the deploy"
SLOW="$WORK/slow-wa"
printf '#!/bin/sh\nsleep 30\n' > "$SLOW"; chmod +x "$SLOW"
started="$(date +%s)"
WA_BUILD_INFO_TIMEOUT=2 wa_build_info "$SLOW" >/dev/null 2>&1
spent=$(( $(date +%s) - started ))
if [ "$spent" -le 6 ]; then ok "the probe is bounded ($spent s on a binary that never answers)"; else bad "the probe ran $spent s: an old binary would hang an install"; fi

echo "test-install-record: the ancestry verdict"
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email test@example.com; git -C "$REPO" config user.name test
printf 'a\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm 'base: the first commit'
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'b\n' > "$REPO/g"; git -C "$REPO" add g; git -C "$REPO" commit -qm 'feature: the commit that would be lost'
NEWER="$(git -C "$REPO" rev-parse HEAD)"
wa_ancestry_verdict "$REPO" "$BASE" "$NEWER"; same "target is older than running -> 1 (a downgrade)" "$?" "1"
shows "and the commits that would be lost are listed" "$WA_ANCESTRY_LOST" "feature: the commit that would be lost"
same "the count is stated" "$WA_ANCESTRY_LOST_COUNT" "1"
wa_ancestry_verdict "$REPO" "$NEWER" "$BASE"; same "target contains running -> 0" "$?" "0"
wa_ancestry_verdict "$REPO" "$NEWER" "$NEWER"; same "target is the running commit -> 0" "$?" "0"
wa_ancestry_verdict "$REPO" "$NEWER" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; same "a commit this tree does not have -> 2" "$?" "2"
wa_ancestry_verdict "$REPO" "$NEWER" ""; same "no running commit -> 2 (a first install is not a downgrade)" "$?" "2"
wa_ancestry_verdict "" "" 1111222233334444555566667777888899990000 "$STUB"
same "a release install: the candidate binary answers for itself -> 0" "$?" "0"
wa_ancestry_verdict "" "" 9999888877776666555544443333222211110000 "$STUB"
same "a candidate that does not contain it -> 1" "$?" "1"

echo "test-install-record: every install path writes through this library"
for path in scripts/deploy.sh scripts/upgrade.sh scripts/fleet-install.sh scripts/linux/bootstrap.sh scripts/rollback-node.sh; do
  if grep -q 'wa_build_info\|wa_record_install' "$ROOT/$path"; then ok "$path asks the binary"; else bad "$path writes a record without asking the binary"; fi
done
if grep -qF 'record_commit="$COMMIT"' "$ROOT/scripts/deploy.sh"; then bad "deploy.sh still records the caller's commit"; else ok "deploy.sh does not record the caller's commit"; fi
if grep -qE 'commit="\$PREVIOUS_COMMIT"' "$ROOT/scripts/upgrade.sh"; then bad "upgrade.sh still records the previous record's commit"; else ok "upgrade.sh does not record a previous record's commit"; fi

echo "test-install-record: rollback-node.sh records the RESTORED binary's own answer"
RINSTALL="$WORK/rinstall"; mkdir -p "$RINSTALL/rollback" "$RINSTALL/scripts/lib"
cp "$LIB" "$RINSTALL/scripts/lib/install-record.sh"
cp "$STUB" "$RINSTALL/rollback/wa"; cp "$STUB" "$RINSTALL/rollback/wa-sentinel"
cp "$STUB" "$RINSTALL/wa"; cp "$STUB" "$RINSTALL/wa-sentinel"
printf 'commit=9999888877776666555544443333222211110000\nrelease=v0.0.1\nsource_provenance=clean-built-by-deploy\n' > "$RINSTALL/installed.txt"
printf 'commit=9999888877776666555544443333222211110000\nrelease=v0.0.1\nmanifest_sha256=feedface\n' > "$RINSTALL/rollback/installed.txt"
bash "$ROOT/scripts/rollback-node.sh" --install "$RINSTALL" --from "$RINSTALL/rollback" --reason "back to the working pair" --no-restart > "$WORK/rollback.log" 2>&1
rc=$?
same "rollback-node.sh restored and recorded -> 0" "$rc" "0"
RECORD="$(cat "$RINSTALL/installed.txt" 2>/dev/null)"
same "the restored binary's own commit is the record" "$(wa_build_field "$RECORD" commit)" "1111222233334444555566667777888899990000"
same "the replaced commit is named" "$(wa_build_field "$RECORD" rollback_of)" "9999888877776666555544443333222211110000"
shows "the reason is recorded" "$RECORD" "rollback_reason=back to the working pair"
shows "the older record's other fields are carried over" "$RECORD" "release=v0.0.1"

printf 'test-install-record: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
