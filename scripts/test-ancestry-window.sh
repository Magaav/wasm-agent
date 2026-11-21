#!/usr/bin/env bash
# The ancestry window a release binary carries, and the floor it stops at.
# (rust/wa-host/build.rs ANCESTORS_FLOOR; scripts/lib/node-binaries.sh wa_ancestry_window_floor)
#
# WHAT THIS EXISTS FOR. A node's install guard asks the CANDIDATE binary "do you contain what is
# running?" (wa --contains). The answer comes from the ancestor list build.rs embedded at build time, so
# a build from a shallow clone carries only what is above the cut - and a node updating from the previous
# release asks about a commit below it. MEASURED 21/11: the release of bfad4f8f was asked about
# 7ddbfa98, a commit 42 back and INSIDE its own embedded list, and refused the install.
#
# It never touches a live node or this repository: every git object is made under a scratch HOME, and it
# refuses to run against a real node home.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }

# A TEST THAT WRITES PROBES ITS OWN HOME: on the real HOME this would make repositories beside a node's
# state, so it refuses by name. scripts/test.sh and scripts/fast.sh pass WA_TEST_SCRATCH_HOME=1 on this
# case's own line - the marker is set by the caller that has made the home a scratch one, never inferred
# from the path, because "looks like a temp dir" is not the same fact as "this run isolated it".
if [ -d "${HOME:-}/.wasm-agent" ] && [ "${WA_TEST_SCRATCH_HOME:-}" != 1 ]; then
  echo "SKIP test-ancestry-window: HOME (${HOME}) is a real node home; run it through scripts/test.sh" >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-ancestry-window.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email test@example.invalid >/dev/null 2>&1
git config --global user.name "ancestry window test" >/dev/null 2>&1
git config --global init.defaultBranch main >/dev/null 2>&1
git config --global protocol.file.allow always >/dev/null 2>&1

. "$ROOT/scripts/lib/node-binaries.sh"

# ---- a history with a release in it, and a shallow clone of that history -------------------------
ORIGIN="$WORK/origin.git"
SRC="$WORK/src"
git init -q --bare "$ORIGIN" || exit 2
git init -q "$SRC" || exit 2
( cd "$SRC" \
  && for n in 1 2 3 4 5; do echo "$n" > "f$n.txt"; git add -A; git commit -qm "commit $n"; done \
  && git tag "node-$(git rev-parse --short=12 HEAD)" \
  && for n in 6 7 8; do echo "$n" > "f$n.txt"; git add -A; git commit -qm "commit $n"; done ) >/dev/null 2>&1 \
  || { echo "test-ancestry-window: could not build the scratch history" >&2; exit 2; }
git -C "$SRC" remote add origin "$ORIGIN" >/dev/null 2>&1
git -C "$SRC" push -q origin main --tags >/dev/null 2>&1 || { echo "test-ancestry-window: could not push" >&2; exit 2; }
RELEASE_TAG="$(git -C "$SRC" tag --list 'node-*' | head -1)"
RELEASE_COMMIT="$(git -C "$SRC" rev-parse --verify -q "${RELEASE_TAG}^{commit}" 2>/dev/null)"
HEAD_SRC="$(git -C "$SRC" rev-parse HEAD)"
[ -n "$RELEASE_COMMIT" ] && ok "the scratch history has a release tag ($RELEASE_TAG)" || bad "no release tag"

SHALLOW="$WORK/shallow"
git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW" >/dev/null 2>&1 || { echo "clone failed" >&2; exit 2; }
same "the clone is shallow" "$(git -C "$SHALLOW" rev-parse --is-shallow-repository 2>/dev/null)" "true"

# ---- 1. A SHALLOW CLONE SAYS IT CANNOT NAME THE FLOOR, never "the root commit" --------------------
# rev-list --max-parents=0 on a shallow clone returns the CUT and would call it the root: the same lie
# as a truncated list claiming to be complete.
floor_value="$(wa_ancestry_window_floor "$SHALLOW" HEAD 2>/dev/null)"
floor_reason="$(wa_ancestry_window_floor "$SHALLOW" HEAD 2>&1 >/dev/null | head -1)"
same "a shallow clone answers nothing for the floor" "$floor_value" ""
same "...and names why, instead of guessing at a root commit" "$floor_reason" "shallow_window_unknown"

# ---- 2. ONE BOUNDED DEEPEN MAKES THE QUESTION ANSWERABLE, and the answer is the RELEASE ----------
wa_ancestry_deepen "$SHALLOW" 2>/dev/null
same "after a deepen the clone is not shallow" "$(git -C "$SHALLOW" rev-parse --is-shallow-repository 2>/dev/null)" "false"
same "the floor is the previous release commit, not the bottom of a cut window" \
  "$(wa_ancestry_window_floor "$SHALLOW" HEAD 2>/dev/null)" "$RELEASE_COMMIT"
same "and the deepen left the clone on the same commit" "$(git -C "$SHALLOW" rev-parse HEAD)" "$HEAD_SRC"

# ---- 3. A FULL HISTORY WITH NO RELEASE says the whole history is the window -----------------------
FULL="$WORK/full"
git init -q "$FULL" || exit 2
( cd "$FULL" && for n in 1 2 3; do echo "$n" > "g$n.txt"; git add -A; git commit -qm "plain $n"; done ) >/dev/null 2>&1
ROOT_COMMIT="$(git -C "$FULL" rev-list --max-parents=0 HEAD | head -1)"
same "a full history with no release tag floors at its root commit" \
  "$(wa_ancestry_window_floor "$FULL" HEAD 2>/dev/null)" "$ROOT_COMMIT"


# ---- 4. THE BINARY NAMES ITS OWN FLOOR, and the floor it names is a commit it CARRIES -------------
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
WABIN="${WA_BIN:-$TARGET_DIR/debug/wa}"
[ -x "$WABIN" ] || WABIN="$TARGET_DIR/release/wa"
if [ -x "$WABIN" ]; then
  INFO="$("$WABIN" --build-info 2>/dev/null)"
  bin_floor="$(printf '%s\n' "$INFO" | sed -n 's/^ancestors_floor=//p' | head -1)"
  bin_complete="$(printf '%s\n' "$INFO" | sed -n 's/^ancestors_complete=//p' | head -1)"
  [ -n "$bin_floor" ] && ok "the document names ancestors_floor (${bin_floor:0:12})" || bad "no ancestors_floor="
  if [ -n "$bin_floor" ] && [ "$bin_floor" != unknown ]; then
    if "$WABIN" --contains "$bin_floor" >/dev/null 2>&1; then
      ok "and the binary CONTAINS the floor it names, so the floor is a usable boundary"
    else
      bad "the binary names floor ${bin_floor:0:12} but --contains does not answer yes for it"
    fi
  else
    ok "this binary carries no window, so there is no floor to check"
  fi
  # 5. A MISS BELOW A PARTIAL WINDOW IS UNKNOWN AND SAYS WHERE: 2 with ancestors_floor named, never 1,
  # which is the verdict a deploy refuses on.
  if [ "$bin_complete" = false ]; then
    out="$("$WABIN" --contains 0123456789abcdef0123456789abcdef01234567 2>/dev/null)"; rc=$?
    same "a miss below a partial window is unknown (2), never a refusal-grade no" "$rc" "2"
    case "$out" in
      *below_ancestry_window*) ok "and it says the commit is below the window" ;;
      *) bad "the unknown does not name below_ancestry_window: $out" ;;
    esac
    case "$out" in
      *ancestors_floor=*) ok "and prints the floor, so a reader can act on it" ;;
      *) bad "the unknown does not print ancestors_floor: $out" ;;
    esac
  else
    ok "this binary window is complete, so the below-window case is not exercised here"
  fi
else
  echo "test-ancestry-window: no binary at $WABIN, so the binary half is skipped"
fi

printf 'test-ancestry-window: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
