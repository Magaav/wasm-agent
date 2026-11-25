#!/usr/bin/env bash
# THE CUT BUILDS ITS OWN RELEASE (25/11, Fable after the nextcloud-b finding).
#
# A TREE-LESS NODE RUNS THE BINARY'S EMBEDDED LUA. A release renamed from a cover therefore gives that node the
# COVER's Lua while its --build-info names the release commit - measured: node-3589b5ca9690 installed as
# commit=a1857d15, tree=a1857d15^{tree}, because compiled_inputs excludes the embedded Lua. So the cut must
# build node-<sha12> from the release commit, even when a published release already covers its compiled inputs.
#
# WHAT THIS ROW PROVES, without cargo:
#   1. the cut's own publish command (lua/core/land.lua) carries NO cover shortcut - no --named-from-cover and
#      no --ensure, which is the only place the publisher can answer "covered" and publish nothing;
#   2. the case is genuine: a SIGNED release that covers this commit's compiled inputs IS found by the
#      product's own digest search (so a shortcut would have fired);
#   3. and the publisher's --check for that same commit still says it WOULD BUILD node-<sha12> and write its
#      manifest - the cover is not taken.
#
# Hermetic: a stub channel (WA_NODE_BINARIES_URL) and a scratch wa-vault (the real vault/wa_vault.py). No
# network, no gh, no cargo, nothing published.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip() { printf 'SKIP cut builds own: %s\n' "$1"; exit 0; }
command -v python3 >/dev/null 2>&1 || skip 'python3 is needed to sign the fixture cover'
command -v curl >/dev/null 2>&1 || skip 'curl is needed by the scratch vault'
[ -f "$ROOT/vault/wa_vault.py" ] || skip 'vault/wa_vault.py is not in this tree, so no cover can be signed'

R="${WA_ROW_SCRATCH_ROOT:-}"
[ -n "$R" ] || R="$(mktemp -d "${TMPDIR:-/tmp}/wa-cut-own-XXXXXX")" || exit 2
mkdir -p "$R/home" "$R/tmp" "$R/stub" "$R/x" || exit 2
export HOME="$R/home" WASM_AGENT_HOME="$R/home" TMPDIR="$R/tmp"
. "$ROOT/scripts/lib/test-release-vault.sh"
test_release_vault_start || skip 'the scratch vault did not start (python3/curl/vault missing)'
trap 'test_release_vault_stop 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$R"' EXIT
. "$ROOT/scripts/lib/node-binaries.sh"
. "$ROOT/scripts/lib/release-signing.sh"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SHORT="$(wa_node_short_sha "$COMMIT")"
TRIPLE="x86_64-unknown-linux-gnu"
COVER="a1857d15887c"

# ---- 1. the cut's own command, read out of the step that publishes it -------------------------------
CUT="$(grep -n 'publish-node-binaries\.sh --commit' "$ROOT/lua/core/land.lua" | head -1)"
case "$CUT" in *publish-node-binaries.sh*) ok 1 "the cut's publish command is in lua/core/land.lua and names the publisher" ;; *) ok 0 "the cut's publish command is in lua/core/land.lua and names the publisher" "$CUT" ;; esac
case "$CUT" in *--named-from-cover*) ok 0 "the cut passes NO --named-from-cover" "$CUT" ;; *) ok 1 "the cut passes NO --named-from-cover" ;; esac
case "$CUT" in *--ensure*) ok 0 "and no --ensure, the only path that can answer 'covered' and publish nothing" "$CUT" ;; *) ok 1 "and no --ensure, the only path that can answer 'covered' and publish nothing" ;; esac
ok "$([ "$(grep -c 'ENSURE" = 1' "$ROOT/scripts/publish-node-binaries.sh")" -ge 1 ] && echo 1 || echo 0)" "the publisher's cover shortcut is gated on --ensure (the cut does not ask for it)"
ok "$([ "$(grep -c -- '--named-from-cover' "$ROOT/scripts/publish-node-binaries.sh")" -ge 1 ] && echo 1 || echo 0)" "and --named-from-cover still exists as a flag the cut does not pass (removed in week 1)"

# ---- 2. a SIGNED cover that really does cover this commit -------------------------------------------
DIGEST="$(wa_compiled_inputs_digest "$ROOT" "$COMMIT")" || skip 'this commit cannot be digested'
cdir="$R/stub/node-$COVER"
mkdir -p "$cdir"
# A real ELF header for the triple: the digest search checks a binary's shape before it trusts a release.
python3 - "$cdir/wa-$TRIPLE-$COVER" "$cdir/wa-sentinel-$TRIPLE-$COVER" <<'PY'
import sys
ident = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8)
head = ident + bytes([2, 0]) + bytes([0x3e, 0]) + bytes(64 - 20)
for path in sys.argv[1:]:
    open(path, 'wb').write(head + b'cover payload\n')
PY
{
  printf 'source_commit=%s\n' 'a1857d15887cc8f7f3c07419f6af2639e852a8d5'
  printf 'compiled_inputs=%s\n' "$DIGEST"
  printf 'built_utc=2026-11-24T10:00:00Z\n'
  printf 'build_seconds=120\n'
  printf '%s %s %s %s %s\n' "$TRIPLE" "$(wa_node_sha256 "$cdir/wa-$TRIPLE-$COVER")" "$(wc -c < "$cdir/wa-$TRIPLE-$COVER" | tr -d '[:space:]')" "$(wa_node_sha256 "$cdir/wa-sentinel-$TRIPLE-$COVER")" "$(wc -c < "$cdir/wa-sentinel-$TRIPLE-$COVER" | tr -d '[:space:]')"
} > "$cdir/node-$COVER.manifest"
printf 'node-%s\n' "$COVER" > "$R/stub/releases.txt"
test_release_sign_dir "$cdir" >/dev/null 2>&1 || skip 'the cover fixture could not be signed'
export WA_NODE_BINARIES_URL="$R/stub" WA_RELEASE_KEYS="$TEST_RELEASE_VAULT_KEYS"
search="$(wa_node_release_digest_search "$ROOT" "$COMMIT" "$TRIPLE" "$R/x/cache" 2>&1)"; src=$?
ok "$([ "$src" = 0 ] && echo 1 || echo 0)" "the product's own digest search FINDS a release covering this commit (rc $src)" "$search"
case "$search" in *"release_tag=node-$COVER"*) ok 1 "and it is the signed cover, so a shortcut would have fired here" ;; *) ok 0 "and it is the signed cover, so a shortcut would have fired here" "$search" ;; esac

# ---- 3. and the publisher still BUILDS this commit ---------------------------------------------------
out="$(bash "$ROOT/scripts/publish-node-binaries.sh" --check --local --commit "$COMMIT" --target "$TRIPLE" 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1 || echo 0)" "--check for that same commit answers (rc $rc)" "$(printf '%s' "$out" | tail -2)"
case "$out" in *"would build $COMMIT"*) ok 1 "and says it WOULD BUILD this commit, not take the cover" ;; *) ok 0 "and says it WOULD BUILD this commit, not take the cover" "$(printf '%s' "$out" | grep -m2 'would build\|covered')" ;; esac
case "$out" in *"node-$SHORT.manifest"*) ok 1 "and it would write node-$SHORT.manifest - the release named for THIS commit" ;; *) ok 0 "and it would write node-$SHORT.manifest - the release named for THIS commit" "$out" ;; esac
case "$out" in *"covered:"*) ok 0 "and it never answers covered: ... nothing to build" "$out" ;; *) ok 1 "and it never answers covered: ... nothing to build" ;; esac
case "$out" in *"compiled inputs: $DIGEST"*) ok 1 "while naming the very digest the cover carries (the case is genuine)" ;; *) ok 0 "while naming the very digest the cover carries (the case is genuine)" "$(printf '%s' "$out" | grep -m1 'compiled inputs')" ;; esac

if [ "$failed" -gt 0 ]; then printf 'cut builds own FAILED (%d checks, %d failed)\n' "$checks" "$failed"; exit 1; fi
printf 'cut builds own ok (%d checks)\n' "$checks"
