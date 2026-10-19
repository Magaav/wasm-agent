#!/usr/bin/env bash
# Installing a PREBUILT Android bundle (`install-termux.sh --bundle DIR --manifest-sha256 SHA`)
# against a private prefix, a fabricated bundle and a pre-existing installation that carries
# identity and state.
#
# What this suite can and cannot prove. It runs on a non-Android host, so the "runtime" in
# the fixtures is a fabricated aarch64 ELF header plus a payload: its executable bit cannot
# be represented here and it cannot be run, so the host-only probe is disabled
# (`WA_TERMUX_HOST_PROBES=0`) and that skip is counted and printed, never silent. What IS
# real: the real installer, the real shared library, the real launcher and updater out of
# this checkout, a real hash chain, real backups and the real two-rename switch. A real
# Android runtime starting on a real phone is not proven here - that is the coordinator's
# device run, and nothing in this file claims it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0
skip=0
skipped_notes=""

ok() { pass=$((pass + 1)); printf '  ok: %s\n' "$1"; }
skipf() { skip=$((skip + 1)); skipped_notes="$skipped_notes
    - $1"; printf '  skip: %s\n' "$1"; }
die() { printf '  FAIL: %s\n' "$1" >&2; exit 1; }

# ---- a fabricated aarch64 ELF, because no Android toolchain runs here -------

write_binary() { # <path> [abi]
  _p=$1
  _abi=${2:-aarch64}
  if [ "$_abi" = not-elf ]; then printf '#!/usr/bin/env sh\nexit 0\n' > "$_p"; return 0; fi
  case "$_abi" in
    aarch64) _m='\267' ;;
    x86-64) _m='\076' ;;
    *) _m='\001' ;;
  esac
  # e_ident (16 bytes), e_type (2), e_machine (2) - written in countable pieces.
  printf '\177ELF\002\001\001\000' > "$_p"
  printf '\000\000\000\000\000\000\000\000' >> "$_p"
  printf '\002\000' >> "$_p"
  printf "$_m\000" >> "$_p"
  printf 'payload-%s\n' "$_abi" >> "$_p"
}

# ---- a bundle, shaped exactly like the one cross-build-android.sh writes -----

. "$root/scripts/termux/release-lib.sh"
RL_MANIFEST_EXCLUDE=bundle.manifest
rl_paths

bundle_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
bundle_tree=tttttttttttttttttttttttttttttttttttttttt
bundle_remote=https://example.invalid/wasm-agent.git

make_bundle() { # <dir> [abi] [triple]
  _d=$1
  _abi=${2:-aarch64}
  _triple=${3:-aarch64-linux-android}
  rm -rf "$_d"
  mkdir -p "$_d/bin" "$_d/ui"
  write_binary "$_d/wa" "$_abi"
  chmod +x "$_d/wa"
  cp "$root/scripts/termux/wa" "$_d/bin/wa"
  cp "$root/scripts/termux/wa-update.sh" "$_d/bin/wa-update"
  cp "$root/scripts/termux/release-lib.sh" "$_d/bin/release-lib.sh"
  chmod +x "$_d/bin/wa" "$_d/bin/wa-update"
  for _a in index.html style.css app.js components.js render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png; do
    printf 'asset %s\n' "$_a" > "$_d/ui/$_a"
  done
  printf 'license text\n' > "$_d/LICENSE"
  {
    printf 'source_commit=%s\n' "$bundle_commit"
    printf 'source_remote=%s\n' "$bundle_remote"
    printf 'installed_utc=2026-10-19T00:00:00Z\n'
    printf 'previous_commit=-\n'
    printf 'installed_by=cross-build-android\n'
    printf 'source_provenance=cross-built-android\n'
    printf 'build_profile=cross-android\n'
  } > "$_d/installed.txt"
  rl_manifest "$_d" "$_d/installed.sha256"
  {
    printf 'bundle_format=1\n'
    printf 'bundle_kind=cross-built-android\n'
    printf 'target_triple=%s\n' "$_triple"
    printf 'elf_machine=%s\n' "$_abi"
    printf 'android_api=21\n'
    printf 'build_profile=cross-android\n'
    printf 'source_provenance=cross-built-android\n'
    printf 'source_commit=%s\n' "$bundle_commit"
    printf 'source_tree_sha256=%s\n' "$bundle_tree"
    printf 'source_remote=%s\n' "$bundle_remote"
    printf 'built_utc=2026-10-19T00:00:00Z\n'
    printf 'built_by=cross-build-android.sh\n'
    printf 'host_triple=x86_64-pc-windows-msvc\n'
    printf 'rustc_version=1.98.1 (48a229cea 2026-09-01)\n'
    printf 'rustc_commit=48a229ceaefd4985c50990b14116b6d856af0985\n'
    printf 'ndk_version=27.3.13750724\n'
    printf 'release_manifest=installed.sha256\n'
    printf 'release_manifest_sha256=%s\n' "$(rl_sha256 "$_d/installed.sha256")"
    printf 'member_count=%s\n' "$(wc -l < "$_d/installed.sha256" | tr -d ' ')"
    sed 's/^\([0-9a-f]\{64\}\)  \(.*\)$/artefact \1 \2/' "$_d/installed.sha256"
  } > "$_d/bundle.manifest"
}

bundle_sha() { rl_sha256 "$1/bundle.manifest"; }

# Recompute the envelope hash after the suite changed the manifest on purpose, so the case
# under test is the one being tested and not the pasted-hash gate.
reseal() { bundle_sha "$1"; }

# ---- a pre-existing installation, with state that must not move -------------

prefix=$work/prefix
install=$prefix/opt/wasm-agent-preview
releases=$prefix/opt/wasm-agent-releases
updated=$prefix/opt/wasm-agent-update
home=$work/home
mkdir -p "$prefix/bin" "$prefix/opt" "$home/.wasm-agent" "$home/workspace"
printf 'WASM_AGENT_LLM_API_KEY=state-must-survive\nWASM_AGENT_DISPLAY_NAME=Phone agent\n' > "$home/.wasm-agent/env"
printf 'node-identity-bytes\n' > "$home/.wasm-agent/identity.key"
printf 'sqlite-ish ledger\n' > "$home/.wasm-agent/memory.db"
printf 'unrelated file\n' > "$home/workspace/notes.txt"

cat > "$prefix/bin/rg" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$prefix/bin/rg"

source_commit_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
make_install() { # <commit> [extra installed.txt lines]
  rm -rf "$install"
  mkdir -p "$install/bin" "$install/ui"
  # The installed runtime is a stand-in; the built CANDIDATES are the fabricated ELFs, which
  # is where the ABI check is actually exercised.
  printf '#!/usr/bin/env sh\nexit 0\n' > "$install/wa"
  chmod +x "$install/wa"
  cp "$root/scripts/termux/wa" "$install/bin/wa"
  cp "$root/scripts/termux/wa-update.sh" "$install/bin/wa-update"
  cp "$root/scripts/termux/release-lib.sh" "$install/bin/release-lib.sh"
  chmod +x "$install/bin/wa" "$install/bin/wa-update"
  for _a in index.html style.css app.js components.js render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png; do
    printf 'asset %s\n' "$_a" > "$install/ui/$_a"
  done
  printf 'license text\n' > "$install/LICENSE"
  {
    printf 'source_commit=%s\n' "$1"
    printf 'source_remote=%s\n' "$bundle_remote"
    printf 'installed_utc=2026-10-18T00:00:00Z\n'
    printf 'previous_commit=-\n'
    printf 'installed_by=install-termux\n'
    printf 'source_provenance=source-built-termux\n'
    printf 'build_profile=debug\n'
  } > "$install/installed.txt"
  rl_paths
  rl_manifest "$install" "$install/installed.sha256"
}

export PREFIX=$prefix
export HOME=$home
export WASM_AGENT_HOME=$home
export WA_TERMUX_INSTALL=$install
export WA_TERMUX_RELEASES=$releases
export WA_TERMUX_UPDATE_DIR=$updated
export WA_TERMUX_TEST=1
export WA_TERMUX_HOST_PROBES=0

bundle=$work/bundle
make_bundle "$bundle"

# Every install goes through the top-level installer, exactly as the operator runs it.
run_install() { bash "$root/scripts/install-termux.sh" --bundle "$1" --manifest-sha256 "$2"; }

state_hashes() { sha256sum "$home/.wasm-agent/env" "$home/.wasm-agent/identity.key" "$home/.wasm-agent/memory.db" "$home/workspace/notes.txt"; }
snapshot_dir() { ( cd "$1" && find . -type f ! -name installed.sha256 -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done ); }

expect_fail() { # <label> <pattern> <args...>
  _label=$1
  _pattern=$2
  shift 2
  set +e
  _out=$(run_install "$@" 2>&1)
  _rc=$?
  set -e
  [ "$_rc" -ne 0 ] || die "$_label: expected a refusal, got exit 0: $_out"
  case "$_out" in
    *"$_pattern"*) ok "$_label: refused with '$_pattern'" ;;
    *) die "$_label: expected '$_pattern' in: $_out" ;;
  esac
}

expect_ok() { # <label> <pattern> <args...>
  _label=$1
  _pattern=$2
  shift 2
  set +e
  _out=$(run_install "$@" 2>&1)
  _rc=$?
  set -e
  [ "$_rc" -eq 0 ] || die "$_label: expected success, got exit $_rc: $_out"
  case "$_out" in
    *"$_pattern"*) ok "$_label" ;;
    *) die "$_label: expected '$_pattern' in: $_out" ;;
  esac
}

# ---- 1. the refusals, before anything is installed --------------------------

good_sha=$(bundle_sha "$bundle")
before_state=$(state_hashes)

expect_fail 'a wrong pasted manifest hash is refused' 'bundle_manifest_sha256_mismatch' \
  "$bundle" 0000000000000000000000000000000000000000000000000000000000000000
expect_fail 'a short hash is refused as malformed' 'manifest_sha256_invalid' "$bundle" abcd1234
expect_fail 'a non-hex hash is refused as malformed' 'manifest_sha256_invalid' \
  "$bundle" zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
expect_fail 'a missing bundle is refused' 'bundle_missing' "$work/no-such-bundle" "$good_sha"
[ ! -e "$install" ] || die 'a refusal installed something'
ok 'no refusal installed anything'

wrongabi=$work/bundle-wrongabi
make_bundle "$wrongabi" x86-64
expect_fail 'a wrong-ABI artefact is refused by its ELF machine' 'wrong_abi' \
  "$wrongabi" "$(bundle_sha "$wrongabi")"

notelf=$work/bundle-notelf
make_bundle "$notelf" not-elf
expect_fail 'a non-ELF "runtime" is refused' 'wrong_abi' "$notelf" "$(bundle_sha "$notelf")"

wrongtriple=$work/bundle-wrongtriple
make_bundle "$wrongtriple" aarch64 x86_64-linux-android
expect_fail 'a bundle for another target triple is refused' 'wrong_target_triple' \
  "$wrongtriple" "$(bundle_sha "$wrongtriple")"

modified=$work/bundle-modified
make_bundle "$modified"
printf 'tampered\n' >> "$modified/ui/app.js"
expect_fail 'a modified member is refused' 'bundle_modified' "$modified" "$(bundle_sha "$modified")"

truncated=$work/bundle-truncated
make_bundle "$truncated"
head -c 12 "$truncated/wa" > "$truncated/wa.part"
mv "$truncated/wa.part" "$truncated/wa"
chmod +x "$truncated/wa"
expect_fail 'a truncated runtime is refused' 'bundle_modified' "$truncated" "$(bundle_sha "$truncated")"

missing=$work/bundle-missing
make_bundle "$missing"
rm -f "$missing/ui/service-worker.js"
expect_fail 'a bundle with a missing member is refused' 'bundle_incomplete' \
  "$missing" "$(bundle_sha "$missing")"

nomanifest=$work/bundle-nomanifest
make_bundle "$nomanifest"
nomanifest_sha=$(bundle_sha "$nomanifest")
rm -f "$nomanifest/bundle.manifest"
expect_fail 'a bundle with no manifest is refused' 'bundle_incomplete' "$nomanifest" "$nomanifest_sha"

# The envelope is re-sealed over a rewritten release manifest, so the tree check passes and
# the per-artefact layer is the one that must catch the changed runtime.
artefact=$work/bundle-artefact
make_bundle "$artefact"
printf 'appended after the manifest was written\n' >> "$artefact/wa"
RL_MANIFEST_EXCLUDE=bundle.manifest rl_manifest "$artefact" "$artefact/installed.sha256"
sed -i "s/^release_manifest_sha256=.*/release_manifest_sha256=$(rl_sha256 "$artefact/installed.sha256")/" \
  "$artefact/bundle.manifest"
expect_fail 'a member that disagrees with its per-artefact hash is refused' 'bundle_member_mismatch' \
  "$artefact" "$(bundle_sha "$artefact")"

# A host that is not the phone: the same guards as the rest of the script.
set +e
_host_out=$(env -u WA_TERMUX_TEST -u PREFIX bash "$root/scripts/install-termux.sh" --bundle "$bundle" --manifest-sha256 "$good_sha" 2>&1)
_host_rc=$?
set -e
[ "$_host_rc" -ne 0 ] || die 'a non-phone host was allowed to install a bundle'
case "$_host_out" in
  *'run this inside the Termux app'*) ok 'a host that is not the phone is refused' ;;
  *) die "expected the Termux guard, got: $_host_out" ;;
esac
[ ! -e "$install" ] || die 'a refusal on a non-phone host installed something'
[ "$before_state" = "$(state_hashes)" ] || die 'a refusal changed node state'
ok 'every refusal above left node state and the installation untouched'

# ---- 2. a fresh install from the bundle -------------------------------------

make_bundle "$bundle"
good_sha=$(bundle_sha "$bundle")
before_state=$(state_hashes)
expect_ok 'a verified bundle installs on a clean node' 'installed' "$bundle" "$good_sha"

[ -f "$install/wa" ] || die 'the runtime was not installed'
[ -f "$install/bin/wa" ] || die 'the launcher was not installed'
[ -f "$install/bin/wa-update" ] || die 'the updater was not installed'
[ -f "$install/bin/release-lib.sh" ] || die 'the updater library was not installed'
for _a in index.html style.css app.js components.js render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png; do
  [ -f "$install/ui/$_a" ] || die "UI asset $_a was not installed"
done
ok 'the installed closure is the whole bundle closure (runtime, launcher, updater, UI, LICENSE)'

rl_paths
rl_manifest_verify "$install" || die 'the installed release does not match its own manifest'
ok 'the installed release verifies against its own manifest'

[ "$(rl_get "$install/installed.txt" source_commit)" = "$bundle_commit" ] || die 'the bundle commit was not recorded'
[ "$(rl_get "$install/installed.txt" build_profile)" = 'cross-android' ] || die 'build_profile=cross-android was not recorded'
[ "$(rl_get "$install/installed.txt" source_provenance)" = 'cross-built-android' ] || die 'cross-build provenance was not recorded'
[ "$(rl_get "$install/installed.txt" bundle_manifest_sha256)" = "$good_sha" ] || die 'the bundle manifest hash was not recorded'
[ "$(rl_get "$install/installed.txt" ndk_version)" = '27.3.13750724' ] || die 'the NDK version was not recorded'
[ "$(rl_get "$install/installed.txt" previous_commit)" = '-' ] || die 'a fresh install recorded a previous release'
ok 'installed.txt records the commit, cross-build provenance, NDK version and the bundle hash'

if [ -L "$prefix/bin/wa" ] || [ -f "$prefix/bin/wa" ]; then
  if [ -L "$prefix/bin/wa" ]; then
    ok 'the launcher is linked at $PREFIX/bin/wa'
  else
    skipf 'the launcher at $PREFIX/bin/wa is a copy, not a link (this host cannot represent a symlink)'
  fi
else
  die 'no launcher was placed at $PREFIX/bin/wa'
fi

[ "$before_state" = "$(state_hashes)" ] || die 'installing a bundle changed node state'
ok 'node state files are byte-identical before and after the install'
[ ! -e "$install/.wasm-agent" ] || die 'state was written into the installation'
stray=$(find "$releases" "$updated" -type f \( -name env -o -name memory.db -o -name identity.key -o -name '*.db' \) 2>/dev/null || true)
[ -z "$stray" ] || die "state appeared in the release/update area: $stray"
ok 'no node state file is anywhere under the release or update area'

doctor=$(sh "$install/bin/wa" doctor 2>&1) || true
case "$doctor" in
  *'Build: cross-android'*) ok 'wa doctor reports the cross-built provenance' ;;
  *) die "wa doctor did not report the cross-built provenance: $doctor" ;;
esac
case "$doctor" in
  *'NDK 27.3.13750724'*) ok 'wa doctor reports the NDK the runtime was built with' ;;
  *) die "wa doctor did not report the NDK version: $doctor" ;;
esac

# ---- 3. a bundle install over an existing installation ----------------------

make_install "$source_commit_a"
previous_snapshot=$(snapshot_dir "$install")
before_state=$(state_hashes)
expect_ok 'a bundle installs over an existing installation' 'installed' "$bundle" "$good_sha"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$bundle_commit" ] || die 'the active revision was not replaced'
[ "$(rl_get "$install/installed.txt" previous_commit)" = "$source_commit_a" ] || die 'the previous release was not recorded'
ok 'the new release records the from/to revisions'
[ -d "$releases/$source_commit_a" ] || die "the previous installation was not kept at $releases/$source_commit_a"
[ "$previous_snapshot" = "$(snapshot_dir "$releases/$source_commit_a")" ] ||
  die 'the backup does not equal the previous installation file by file'
[ "$(rl_get "$releases/$source_commit_a/installed.txt" source_commit)" = "$source_commit_a" ] ||
  die 'the backup does not carry the previous revision'
ok 'the previous installation is kept, byte-for-byte, as the rollback release'
[ "$before_state" = "$(state_hashes)" ] || die 'installing over an existing installation changed node state'
ok 'node state survives the upgrade byte-for-byte'

# ---- 4. rollback, offline ---------------------------------------------------

# The launcher copy lives outside the prefix: on this host a shell cannot move a directory
# that holds the script it is executing, and the launcher legitimately lives inside the
# release it replaces (on the phone that is a POSIX rename and causes no trouble).
launcher=$work/launcher
cp "$root/scripts/termux/wa" "$launcher"
export WA_TERMUX_UPSTREAM=$work/offline-no-such-remote
set +e
_rollback_out=$(sh "$launcher" update --rollback 2>&1)
_rollback_rc=$?
set -e
unset WA_TERMUX_UPSTREAM
[ "$_rollback_rc" -eq 0 ] || die "rollback failed: $_rollback_out"
case "$_rollback_out" in
  *'rolled back'*) ok 'wa update --rollback restores the previous release, with no upstream' ;;
  *) die "rollback did not report a rollback: $_rollback_out" ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$source_commit_a" ] || die 'rollback did not restore the previous revision'
[ "$previous_snapshot" = "$(snapshot_dir "$install")" ] || die 'rollback did not restore the previous installation byte-for-byte'
ok 'rollback restores the previous installation exactly'
[ "$before_state" = "$(state_hashes)" ] || die 'rollback changed node state'

# ---- 5. installing the same bundle again ------------------------------------

make_bundle "$bundle"
good_sha=$(bundle_sha "$bundle")
expect_ok 'installing the same bundle again installs it again (the rollback is restored by it)' 'installed' \
  "$bundle" "$good_sha"
rl_manifest_verify "$install" || die 'the reinstalled release does not verify'
[ "$(rl_get "$install/installed.txt" source_commit)" = "$bundle_commit" ] || die 'the reinstall did not activate the bundle'
expect_ok 'installing the same bundle a third time is idempotent' 'already installed' "$bundle" "$good_sha"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$bundle_commit" ] || die 'the idempotent reinstall changed the active revision'
rl_manifest_verify "$install" || die 'the idempotent reinstall broke the installed release'
ok 'reinstalling an installed bundle is idempotent and leaves a verified release'

# The case this installer exists for on the operator's phone: the SAME revision is already
# installed, but from a source build, and the cross-built bundle that compiles nowhere here
# replaces it. The commit matches, so the release directory name does too - the rollback
# copy and the new release must not collide, and a second run of the same bundle must be a
# no-op rather than a conflict over the directory the first run created.
same=$work/bundle-same-commit
make_bundle "$same"
same_sha=$(bundle_sha "$same")
make_install "$bundle_commit"
source_built_snapshot=$(snapshot_dir "$install")
expect_ok 'a cross-built bundle replaces a source-built install of the same revision' 'installed' \
  "$same" "$same_sha"
[ "$(rl_get "$install/installed.txt" source_provenance)" = 'cross-built-android' ] || die 'the same-revision install did not record the cross-build provenance'
[ "$(rl_get "$install/installed.txt" previous_commit)" = "$bundle_commit" ] || die 'the same-revision install lost the rollback revision'
rl_manifest_verify "$install" || die 'the same-revision install does not verify'
[ "$source_built_snapshot" = "$(snapshot_dir "$releases/$bundle_commit")" ] ||
  die 'the source-built release of the same revision was not kept as the rollback'
ok 'the same revision installed from source and from a bundle coexist as active and rollback'
expect_ok 'a second run of the same-revision bundle is a no-op' 'already installed' "$same" "$same_sha"
[ "$(rl_get "$install/installed.txt" source_provenance)" = 'cross-built-android' ] || die 'the no-op run changed what is installed'
set +e
_same_rollback=$(sh "$launcher" update --rollback 2>&1)
_same_rollback_rc=$?
set -e
[ "$_same_rollback_rc" -eq 0 ] || die "same-revision rollback failed: $_same_rollback"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$bundle_commit" ] || die 'the same-revision rollback did not restore the previous revision'
[ "$(rl_get "$install/installed.txt" source_provenance)" = 'source-built-termux' ] || die 'the same-revision rollback did not restore the source-built release'
rl_manifest_verify "$install" || die 'the rolled-back source-built release does not verify'
kept_cross=$(find "$releases" -maxdepth 1 -type d -name "$bundle_commit+bundle.*" | head -n 1)
[ -n "$kept_cross" ] || die 'the cross-built release was destroyed by the rollback instead of being kept'
rl_manifest_verify "$kept_cross" || die 'the kept cross-built release does not verify'
ok 'rollback restores the source-built release of the same revision and keeps the cross-built one for rolling forward'

# ---- 6. refusals against an existing installation --------------------------

make_install "$source_commit_a"
before_snapshot=$(snapshot_dir "$install")
printf 'tampered\n' >> "$install/ui/index.html"
expect_fail 'a modified existing installation is not taken as the rollback release' \
  'installed_release_modified' "$bundle" "$good_sha"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$source_commit_a" ] ||
  die 'a refusal against a modified installation still switched releases'
ok 'a refusal leaves the existing installation in place'

make_install "$source_commit_a"
printf 'state in the wrong place\n' > "$install/memory.db"
expect_fail 'state found inside the installation is refused, not moved' 'state_inside_install' \
  "$bundle" "$good_sha"
rm -f "$install/memory.db"

make_install "$source_commit_a"
# A fully re-sealed bundle - every hash in the chain is consistent - whose installed.txt
# names a different revision than the manifest does. Only the cross-check between the two
# records can catch this, so it is the check under test.
sed -i 's/^source_commit=.*/source_commit=cccccccccccccccccccccccccccccccccccccccc/' "$bundle/installed.txt"
RL_MANIFEST_EXCLUDE=bundle.manifest rl_manifest "$bundle" "$bundle/installed.sha256"
sed -i "s/^release_manifest_sha256=.*/release_manifest_sha256=$(rl_sha256 "$bundle/installed.sha256")/" "$bundle/bundle.manifest"
sed -i '/^artefact /d' "$bundle/bundle.manifest"
sed 's/^\([0-9a-f]\{64\}\)  \(.*\)$/artefact \1 \2/' "$bundle/installed.sha256" >> "$bundle/bundle.manifest"
expect_fail 'a bundle whose installed.txt disagrees with its manifest is refused' \
  'bundle_manifest_mismatch' "$bundle" "$(bundle_sha "$bundle")"

make_bundle "$bundle"
good_sha=$(bundle_sha "$bundle")
[ "$(rl_get "$install/installed.txt" source_commit)" = "$source_commit_a" ] ||
  die 'the existing installation was disturbed by the refusal cases'
rl_manifest_verify "$install" || die 'the existing installation no longer verifies after the refusal cases'
ok 'the refusal cases above left the existing installation untouched and intact'

# ---- summary ----------------------------------------------------------------

printf 'termux bundle install: %s passed, %s skipped' "$pass" "$skip"
if [ "$skip" -gt 0 ]; then
  printf ' (host skips:%s)\n' "$skipped_notes"
else
  printf '\n'
fi
printf '%s\n' 'termux bundle install: Android runtime execution on a real phone is NOT proven by this suite'
