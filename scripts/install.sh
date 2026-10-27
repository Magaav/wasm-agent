#!/usr/bin/env bash
# wasm-agent installer for Linux/macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
#
# Installs a `wa` command that talks to your wasm-agent host over SSH.
set -euo pipefail

HOST_ALIAS="${WASM_AGENT_HOST:-openclaw.ohana}"
DIR="${WASM_AGENT_BIN_DIR:-$HOME/.local/bin}"

# Where does this machine run its node from? The same file the deploy gate reads, so "where the node lives"
# has one answer here too - and so this installer can tell whether the supervisor it is placing is the one the
# sentinel service will start. Measured on the cloud node: `~/.local/bin/wa-sentinel` (user-owned) and
# `/usr/local/bin/wa-sentinel` (root-owned) were the same binary at two paths and `$PATH` quietly preferred
# the first, which is the same class of failure as the node that looped 61,117 times.
WA_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/service-target.sh"
HAVE_LIB=0
if [ -f "$WA_LIB" ]; then . "$WA_LIB"; HAVE_LIB=1; fi
die() { printf "     ${yellow}!${reset}  %s\n" "$1" >&2; exit 1; }

node_service_dir() { # -> the directory the sentinel service runs its supervisor from, empty when unknowable
  # Explicitly, not `[ ... ] && cmd`: this file runs under `set -e`, and a false test as the last status of a
  # function called in a command substitution would end the installer silently.
  if [ "$HAVE_LIB" = "1" ]; then wa_sentinel_service_dir; fi
}

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
    (cd "$ROOT" && cargo build --release --locked --manifest-path rust/wa-sentinel/Cargo.toml 2>&1 | tail -1) || true
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
  # ...but a supervisor is only installed where the service starts it. `wa-sentinel` in the wrong directory is
  # the same defect as a node in the wrong directory: the service keeps running the old copy, and everything
  # that reports success is reading the one nobody runs. Name both paths, place it where the service looks
  # when that directory is writable, and refuse to claim success when it is not.
  #
  # This comes first: the restart below asks the manager to bring the unit up, and the unit's `ExecStart=` is
  # the path this puts the new binary at. Restarting before placing would start the copy nobody replaced.
  SENTINEL_SERVICE_DIR="$(node_service_dir)"
  if [ -n "$SENTINEL_SERVICE_DIR" ] && ! wa_same_dir "$SENTINEL_SERVICE_DIR" "$DIR"; then
    warn "the sentinel service runs $SENTINEL_SERVICE_DIR/wa-sentinel, not $DIR/wa-sentinel"
    if [ -w "$SENTINEL_SERVICE_DIR" ]; then
      cp -f "$DIR/wa-sentinel" "$SENTINEL_SERVICE_DIR/wa-sentinel" \
        && ok "$SENTINEL_SERVICE_DIR/wa-sentinel (the path the service starts)" \
        || die "could not place the supervisor at $SENTINEL_SERVICE_DIR/wa-sentinel; the service would keep starting the old one"
    else
      die "$SENTINEL_SERVICE_DIR is not writable by $(id -un): install it with sudo (install -m 755 $DIR/wa-sentinel $SENTINEL_SERVICE_DIR/wa-sentinel), or point the unit at $DIR/wa-sentinel; this installer will not report success while the service and the installed supervisor disagree"
    fi
  fi
  # The supervisor has to *start*, and its refusal must not be swallowed: `|| true` here printed a
  # successful install while the manager refused to bring the unit up - `Interactive authentication
  # required` for a system unit from an unprivileged shell, a unit that no longer exists, a control group
  # it cannot create - and the operator found out when nothing could restart their node. The sentinel's own
  # words are where the manager's reason is, so they are printed, not discarded.
  if SENTINEL_START="$("$DIR/wa-sentinel" restart 2>&1)"; then
    SENTINEL_SAID="$(printf '%s\n' "$SENTINEL_START" | sed 's/^  *//' | sed -n '/./p')"
    ok "sentinel: $(printf '%s\n' "$SENTINEL_SAID" | head -1)"
    printf '%s\n' "$SENTINEL_SAID" | tail -n +2 | sed 's/^/     /'
  else
    printf '\n   the sentinel did not start, and nothing else here can restart or upgrade this node:\n' >&2
    printf '%s\n' "$SENTINEL_START" | sed 's/^/     /' >&2
    printf '   fix the cause, then run: %s restart\n\n' "$DIR/wa-sentinel" >&2
    exit 1
  fi
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

# The MCP runtime: `lua/core/mcp.lua` and `lua/core/web.lua` spawn these Node scripts for every
# `web_search`/`web_read` call and for the WhatsApp connector. `deploy.sh` ships them when it upgrades a
# running install; a *fresh* install shipped only `upgrade.sh`, so on a brand-new node every web tool
# answered `web_adapter_not_installed` and the connector answered `mcp_script_directory_unbound`. The Lua
# core is compiled into the binary - these files are not, and nothing put them on disk.
#
# Two destinations, on purpose. `<install>/scripts` is where `WA_INSTALL_DIR` points when the sentinel
# starts the service; `<home>/.wasm-agent/scripts` is the node's own data directory, the one path
# `host.paths()` always reports with no environment variable and no install layout involved. A node
# started by hand, or a node in a brand-new cluster, therefore finds the runtime too.
if [ "$HAVE_LIB" = "1" ]; then
  MCP_DATA_DIR="$(wa_config_dir)"
else
  MCP_DATA_DIR="${WASM_AGENT_HOME:-$HOME}/.wasm-agent"
fi
MCP_RUNTIME="mcp-client.mjs mcp-client-core.mjs mcp-server-core.mjs mcp-session.mjs mcp-web.mjs mcp-whatsapp.mjs web-core.mjs web-http-outcomes.mjs"
MCP_MISSING=""
for MCP_TARGET in "$SCRIPTS_DIR" "$MCP_DATA_DIR/scripts"; do
  mkdir -p "$MCP_TARGET" || { MCP_MISSING="$MCP_MISSING $MCP_TARGET"; continue; }
  for MCP_FILE in $MCP_RUNTIME; do
    if [ -n "$ROOT" ] && [ -f "$ROOT/scripts/$MCP_FILE" ]; then
      if cp -f "$ROOT/scripts/$MCP_FILE" "$MCP_TARGET/$MCP_FILE"; then continue; fi
    elif command -v curl >/dev/null 2>&1; then
      if curl -fsSL "https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/$MCP_FILE" \
        -o "$MCP_TARGET/$MCP_FILE" 2>/dev/null; then continue; fi
    fi
    MCP_MISSING="$MCP_MISSING $MCP_TARGET/$MCP_FILE"
  done
done
if [ -z "$MCP_MISSING" ]; then
  ok "MCP runtime: mcp-web.mjs, mcp-whatsapp.mjs and their imports"
else
  warn "MCP runtime incomplete (missing:$MCP_MISSING) - web_search, web_read and the WhatsApp connector refuse until it is installed"
fi

# Node is the runtime those scripts need. Shipping the scripts without it is the same half-fix one level
# down: the Lua core is in the binary, the `.mjs` files are on disk, and both are inert if nothing can
# execute them, which is what a device with no Node on its PATH produced.
#
# Pinned, not "latest": an installer that silently changes a runtime under a working node is a worse
# surprise than an old one. The build is verified against the checksums Node publishes for that release,
# extracted beside the binary, and named in `<config>/env` as WA_NODE - the file the host reads at startup
# - so the node's tools never depend on the PATH a service happened to inherit.
NODE_VERSION="24.22.1"
NODE_MIN_MAJOR="18"
NODE_BIN=""
node_major() { "$1" --version 2>/dev/null | sed 's/^v//' | cut -d. -f1; }
node_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
node_platform() {
  node_os="$(uname -s 2>/dev/null)"; node_arch="$(uname -m 2>/dev/null)"
  case "$node_os" in Linux) node_os=linux ;; Darwin) node_os=darwin ;; *) return 1 ;; esac
  case "$node_arch" in x86_64|amd64) node_arch=x64 ;; arm64|aarch64) node_arch=arm64 ;; *) return 1 ;; esac
  printf '%s-%s' "$node_os" "$node_arch"
}
ensure_node() {
  if [ -n "${WA_NODE:-}" ] && [ -x "${WA_NODE}" ]; then
    NODE_BIN="$WA_NODE"; ok "node: $NODE_BIN (WA_NODE)"
  elif [ -x "$DIR/node/bin/node" ]; then
    # Re-running the installer must not re-download a runtime that is already there and working.
    NODE_BIN="$DIR/node/bin/node"; ok "node: $NODE_BIN ($("$NODE_BIN" --version 2>/dev/null), already installed)"
  else
    node_existing="$(command -v node 2>/dev/null || true)"
    node_existing_major=""
    if [ -n "$node_existing" ]; then node_existing_major="$(node_major "$node_existing")"; fi
    if [ -n "$node_existing" ] && [ -n "$node_existing_major" ] && [ "$node_existing_major" -ge "$NODE_MIN_MAJOR" ]; then
      NODE_BIN="$node_existing"
      ok "node: $NODE_BIN ($("$NODE_BIN" --version 2>/dev/null))"
    else
      node_pair="$(node_platform)" || {
        warn "node: no pinned build for this platform - install Node $NODE_MIN_MAJOR+ and set WA_NODE"
        return 1
      }
      node_archive="node-v$NODE_VERSION-$node_pair.tar.gz"
      node_tmp="$(mktemp -d)"
      if command -v curl >/dev/null 2>&1 \
        && curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/$node_archive" -o "$node_tmp/$node_archive" 2>/dev/null \
        && curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" -o "$node_tmp/SHASUMS256.txt" 2>/dev/null; then
        node_expected="$(awk -v f="$node_archive" '$2==f {print $1}' "$node_tmp/SHASUMS256.txt")"
        node_actual="$(node_sha256 "$node_tmp/$node_archive")"
        if [ -z "$node_expected" ] || [ "$node_expected" != "$node_actual" ]; then
          warn "node: checksum mismatch for $node_archive - refusing to install an unverified runtime"
          rm -rf "$node_tmp"; return 1
        fi
        rm -rf "$DIR/node"; mkdir -p "$DIR/node"
        if tar -xzf "$node_tmp/$node_archive" -C "$DIR/node" --strip-components=1 2>/dev/null; then
          NODE_BIN="$DIR/node/bin/node"
          ok "node: $NODE_BIN (v$NODE_VERSION, checksum verified)"
        else
          warn "node: could not extract $node_archive"; rm -rf "$node_tmp"; return 1
        fi
      else
        warn "node: could not download v$NODE_VERSION from nodejs.org - install Node $NODE_MIN_MAJOR+ and set WA_NODE"
        rm -rf "$node_tmp"; return 1
      fi
      rm -rf "$node_tmp"
    fi
  fi
  if [ "$HAVE_LIB" = "1" ]; then NODE_ENV_FILE="$(wa_config_dir)/env"; else NODE_ENV_FILE="${WASM_AGENT_HOME:-$HOME}/.wasm-agent/env"; fi
  if [ -f "$NODE_ENV_FILE" ] && grep -q '^WA_NODE=' "$NODE_ENV_FILE" 2>/dev/null; then
    node_recorded="$(sed -n 's/^WA_NODE=//p' "$NODE_ENV_FILE" | tail -1)"
    if [ ! -x "$node_recorded" ]; then
      warn "node: $NODE_ENV_FILE names WA_NODE=$node_recorded, which is not executable - fix or remove that line"
    fi
  else
    mkdir -p "$(dirname "$NODE_ENV_FILE")"
    printf 'WA_NODE=%s\n' "$NODE_BIN" >> "$NODE_ENV_FILE"
    ok "node: WA_NODE=$NODE_BIN in $NODE_ENV_FILE"
  fi
  if [ -f "$SCRIPTS_DIR/mcp-web.mjs" ] && "$NODE_BIN" --check "$SCRIPTS_DIR/mcp-web.mjs" 2>/dev/null; then
    ok "node: parses the MCP runtime"
  else
    warn "node: $NODE_BIN cannot parse $SCRIPTS_DIR/mcp-web.mjs - web_search, web_read and the WhatsApp connector will refuse"
  fi
}
ensure_node || true

# The skills the node needs to know how to update itself. Delivered as a skill rather than a
# paragraph in AGENTS.md: only `name` and `description` enter the prompt, and the body loads when the
# task matches, so the procedure costs nothing per turn and can be as long as it needs to be.
#
# The directory is the node's own scan root - `<home>/.wasm-agent/skills`, the same expression
# `lua/core/paths.lua` uses for `paths.config()` and `scripts/verify-install.sh` uses to check it - and not
# `$DIR`, which is where the *command* lives and which no node ever reads. The comment here used to claim the
# install directory and the config directory were the same place; on this project they are not, and a skill
# written into $DIR/skills is a skill the node never loads.
if [ "$HAVE_LIB" = "1" ]; then
  SKILLS_DIR="$(wa_config_dir)/skills/self-update"
else
  SKILLS_DIR="${WASM_AGENT_HOME:-$HOME}/.wasm-agent/skills/self-update"
fi
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
