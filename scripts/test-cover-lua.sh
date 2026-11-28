#!/usr/bin/env bash
# A COVER IS THE SAME PROGRAM ONLY IF ITS EMBEDDED LUA IS EQUAL TOO (25/11, week 1).
#
# MEASURED 25/11. node-3589b5ca9690 was published as "named for 3589b5ca" carrying the bytes of
# node-a1857d15887c, because `wa_compiled_inputs_digest` was equal - and a TREE-LESS node runs the binary's
# EMBEDDED Lua (its install has no lua-core to stage), so that node ran a1857d15's Lua while its record said
# 3589b5ca. `compiled_inputs` excludes the Lua tree on purpose: a node WITH a tree stages its own lua-core
# beside the binary and never reads the embedded copy. The digest therefore answers "does this change need a
# build?" and NOT "is this the same program?", and the two answers differ exactly for a tree-less node.
#
# WHAT THIS ROW PROVES, and why each part earns a line:
#   1. the two digests answer two DIFFERENT questions - a Lua-only commit changes the Lua-tree digest and NOT
#      the compiled-inputs one; a scripts-only commit changes neither. That is why folding lua/ into
#      `wa_compiled_input` is the wrong fix: it would price a full build on every Lua change (measured on
#      origin/main: 64 of the last 250 first-parent landings are Lua-only, against 31 that compile something).
#   2. the publisher NAMES the Lua tree its bytes embed (`lua_inputs=`), and `--from` recomputes that row
#      instead of trusting the build host: a manifest naming another tree is refused (lua_inputs_mismatch).
#   3. the tree-less door - scripts/upgrade.sh, the ONE code path that installs new bytes - REFUSES a cover
#      when the Lua cannot be shown equal, by name: no digest given, no row in the manifest, a different
#      digest, or a manifest the signed sums do not cover. And it PASSES when they are equal, which is what
#      makes the honest cover (a docs/scripts-only commit) installable at all on such a node.
#
# Hermetic: a scratch HOME/WASM_AGENT_HOME, a scratch install directory, a scratch wa-vault (the real
# vault/wa_vault.py) for the signature the release gate demands, and a fixture git repository. No network,
# no cargo, no gh, no live node.
#
#   bash scripts/test-cover-lua.sh        (prints 'cover lua: ok (N checks)'; a failed check exits 1)
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/scratch-home.sh"
checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
says() { printf '%s' "$1" | grep -qF -- "$2"; }
skip() { printf 'SKIP cover lua: %s\n' "$1"; exit 0; }
command -v python3 >/dev/null 2>&1 || skip 'python3 is needed to sign the fixture release'
command -v curl >/dev/null 2>&1 || skip 'curl is needed by the scratch vault'
[ -f "$ROOT/vault/wa_vault.py" ] || skip 'vault/wa_vault.py is not in this tree, so no release can be signed'

scratch_root="${WA_ROW_SCRATCH_ROOT:-}"
[ -n "$scratch_root" ] || scratch_root="$(wa_scratch_root wa-cover-lua)" || exit 2
R="$(mktemp -d "$scratch_root/row.XXXXXX")" || exit 2
mkdir -p "$R/home" "$R/tmp" "$R/repo" "$R/install" || exit 2
wa_scratch_home_guard "$R/home" || { rm -rf "$R"; exit 2; }
export HOME="$R/home" WASM_AGENT_HOME="$R/home" TMPDIR="$R/tmp"
. "$ROOT/scripts/lib/test-release-vault.sh"
test_release_vault_start || { rm -rf "$R"; skip 'the scratch vault did not start (python3/curl/vault missing)'; }
trap 'test_release_vault_stop 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$R"' EXIT
. "$ROOT/scripts/lib/node-binaries.sh"
. "$ROOT/scripts/lib/lua-tree.sh"
. "$ROOT/scripts/lib/release-signing.sh"
export WA_RELEASE_KEYS="$TEST_RELEASE_VAULT_KEYS"
TRIPLE="x86_64-unknown-linux-gnu"

elf() { # <machine-hex> <path...>: a real ELF header of that machine - the release gate reads a binary's shape
  local machine="$1"; shift
  python3 - "$machine" "$@" <<'PY'
import sys
machine = int(sys.argv[1], 16)
ident = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8)
head = ident + bytes([2, 0]) + bytes([machine & 0xff, machine >> 8]) + bytes(64 - 20)
for path in sys.argv[2:]:
    open(path, 'wb').write(head + b'fixture payload\n')
PY
}

# ---- 1. the two digests answer two different questions --------------------------------------------
# A fixture repository, because the classification is about COMMITS: a base commit, a Lua-only change on top
# of it, and a scripts-only change on top of that. The numbers quoted in the header come from origin/main and
# are not re-measured here.
fixture="$R/repo"
git -C "$fixture" init -q
git -C "$fixture" config user.email t@t
git -C "$fixture" config user.name t
mkdir -p "$fixture/lua/core" "$fixture/scripts" "$fixture/rust"
printf 'local M = {}\nreturn M\n' > "$fixture/lua/core/a.lua"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/scripts/thing.sh"
printf 'fn main() {}\n' > "$fixture/rust/main.rs"
printf '# orchestrator\n' > "$fixture/AGENTS.orchestrator.md"
git -C "$fixture" add -A && git -C "$fixture" commit -qm base
C_BASE="$(git -C "$fixture" rev-parse HEAD)"
printf 'local M = {}\nreturn M, 2\n' > "$fixture/lua/core/a.lua"
git -C "$fixture" commit -qam 'lua only'
C_LUA="$(git -C "$fixture" rev-parse HEAD)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fixture/scripts/thing.sh"
git -C "$fixture" commit -qam 'scripts only'
C_SCRIPT="$(git -C "$fixture" rev-parse HEAD)"

same() { [ "$1" = "$2" ] && echo 1 || echo 0; }
: "${C_BASE:?}" "${C_LUA:?}" "${C_SCRIPT:?}"
ok "$(same "$(wa_compiled_inputs_digest "$fixture" "$C_BASE")" "$(wa_compiled_inputs_digest "$fixture" "$C_LUA")")" \
  'a Lua-only commit compiles nothing: the compiled-inputs digest is unchanged (a cover is right for a node WITH a tree)'
ok "$([ "$(same "$(wa_lua_tree_digest "$fixture" "$C_BASE")" "$(wa_lua_tree_digest "$fixture" "$C_LUA")")" = 0 ] && echo 1 || echo 0)" \
  'the Lua-tree digest CHANGES with a Lua-only commit (the fact compiled_inputs cannot see)'
ok "$(same "$(wa_compiled_inputs_digest "$fixture" "$C_LUA")" "$(wa_compiled_inputs_digest "$fixture" "$C_SCRIPT")")" \
  'a scripts-only commit compiles nothing either'
ok "$(same "$(wa_lua_tree_digest "$fixture" "$C_LUA")" "$(wa_lua_tree_digest "$fixture" "$C_SCRIPT")")" \
  'and its Lua tree is unchanged: this is the cover a tree-less node may install'

# ---- 2. the publisher names the Lua tree the bytes EMBED ------------------------------------------
# The publisher runs against a FIXTURE tree (this checkout is a mission worktree: dirty and unpushed, both of
# which the publisher refuses on purpose). The fixture is given this tree's own libs so it answers with the
# real code, and ALLOW_UNPUSHED_COMMIT=1 is the publisher's own name for a development artifact that is
# installed nowhere.
mkdir -p "$fixture/config"
cp -R "$ROOT/scripts/." "$fixture/scripts/"
cp -R "$ROOT/config/." "$fixture/config/"
cp -R "$ROOT/assets" "$fixture/assets" 2>/dev/null || true
cp "$ROOT/AGENTS."*.md "$fixture/" 2>/dev/null || true
git -C "$fixture" add -A && git -C "$fixture" commit -qm tools
FIXTURE_SHA="$(git -C "$fixture" rev-parse HEAD)"
FIXTURE_SHORT="${FIXTURE_SHA:0:12}"
# A NON-NATIVE TRIPLE ON PURPOSE: the publisher EXECUTES a native row to prove it runs, and a fixture binary
# cannot answer --version. An aarch64 row on this x86_64 host is reported as skipped, which is what a real
# cross build from this machine is too.
PUB_TRIPLE=aarch64-unknown-linux-gnu
publish() { ALLOW_UNPUSHED_COMMIT=1 ALLOW_UNPUSHED_REASON='the fixture commit is a development artifact, installed nowhere' bash "$fixture/scripts/publish-node-binaries.sh" --repo "$fixture" --target "$PUB_TRIPLE" "$@"; }

plan="$(publish --check --local --allow-empty-codemode 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1 || echo 0)" "--check for the fixture commit answers (rc $rc)" "$(printf '%s' "$plan" | tail -2)"
ok "$(says "$plan" "lua inputs: $(wa_lua_tree_digest "$fixture" "$FIXTURE_SHA")" && echo 1 || echo 0)" \
  'and the plan names the Lua-tree digest the binary will EMBED'

# A manifest built elsewhere that does not carry the row: --from gives it one, from THIS commit's tree.
built="$R/built"
mkdir -p "$built"
elf b7 "$built/wa-$PUB_TRIPLE-$FIXTURE_SHORT" "$built/wa-sentinel-$PUB_TRIPLE-$FIXTURE_SHORT"
  # The set a --from publish receives is the FOUR-member set the publisher now requires of any bundle: it copies
  # the one member list, so a two-member directory cannot produce an installable bundle (binary_missing).
  elf b7 "$built/wa-term-$PUB_TRIPLE-$FIXTURE_SHORT" "$built/wa-operations-supervisor-$PUB_TRIPLE-$FIXTURE_SHORT"
write_manifest() { # <dir> [extra lines...]
  local dir="$1"; shift
  local line
  {
    printf 'schema=wasm-agent-node-binaries/1\n'
    printf 'source_commit=%s\n' "$FIXTURE_SHA"
    printf 'source_tree=%s\n' "$(git -C "$fixture" rev-parse "$FIXTURE_SHA^{tree}")"
    printf 'glibc_floor=2.31\n'
    printf 'codemode=embedded\n'
    printf 'built_utc=2026-11-25T00:00:00Z\n'
    for line in "$@"; do printf '%s\n' "$line"; done
    printf '# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes wa-term_sha256 wa-term_bytes wa-operations-supervisor_sha256 wa-operations-supervisor_bytes\n'
    printf '%s %s %s %s %s %s %s %s %s\n' "$PUB_TRIPLE" \
      "$(wa_node_sha256 "$dir/wa-$PUB_TRIPLE-$FIXTURE_SHORT")" "$(wc -c < "$dir/wa-$PUB_TRIPLE-$FIXTURE_SHORT" | tr -d '[:space:]')" \
      "$(wa_node_sha256 "$dir/wa-sentinel-$PUB_TRIPLE-$FIXTURE_SHORT")" "$(wc -c < "$dir/wa-sentinel-$PUB_TRIPLE-$FIXTURE_SHORT" | tr -d '[:space:]')" \
      "$(wa_node_sha256 "$dir/wa-term-$PUB_TRIPLE-$FIXTURE_SHORT")" "$(wc -c < "$dir/wa-term-$PUB_TRIPLE-$FIXTURE_SHORT" | tr -d '[:space:]')" \
      "$(wa_node_sha256 "$dir/wa-operations-supervisor-$PUB_TRIPLE-$FIXTURE_SHORT")" "$(wc -c < "$dir/wa-operations-supervisor-$PUB_TRIPLE-$FIXTURE_SHORT" | tr -d '[:space:]')"
  } > "$dir/node-$FIXTURE_SHORT.manifest"
}
write_manifest "$built"
out="$(publish --from "$built" --out "$R/bundle" 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1 || echo 0)" "--from a matching artifact set answers (rc $rc)" "$(printf '%s' "$out" | tail -3)"
ok "$(says "$(cat "$R/bundle/node-$FIXTURE_SHORT.manifest" 2>/dev/null)" "lua_inputs=$(wa_lua_tree_digest "$fixture" "$FIXTURE_SHA")" && echo 1 || echo 0)" \
  'the bundled manifest names the Lua tree those bytes EMBED (computed here, not taken from the build host)'

liar="$R/built-liar"
cp -r "$built" "$liar"
write_manifest "$liar" "lua_inputs=$(printf 'a%.0s' $(seq 64))"
out="$(publish --from "$liar" --out "$R/bundle-liar" 2>&1)"; rc=$?
ok "$([ "$rc" = 5 ] && echo 1 || echo 0)" "--from a manifest recording another Lua tree is refused (rc $rc, expected 5)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'lua_inputs_mismatch:' && echo 1 || echo 0)" \
  'and the refusal names the row it disagrees about (those bytes embed another program)'

# ---- 3. the tree-less door refuses a cover whose embedded Lua is not the target's ------------------
# THE REAL PATH: scripts/upgrade.sh, installed as it is on a node, run with the candidate and the release
# directory a release install hands it. The releases here are really signed (scratch vault), because the
# signature gate runs before the cover gate and a fixture that skipped it would prove nothing about the order.
INSTALL="$R/install"
mkdir -p "$INSTALL/scripts" "$INSTALL/ui"
cp -R "$ROOT/scripts/." "$INSTALL/scripts/"
cp -R "$ROOT/config" "$INSTALL/config" 2>/dev/null || true
printf '#!/usr/bin/env bash\nexit 0\n' > "$INSTALL/wa"
chmod +x "$INSTALL/wa"
printf 'commit=%s\nbranch=main\ndirty=0\n' "$C_BASE" > "$INSTALL/installed.txt"

cover_release() { # <dir> <cover commit> [extra manifest lines...] -> the directory
  local dir="$1" commit="$2"; shift 2
  local short="${commit:0:12}" line
  rm -rf "$dir"; mkdir -p "$dir"
  elf 3e "$dir/wa-$TRIPLE-$short" "$dir/wa-sentinel-$TRIPLE-$short"
  # THE OTHER TWO MEMBERS: a release this publisher can produce carries wa-term and wa-operations-supervisor,
  # and upgrade.sh refuses a set whose wa-term is not beside it before it reads the cover rule this row is about
  # (term_program_missing, measured: the cover cases answered 2 instead of 3).
  elf 3e "$dir/wa-term-$TRIPLE-$short" "$dir/wa-operations-supervisor-$TRIPLE-$short"
  chmod +x "$dir/wa-$TRIPLE-$short" "$dir/wa-sentinel-$TRIPLE-$short" "$dir/wa-term-$TRIPLE-$short" "$dir/wa-operations-supervisor-$TRIPLE-$short"
  # upgrade.sh resolves the siblings BY THE RUNTIME NAME, not the release asset name: it takes dirname of the
  # binary it was handed and looks for a plain wa-term there (scripts/upgrade.sh:168-185). A release directory
  # that carries only the suffixed files answers term_program_missing before the cover rule below is read.
  cp -f "$dir/wa-term-$TRIPLE-$short" "$dir/wa-term"
  cp -f "$dir/wa-operations-supervisor-$TRIPLE-$short" "$dir/wa-operations-supervisor"
  {
    printf 'schema=wasm-agent-node-binaries/1\n'
    printf 'source_commit=%s\n' "$commit"
    printf 'source_tree=%s\n' "$(git -C "$fixture" rev-parse "$commit^{tree}")"
    printf 'compiled_inputs=%s\n' "$(wa_compiled_inputs_digest "$fixture" "$commit")"
    for line in "$@"; do printf '%s\n' "$line"; done
    printf 'glibc_floor=2.31\n'
    printf 'codemode=embedded\n'
    printf '# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes wa-term_sha256 wa-term_bytes wa-operations-supervisor_sha256 wa-operations-supervisor_bytes\n'
    printf '%s %s %s %s %s %s %s %s %s\n' "$TRIPLE" \
      "$(wa_node_sha256 "$dir/wa-$TRIPLE-$short")" "$(wc -c < "$dir/wa-$TRIPLE-$short" | tr -d '[:space:]')" \
      "$(wa_node_sha256 "$dir/wa-sentinel-$TRIPLE-$short")" "$(wc -c < "$dir/wa-sentinel-$TRIPLE-$short" | tr -d '[:space:]')" \
      "$(wa_node_sha256 "$dir/wa-term-$TRIPLE-$short")" "$(wc -c < "$dir/wa-term-$TRIPLE-$short" | tr -d '[:space:]')" \
      "$(wa_node_sha256 "$dir/wa-operations-supervisor-$TRIPLE-$short")" "$(wc -c < "$dir/wa-operations-supervisor-$TRIPLE-$short" | tr -d '[:space:]')"
  } > "$dir/node-$short.manifest"
  test_release_sign_dir "$dir" >/dev/null 2>&1 || skip "the fixture release $dir could not be signed"
  printf '%s\n' "$dir"
}
upgrade_with() { # <release dir> <requested commit> <lua digest or empty>
  WA_INSTALL_DIR="$INSTALL" WA_PORT=8799 WA_CLIENT_PORT=8800 \
  WA_UPGRADE_REQUESTED_COMMIT="$2" WA_RELEASE_LUA_INPUTS="${3:-}" \
    bash "$INSTALL/scripts/upgrade.sh" "$1/wa-$TRIPLE-$(sed -n 's/^source_commit=//p' "$1/node-"*.manifest | head -1 | cut -c1-12)" --release "$1" 2>&1
}

LUA_DIGEST="$(wa_lua_tree_digest "$fixture" "$C_LUA")"
BASE_DIGEST="$(wa_lua_tree_digest "$fixture" "$C_BASE")"
R1="$(cover_release "$R/release1" "$C_BASE" "lua_inputs=$BASE_DIGEST")"

out="$(upgrade_with "$R1" "$C_LUA" "")"; rc=$?
ok "$([ "$rc" = 3 ] && echo 1 || echo 0)" "a cover with no Lua-tree digest given is refused (rc $rc, expected 3)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'release_cover_lua_unknown' && echo 1 || echo 0)" 'by name: release_cover_lua_unknown' "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'nothing was staged' && echo 1 || echo 0)" 'and it says nothing was staged'

out="$(upgrade_with "$R1" "$C_LUA" "$LUA_DIGEST")"; rc=$?
ok "$([ "$rc" = 3 ] && echo 1 || echo 0)" "a cover whose embedded Lua tree differs from the target's is refused (rc $rc, expected 3)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'release_cover_lua_mismatch' && echo 1 || echo 0)" 'by name: release_cover_lua_mismatch' "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" "$BASE_DIGEST" && echo 1 || echo 0)" 'and it names the Lua tree these bytes embed'
ok "$(says "$out" "$LUA_DIGEST" && echo 1 || echo 0)" 'and the Lua tree the target commit has'

# A release published before the row existed (or by a publisher that lost it). Unknown is not yes.
R2="$(cover_release "$R/release2" "$C_BASE")"
out="$(upgrade_with "$R2" "$C_LUA" "$LUA_DIGEST")"; rc=$?
ok "$([ "$rc" = 3 ] && echo 1 || echo 0)" "a cover whose manifest names no lua_inputs row is refused (rc $rc, expected 3)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'release_cover_lua_unrecorded' && echo 1 || echo 0)" 'by name: release_cover_lua_unrecorded' "$(printf '%s' "$out" | tail -2)"

# A manifest whose bytes the signed sums do not cover: the row is the witness, so the witness is verified.
R3="$(cover_release "$R/release3" "$C_BASE" "lua_inputs=$BASE_DIGEST")"
printf 'note=swapped after signing\n' >> "$R3/node-$(sed -n 's/^source_commit=//p' "$R3/node-"*.manifest | head -1 | cut -c1-12).manifest"
out="$(upgrade_with "$R3" "$C_LUA" "$LUA_DIGEST")"; rc=$?
ok "$([ "$rc" = 3 ] && echo 1 || echo 0)" "a cover whose manifest the signed sums do not name is refused (rc $rc, expected 3)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'release_cover_lua_manifest_unverified' && echo 1 || echo 0)" 'by name: release_cover_lua_manifest_unverified' "$(printf '%s' "$out" | tail -2)"

# AND THE HONEST COVER PASSES. The node is asked for the SCRIPTS-ONLY commit; the cover is the LUA-ONLY one,
# whose Lua tree is identical, so those bytes are this commit's program. The gate must not refuse it: the run
# goes on to the next gate (the candidate's own identity - a fixture ELF cannot answer --build-info), which is
# where this row stops, because the row is about the cover gate and not about installing.
R4="$(cover_release "$R/release4" "$C_LUA" "lua_inputs=$LUA_DIGEST")"
out="$(upgrade_with "$R4" "$C_SCRIPT" "$(wa_lua_tree_digest "$fixture" "$C_SCRIPT")")"; rc=$?
ok "$([ "$rc" != 3 ] && echo 1 || echo 0)" "a cover whose embedded Lua tree IS the target commit's is not refused by the cover gate (rc $rc)" "$(printf '%s' "$out" | tail -2)"
ok "$([ "$(says "$out" 'release_cover_lua_' && echo 0 || echo 1)" = 1 ] && echo 1 || echo 0)" \
  'and none of the cover refusals appears in its output'
ok "$(says "$out" 'signed:' && echo 1 || echo 0)" 'it got past the signature gate, so the order is: signed first, then the Lua check' "$(printf '%s' "$out" | head -4)"

# ---- 4. the two facts CROSS THE DOOR: scripts/release-install.sh hands them to scripts/upgrade.sh ------
# The tree-less door cannot compute either fact (no tree, no git), so the caller names them. This is the seam
# that carries them, proved with two real processes: release-install.sh (env -i, its own install dir) downloads
# the cover and runs upgrade.sh as a CHILD, which is the process that refuses. Nothing is installed: every case
# below stops at the cover gate, before anything is staged.
DOOR="$INSTALL/scripts/release-install.sh"
BASE_SHORT="${C_BASE:0:12}"
# wa_node_binary_download reads a stub channel FLAT ($BASE/node-<sha12>.manifest, $BASE/wa-...), while the
# digest SEARCH keys it by tag ($BASE/node-<sha12>/...). This channel is for the door, so it is flat.
CHANNEL="$R/channel"
mkdir -p "$CHANNEL"
cp -R "$R1/." "$CHANNEL/"
printf 'node-%s\n' "$BASE_SHORT" > "$CHANNEL/releases.txt"
EMPTY_CHANNEL="$R/empty-channel"
mkdir -p "$EMPTY_CHANNEL"
printf '' > "$EMPTY_CHANNEL/releases.txt"
door() { # <channel> <args...> -> the door's own output
  local channel="$1"; shift
  env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin TMPDIR="$TMPDIR" \
    WA_INSTALL_DIR="$INSTALL" WA_NODE_BINARIES_URL="$channel" WA_NODE_RELEASE_REPO=fixture/repo \
    WA_RELEASE_KEYS="$WA_RELEASE_KEYS" \
    bash "$DOOR" "$@" 2>&1
}

out="$(door "$EMPTY_CHANNEL" "$C_LUA")"; rc=$?
ok "$([ "$rc" = 2 ] && echo 1 || echo 0)" "a tree-less node asked for a commit nothing publishes is refused (rc $rc, expected 2)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'release_cover_needed' && echo 1 || echo 0)" 'by name: release_cover_needed' "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" '--cover-commit' && echo 1 || echo 0)" 'and it names the two facts the caller must pass'
ok "$(says "$out" '--lua-inputs' && echo 1 || echo 0)" '...both of them'

out="$(door "$EMPTY_CHANNEL" "$C_LUA" --cover-commit "$C_BASE")"; rc=$?
ok "$([ "$rc" = 2 ] && echo 1 || echo 0)" "a cover named without the target's Lua digest is refused before anything is downloaded (rc $rc)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'release_cover_lua_unknown' && echo 1 || echo 0)" 'by name: release_cover_lua_unknown' "$(printf '%s' "$out" | tail -2)"

out="$(door "$EMPTY_CHANNEL" "$C_BASE" --cover-commit "$C_BASE" --lua-inputs "$BASE_DIGEST")"; rc=$?
ok "$(says "$out" 'cover_commit_pointless' && echo 1 || echo 0)" 'a cover that names the commit itself is refused instead of silently used' "$(printf '%s' "$out" | tail -2)"

# THE SEAM: the cover is on the channel, both facts are given, and the CHILD (upgrade.sh) is what refuses -
# naming the two digests it got from a process that could not compute either one itself.
out="$(door "$CHANNEL" "$C_LUA" --cover-commit "$C_BASE" --lua-inputs "$LUA_DIGEST")"; rc=$?
ok "$([ "$rc" != 0 ] && echo 1 || echo 0)" "a cover whose embedded Lua differs from the target's is refused through the door too (rc $rc)" "$(printf '%s' "$out" | tail -2)"
ok "$(says "$out" 'taking the cover node-' && echo 1 || echo 0)" 'the door fetched the cover it was told to fetch'
ok "$(says "$out" 'release_cover_lua_mismatch' && echo 1 || echo 0)" 'and upgrade.sh, as its child process, refused it by name - the two facts crossed the boundary'
ok "$(says "$out" "$BASE_DIGEST" && echo 1 || echo 0)" 'with the Lua tree those bytes embed'
ok "$(says "$out" "$LUA_DIGEST" && echo 1 || echo 0)" 'and the Lua tree the target commit has'

if [ "$failed" != 0 ]; then printf 'cover lua FAILED (%s checks, %s failed)\n' "$checks" "$failed" >&2; exit 1; fi
printf 'cover lua: ok (%s checks)\n' "$checks"

