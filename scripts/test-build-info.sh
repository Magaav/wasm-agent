#!/usr/bin/env bash
# Does the binary answer for itself? (`wa --build-info`, `wa --contains`; rust/wa-host/build.rs)
#
# WHAT THIS EXISTS FOR. On 18/11 a node ran a binary built from 8 commits that were on no landed branch while
# its installed.txt said commit=14963b6f - the install record was a belief, and it was wrong. The answer to
# "which commit is this?" has to come from the bytes, and this test is what says the bytes can answer.
#
# It checks the identity against the checkout the binary was built in, every verdict of --contains with its
# exit code (0 yes, 1 no, 2 unknown - a caller that confused "no" with "unknown" would either accept a silent
# downgrade or block every install of an old release), and that both commands work with no usable HOME, since
# a rollback runs exactly there.
#
# Usage:  bash scripts/test-build-info.sh            (against a binary built from THIS checkout: the test
#         asserts the commit it reports is this checkout's HEAD, which is the property a deploy relies on)
#         WA_BIN=/path/to/wa bash scripts/test-build-info.sh     (a release binary, for instance)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
WABIN="${WA_BIN:-$TARGET_DIR/debug/wa}"
[ -x "$WABIN" ] || WABIN="$TARGET_DIR/release/wa"

checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }

if [ ! -x "$WABIN" ]; then
  echo "SKIP test-build-info: no binary at $WABIN (build it: cd rust && cargo build -p wa-host)"
  exit 0
fi
echo "test-build-info: $WABIN"

INFO="$("$WABIN" --build-info 2>&1)"
[ -n "$INFO" ] && ok "the binary answers --build-info" || bad "the binary answered nothing"

field() { printf '%s\n' "$INFO" | sed -n "s/^$1=//p" | head -1; }

# 1. Every field the records are written from is present.
for key in version commit tree dirty source built_epoch ancestors ancestors_complete; do
  [ -n "$(field "$key")" ] && ok "the document names $key ($(field "$key" | cut -c1-24))" || bad "the document has no $key="
done

# 2. The identity is the checkout's, when the build took it from git (a stamper that set
#    WA_BUILD_SOURCE_COMMIT says source=env, and then git is not the witness).
HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
if [ "$(field source)" = git ]; then
  same "commit is this checkout's HEAD" "$(field commit)" "$HEAD"
  same "tree is this commit's tree" "$(field tree)" "$TREE"
  if [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    same "dirty is false on a clean tree" "$(field dirty)" "false"
  else
    same "dirty is true on a tree with uncommitted changes" "$(field dirty)" "true"
  fi
else
  ok "source=$(field source): this build was stamped, so git is not the witness (skipped the HEAD comparison)"
fi
[ "$(field ancestors)" -ge 1 ] 2>/dev/null && ok "the binary carries $(field ancestors) ancestors" || bad "no ancestors embedded (contains_commits=$(field ancestors))"

# 3. --contains answers, and its EXIT CODE is the contract.
"$WABIN" --contains "$(field commit)" >/dev/null 2>&1
same "contains its own commit -> 0" "$?" "0"
"$WABIN" --contains "$(printf '%s' "$(field commit)" | cut -c1-12)" >/dev/null 2>&1
same "contains an abbreviated own commit -> 0" "$?" "0"
# a commit that no history can contain: the verdict a deploy refuses on
"$WABIN" --contains 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1
same "does not contain an absent commit -> 1" "$?" "1"
"$WABIN" --contains not-a-commit >/dev/null 2>&1
same "a malformed id is unknown -> 2" "$?" "2"
"$WABIN" --contains abc >/dev/null 2>&1
same "a too-short id is unknown -> 2" "$?" "2"

# 4. It works on a node with nothing: no HOME, no state, no Lua tree. A rollback runs there.
BROKEN="$(mktemp -d)"
OUT="$(env -i PATH=/usr/bin:/bin HOME="$BROKEN/none" WASM_AGENT_HOME="$BROKEN/none" "$WABIN" --build-info 2>/dev/null)"
[ -n "$OUT" ] && ok "answers with no HOME and no state directory" || bad "--build-info needs a working node"
OUT2="$(env -i PATH=/usr/bin:/bin HOME="$BROKEN/none" WASM_AGENT_HOME="$BROKEN/none" "$WABIN" --contains 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; echo $?)"
same "--contains answers with no HOME either" "$OUT2" "1"
rm -rf "$BROKEN"

printf 'test-build-info: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
