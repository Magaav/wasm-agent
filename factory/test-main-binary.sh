#!/bin/bash
# ONE TEST FOR wa_main_binary, and it can fail.
#
# The rule is Victor's (27/11): no laptop install by default, so the health loop must grade main's tip with
# MAIN'S OWN binary. This test drives the resolution with stubs and asserts the four things that can go
# wrong:
#   * the installed binary (~/.local/bin/wa) is ever returned - the bug this file fixes;
#   * a published bundle for the sha is ignored;
#   * the tree's own build is used when it is ANOTHER commit's (the same bug wearing a different hat);
#   * a resolution that fails says why, instead of returning something.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-main-binary.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
checks=0; failed=0
fail() { echo "FAIL test-main-binary: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
. "$HERE/lib/main-binary.sh"

SHA=0123456789abcdef0123456789abcdef01234567; SHORT=${SHA:0:12}
REL="$WORK/releases"; TARGET="$WORK/target"; LOCAL="$WORK/local/bin"
mkdir -p "$REL" "$TARGET/release" "$LOCAL"
# The laptop's installed binary, and a PATH that has NO cargo: a resolution that would fall back to it must fail
# instead.
printf '#!/bin/bash\necho "wasm-agent v0.1.3"\n' > "$LOCAL/wa"; chmod +x "$LOCAL/wa"

# ---- 1. nothing anywhere: a named refusal, and NOT the installed binary ---------------------------------
out=$(PATH="$LOCAL:/usr/bin:/bin" wa_main_binary "$SHA" "$REL" "$TARGET" 2>&1); rc=$?
ok "$rc" "1" "with no published bundle and no cargo it refuses"
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }
like "$out" "NOT used" "and says the installed binary is not used"
ok "$(case "$out" in *"$LOCAL/wa"*) echo leaked;; *) echo clean;; esac)" "clean" "nothing it prints is the installed binary"

# ---- 2. a published bundle for the sha wins, and the installed binary is never consulted ------------------
mkdir -p "$REL/node-$SHORT"
printf '#!/bin/bash\necho bundle\n' > "$REL/node-$SHORT/wa-x86_64-unknown-linux-gnu-$SHORT"; chmod +x "$REL/node-$SHORT/wa-x86_64-unknown-linux-gnu-$SHORT"
out=$(PATH="$LOCAL:/usr/bin:/bin" wa_main_binary "$SHA" "$REL" "$TARGET" 2>/dev/null)
ok "$out" "$REL/node-$SHORT/wa-x86_64-unknown-linux-gnu-$SHORT" "the published bundle for this sha is the answer"

# ---- 3. the tree's own build, only when it IS this commit ----------------------------------------------
rm -rf "$REL/node-$SHORT"
# A build that reports ANOTHER commit is not "close enough": with no cargo, that must be a refusal.
printf '#!/bin/bash\necho "commit=ffffffffffffffffffffffffffffffffffffffff"\n' > "$TARGET/release/wa"; chmod +x "$TARGET/release/wa"
out=$(PATH="$LOCAL:/usr/bin:/bin" wa_main_binary "$SHA" "$REL" "$TARGET" 2>&1); rc=$?
ok "$rc" "1" "a build of another commit is refused"
like "$out" "$SHORT" "and the refusal names the sha it could not find"
# The same build, reporting THIS commit, is used.
printf '#!/bin/bash\necho "commit=%s"\n' "$SHA" > "$TARGET/release/wa"; chmod +x "$TARGET/release/wa"
out=$(PATH="$LOCAL:/usr/bin:/bin" wa_main_binary "$SHA" "$REL" "$TARGET" 2>/dev/null)
ok "$out" "$TARGET/release/wa" "the tree's own build of this commit is accepted"

if [ "$failed" -gt 0 ]; then echo "test-main-binary: $failed failed of $checks checks"; exit 1; fi
echo "test-main-binary ok ($checks checks)"
