#!/usr/bin/env bash
# Cross-build the Windows WebView2 companion (wa-window.exe) from Linux.
#
# The window is a frameless, always-on-top, translucent shell that collapses to
# a round avatar and expands into the chat panel. It loads the same `wa serve`
# UI over the SSH tunnel, so the UI still hot-reloads while it runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

docker build -q -t wa-window-build -f rust/wa-window/Dockerfile.windows rust/wa-window >/dev/null

# The container runs as root; hand the artifacts back to the invoking user.
docker run --rm \
  -v "$ROOT:/source" -w /source \
  -v wa-cargo-registry:/usr/local/cargo/registry \
  wa-window-build \
  cargo build --manifest-path rust/wa-window/Cargo.toml \
    --target x86_64-pc-windows-gnu --release
docker run --rm -v "$ROOT:/source" wa-window-build \
  chown -R "$(id -u):$(id -g)" /source/target/windows-x64

R="$ROOT/target/windows-x64/x86_64-pc-windows-gnu/release"
DLL="$(ls "$R"/build/webview2-com-sys-*/out/x64/WebView2Loader.dll | head -1)"
cp -f "$DLL" "$R/WebView2Loader.dll"

echo "built:"
echo "  $R/wa-window.exe"
echo "  $R/WebView2Loader.dll"
