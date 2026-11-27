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
# The complement: a string that must NOT be there. It was missing, and three assertions below called it anyway -
# bash printed `hides: command not found`, the checks did not run, and the run still said 0 failed. A test whose
# assertion is a missing command is a test that passes by not looking (found while wiring this file, round 4).
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }
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
wa_ancestry_verdict "$REPO" "$NEWER" ""; same "no running commit -> 2 (a first install is not a downgrade)" "$?" "2"

echo "test-install-record: a reused build - digest of compiled inputs, not a tree (incident 26/11 01:10Z)"
# Fable shape: the guard asks whether the SOURCE of the commit being installed contains the running commit, and
# whether the candidate binary IS that commit's build - answered by the digest of the COMPILED INPUTS (the same
# definition the build cache and the manifest use). Tree equality is only the named fallback: it cannot pass a
# scripts-only landing, which has a different tree and the same compiled inputs.
CIN="$WORK/cinputs"
mkdir -p "$CIN"
git -C "$CIN" init -q 2>/dev/null
git -C "$CIN" config user.email test@example.com; git -C "$CIN" config user.name test
mkdir -p "$CIN/rust/wa-host/src" "$CIN/scripts"
printf 'fn a() {}
' > "$CIN/rust/wa-host/src/a.rs"; printf 'echo one
' > "$CIN/scripts/x.sh"
git -C "$CIN" add -A; git -C "$CIN" commit -qm 'the compiled source a build was made from'
BUILT="$(git -C "$CIN" rev-parse HEAD)"
printf 'fn a() { two(); }
' > "$CIN/rust/wa-host/src/a.rs"
git -C "$CIN" add -A; git -C "$CIN" commit -qm 'a compiled change, later reverted'
RUNNING="$(git -C "$CIN" rev-parse HEAD)"
git -C "$CIN" revert --no-edit HEAD >/dev/null 2>&1
REVERT="$(git -C "$CIN" rev-parse HEAD)"
same 'the revert restores the built tree exactly' "$([ "$(git -C "$CIN" rev-parse "$REVERT^{tree}")" = "$(git -C "$CIN" rev-parse "$BUILT^{tree}")" ] && echo same || echo differs)" 'same'
same 'but its COMPILED INPUTS are the built commit ones' "$(wa_compiled_inputs_digest "$CIN" "$REVERT")" "$(wa_compiled_inputs_digest "$CIN" "$BUILT")"
wa_ancestry_verdict "$CIN" "$BUILT" "$RUNNING"
same 'revert to an old tree -> 0 (installs on the reused binary)' "$?" "0"
same 'and the verdict names the commit being installed (the revert)' "$WA_ANCESTRY_REUSED" "$REVERT"
shows 'the reason says the compiled inputs are that commit and it is a reused build' "$WA_ANCESTRY_WHY" 'reused build'

# A SCRIPTS-ONLY LANDING ON A REUSED BINARY: a different tree, the same compiled inputs - the case tree equality
# could never pass, and the reason the digest is the rule.
printf 'echo two
' > "$CIN/scripts/x.sh"
git -C "$CIN" add -A; git -C "$CIN" commit -qm 'scripts only: nothing compiled changed'
SCRIPTS_ONLY="$(git -C "$CIN" rev-parse HEAD)"
same 'the scripts-only tree differs from the built one' "$([ "$(git -C "$CIN" rev-parse "$SCRIPTS_ONLY^{tree}")" = "$(git -C "$CIN" rev-parse "$BUILT^{tree}")" ] && echo same || echo differs)" 'differs'
wa_ancestry_verdict "$CIN" "$BUILT" "$SCRIPTS_ONLY"
same 'a scripts-only landing on the reused binary -> 0 (installs)' "$?" "0"
same 'and it is restamped with the scripts-only commit' "$WA_ANCESTRY_REUSED" "$SCRIPTS_ONLY"

# THE LIVE SHAPE (26/11 05:29Z), which the earlier rows MISSED: the RUNNING binary answers that it CONTAINS the
# candidate stamp. That answer is correct, and it used to short-circuit the verdict to 1 BEFORE the reuse question
# was asked - so the landed rule never ran, and a deploy of 76906a27 (which contains the running 702e4342, and
# whose compiled inputs equal the stamp 7490fc56) was refused. The fixture reproduces the whole shape: a compiled
# change, then its revert (compiled inputs back to the stamp), and a running binary that says it contains the stamp.
LIVE="$WORK/live"
mkdir -p "$LIVE"
git -C "$LIVE" init -q 2>/dev/null
git -C "$LIVE" config user.email test@example.com; git -C "$LIVE" config user.name test
mkdir -p "$LIVE/rust/wa-host/src"
printf 'fn a() {}\n' > "$LIVE/rust/wa-host/src/a.rs"; git -C "$LIVE" add -A; git -C "$LIVE" commit -qm 'the compiled source the reused build was made from'
L_STAMP="$(git -C "$LIVE" rev-parse HEAD)"
printf 'fn a() { one(); }\n' > "$LIVE/rust/wa-host/src/a.rs"; git -C "$LIVE" add -A; git -C "$LIVE" commit -qm 'the commit the node is running'
L_RUNNING="$(git -C "$LIVE" rev-parse HEAD)"
git -C "$LIVE" revert --no-edit HEAD >/dev/null 2>&1
L_INSTALLING="$(git -C "$LIVE" rev-parse HEAD)"
same 'the live fixture: the commit being installed has the stamp compiled inputs' "$(wa_compiled_inputs_digest "$LIVE" "$L_INSTALLING")" "$(wa_compiled_inputs_digest "$LIVE" "$L_STAMP")"
RUNBIN="$LIVE/fake-running-wa"
printf '#!/bin/sh\ncase "$1" in --contains) exit 0 ;; esac\nexit 2\n' > "$RUNBIN"
chmod +x "$RUNBIN"
wa_ancestry_verdict "$LIVE" "$L_STAMP" "$L_RUNNING" "$RUNBIN" "$RUNBIN"
same 'the live shape: running contains the stamp, and it still installs' "$?" "0"
same 'and the verdict names the commit being installed, not the stamp' "$WA_ANCESTRY_REUSED" "$L_INSTALLING"
shows 'the reason says it is a reused build' "$WA_ANCESTRY_WHY" 'reused build'

# A TRULY OLDER COMMIT: the commit being installed does not contain what is running, whatever the digests say.
wa_ancestry_verdict "$CIN" "$BUILT" "$RUNNING" 2>/dev/null >/dev/null
wa_ancestry_verdict "$CIN" "$BUILT" "$RUNNING" >/dev/null 2>&1
OLDCASE="$WORK/older"
mkdir -p "$OLDCASE"
git -C "$OLDCASE" init -q 2>/dev/null
git -C "$OLDCASE" config user.email test@example.com; git -C "$OLDCASE" config user.name test
mkdir -p "$OLDCASE/rust/wa-host/src"
printf 'fn a() {}
' > "$OLDCASE/rust/wa-host/src/a.rs"; git -C "$OLDCASE" add -A; git -C "$OLDCASE" commit -qm base
O_BASE="$(git -C "$OLDCASE" rev-parse HEAD)"
printf 'fn b() {}
' > "$OLDCASE/rust/wa-host/src/b.rs"; git -C "$OLDCASE" add -A; git -C "$OLDCASE" commit -qm newer
O_NEW="$(git -C "$OLDCASE" rev-parse HEAD)"
# the tree being installed is the OLDER commit: it does not contain the running one, so a reused binary is no excuse
wa_ancestry_verdict "$OLDCASE" "$O_NEW" "$O_NEW" >/dev/null 2>&1; : "$?"
same 'a truly older commit is still refused' "$(wa_ancestry_verdict "$OLDCASE" "$O_BASE" "$O_NEW" >/dev/null 2>&1; echo $?)" '1'
same 'and nothing is restamped' "$WA_ANCESTRY_REUSED" ""

echo "test-install-record: a verdict from the CALLER environment is not inherited (Fable 26/11)"
# MEASURED SHAPE: WA_ANCESTRY_REUSED is this process answer about this candidate, written by wa_ancestry_verdict.
# An INHERITED value would restamp the record with a commit of the caller choice on any path where the verdict never
# ran. upgrade.sh clears it at the very top, before anything is sourced, and never exports it.
UPG="$ROOT/scripts/upgrade.sh"
unset_line=$(grep -n '^unset WA_ANCESTRY_REUSED WA_ANCESTRY_WHY' "$UPG" | head -1 | cut -d: -f1)
[ -n "$unset_line" ] && ok 'upgrade.sh clears the verdict' || bad 'upgrade.sh does not clear WA_ANCESTRY_REUSED'
first_source=$(grep -nE '^[[:space:]]*([.][[:space:]]|source[[:space:]])' "$UPG" | head -1 | cut -d: -f1)
if [ -n "$unset_line" ] && [ -n "$first_source" ] && [ "$unset_line" -lt "$first_source" ]; then
  ok 'and it does so BEFORE anything is sourced'
else
  bad 'the clear is not above the first sourced file'
fi
same 'and nothing exports it' "$(grep -c 'export WA_ANCESTRY_' "$UPG" "$ROOT/scripts/lib/install-record.sh" | awk -F: '{s+=$2} END {print s}')" '0'
# AND THE INSTALL ITSELF: a run with the verdict inherited must leave the record EXACTLY as a run without it does.
INH="$WORK/inherit"; mkdir -p "$INH/a" "$INH/b"
seed() { printf 'commit=1111111111111111111111111111111111111111\nsha256=deadbeef\nrecord_role=final\n' > "$1/installed.txt"; printf '#!/bin/sh\necho version=0.0.0\n' > "$1/wa"; chmod +x "$1/wa"; }
seed "$INH/a"; seed "$INH/b"
env WA_ANCESTRY_REUSED=2222222222222222222222222222222222222222 WA_INSTALL_DIR="$INH/a" \
  bash "$UPG" "$INH/no-such-candidate" >/dev/null 2>&1 || true
env WA_INSTALL_DIR="$INH/b" bash "$UPG" "$INH/no-such-candidate" >/dev/null 2>&1 || true
WITH="$(cat "$INH/a/installed.txt" 2>/dev/null)"
WITHOUT="$(cat "$INH/b/installed.txt" 2>/dev/null)"
same 'an inherited verdict leaves the record byte-identical' "$WITH" "$WITHOUT"
case "$WITH" in *2222222222*) bad 'the inherited commit reached the record' ;; *1111111111*) ok 'and no caller commit was written into it' ;; *) bad "the record was not the one the fixture seeded: $WITH" ;; esac

echo "test-install-record: the 18/11 case - the running commit is missing from the deployer's history"
# THE CASE THE GUARD USED TO FAIL OPEN ON. A deployer's checkout that does not carry the running commit used to
# answer 2 ("cannot tell") for every cause at once, and every caller then only noted it and installed. Two
# different facts hide behind that shape, and only one of them is ignorance.
ABSENT=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
wa_ancestry_verdict "$REPO" "$NEWER" "$ABSENT"
same "a FULL history that does not carry the running commit -> 1 (refuse)" "$?" "1"
shows "and the refusal names the running commit" "$WA_ANCESTRY_LOST" "deadbeefdead"
shows "...saying it is on no branch here" "$WA_ANCESTRY_WHY" "not in this history"

# A SHALLOW checkout of the same repository. It cannot see the running commit either, but now for a reason that
# is ignorance rather than evidence, and "cannot tell" is the right answer there - which the callers refuse.
SHALLOW="$WORK/shallow"
if git clone -q --depth 1 "file://$REPO" "$SHALLOW" 2>/dev/null; then
  SHEAD="$(git -C "$SHALLOW" rev-parse HEAD)"
  same "the fixture is really shallow" "$(git -C "$SHALLOW" rev-parse --is-shallow-repository)" "true"
  # IT IS DEEPENED FIRST (item 29): one bounded fetch can turn this clone's ignorance into the answer the full
  # history gives, and an answer is worth more than a refusal about ignorance. Here the running commit is on no
  # branch of the history even after deepening, so the verdict is 1 - the SAME answer the full-history case
  # above gives - where it used to be 2. Both refuse; this one also says why.
  wa_ancestry_verdict "$SHALLOW" "$SHEAD" "$ABSENT"
  same "a shallow clone is deepened, and a running commit the history does not carry -> 1 (refuse, as the full history does)" "$?" "1"
  same "and the clone is no longer shallow" "$(git -C "$SHALLOW" rev-parse --is-shallow-repository)" "false"
  # AND WHEN THE DEEPENING CANNOT HAPPEN, THE ANSWER IS STILL UNKNOWN, NOT YES AND NOT NO: a clone whose remote
  # is gone cannot be deepened, and its blindness is not evidence either way (the callers refuse on 2).
  BLIND="$WORK/blind"
  if git clone -q --depth 1 "file://$REPO" "$BLIND" 2>/dev/null; then
    git -C "$BLIND" remote remove origin 2>/dev/null || true
    BLIND_ABSENT=1111222233334444555566667777888899990000
    wa_ancestry_verdict "$BLIND" "$(git -C "$BLIND" rev-parse HEAD)" "$BLIND_ABSENT"
    same "a shallow clone that cannot be deepened -> 2 (unknown, which the callers refuse)" "$?" "2"
    shows "and it says why, and what to do" "$WA_ANCESTRY_WHY" "shallow"
  fi

  # ...AND THE RUNNING BINARY CAN SETTLE IT WITHOUT A CHECKOUT: if the running build reports that it already
  # contains the target, the target cannot contain the running build. That answer turns the unknown into a
  # refusal, which is the whole point of asking the bytes.
  LT="$WORK/contains-target-wa"   # answers --contains 1111... with 0 (its own ancestry names that commit)
  cat > "$LT" <<'LTEOF'
#!/bin/sh
case "$1" in
  --build-info) printf 'commit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
dirty=false
ancestors_complete=true
' ;;
  --contains) exit 0 ;;   # "yes, my ancestry contains whatever you asked about" - the answer that settles it
esac
exit 2
LTEOF
  chmod +x "$LT"
  wa_ancestry_verdict "$SHALLOW" "$SHEAD" "$ABSENT" "" "$LT"
  same "the running binary contains the target -> 1, even from a shallow clone" "$?" "1"
  shows "and it says which answer settled it" "$WA_ANCESTRY_WHY" "already contains the target commit"

  # A shallow clone also has to stop a 'not an ancestor' answer from being read as a downgrade when the walk
  # from the running commit hit the boundary: the target here is an OLD commit, the running one is the head,
  # and the links between them are below the cut.
  DEEP="$WORK/deep"; git init -q "$DEEP"
  git -C "$DEEP" config user.email test@example.com; git -C "$DEEP" config user.name test
  for n in 1 2 3 4 5; do printf 'n%s\n' "$n" > "$DEEP/f$n"; git -C "$DEEP" add "f$n"; git -C "$DEEP" commit -qm "commit $n"; done
  CUT="$(git -C "$DEEP" rev-parse HEAD)"
  FIRST="$(git -C "$DEEP" rev-list --max-parents=0 HEAD)"
  SH2="$WORK/shallow2"
  if git clone -q --depth 1 "file://$DEEP" "$SH2" 2>/dev/null; then
    git -C "$SH2" config user.email test@example.com; git -C "$SH2" config user.name test
    wa_ancestry_truncated "$SH2" "$CUT"
    same "the walk from the shallow head reaches the boundary -> truncated" "$?" "0"
    wa_ancestry_verdict "$SH2" "$FIRST" "$CUT"
    same "so 'not an ancestor' there is 2 (unknown), not 1" "$?" "2"
  else
    bad "could not make a shallow clone of the local repository (the file:// transport was refused)"
  fi
else
  bad "could not make a shallow clone of the fixture repository (the file:// transport was refused)"
fi
wa_ancestry_verdict "$REPO" "$NEWER" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
same "...and the full-history case with the fixture stub is still 1" "$?" "1"
wa_ancestry_verdict "" "" 1111222233334444555566667777888899990000 "$STUB"
same "a release install: the candidate binary answers for itself -> 0" "$?" "0"
wa_ancestry_verdict "" "" 9999888877776666555544443333222211110000 "$STUB"
same "a candidate that does not contain it -> 1" "$?" "1"

echo "test-install-record: the real binary, written through the writer, reads back as its own --build-info"
# The stub above states the rule; this states that the rule and the SHIPPED binary agree - the equality a reader
# of a node depends on (the record says what the binary says, field for field).
REALBIN="${WA_BIN:-${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa}"
[ -x "$REALBIN" ] || REALBIN="${CARGO_TARGET_DIR:-$ROOT/rust/target}/release/wa"
if [ -x "$REALBIN" ]; then
  RB="$WORK/real-install"; mkdir -p "$RB"
  wa_record_install "$RB" "$REALBIN" 'via=test'
  REALREC="$(cat "$RB/installed.txt")"
  for key in commit tree dirty; do
    same "installed.txt $key equals the binary's --build-info" "$(wa_build_field "$REALREC" $key)" "$("$REALBIN" --build-info | sed -n "s/^$key=//p" | head -1)"
  done
  same "and the record says the binary answered" "$(wa_build_field "$REALREC" build_info)" "yes"
else
  echo "  skip the real binary (none at $REALBIN)"
fi

echo "test-install-record: who says what is running (wa_running_identity)"
# The same question on every install path: the binary first, the record only when the record is about THESE
# bytes, and "nothing is installed" kept distinct from "nothing can tell".
ID="$WORK/identity"; mkdir -p "$ID"
wa_running_identity "$ID"
same "an empty directory is a first install, not ignorance" "$WA_RUNNING_SOURCE" "none"
same "...with no commit claimed" "$WA_RUNNING_COMMIT" ""
cp "$STUB" "$ID/wa"
wa_running_identity "$ID"
same "the binary names the commit" "$WA_RUNNING_SOURCE" "binary"
same "...and it is the binary's" "$WA_RUNNING_COMMIT" "1111222233334444555566667777888899990000"
same "...and dirty is asked too" "$WA_RUNNING_DIRTY" "false"
# a record that is about other bytes, beside a binary that cannot answer: its commit= is NOT what is running
DEADID="$WORK/identity-dead"; mkdir -p "$DEADID"
printf '#!/bin/sh\nexit 1\n' > "$DEADID/wa"; chmod +x "$DEADID/wa"
printf 'commit=%s\nsha256=%s\n' "$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)" "$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)" > "$DEADID/installed.txt"
wa_running_identity "$DEADID"
same "a record naming other bytes is not evidence" "$WA_RUNNING_RECORD_IS_BYTES" "no"
same "...so no commit is claimed" "$WA_RUNNING_COMMIT" ""
same "...and the source is named as the mismatch it is" "$WA_RUNNING_SOURCE" "record_mismatch"
shows "the sentence says the record is about other bytes" "$WA_RUNNING_WHY" "other bytes"
# the same record, when it IS about these bytes: a fallback, named as one
GOODID="$WORK/identity-good"; mkdir -p "$GOODID"
printf '#!/bin/sh\nexit 1\n' > "$GOODID/wa"; chmod +x "$GOODID/wa"
printf 'commit=%s\nsha256=%s\n' "$(printf 'c%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)" "$(sha256sum < "$GOODID/wa" | awk '{print $1}')" > "$GOODID/installed.txt"
wa_running_identity "$GOODID"
same "a record that IS these bytes is the fallback" "$WA_RUNNING_SOURCE" "record"
same "...and its commit is used" "$WA_RUNNING_COMMIT" "$(printf 'c%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"

echo "test-install-record: every install path writes through this library"
for path in scripts/deploy.sh scripts/upgrade.sh scripts/fleet-install.sh scripts/linux/bootstrap.sh scripts/rollback-node.sh; do
  if grep -q 'wa_build_info\|wa_record_install' "$ROOT/$path"; then ok "$path asks the binary"; else bad "$path writes a record without asking the binary"; fi
done
# THE CALLER'S COMMIT MUST NEVER BECOME THE RECORD'S IDENTITY, and this used to be one grep on scripts/deploy.sh
# (`record_commit="$COMMIT"` must not appear). A grep measures the SHAPE of the code, and on 21/11 the Lua fast
# path gave commit= a second, honest meaning: a fast-path install places no binary at all, so the install IS the
# Lua tree that deploy staged and verified, while the binary it KEEPS is named in binary_commit= from its own
# --build-info (docs/COMPONENTS.md, "The node binary itself"). A shape check cannot tell that apart from the
# 18/11 mistake, so the rule is asserted where it is decidable - on the record the REAL step writes, for both
# kinds of install. It is strictly more than the grep said: a build whose bytes report another commit must be
# REFUSED (the caller's commit cannot be written at all), and a fast-path record must name the tree and the
# bytes as two different, checkable facts.
RECORD_STEP="$WORK/record-step.sh"
STUB_COMMIT=1111222233334444555566667777888899990000
awk '/^record_installed\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$ROOT/scripts/deploy.sh" > "$RECORD_STEP"
grep -q 'binary_commit=' "$RECORD_STEP" \
  || bad "could not read record_installed() out of scripts/deploy.sh (nothing below could run)"
record_step() { # <dir> <LUA_FAST 0|1> <the commit this deploy holds> -> runs the real step, its output on stdout
  local dir="$1" fast="$2" held="$3"
  mkdir -p "$dir/scripts"
  cp "$STUB" "$dir/wa"
  printf '#!/bin/sh\nexit 0\n' > "$dir/scripts/upgrade.sh"
  (
    set -uo pipefail
    . "$LIB"
    . "$ROOT/scripts/lib/node-binaries.sh"
    . "$ROOT/scripts/lib/commit-id.sh"
    . "$RECORD_STEP"
    note() { printf 'note: %s\n' "$*"; }
    fail() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
    # deploy.sh defines this ABOVE the block this test extracts (it is how a failure on the far side of the
    # swap is recorded instead of refusing); the harness has to provide it, or every row that reaches one
    # reads `post_swap_problem: command not found` - which is what this file reported on 24/11.
    post_swap_problem() { printf 'post-swap problem: %s\n' "$1"; }
    INSTALL_DIR="$dir"; COMMIT="$held"; BRANCH=main; LUA_FAST="$fast"; RELEASE=''; REASON=''
    SOURCE_ROOT=''; RUNNING_SOURCE=binary; RUNNING_WHY='the running binary reports it'
    RUNNING_COMMIT="$STUB_COMMIT"; INSTALLED_BINARY_COMMIT="$STUB_COMMIT"
    UPGRADE_HASH=test; SENTINEL_HASH=test
    HASH="$(sha256sum < "$dir/wa" | awk '{print $1}')"
    record_installed
  )
}
HELD_OTHER=9999888877776666555544443333222211110000
BUILDR="$WORK/record-build"
OUT="$(record_step "$BUILDR" 0 "$STUB_COMMIT" 2>&1)"; rc=$?
same "a build's record step finishes -> 0" "$rc" "0"
same "a build's commit= is the binary's own answer" \
  "$(wa_build_field "$(cat "$BUILDR/installed.txt" 2>/dev/null)" commit)" "$STUB_COMMIT"
BUILDR2="$WORK/record-build-other"
OUT="$(record_step "$BUILDR2" 0 "$HELD_OTHER" 2>&1)"; rc=$?
same "a build whose bytes report ANOTHER commit is refused -> 1" "$rc" "1"
shows "...by name" "$OUT" "build_commit_mismatch"
same "...and the caller's commit is NOT recorded over the previous record" \
  "$([ -f "$BUILDR2/installed.txt" ] && cat "$BUILDR2/installed.txt" || echo none)" "none"
FASTR="$WORK/record-fast"
OUT="$(record_step "$FASTR" 1 "$HELD_OTHER" 2>&1)"; rc=$?
same "a Lua fast-path record step finishes -> 0" "$rc" "0"
same "a fast-path record names the LUA TREE it installed in commit=" \
  "$(wa_build_field "$(cat "$FASTR/installed.txt" 2>/dev/null)" commit)" "$HELD_OTHER"
same "...and the binary it KEPT in binary_commit=, from the binary's own answer" \
  "$(wa_build_field "$(cat "$FASTR/installed.txt" 2>/dev/null)" binary_commit)" "$STUB_COMMIT"
same "...and says which kind of record it is" \
  "$(wa_build_field "$(cat "$FASTR/installed.txt" 2>/dev/null)" lua_fast_path)" "1"
same "...so the two commits are distinguishable in one record" \
  "$([ "$(wa_build_field "$(cat "$FASTR/installed.txt" 2>/dev/null)" commit)" != "$(wa_build_field "$(cat "$FASTR/installed.txt" 2>/dev/null)" binary_commit)" ] && echo distinguishable)" \
  "distinguishable"
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

echo "test-install-record: a binary with no provable commit is UNKNOWN, not a first install (item 1)"
# Round 3 of the review: an old binary that cannot report its build, beside no record (or beside a record that
# names a commit and no sha256=), answered "source=none, commit empty" - and every caller read THAT as a first
# install and replaced it with no ancestry question at all. A binary is the test, not the silence about it.
BARE="$WORK/identity-bare"; mkdir -p "$BARE"
printf '#!/bin/sh\nexit 1\n' > "$BARE/wa"; chmod +x "$BARE/wa"
wa_running_identity "$BARE"
same "a binary that cannot answer, and no record: unprovable" "$WA_RUNNING_SOURCE" "unprovable"
same "...with no commit claimed" "$WA_RUNNING_COMMIT" ""
shows "...and the sentence says nobody can say" "$WA_RUNNING_WHY" "cannot name its own commit"
if wa_running_first_install; then bad "a binary with no provable commit was called a first install"; else ok "it is NOT a first install"; fi
NOREC="$WORK/identity-norecord"; mkdir -p "$NOREC"
printf 'commit=%s\n' "$(printf 'd%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)" > "$NOREC/installed.txt"
wa_running_identity "$NOREC"
same "a record with no binary and no sha256: named, but not bytes" "$WA_RUNNING_SOURCE" "record"
wa_running_identity "$BARE"
UNPROVEN="$WORK/identity-unproven"; mkdir -p "$UNPROVEN"
printf '#!/bin/sh\nexit 1\n' > "$UNPROVEN/wa"; chmod +x "$UNPROVEN/wa"
printf 'commit=%s\nvia=deploy.sh\n' "$(printf 'e%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)" > "$UNPROVEN/installed.txt"
wa_running_identity "$UNPROVEN"
same "a record with commit= and NO sha256= is not evidence" "$WA_RUNNING_RECORD_IS_BYTES" "unproven"
same "...so its commit is not claimed" "$WA_RUNNING_COMMIT" ""
same "...and the source says the commit is unprovable" "$WA_RUNNING_SOURCE" "unprovable"
shows "...naming the missing sha256" "$WA_RUNNING_WHY" "no sha256="
if wa_running_first_install; then bad "an unprovable record was called a first install"; else ok "an unprovable record is not a first install"; fi
# ROUND 4, ITEM 1. A record that IS about these bytes and names NO commit (commit=unknown, or commit= written
# blank - line 277 of scripts/lib/install-record.sh blanks "unknown"). The record proves it is about the binary and
# says nothing about where those bytes come from, so the answer is UNKNOWN. It used to be "source=none, commit
# empty", which deploy.sh read as a FIRST INSTALL: it installed over the node and printed an override
# ("ancestry_unverified=yes") that nobody had given. Fail-open, in the one sentence that is supposed to say why.
NOCOMMIT="$WORK/identity-nocommit"; mkdir -p "$NOCOMMIT"
printf '#!/bin/sh
exit 1
' > "$NOCOMMIT/wa"; chmod +x "$NOCOMMIT/wa"
printf 'commit=unknown
sha256=%s
via=deploy.sh
' "$(sha256sum < "$NOCOMMIT/wa" | awk '{print $1}')" > "$NOCOMMIT/installed.txt"
wa_running_identity "$NOCOMMIT"
same "a record about THESE bytes with commit=unknown is still about these bytes" "$WA_RUNNING_RECORD_IS_BYTES" "yes"
same "...and it names no commit" "$WA_RUNNING_RECORD_COMMIT" ""
same "...so the source is unprovable, not none" "$WA_RUNNING_SOURCE" "unprovable"
same "...and no commit is claimed" "$WA_RUNNING_COMMIT" ""
shows "...and the sentence says the record names no commit" "$WA_RUNNING_WHY" "names no commit"
if wa_running_first_install; then bad "a record about these bytes with no commit was called a first install"; else ok "it is NOT a first install"; fi
# The same record with commit= written blank rather than commit=unknown. Both spellings are the same fact and the
# reader cannot be allowed to answer one of them with "nothing here" and the other with "unknown".
BLANK="$WORK/identity-blankcommit"; mkdir -p "$BLANK"
printf '#!/bin/sh
exit 1
' > "$BLANK/wa"; chmod +x "$BLANK/wa"
printf 'commit=
sha256=%s
' "$(sha256sum < "$BLANK/wa" | awk '{print $1}')" > "$BLANK/installed.txt"
wa_running_identity "$BLANK"
same "a blank commit= beside these bytes is unprovable too" "$WA_RUNNING_SOURCE" "unprovable"
if wa_running_first_install; then bad "a blank commit= beside these bytes was called a first install"; else ok "...and it is NOT a first install either"; fi

EMPTY="$WORK/identity-empty"; mkdir -p "$EMPTY"
wa_running_identity "$EMPTY"
if wa_running_first_install; then ok "only an empty directory is a first install"; else bad "an empty directory is not a first install"; fi

echo "test-install-record: the --contains probe is bounded and scrubbed (item 8)"
# The probe asks a binary older than --contains to do something it does not know: the host hands the argument to
# the Lua core, which can open the interpreter, the database and the node. It must be bounded, and it must not run
# with this node's home, database or Lua root in its environment.
PROBE="$WORK/probe-wa"
cat > "$PROBE" <<'PROBEEOF'
#!/bin/sh
case "$1" in
  --contains)
    printf 'home=%s\nagent_home=%s\ndb=%s\nlua=%s\n' "$HOME" "${WASM_AGENT_HOME:-}" "${WASM_AGENT_DB:-}" "${WASM_AGENT_LUA_ROOT:-}" >> "$PROBE_LOG"
    sleep 30 ;;
  *) exit 0 ;;
esac
PROBEEOF
chmod +x "$PROBE"
export PROBE_LOG="$WORK/probe.log"; : > "$PROBE_LOG"
started="$(date +%s)"
WASM_AGENT_HOME="$WORK/node-home" WASM_AGENT_DB="$WORK/node.db" WASM_AGENT_LUA_ROOT="/should/not/be/seen" \
  WA_CONTAINS_TIMEOUT=2 wa_contains "$PROBE" "$(printf 'f%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"
same "a probe that never answers is 'cannot tell' (2), never 'no'" "$?" "2"
spent=$(( $(date +%s) - started ))
if [ "$spent" -le 10 ]; then ok "the probe is bounded ($spent s on a binary that never answers)"; else bad "the probe ran $spent s: an old binary would hang a deploy"; fi
LOG="$(cat "$PROBE_LOG" 2>/dev/null)"
case "$LOG" in
  *"home=$WORK"*) bad "the probe ran with the caller's HOME" ;;
  *"home="*) ok "it ran with a HOME of its own (a scratch directory, not this node's)" ;;
  *) bad "the probe did not record its HOME: $LOG" ;;
esac
hides "...and no WASM_AGENT_HOME" "$LOG" "agent_home=$WORK/node-home"
hides "...no WASM_AGENT_DB" "$LOG" "db=$WORK/node.db"
hides "...and no WASM_AGENT_LUA_ROOT" "$LOG" "/should/not/be/seen"
SAYER="$WORK/contains-wa"
printf '#!/bin/sh\ncase "$1" in --contains) exit 0 ;; *) exit 1 ;; esac\n' > "$SAYER"; chmod +x "$SAYER"
wa_contains "$SAYER" "$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"
same "a binary that contains the commit answers 0" "$?" "0"
NOPE="$WORK/contains-no"
printf '#!/bin/sh\nexit 1\n' > "$NOPE"; chmod +x "$NOPE"
wa_contains "$NOPE" "$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"
same "...and one that does not answers 1" "$?" "1"
wa_contains "$WORK/no-such-binary" "$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"
same "no binary at all is 'cannot tell' (2)" "$?" "2"


# ---- item 29: a shallow checkout is deepened before it is believed, and the signed manifest answers
# WHEN A CANDIDATE CANNOT NAME ITSELF. The shallow verdict above must not be the answer while one bounded
# fetch can settle it: --depth 1 clone, ask about the OLD commit, and the clone deepens itself.
if [ -d "$SHALLOW" ]; then
  git -C "$SHALLOW" remote set-url origin "file://$REPO" 2>/dev/null || true
  OLD="$(git -C "$REPO" rev-list --max-parents=0 HEAD | head -1)"
  wa_ancestry_verdict "$SHALLOW" "$SHEAD" "$OLD"
  same "a shallow clone is deepened and answers from the history instead of from its ignorance" "$?" "0"
  same "and the clone is no longer shallow" "$(git -C "$SHALLOW" rev-parse --is-shallow-repository)" "false"
fi

# A MANIFEST IS THE SIGNED ANSWER FOR A CANDIDATE THAT CANNOT REPORT ITS OWN BUILD - and only for one.
MF="$WORK/node-deadbeefdead.manifest"
printf 'schema=wasm-agent-node-binaries/1\nsource_commit=%s\n' "$(printf 'c%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)" > "$MF"
same "a manifest's source_commit is read" "$(wa_manifest_source_commit "$MF")" "$(printf 'c%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"
printf 'schema=wasm-agent-node-binaries/1\nsource_commit=not-a-commit\n' > "$WORK/bad.manifest"
wa_manifest_source_commit "$WORK/bad.manifest" >/dev/null 2>&1
same "a manifest naming something that is not a commit answers nothing" "$?" "1"
wa_manifest_source_commit "$WORK/absent.manifest" >/dev/null 2>&1
same "and a missing manifest answers nothing" "$?" "1"
# AN INSTALLED RECORD IS FINAL (Fable 26/11, the nextcloud-b row). A release install onto a node that was ALREADY
# at the target wrote commit=, release= and via=remote-update.sh and no record_role at all, and the row that asks
# for record_role=final failed on a node whose update had settled 'installed'. The writer now answers final by
# default and lets a caller say interim.
ROLE="$WORK/role"
mkdir -p "$ROLE"
wa_record_install "$ROLE" "$STUB" 'via=release-install.sh' >/dev/null 2>&1
same 'an install record is final by default' "$(sed -n 's/^record_role=//p' "$ROLE/installed.txt")" 'final'
wa_record_install "$ROLE" "$STUB" 'via=upgrade.sh' 'record_role=interim' >/dev/null 2>&1
same 'and a caller handing over an interim record is believed' "$(sed -n 's/^record_role=//p' "$ROLE/installed.txt")" 'interim'
wa_record_install "$ROLE" "$STUB" 'record_role=' >/dev/null 2>&1
same 'an empty record_role falls back to final instead of writing nothing' "$(sed -n 's/^record_role=//p' "$ROLE/installed.txt")" 'final'

printf 'test-install-record: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
