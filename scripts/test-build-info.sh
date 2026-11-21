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
for key in version commit tree dirty source source_shared built_epoch ancestors ancestors_complete; do
  [ -n "$(field "$key")" ] && ok "the document names $key ($(field "$key" | cut -c1-24))" || bad "the document has no $key="
done

# 2. The identity is the checkout's, when the build took it from git (a stamper that set
#    WA_BUILD_SOURCE_COMMIT says source=env, and then git is not the witness).
HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
if [ "$(field source)" = git ]; then
  same "commit is this checkout's HEAD" "$(field commit)" "$HEAD"
  same "tree is this commit's tree" "$(field tree)" "$TREE"
  # dirty is a fact about the tree AT BUILD TIME, so it can only be compared with the tree's state now when the
  # tree has not moved since: a binary built from a clean commit reports false, and the edits made after it was
  # built are not its business. What must never happen is a field that says "unknown" for a tree git could read.
  case "$(field dirty)" in
    true|false) ok "dirty is a git answer ($(field dirty))" ;;
    *) bad "dirty is $(field dirty): a build in a checkout git could read must say true or false" ;;
  esac
  if [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    same "a clean tree at build time reports dirty=false" "$(field dirty)" "false"
  else
    ok "the tree has uncommitted changes now (the build recorded $(field dirty) for the moment it read)"
  fi
else
  ok "source=$(field source): this build was stamped, so git is not the witness (skipped the HEAD comparison)"
fi
[ "$(field ancestors)" -ge 1 ] 2>/dev/null && ok "the binary carries $(field ancestors) ancestors" || bad "no ancestors embedded (contains_commits=$(field ancestors))"

# 2b. THE ANCESTRY IS COMPLETE ONLY WHEN THE BUILD CHECKOUT WAS NOT SHALLOW, and an incomplete list must answer
#     "unknown" (2) for a commit it does not carry, never "no" (1): "no" is the verdict a deploy refuses on, and a
#     truncated history cannot honestly produce it. MEASURED: a build from a --depth 1 clone embedded
#     ancestors=137 and claimed ancestors_complete=true, so every commit older than the cut looked like a
#     downgrade and every install of an old release would have been refused.
if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = true ] && [ "$(field source)" = git ]; then
  same "a shallow build reports ancestors_complete=false" "$(field ancestors_complete)" "false"
  "$WABIN" --contains 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1
  same "...and 'not contained' from an incomplete list is 2 (unknown), not 1" "$?" "2"
else
  ok "this build checkout is not shallow (or the build was stamped), so the incomplete-ancestry case is not exercised here"
fi

# 3. --contains answers, and its EXIT CODE is the contract.
"$WABIN" --contains "$(field commit)" >/dev/null 2>&1
same "contains its own commit -> 0" "$?" "0"
"$WABIN" --contains "$(printf '%s' "$(field commit)" | cut -c1-12)" >/dev/null 2>&1
same "contains an abbreviated own commit -> 0" "$?" "0"

# 3b. A COMMIT THE BINARY CARRIES IS CONTAINED, WHATEVER ITS WINDOW'S COMPLETENESS. MEASURED 21/11: a release
#     binary of bfad4f8f was asked about 7ddbfa98 - a commit 42 down, INSIDE its own embedded list - and answered
#     unknown, so every rollout that day needed WA_UPGRADE_FORCE_REASON. The reader had refused to look at the
#     list because ancestors_complete was false. From an incomplete window only a MISS is unknown, so the
#     boundary commit of this checkout (the oldest one its window carries) must answer YES.
if [ "$(field source)" = git ]; then
  window_oldest="$(git -C "$ROOT" rev-list HEAD 2>/dev/null | tail -1)"
  if [ -n "$window_oldest" ]; then
    "$WABIN" --contains "$window_oldest" >/dev/null 2>&1
    # THE STATUS IS READ BEFORE THE LABEL IS BUILT. A $(...) inside the first argument runs a command, which
    # resets $? to ITS status - so the version of this line that expanded `printf` in the label compared 0
    # with 0 and could never fail (measured: it passed against a binary that answers unknown here).
    window_rc=$?
    same "the OLDEST commit this build carries answers yes ($(printf '%s' "$window_oldest" | cut -c1-12))" "$window_rc" "0"
  fi
fi

# a commit that no history can contain: the verdict a deploy refuses on - when the ancestry the binary carries
# is complete. From an incomplete one the honest answer is 2, and this asserts whichever the binary says of itself.
"$WABIN" --contains 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1
absent_rc=$?
if [ "$(field ancestors_complete)" = true ]; then
  same "does not contain an absent commit -> 1" "$absent_rc" "1"
else
  same "does not contain an absent commit, from an incomplete list -> 2 (unknown, never 'no')" "$absent_rc" "2"
fi
"$WABIN" --contains not-a-commit >/dev/null 2>&1
same "a malformed id is unknown -> 2" "$?" "2"
"$WABIN" --contains abc >/dev/null 2>&1
same "a too-short id is unknown -> 2" "$?" "2"

# 4. It works on a node with nothing: no HOME, no state, no Lua tree. A rollback runs there.
BROKEN="$(mktemp -d)"
OUT="$(env -i PATH=/usr/bin:/bin HOME="$BROKEN/none" WASM_AGENT_HOME="$BROKEN/none" "$WABIN" --build-info 2>/dev/null)"
[ -n "$OUT" ] && ok "answers with no HOME and no state directory" || bad "--build-info needs a working node"
OUT2="$(env -i PATH=/usr/bin:/bin HOME="$BROKEN/none" WASM_AGENT_HOME="$BROKEN/none" "$WABIN" --contains 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; echo $?)"
# ...and it answers the same thing it answers with a HOME: 1 from a complete ancestry, 2 from an incomplete one.
if [ "$(field ancestors_complete)" = true ]; then
  same "--contains answers with no HOME either" "$OUT2" "1"
else
  same "--contains answers with no HOME either (2, the same as with one)" "$OUT2" "2"
fi
rm -rf "$BROKEN"

printf 'test-build-info: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
