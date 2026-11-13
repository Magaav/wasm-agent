#!/usr/bin/env bash
# Pack a checkout's Lua UI layer as the payload a deployed node reloads from - and sign it, or refuse to
# install it.
#
#   bash scripts/hotreload-payload.sh <out-dir> [--root <tree>] [--sign] [--install]
#   bash scripts/hotreload-payload.sh --install [--root <tree>] [--sign]
#
# WHY. docs/HOTRELOAD.md: a deployed node reloads the UI and command layer from `<config>/payload` with no
# flag, so a deploy of UI-only changes reaches sessions that are already running. That directory is a
# `SHA256SUMS` + `SHA256SUMS.sig` pair over a committed tree's `lua/`, verified by the node's own binary
# (`wa release verify`, rust/wa-host/src/release.rs) against the keys it already trusts, and then per file
# by `lua/core/payload.lua` before anything is loaded. So this script is the producer of that shape, and the
# two halves it must never separate are "write the tree" and "write the signature".
#
# WHAT IT WRITES
#
#   <out>/SHA256SUMS       `<sha256>  lua/core/cli_view.lua`, one line per file, sorted by path
#   <out>/SHA256SUMS.sig   written by scripts/sign-release.sh on the host that can reach the vault
#   <out>/lua/...          the tree's Lua, byte for byte
#
# SIGNING. `--sign` runs the one signing command this project has (`scripts/sign-release.sh`), which needs
# the vault's admin listener - measured 13/11, loopback only, on the machine that runs the vault. A host
# that cannot sign writes an unsigned payload and says so; `--install` then refuses, because an unsigned
# payload is one the node would refuse to load anyway, and installing it would leave a directory that looks
# like a source and is dead.
#
# `--install` writes `<config>/payload` for this node's home (`WASM_AGENT_HOME`, else `~/.wasm-agent`), by
# building beside it and renaming over it, so a running node never reads a half-copied payload.
set -uo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DEFAULT="$(CDPATH= cd -- "$SELF_DIR/.." && pwd)"

OUT=""
ROOT="$ROOT_DEFAULT"
SIGN=0
INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a tree}"; shift 2 ;;
    --sign) SIGN=1; shift ;;
    --install) INSTALL=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "hotreload-payload: unknown option $1" >&2; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

say() { printf 'hotreload-payload: %s\n' "$*"; }
fail() { printf 'hotreload-payload: %s\n' "$*" >&2; exit 1; }

[ -d "$ROOT/lua/core" ] || fail "no lua/core under $ROOT - --root must name a checkout"

if [ "$INSTALL" = 1 ]; then
  home="${WASM_AGENT_HOME:-${HOME:-}/.wasm-agent}"
  [ -n "${WASM_AGENT_HOME:-}" ] || home="$HOME/.wasm-agent"
  [ -d "$home" ] || fail "this node's home does not exist: $home (WASM_AGENT_HOME names it)"
  [ -n "$OUT" ] || OUT="$home/payload"
fi
[ -n "$OUT" ] || fail "usage: hotreload-payload.sh <out-dir> [--root <tree>] [--sign] [--install]"

sha256_of() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  else return 7
  fi
}
sha256_of "$ROOT/lua/core/cli_view.lua" >/dev/null 2>&1 || fail "release_unverified: no sha256 tool on this machine"

# ---- build beside the target, then move it into place ------------------------------------------------
STAGE="${OUT}.new.$$"
rm -rf "$STAGE" 2>/dev/null
mkdir -p "$STAGE/lua" || fail "cannot create $STAGE"
trap 'rm -rf "$STAGE" 2>/dev/null' EXIT

# The whole `lua/` tree, not only the modules that are reloadable today: `lua/core/reload.lua` decides that
# (its UI list), and a payload that dropped a file would silently change the tree's own answer about what it
# can load. `--exclude` protects nothing here - the gate is the classification, not the file list.
( cd "$ROOT" && find lua -type f -name '*.lua' -print0 | while IFS= read -r -d '' file; do
    mkdir -p "$STAGE/$(dirname -- "$file")" && cp -- "$file" "$STAGE/$file"
  done ) || fail "could not copy lua/ from $ROOT"

# ---- the sums, in the release format (<sha256>  <path>, sorted by path) ------------------------------
( cd "$STAGE" && find lua -type f -name '*.lua' | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s  %s\n' "$(sha256_of "$STAGE/$file")" "$file"
  done > "$STAGE/SHA256SUMS" ) || fail "could not write $STAGE/SHA256SUMS"
files=$(wc -l < "$STAGE/SHA256SUMS" | tr -d '[:space:]')
[ "${files:-0}" -gt 0 ] || fail "wrote no sums - refusing to publish an empty payload"
say "packed $files lua files into $STAGE"

# ---- sign, or say plainly that this payload is unsigned ----------------------------------------------
if [ "$SIGN" = 1 ]; then
  if bash "$ROOT/scripts/sign-release.sh" "$STAGE/SHA256SUMS" "$STAGE/SHA256SUMS.sig" >&2; then
    say "signed with $(sed -n 's/^key //p' "$STAGE/SHA256SUMS.sig")"
  else
    rm -f "$STAGE/SHA256SUMS.sig"
    say "NOT signed: the vault was not reachable from here (scripts/sign-release.sh refused) - this payload will be refused by every node"
  fi
else
  say "unsigned (--sign signs it with the vault's release-signing key on the host that can reach the vault)"
fi

# ---- verify with the node's own binary, exactly as a node will ---------------------------------------
verify() { # <dir>
  local binary="${WA_BIN:-}"
  if [ -z "$binary" ]; then
    for candidate in "$ROOT/rust/target/release/wa" "$(command -v wa 2>/dev/null || true)"; do
      [ -n "$candidate" ] && [ -x "$candidate" ] && { binary="$candidate"; break; }
    done
  fi
  [ -n "$binary" ] || { say "no wa binary found to verify with (WA_BIN names one)"; return 3; }
  "$binary" release verify --sums "$1" --quiet
}
if [ -f "$STAGE/SHA256SUMS.sig" ]; then
  if verify "$STAGE"; then say "verified by $(command -v wa 2>/dev/null || echo 'the node binary')"
  else fail "the signature does not verify against the keys this machine trusts - nothing installed"; fi
fi

# ---- install (or move into the named place) ----------------------------------------------------------
if [ "$INSTALL" = 1 ]; then
  [ -f "$STAGE/SHA256SUMS.sig" ] || fail "payload_unsigned: refusing to install $OUT without a verified signature (a node would refuse to load it, and a dead source is worse than none)"
  target="$OUT"
  mkdir -p "$(dirname -- "$target")" || fail "cannot create $(dirname -- "$target")"
  previous="${target}.previous.$$"
  if [ -d "$target" ]; then mv "$target" "$previous" || fail "cannot move the old payload aside"; fi
  if ! mv "$STAGE" "$target"; then
    [ -d "$previous" ] && mv "$previous" "$target"
    fail "cannot install into $target (the previous payload is back)"
  fi
  trap - EXIT
  rm -rf "$previous" 2>/dev/null
  say "installed $target - a running chat picks it up at its next frame"
else
  rm -rf "$OUT" 2>/dev/null
  mv "$STAGE" "$OUT" || fail "cannot move the payload into $OUT"
  trap - EXIT
  say "wrote $OUT"
fi
