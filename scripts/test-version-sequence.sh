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
  printf '#!/bin/sh\nprintf "wa-stub\\n"\n' > "$dir/wa"; chmod +x "$dir/wa"
  printf 'sentinel' > "$dir/wa-sentinel"
  printf 'init' > "$dir/lua-core/lua/core/init.lua"
  printf 'deploy' > "$dir/scripts/deploy.sh"
  printf 'commit=%s\nbranch=main\n' "$commit" > "$dir/installed.txt"
}
mkdir -p "$W/root/scripts" "$W/root/ui" "$W/lua-stage/lua/core"
printf 'deploy' > "$W/root/scripts/deploy.sh"; printf 'ui' > "$W/root/ui/index.html"
printf 'init' > "$W/lua-stage/lua/core/init.lua"

sequence() { # <install> <commit> [extra args...]
  local install="$1" commit="$2"; shift 2
  bash scripts/version-sequence.sh --install "$install" --candidate "$install/wa" --commit "$commit" \
    --root "$W/root" --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/lua-stage" --share "$W/share" "$@"
}

# --- 1. happy path ---------------------------------------------------------------------------------------------
I="$W/i1"; in_place "$I" "$PREV_COMMIT"; echo ok > "$SEQ_MODE"
sequence "$I" "$COMMIT" > "$W/seq1.log" 2>&1 || { sed -n '1,10p' "$W/seq1.log" >&2; fail "happy: the sequence must succeed"; }
grep -q 'version_folders_ok' "$W/seq1.log" || fail "happy: the sequence does not say it finished"
ok
[ "$(cat "$W/share/current" 2>/dev/null; WA_SHARE_ROOT="$W/share" . scripts/lib/versions.sh; wa_version_current)" = "$ID" ] || fail "happy: current does not name the new version"
[ -f "$W/share/versions/$ID/version.txt" ] || fail "happy: no version folder"
ok
for name in wa lua-core scripts; do
  [ -L "$I/$name" ] || fail "happy: $name is not a link through the pointer"
done
ok
# the ORDER: convert before stage before seal before restart before sentinel
order="$(grep -n 'step [1-5]' "$W/seq1.log" | cut -d: -f2 | tr -d ' ' | tr '\n' ',')"
case "$order" in 'step1,step2,step3,step4,step5,') ;; *) fail "happy: the steps did not run in order ($order)";; esac
ok

# --- 2. a FAILED restart moves the pointer BACK -----------------------------------------------------------------
I2="$W/i2"; in_place "$I2" "$PREV_COMMIT"
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
I3="$W/i3"; in_place "$I3" "$PREV_COMMIT"; echo sentinel-fail > "$SEQ_MODE"
bash scripts/version-sequence.sh --install "$I3" --candidate "$I3/wa" --commit "$COMMIT" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/lua-stage" --share "$W/share3" > "$W/seq3.log" 2>&1 \
  && fail "failed sentinel: without the expectation the sequence must not claim success"
grep -q 'version_folders_sentinel_failed' "$W/seq3.log" || { sed -n '1,12p' "$W/seq3.log" >&2; fail "failed sentinel: the failure is not named"; }
ok
I4="$W/i4"; in_place "$I4" "$PREV_COMMIT"
bash scripts/version-sequence.sh --install "$I4" --candidate "$I4/wa" --commit "$COMMIT" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/lua-stage" --share "$W/share4" --sentinel-fail-expected > "$W/seq4.log" 2>&1 \
  || { sed -n '1,12p' "$W/seq4.log" >&2; fail "failed sentinel: with the expectation the sequence reports it"; }
grep -q 'sentinel_move_failed_as_expected' "$W/seq4.log" || fail "failed sentinel: the expected failure is not named"
ok

# --- 4. a required member that is not there --------------------------------------------------------------------
I5="$W/i5"; in_place "$I5" "$PREV_COMMIT"; echo ok > "$SEQ_MODE"
bash scripts/version-sequence.sh --install "$I5" --candidate "$I5/wa" --commit "$COMMIT" --root "$W/root" \
  --upgrade "$W/upgrade-stub.sh" --lua-stage "$W/absent-lua" --share "$W/share5" > "$W/seq5.log" 2>&1 \
  && fail "member required: a missing lua-core must fail the sequence"
grep -q 'version_folders_member_missing: lua-core' "$W/seq5.log" || { sed -n '1,8p' "$W/seq5.log" >&2; fail "member required: the failure is not named"; }
ok

echo "version sequence ok ($n checks)"

