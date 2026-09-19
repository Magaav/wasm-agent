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
#
# Piped from the network there is no checkout, so the binary is fetched from the host that runs the
# node - the same place the rest of this installer's knowledge comes from. Only when *that* fails is
# the absence reported, because "you have no supervisor" is a fact the operator must not have to
# infer from a warning about a missing repository.
ROOT="${WASM_AGENT_REPO:-}"
SENTINEL_GOT=0
if command -v scp >/dev/null 2>&1; then
  step "fetching the sentinel from ${HOST_ALIAS}"
  if scp -q -o BatchMode=yes "${HOST_ALIAS}:~/.local/bin/wa-sentinel" "$DIR/wa-sentinel" 2>/dev/null \
     || scp -q -o BatchMode=yes "${HOST_ALIAS}:~/.local/bin/wa-sentinel.exe" "$DIR/wa-sentinel" 2>/dev/null; then
    chmod +x "$DIR/wa-sentinel" 2>/dev/null || true
    [ -x "$DIR/wa-sentinel" ] && SENTINEL_GOT=1
  fi
fi
if [ "$SENTINEL_GOT" = "0" ] && [ -n "$ROOT" ] && [ -d "$ROOT/rust/wa-sentinel" ]; then
  step "building the sentinel from $ROOT"
  if command -v cargo >/dev/null 2>&1; then
    (cd "$ROOT" && cargo build --release --manifest-path rust/wa-sentinel/Cargo.toml 2>&1 | tail -1) || true
    for built in "$ROOT/rust/wa-sentinel/target/release/wa-sentinel" "$ROOT/rust/wa-sentinel/target/release/wa-sentinel.exe"; do
      if [ -x "$built" ]; then
        cp -f "$built" "$DIR/" && SENTINEL_GOT=1
        break
      fi
    done
  else
    warn "cargo not found, so the sentinel could not be built - see: wa toolchain plan"
  fi
fi
if [ "$SENTINEL_GOT" = "1" ]; then
  ok "$DIR/wa-sentinel"
  "$DIR/wa-sentinel" restart >/dev/null 2>&1 || true
else
  warn "no sentinel: this node cannot restart or upgrade itself. Set WASM_AGENT_REPO to a checkout, or install wa-sentinel by hand."
fi

# `scripts/upgrade.sh` beside the binary, which is where the sentinel looks for it. A supervisor that
# can restart but not upgrade is half a supervisor, and the failure is silent: the request is
# accepted, the script is not found, and the node simply does not change.
SCRIPTS_DIR="$DIR/scripts"
mkdir -p "$SCRIPTS_DIR"
UPGRADE_GOT=0
if [ -n "$ROOT" ] && [ -f "$ROOT/scripts/upgrade.sh" ]; then
  cp -f "$ROOT/scripts/upgrade.sh" "$SCRIPTS_DIR/upgrade.sh" && UPGRADE_GOT=1
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/upgrade.sh" \
    -o "$SCRIPTS_DIR/upgrade.sh" 2>/dev/null && UPGRADE_GOT=1
fi
if [ "$UPGRADE_GOT" = "1" ]; then
  chmod +x "$SCRIPTS_DIR/upgrade.sh" 2>/dev/null || true
  ok "$SCRIPTS_DIR/upgrade.sh"
else
  warn "scripts/upgrade.sh was not installed - the sentinel can restart but not upgrade until it is"
fi

# The skills the node needs to know how to update itself. Delivered as a skill rather than a
# paragraph in AGENTS.md: only `name` and `description` enter the prompt, and the body loads when the
# task matches, so the procedure costs nothing per turn and can be as long as it needs to be.
# `~/.wasm-agent/skills` is the node-scoped place it scans, which is this install directory.
SKILLS_DIR="$DIR/skills/self-update"
mkdir -p "$SKILLS_DIR"
SKILL_GOT=0
if [ -n "$ROOT" ] && [ -f "$ROOT/skills/self-update/SKILL.md" ]; then
  cp -f "$ROOT/skills/self-update/SKILL.md" "$SKILLS_DIR/SKILL.md" && SKILL_GOT=1
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "https://raw.githubusercontent.com/Magaav/wasm-agent/main/skills/self-update/SKILL.md" \
    -o "$SKILLS_DIR/SKILL.md" 2>/dev/null && SKILL_GOT=1
fi
if [ "$SKILL_GOT" = "1" ]; then
  ok "$SKILLS_DIR/SKILL.md"
else
  warn "skills/self-update was not installed - this node will not know how to update itself"
fi

printf "\n   ${green}ready.${reset}\n\n"
printf "   ${grey}start chatting:${reset}\n     wa\n\n"
case ":$PATH:" in
  *":$DIR:"*) ;;
  *) warn "add $DIR to PATH, then run: wa" ;;
esac
