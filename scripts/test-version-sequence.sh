#!/usr/bin/env bash
# THE NODE-SHAPE ROW (Fable 25/11): a scratch node driven through the five steps, including a FAILED restart and a
# FAILED sentinel move - required before the switch is turned on anywhere.
#
# WHAT IS REAL HERE and what is a stub, said plainly:
#   real   scripts/versions-adopt.sh (the conversion and its verification), scripts/lib/versions.sh (assemble,
#          pointer, links, retention), scripts/version-install.sh (seal + point), scripts/lib/sentinel-move.sh
#          (the sentinel order, the drop-in fallback, the named failure) and scripts/version-sequence.sh (the order)
#   stub   upgrade.sh, in both of its modes: staging (write the program and the record into WA_VERSION_STAGING and
#          exit 0) and restart (exit 0, or exit 7 when the row asks for a failed restart). upgrade.sh itself needs a
#          live node, a service target and a real swap; its internals have their own rows and the deploy runs it for
#          real. What this row proves is the SEQUENCE around it, which is what nothing else drives.
#   stub   systemctl (WA_SENTINEL_UNIT_SYSTEMCTL): active, or never active, so the sentinel fallback can be driven.
#
# CASES
#   happy             convert -> stage -> seal+point -> restart -> sentinel: rc 0, current names the new version,
#                     every legacy path resolves through it
#   failed restart    the restart exits non-zero: rc 3, current moves BACK by one rename, the new version stays
#                     sealed and kept, and the message names both
#   failed sentinel   no sentinel ever comes up: with --sentinel-fail-expected rc 0 and the line says the previous
#                     version keeps supervising (or that nothing is) ; without the flag rc 4
#   member required   no lua-stage: version_folders_member_missing, and no pointer move
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/scratch-env.sh

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-version-sequence: $*" >&2; exit 1; }

BASE="${WA_ROW_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W="$(mktemp -d "$BASE/wa-seq-XXXXXX")" || { echo "FAIL test-version-sequence: no scratch" >&2; exit 2; }
cleanup() { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
wa_scratch_env_apply "$W" >/dev/null
ISOLATION="$(wa_scratch_env_check "$W" 2>&1)" || { printf '%s\n' "$ISOLATION" >&2; fail "the row's environment is NOT ISOLATED: nothing was run"; }

ID=aaaaaaaaaaaa; COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREV_ID=bbbbbbbbbbbb; PREV_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# the stub upgrade.sh, whose two modes are the contract the sequence relies on
cat > "$W/upgrade-stub.sh" <<'UP'
#!/bin/sh
echo "upgrade-stub: staging=${WA_VERSION_STAGING:-none}" >> "$SEQ_LOG"
if [ -n "${WA_VERSION_STAGING:-}" ]; then
  mkdir -p "$WA_VERSION_STAGING"/scripts || exit 9
  cp -f "$1" "$WA_VERSION_STAGING/wa" || exit 9
  printf 'commit=%s\nvia=stub\n' "$SEQ_COMMIT" > "$WA_VERSION_STAGING/installed.txt" || exit 9
  exit 0
fi
[ "$(cat "$SEQ_MODE")" = restart-fail ] && { echo "upgrade-stub: the restart failed on purpose" >> "$SEQ_LOG"; exit 7; }
exit 0
UP
chmod +x "$W/upgrade-stub.sh"

# the stub systemctl: active unless $SEQ_MODE is sentinel-fail
cat > "$WA_SENTINEL_UNIT_SYSTEMCTL" <<'SC'
#!/bin/sh
echo "$*" >> "$SEQ_LOG"
case "$1 $2" in
  "--user daemon-reload") exit 0 ;;
  "--user is-active") [ "$(cat "$SEQ_MODE")" = sentinel-fail ] && { echo inactive; exit 3; }; echo active; exit 0 ;;
esac
exit 0
SC
chmod +x "$WA_SENTINEL_UNIT_SYSTEMCTL"
export SEQ_LOG="$W/seq.log" SEQ_MODE="$W/mode" SEQ_COMMIT="$COMMIT"

in_place() { # <dir> <commit>
  local dir="$1" commit="$2"
  mkdir -p "$dir/lua-core/lua/core" "$dir/scripts"
  # A stub that DECLARES its interface, because a lua part is checked against the program that will run it.
  printf '#!/bin/sh\n[ "$1" = --interface ] && { echo %s; exit 0; }\nprintf "wa-stub\\n"\n' "$HOST_INT" > "$dir/wa"
  chmod +x "$dir/wa"
  printf 'sentinel' > "$dir/wa-sentinel"
  printf 'init' > "$dir/lua-core/lua/core/init.lua"
  printf 'deploy' > "$dir/scripts/deploy.sh"
  printf 'commit=%s\nbranch=main\n' "$commit" > "$dir/installed.txt"
}
# a lua part, built here exactly as scripts/test-lua-part.sh builds one: a tree + manifest, tarred, and pinned
a_lua_part() { # <tree dir> <out> <interface>
  local dir="$1" out="$2" int="$3"
  mkdir -p "$dir/lua/core"
  printf 'init from the part for %s\n' "$int" > "$dir/lua/core/init.lua"
  printf 'vendored\n' > "$dir/lua/core/vendor.lua"
  { printf 'capabilities %s\n' "$int"; printf 'commit deadbeefcafe\n'
    printf '%s  lua/core/init.lua\n' "$(sha256sum < "$dir/lua/core/init.lua" | awk '{print $1}')"
    printf '%s  lua/core/vendor.lua\n' "$(sha256sum < "$dir/lua/core/vendor.lua" | awk '{print $1}')"
  } > "$dir/manifest.txt"
  ( cd "$dir" && tar czf "$out" manifest.txt lua )
}
part_lock() { # <lock> <part> <interface>
  local sha bytes
  sha="$(sha256sum < "$2" | awk '{print $1}')"; bytes="$(wc -c < "$2" | tr -d '[:space:]')"
  { printf 'compat 1\n'; printf 'lua-core %s %s interface=%s\n' "$sha" "$bytes" "$3"; } > "$1"
}
HOST_INT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_INT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$W/root/scripts" "$W/root/ui" "$W/lua-stage/lua/core"
printf 'deploy' > "$W/root/scripts/deploy.sh"; printf 'ui' > "$W/root/ui/index.html"
printf 'init' > "$W/lua-stage/lua/core/init.lua"

sequence() { # <install> <commit> [extra args...]
  local install="$1" commit="$2"; shift 2
  bash scripts/version-sequence.sh --install "$install" --candidate "$install/wa" --commit "$commit" \
    --root "$W/root" --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/lua-stage" --share "$W/share" "$@"
}

# --- 1. happy path ---------------------------------------------------------------------------------------------
I="$W/i1"; in_place "$I" "$COMMIT"; echo ok > "$SEQ_MODE"
sequence "$I" "$COMMIT" > "$W/seq1.log" 2>&1 || { sed -n '1,10p' "$W/seq1.log" >&2; fail "happy: the sequence must succeed"; }
grep -q 'version_folders_ok' "$W/seq1.log" || fail "happy: the sequence does not say it finished"
ok
# ONE command, not two concatenated: the first version read `cat current` and `wa_version_current` into the same
# string, so it could never equal the id (the runner caught it: rows/20261125T233148Z-25616).
happy_now="$(WA_SHARE_ROOT="$W/share" bash -c '. scripts/lib/versions.sh; wa_version_current' 2>/dev/null)"
[ "$happy_now" = "$ID" ] || fail "happy: current is '$happy_now', not the new version"
[ -f "$W/share/versions/$ID/version.txt" ] || fail "happy: no version folder"
ok
for name in wa lua-core scripts; do
  [ -L "$I/$name" ] || fail "happy: $name is not a link through the pointer"
done
ok
# the ORDER: convert before stage before seal before restart before sentinel
# `grep -o`, not `grep -n | cut -d: -f2`: the line-number prefix became the second field, so the first version read
# the program name five times (rows/20261125T233250Z-24786).
# The sequence's OWN marker. "step N" matched version-install.sh's numbered steps in the same log, which made the
# order look wrong (rows/20261125T233514Z-16680).
order="$(grep -o 'SEQSTEP [1-5]' "$W/seq1.log" | tr -d ' ' | tr '\n' ',')"
case "$order" in 'SEQSTEP1,SEQSTEP2,SEQSTEP3,SEQSTEP4,SEQSTEP5,') ;; *) fail "happy: the steps did not run in order ($order)";; esac
ok

# --- 2. a FAILED restart moves the pointer BACK -----------------------------------------------------------------
I2="$W/i2"; in_place "$I2" "$COMMIT"
WNEW="$W/w2"; mkdir -p "$WNEW"; cp -a "$W/share/versions/$ID" "$WNEW/" 2>/dev/null || true
# a second scratch share with the previous version already current, so there IS a version to go back to
mkdir -p "$W/share2/versions/$PREV_ID"; printf 'id=%s\ninstall_dir=%s\n' "$PREV_ID" "$I2" > "$W/share2/versions/$PREV_ID/version.txt"
ln -sfn "versions/$PREV_ID" "$W/share2/current"
echo restart-fail > "$SEQ_MODE"
SEQ_MODE_FILE="$SEQ_MODE" bash scripts/version-sequence.sh --install "$I2" --candidate "$I2/wa" --commit "$COMMIT" \
  --root "$W/root" --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/lua-stage" --share "$W/share2" > "$W/seq2.log" 2>&1
rc=$?
[ "$rc" = 3 ] || { sed -n '1,10p' "$W/seq2.log" >&2; fail "failed restart: the sequence must report rc 3, got $rc"; }
grep -q "version_folders_restart_failed" "$W/seq2.log" || fail "failed restart: the failure is not named"
grep -q "back on $PREV_ID" "$W/seq2.log" || fail "failed restart: the sequence does not say the pointer moved back"
ok
now="$(WA_SHARE_ROOT="$W/share2" bash -c '. scripts/lib/versions.sh; wa_version_current')"
[ "$now" = "$PREV_ID" ] || fail "failed restart: current is $now, not the previous version"
[ -d "$W/share2/versions/$ID" ] || fail "failed restart: the new version was not kept sealed"
ok

# --- 3. a FAILED sentinel -------------------------------------------------------------------------------------
# A PREVIOUS VERSION must exist for step 5 to run at all: on a fresh share the sequence skips the sentinel move by
# design (there is nothing to fall back to), which made the first version of this case prove nothing
# (rows/20261125T233626Z-20949).
seed_prev() { # <share> <install>
  local share="$1" install="$2"
  mkdir -p "$share/versions/$PREV_ID"
  printf 'id=%s
install_dir=%s
' "$PREV_ID" "$install" > "$share/versions/$PREV_ID/version.txt"
  printf '#!/bin/sh
exit 0
' > "$share/versions/$PREV_ID/wa-sentinel"; chmod +x "$share/versions/$PREV_ID/wa-sentinel"
  ln -sfn "versions/$PREV_ID" "$share/current"
}
I3="$W/i3"; in_place "$I3" "$COMMIT"; seed_prev "$W/share3" "$I3"; echo sentinel-fail > "$SEQ_MODE"
bash scripts/version-sequence.sh --install "$I3" --candidate "$I3/wa" --commit "$COMMIT" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/lua-stage" --share "$W/share3" > "$W/seq3.log" 2>&1 \
  && fail "failed sentinel: without the expectation the sequence must not claim success"
grep -q 'version_folders_sentinel_failed' "$W/seq3.log" || { sed -n '1,12p' "$W/seq3.log" >&2; fail "failed sentinel: the failure is not named"; }
ok
I4="$W/i4"; in_place "$I4" "$COMMIT"; seed_prev "$W/share4" "$I4"
bash scripts/version-sequence.sh --install "$I4" --candidate "$I4/wa" --commit "$COMMIT" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/lua-stage" --share "$W/share4" --sentinel-fail-expected > "$W/seq4.log" 2>&1 \
  || { sed -n '1,12p' "$W/seq4.log" >&2; fail "failed sentinel: with the expectation the sequence reports it"; }
grep -q 'sentinel_move_failed_as_expected' "$W/seq4.log" || fail "failed sentinel: the expected failure is not named"
ok

# --- 4. a required member that is not there --------------------------------------------------------------------
I5="$W/i5"; in_place "$I5" "$COMMIT"; echo ok > "$SEQ_MODE"
bash scripts/version-sequence.sh --install "$I5" --candidate "$I5/wa" --commit "$COMMIT" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/absent-lua" --share "$W/share5" > "$W/seq5.log" 2>&1 \
  && fail "member required: a missing lua-core must fail the sequence"
grep -q 'version_folders_member_missing: lua-core' "$W/seq5.log" || { sed -n '1,8p' "$W/seq5.log" >&2; fail "member required: the failure is not named"; }
ok

# --- 5. the lua-core member COMES FROM A PART ---------------------------------------------------------------
# ITS OWN COMMIT: reusing the earlier one means the version is already assembled, version-install skips to step 5
# and the part is never filled - the row would then be testing nothing (rows/20261126T023132Z-13126). A Lua-only
# landing IS its own commit.
COMMIT_P=dddddddddddddddddddddddddddddddddddddddd; ID_P=dddddddddddd
I6="$W/i6"; in_place "$I6" "$COMMIT_P"; echo ok > "$SEQ_MODE"
a_lua_part "$W/part-tree" "$W/lua-core-good.tar.gz" "$HOST_INT"
part_lock "$W/lua.part.lock" "$W/lua-core-good.tar.gz" "$HOST_INT"
bash scripts/version-sequence.sh --install "$I6" --candidate "$I6/wa" --commit "$COMMIT_P" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --share "$W/share6" \
  --lua-part "$W/lua-core-good.tar.gz" --lua-lock "$W/lua.part.lock" > "$W/seq6.log" 2>&1 \
  || { sed -n '1,12p' "$W/seq6.log" >&2; fail "part: a good lua part must install through the sequence"; }
grep -q 'lua_part_filled' "$W/seq6.log" || { sed -n '1,12p' "$W/seq6.log" >&2; fail "part: the part did not fill the member"; }
sealed="$W/share6/versions/$ID_P/lua-core/lua/core/init.lua"
[ -f "$sealed" ] || fail "part: the sealed version has no lua/core/init.lua from the part"
grep -q "init from the part for $HOST_INT" "$sealed" || fail "part: the sealed member is not the part's tree"
[ "$(WA_SHARE_ROOT="$W/share6" bash -c '. scripts/lib/versions.sh; wa_version_current')" = "$ID_P" ] || fail "part: current does not name the version"
ok
# a part whose interface differs is refused BEFORE the seal, and the pointer does not move
COMMIT_P2=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee; ID_P2=eeeeeeeeeeee
I7="$W/i7"; in_place "$I7" "$COMMIT_P2"; echo ok > "$SEQ_MODE"
a_lua_part "$W/part-tree2" "$W/lua-core-bad.tar.gz" "$OTHER_INT"
part_lock "$W/lua.bad.lock" "$W/lua-core-bad.tar.gz" "$OTHER_INT"
bash scripts/version-sequence.sh --install "$I7" --candidate "$I7/wa" --commit "$COMMIT_P2" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --share "$W/share7" \
  --lua-part "$W/lua-core-bad.tar.gz" --lua-lock "$W/lua.bad.lock" > "$W/seq7.log" 2>&1 \
  && fail "part: a part whose interface differs must not install"
grep -q 'lua_part_interface_mismatch\|version_install_lua_part_refused' "$W/seq7.log" || { sed -n '1,12p' "$W/seq7.log" >&2; fail "part: the mismatch is not named"; }
[ ! -d "$W/share7/versions/$ID_P2" ] && ok || fail "part: a refused part still produced a sealed version"

echo "version sequence ok ($n checks)"

