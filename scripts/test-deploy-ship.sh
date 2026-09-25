#!/usr/bin/env bash
# Does `deploy.sh` ship a WhatsApp pipeline that can *start*?
#
# The failure this exists for: `5cc38d1` moved the WebSocket runtime into
# `scripts/lib/websocket-runtime.mjs`, deploy.sh copied `scripts/whatsapp-*` and nothing else, and the
# install held a reader whose own import was absent. The deploy reported success; every subsequent delivery
# died at step 3 with ERR_MODULE_NOT_FOUND, 26 of them, one per tick, and `job history` was the only place
# that said so. A pipeline that cannot start is not a deployed pipeline.
#
# So this test does not describe what deploy.sh does - it *runs it*: the block under test is read out of
# deploy.sh between its own markers, with a scratch ROOT and a scratch INSTALL_DIR, and then:
#
#   1. every module a shipped script imports is installed beside it;
#   2. a tree whose imported module is missing is **refused**, naming the module; and
#   3. a shipped script that imports something this deploy cannot install is refused too - the closure
#      check, which is the one that would have caught the live failure from the other side.
#
# Hermetic: a temp directory per run, no browser, no sentinel, no model, and nothing outside it is touched.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/scripts/deploy.sh"
# The block starts at the copy loop (its first line) and ends before the job files: everything between is
# the WhatsApp pipeline's own ship list.
START_MARK='for source in "$ROOT"/scripts/whatsapp-*; do'
END_MARK='^  INSTALL_MIXED='

fail() { echo "test-deploy-ship: $*" >&2; exit 1; }

[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"
BLOCK="$(awk -v start="$START_MARK" 'index($0, start) && !on { on = 1 } on { print } /^  INSTALL_MIXED=/ { if (on) exit }' "$DEPLOY")"
printf '%s' "$BLOCK" | grep -q 'MODULES=' || fail "could not read the ship block out of deploy.sh (the marker moved?)"
printf '%s' "$BLOCK" | grep -q 'which this deploy did not install' || fail "the extracted block has no closure check to test"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-ship-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# One run of the real block. `fail` is the deploy's own refusal path, so a refusal exits non-zero here too.
run_block() { # root install_dir -> the block's output, refusal in it when it refused
  local root="$1" install="$2" wrapper="$WORK/run.sh"
  mkdir -p "$install/scripts" || return 1
  {
    echo 'set -uo pipefail'
    echo "ROOT=\"$root\""
    echo "INSTALL_DIR=\"$install\""
    echo 'PIPELINE=0'
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    printf '%s\n' "$BLOCK"
    echo 'echo "PIPELINE=$PIPELINE"'
  } > "$wrapper"
  bash "$wrapper" 2>&1
}

# A scratch tree that is exactly what the repository has for this pipeline.
stage_tree() { # destination
  mkdir -p "$1/scripts/lib" || return 1
  cp -f "$ROOT"/scripts/whatsapp-* "$1/scripts/" || return 1
  cp -f "$ROOT/scripts/lib/websocket-runtime.mjs" "$1/scripts/lib/" || return 1
}

TREE="$WORK/tree"
stage_tree "$TREE" || fail "could not stage a scratch tree"
OUT="$(run_block "$TREE" "$WORK/install")"
[ $? = "0" ] || fail "the ship block refused a complete tree: $OUT"
echo "$OUT" | grep -q 'PIPELINE=' || fail "the ship block did not reach its end: $OUT"

# 1. The reader and the module it imports are both installed, and every other relative import resolves.
[ -f "$WORK/install/scripts/whatsapp-read.mjs" ] || fail "the reader itself was not installed"
[ -f "$WORK/install/scripts/lib/websocket-runtime.mjs" ] \
  || fail "whatsapp-read.mjs imports ./lib/websocket-runtime.mjs and the deploy did not install it"
for source in "$WORK/install"/scripts/whatsapp-*; do
  [ -f "$source" ] || continue
  for relative in $(grep -o '\./[A-Za-z0-9._/-]*' "$source" 2>/dev/null | sort -u); do
    [ -f "$WORK/install/scripts/${relative#./}" ] \
      || fail "$(basename "$source") imports $relative but the install does not have it"
  done
done
echo "ok   an installed pipeline is import-closed (lib: $(ls "$WORK/install/scripts/lib" | tr '\n' ' '))"

# 2. A tree that has the importing script but not the module it imports must be refused, naming it.
BARE="$WORK/tree-bare"
mkdir -p "$BARE/scripts" || fail "could not build the incomplete tree"
cp -f "$ROOT"/scripts/whatsapp-* "$BARE/scripts/" || fail "could not stage the incomplete tree"
BARE_OUT="$(run_block "$BARE" "$WORK/install-bare")"
BARE_STATUS=$?
[ "$BARE_STATUS" != "0" ] || fail "a tree whose imported module is missing was installed anyway: $BARE_OUT"
echo "$BARE_OUT" | grep -q 'scripts/lib/websocket-runtime.mjs' \
  || fail "the refusal did not name the missing module: $BARE_OUT"
echo "ok   a tree missing an imported module is refused, naming it"

# 3. The closure check: a shipped script importing something this deploy does not install is refused, even
#    when the tree is otherwise complete. This is the half that catches a dependency arriving under a name
#    the ship list does not know (a sibling file the glob misses, say).
LEAKY="$WORK/tree-leaky"
stage_tree "$LEAKY" || fail "could not stage the leaky tree"
printf 'import { nothing } from "./whatsapp-not-shipped.mjs";\n' > "$LEAKY/scripts/whatsapp-leaky.mjs" \
  || fail "could not write the leaky fixture"
LEAKY_OUT="$(run_block "$LEAKY" "$WORK/install-leaky")"
LEAKY_STATUS=$?
[ "$LEAKY_STATUS" != "0" ] || fail "an install whose script cannot load was reported as deployed: $LEAKY_OUT"
echo "$LEAKY_OUT" | grep -q 'whatsapp-not-shipped.mjs' \
  || fail "the closure refusal did not name the unshipped import: $LEAKY_OUT"
echo "ok   a shipped script importing an uninstalled module is refused, naming it"

echo "ALL PASS"
