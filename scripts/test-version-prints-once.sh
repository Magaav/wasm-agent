#!/usr/bin/env bash
# ONE `v` IN THE VERSION LINE (Fable, 24/11): `wa --version` must not print a label that already names a
# release.
#
# WHY THIS ROW EXISTS. Measured on this node, 24/11: a machine installed from the PUBLIC channel
# (`scripts/install.sh` -> `scripts/linux/bootstrap.sh`) has `release=v0.1.1` in its `installed.txt`, and
# `wa --version` printed `wasm-agent v0.1.1 . vv0.1.1` - the printer added a `v` to a label that was
# already the published release tag. Every fleet node is a channel install, so every one of them would have
# printed `vv0.1.2` after the next update, and nothing failed: a version line is read by people, not by a check.
#
# WHAT IT HOLDS: the four shapes a label has (`install_label` makes them) through the REAL binary, each in its
# own scratch install directory - a published channel release, an install record's `binary_release`, a
# `node-<sha12>` release tag, and the bytes' own commit label when there is no record at all. The whole line is
# checked too, against the product version the same binary reports, so a change to either half is noticed.
#
#   WA_BIN=/path/to/wa bash scripts/test-version-prints-once.sh
set -o pipefail
tmpdir="$TMPDIR"; [ -n "$tmpdir" ] || tmpdir=/tmp
T=$(mktemp -d "$tmpdir/wa-version-once-test.XXXXXX") || { printf 'FAIL tmpdir_unavailable: cannot create a temp dir under %s\n' "$tmpdir" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
BIN="$WA_BIN"
[ -n "$BIN" ] || BIN="$(command -v wa 2>/dev/null)"
[ -n "$BIN" ] && [ -x "$BIN" ] || { printf 'FAIL wa_binary_missing: set WA_BIN to a wa binary (fast.sh exports it)\n' >&2; exit 1; }
pass=0; failed=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf 'FAIL %s\n' "$1"; if [ -n "$2" ]; then printf '%s\n' "$2" | tail -4 | sed 's/^/     /'; fi; }

mkdir -p "$T/home"
PRODUCT="$("$BIN" --build-info 2>/dev/null | sed -n 's/^version=//p' | head -1)"
[ -n "$PRODUCT" ] || { printf 'FAIL wa_binary_no_product_version: %s --build-info answered no version=\n' "$BIN" >&2; exit 1; }
MIDDLE=$'\u00b7'

line_of() { # PREFIX HOME -> the whole first line of wa --version
  WA_INSTALL_DIR="$1" HOME="$2" "$BIN" --version 2>/dev/null | head -1
}
identity_of() { # PREFIX HOME -> the half after the middle dot (or the whole line when there is none)
  local line
  line="$(line_of "$1" "$2")"
  printf '%s' "$line" | python3 -c 'import sys
line = sys.stdin.read().strip()
marker = " " + "\u00b7" + " "
print(line.split(marker)[-1] if marker in line else line)'
}

# check <name> <record lines or -> <expected identity>
check() {
  local name="$1" record="$2" expected="$3" prefix="$T/prefix-$1" home="$T/home-$1"
  mkdir -p "$prefix" "$home"
  if [ "$record" != - ]; then printf '%s\n' "$record" > "$prefix/installed.txt"; fi
  local line identity
  line="$(line_of "$prefix" "$home")"
  identity="$(identity_of "$prefix" "$home")"
  [ -n "$line" ] || { bad "$name: wa --version printed nothing" "$line"; return; }
  if [ "$identity" = "$expected" ]; then
    ok "$name: the identity half is '$expected'"
  else
    bad "$name: the identity half is '$identity', wanted '$expected'" "$line"
  fi
  case "$identity" in
    vv*) bad "$name: the label carries a doubled v ('$identity')" "$line" ;;
    *) ok "$name: and no label carries two v's" ;;
  esac
  if [ "$line" = "wasm-agent v$PRODUCT $MIDDLE $expected" ]; then
    ok "$name: the whole line is 'wasm-agent v<product> . <label>'"
  else
    bad "$name: the whole line is '$line', wanted 'wasm-agent v$PRODUCT $MIDDLE $expected'" "$line"
  fi
}

# THE CASE THAT WAS BROKEN: a node installed from the public channel (bootstrap writes release=<tag>).
check channel-release 'commit=2104a4d88a37bb05627f166eaf47b5f32e8eacf4
release=v0.1.1
via=linux-bootstrap' 'v0.1.1'
# The record's binary_release wins when a deploy wrote one (scripts/lib/install-record.sh).
check binary-release 'commit=2104a4d88a37bb05627f166eaf47b5f32e8eacf4
binary_release=v0.2.3' 'v0.2.3'
# A node release tag is printed as it is - no v in front of a word that is not a commit.
check node-release 'commit=7fa1b2c3d4e5a6b7c8d9e0f1a2b3c4d5e6f7a8b9
release=node-7fa1b2c3d4e5' 'node-7fa1b2c3d4e5'
# With no record at all the bytes name themselves, and that half IS a commit label: one v.
mkdir -p "$T/prefix-bare" "$T/home-bare"
identity="$(identity_of "$T/prefix-bare" "$T/home-bare")"
if printf '%s' "$identity" | grep -qx 'v[0-9a-f]\{8\}\(+dirty\)\?'; then
  ok "no record: the bytes' own commit label, prefixed once ('$identity')"
else
  bad "no record: the identity half is '$identity', wanted 'v<8 hex>' or 'v<8 hex>+dirty'" "$(line_of "$T/prefix-bare" "$T/home-bare")"
fi

if [ "$failed" = 0 ]; then printf '\nversion-once ok (%d checks)\n' "$pass"; else printf '\nversion-once FAILED (%d passed, %d failed)\n' "$pass" "$failed"; fi
[ "$failed" = 0 ]
