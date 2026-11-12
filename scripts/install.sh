#!/bin/sh
# wasm-agent: ONE command installs a node, and the same command updates it.
#
#   curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --join https://rendezvous.colmeio.com
#   curl -fsSL .../install.sh | sh -s -- --check          # resolve and verify; change nothing
#
# WHAT THIS FILE IS, AND WHAT IT IS NOT. It is the FRONT DOOR: it says which platform this is, which
# release channel that platform has, fetches that channel's installer core at ONE reviewed path, and
# hands every option to it. It is not a second installer. The core is the reviewed script that already
# owns the verifying install (`scripts/linux/bootstrap.sh`: index entry -> size -> sha256(bundle.manifest)
# -> manifest commit/target -> sha256(files.sha256) -> every member -> ELF machine -> run the candidate
# -> install -> record). This file adds no second copy of that chain to drift away from it.
#
# WHY A FRONT DOOR AT ALL. Measured 11/11: bringing up a Linux node by hand took ~5 steps and ~40 min
# (apt toolchain, rustup, clone, provision the code-mode assets, prepare, cold release build), because the
# old `scripts/install.sh` installed an SSH wrapper that talks to somebody else's node - it never
# installed a node. The published bundle channel (`releases/index-linux.json` + a prebuilt bundle: no
# compiler, no clone) existed, but reaching it needed a git clone launcher. This is the one line a new
# machine needs: no git, no cargo, no checkout, no toolchain - only `curl` + `tar` + `sha256sum` +
# `python3`, which are checked and named before anything is downloaded.
#
# THE CHANNELS, because "install from GitHub" is only true where a channel is published:
#
#   Linux (glibc or musl, x86_64 or aarch64)  releases/index-linux.json -> scripts/linux/bootstrap.sh
#   Android / Termux (aarch64)                the phone updater track    -> scripts/termux/bootstrap.sh
#   macOS                                     NO published bundle yet; says so, and what to run instead
#   Windows                                   NO published bundle yet; says so, and points at install.ps1
#
# A platform with no published bundle is a NAMED REFUSAL here, before anything is downloaded - never a
# failed download of an asset that was never published.
#
# THE PIN. The index entry that names the bundle also names the commit it was built from, and the core is
# fetched from THAT commit, not from `main`: the installer a node runs is the installer of the release it
# is installing. When the entry carries `installer_sha256` the fetched core is checked against it and a
# mismatch installs nothing (`installer_hash_mismatch`). Entries published before that field existed are
# still installable; the front door then prints `installer_pin=absent` and the commit it fetched from,
# rather than pretending to a check it did not make.
#
# AFTER THE INSTALL, `wa update` IS THIS FILE. A release bundle carries `scripts/install.sh` (these bytes,
# pinned by the bundle's own files.sha256) and the core installs it into `<prefix>/scripts/`, so a node
# updates with no checkout and no clone: `wa update` runs the neighbour of its own binary. Install and
# update are one path because they are one command here; `--update` is the default action, spelled out so
# an operator can say what they mean.
#
# Options (after `sh -s --`):
#   --check                 resolve the channel and verify the published bundle; install nothing
#   --update                install the newest published bundle (the default; identical path)
#   --rollback              put back the binary pair the last install replaced (Linux; named refusal when
#                           there is no recorded previous release)
#   --join URL|none         announce this node to a fleet registry (Linux: WASM_AGENT_RENDEZVOUS). `none`
#                           keeps it standalone. This is the FLEET JOIN, not a binding: binding operators
#                           to a device is an interactive consent (`wa bind <fabric-url>`, type BIND), and
#                           an installer must never type consent on the operator's behalf.
#   --prefix DIR            install directory (default ~/.local/bin; Linux only)
#   --port N                node UI port (default 8799; Linux only)
#   --client-port N         client bridge port (default 8800; Linux only)
#   --no-service            do not install or touch the systemd --user unit (Linux only)
#   --adopt                 replace an install this channel did not make (backed up first; Linux only)
#   --force                 install even while the node reports a running turn (Linux only)
#   --trusted-masters IDS   node ids allowed to act as master on this node (Linux only)
#   --ref REF               ref the core is fetched from (default main; WA_INSTALL_REF overrides)
#   --base URL              repository endpoint the core is fetched from, without the ref (default
#                           https://raw.githubusercontent.com/Magaav/wasm-agent; WA_INSTALL_BASE
#                           overrides; `file://` needs WA_INSTALL_ALLOW_LOCAL=1)
#   --repo DIR              use the core from this checkout instead of the network (dev/test path)
#   -h, --help              this text
#
# Knobs: WA_INSTALL_BASE, WA_INSTALL_REF, WA_INSTALL_DIR, WA_INSTALL_ALLOW_LOCAL=1 (file:// fixtures),
# WA_OFFLINE=1 (never touch the network; the core must then come from --repo).
#
# Exit codes: 0 done or nothing to do; 2 usage/unknown option; 1 a named refusal (the core's own word is
# printed as the core printed it). Nothing is installed on any non-zero exit.
set -eu
WA_INSTALL_FRONT_DOOR=1

REPO_SLUG="Magaav/wasm-agent"
BASE="${WA_INSTALL_BASE:-https://raw.githubusercontent.com/$REPO_SLUG}"
REF="${WA_INSTALL_REF:-main}"
PREFIX_DIR="${WA_INSTALL_DIR:-$HOME/.local/bin}"
REPO_DIR="${WA_INSTALL_REPO:-}"
ACTION=install
JOIN=
JOIN_GIVEN=0
ROLLBACK=0
CORE_ARGS=
CORE_REF=
WANT_PIN=absent

say()  { printf 'install: %s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'TEXT'
wasm-agent installer - one command, then the same command to update.

  curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
  curl -fsSL .../install.sh | sh -s -- --join https://rendezvous.colmeio.com

  --check                 resolve the channel and verify the published bundle; install nothing
  --update                install the newest published bundle (the default)
  --rollback              put back the binary pair the last install replaced (Linux)
  --join URL|none         announce this node to a fleet registry / keep it standalone (Linux)
  --prefix DIR            install directory (default ~/.local/bin; Linux)
  --port N                node UI port (default 8799; Linux)
  --client-port N         client bridge port (default 8800; Linux)
  --no-service            do not install or touch the systemd --user unit (Linux)
  --adopt                 replace an install this channel did not make (backed up first; Linux)
  --force                 install even while the node reports a running turn (Linux)
  --trusted-masters IDS   node ids allowed to act as master on this node (Linux)
  --ref REF               ref the core is fetched from (default main)
  --base URL              repository endpoint, without the ref
  --repo DIR              use the core from this checkout instead of the network
  -h, --help              this text
TEXT
}

# One argument per line, so a value containing a space (a path) survives: the list is split on newline only.
push() {
  if [ -z "$CORE_ARGS" ]; then CORE_ARGS="$1"; else CORE_ARGS="$CORE_ARGS
$1"; fi
}
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1_value_required"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) ACTION=check; shift ;;
    --update) ACTION=install; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --join) need_value --join "$@"; JOIN="$2"; JOIN_GIVEN=1; shift 2 ;;
    --join=*) JOIN="${1#--join=}"; JOIN_GIVEN=1; shift ;;
    --rendezvous) need_value --rendezvous "$@"; JOIN="$2"; JOIN_GIVEN=1; shift 2 ;;
    --prefix) need_value --prefix "$@"; PREFIX_DIR="$2"; shift 2 ;;
    --prefix=*) PREFIX_DIR="${1#--prefix=}"; shift ;;
    --port|--client-port|--trusted-masters) need_value "$1" "$@"; push "$1"; push "$2"; shift 2 ;;
    --no-service|--adopt|--force) push "$1"; shift ;;
    --ref) need_value --ref "$@"; REF="$2"; shift 2 ;;
    --base) need_value --base "$@"; BASE="${2%/}"; shift 2 ;;
    --base=*) BASE="${1#--base=}"; BASE="${BASE%/}"; shift ;;
    --repo) need_value --repo "$@"; REPO_DIR="$2"; shift 2 ;;
    --repo=*) REPO_DIR="${1#--repo=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown_option: $1 (see --help)" ;;
  esac
done
case "$PREFIX_DIR" in /*) ;; *) die "prefix_not_absolute: $PREFIX_DIR" ;; esac

# ---- 1. what is this machine ---------------------------------------------------------------------
# `uname` is taken from PATH (not a hardcoded command) because the platform matrix is tested by putting
# fixture answers on PATH (scripts/test-install.sh) - the only way to prove the mapping on one host.
os=$(uname -s 2>/dev/null || echo unknown)
arch=$(uname -m 2>/dev/null || echo unknown)
termux=0
case "${PREFIX:-}" in *com.termux*) termux=1 ;; esac
case "$os" in
  Linux) os=linux ;;
  Android) os=android; termux=1 ;;
  Darwin) os=macos ;;
  MSYS*|MINGW*|CYGWIN*) os=windows ;;
esac
[ "$termux" = 1 ] && os=android
case "$arch" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
esac

case "$os" in
  linux) CORE_PATH=scripts/linux/bootstrap.sh; CHANNEL='linux bundle (releases/index-linux.json)' ;;
  android) CORE_PATH=scripts/termux/bootstrap.sh; CHANNEL='Termux preview (the phone updater track)' ;;
  macos) die "no_published_bundle_for_macos: the release channel publishes Linux (static musl and glibc, x86_64 and aarch64) and Android/Termux bundles; there is no Apple bundle to download and this installer will not build one.
This Mac can still run a node - build it here, which needs Rust and a checkout:
  git clone https://github.com/$REPO_SLUG.git ~/wasm-agent && bash ~/wasm-agent/scripts/deploy.sh
Then this same command installs published bundles from that checkout: bash scripts/install.sh --repo ~/wasm-agent" ;;
  windows) die "no_published_bundle_for_windows: the Windows release is installed by scripts/install.ps1, not by this POSIX script. In PowerShell:
  irm https://raw.githubusercontent.com/$REPO_SLUG/main/scripts/install.ps1 | iex" ;;
  *) die "os_unsupported: $(uname -s 2>/dev/null || echo unknown) (published channels: Linux, Android/Termux, and Windows through install.ps1)" ;;
esac
case "$arch" in
  x86_64|aarch64) ;;
  *) die "arch_unsupported: $arch (published: x86_64, aarch64)" ;;
esac

# ---- 2. the prerequisites the core needs, named before anything is downloaded ---------------------
missing=
if [ -z "$REPO_DIR" ]; then
  for tool in curl tar sha256sum python3; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
fi
if [ -n "$missing" ]; then
  hint=
  if command -v apt-get >/dev/null 2>&1; then hint='sudo apt-get install -y curl ca-certificates tar coreutils python3'
  elif command -v apk >/dev/null 2>&1; then hint='apk add bash curl ca-certificates tar coreutils python3'
  elif command -v dnf >/dev/null 2>&1; then hint='sudo dnf install -y curl ca-certificates tar coreutils python3'
  else hint='install curl, ca-certificates, tar, coreutils and python3'; fi
  die "prerequisites_missing:$missing - $hint"
fi

# One fetcher for every file this script takes from the network, so the scheme rules are in one place.
fetch() { # URL DEST
  case "$1" in
    https://*|http://*) curl -fsSL --retry 2 --connect-timeout 20 -o "$2" "$1" ;;
    file://*)
      [ "${WA_INSTALL_ALLOW_LOCAL:-0}" = 1 ] || die "local_url_refused: $1 (set WA_INSTALL_ALLOW_LOCAL=1 for a fixture)"
      cp -f -- "${1#file://}" "$2" ;;
    *) die "url_scheme_refused: $1" ;;
  esac
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/wa-install.XXXXXX") || die 'scratch_unwritable'
trap 'rm -rf "$tmp"' EXIT

# ---- 3. the core: this checkout, or the commit the published release was built from ----------------
CORE=
CORE_ORIGIN=
if [ -n "$REPO_DIR" ]; then
  [ -f "$REPO_DIR/$CORE_PATH" ] || die "not_a_checkout: $REPO_DIR/$CORE_PATH is missing"
  CORE="$REPO_DIR/$CORE_PATH"
  CORE_ORIGIN="checkout $REPO_DIR"
  CORE_REF=$REF
  say "channel: $CHANNEL"
  say "core: $CORE_PATH from $CORE_ORIGIN"
else
  case "${WA_OFFLINE:-0}" in
    1|true|yes) die "offline: WA_OFFLINE=1 and no --repo; there is no local core to install from and an offline install downloads nothing" ;;
  esac
  say "channel: $CHANNEL"
  if [ "$os" = linux ]; then
    # Ask the index which commit this machine's bundle was built from, and take the core from exactly
    # that commit: one extra request buys an installer that matches its release instead of one from an
    # unrelated day.
    index_url="$BASE/$REF/releases/index-linux.json"
    fetch "$index_url" "$tmp/index.json" || die "index_unreachable: $index_url"
    row=$(python3 - "$tmp/index.json" "$arch" <<'PY'
import json,sys,re
try: doc=json.load(open(sys.argv[1]))
except Exception: print("ERR index_invalid: not JSON"); sys.exit()
if doc.get("schema")!="wasm-agent-linux-release-index" or doc.get("schema_version")!=1:
    print("ERR index_invalid: schema %r v%r is not wasm-agent-linux-release-index v1"%(doc.get("schema"),doc.get("schema_version"))); sys.exit()
arch=sys.argv[2]
wanted=[arch+"-unknown-linux-musl", arch+"-unknown-linux-gnu"]
for want in wanted:
    for r in doc.get("releases") or []:
        if r.get("target")!=want: continue
        commit=r.get("commit") or ""
        if not re.fullmatch(r"[0-9a-f]{40}", commit): continue
        pin=r.get("installer_sha256") or ""
        print("\t".join([want, commit, pin if re.fullmatch(r"[0-9a-f]{64}", pin) else "absent"])); sys.exit()
print("ERR no_release_for_target: the index has no entry for %s" % " or ".join(wanted))
PY
)
    case "$row" in ERR*) die "${row#ERR }" ;; esac
    want_target=$(printf '%s' "$row" | cut -f1)
    CORE_REF=$(printf '%s' "$row" | cut -f2)
    WANT_PIN=$(printf '%s' "$row" | cut -f3)
    say "platform: $os $arch -> bundle $want_target at $CORE_REF (index entry)"
  else
    CORE_REF=$REF
    say "platform: $os $arch"
  fi
  core_url="$BASE/$CORE_REF/$CORE_PATH"
  fetch "$core_url" "$tmp/core" || die "core_unreachable: $core_url"
  got_sha=$(sha256sum "$tmp/core" | cut -d' ' -f1)
  if [ "$WANT_PIN" != absent ]; then
    [ "$got_sha" = "$WANT_PIN" ] || die "installer_hash_mismatch: $CORE_PATH at $CORE_REF is $got_sha, the index entry pins $WANT_PIN; nothing was installed"
    say "core: $CORE_PATH at $CORE_REF (sha256 $got_sha, pinned by the index entry)"
  else
    say "core: $CORE_PATH at $CORE_REF (sha256 $got_sha, installer_pin=absent: the entry predates the pin)"
  fi
  CORE="$tmp/core"
  CORE_ORIGIN="release $CORE_REF"
fi

# ---- 4. what the core is asked to do -------------------------------------------------------------
# The channels take different words for the same intent, so the mapping lives here, once, and a request a
# channel cannot honour is refused by name instead of being dropped silently.
case "$os" in
  linux)
    push "--prefix"; push "$PREFIX_DIR"
    [ "$JOIN_GIVEN" = 1 ] && { push "--rendezvous"; push "$JOIN"; }
    [ "$ROLLBACK" = 1 ] && push "--rollback"
    ;;
  android)
    [ "$JOIN_GIVEN" = 1 ] && die "join_unsupported_on_android: the fleet registry key this writes is Linux-side; on the phone pair with 'wa bind <fabric-url>' after the install"
    [ "$ROLLBACK" = 1 ] && die "rollback_unsupported_on_android: run 'wa update --rollback' after the install (the phone updater owns its own switch)"
    [ "$PREFIX_DIR" != "$HOME/.local/bin" ] && die "prefix_unsupported_on_android: Termux installs under \$PREFIX/opt (WA_TERMUX_INSTALL overrides it)"
    [ -n "$CORE_ARGS" ] && say "android_ignores: the phone channel takes no service/port options"
    CORE_ARGS=
    ;;
esac
[ "$ACTION" = check ] && push "--check"

# POSIX sh has no arrays: the list is newline-separated and split on newline only, so a path with a space
# survives. No value this script accepts contains a newline.
IFS='
'
# shellcheck disable=SC2086
set -- $CORE_ARGS
unset IFS

say "running: $CORE_PATH ($CORE_ORIGIN)$( [ "$#" -gt 0 ] && printf ' %s' "$@" )"
rc=0
bash "$CORE" "$@" || rc=$?
if [ "$rc" != 0 ]; then
  printf 'install: the %s core refused (exit %s); nothing was installed\n' "$CORE_PATH" "$rc" >&2
  exit "$rc"
fi

# ---- 5. the updater, beside the binary -----------------------------------------------------------
# A release bundle carries scripts/install.sh (these bytes, pinned by the bundle's files.sha256) and the core
# installs it into <prefix>/scripts/, so `wa update` runs the neighbour of its own binary: no checkout, no
# clone, no toolchain, install and update one path. A bundle published BEFORE that carries no updater - and
# the rule here is that nothing is invented for it: this script will not fetch a file called install.sh from
# an older ref, because before 11/11 that name held an SSH client wrapper, and "the updater" turning out to
# be something that replaces `wa` with a wrapper is exactly the class of silent replacement this project
# refuses. Such a node keeps the update path it already had (the bootstrap clone), says so, and gets the
# bundled updater with its next release.
if [ "$os" = linux ] && [ "$ACTION" != check ] && [ "${WA_INSTALL_TEST:-0}" != 1 ]; then
  updater="$PREFIX_DIR/scripts/install.sh"
  if [ -f "$updater" ] && grep -q '^WA_INSTALL_FRONT_DOOR=1' "$updater" 2>/dev/null; then
    say "updater: $updater (came with the bundle, verified with it)"
  elif [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/scripts/install.sh" ] \
       && grep -q '^WA_INSTALL_FRONT_DOOR=1' "$REPO_DIR/scripts/install.sh" 2>/dev/null; then
    mkdir -p "$PREFIX_DIR/scripts" 2>/dev/null || true
    cp -f "$REPO_DIR/scripts/install.sh" "$updater" && chmod 755 "$updater" \
      && say "updater: $updater (from the checkout; this bundle predates it)"
  else
    say "updater=absent: this bundle predates the bundled updater, so \`wa update\` uses its existing"
    say "  bootstrap path until the next release installs one beside the binary"
  fi
fi

printf '\n'
say "done. This node updates with the same command that installed it:"
say "  $PREFIX_DIR/scripts/install.sh --update"
case ":$PATH:" in
  *":$PREFIX_DIR:"*) ;;
  *) say "  export PATH=\"$PREFIX_DIR:\$PATH\"   (or open a new shell)" ;;
esac
