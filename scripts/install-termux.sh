#!/data/data/com.termux/files/usr/bin/bash
# Build and install the wasm-agent developer preview inside Termux.
#
# A fresh install only. An installation from before `wa update` existed is brought onto the
# update track by `--adopt-existing`, which is the one-time bootstrap in
# scripts/termux/adopt-existing.sh - it refuses more, backs the old install up, and says
# exactly which fact it is missing when the on-phone layout is not the documented one.
#
# `--recover` is the out-of-band repair for the one damage `wa update` cannot fix itself:
# a switch interrupted between its two renames leaves the active path absent, and with it
# the launcher, so the next `wa update` cannot even start. This runs from the checkout,
# which is outside everything the switch moves.
set -euo pipefail

fail() { printf 'install-termux: %s\n' "$*" >&2; exit 1; }

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
action=fresh
case "${1:-}" in
  --adopt-existing) action=adopt; shift ;;
  --recover) action=recover; shift ;;
  '') : ;;
  *) fail "unknown_install_option: $1 (the options are --adopt-existing and --recover)" ;;
esac

if [ "${WA_TERMUX_TEST:-0}" = 1 ]; then
  # The fixture suite drives the refusals below on a host that is not the phone; it has to
  # say so, and this line is the record that it did.
  printf 'install-termux: WA_TERMUX_TEST=1: Android/architecture guards bypassed for the fixture suite\n' >&2
else
  [ "${PREFIX:-}" = /data/data/com.termux/files/usr ] || fail 'run this inside the Termux app'
  [ "$(uname -o 2>/dev/null || true)" = Android ] || fail 'android_required'
  case "$(uname -m)" in aarch64|arm64) ;; *) fail 'only Android arm64 is supported by this preview' ;; esac
fi

. "$root/scripts/termux/release-lib.sh"
rl_paths

# ---- the out-of-band repair -------------------------------------------------

if [ "$action" = recover ]; then
  [ "$#" -eq 0 ] || fail "unknown_install_option: $1"
  [ -d "$RL_UPDATE" ] || fail "nothing_to_recover: $RL_UPDATE does not exist"
  rl_recover
  [ -e "$RL_INSTALL" ] ||
    fail "recovery_failed: $RL_INSTALL is still missing; inspect $RL_UPDATE and $RL_RELEASES"
  printf 'termux-adopt: active release is %s\n' "$(rl_get "$RL_INSTALL/installed.txt" source_commit)"
  exit 0
fi

if [ "$action" = adopt ]; then
  exec bash "$root/scripts/termux/adopt-existing.sh" "$@"
fi
[ "$#" -eq 0 ] || fail "unknown_install_option: $1"

# ---- a fresh install --------------------------------------------------------

[ -f "$root/rust/Cargo.toml" ] || fail 'source_checkout_required'
command -v git >/dev/null 2>&1 || fail 'git_required_for_source_checkout'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] || fail 'dirty_source: commit the revision before installing it'
source_commit=$(git -C "$root" rev-parse HEAD)

[ ! -e "$RL_INSTALL" ] || fail "existing_installation: '$RL_INSTALL' already exists; for an existing preview run 'bash scripts/install-termux.sh --adopt-existing', otherwise remove or move it"
[ ! -e "$RL_PREFIX/bin/wa" ] && [ ! -L "$RL_PREFIX/bin/wa" ] || fail "launcher_exists: $RL_PREFIX/bin/wa"

# The upstream this install came from, recorded so `wa update` has somewhere to look. A
# checkout with no remote records nothing and `wa update` then refuses by name until the
# operator passes --upstream once.
source_remote=${WA_TERMUX_UPSTREAM_URL:-}
if [ -z "$source_remote" ]; then
  source_remote=$(git -C "$root" remote get-url origin 2>/dev/null || true)
fi

printf '%s\n' 'Installing Termux build prerequisites...'
pkg update -y
pkg install -y rust clang make pkg-config git ripgrep

printf '%s\n' 'Building wasm-agent for this Android device (the first build can take several minutes)...'
built=$(rl_build_wa "$root")
built_profile=$(rl_build_profile_of_bin "$built")
[ "$(git -C "$root" rev-parse HEAD)" = "$source_commit" ] || fail 'source_changed_during_build'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] || fail 'source_changed_during_build'

stage="$RL_BASE/.wasm-agent-preview.$$"
cleanup() { [ ! -d "$stage" ] || rm -rf -- "$stage"; }
trap cleanup EXIT
rl_assemble "$root" "$built" "$stage" "$source_commit" "$source_remote" '-' 'install-termux' \
  "$built_profile"
rl_verify_release "$stage" || fail 'candidate_refused: the build did not verify (see above)'
mkdir -p -- "$RL_RELEASES" "$RL_UPDATE" 2>/dev/null || true
mv -- "$stage" "$RL_INSTALL"
trap - EXIT
ln -s "$RL_INSTALL/bin/wa" "$RL_PREFIX/bin/wa"

printf '%s\n' "Installed wasm-agent Termux preview in $RL_INSTALL"
if [ "$built_profile" = dev ]; then
  printf '%s\n' 'This runtime was built with the debug/unoptimized profile: the optimized build did not finish on this device. It works, and it is slower than a release build. "wa doctor" reports it.'
fi
printf '%s\n' "Next: run 'wa setup', then 'wa doctor', then 'wa ui'."
printf '%s\n' "Later revisions are installed with 'wa update --check' then 'wa update'."
printf '%s\n' 'This is a source-built developer preview, not a published or Play Store release.'
