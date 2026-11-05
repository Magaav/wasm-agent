#!/usr/bin/env bash
# Build the agent-core component (rust/components/agent-core): wa-host's vendored Lua 5.4 + the
# host.call bridge as one wasm32-wasip2 component (docs/KERNEL.md, "A2.1"). Needs wasi-sdk (clang
# for wasm32-wasip2 + libsetjmp): WASI_SDK=<dir>, else ~/wasi-sdk*, else /opt/wasi-sdk*.
#
#   bash scripts/build-agent-core.sh    # prints the path of the built .wasm on its last line
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
SDK="${WASI_SDK:-}"
if [ -z "$SDK" ]; then
  for candidate in "$HOME"/wasi-sdk* /opt/wasi-sdk*; do [ -d "$candidate/share/wasi-sysroot" ] && SDK="$candidate"; done
fi
[ -n "$SDK" ] && [ -d "$SDK/share/wasi-sysroot" ] || { echo "wasi-sdk not found (set WASI_SDK)" >&2; exit 2; }
if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx wasm32-wasip2; then
  rustup target add wasm32-wasip2 >/dev/null
fi
ext=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ext=".exe";; esac
CC_wasm32_wasip2="$SDK/bin/clang$ext" AR_wasm32_wasip2="$SDK/bin/llvm-ar$ext" \
  WASI_SYSROOT="$SDK/share/wasi-sysroot" \
  cargo build --release --target wasm32-wasip2 --manifest-path rust/components/agent-core/Cargo.toml >&2
wasm="rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm"
echo "built $wasm ($(wc -c < "$wasm") bytes)" >&2
echo "$wasm"
