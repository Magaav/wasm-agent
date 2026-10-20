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
  cp "$root/scripts/termux/bootstrap.sh" "$_d/scripts/termux/bootstrap.sh"
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

# Which cargo profile this invocation is: `--profile dev` is the third rung of the build
# ladder (the debug/unoptimized build), everything else is `--release`. The output directory
# follows cargo: the `dev` profile writes target/debug, the release one target/release - and
# the payload records the profile, so a fixture can assert which rung's binary was installed.
mode=release
outdir=release
case " $* " in *" --profile dev "*) mode=dev; outdir=debug ;; esac

# How many times this fake compiler has been asked to build, so a fixture can crash the
# first attempt and succeed on the retry. And what the build handed it, so a fixture can
# assert the profile rather than guess at it.
attempt=1
if [ -n "${FAKE_CARGO_STATE:-}" ]; then
  if [ -f "$FAKE_CARGO_STATE" ]; then attempt=$(( $(cat "$FAKE_CARGO_STATE") + 1 )); fi
  printf '%s\n' "$attempt" > "$FAKE_CARGO_STATE"
fi
if [ -n "${FAKE_CARGO_RECORD:-}" ]; then
  printf 'attempt=%s jobs=%s stack=%s flags=%s incremental=%s argv=%s\n' "$attempt" \
    "${CARGO_BUILD_JOBS:-}" "${RUST_MIN_STACK:-}" "${RUSTFLAGS:-}" "${CARGO_INCREMENTAL:-}" "$*" \
    >> "$FAKE_CARGO_RECORD"
fi

# The phone failure in the shape cargo reports it: rustc killed by a signal, `process
# didn't exit successfully`, exit status 101 - and no Rust diagnostic at all. cargo prints the
# rustc command line it ran on the way, which is where the crate name comes from, and the
# last crate in the log is the one rustc was compiling when it died.
crash=0
if [ -n "${FAKE_CARGO_CRASH_ATTEMPTS:-}" ]; then
  case ",${FAKE_CARGO_CRASH_ATTEMPTS}," in
    *",$attempt,"*) crash=1 ;;
  esac
fi
if [ "$crash" = 1 ]; then
  echo '   Compiling wasmtime-environ v33.0.0' >&2
  echo '    Running `rustc --crate-name wasmtime_environ --edition=2021 crates/environ/src/lib.rs`' >&2
  echo '   Compiling cranelift-codegen v0.121.0' >&2
  echo '    Running `rustc --crate-name cranelift_codegen --edition=2021 crates/codegen/src/lib.rs`' >&2
  echo 'error: could not compile `cranelift-codegen`' >&2
  echo "process didn't exit successfully: \`rustc --crate-name cranelift_codegen --edition=2021 crates/codegen/src/lib.rs\` (signal: 11, SIGSEGV)" >&2
  echo 'warning: build failed, waiting for other jobs to finish...' >&2
  exit 101
fi
if [ "${FAKE_CARGO_FAIL:-0}" = 1 ]; then echo 'fake cargo: build error' >&2; exit 1; fi
out=$(dirname "$manifest")/target/$outdir
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
printf 'payload-%s\n' "$mode" >> "$out/wa"
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

# `wa update` now looks for a PUBLISHED RELEASE first (releases/index.json on main). This
# suite is about the other rung - the on-device build ladder, which now runs only as the
# fallback - so it points the updater at a local, EMPTY fixture index: no release is
# published for the fake commits below, which is exactly the condition that selects the
# fallback, and it is the loud one (the output says the device cannot compile this
# workspace). No network is used by this suite.
{
  printf '%s\n' '{'
  printf '%s\n' '  "schema": "wasm-agent-release-index",'
  printf '%s\n' '  "schema_version": 1,'
  printf '%s\n' '  "releases": []'
  printf '%s\n' '}'
} > "$work/index.json"
export WA_TERMUX_RELEASE_ALLOW_LOCAL=1
export WA_TERMUX_RELEASE_INDEX_URL="file://$work/index.json"

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

# ---- 8. the phone build path: the ladder, the debug rung, the refusal -------
#
# The failure this section exists for, in the operator's own log: rustc killed by a signal
# under memory pressure, cargo reporting `process didn't exit successfully ... (signal: 11,
# SIGSEGV)` on the Wasmtime engine crate `cranelift_codegen`, and the install stopping there
# with nothing left to read. The fixtures below drive the ladder that replaced that: attempt
# 1 the phone default (one job, default codegen units), attempt 2 the resource-safe profile,
# attempt 3 a debug/unoptimized build; which rung's binary is installed; one named refusal
# that names every attempt and every log; never overriding an explicit setting and never
# calling this script's own values the operator's; forcing a single rung by name; and a host
# that is not a phone staying exactly as it was.
#
# The ladder is the phone build path, so these fixtures make this non-Android host stand in
# for the phone with WA_TERMUX_TEST=1, and the build announces that in its output.

# Every build before this point ran a single host rung, and a successful build writes no log
# and creates no log directory. This asserts what the suites above did.
[ ! -e "$updated/build-logs" ] || die 'a successful build created a build log directory'
ok 'no successful build left a build log behind'

# 8a. a non-Android host is unchanged: one rung, the same cargo invocation as before the
#     ladder existed, no profile variables in the environment, no log directory.
#     The gate can run this suite with CARGO_BUILD_JOBS set (WA_GATE_JOBS): the fixtures
#     that follow are about what a build does with an explicit setting, so they set their
#     own and this one starts from none.
unset CARGO_BUILD_JOBS RUST_MIN_STACK RUSTFLAGS CARGO_INCREMENTAL
export FAKE_CARGO_RECORD=$work/cargo-record
: > "$FAKE_CARGO_RECORD"
export WA_TERMUX_BUILD_LOG_DIR=$work/logs-that-must-not-appear
make_install "$A" "$up"
set +e
host_out=$(run_update 2>&1)
host_rc=$?
set -e
[ "$host_rc" -eq 0 ] || die "a non-Android host did not update: $host_out"
case "$host_out" in
  *'updated'*) ok 'a non-Android host updates' ;;
  *) die "the host update did not report: $host_out" ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$B" ] ||
  die 'the host-profile update did not switch'
case "$host_out" in
  *'build ladder: default (1 attempt(s)'*) ok 'a non-Android host runs one rung, not the phone ladder' ;;
  *) die "the host build did not report a single rung: $host_out" ;;
esac
case "$host_out" in
  *'attempt 1/1 of the ladder, profile default'*'unchanged (host defaults)'*)
    ok 'the host rung is reported as unchanged host defaults' ;;
  *) die "the host profile was not reported: $host_out" ;;
esac
case "$host_out" in
  *'WA_TERMUX_TEST=1'*) die "the phone ladder was driven on a host that is not a phone: $host_out" ;;
  *) ok 'no phone ladder on a host that is not a phone' ;;
esac
grep -q 'attempt=1 jobs= stack= flags= incremental= argv=build --release --locked --manifest-path ' \
  "$FAKE_CARGO_RECORD" ||
  die "the non-Android invocation changed: $(cat "$FAKE_CARGO_RECORD")"
ok 'a non-Android host gets the unchanged cargo invocation and no profile variables'
[ ! -e "$WA_TERMUX_BUILD_LOG_DIR" ] || die 'a successful build created a log directory'
ok 'a successful build writes no build log'
unset WA_TERMUX_BUILD_LOG_DIR

# 8b. the compiler crashes on the first rung: the crash is named with the crate that died,
#     the ladder advances and announces the rung it moves to, and the install completes on
#     the resource-safe profile - and it is the second rung's binary that gets installed.
export FAKE_CARGO_STATE=$work/cargo-attempts
export FAKE_CARGO_CRASH_ATTEMPTS=1
: > "$FAKE_CARGO_RECORD"
rm -f "$FAKE_CARGO_STATE"
rm -rf "$releases" "$updated"
make_install "$A" "$up"
before_hashes=$(state_hashes)
set +e
ladder_out=$(adopt 2>&1)
ladder_rc=$?
set -e
[ "$ladder_rc" -eq 0 ] || die "the ladder did not rescue the build: $ladder_out"
case "$ladder_out" in
  *'WA_TERMUX_TEST=1: this host is not an Android device; driving the phone build ladder'*)
    ok 'the fixture announces that it is standing in for the phone' ;;
  *) die "the phone ladder was not announced: $ladder_out" ;;
esac
case "$ladder_out" in
  *'build ladder: default conservative debug (3 attempt(s)'*)
    ok 'the ladder is default -> conservative -> debug, three attempts' ;;
  *) die "the ladder was not reported: $ladder_out" ;;
esac
case "$ladder_out" in
  *'THE COMPILER CRASHED'*'the last crate in that log is cranelift_codegen'*)
    ok 'a rustc signal is reported as a compiler crash, with the crate that died' ;;
  *) die "the crash was not named with its crate: $ladder_out" ;;
esac
case "$ladder_out" in
  *'attempt 1/3 of the ladder, profile default'*'attempt 2/3 of the ladder, profile conservative'*)
    ok 'the crashed rung and the rung it advances to are both announced' ;;
  *) die "the ladder did not advance: $ladder_out" ;;
esac
case "$ladder_out" in
  *'profile conservative finished:'*'adopted'*) ok 'the install completes on the second rung' ;;
  *) die "the second rung did not finish the install: $ladder_out" ;;
esac
grep -q '^attempt=1 jobs=1 stack= flags= incremental= argv=build --release --locked --manifest-path ' \
  "$FAKE_CARGO_RECORD" ||
  die "the first rung is not one job with default codegen units: $(cat "$FAKE_CARGO_RECORD")"
ok 'the first rung ran one job, with default codegen units and no RUSTFLAGS'
grep -q '^attempt=2 jobs=1 stack=33554432 flags= incremental= argv=build --release --locked --manifest-path ' \
  "$FAKE_CARGO_RECORD" ||
  die "the second rung is not the resource-safe profile: $(cat "$FAKE_CARGO_RECORD")"
ok 'the second rung ran one job and a raised compiler stack, still with default codegen units'
grep -q 'payload-release' "$install/wa" ||
  die 'the installed runtime is not the one the second rung built'
ok 'the installed runtime is the binary the rung that finished built'
grep -q '^build_profile=release$' "$install/installed.txt" ||
  die 'the release does not record which rung produced the runtime'
ok 'the release records the rung that produced it'
[ -f "$updated/build-logs/build-attempt1.log" ] || die 'the first crash kept no build log'
grep -q 'signal: 11' "$updated/build-logs/build-attempt1.log" ||
  die 'the kept log does not contain the crash it was kept for'
[ ! -e "$updated/build-logs/build-attempt2.log" ] || die 'a rung that succeeded wrote a log'
ok 'the crash log is kept where the operator can read and paste it, and success writes none'
[ "$before_hashes" = "$(state_hashes)" ] || die 'the crash and its retry changed node state'
ok 'node state survives a crash and its retry byte-for-byte'
unset FAKE_CARGO_CRASH_ATTEMPTS

# 8c. the compiler crashes on the first TWO rungs: the third rung is the debug/unoptimized
#     build, it builds with `cargo build --profile dev`, and the runtime that is installed
#     and reported is that debug binary - not a stale release one and not nothing.
export FAKE_CARGO_CRASH_ATTEMPTS=1,2
rm -f "$FAKE_CARGO_STATE"
: > "$FAKE_CARGO_RECORD"
rm -rf "$releases" "$updated"
make_install "$A" "$up"
before_hashes=$(state_hashes)
set +e
debug_out=$(adopt 2>&1)
debug_rc=$?
set -e
[ "$debug_rc" -eq 0 ] || die "the debug rung did not rescue the build: $debug_out"
case "$debug_out" in
  *'attempt 3/3 of the ladder, profile debug'*) ok 'the third rung is the debug profile' ;;
  *) die "the debug rung was not attempted: $debug_out" ;;
esac
case "$debug_out" in
  *'build --profile dev (debug, unoptimized)'*'profile debug finished:'*)
    ok 'the debug rung builds with cargo --profile dev, and it is the rung that finishes' ;;
  *) die "the debug rung was not what built: $debug_out" ;;
esac
grep -q '^attempt=3 jobs=1 stack=33554432 flags= incremental=0 argv=build --profile dev --locked --manifest-path ' \
  "$FAKE_CARGO_RECORD" ||
  die "the debug rung did not run as expected: $(cat "$FAKE_CARGO_RECORD")"
ok 'the debug rung ran one job, a raised stack and no incremental state'
grep -q 'payload-dev' "$install/wa" ||
  die 'the installed runtime is not the debug binary that was built'
ok 'the installed runtime is the debug binary the third rung built'
grep -q '^build_profile=dev$' "$install/installed.txt" ||
  die 'the release does not record that it is an unoptimized build'
ok 'the release records that its runtime is the unoptimized one'
case "$debug_out" in
  *'the runtime was built with the debug/unoptimized profile'*)
    ok 'the install says plainly that the runtime it installed is unoptimized' ;;
  *) die "the install did not say what kind of runtime it installed: $debug_out" ;;
esac
set +e
doctor_out=$(sh "$install/bin/wa" doctor 2>&1)
set -e
case "$doctor_out" in
  *'Build: dev (unoptimized'*) ok 'wa doctor reports the unoptimized runtime' ;;
  *) die "wa doctor does not report the build profile: $doctor_out" ;;
esac
for n in 1 2; do
  [ -f "$updated/build-logs/build-attempt$n.log" ] || die "rung $n kept no log"
  grep -q 'signal: 11' "$updated/build-logs/build-attempt$n.log" || die "log $n has no crash in it"
done
[ ! -e "$updated/build-logs/build-attempt3.log" ] || die 'the rung that succeeded wrote a log'
ok 'each crashed rung kept its own log, and the successful one kept none'
[ "$(rl_get "$install/installed.txt" source_commit)" = "$B" ] ||
  die 'the debug-rung install did not install its revision'
[ "$before_hashes" = "$(state_hashes)" ] || die 'the debug rung changed node state'
ok 'node state is untouched by the ladder that ended in a debug build'
unset FAKE_CARGO_CRASH_ATTEMPTS

# 8d. the compiler crashes on all three rungs: ONE named refusal that names every attempt,
#     every retained log and the crate, assembles and switches nothing, and leaves node state
#     byte-for-byte as it was.
export FAKE_CARGO_CRASH_ATTEMPTS=1,2,3
rm -f "$FAKE_CARGO_STATE"
: > "$FAKE_CARGO_RECORD"
rm -rf "$releases" "$updated"
make_install "$A" "$up"
before_hashes=$(state_hashes)
before_install=$(snapshot_install)
set +e
refused_out=$(adopt 2>&1)
refused_rc=$?
set -e
[ "$refused_rc" -ne 0 ] || die 'a compiler that crashed on every rung was accepted'
case "$refused_out" in
  *'compiler_crash_build_refused: the compiler crashed on every attempt of the build ladder'*)
    ok 'the exhausted ladder is refused by name' ;;
  *) die "the refusal was not named: $refused_out" ;;
esac
for want in \
  'attempt 1/3, profile default' \
  'attempt 2/3, profile conservative' \
  'attempt 3/3, profile debug'; do
  case "$refused_out" in
    *"$want"*) ;;
    *) die "the refusal does not name '$want': $refused_out" ;;
  esac
done
ok 'the refusal names every attempt of the ladder'
for n in 1 2 3; do
  [ -f "$updated/build-logs/build-attempt$n.log" ] || die "the refusal kept no log for rung $n"
  case "$refused_out" in
    *"build-attempt$n.log"*) ;;
    *) die "the refusal does not name build-attempt$n.log: $refused_out" ;;
  esac
  grep -q 'signal: 11' "$updated/build-logs/build-attempt$n.log" ||
    die "log $n does not contain the crash it was kept for"
done
ok 'the refusal names every retained log, and each one holds its crash'
case "$refused_out" in
  *'last crate in the log: cranelift_codegen'*)
    ok 'the refusal names the crate the log points at' ;;
  *) die "the refusal does not name the crate: $refused_out" ;;
esac
case "$refused_out" in
  *'CARGO_BUILD_JOBS=1 (this script, rung debug)'*'CARGO_INCREMENTAL=0 (this script, rung debug)'*)
    ok 'the refusal attributes the values it set itself to the script, not to the operator' ;;
  *) die "the refusal does not attribute its own values: $refused_out" ;;
esac
case "$refused_out" in
  *'you had set none of these variables yourself'*)
    ok 'the refusal says plainly that none of those values were the operator own' ;;
  *) die "the refusal does not say where the values came from: $refused_out" ;;
esac
case "$refused_out" in
  *'rustc -V'*'free -m | head -3'*'nproc'*) ok 'the refusal names the three diagnostics to paste' ;;
  *) die "the refusal does not name the diagnostics: $refused_out" ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$A" ] ||
  die 'a refused ladder still switched the installed revision'
[ "$before_install" = "$(snapshot_install)" ] || die 'a refused ladder changed the installation'
[ ! -e "$releases/$B" ] || die 'a refused ladder left a release behind'
[ -z "$(find "$releases" -maxdepth 1 -name '.adopt.*' 2>/dev/null)" ] ||
  die 'a refused ladder left a staging release behind'
ok 'a refused ladder switched nothing, assembled no release and left no staging behind'
[ "$before_hashes" = "$(state_hashes)" ] || die 'the refused ladder changed node state'
ok 'node state is untouched by the refused ladder'
unset FAKE_CARGO_CRASH_ATTEMPTS

# 8e. authorship: a value the operator set is theirs and is kept verbatim; a value this
#     script set is the script's, even on the rung after the one that set it. The old
#     wording called the script's own conservative values "yours, kept".
export FAKE_CARGO_CRASH_ATTEMPTS=1
export RUST_MIN_STACK=67108864
rm -f "$FAKE_CARGO_STATE"
: > "$FAKE_CARGO_RECORD"
rm -rf "$releases" "$updated"
make_install "$A" "$up"
set +e
kept_out=$(adopt 2>&1)
kept_rc=$?
set -e
[ "$kept_rc" -eq 0 ] || die "an operator setting broke the build: $kept_out"
case "$kept_out" in
  *'RUST_MIN_STACK=67108864 (yours, kept)'*)
    ok 'a value the operator set is reported as the operator own' ;;
  *) die "the operator value was not reported as theirs: $kept_out" ;;
esac
case "$kept_out" in
  *'CARGO_BUILD_JOBS=1 (this script, rung conservative)'*)
    ok 'the value this script set on the second rung is reported as the script own' ;;
  *) die "the script's own value was not attributed to the script: $kept_out" ;;
esac
case "$kept_out" in
  *'CARGO_BUILD_JOBS=1 (yours, kept)'*) die 'the script own value was reported as the operator own' ;;
  *) ok 'no value this script set is claimed as the operator own' ;;
esac
grep -q '^attempt=2 jobs=1 stack=67108864 ' "$FAKE_CARGO_RECORD" ||
  die "the operator stack was not used verbatim: $(cat "$FAKE_CARGO_RECORD")"
ok 'the operator value reached the compiler verbatim'
unset RUST_MIN_STACK FAKE_CARGO_CRASH_ATTEMPTS

# 8f. one rung can be forced by name, and then there is no ladder: the forced rung runs
#     once, keeps an operator value, applies the rest of itself, and an unknown name is
#     refused with the three choices.
export WA_TERMUX_BUILD_PROFILE=conservative
export CARGO_BUILD_JOBS=3
rm -f "$FAKE_CARGO_STATE"
: > "$FAKE_CARGO_RECORD"
rm -rf "$releases" "$updated"
make_install "$A" "$up"
set +e
forced_out=$(run_update 2>&1)
forced_rc=$?
set -e
[ "$forced_rc" -eq 0 ] || die "the forced profile did not build: $forced_out"
case "$forced_out" in
  *'build profile forced by WA_TERMUX_BUILD_PROFILE=conservative: one attempt, no ladder'*)
    ok 'a forced profile is announced as one attempt' ;;
  *) die "the forced profile was not announced: $forced_out" ;;
esac
case "$forced_out" in
  *'attempt 1/1, profile conservative'*) ok 'a forced profile runs exactly one rung' ;;
  *) die "the forced profile did not run once: $forced_out" ;;
esac
case "$forced_out" in
  *'CARGO_BUILD_JOBS=3 (yours, kept)'*)
    ok 'an explicit CARGO_BUILD_JOBS is respected, not overridden' ;;
  *) die "the operator job count was not kept: $forced_out" ;;
esac
case "$forced_out" in
  *'RUST_MIN_STACK=33554432 (this script, rung conservative)'*)
    ok 'the rest of the forced rung is applied, and attributed to the script' ;;
  *) die "the forced rung was not applied: $forced_out" ;;
esac
grep -q '^attempt=1 jobs=3 stack=33554432 flags= incremental= argv=build --release --locked --manifest-path ' \
  "$FAKE_CARGO_RECORD" ||
  die "the forced rung was not applied as documented: $(cat "$FAKE_CARGO_RECORD")"
ok 'the forced rung kept the operator job count, applied the rest, and set no codegen-units flag'
[ ! -e "$updated/build-logs" ] || die 'a successful forced build created a log directory'
unset CARGO_BUILD_JOBS
export WA_TERMUX_BUILD_PROFILE=clever
make_install "$A" "$up"
set +e
unknown_out=$(run_update 2>&1)
unknown_rc=$?
set -e
[ "$unknown_rc" -ne 0 ] || die 'an unknown build profile was accepted'
case "$unknown_out" in
  *"build_profile_unknown: WA_TERMUX_BUILD_PROFILE=clever"*"'default', 'conservative' or 'debug'"*)
    ok 'an unknown build profile is refused by name, naming the three choices' ;;
  *) die "the unknown profile refusal is not by name: $unknown_out" ;;
esac
unset WA_TERMUX_BUILD_PROFILE

# 8g. a forced rung that crashes is refused after ONE attempt: forcing a profile means
#     forcing it, with no ladder behind it.
export WA_TERMUX_BUILD_PROFILE=debug
export FAKE_CARGO_CRASH_ATTEMPTS=1
rm -f "$FAKE_CARGO_STATE"
rm -rf "$releases" "$updated"
make_install "$A" "$up"
set +e
forced_crash_out=$(run_update 2>&1)
forced_crash_rc=$?
set -e
[ "$forced_crash_rc" -ne 0 ] || die 'a forced rung that crashed was accepted'
case "$forced_crash_out" in
  *'attempt 1/1, profile debug'*'compiler_crash_build_refused'*)
    ok 'a forced rung that crashed is refused after one attempt' ;;
  *) die "the forced rung did not refuse after one attempt: $forced_crash_out" ;;
esac
[ -f "$updated/build-logs/build-attempt1.log" ] || die 'the forced rung kept no log'
[ ! -e "$updated/build-logs/build-attempt2.log" ] || die 'a forced profile ran a second rung'
[ "$(rl_get "$install/installed.txt" source_commit)" = "$A" ] ||
  die 'a refused forced rung still switched'
ok 'a forced profile produced one log, ran no second rung and switched nothing'
unset FAKE_CARGO_CRASH_ATTEMPTS WA_TERMUX_BUILD_PROFILE

# 8h. a host that is not a phone has no ladder to walk: one rung, and a compiler crash on
#     it is refused at once with its log. The phone's knobs exist for the phone's memory,
#     not to be sprayed onto CI.
unset WA_TERMUX_BUILD_PROFILE
export FAKE_CARGO_CRASH_ATTEMPTS=1
rm -f "$FAKE_CARGO_STATE"
rm -rf "$releases" "$updated"
make_install "$A" "$up"
set +e
host_crash_out=$(run_update 2>&1)
host_crash_rc=$?
set -e
[ "$host_crash_rc" -ne 0 ] || die 'a crashed compiler on a non-Android host was accepted'
case "$host_crash_out" in
  *'attempt 1/1 of the ladder, profile default'*'compiler_crash_build_refused'*)
    ok 'a non-Android host refuses after its one rung, with no phone ladder' ;;
  *) die "the host crash path changed: $host_crash_out" ;;
esac
[ -f "$updated/build-logs/build-attempt1.log" ] || die 'the host crash kept no log'
[ ! -e "$updated/build-logs/build-attempt2.log" ] || die 'a non-Android host ran a second rung'
case "$host_crash_out" in
  *'CARGO_BUILD_JOBS'*) die "the phone knobs were applied on a host that is not a phone: $host_crash_out" ;;
  *) ok 'no phone knobs on a host that is not a phone' ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$A" ] ||
  die 'a refused host build still switched'
unset FAKE_CARGO_CRASH_ATTEMPTS

# ---- 9. the one command: clone from a local bare repo, adopt, then update -----
#
# A bare upstream (so the clone is a real git clone over file:// with no network) into a
# destination that does not exist yet, against an installation with no updater - the state
# the operator's phone was in. The build is still the fake cargo: no Rust toolchain runs.
git clone -q --bare "$up" "$work/upstream-bare.git"
one_dir=$work/one-command-checkout
one_url="file://$work/upstream-bare.git"
rm -rf "$one_dir" "$releases" "$updated"
make_install "$A" "$up"
rm -f "$install/bin/wa-update"
rl_paths
rl_manifest "$install" "$install/installed.sha256"
before_hashes=$(state_hashes)
run_one() { WA_TERMUX_TEST=1 bash "$root/scripts/termux/bootstrap.sh" "$@"; }
set +e
one_out=$(run_one --checkout "$one_dir" --repo "$one_url" 2>&1)
one_rc=$?
set -e
[ "$one_rc" -eq 0 ] || die "the one command failed: $one_out"
case "$one_out" in
  *'cloning'*"$one_url"*) ok 'the one command clones when the checkout is absent' ;;
  *) die "the one command did not clone: $one_out" ;;
esac
case "$one_out" in
  *'adopting the existing installation'*) ok 'the one command chooses the one-time bootstrap for a pre-updater install' ;;
  *) die "the one command did not adopt: $one_out" ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$B" ] ||
  die 'the one command did not install the checkout revision'
[ "$(rl_get "$install/installed.txt" source_remote)" = "$one_url" ] ||
  die "the upstream was not defaulted from the clone's own remote: $(rl_get "$install/installed.txt" source_remote)"
ok 'the upstream defaulted to the checkout own origin - no --upstream and no hardcoded URL'
[ "$before_hashes" = "$(state_hashes)" ] || die 'the one command changed node state'
ok 'node state survives the one command byte-for-byte'

# The same one command, run again on a node that is now on the update track, updates
# instead of adopting: this is what makes one line enough for every later revision.
set +e
again_out=$(run_one --checkout "$one_dir" --check 2>&1)
again_rc=$?
set -e
[ "$again_rc" -eq 0 ] || die "the second run of the one command failed: $again_out"
case "$again_out" in
  *'on the update track'*) ok 'the same one command switches to wa update once the node is adopted' ;;
  *) die "the second run did not switch to wa update: $again_out" ;;
esac
case "$again_out" in
  *'up to date'*) ok 'and wa update answers for it' ;;
  *) die "the second run did not reach the updater: $again_out" ;;
esac
[ "$(rl_get "$install/installed.txt" source_commit)" = "$B" ] ||
  die 'the second run changed the installed revision'
[ "$before_hashes" = "$(state_hashes)" ] || die 'the second run changed node state'
ok 'the second run changed neither the revision nor node state'

if [ "$(uname -s)" = MINGW64_NT-10.0 ] || [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]]; then
  skipf "already_adopted (a managed release link) — this host cannot create symlinks"
fi

printf '%s\n' "termux update: $pass passed, $skip skipped"
if [ -n "$skipped_notes" ]; then
  printf '%s\n' '  skipped:'
  printf '%s\n' "$skipped_notes"
fi
