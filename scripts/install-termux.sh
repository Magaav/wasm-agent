#!/data/data/com.termux/files/usr/bin/bash
# Build and install the wasm-agent developer preview inside Termux.
set -euo pipefail

fail() { printf 'install-termux: %s\n' "$*" >&2; exit 1; }
[ "${PREFIX:-}" = /data/data/com.termux/files/usr ] || fail 'run this inside the Termux app'
[ "$(uname -o 2>/dev/null || true)" = Android ] || fail 'android_required'
case "$(uname -m)" in aarch64|arm64) ;; *) fail 'only Android arm64 is supported by this preview' ;; esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$root/rust/Cargo.toml" ] || fail 'source_checkout_required'
command -v git >/dev/null 2>&1 || fail 'git_required_for_source_checkout'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] || fail 'dirty_source: commit the revision before installing it'
source_commit=$(git -C "$root" rev-parse HEAD)
install_root=${WA_TERMUX_INSTALL:-"$PREFIX/opt/wasm-agent-preview"}
[ ! -e "$install_root" ] || fail "existing_installation: remove or move $install_root before reinstalling"
[ ! -e "$PREFIX/bin/wa" ] && [ ! -L "$PREFIX/bin/wa" ] || fail "launcher_exists: $PREFIX/bin/wa"

printf '%s\n' 'Installing Termux build prerequisites...'
pkg update -y
pkg install -y rust clang make pkg-config git ripgrep

printf '%s\n' 'Building wasm-agent for this Android device (the first build can take several minutes)...'
cargo_args=(build --release --locked --manifest-path "$root/rust/Cargo.toml")
if [ "${WA_TERMUX_OFFLINE:-0}" = 1 ]; then cargo_args+=(--offline); fi
cargo "${cargo_args[@]}"
[ "$(git -C "$root" rev-parse HEAD)" = "$source_commit" ] || fail 'source_changed_during_build'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] || fail 'source_changed_during_build'

stage="$PREFIX/opt/.wasm-agent-preview.$$"
cleanup() { [ ! -d "$stage" ] || rm -rf -- "$stage"; }
trap cleanup EXIT
mkdir -p "$stage/ui" "$stage/bin"
install -m 755 "$root/rust/target/release/wa" "$stage/wa"
install -m 755 "$root/scripts/termux/wa" "$stage/bin/wa"
for asset in index.html style.css app.js components.js render.wasm; do
  install -m 644 "$root/ui/$asset" "$stage/ui/$asset"
done
install -m 644 "$root/LICENSE" "$stage/LICENSE"
printf 'source_commit=%s\ninstalled_utc=%s\n' "$source_commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$stage/installed.txt"
mv -- "$stage" "$install_root"
trap - EXIT
ln -s "$install_root/bin/wa" "$PREFIX/bin/wa"

printf '%s\n' "Installed wasm-agent Termux preview in $install_root"
printf '%s\n' "Next: run 'wa setup', then 'wa doctor', then 'wa ui'."
printf '%s\n' 'This is a source-built developer preview, not a published or Play Store release.'
