#!/bin/sh
# Served at https://wa.colmeio.com/install.sh (openclaw /srv/wasm-agent-releases). This file is its source.
# wasm-agent: install a node from the signed node-binary channel.
#   curl -fsSL <url> | sh              install/update into ~/.local/bin
#   ... | sh -s -- --check            resolve + verify, change nothing
set -eu
REPO=Magaav/wasm-agent
SIGNER=release-signing-312805587de9606c
PREFIX=${WA_PREFIX:-$HOME/.local/bin}
UI=${WA_UI:-$HOME/.local/share/wasm-agent/ui}
check=0; [ "${1:-}" = --check ] && check=1

say() { printf 'install: %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "unsupported_os: $(uname -s) (this channel is Linux only)"
case $(uname -m) in
  x86_64|amd64) T=x86_64-unknown-linux-gnu ;;
  aarch64|arm64) T=aarch64-unknown-linux-gnu ;;
  *) die "unsupported_arch: $(uname -m)" ;;
esac
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
[ -n "$glibc" ] || die "unsupported_libc: $T needs glibc >= 2.31 (musl/Alpine gets a static bundle that is not published yet)"
say "platform: $T ($glibc)"
for t in curl tar sha256sum; do command -v "$t" >/dev/null 2>&1 || die "missing_tool: $t"; done

say "channel: signed node binaries (releases tagged node-<commit>)"
# Which release: the one the publisher names in latest-node.txt beside this script (written by the publish
# step, one line `node-<sha12>`). GitHub's release listing is NOT ordered by date - measured 17/11: a release
# edited after a newer one was published came first, and this installer picked the broken one. The listing
# scan stays as the fallback for a host that serves no pointer.
tag=$(curl -fsSL "${WA_RELEASE_POINTER:-https://wa.colmeio.com/latest-node.txt}" 2>/dev/null | tr -d '[:space:]') || true
case $tag in node-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;; *) tag= ;; esac
[ -n "$tag" ] || tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=60" \
      | sed -n 's/^ *"tag_name": "\(node-[0-9a-f]\{12\}\)".*/\1/p' | head -1) || true
[ -n "$tag" ] || die "no_release: no node-<commit> release found"
sha=${tag#node-}
say "release: $tag"

d=${TMPDIR:-/tmp}/wa-install-$$; mkdir -p "$d"; trap 'rm -rf "$d"' EXIT INT TERM
base="https://github.com/$REPO/releases/download/$tag"
for f in "wa-$T-$sha" "wa-sentinel-$T-$sha" node-$sha.manifest SHA256SUMS SHA256SUMS.sig; do
  curl -fsSL -o "$d/$f" "$base/$f" || die "download_failed: $f"
done
chmod +x "$d/wa-$T-$sha"

if ! grep -E " (wa-$T-$sha|wa-sentinel-$T-$sha)$" "$d/SHA256SUMS" | (cd "$d" && sha256sum -c -) >/dev/null 2>&1; then
  die "checksum_mismatch: the assets do not match SHA256SUMS"
fi
say "checksums: ok"
out=$("$d/wa-$T-$sha" release verify "$d" 2>&1) || die "release_signature_invalid: $out"
case $out in *"$SIGNER"*) say "signature: ok ($SIGNER)" ;;
  *) die "release_signed_by_unexpected_key: $out" ;; esac

if [ "$check" = 1 ]; then say "check: verified $tag; nothing installed"; exit 0; fi

install -d "$PREFIX" "$UI"
install -m755 "$d/wa-$T-$sha" "$PREFIX/wa"
install -m755 "$d/wa-sentinel-$T-$sha" "$PREFIX/wa-sentinel"
# the web UI ships in the repo tree, not in the binary
commit=$(sed -n 's/^source_commit=//p' "$d/node-$sha.manifest")
if [ -n "$commit" ]; then
  mkdir -p "$d/tree"
  if curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$commit" | tar -xz -C "$d/tree" --strip-components=1 "wasm-agent-$commit/ui"; then
    rm -rf "$UI"; cp -R "$d/tree/ui" "$UI"; say "ui: $UI"
  else
    say "ui: not installed (serve one with wa serve --ui <checkout>/ui)"
  fi
fi
printf 'release=%s\nvia=node-binaries\ntarget=%s\n' "$tag" "$T" > "$PREFIX/installed.txt"
say "installed: $PREFIX/wa $($PREFIX/wa --version) and $PREFIX/wa-sentinel"
case ":$PATH:" in *":$PREFIX:"*) : ;; *) say "add to PATH: export PATH=\"$PREFIX:\$PATH\"" ;; esac
say "next: wa serve --ui $UI   (or wa chat)"
