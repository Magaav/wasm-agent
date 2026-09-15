#!/usr/bin/env bash
# wasm-agent installer for Linux/macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/wasm-agent/main/scripts/install.sh | sh
#
# Default: installs a `wa` command that talks to a wasm-agent host over SSH.
# Set WASM_AGENT_LOCAL=1 to pip-install the package on this machine instead.
set -euo pipefail

HOST_ALIAS="${WASM_AGENT_HOST:-openclaw.ohana}"
SOURCE="${WASM_AGENT_SOURCE:-git+https://github.com/Magaav/wasm-agent.git}"

if [ "${WASM_AGENT_LOCAL:-0}" = "1" ]; then
  python3 -m pip install --user --upgrade "$SOURCE"
  echo "wasm-agent installed locally. Run: wa"
  exit 0
fi

DIR="${HOME}/.local/bin"
mkdir -p "$DIR"
cat > "$DIR/wa" <<EOF
#!/usr/bin/env bash
exec ssh -t ${HOST_ALIAS} wasm-agent "\$@"
EOF
chmod +x "$DIR/wa"

echo "wasm-agent installed:"
echo "  $DIR/wa -> ssh -t ${HOST_ALIAS} wasm-agent"
echo
echo "Make sure $DIR is on your PATH, then run: wa"
