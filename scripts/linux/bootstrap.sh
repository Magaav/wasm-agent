#!/usr/bin/env bash
# Make this Linux machine a wasm-agent node from a published prebuilt bundle - one command, no compiler.
#
#   d=~/wasm-agent-bootstrap; [ -d "$d/.git" ] || git clone --depth 1 https://github.com/Magaav/wasm-agent.git "$d" || exit 1; exec bash "$d/scripts/linux/bootstrap.sh"
#
# Paste the same line again later to update: the run is idempotent (same bundle: nothing replaced).
#
# What it does, and every step refuses by name:
#   1. reads releases/index-linux.json over HTTPS from the public repository and picks the newest
#      entry for this machine's architecture (aarch64 or x86_64, glibc);
#   2. downloads the asset, checks its size, sha256(bundle.manifest) against the index, the manifest's
#      files_sha256 against files.sha256, every member against files.sha256, the ELF machine of `wa`,
#      and runs the candidate once - a mismatch installs nothing;
#   3. installs `wa`, `wa-sentinel`, `ui/` and the MCP runtime into the install directory (default
#      ~/.local/bin, the layout a sentinel deploy produces) and the pinned Node (SHASUMS256-verified)
#      the MCP runtime runs on; writes installed.txt (commit, release, via=linux-bootstrap);
#   4. writes <config>/env keys it owns only when absent (the rendezvous, trusted masters, ports);
#   5. installs a systemd --user unit `wa-sentinel.service`; the sentinel (autostart) starts and
#      supervises `wa serve`. Linger is enabled when allowed without sudo, else the one sudo line is printed;
#   6. prints the node's status, its id, and how to pair it with the fleet as a standalone peer.
#
# Options:
#   --check                 resolve and verify, print the plan, change nothing
#   --index URL             index to read (default: WA_LINUX_RELEASE_INDEX_URL, else the public main copy);
#                           file: URLs need WA_LINUX_RELEASE_ALLOW_LOCAL=1 (fixtures)
#   --prefix DIR            install directory (default ~/.local/bin)
#   --port N / --client-port N   node ports (default 8799 / 8800)
#   --rendezvous URL|none   registry the node announces itself to (default https://rendezvous.colmeio.com)
#   --trusted-masters IDS   comma-separated node ids allowed to act as master on this node
#   --no-service            do not install or touch the systemd unit (tests, containers)
#   --adopt                 take over an install this script did not make (it is backed up first)
#   --force                 update even while the node reports a running turn
set -euo pipefail

REPO="Magaav/wasm-agent"
DEFAULT_INDEX="https://raw.githubusercontent.com/$REPO/main/releases/index-linux.json"
index="${WA_LINUX_RELEASE_INDEX_URL:-$DEFAULT_INDEX}"
prefix="$HOME/.local/bin"; port=8799; cport=8800
rendezvous="https://rendezvous.colmeio.com"; masters=; check=0; service=1; adopt=0; force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --index) index=${2:?index URL}; shift 2 ;;
    --prefix) prefix=${2:?prefix}; shift 2 ;;
    --port) port=${2:?port}; shift 2 ;;
    --client-port) cport=${2:?client port}; shift 2 ;;
    --rendezvous) rendezvous=${2:?rendezvous URL or none}; shift 2 ;;
    --trusted-masters) masters=${2:?node ids}; shift 2 ;;
    --no-service) service=0; shift ;;
    --adopt) adopt=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bootstrap: unknown_option: $1" >&2; exit 2 ;;
  esac
done
case "$port$cport" in *[!0-9]*) echo 'bootstrap: port_invalid' >&2; exit 2 ;; esac

say()  { printf 'bootstrap: %s\n' "$*"; }
fail() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }

# ---- 0. prerequisites ----------------------------------------------------------------------------
[ "$(uname -s)" = Linux ] || fail "not_linux: $(uname -s) (Android/Termux: scripts/termux/bootstrap.sh; Windows: scripts/install.ps1)"
case "${PREFIX:-}" in *com.termux*) fail 'termux_detected: Android uses scripts/termux/bootstrap.sh' ;; esac
case "$(uname -m)" in
  aarch64|arm64) target=aarch64-unknown-linux-gnu; elf_machine=b7 ;;
  x86_64|amd64)  target=x86_64-unknown-linux-gnu;  elf_machine=3e ;;
  *) fail "arch_unsupported: $(uname -m) (published: aarch64, x86_64)" ;;
esac
missing=
for tool in curl tar sha256sum python3 od; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
[ -z "$missing" ] || fail "prerequisites_missing:$missing - on Ubuntu: sudo apt-get install -y curl ca-certificates tar coreutils python3"
work="${XDG_CACHE_HOME:-$HOME/.cache}/wasm-agent-bootstrap"
mkdir -p "$work"
tmp=$(mktemp -d "$work/run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fetch() { # URL DEST
  case "$1" in
    https://*|http://*) curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1" ;;
    file://*) [ "${WA_LINUX_RELEASE_ALLOW_LOCAL:-0}" = 1 ] || { say "local_url_refused: $1 (set WA_LINUX_RELEASE_ALLOW_LOCAL=1 for a fixture)"; return 1; }
              cp -f -- "${1#file://}" "$2" ;;
    *) say "url_scheme_refused: $1"; return 1 ;;
  esac
}

# ---- 1. the index entry for this machine -----------------------------------------------------------
fetch "$index" "$tmp/index.json" || fail "index_unreachable: $index"
entry=$(python3 - "$tmp/index.json" "$target" <<'PY'
import json,sys,re
try: doc=json.load(open(sys.argv[1]))
except Exception: print("ERR index_invalid: not JSON"); sys.exit()
if doc.get("schema")!="wasm-agent-linux-release-index" or doc.get("schema_version")!=1:
    print("ERR index_invalid: schema %r v%r is not wasm-agent-linux-release-index v1"%(doc.get("schema"),doc.get("schema_version"))); sys.exit()
for r in doc.get("releases") or []:
    if r.get("target")!=sys.argv[2]: continue
    ok=all(isinstance(r.get(k),str) and r.get(k) for k in ("tag","commit","manifest_sha256","url","node_version")) \
       and isinstance(r.get("size"),int) and re.fullmatch(r"[0-9a-f]{64}",r["manifest_sha256"]) and re.fullmatch(r"[0-9a-f]{40}",r["commit"])
    if not ok: print("ERR index_invalid: malformed entry for %s"%sys.argv[2]); sys.exit()
    print("\t".join([r["tag"],r["commit"],r["manifest_sha256"],r["url"],str(r["size"]),r["node_version"]])); sys.exit()
print("ERR no_release_for_target: the index has no entry for %s"%sys.argv[2])
PY
)
case "$entry" in ERR*) fail "${entry#ERR }" ;; esac
IFS=$'\t' read -r tag commit manifest_sha url size node_version <<< "$entry"
short=$(printf '%.12s' "$commit")
say "release $tag ($short) for $target"

# ---- 2. what is installed, and may this script touch it ---------------------------------------------
record="$prefix/installed.txt"
installed_commit=$(sed -n 's/^commit=//p' "$record" 2>/dev/null | head -1 || true)
installed_manifest=$(sed -n 's/^manifest_sha256=//p' "$record" 2>/dev/null | head -1 || true)
installed_via=$(sed -n 's/^via=//p' "$record" 2>/dev/null | head -1 || true)
state=fresh
if [ -e "$prefix/wa" ] || [ -f "$record" ]; then
  if [ "$installed_via" = linux-bootstrap ]; then state=update
  elif [ "$adopt" = 1 ]; then state=adopt
  else fail "existing_install_not_ours: $prefix holds a wa this script did not install (${installed_via:-no record}, commit ${installed_commit:-unknown}); a sentinel/deploy-managed node updates through its own deploy. Re-run with --adopt to replace it (backed up first), or --prefix DIR for a separate install"
  fi
fi
if [ "$state" = update ] && [ "$installed_manifest" = "$manifest_sha" ] && [ -x "$prefix/wa" ]; then
  state=current
fi
say "install $prefix: $state${installed_commit:+ (installed ${installed_commit:0:12})}"

# ---- 3. download and verify (always, even when current: --check proves the published bytes) ---------
if [ "$state" != current ] || [ "$check" = 1 ]; then
  fetch "$url" "$tmp/bundle.tar.gz" || fail "download_failed: $url"
  got=$(wc -c < "$tmp/bundle.tar.gz" | tr -d ' ')
  [ "$got" = "$size" ] || fail "download_truncated: $got bytes, the index records $size"
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/x" --no-same-owner || fail 'archive_invalid'
  dirs=$(find "$tmp/x" -mindepth 1 -maxdepth 1 | wc -l)
  bundle=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ "$dirs" = 1 ] && [ -n "$bundle" ] || fail 'archive_layout_invalid: expected one top-level directory'
  [ -f "$bundle/bundle.manifest" ] && [ -f "$bundle/files.sha256" ] || fail 'bundle_incomplete: bundle.manifest/files.sha256 missing'
  [ "$(sha256sum "$bundle/bundle.manifest" | cut -d' ' -f1)" = "$manifest_sha" ] \
    || fail 'hash_mismatch: bundle.manifest does not match the index; nothing installed'
  mval() { sed -n "s/^$1=//p" "$bundle/bundle.manifest" | head -1; }
  [ "$(mval source_commit)" = "$commit" ] || fail 'manifest_commit_mismatch'
  [ "$(mval target_triple)" = "$target" ] || fail "manifest_target_mismatch: $(mval target_triple)"
  [ "$(sha256sum "$bundle/files.sha256" | cut -d' ' -f1)" = "$(mval files_sha256)" ] || fail 'hash_mismatch: files.sha256'
  ( cd "$bundle" && sha256sum --quiet --strict -c files.sha256 ) >/dev/null 2>&1 || fail 'hash_mismatch: a bundle member differs from files.sha256'
  listed=$(wc -l < "$bundle/files.sha256"); present=$(cd "$bundle" && find . -type f ! -name bundle.manifest ! -name files.sha256 | wc -l)
  [ "$listed" = "$present" ] || fail "bundle_unlisted_files: $present files, $listed listed"
  for f in wa wa-sentinel; do
    [ "$(od -An -tx1 -j18 -N1 "$bundle/$f" | tr -d ' ')" = "$elf_machine" ] || fail "elf_machine_mismatch: $f is not built for $target"
  done
  "$bundle/wa" --version >/dev/null 2>&1 || fail 'candidate_does_not_run: wa --version failed on this machine (glibc too old?)'
  say "verified: $(mval wa_version) - every member matches"
fi

if [ "$check" = 1 ]; then
  say "check only: would install $tag into $prefix ($state), Node v$node_version, rendezvous ${rendezvous}, service $([ $service = 1 ] && echo wa-sentinel.service || echo none)"
  exit 0
fi

# ---- 4. a running turn is not interrupted unless asked -----------------------------------------------
health=$(curl -fsS -m 3 "http://127.0.0.1:$port/health" 2>/dev/null || true)
if [ "$state" != current ] && [ -n "$health" ] && [ "$force" = 0 ] \
   && printf '%s' "$health" | grep -q '"node_state":{[^}]*"state":"busy"'; then
  fail 'node_busy: the node on this port is running a turn; re-run when idle, or --force'
fi

# ---- 5. install the files ----------------------------------------------------------------------------
mkdir -p "$prefix"
if [ "$state" = adopt ]; then
  backup="$prefix.pre-bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "$prefix" "$backup" && say "previous install backed up to $backup"
fi
if [ "$state" != current ]; then
  if [ "$service" = 1 ] && systemctl --user is-active -q wa-sentinel.service 2>/dev/null; then
    systemctl --user stop wa-sentinel.service || true
  fi
  [ -f "$prefix/wa" ] && cp -p "$prefix/wa" "$prefix/wa.prev"
  for f in wa wa-sentinel; do install -m755 "$bundle/$f" "$prefix/$f.new" && mv -f "$prefix/$f.new" "$prefix/$f"; done
  for d in ui scripts; do
    rm -rf "$prefix/$d.new" "$prefix/$d.old"
    cp -r "$bundle/$d" "$prefix/$d.new"
    if [ "$d" = scripts ] && [ -d "$prefix/scripts" ]; then
      # Keep what a later sentinel deploy shipped beside the runtime (deploy.sh, lib/, jobs); refresh the runtime.
      cp -rn "$prefix/scripts/." "$prefix/scripts.new/" 2>/dev/null || true
      cp -f "$bundle/scripts/"* "$prefix/scripts.new/"
    fi
    [ -d "$prefix/$d" ] && mv "$prefix/$d" "$prefix/$d.old"
    mv "$prefix/$d.new" "$prefix/$d" && rm -rf "$prefix/$d.old"
  done
  {
    echo "commit=${commit:0:8}"
    echo "branch=main"
    echo "dirty=0"
    echo "sha256=$(sha256sum "$prefix/wa" | cut -d' ' -f1)"
    echo "sentinel_sha256=$(sha256sum "$prefix/wa-sentinel" | cut -d' ' -f1)"
    echo "release=$tag"
    echo "source_commit=$commit"
    echo "manifest_sha256=$manifest_sha"
    echo "target=$target"
    echo "install_dir=$prefix"
    echo "source_provenance=release-bundle"
    echo "via=linux-bootstrap"
    echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$record.tmp" && mv -f "$record.tmp" "$record"
  say "installed $tag into $prefix"
fi

# ---- 6. Node for the MCP runtime (web search/read, mail, WhatsApp bridges) ---------------------------
node_dir="$prefix/node"
[ -e "$node_dir" ] && [ ! -d "$node_dir" ] && node_dir="$HOME/.wasm-agent/node"
if [ "$("$node_dir/bin/node" --version 2>/dev/null)" != "v$node_version" ]; then
  case "$target" in aarch64*) narch=arm64 ;; *) narch=x64 ;; esac
  archive="node-v$node_version-linux-$narch.tar.gz"
  say "installing Node v$node_version (SHASUMS256-verified) into $node_dir"
  fetch "https://nodejs.org/dist/v$node_version/$archive" "$tmp/$archive" || fail "node_download_failed: $archive"
  fetch "https://nodejs.org/dist/v$node_version/SHASUMS256.txt" "$tmp/SHASUMS256.txt" || fail 'node_shasums_unreachable'
  expected=$(awk -v f="$archive" '$2==f {print $1}' "$tmp/SHASUMS256.txt")
  [ -n "$expected" ] && [ "$expected" = "$(sha256sum "$tmp/$archive" | cut -d' ' -f1)" ] || fail 'node_hash_mismatch: not installed'
  rm -rf "$node_dir.new" && mkdir -p "$node_dir.new" && tar -xzf "$tmp/$archive" -C "$node_dir.new" --strip-components=1 \
    && rm -rf "$node_dir" && mv "$node_dir.new" "$node_dir" || fail 'node_install_failed'
fi

# ---- 7. configuration keys this script owns (written only when absent; nothing secret) ---------------
config="${WASM_AGENT_HOME:-$HOME}/.wasm-agent"
mkdir -p "$config" && chmod 700 "$config"
env_file="$config/env"
touch "$env_file" && chmod 600 "$env_file"
set_key() { grep -q "^$1=" "$env_file" || { printf '%s=%s\n' "$1" "$2" >> "$env_file"; say "config: $1 set"; }; }
[ "$rendezvous" = none ] || set_key WASM_AGENT_RENDEZVOUS "$rendezvous"
[ -n "$masters" ] && set_key WASM_AGENT_TRUSTED_MASTERS "$masters"
set_key WA_NODE "$node_dir/bin/node"

# ---- 8. the supervisor -------------------------------------------------------------------------------
if [ "$service" = 1 ]; then
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1 \
    || fail 'systemd_user_unavailable: no systemd --user session (log in over SSH as this user, or use --no-service and start: wa-sentinel start)'
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/wa-sentinel.service.new" <<UNIT
# Written by scripts/linux/bootstrap.sh. The sentinel (autostart) starts and supervises wa serve.
[Unit]
Description=wasm-agent sentinel (starts, restarts and upgrades the node from outside)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$prefix/wa-sentinel watch
Restart=always
RestartSec=5
WorkingDirectory=$prefix
EnvironmentFile=-$env_file
Environment=WA_INSTALL_DIR=$prefix
Environment=WA_SENTINEL_AUTOSTART=1
Environment=WA_SENTINEL_SUPERVISOR=user:wa-sentinel.service
Environment=WA_SENTINEL_SCRIPTS=$prefix/scripts
Environment=WA_SENTINEL_WAKE_BUDGET=6
Environment=WASM_AGENT_PORT=$port
Environment=WASM_AGENT_CLIENT_PORT=$cport
Environment=PATH=$prefix:$node_dir/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
UNIT
  mv -f "$unit_dir/wa-sentinel.service.new" "$unit_dir/wa-sentinel.service"
  systemctl --user daemon-reload
  systemctl --user enable -q wa-sentinel.service
  systemctl --user restart wa-sentinel.service
  if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
    loginctl enable-linger "$(id -un)" 2>/dev/null \
      || say "to keep the node running after logout and across reboots, run once: sudo loginctl enable-linger $(id -un)"
  fi
  say 'waiting for the node to answer'
  for _ in $(seq 1 60); do curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 1; done
fi

# ---- 9. status and the next step -------------------------------------------------------------------
echo
if curl -fsS -m 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
  say "node up on 127.0.0.1:$port (UI) / $cport (client bridge) - $("$prefix/wa" --version 2>/dev/null | head -1)"
elif [ "$service" = 1 ]; then
  say "node not answering yet - check: $prefix/wa-sentinel status ; journalctl --user -u wa-sentinel"
else
  say "installed (no service): start it with  WA_SENTINEL_AUTOSTART=1 WA_INSTALL_DIR=$prefix WASM_AGENT_PORT=$port WASM_AGENT_CLIENT_PORT=$cport $prefix/wa-sentinel start"
fi
node_id=$("$prefix/wa" node 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("node_id",""))' 2>/dev/null || true)
cat <<NEXT

  Next steps
  1. Model credentials:   $prefix/wa paths      (put your provider key in $env_file)
  2. This node's id:      ${node_id:-run: $prefix/wa node}
  3. Join the fleet as a standalone peer (registry: ${rendezvous}):
       - it announces itself to the rendezvous on start (WASM_AGENT_RENDEZVOUS in $env_file);
       - pin the masters that may drive it: add WASM_AGENT_TRUSTED_MASTERS=<master node id>[,...]
         to $env_file, then: systemctl --user restart wa-sentinel
         (unset, the rendezvous's network admins are the authority - docs/RENDEZVOUS.md, Guest nodes);
       - from a master: the nodes tool lists it; remote {node:"<name>", capability:"ls", path:"/"} reaches it.
  4. Update later: paste the same install line again.
NEXT
