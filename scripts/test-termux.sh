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

export PREFIX="$prefix" HOME="$work/home" WASM_AGENT_HOME="$work/home" PATH="$prefix/bin:$PATH"
help=$(sh "$install/bin/wa" help)
[[ "$help" == *'wa setup'* ]]
delegated=$(sh "$install/bin/wa" status one)
[[ "$delegated" == 'native:status one' ]]
doctor=$(sh "$install/bin/wa" doctor)
[[ "$doctor" == *'UI assets: present'* ]]
[[ "$doctor" == *'Configuration: present'* ]]

printf 'Phone agent\n%s\nhttps://provider.example/v1\nmodel-name\n\n' "$work/home" | sh "$install/bin/wa" setup >/dev/null 2>&1
grep -q '^WASM_AGENT_DISPLAY_NAME=Phone agent$' "$work/home/.wasm-agent/env"
grep -q '^WASM_AGENT_LLM_API_KEY=preserved-key$' "$work/home/.wasm-agent/env"
mode=$(stat -c '%a' "$work/home/.wasm-agent/env")
permission_skip=0
# `uname -s` on the Windows development hosts is MSYS_NT-* or CYGWIN_NT-*, not only MINGW*:
# those hosts cannot represent a POSIX mode at all, so the 600 assertion is skipped and
# counted rather than reported as a failure.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) permission_skip=1 ;;
  *) [[ "$mode" == 600 ]] ;;
esac

ui_output=$(sh "$install/bin/wa" ui --no-open --port 18899)
[[ "$ui_output" == *'native:serve --port 18899 --client-port 18900'* ]]
bash -n "$root/scripts/install-termux.sh"
sh -n "$root/scripts/termux/wa"
sh -n "$root/scripts/termux/wa-update.sh"
sh -n "$root/scripts/termux/release-lib.sh"
bash -n "$root/scripts/termux/adopt-existing.sh"
bash -n "$root/scripts/termux/bootstrap.sh"
bash -n "$root/scripts/termux/install-bundle.sh"
bash -n "$root/scripts/termux/cross-build-android.sh"
bash -n "$root/scripts/test-termux-update.sh"
bash -n "$root/scripts/test-termux-bundle.sh"
bash -n "$root/scripts/test-termux-release-fetch.sh"
# The Android section of the README is where the one command lives: if the script it names
# is renamed, the documented command must not keep pointing at nothing.
grep -q 'scripts/termux/bootstrap.sh' "$root/README.md"
if [[ "$permission_skip" == 1 ]]; then
  printf '%s\n' 'termux launcher: 15 passed, 1 skipped (POSIX mode semantics unavailable on Windows); Android build and runtime skipped on this non-Android host'
else
  printf '%s\n' 'termux launcher: 16 passed, 0 skipped; Android build and runtime skipped on this non-Android host'
fi

# The updater has its own fixture suite - a fake upstream, a pre-existing installation
# carrying identity and state, and the real switch - because that behaviour is too large
# to bolt onto the launcher contracts above.
bash "$root/scripts/test-termux-update.sh"
# So does the prebuilt-bundle installer: a fabricated Android bundle, the pasted hash, every
# refusal, the byte-for-byte backup and the switch. Neither suite can prove that a
# cross-built Android binary runs; that is the device step.
bash "$root/scripts/test-termux-bundle.sh"
# And so does the published-release channel `wa update` now uses first: a real local bundle
# served from file:// URLs, a real index, the hash refusal and the loud build fallback. It
# uses no network, so it proves the channel's own logic and not the HTTPS transport.
bash "$root/scripts/test-termux-release-fetch.sh"
