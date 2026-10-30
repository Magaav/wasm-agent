#!/usr/bin/env bash
# `wa update` fetching a PUBLISHED RELEASE: the index, the download, the hash refusal, and
# the loud build fallback.
#
# What this suite can and cannot prove. It runs with NO NETWORK: the release index and the
# release asset are real files, served through `file://` URLs, with
# WA_TERMUX_RELEASE_ALLOW_LOCAL=1 opting into a local asset (the production channel is
# HTTPS, and a file: URL is refused without that opt-in - case 2 proves it). Everything else
# is real: the real updater (`bin/wa-update`) and the real shared library out of this
# checkout, a real tar.gz written the way `cross-build-android.sh` writes it, a real bundle
# whose hash chain is real, the real installer (`rl_bundle_install`), real backups and the
# real two-rename switch. Because this host is not Android, the fabricated "runtime" is an
# aarch64 ELF header plus a payload: it cannot be executed here, so the candidate probe is
# disabled (WA_TERMUX_HOST_PROBES=0) and that skip is counted and printed, never silent. A
# real Android runtime starting on a real phone, and a real HTTPS download, are NOT proven
# here - the coordinator's device run is where those are proven.
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
  printf '\177ELF\002\001\001\000' > "$_p"
  printf '\000\000\000\000\000\000\000\000' >> "$_p"
  printf '\002\000' >> "$_p"
  printf "$_m\000" >> "$_p"
  printf 'payload-%s\n' "$_abi" >> "$_p"
}

# ---- a real bundle, shaped exactly like cross-build-android.sh writes one ---

. "$root/scripts/termux/release-lib.sh"
RL_MANIFEST_EXCLUDE=bundle.manifest
rl_paths

remote=https://example.invalid/wasm-agent.git
commit_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
commit_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
commit_c=cccccccccccccccccccccccccccccccccccccccc

make_bundle() { # <dir> <commit>
  _d=$1
  _c=$2
  rm -rf "$_d"
  mkdir -p "$_d/bin" "$_d/ui"
  write_binary "$_d/wa" aarch64
  chmod +x "$_d/wa"
  cp "$root/scripts/termux/wa" "$_d/bin/wa"
  cp "$root/scripts/termux/wa-update.sh" "$_d/bin/wa-update"
  cp "$root/scripts/termux/release-lib.sh" "$_d/bin/release-lib.sh"
  chmod +x "$_d/bin/wa" "$_d/bin/wa-update"
  for _a in $RL_UI_ASSETS; do
    printf 'asset %s\n' "$_a" > "$_d/ui/$_a"
  done
  printf 'license text\n' > "$_d/LICENSE"
  {
    printf 'source_commit=%s\n' "$_c"
    printf 'source_remote=%s\n' "$remote"
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
    printf 'target_triple=aarch64-linux-android\n'
    printf 'elf_machine=aarch64\n'
    printf 'android_api=21\n'
    printf 'build_profile=cross-android\n'
    printf 'source_provenance=cross-built-android\n'
    printf 'source_commit=%s\n' "$_c"
    printf 'source_tree_sha256=tttttttttttttttttttttttttttttttttttttttt\n'
    printf 'source_remote=%s\n' "$remote"
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

# Pack it the way cross-build-android.sh does: one top directory, the bundle inside it.
pack_bundle() { # <bundle_dir> <out_tar_gz>
  _stage=$(mktemp -d "$work/pack.XXXXXX")
  mkdir -p "$_stage/wa-android-bundle"
  cp -a "$1" "$_stage/wa-android-bundle/bundle"
  ( cd "$_stage" && tar -czf "$2" wa-android-bundle )
  rm -rf "$_stage"
}

# ---- the index -------------------------------------------------------------

entry_json() { # <commit> <manifest_sha256> <url> <size> [target]
  _t=${5:-aarch64-linux-android}
  printf '    {\n'
  printf '      "commit": "%s",\n' "$1"
  printf '      "commit_short": "%s",\n' "$(printf '%.12s' "$1")"
  printf '      "manifest_sha256": "%s",\n' "$2"
  printf '      "url": "%s",\n' "$3"
  printf '      "size": %s,\n' "$4"
  printf '      "target": "%s",\n' "$_t"
  printf '      "ndk": "27.3.13750724",\n'
  printf '      "rustc": "1.98.1 (48a229cea 2026-09-01)",\n'
  printf '      "built_utc": "2026-10-19T00:00:00Z"\n'
  printf '    }'
}

write_index() { # <out> [entry_json_string...]
  _out=$1
  shift
  {
    printf '{\n'
    printf '  "schema": "wasm-agent-release-index",\n'
    printf '  "schema_version": 1,\n'
    printf '  "doc": "docs/release/RELEASE_INDEX.md",\n'
    printf '  "trust_chain": [\n'
    printf '    "fixture index: the real format, one entry per released bundle"\n'
    printf '  ],\n'
    printf '  "releases": [\n'
    _first=1
    for _e in "$@"; do
      [ "$_first" = 1 ] || printf ',\n'
      _first=0
      printf '%s' "$_e"
    done
    printf '\n  ]\n'
    printf '}\n'
  } > "$_out"
}

# ---- a node: a prefix, a home with state, an installed release --------------

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

source_commit_x=dddddddddddddddddddddddddddddddddddddddd
make_install() { # <commit> [remote]
  rm -rf "$install"
  mkdir -p "$install/bin" "$install/ui"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$install/wa"
  chmod +x "$install/wa"
  cp "$root/scripts/termux/wa" "$install/bin/wa"
  cp "$root/scripts/termux/wa-update.sh" "$install/bin/wa-update"
  cp "$root/scripts/termux/release-lib.sh" "$install/bin/release-lib.sh"
  chmod +x "$install/bin/wa" "$install/bin/wa-update"
  for _a in $RL_UI_ASSETS; do
    printf 'asset %s\n' "$_a" > "$install/ui/$_a"
  done
  printf 'license text\n' > "$install/LICENSE"
  {
    printf 'source_commit=%s\n' "$1"
    printf 'source_remote=%s\n' "${2:-$remote}"
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
# The fixture suite serves REAL bundles from file:// URLs; the production channel is HTTPS.
export WA_TERMUX_RELEASE_ALLOW_LOCAL=1
export WA_TERMUX_RELEASE_INDEX_URL="file://$work/index.json"

# The launcher is a copy kept OUTSIDE the prefix: on this host a shell cannot move the
# directory that holds the script it is executing, and on the phone that is a POSIX rename.
launcher=$work/launcher
cp "$root/scripts/termux/wa" "$launcher"
run_update() { sh "$launcher" update "$@"; }

state_hashes() { sha256sum "$home/.wasm-agent/env" "$home/.wasm-agent/identity.key" "$home/.wasm-agent/memory.db" "$home/workspace/notes.txt"; }
snapshot_install() { ( cd "$1" && find . -type f ! -name installed.sha256 -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done ); }

expect_fail() { # <label> <pattern> <args...>
  _label=$1
  _pattern=$2
  shift 2
  set +e
  _out=$(run_update "$@" 2>&1)
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
  _out=$(run_update "$@" 2>&1)
  _rc=$?
  set -e
  [ "$_rc" -eq 0 ] || die "$_label: expected success, got exit $_rc: $_out"
  case "$_out" in
    *"$_pattern"*) ok "$_label" ;;
    *) die "$_label: expected '$_pattern' in: $_out" ;;
  esac
}

expect_out_has() { # <label> <pattern> <output>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) die "$1: expected '$2' in: $3" ;;
  esac
}

expect_out_lacks() { # <label> <pattern> <output>
  case "$3" in
    *"$2"*) die "$1: '$2' must NOT appear in: $3" ;;
    *) ok "$1" ;;
  esac
}

# ---- the released bundle for commit B, and its index -----------------------

bundle_b=$work/bundle-b
make_bundle "$bundle_b" "$commit_b"
asset_b=$work/wa-android-bundle-bbbbbbbbbbbb.tar.gz
pack_bundle "$bundle_b" "$asset_b"
sha_b=$(rl_sha256 "$bundle_b/bundle.manifest")
size_b=$(wc -c < "$asset_b" | tr -d ' ')

bundle_a=$work/bundle-a
make_bundle "$bundle_a" "$commit_a"
asset_a=$work/wa-android-bundle-aaaaaaaaaaaa.tar.gz
pack_bundle "$bundle_a" "$asset_a"
sha_a=$(rl_sha256 "$bundle_a/bundle.manifest")
size_a=$(wc -c < "$asset_a" | tr -d ' ')

entry_b=$(entry_json "$commit_b" "$sha_b" "file://$asset_b" "$size_b")
entry_a=$(entry_json "$commit_a" "$sha_a" "file://$asset_a" "$size_a")
write_index "$work/index.json" "$entry_b" "$entry_a"

# ---- 1. --check reports the index and the channel it would use -------------

make_install "$source_commit_x"
before_hashes=$(state_hashes)
before_install=$(snapshot_install "$install")
set +e
check_out=$(run_update --check 2>&1)
check_rc=$?
set -e
[ "$check_rc" -eq 0 ] || die "--check failed: $check_out"
expect_out_has '--check names the release index it used' "index      file://$work/index.json" "$check_out"
expect_out_has '--check reports the newest release and its build facts' "$(printf '%.12s' "$commit_b")" "$check_out"
expect_out_has '--check says which channel it would use' 'channel it would use: fetch-prebuilt' "$check_out"
expect_out_has '--check reports the available update' '1 update available' "$check_out"
[ "$before_hashes" = "$(state_hashes)" ] || die '--check changed node state'
[ "$before_install" = "$(snapshot_install "$install")" ] || die '--check changed the installation'
[ ! -e "$updated" ] || die "--check created $updated; it must be read-only"
ok '--check is read-only (state, install and update area untouched)'

# ---- 2. the index is parsed, and a file: asset needs the explicit opt-in ---

set +e
noopt_out=$(env -u WA_TERMUX_RELEASE_ALLOW_LOCAL sh "$launcher" update --check 2>&1)
noopt_rc=$?
set -e
[ "$noopt_rc" -ne 0 ] || die 'a file: index was accepted without WA_TERMUX_RELEASE_ALLOW_LOCAL'
case "$noopt_out" in
  *index_unreachable*|*index_invalid*) ok 'a file: URL is refused unless the fixture opt-in is set' ;;
  *) die "expected a local-URL refusal, got: $noopt_out" ;;
esac

bad=$work/index-bad.json
printf '{"schema": "wasm-agent-release-index", "releases": [}\n' > "$bad"
expect_fail 'a malformed index is refused by name' 'index_invalid' --check --index "file://$bad"

missing_index=$work/no-such-index.json
expect_fail 'an unreachable index is refused by name' 'index_unreachable' --check --index "file://$missing_index"

wrong_schema=$work/index-wrong-schema.json
sed 's/"schema_version": 1/"schema_version": 2/' "$work/index.json" > "$wrong_schema"
expect_fail 'an index for another schema version is refused' 'index_invalid' --check --index "file://$wrong_schema"

[ "$before_hashes" = "$(state_hashes)" ] || die 'an index refusal changed node state'
[ "$before_install" = "$(snapshot_install "$install")" ] || die 'an index refusal changed the installation'
ok 'the index refusals above changed nothing'

# ---- 3. no curl and no wget: http_client_missing, from an https index ------

bare=$work/bare-path
make_bare_path() { # <dir> <excluded command>...
  _d=$1
  shift
  rm -rf "$_d"
  mkdir -p "$_d"
  for _c in sh sed grep cut head tail tr wc cp mv rm mkdir chmod install mktemp \
            sha256sum od find sort cmp date uname tar cat dirname basename ls touch ln env id; do
    _skip=0
    for _x in "$@"; do [ "$_c" = "$_x" ] && _skip=1; done
    [ "$_skip" = 1 ] && continue
    _real=$(command -v "$_c" 2>/dev/null || true)
    [ -n "$_real" ] || continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$_real" > "$_d/$_c"
    chmod +x "$_d/$_c"
  done
}
make_bare_path "$bare" curl wget
[ ! -e "$bare/curl" ] || die 'the bare PATH still has curl'
[ ! -e "$bare/wget" ] || die 'the bare PATH still has wget'
set +e
noclient_out=$(env PATH="$bare" WA_TERMUX_RELEASE_INDEX_URL=https://example.invalid/releases/index.json \
  sh "$launcher" update --check 2>&1)
noclient_rc=$?
set -e
[ "$noclient_rc" -ne 0 ] || die 'an update ran with no http client'
expect_out_has "with neither curl nor wget the refusal is http_client_missing" 'http_client_missing' "$noclient_out"
[ "$before_hashes" = "$(state_hashes)" ] || die 'the http_client_missing refusal changed node state'
ok 'the http_client_missing refusal changed nothing'

# ---- 4. the real thing: fetch the published release for B ------------------

make_install "$source_commit_x"
before_hashes=$(state_hashes)
set +e
update_out=$(run_update 2>&1)
update_rc=$?
set -e
[ "$update_rc" -eq 0 ] || die "the published release did not install: $update_out"
expect_out_has 'the update says which channel it used' 'channel    fetch-prebuilt' "$update_out"
expect_out_has 'the update names the pinned hash from the index' "$sha_b" "$update_out"
expect_out_has 'the update reports the revision it moved to' 'updated dddddddddddd -> bbbbbbbbbbbb' "$update_out"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$commit_b" ] || die 'the published release was not activated'
[ "$(rl_get "$install/installed.txt" source_provenance)" = 'cross-built-android' ] || die 'the cross-built provenance was not recorded'
[ "$(rl_get "$install/installed.txt" bundle_manifest_sha256)" = "$sha_b" ] || die 'the bundle hash was not recorded'
[ "$(rl_get "$install/installed.txt" previous_commit)" = "$source_commit_x" ] || die 'the previous release was not recorded'
rl_manifest_verify "$install" || die 'the installed release does not verify'
ok 'the fetched bundle is installed, verified and records its provenance and rollback'

[ -d "$releases/$source_commit_x" ] || die 'the previous release was not kept'
[ "$(rl_get "$releases/$source_commit_x/installed.txt" source_commit)" = "$source_commit_x" ] || die 'the kept release is not the previous revision'
rl_manifest_verify "$releases/$source_commit_x" || die 'the kept release does not verify'
ok 'the previous release is kept, verified, as the rollback target'

[ "$before_hashes" = "$(state_hashes)" ] || die 'the update changed node state'
[ ! -e "$install/.wasm-agent" ] || die 'state was written into the release'
stray=$(find "$releases" "$updated" -type f \( -name env -o -name memory.db -o -name identity.key \) 2>/dev/null || true)
[ -z "$stray" ] || die "node state appeared in the release/update area: $stray"
ok 'node state is byte-identical everywhere and is inside no release'

expect_ok 'a second --check reports up to date' 'channel it would use: fetch-prebuilt' --check
set +e
again_out=$(run_update 2>&1)
again_rc=$?
set -e
[ "$again_rc" -eq 0 ] || die "the idempotent run failed: $again_out"
expect_out_has 'a second update of the same release changes nothing' 'already up to date' "$again_out"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$commit_b" ] || die 'the idempotent run changed the revision'
ok 'running the same release twice is a no-op'

set +e
rollback_out=$(run_update --rollback 2>&1)
rollback_rc=$?
set -e
[ "$rollback_rc" -eq 0 ] || die "rollback failed: $rollback_out"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$source_commit_x" ] || die 'rollback did not restore the previous release'
ok 'wa update --rollback restores the previous release offline'

# ---- 5. --commit picks one entry, not just the newest ----------------------

make_install "$source_commit_x"
set +e
commit_out=$(run_update --check --commit "$commit_a" 2>&1)
commit_rc=$?
set -e
[ "$commit_rc" -eq 0 ] || die "--check --commit failed: $commit_out"
expect_out_has '--commit selects the entry for that commit' 'channel it would use: fetch-prebuilt (aaaaaaaaaaaa is published' "$commit_out"
set +e
commit_update=$(run_update --commit "$commit_a" 2>&1)
commit_update_rc=$?
set -e
[ "$commit_update_rc" -eq 0 ] || die "--commit update failed: $commit_update"
[ "$(rl_get "$install/installed.txt" source_commit)" = "$commit_a" ] || die '--commit did not install the requested revision'
[ "$(rl_get "$install/installed.txt" bundle_manifest_sha256)" = "$sha_a" ] || die '--commit installed the wrong bundle'
ok '--commit installs the requested release, older than the newest one'

# ---- 6. a hash mismatch is refused, named, and never becomes a build -------

make_install "$source_commit_x"
before_install=$(snapshot_install "$install")
before_hashes=$(state_hashes)
wrong=$work/index-wrong-hash.json
write_index "$wrong" "$(entry_json "$commit_b" 0000000000000000000000000000000000000000000000000000000000000000 "file://$asset_b" "$size_b")"
set +e
mismatch_out=$(run_update --index "file://$wrong" 2>&1)
mismatch_rc=$?
set -e
[ "$mismatch_rc" -ne 0 ] || die 'a hash mismatch was accepted'
expect_out_has 'a hash mismatch is refused as hash_mismatch' 'hash_mismatch' "$mismatch_out"
expect_out_has 'the hash_mismatch refusal says nothing was installed' 'nothing was installed' "$mismatch_out"
expect_out_lacks 'a hash mismatch does NOT fall back to building' 'fallback: build on this device' "$mismatch_out"
expect_out_lacks 'a hash mismatch does not claim a crate crash' 'compiler_crash_build_refused' "$mismatch_out"
[ "$before_install" = "$(snapshot_install "$install")" ] || die 'a hash mismatch changed the installation'
[ "$(rl_get "$install/installed.txt" source_commit)" = "$source_commit_x" ] || die 'a hash mismatch switched releases'
[ "$before_hashes" = "$(state_hashes)" ] || die 'a hash mismatch changed node state'
ok 'a hash mismatch leaves the installation and node state untouched'

# ---- 7. a truncated download is refused, named -----------------------------

truncated=$work/index-truncated.json
write_index "$truncated" "$(entry_json "$commit_b" "$sha_b" "file://$asset_b" $((size_b + 500)))"
before_install=$(snapshot_install "$install")
expect_fail 'a short download is refused as download_truncated' 'download_truncated' --index "file://$truncated"
[ "$before_install" = "$(snapshot_install "$install")" ] || die 'a truncated download changed the installation'
ok 'a truncated download leaves the installation untouched'

# ---- 8. an unsafe archive is refused before it is unpacked -----------------

evil_src=$work/evil
mkdir -p "$evil_src"
printf 'payload\n' > "$evil_src/wa-android-bundle"
( cd "$evil_src" && tar -czf "$work/evil.tar.gz" --transform 's|^wa-android-bundle$|../../escape|' wa-android-bundle ) 2>/dev/null ||
  ( cd "$evil_src" && tar -czf "$work/evil.tar.gz" wa-android-bundle )
evil_size=$(wc -c < "$work/evil.tar.gz" | tr -d ' ')
evil_index=$work/index-evil.json
write_index "$evil_index" "$(entry_json "$commit_b" "$sha_b" "file://$work/evil.tar.gz" "$evil_size")"
if tar -tzf "$work/evil.tar.gz" | grep -q '\.\./'; then
  expect_fail 'an archive that escapes its directory is refused' 'archive_unsafe' --index "file://$evil_index"
else
  skipf 'this tar cannot write a ../ member, so archive_unsafe is not exercised here'
fi

# ---- 9. no release for the commit: the LOUD build fallback -----------------

missing_index=$work/index-other-commit.json
write_index "$missing_index" "$entry_b"
set +e
fallback_check=$(run_update --check --commit "$commit_c" --index "file://$missing_index" 2>&1)
fallback_check_rc=$?
set -e
[ "$fallback_check_rc" -eq 0 ] || die "--check in the fallback case failed: $fallback_check"
expect_out_has '--check names the commit it was asked for' "NO release is published for $(printf '%.12s' "$commit_c")" "$fallback_check"
expect_out_has '--check says it would build on the device' 'channel it would use: source-build on this device' "$fallback_check"
expect_out_has '--check warns that the device cannot compile' 'this device cannot compile this workspace' "$fallback_check"

make_install "$source_commit_x"
before_install=$(snapshot_install "$install")
export WA_TERMUX_UPSTREAM=$work/offline-no-such-remote
set +e
fallback_out=$(run_update --commit "$commit_c" --index "file://$missing_index" 2>&1)
fallback_rc=$?
set -e
unset WA_TERMUX_UPSTREAM
[ "$fallback_rc" -ne 0 ] || die 'the build fallback unexpectedly succeeded'
expect_out_has 'the fallback warns loudly that no release exists for the commit' "WARNING: no published release for $(printf '%.12s' "$commit_c")" "$fallback_out"
expect_out_has 'the fallback says the device cannot compile this workspace' 'THIS DEVICE CANNOT COMPILE THIS WORKSPACE' "$fallback_out"
expect_out_has 'the fallback names the measured crash' 'SIGSEGV' "$fallback_out"
expect_out_has 'the fallback points at the released channel' 'docs/release/RELEASE_INDEX.md' "$fallback_out"
expect_out_has 'the fallback reaches the build rung (and fails there, offline)' 'fetch_failed' "$fallback_out"
[ "$before_install" = "$(snapshot_install "$install")" ] || die 'the failed fallback changed the installation'
[ "$(rl_get "$install/installed.txt" source_commit)" = "$source_commit_x" ] || die 'the failed fallback switched releases'
ok 'a failed build fallback installs nothing and leaves the installation alone'

# ---- 10. the bootstrap (empty) index is valid, and says so -----------------

empty_index=$work/index-empty.json
write_index "$empty_index"
set +e
empty_check=$(run_update --check --commit "$commit_b" --index "file://$empty_index" 2>&1)
empty_check_rc=$?
set -e
[ "$empty_check_rc" -eq 0 ] || die "an empty index should still be readable: $empty_check"
expect_out_has 'an empty index parses as the bootstrap state' '0 releases: this is the bootstrap index' "$empty_check"
ok 'the committed bootstrap state (releases: []) is a valid index'

# ---- 11. the repository's own index is valid as committed --------------------
# It was the bootstrap state (releases: []) until a63076f4/6b04dfc1 published the first Android bundles;
# what must hold for every committed state is that a phone's updater reads it, with every entry complete
# (6b04dfc1's entry had no built_utc, so every phone got index_invalid - found 30/10).

repo_index=$root/releases/index.json
[ -f "$repo_index" ] || die 'releases/index.json is not committed'
set +e
repo_out=$(run_update --check --commit "$commit_b" --index "file://$repo_index" 2>&1)
repo_rc=$?
set -e
repo_count=$(grep -c '"manifest_sha256"' "$repo_index" || true)
if [ "$repo_count" = 0 ]; then
  expect_out_has 'the committed index carries its schema version' '0 releases' "$repo_out"
else
  expect_out_has 'the committed index is read whole by the updater' "$repo_count release(s); newest" "$repo_out"
fi
case "$repo_out" in *index_invalid*) die "the committed index is refused by the updater: $repo_out" ;; esac
grep -q '"schema_version": 1' "$repo_index" || die 'the committed index has no schema_version 1'
grep -q '"schema": "wasm-agent-release-index"' "$repo_index" || die 'the committed index has no schema name'
grep -q '"trust_chain"' "$repo_index" || die 'the committed index does not document its trust chain'
ok 'releases/index.json is the documented bootstrap index'

# ---- summary ----------------------------------------------------------------

printf 'termux release fetch: %s passed, %s skipped' "$pass" "$skip"
if [ "$skip" -gt 0 ]; then
  printf ' (host skips:%s)\n' "$skipped_notes"
else
  printf '\n'
fi
printf '%s\n' 'termux release fetch: NO NETWORK was used; a real HTTPS download and a real Android runtime on a real phone are NOT proven by this suite'
