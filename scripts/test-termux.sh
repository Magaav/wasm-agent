#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
install="$prefix/opt/wasm-agent-preview"
mkdir -p "$install/ui" "$install/bin" "$prefix/bin" "$work/home/.wasm-agent"
cp "$root/scripts/termux/wa" "$install/bin/wa"
chmod +x "$install/bin/wa"
printf '<html></html>\n' > "$install/ui/index.html"
cat > "$install/wa" <<'EOF'
#!/usr/bin/env sh
printf 'native:%s\n' "$*"
EOF
chmod +x "$install/wa"
cat > "$prefix/bin/rg" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "$prefix/bin/rg"
printf 'WASM_AGENT_LLM_API_KEY=preserved-key\n' > "$work/home/.wasm-agent/env"

export PREFIX="$prefix" HOME="$work/home" PATH="$prefix/bin:$PATH"
help=$($install/bin/wa help)
[[ "$help" == *'wa setup'* ]]
delegated=$($install/bin/wa status one)
[[ "$delegated" == 'native:status one' ]]
doctor=$($install/bin/wa doctor)
[[ "$doctor" == *'UI assets: present'* ]]
[[ "$doctor" == *'Configuration: present'* ]]

printf 'Phone agent\n%s\nhttps://provider.example/v1\nmodel-name\n\n' "$work/home" | "$install/bin/wa" setup >/dev/null 2>&1
grep -q '^WASM_AGENT_DISPLAY_NAME=Phone agent$' "$work/home/.wasm-agent/env"
grep -q '^WASM_AGENT_LLM_API_KEY=preserved-key$' "$work/home/.wasm-agent/env"
mode=$(stat -c '%a' "$work/home/.wasm-agent/env")
permission_skip=0
if [[ "$(uname -s)" == MINGW* ]]; then
  permission_skip=1
else
  [[ "$mode" == 600 ]]
fi

ui_output=$($install/bin/wa ui --no-open --port 18899)
[[ "$ui_output" == *'native:serve --port 18899 --client-port 18900'* ]]
bash -n "$root/scripts/install-termux.sh"
sh -n "$root/scripts/termux/wa"
if [[ "$permission_skip" == 1 ]]; then
  printf '%s\n' 'termux launcher: 8 passed, 1 skipped (POSIX mode semantics unavailable on Windows); Android build and runtime skipped on this non-Android host'
else
  printf '%s\n' 'termux launcher: 9 passed, 0 skipped; Android build and runtime skipped on this non-Android host'
fi
