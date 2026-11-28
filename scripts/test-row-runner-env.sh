#!/bin/bash
set -uo pipefail
W=/home/victor/Work/missions/mcp-list-is-fast/wt
R=/home/victor/wa-scratch/envi-root
rm -rf "$R"; mkdir -p "$R/home" "$R/install" "$R/tmp" "$R/units" "$R/bin"
printf '#!/bin/sh\nexit 0\n' > "$R/bin/systemctl"; chmod +x "$R/bin/systemctl"
T=/home/victor/wasm-agent/toolchain
cd $W
env -i \
  PATH="$R/install:$T/cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  HOME="$R/home" WASM_AGENT_HOME="$R/home" WA_INSTALL_DIR="$R/install" \
  WASM_AGENT_PORT=31111 WASM_AGENT_CLIENT_PORT=31112 \
  WA_SENTINEL_UNIT_DIR="$R/units" WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl" \
  TMPDIR="$R/tmp" LANG=C.UTF-8 TERM=dumb \
  RUSTUP_HOME="$T/rustup" CARGO_HOME="$T/cargo" CARGO_BUILD_JOBS=6 \
  CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-release-rows-real \
  WA_ROW_SCRATCH_ROOT="$R" \
  WA_BIN=/home/victor/wasm-agent/target/m-release-rows-real/release/wa \
  bash scripts/test-version-folders-real-restart.sh 2>&1 | tail -25 | cut -c1-130
echo '--- which binaries exist now ---'
ls -la /home/victor/wasm-agent/target/m-release-rows-real/release/ | grep -E 'wa-sentinel|wa-operations| wa$' | cut -c1-100
echo '--- build logs ---'
for f in "$R/tmp"/build-*.log; do echo "== $f"; tail -2 "$f" 2>/dev/null | cut -c1-110; done
