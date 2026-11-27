#!/usr/bin/env bash
# THE PUBLISHER BUILDS AND SHIPS THE PROGRAM FOR EVERY TARGET IT PUBLISHES (wa-term-own-program, re-land).
#
# WHAT WENT WRONG, MEASURED: the first landing added wa-term to the payload and to the manifest, but the
# cross build still ran `cargo zigbuild -p wa-host` alone - so a real publish died on
#   binary_missing: no built wa-term for aarch64-unknown-linux-gnu.2.31   (rc=8, on 97c7a9f6 and 334aeae7)
# and the whole landing was reverted. The payload was right; the BUILD was not.
#
# This row drives the REAL script with STUB tools on PATH (cargo, cargo-zigbuild, zig), so no cross
# toolchain is needed and nothing is published: the stub cargo records its arguments and drops the
# binaries a real build would produce into a scratch target dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/scripts/publish-node-binaries.sh"
[ -f "$PUBLISH" ] || { echo "FAIL: no scripts/publish-node-binaries.sh"; exit 1; }
WORK="${WA_TEST_DIR:-$HOME/wa-test-scratch/publish-program}"
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/target" "$WORK/out" || exit 1
fails=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

# ---- the stub tools -------------------------------------------------------------------------------
{ echo '#!/usr/bin/env bash'; cat <<'STUB'
printf '%s\n' "$*" >> "$CARGO_LOG"
target=""; prev=""
for arg in "$@"; do
  [ "$prev" = "--target" ] && target="$arg"
  prev="$arg"
done
[ -n "$target" ] || exit 0
triple="${target%%.2.*}"
dir="$STUB_TARGET_DIR/$target/release"
mkdir -p "$dir" || exit 1
machine=3e; case "$triple" in aarch64-*) machine=b7 ;; esac
mk() { { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$machine"; head -c 4096 /dev/zero | tr '\0' ' '; } > "$1"; chmod 0755 "$1"; }
mk "$dir/wa"; mk "$dir/wa-sentinel"
case "$*" in *"-p wa-term"*) mk "$dir/wa-term" ;; esac
exit 0
STUB
} > "$WORK/bin/cargo"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/cargo-zigbuild"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/zig"
chmod 0755 "$WORK/bin/cargo" "$WORK/bin/cargo-zigbuild" "$WORK/bin/zig"

run_build() { # <script> <out dir> <target dir> <log> [extra args...]
  local script="$1" outdir="$2" targetdir="$3" log="$4"; shift 4
  CARGO_LOG="$log" STUB_TARGET_DIR="$targetdir" PATH="$WORK/bin:$PATH" \
    ALLOW_UNPUSHED_COMMIT=1 \
    ALLOW_UNPUSHED_REASON="test-publish-builds-the-program: stub tools and fixture bytes, installed nowhere" \
    WA_CODEMODE_ALLOW_EMPTY=1 \
    bash "$script" --repo "$ROOT" --local --target aarch64-unknown-linux-gnu \
      --out "$outdir" --target-dir "$targetdir" "$@" 2>&1
}

# 1. THE PLAN FOR BOTH TRIPLES NAMES THE PROGRAM PER TARGET (a dry run: no build, no publish).
out="$(ALLOW_UNPUSHED_COMMIT=1 ALLOW_UNPUSHED_REASON="test-publish-builds-the-program: dry run" \
        WA_CODEMODE_ALLOW_EMPTY=1 bash "$PUBLISH" --local --check \
        --target aarch64-unknown-linux-gnu --target x86_64-unknown-linux-gnu 2>&1)"
for triple in aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu; do
  case "$out" in
    *"wa-term-$triple-"*) pass "the plan names wa-term for $triple" ;;
    *) bad "the plan does not name wa-term for $triple" ;;
  esac
done

# 2. THE ONE LINE THE FIRST LANDING MISSED.
grep -q 'cargo zigbuild --release --offline --locked -p wa-host -p wa-term --target' "$PUBLISH" \
  && pass "the cross build command carries -p wa-term" \
  || bad "the cross build command does NOT carry -p wa-term: a real publish cannot ship the program"

# 3. A BUILD WITHOUT THE FLAG IS REFUSED BY NAME - the regression, reproduced on a copy of the script.
NOFLAG="$WORK/publish-noflag.sh"
sed 's/-p wa-host -p wa-term/-p wa-host/' "$PUBLISH" > "$NOFLAG"
out="$(run_build "$NOFLAG" "$WORK/out-none" "$WORK/target-none" "$WORK/noflag.log")"
case "$out" in
  *"binary_missing: no built wa-term"*) pass "a build without the flag is refused by name, as the real publish was" ;;
  *) bad "a build without -p wa-term did not refuse by name: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')" ;;
esac

# 4. AND WITH THE FLAG THE PROGRAM IS BUILT AND REACHES THE PAYLOAD.
out="$(run_build "$PUBLISH" "$WORK/out" "$WORK/target" "$WORK/ok.log")"
case "$out" in
  *"binary_missing: no built wa-term"*) bad "the program was built but the script could not find it" ;;
  *) pass "with -p wa-term the build passes its own program check" ;;
esac
case "$out" in
  *"wa-term-aarch64-unknown-linux-gnu-"*) pass "the payload names the program for the cross target" ;;
  *) bad "the payload was written without wa-term: $(ls "$WORK/out" 2>/dev/null | tr '\n' ' ')" ;;
esac

rm -rf "$WORK"
if [ "$fails" -eq 0 ]; then echo "PASS test-publish-builds-the-program (6 checks)"; exit 0; fi
echo "FAIL test-publish-builds-the-program ($fails check(s) failed)"; exit 1
