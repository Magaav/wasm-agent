#!/usr/bin/env bash
# Does `wa --version` mark THIS node "(pinned)" only when a pin names it?
#
# WHAT THIS EXISTS FOR. The pin ledger (pins.txt) is fleet-wide: one file holds a record per node. The
# label's old reader walked it line by line keeping the last commit= it saw, so a pin written for
# ANOTHER node marked these bytes "(pinned)" - and a commit= written above a state=cleared was still
# taken as active. Round 3 moved the whole decision into rust/wa-host/src/build_info.rs:
# `install_label` is the ONE composer, it filters to this node (name or id), and it parses each block
# regardless of line order. This drives the real binary, because the composer runs before any Lua.
#
# It is also how the test HOME refuses to be the real one: it refuses a HOME that already has
# ~/.wasm-agent/pins.txt in it.
#
# Usage:  bash scripts/test-pin-label.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
WABIN="${WA_BIN:-$TARGET_DIR/debug/wa}"
[ -x "$WABIN" ] || WABIN="$TARGET_DIR/release/wa"
if [ ! -x "$WABIN" ]; then
  echo "SKIP test-pin-label: no binary at $WABIN (build it: cd rust && cargo build -p wa-host)"
  # 77, not 0: a skip is not a pass, and a caller that cannot tell them apart reports a composer it
  # never ran as verified. scripts/test.sh turns this into a counted skip.
  exit 77
fi
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found in '$2'" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there ($2)" ;; *) ok "$1" ;; esac; }

# The scratch tree is made OUTSIDE the real home on purpose: a TMPDIR under ~/.wasm-agent would put
# this test's pins.txt inside the machine's own state, which the guard below refuses (19/11: a test
# that wrote into the real config left a pin the next deploy obeyed).
WORK="$(mktemp -d "${WA_TEST_TMP:-/tmp}/pin-label.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR/.wasm-agent"
# UNKNOWN IS NOT YES: the scratch HOME must be one this script just created, under the mktemp tree, and
# must not be (or be inside) the real home - otherwise the ledger it writes is a machine's real pins.
case "$HOME_DIR" in
  "${HOME:-/nonexistent}"|"${HOME:-/nonexistent}"/*) echo "REFUSING test-pin-label: scratch HOME is the real home ($HOME_DIR)"; exit 1 ;;
esac
[ -d "$WORK" ] && [ -w "$WORK" ] || { echo "REFUSING test-pin-label: no writable scratch tree"; exit 1; }
STATE="$HOME_DIR/.wasm-agent"
PINFILE="$STATE/pins.txt"
# The node's name: `node.name` is what this node announces first, so the composer resolves it too.
echo "work" > "$STATE/node.name"
# WASM_AGENT_HOME is the HOME itself (rust/wa-host-support/src/paths.rs::resolve_home); the state
# directory is <home>/.wasm-agent, which is $STATE.
version() { HOME="$HOME_DIR" WASM_AGENT_HOME="$HOME_DIR" "$WABIN" --version 2>/dev/null; }
# The one owner of the product version: the binary was built from THIS tree, so the version it prints is
# this file.
TREE_VERSION="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/VERSION"

# A pin for a DIFFERENT node must not mark this one. This is the finding: the ledger is fleet-wide.
cat > "$PINFILE" <<'LEDGER'
schema=wasm-agent-pins/1
id=aaaa
node=mail
node_id=1111111111111111
kind=pin
state=active
commit=1111111111111111111111111111111111111111
reason=held on the codeact build until it lands
by=operator
at=2026-11-19T00:00:00Z
LEDGER
OUT="$(version)"
hides "a pin for another node does not mark this one (pinned)" "$OUT" "(pinned)"
hides "...and does not print that node's commit" "$OUT" "11111111"

# A pin for THIS node does - and it is what the label shows.
cat >> "$PINFILE" <<'LEDGER'

schema=wasm-agent-pins/1
id=bbbb
node=work
kind=pin
state=active
commit=2222222222222222222222222222222222222222
reason=this one is held
by=operator
at=2026-11-19T00:01:00Z
LEDGER
OUT="$(version)"
shows "a pin naming this node marks it (pinned)" "$OUT" "22222222 (pinned)"
hides "...and not the other node's commit" "$OUT" "11111111"

# A CLEARED record for this node releases the label, and the LINE ORDER does not decide it: state= before
# commit= is the writer's order, commit= before state= is what a hand edit looks like.
cat >> "$PINFILE" <<'LEDGER'

schema=wasm-agent-pins/1
id=cccc
node=work
state=cleared
commit=2222222222222222222222222222222222222222
reason=released
by=operator
at=2026-11-19T00:02:00Z
LEDGER
OUT="$(version)"
hides "a cleared record releases the label (state= before commit=)" "$OUT" "(pinned)"

cat >> "$PINFILE" <<'LEDGER'

schema=wasm-agent-pins/1
id=dddd
node=work
commit=3333333333333333333333333333333333333333
state=cleared
reason=released again
by=operator
at=2026-11-19T00:03:00Z
LEDGER
OUT="$(version)"
hides "...and the same in the other line order (commit= before state=)" "$OUT" "(pinned)"
hides "...never echoing the commit it cleared" "$OUT" "33333333"

# THE VERSION LINE CARRIES TWO FACTS (Victor, 22/11: "make v0.1.0 be reflected into the entrance ... wa --version
# prints the product version and the sha, from the same source"). It used to be asserted the other way round -
# "never 0.1.0", because a node claimed the crate's version whatever it ran (18/11). Now the product version is
# READ from the tree's VERSION file and the sha is printed beside it, so the line is held to both and to their
# order: a version without a sha would be the 18/11 lie again.
shows "the version line names the program" "$OUT" "wasm-agent v"
shows "...the PRODUCT version, from the tree's VERSION file" "$OUT" "v$(sed -n '1p' "$TREE_VERSION")"
# the separator is the middle dot the line uses (U+00B7); built with printf so this file stays ASCII
DOT=$(printf '\302\267')
shows "...and the bytes beside it, on the same line" "$OUT" " $DOT v"
ok_line=$(printf '%s' "$OUT" | head -1)
case "$ok_line" in
  "wasm-agent v$(sed -n '1p' "$TREE_VERSION") "* ) ok "...in that order: version first, the sha after the separator" ;;
  *) bad "the version line is '<program> v<version> . v<sha>'" "$ok_line" ;;
esac

printf 'test-pin-label: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
