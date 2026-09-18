#!/usr/bin/env bash
# wasm-agent installer for Linux/macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
#
# Installs a `wa` command that talks to your wasm-agent host over SSH.
set -euo pipefail

HOST_ALIAS="${WASM_AGENT_HOST:-openclaw.ohana}"
DIR="${WASM_AGENT_BIN_DIR:-$HOME/.local/bin}"

cyan="\033[36m"; green="\033[32m"; grey="\033[90m"; yellow="\033[33m"; reset="\033[0m"
step() { printf "   ${cyan}*${reset} %s\n" "$1"; }
ok()   { printf "     ${green}ok${reset} ${grey}%s${reset}\n" "$1"; }
warn() { printf "     ${yellow}!${reset}  ${grey}%s${reset}\n" "$1"; }

printf "\n   ${cyan}wasm-agent${reset}\n   ${grey}a portable agent with organized memory${reset}\n\n"

step "installing the wa command"
mkdir -p "$DIR"
cat > "$DIR/wa" <<EOF
#!/usr/bin/env bash
exec ssh -t ${HOST_ALIAS} wasm-agent "\$@"
EOF
chmod +x "$DIR/wa"
ok "$DIR/wa -> ssh -t ${HOST_ALIAS} wasm-agent"

step "checking the connection to ${HOST_ALIAS}"
if command -v ssh >/dev/null 2>&1; then
  if version="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST_ALIAS" "wasm-agent --version" 2>/dev/null | head -1)" && [ -n "$version" ]; then
    ok "connected: $version"
  else
    warn "not reachable yet - check ~/.ssh/config, then run: wa"
  fi
else
  warn "ssh not found; install OpenSSH, then run: wa"
fi

# Can this node build itself? The toolchains are ordinary packages, so a node can install them
# on its own machine and stop depending on whichever machine happened to have them. Reported
# always; installed only when asked, because a fresh install is not the moment to start a 1.5GB
# download behind somebody's back.
if command -v wa >/dev/null 2>&1; then
  TOOLCHAIN_LINE="$(wa toolchain check 2>/dev/null | tail -1)"
  ok "toolchains: ${TOOLCHAIN_LINE:-unknown}"
  case "$TOOLCHAIN_LINE" in
    *"every one resolves"*) ;;
    *)
      warn "this node cannot build itself yet. See: wa toolchain plan"
      if [ "${WA_INSTALL_TOOLCHAIN:-0}" = "1" ]; then
        wa toolchain ensure --yes
      else
        warn "run: wa toolchain ensure --yes   (or re-run this installer with WA_INSTALL_TOOLCHAIN=1)"
      fi
      ;;
  esac
fi

# The sentinel: the process outside the node, for restarts, upgrades, and waking the model on an
# event. A node cannot restart itself, so this is what does it - and a supervisor that has to be
# remembered is a supervisor that is not there when it is needed.
ROOT="${WASM_AGENT_REPO:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/rust/wa-sentinel" ]; then
  warn "sentinel not installed: this installer is a pipe, not a checkout (set WASM_AGENT_REPO=/path/to/wasm-agent)"
fi
if [ -n "$ROOT" ] && [ -d "$ROOT/rust/wa-sentinel" ]; then
  step "building and starting the sentinel"
  if command -v cargo >/dev/null 2>&1; then
    (cd "$ROOT" && cargo build --release --manifest-path rust/wa-sentinel/Cargo.toml 2>&1 | tail -1) || true
    for built in "$ROOT/rust/wa-sentinel/target/release/wa-sentinel" "$ROOT/rust/wa-sentinel/target/release/wa-sentinel.exe"; do
      if [ -x "$built" ]; then
        cp -f "$built" "$DIR/" && ok "$DIR/$(basename "$built")" && "$DIR/$(basename "$built")" restart >/dev/null 2>&1 || true
        break
      fi
    done
  else
    warn "cargo not found, so the sentinel was not built - see: wa toolchain plan"
  fi
fi

printf "\n   ${green}ready.${reset}\n\n"
printf "   ${grey}start chatting:${reset}\n     wa\n\n"
case ":$PATH:" in
  *":$DIR:"*) ;;
  *) warn "add $DIR to PATH, then run: wa" ;;
esac
