#!/usr/bin/env bash
# `wa update` on the Termux preview, exercised against a private fake upstream and a
# pre-existing installation that carries identity and state.
#
# What this suite can and cannot prove. It runs on a non-Android host, so it cannot build
# an Android runtime, cannot exec an aarch64 ELF, and cannot prove anything about the phone.
# Everything else is real: a real git repository as upstream (so fetch, ancestry and
# refusals are the actual git behaviour), the real launcher, the real updater and the real
# shared library out of this checkout, and the real switch. The probes it must disable are
# the host-only ones (`WA_TERMUX_HOST_PROBES=0`): the candidate is a fabricated aarch64 ELF
# header on this host, so its executable bit cannot be represented here and it cannot be
# run. That skip is counted and printed, never silent.
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

git_c() { git -c user.email=test@example.invalid -c user.name=TermuxUpdateTest "$@"; }

# Every git here, including the clones the updater itself makes, reads LF as committed:
# the Windows default smudge would otherwise rewrite the fake tree on checkout and drown
# the run in warnings.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.autocrlf
export GIT_CONFIG_VALUE_0=false

# ---- a fabricated aarch64 ELF, because no Android toolchain runs here -------

write_binary() { # <path> [abi]
  _p=$1
  _abi=${2:-aarch64}
  if [ "$_abi" = not-elf ]; then printf 'not an elf file\n' > "$_p"; return 0; fi
  case "$_abi" in
    aarch64) _m='\267' ;;
    x86-64) _m='\076' ;;
    *) _m='\001' ;;
  esac
  # e_ident (16 bytes: \x7fELF, class, data, version, osabi, abiversion, 7 pad),
  # e_type (2), e_machine (2) -- written in three pieces so the offsets are countable.
  printf '\177ELF\002\001\001\000' > "$_p"
  printf '\000\000\000\000\000\000\000\000' >> "$_p"
  printf '\002\000' >> "$_p"
  printf "$_m\000" >> "$_p"
  printf 'payload-%s\n' "$_abi" >> "$_p"
}

# ---- the fake upstream: a real git repository -------------------------------

make_source_tree() { # <dir>
  _d=$1
  mkdir -p "$_d/rust" "$_d/scripts/termux" "$_d/ui"
  printf '[package]\nname = "wa"\nversion = "0.0.0"\n' > "$_d/rust/Cargo.toml"
  cp "$root/scripts/termux/wa" "$_d/scripts/termux/wa"
  cp "$root/scripts/termux/wa-update.sh" "$_d/scripts/termux/wa-update.sh"
  cp "$root/scripts/termux/release-lib.sh" "$_d/scripts/termux/release-lib.sh"
  cp "$root/scripts/termux/adopt-existing.sh" "$_d/scripts/termux/adopt-existing.sh"
  cp "$root/scripts/install-termux.sh" "$_d/scripts/install-termux.sh"
  for _a in index.html style.css app.js components.js render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png; do
    printf 'asset %s\n' "$_a" > "$_d/ui/$_a"
  done
  printf 'license text\n' > "$_d/LICENSE"
  # The build writes rust/target; the source tree must ignore it or the updater's
  # 'source changed during build' guard fires on its own build output.
  printf 'rust/target/\n' > "$_d/.gitignore"
}

up=$work/upstream
mkdir -p "$up"
git_c -C "$up" init -q -b main
make_source_tree "$up"
git_c -C "$up" add -A
git_c -C "$up" commit -qm 'revision A'
A=$(git -C "$up" rev-parse HEAD)
printf 'revision B\n' > "$up/MARKER-B"
git_c -C "$up" add -A
git_c -C "$up" commit -qm 'revision B'
B=$(git -C "$up" rev-parse HEAD)
printf 'revision C\n' > "$up/MARKER-C"
git_c -C "$up" add -A
git_c -C "$up" commit -qm 'revision C'
C=$(git -C "$up" rev-parse HEAD)
git_c -C "$up" checkout -q "$B"   # upstream HEAD is B; C exists only for the downgrade probe

# ---- fake cargo -------------------------------------------------------------

fake_cargo=$work/fake-cargo
cat > "$fake_cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
manifest=
for a in "$@"; do manifest=$a; done
[ -n "$manifest" ] || { echo 'fake cargo: no manifest path' >&2; exit 1; }
if [ "${FAKE_CARGO_FAIL:-0}" = 1 ]; then echo 'fake cargo: build error' >&2; exit 1; fi
out=$(dirname "$manifest")/target/release
mkdir -p "$out"
case "${FAKE_CARGO_ABI:-aarch64}" in
  aarch64) m='\267' ;;
  x86-64) m='\076' ;;
  *) m='\001' ;;
esac
printf '\177ELF\002\001\001\000' > "$out/wa"
printf '\000\000\000\000\000\000\000\000' >> "$out/wa"
printf '\002\000' >> "$out/wa"
printf "$m\000" >> "$out/wa"
printf 'payload\n' >> "$out/wa"
SH
chmod +x "$fake_cargo"

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

. "$root/scripts/termux/release-lib.sh"

make_install() { # <commit> <remote> [previous]
  rm -rf "$install"
  mkdir -p "$install/bin" "$install/ui"
  # The installed runtime is a stand-in for the Android binary. On this non-POSIX host a
  # file with a shebang is the only thing that can be executable at all, so the stand-in
  # is a script; the built CANDIDATES are the fabricated aarch64 ELFs, which is where the
  # ABI check is actually exercised.
  printf '#!/usr/bin/env sh\nexit 0\n' > "$install/wa"
  chmod +x "$install/wa"
  cp "$root/scripts/termux/wa" "$install/bin/wa"
  cp "$root/scripts/termux/wa-update.sh" "$install/bin/wa-update"
  cp "$root/scripts/termux/release-lib.sh" "$install/bin/release-lib.sh"
  chmod +x "$install/bin/wa" "$install/bin/wa-update"
  for a in index.html style.css app.js components.js render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png; do
    printf 'asset %s\n' "$a" > "$install/ui/$a"
  done
  printf 'license text\n' > "$install/LICENSE"
  {
    printf 'source_commit=%s\n' "$1"
    printf 'source_remote=%s\n' "$2"
    printf 'installed_utc=2026-10-18T00:00:00Z\n'
    printf 'previous_commit=%s\n' "${3:--}"
    printf 'installed_by=install-termux\n'
    printf 'source_provenance=source-built-termux\n'
  } > "$install/installed.txt"
  rl_paths
  rl_manifest "$install" "$install/installed.sha256"
}

export PREFIX=$prefix
export HOME=$home
export WASM_AGENT_HOME=$home
export WASM_AGENT_INSTALL_ROOT=$install
export WA_TERMUX_INSTALL=$install
export WA_TERMUX_RELEASES=$releases
export WA_TERMUX_UPDATE_DIR=$updated
export WA_TERMUX_CARGO=$fake_cargo
export WA_TERMUX_HOST_PROBES=0

updater="$install/bin/wa-update"
# Every update goes through the launcher, exactly as the operator runs it. The launcher is
# a copy kept OUTSIDE the prefix: on this host a shell cannot move a directory that holds
# the script it is executing, and the launcher legitimately lives inside the release it
# replaces (on the phone that is a POSIX rename and causes no trouble). The copy is
# byte-identical to the installed launcher and the launcher still resolves $WA_TERMUX_INSTALL.
launcher=$work/launcher
cp "$root/scripts/termux/wa" "$launcher"
run_update() { sh "$launcher" update "$@"; }

state_hashes() { sha256sum "$home/.wasm-agent/env" "$home/.wasm-agent/identity.key" "$home/.wasm-agent/memory.db" "$home/workspace/notes.txt"; }

snapshot_install() { ( cd "$install" && find . -type f ! -name installed.sha256 -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done ); }
manifest_of() { ( cd "$1" && find . -type f ! -name installed.sha256 -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done ); }

expect_fail() { # <label> <pattern> <args...>
  _label=$1; _pattern=$2; shift 2
  set +e
  _out=$(run_update "$@" 2>&1)
  _rc=$?
  set -e
  [ "$_rc" -ne 0 ] || die "$_label: expected a refusal, got exit 0: $_out"
  case "$_out" in *"$_pattern"*) ok "$_label: refused with '$_pattern'" ;;
    *) die "$_label: expected '$_pattern' in: $_out" ;;
  esac
}

expect_ok() { # <label> <pattern> <args...>
  _label=$1; _pattern=$2; shift 2
  set +e
  _out=$(run_update "$@" 2>&1)
  _rc=$?
  set -e
  [ "$_rc" -eq 0 ] || die "$_label: expected success, got exit $_rc: $_out"
  case "$_out" in *"$_pattern"*) ok "$_label" ;;
    *) die "$_label: expected '$_pattern' in: $_out" ;;
  esac
}

marker=$work/marker
touch "$marker"
sleep 1

# ---- 1. --check: from/to, read-only, exits 0 --------------------------------

make_install "$A" "$up"
before_hashes=$(state_hashes)
before_install=$(snapshot_install)
before_newer=$(find "$prefix" -newer "$marker" -print | wc -l)
out=$(run_update --check)
case "$out" in
  *"1 update available"*) ok '--check reports an available update' ;;
  *) die "--check did not report an update: $out" ;;
esac
case "$out" in
  *"$(printf '%.12s' "$A")"*"$(printf '%.12s' "$B")"*) ok '--check names both the installed and the upstream revision' ;;
  *) die "--check did not name both revisions: $out" ;;
esac
[ "$before_hashes" = "$(state_hashes)" ] || die '--check changed node state'
[ "$before_install" = "$(snapshot_install)" ] || die '--check changed the installation'
[ ! -e "$updated" ] || die "--check created $updated; it must be read-only"
[ "$before_newer" -eq "$(find "$prefix" -newer "$marker" -print | wc -l)" ] ||
  die '--check created or touched files under the prefix'
ok '--check changed nothing (state, install and prefix all identical)'

# ---- 2. up to date is not an error ------------------------------------------

make_install "$B" "$up"
expect_ok 'up to date exits 0' 'up to date' --check

# ---- 3. update: switches, preserves state, keeps the old release ------------

make_install "$A" "$up"
before_hashes=$(state_hashes)
expect_ok 'update moves A -> B' 'updated' update
[ "$(rl_get "$install/installed.txt" source_commit)" = "$B" ] || die 'installed commit was not updated'
[ "$(rl_get "$install/installed.txt" previous_commit)" = "$A" ] || die 'previous commit was not recorded'
[ "$(rl_get "$install/installed.txt" source_remote)" = "$up" ] || die 'source_remote was not carried forward'
ok 'the new release records the from/to revisions and its upstream'
[ -d "$releases/$A" ] || die "the previous release was not kept at $releases/$A"
[ -f "$releases/$A/ui/index.html" ] || die 'the kept release is incomplete'
ok 'the previous release is kept for rollback'
[ "$before_hashes" = "$(state_hashes)" ] || die 'update changed node state'
ok 'node state files survive update byte-for-byte'
[ ! -e "$install/.wasm-agent" ] || die 'state was written into the installation'
stray=$(find "$releases" "$updated" -type f \( -name env -o -name memory.db -o -name identity.key -o -name '*.db' \) 2>/dev/null || true)
[ -z "$stray" ] || die "state appeared in the release/staging area: $stray"
want=$(sha256sum "$home/.wasm-agent/env" | cut -d' ' -f1)
found=$(find "$releases" "$updated" -type f -exec sha256sum {} + 2>/dev/null | grep -c "$want" || true)
[ "$found" -eq 0 ] || die 'a file with the state env content exists under the release/staging area'
ok 'no node state file — or a copy of one — is anywhere in the release or staging area'
[ -f "$install/installed.sha256" ] || die 'the active release has no manifest'
rl_paths; rl_manifest_verify "$install" || die 'the active release does not match its own manifest'
ok 'the switched-in release is complete and matches its own manifest'

# ---- 4. rollback restores the previous release ------------------------------

# An unreachable upstream is exported deliberately: rollback must not need the network at
# all, because a failed update is exactly when the operator needs it.
export WA_TERMUX_UPSTREAM=$work/offline-no-such-remote
expect_ok 'rollback restores A, and does not need the upstream' 'rolled back' --rollback
unset WA_TERMUX_UPSTREAM
[ "$(rl_get "$install/installed.txt" source_commit)" = "$A" ] || die 'rollback did not restore the previous revision'
[ "$before_hashes" = "$(state_hashes)" ] || die 'rollback changed node state'
ok 'rollback restores the previous revision and leaves state alone'

# ---- 5. refusals ------------------------------------------------------------

make_install "$A" "$up"
printf 'tampered\n' >> "$install/ui/index.html"
expect_fail 'a modified installed release is refused' 'installed_release_modified' --check

make_install "$A" "$up"
sed -i 's/^source_remote=.*/source_remote=/' "$install/installed.txt"
rl_paths; rl_manifest "$install" "$install/installed.sha256"
expect_fail 'an unknown upstream is refused' 'upstream_unknown' --check

make_install "$A" "$up"
sed -i "s|^source_remote=.*|source_remote=$work/does-not-exist|" "$install/installed.txt"
rl_paths; rl_manifest "$install" "$install/installed.sha256"
expect_fail 'an unreachable upstream is refused' 'upstream_unreachable' --check

# installed = C, upstream points at B (an ancestor): a downgrade
make_install "$C" "$up"
expect_fail 'a downgrade is refused' 'downgrade_or_divergent' update --ref "$B"

# installed revision is not in upstream at all
make_install '0123456789abcdef0123456789abcdef01234567' "$up"
expect_fail 'an unknown installed revision is refused' 'installed_revision_unknown_to_upstream' update

# wrong ABI
export FAKE_CARGO_ABI=x86-64
make_install "$A" "$up"
expect_fail 'a wrong-ABI build is refused' 'wrong_abi' update
[ "$(rl_get "$install/installed.txt" source_commit)" = "$A" ] || die 'a refused update still switched'
ok 'a refused update leaves the installed revision in place'
unset FAKE_CARGO_ABI

# failed build
export FAKE_CARGO_FAIL=1
make_install "$A" "$up"
expect_fail 'a failed build is refused' 'build_failed' update
[ "$(rl_get "$install/installed.txt" source_commit)" = "$A" ] || die 'a failed build still switched'
ok 'a failed build leaves the installed revision in place'
unset FAKE_CARGO_FAIL

# a concurrent run
make_install "$A" "$up"
mkdir -p "$updated" "$updated/lock"
expect_fail 'a concurrent update is refused' 'update_in_progress' update
rmdir "$updated/lock"

# a half-built release left behind
make_install "$A" "$up"
mkdir -p "$releases/$B"
printf 'garbage\n' > "$releases/$B/junk"
expect_fail 'a leftover non-verifying release is refused' 'interrupted_release_present' update
rm -rf "$releases/$B"

# An interrupted switch: the active path is gone, and with it the launcher, so the normal
# `wa update` cannot run. It is repaired out of band, from the checkout.
make_install "$A" "$up"
mkdir -p "$releases" "$updated"
cp -a "$install" "$releases/$A"
rl_manifest "$releases/$A" "$releases/$A/installed.sha256"
printf '%s %s\n' "$A" "$B" > "$updated/switch.intent"
rm -rf "$install"
set +e
recover_out=$(WA_TERMUX_TEST=1 bash "$root/scripts/install-termux.sh" --recover 2>&1)
recover_rc=$?
set -e
[ "$recover_rc" -eq 0 ] || die "--recover failed: $recover_out"
case "$recover_out" in *'recovered an interrupted switch'*) ok 'an interrupted switch is detected and the previous release restored' ;;
  *) die "recovery did not run: $recover_out" ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$A" ] || die 'recovery did not restore the active release'
ok 'the recovered install names the release that was active before the switch'

# ---- 6. the launcher delegates `wa update` ----------------------------------

make_install "$A" "$up"
launcher_out=$(sh "$install/bin/wa" update --check)
case "$launcher_out" in *'1 update available'*) ok 'wa update --check is served by the launcher' ;;
  *) die "the launcher did not serve 'update': $launcher_out" ;;
esac
launcher_help=$(sh "$install/bin/wa" help)
case "$launcher_help" in *'wa update'*) ok 'wa help names the update command' ;;
  *) die 'wa help does not name the update command' ;;
esac
# an install from before this revision has no updater, and is told exactly what to run
make_install "$A" "$up"
rm -f "$install/bin/wa-update"
rl_paths; rl_manifest "$install" "$install/installed.sha256"
set +e
legacy_out=$(sh "$install/bin/wa" update 2>&1)
legacy_rc=$?
set -e
[ "$legacy_rc" -ne 0 ] || die 'a pre-updater install accepted wa update'
case "$legacy_out" in *'updater_missing'*'--adopt-existing'*) ok 'a pre-updater install is directed to the one-time bootstrap' ;;
  *) die "the legacy install was not directed to the bootstrap: $legacy_out" ;;
esac

# ---- 7. the one-time bootstrap ----------------------------------------------

checkout=$work/checkout
git -c advice.detachedHead=false clone -q "$up" "$checkout"
git -c advice.detachedHead=false -C "$checkout" checkout -q "$B"
git_c -C "$checkout" remote set-url origin "$up"

# Run the SHIPPED bootstrap, but out of the clone, so it resolves its own root to the
# clone and the fake build never writes into this checkout.
adopt() { WA_TERMUX_TEST=1 bash "$checkout/scripts/termux/adopt-existing.sh" "$@"; }

# no existing installation
rm -rf "$install"
set +e
adopt_out=$(adopt 2>&1)
adopt_rc=$?
set -e
[ "$adopt_rc" -ne 0 ] || die 'adopt accepted a machine with no installation'
case "$adopt_out" in *'no_existing_installation'*) ok 'bootstrap refuses with no existing installation' ;;
  *) die "unexpected adopt output: $adopt_out" ;;
esac

# an installation with no installed.txt: the exact missing fact is named
make_install "$A" "$up"
rm -f "$install/installed.txt"
set +e
adopt_out=$(adopt 2>&1)
adopt_rc=$?
set -e
[ "$adopt_rc" -ne 0 ] || die 'adopt accepted an installation with no metadata'
case "$adopt_out" in *"installed_metadata_missing: $install/installed.txt"*) ok 'bootstrap names the missing metadata file exactly' ;;
  *) die "unexpected adopt output: $adopt_out" ;;
esac

# state found inside the install directory: refuse, never move it
make_install "$A" "$up"
mkdir -p "$install/.wasm-agent"
printf 'secret\n' > "$install/.wasm-agent/env"
set +e
adopt_out=$(adopt 2>&1)
adopt_rc=$?
set -e
[ "$adopt_rc" -ne 0 ] || die 'adopt accepted state inside the installation'
case "$adopt_out" in *"state_inside_install: $install/.wasm-agent"*) ok 'bootstrap refuses state inside the install directory' ;;
  *) die "unexpected adopt output: $adopt_out" ;;
esac
rm -rf "$install/.wasm-agent"

# a dirty checkout
make_install "$A" "$up"
before_hashes=$(state_hashes)
printf 'dirty\n' >> "$checkout/ui/app.js"
set +e
adopt_out=$(adopt 2>&1)
adopt_rc=$?
set -e
[ "$adopt_rc" -ne 0 ] || die 'adopt accepted a dirty checkout'
case "$adopt_out" in *'dirty_source'*) ok 'bootstrap refuses a dirty checkout' ;;
  *) die "unexpected adopt output: $adopt_out" ;;
esac
git -C "$checkout" checkout -q -- ui/app.js

# the real thing: adopt A -> B
rm -rf "$releases" "$updated"
make_install "$A" "$up"
before_release=$(snapshot_install)
set +e
adopt_out=$(adopt --upstream "$up" 2>&1)
adopt_rc=$?
set -e
[ "$adopt_rc" -eq 0 ] || die "adopt failed: $adopt_out"
case "$adopt_out" in *'adopted'*) ok 'bootstrap adopts the existing install' ;;
  *) die "unexpected adopt output: $adopt_out" ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$B" ] || die 'adopt did not install the checkout revision'
[ "$(rl_get "$install/installed.txt" previous_commit)" = "$A" ] || die 'adopt did not record the previous revision'
[ "$(rl_get "$install/installed.txt" source_remote)" = "$up" ] || die 'adopt did not record the upstream'
ok 'adopt records the from/to revisions and the upstream'
[ "$before_release" = "$(manifest_of "$releases/$A")" ] ||
  die 'the backup of the old install is not byte-for-byte the old install'
ok 'the bootstrap backup is byte-for-byte the previous installation'
[ "$before_hashes" = "$(state_hashes)" ] || die 'adopt changed node state'
ok 'node state survives the bootstrap byte-for-byte'
verify_out=$(run_update --check)
case "$verify_out" in *'up to date'*) ok 'after the bootstrap, wa update works and reports up to date' ;;
  *) die "after adopt, wa update --check said: $verify_out" ;;
esac

if [ "$(uname -s)" = MINGW64_NT-10.0 ] || [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]]; then
  skipf "already_adopted (a managed release link) — this host cannot create symlinks"
fi

printf '%s\n' "termux update: $pass passed, $skip skipped"
if [ -n "$skipped_notes" ]; then
  printf '%s\n' '  skipped:'
  printf '%s\n' "$skipped_notes"
fi
