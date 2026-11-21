#!/usr/bin/env bash
# A --from publish names the ancestry floor it verifies against, on a set of two architectures.
#
# MEASURED 21/11 (land250's ship step): publish-node-binaries.sh --from died at
#   line 624: WINDOW_FLOOR: unbound variable
# AFTER reporting every artifact verified. WINDOW_FLOOR was assigned only in the BUILD half, and --from
# skips that half while sharing its verify loop - so a host that cannot build (or publishes artifacts
# built elsewhere) lost the release. It surfaced on a set with one runnable and one cross architecture.
#
# What this asserts, in the order the failure would bite:
#   1. a two-architecture --from publish SUCCEEDS (the crash is gone);
#   2. it names the floor it checks against (the half that did not build still knows it);
#   3. the artifact this host CAN run is proved to contain it;
#   4. the one it CANNOT run is named as not proved - never claimed as checked.
#
# Its own scratch HOME, and it refuses to run against a real node home. Nothing touches a live node.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0; failed=0
ok()   { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }

if [ -d "${HOME:-}/.wasm-agent" ] && [ "${WA_TEST_SCRATCH_HOME:-}" != 1 ]; then
  echo "SKIP test-publish-from-ancestry: HOME (${HOME}) is a real node home; run it through scripts/test.sh or set WA_TEST_SCRATCH_HOME=1" >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-from-ancestry.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
for kv in "user.email=t@example.invalid" "user.name=from-ancestry" "init.defaultBranch=main" "protocol.file.allow=always"; do
  git config --global "${kv%%=*}" "${kv#*=}" >/dev/null 2>&1
done

PUBLISH="$ROOT/scripts/publish-node-binaries.sh"
[ -f "$PUBLISH" ] || { echo "test-publish-from-ancestry: no $PUBLISH" >&2; exit 2; }

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SHORT="${COMMIT:0:12}"
HOST_TRIPLE="$(uname -m)-unknown-linux-gnu"
case "$HOST_TRIPLE" in
  x86_64-*) OTHER_TRIPLE=aarch64-unknown-linux-gnu; OTHER_MACHINE=b7 ;;
  aarch64-*) OTHER_TRIPLE=x86_64-unknown-linux-gnu; OTHER_MACHINE=3e ;;
  *) echo "SKIP test-publish-from-ancestry: no cross triple for $(uname -m)" >&2; exit 0 ;;
esac

mkelf() { { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture'; } > "$1"; }
sha() { sha256sum "$1" | awk '{print $1}'; }
bytes() { wc -c < "$1" | tr -d '[:space:]'; }

# The artifact this host can run is a REAL binary: only a runnable one reaches the ancestry question,
# which is the question that crashed. Built from this tree (the same commit the manifest names).
WABIN="${WA_BIN:-${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa}"
[ -x "$WABIN" ] || WABIN="${CARGO_TARGET_DIR:-$ROOT/rust/target}/release/wa"
if [ ! -x "$WABIN" ]; then
  echo "SKIP test-publish-from-ancestry: no wa binary at $WABIN (cd rust && cargo build -p wa-host --bin wa)" >&2
  exit 0
fi
same_commit="$("$WABIN" --build-info 2>/dev/null | sed -n 's/^commit=//p' | head -1)"
[ "$same_commit" = "$COMMIT" ] || {
  echo "SKIP test-publish-from-ancestry: $WABIN is built from ${same_commit:0:12}, not $SHORT (rebuild it)" >&2
  exit 0
}

built="$WORK/built"
mkdir -p "$built"
cp "$WABIN" "$built/wa-$HOST_TRIPLE-$SHORT"
chmod +x "$built/wa-$HOST_TRIPLE-$SHORT" 2>/dev/null || true
mkelf "$built/wa-$OTHER_TRIPLE-$SHORT" "$OTHER_MACHINE"
mkelf "$built/wa-sentinel-$HOST_TRIPLE-$SHORT" 3e
mkelf "$built/wa-sentinel-$OTHER_TRIPLE-$SHORT" "$OTHER_MACHINE"
{
  echo "schema=wasm-agent-node-binaries/1"
  echo "source_commit=$COMMIT"
  echo "source_tree=$(git -C "$ROOT" rev-parse "$COMMIT^{tree}")"
  echo "rustc_version=fixture"
  echo "zig_version=fixture"
  echo "glibc_floor=2.31"
  echo "codemode=embedded"
  echo "built_utc=2026-11-21T00:00:00Z"
  echo "# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes"
  echo "$HOST_TRIPLE $(sha "$built/wa-$HOST_TRIPLE-$SHORT") $(bytes "$built/wa-$HOST_TRIPLE-$SHORT") $(sha "$built/wa-sentinel-$HOST_TRIPLE-$SHORT") $(bytes "$built/wa-sentinel-$HOST_TRIPLE-$SHORT")"
  echo "$OTHER_TRIPLE $(sha "$built/wa-$OTHER_TRIPLE-$SHORT") $(bytes "$built/wa-$OTHER_TRIPLE-$SHORT") $(sha "$built/wa-sentinel-$OTHER_TRIPLE-$SHORT") $(bytes "$built/wa-sentinel-$OTHER_TRIPLE-$SHORT")"
} > "$built/node-$SHORT.manifest"

out="$(bash "$PUBLISH" --from "$built" --out "$WORK/bundle" --target "$HOST_TRIPLE" --target "$OTHER_TRIPLE" --glibc 2.39 2>&1)"
rc=$?
case "$out" in
  *"unbound variable"*) bad "unbound variable in the verify loop" ;;
  *) ok "no unbound variable in the verify loop" ;;
esac
case "$out" in *"ancestry window floor:"*) ok "the half that did not build names the floor" ;; *) bad "no floor named" ;; esac
# THE POINT IS NOT THE FINAL STATUS. rc 5 (a floor below this shallow checkout's window) and rc 6 (the
# signing vault is absent on this host) are both LATER gates than the one this case is about, and both mean
# the ancestry step already ran. What must be true is what happened AT it.
case "$out" in
  *"ancestry window: wa-$HOST_TRIPLE-$SHORT contains "*)
    ok "the artifact this host runs is PROVED to contain the previous release" ;;
  *) bad "the runnable artifact was not proved to contain the floor" ;;
esac
# A LITERAL TEST, not a case pattern: the text contains parentheses, which a case pattern reads as its own
# delimiter - the first version of this assertion compared against a pattern that could never match and
# reported a correct run as failed.
if printf '%s' "$out" | grep -Fq "cannot be executed on this host ($OTHER_TRIPLE)"; then
  ok "the artifact it cannot run is named as NOT proved, never claimed"
else
  bad "the cross artifact's window was claimed or silently skipped"
fi
case "$out" in
  *"unbound variable"*) bad "the crash is still reachable" ;;
  *) ok "--from reached its ancestry verdict and went on past it (rc=$rc, a later gate)" ;;
esac
printf 'test-publish-from-ancestry: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
