#!/usr/bin/env bash
# A Lua-only deploy: does the record name BOTH commits, and does the deploy stop refusing its own install?
#
# WHAT THIS EXISTS FOR (measured 21/11 on avell, twice: land254 de2c755f, land257 93168d96). A deploy whose
# change touches nothing compiled takes the Lua fast path: it keeps the installed binary, installs lua-core,
# restarts the node - and then refused the install it had just made:
#
#   deploy: refused(build_commit_mismatch): the binary installed at ~/.local/bin/wa reports commit a5d8c6167965
#   but this deploy meant to install 93168d96
#
# because scripts/deploy.sh took the commit of the binary it KEPT from `INSTALLED_COMMIT` - the record's
# commit= fallback - and scripts/lib/install-record.sh's wa_running_identity returns as soon as the binary
# names its own commit, so that variable is "" exactly when the binary can answer, which is every fast path.
# The Lua tree WAS installed, the node restarted, installed.txt was not rewritten, and the deploy unit failed.
#
# WHAT IS ASSERTED, each claim by running the real code:
#   1. the kept binary's commit is taken from the binary itself: wa_running_identity (real, early return
#      included) plus the deploy's own region, both read out of the files that ship them, never restated here;
#   2. a full install followed by a Lua-only deploy writes commit=<the Lua tree> AND binary_commit=<the kept
#      binary's build>, with lua_tree=<the Lua tree> and lua_fast_path=1 - and does not refuse
#      build_commit_mismatch (the code before this change does: that is the row test-discriminates sees);
#   3. a second Lua-only deploy keeps naming both: commit= moves forward, binary_commit= stays;
#   4. when the kept binary stops answering, binary_commit= comes from the record - and a record whose commit=
#      is a LUA TREE (lua_fast_path=1) is never read as the binary's commit;
#   5. when nothing names the bytes, binary_commit= is `unknown` WITH binary_commit_why= - never an empty line,
#      and never the tree's commit;
#   6. a record that disagrees with a binary that can answer is recorded and the binary wins (nothing is
#      replaced on a fast path, so there is nothing to refuse);
#   7. binary_inputs= is the digest of commit= (the tree), so the next deploy's reuse decision compares like
#      with like.
#
# HOW. The kept-binary block of scripts/deploy.sh (from its LUA_FAST=0 to its INSTALLED_BIN= line) and
# record_installed() are extracted and run in a scratch install directory, over the REAL
# scripts/lib/install-record.sh and scripts/lib/node-binaries.sh. The `wa` in that directory is a stub that
# answers --build-info. A hand-written stub is used because scripts/lib/contract-host.lua fakes the Lua HOST
# for Lua code; what this needs is a node EXECUTABLE's command line, which no shared fake covers - so the stub
# answers --build-info and nothing else, and it refuses everything the real binary would refuse.
#
# Hermetic: a scratch HOME, WASM_AGENT_HOME and install directory under mktemp; the machine's own
# ~/.wasm-agent and ~/.local/bin are never read or written; no cargo, no network, no restart, no model.
# Wired into scripts/test.sh beside the other deploy gates.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/scripts/deploy.sh"
LIB="$ROOT/scripts/lib/install-record.sh"
NODELIB="$ROOT/scripts/lib/node-binaries.sh"

checks=0 failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found in: $(printf '%s' "$2" | tail -3 | tr '\n' '|')" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there ($(printf '%s' "$2" | grep -m1 "$3"))" ;; *) ok "$1" ;; esac; }
say()   { printf 'test-deploy-luafast-record: %s\n' "$*"; }
field() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }

[ -f "$DEPLOY" ] || { say "no $DEPLOY to test"; exit 1; }
[ -f "$LIB" ] || { say "no $LIB to test"; exit 1; }
[ -f "$NODELIB" ] || { say "no $NODELIB to test"; exit 1; }

# NEVER THE MACHINE'S OWN STATE. This file writes install records, so HOME, the agent state directory and every
# install it touches live under a scratch tree - and it refuses outright if any of them is the real one.
REAL_HOME="${HOME:-/nonexistent}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-luafast-record-XXXXXX")" || { say "no scratch directory"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME" || { say "cannot make a scratch HOME"; exit 1; }
export WASM_AGENT_HOME="$WORK/agent-home"
mkdir -p "$WASM_AGENT_HOME" || { say "cannot make a scratch state directory"; exit 1; }
REAL_STATE="$REAL_HOME/.wasm-agent"
[ -e "$REAL_STATE" ] && REAL_STATE="$(cd "$REAL_STATE" && pwd -P)"
for probe in "$HOME" "$WASM_AGENT_HOME" "$WORK"; do
  resolved="$(cd "$probe" && pwd -P)"
  if [ "$resolved" = "$REAL_STATE" ] || [ "$resolved" = "$REAL_HOME" ]; then
    say "refusing: $probe is this machine's own state ($resolved); this file writes install records and only into a scratch tree" >&2
    exit 1
  fi
done
# A scratch directory NESTED under $TMPDIR is expected - this harness sets TMPDIR to $REAL_STATE/tmp, so a
# prefix test here would refuse every honest run. What matters is that no install record is written into
# $REAL_STATE, and every directory this file writes to is under $WORK.

# --- the real code, read out of the files that ship it --------------------------------------------
# The deploy's kept-binary block, from its own LUA_FAST=0 to its own INSTALLED_BIN= line. On the code before
# this change that block is two lines that read installed.txt's commit=; here it is the resolution itself - so
# the SAME extraction runs both, and every case below is an assertion about what the block resolves, not about
# whether some marker text still exists.
awk '/^LUA_FAST=0$/{on=1} on && /^INSTALLED_BIN=/{print; exit} on' "$DEPLOY" > "$WORK/kept-binary.sh"
grep -q 'INSTALLED_BINARY_COMMIT=' "$WORK/kept-binary.sh" \
  || { say "could not read the kept-binary block out of scripts/deploy.sh (from LUA_FAST=0 to INSTALLED_BIN=)"; exit 1; }
awk '/^record_installed\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$DEPLOY" > "$WORK/record-installed.sh"
grep -q 'binary_commit=' "$WORK/record-installed.sh" \
  || { say "could not read record_installed out of scripts/deploy.sh, or it no longer writes binary_commit="; exit 1; }

# Real commits out of this tree: A is a landed commit (what a full install's binary is a build of), T1 and T2
# are the two commits a Lua-only deploy would install. Real ids keep wa_compiled_inputs_digest and the 40-hex
# rules honest; a fixture made of invented hashes would only test its own arithmetic.
A="$(git -C "$ROOT" rev-parse --verify --quiet 'HEAD~2^{commit}' 2>/dev/null)"
T1="$(git -C "$ROOT" rev-parse --verify --quiet 'HEAD~1^{commit}' 2>/dev/null)"
T2="$(git -C "$ROOT" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
if [ -z "$A" ] || [ -z "$T1" ] || [ -z "$T2" ]; then
  say "SKIP: $ROOT has fewer than three commits of history to name a full install, a first Lua-only deploy and a second one"
  exit 0
fi
digest_at() { bash -c 'set -u; . "$1"; wa_compiled_inputs_digest "$2" "$3"' _ "$NODELIB" "$ROOT" "$1"; }
DIGEST_T1="$(digest_at "$T1")"
DIGEST_T2="$(digest_at "$T2")"

# --- fixtures -------------------------------------------------------------------------------------
new_install() { # <name> -> the install directory, with the files record_installed hashes
  local dir="$WORK/install-$1"
  mkdir -p "$dir/scripts" || return 1
  printf '#!/bin/sh\nexit 0\n' > "$dir/scripts/upgrade.sh"
  printf 'stub sentinel\n' > "$dir/wa-sentinel"
  chmod +x "$dir/scripts/upgrade.sh" "$dir/wa-sentinel"
  printf '%s\n' "$dir"
}
stub() { # <install-dir> <commit|""> <tree>
  local dir="$1" commit="$2" tree="$3"
  if [ -n "$commit" ]; then
    cat > "$dir/wa" <<STUB
#!/bin/sh
# A stub node executable for scripts/test-deploy-luafast-record.sh: it answers --build-info (the document
# rust/wa-host/build.rs compiles in) and refuses every other flag, as a real binary does for a flag it does
# not have. Hand-written: scripts/lib/contract-host.lua fakes the Lua HOST, not an executable's command line.
case "\${1:-}" in
  --build-info) printf 'commit=$commit\ntree=$tree\ndirty=false\n' ;;
  *) exit 1 ;;
esac
STUB
  else
    cat > "$dir/wa" <<'STUB'
#!/bin/sh
# A stub node executable that cannot name its own build: every flag exits 1, which is what wa_build_info sees
# from a binary older than --build-info (the probe is bounded and refuses to guess).
exit 1
STUB
  fi
  chmod +x "$dir/wa"
}
record_fixture() { # <install-dir> <commit> <binary_commit|""> <lua_fast_path 0|1>
  local dir="$1" commit="$2" binary="$3" fast="$4"
  {
    printf 'commit=%s\nbranch=main\ndirty=false\nsha256=%s\nsentinel_sha256=stub-sentinel\nupgrade_sha256=%s\ninstall_dir=%s\nservice_install_dir=unverified\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nvia=deploy.sh\nsource_worktree=%s\nbuild_pin=unpinned\nat=2026-11-21T00:00:00Z\nreason=\n' \
      "$commit" "$(sha256sum < "$dir/wa" | awk '{print $1}')" "$(sha256sum < "$dir/scripts/upgrade.sh" | awk '{print $1}')" \
      "$dir" "$ROOT"
    printf 'tree=%s\nbuild_info=yes\n' "$commit"
    printf 'lua_tree=%s\nlua_fast_path=%s\n' "$commit" "$fast"
    [ -z "$binary" ] || printf 'binary_commit=%s\n' "$binary"
  } > "$dir/installed.txt"
}
# The runner is one deploy-shaped process: the real identity step, then the real kept-binary region, then the
# real record step. INSTALL_DIR and COMMIT come from the environment, so a case only says which of them it is.
write_runner() { # <file>
  cat > "$1" <<RUNNER
set -uo pipefail
. '$LIB'
. '$NODELIB'
# deploy.sh sources this one separately (line 556, wa_same_commit): without it every commit comparison
# exits 127 and reads as 'different', which turns a correct record into a refusal.
. '$ROOT/scripts/lib/commit-id.sh'
note() { printf 'deploy: %s\n' "\$*"; }
fail() { printf 'deploy: %s\n' "\$*" >&2; exit 1; }
INSTALL_DIR="\${INSTALL_DIR:?the case must name an install directory}"
COMMIT="\${COMMIT:?the case must name the commit this deploy installs}"
BRANCH=main
RELEASE=''
REASON=''   # set, not merely absent: record_installed reads it, and an unbound variable hides as an empty reason
SOURCE_ROOT='$ROOT'
RECORD_IS_THESE_BYTES=unknown
UPGRADE_HASH="\$(sha256sum < "\$INSTALL_DIR/scripts/upgrade.sh" | awk '{print \$1}')"
HASH="\$(sha256sum < "\$INSTALL_DIR/wa" | awk '{print \$1}')"
SENTINEL_HASH=stub-sentinel
# What is running here, asked by the deploy's own step. The real function, early return included: this is the
# half of the bug that lives in scripts/lib/install-record.sh.
wa_running_identity "\$INSTALL_DIR"
RUNNING_BIN="\$WA_RUNNING_BIN"
RUNNING_COMMIT="\$WA_RUNNING_COMMIT"
RUNNING_DIRTY="\$WA_RUNNING_DIRTY"
RUNNING_SOURCE="\$WA_RUNNING_SOURCE"
RUNNING_WHY="\$WA_RUNNING_WHY"
RECORD_IS_THESE_BYTES="\$WA_RUNNING_RECORD_IS_BYTES"
INSTALLED_COMMIT="\$WA_RUNNING_RECORD_COMMIT"
# The deploy's own region, as it ships.
. '$WORK/kept-binary.sh'
# The block opens with the deploy's default (LUA_FAST=0) and this case is a Lua-only deploy, so the fast path
# is stated AFTER it: setting it before would be overwritten by the real line, and the run would silently be a
# full install's record step with a fast path's fixture.
LUA_FAST=1
printf 'RESOLVED_SOURCE=%s\n' "\$RUNNING_SOURCE"
printf 'RESOLVED_RECORD_COMMIT=%s\n' "\$INSTALLED_COMMIT"
printf 'RESOLVED_KEPT=%s\n' "\$INSTALLED_BINARY_COMMIT"
. '$WORK/record-installed.sh'
record_installed
RUNNER
}
run_case() { # <install-dir> <commit> -> sets OUT and RC
  local dir="$1" commit="$2" runner
  runner="$WORK/run-$(basename "$dir").sh"
  write_runner "$runner"
  OUT="$(env INSTALL_DIR="$dir" COMMIT="$commit" bash "$runner" 2>&1)"
  RC=$?
}
resolved() { printf '%s\n' "$OUT" | sed -n "s/^RESOLVED_$1=//p" | head -1; }

say "checking the Lua fast path's record (A=$(printf '%s' "$A" | cut -c1-12) T1=$(printf '%s' "$T1" | cut -c1-12) T2=$(printf '%s' "$T2" | cut -c1-12))"

# --- 1. a full install, then a Lua-only deploy (the 21/11 failure) --------------------------------
INST="$(new_install full-then-lua)"
stub "$INST" "$A" "$A"
record_fixture "$INST" "$A" "" 0     # what a FULL install leaves: commit= is the binary's own build, no binary_commit=
run_case "$INST" "$T1"
same  "1 the Lua-only deploy after a full install finishes (exit)" "$RC" "0"
hides "1 it does not refuse the binary it just kept" "$OUT" "build_commit_mismatch"
same  "1 the kept binary's commit is the binary's own answer" "$(resolved KEPT)" "$A"
same  "1 installed.txt commit= is the Lua tree it installed" "$(field commit "$INST/installed.txt")" "$T1"
same  "1 installed.txt binary_commit= is the kept binary's build" "$(field binary_commit "$INST/installed.txt")" "$A"
same  "1 lua_tree= names that same tree" "$(field lua_tree "$INST/installed.txt")" "$T1"
same  "1 lua_fast_path= says which kind of record this is" "$(field lua_fast_path "$INST/installed.txt")" "1"
same  "1 the two commits are really different (a fast path kept the binary)" \
      "$([ -n "$(field commit "$INST/installed.txt")" ] && [ "$(field commit "$INST/installed.txt")" != "$(field binary_commit "$INST/installed.txt")" ] && echo differ)" "differ"
same  "1 binary_inputs= is the digest of commit= (the tree)" "$(field binary_inputs "$INST/installed.txt")" "$DIGEST_T1"
same  "1 the record says the binary reported its own build" "$(field build_info "$INST/installed.txt")" "yes"

# --- 2. a second Lua-only deploy, over the record case 1 wrote ------------------------------------
INST2="$(new_install lua-then-lua)"
stub "$INST2" "$A" "$A"
record_fixture "$INST2" "$T1" "$A" 1
run_case "$INST2" "$T2"
same  "2 the second Lua-only deploy finishes (exit)" "$RC" "0"
hides "2 it does not refuse the binary it kept" "$OUT" "build_commit_mismatch"
same  "2 commit= moves forward to the new tree" "$(field commit "$INST2/installed.txt")" "$T2"
same  "2 binary_commit= still names the same kept binary" "$(field binary_commit "$INST2/installed.txt")" "$A"
same  "2 lua_tree= moves with commit=" "$(field lua_tree "$INST2/installed.txt")" "$T2"
same  "2 binary_inputs= is the digest of the new tree" "$(field binary_inputs "$INST2/installed.txt")" "$DIGEST_T2"

# --- 3. the kept binary stops answering, and the record is a fast-path one ------------------------
# A fast-path record keeps the binary's sha256=, so it is still the record OF these bytes: what it says about
# the binary is binary_commit=. Its commit= is the LUA TREE and must never be read as the binary's commit.
INST3="$(new_install silent-fast)"
stub "$INST3" "" ""
record_fixture "$INST3" "$T1" "$A" 1
run_case "$INST3" "$T2"
same  "3 a silent binary leaves the record as the witness" "$(resolved SOURCE)" "record"
same  "3 the kept binary's commit is binary_commit= (not the tree's commit=)" "$(resolved KEPT)" "$A"
same  "3 the record finishes (exit)" "$RC" "0"
same  "3 commit= is the new tree" "$(field commit "$INST3/installed.txt")" "$T2"
same  "3 binary_commit= is still the kept binary" "$(field binary_commit "$INST3/installed.txt")" "$A"

# --- 4. nothing names the bytes: `unknown` with its reason, never an empty line --------------------
INST4="$(new_install silent-nobody)"
stub "$INST4" "" ""
record_fixture "$INST4" "$T1" "" 1    # a fast-path record that carries no binary_commit=
run_case "$INST4" "$T2"
same  "4 the record still lands (exit)" "$RC" "0"
hides "4 it does not refuse over an unnamed binary" "$OUT" "build_commit_mismatch"
same  "4 commit= is the tree it installed" "$(field commit "$INST4/installed.txt")" "$T2"
same  "4 installed.txt carries a binary_commit= line at all" "$(grep -c '^binary_commit=' "$INST4/installed.txt")" "1"
same  "4 ...with a value, never the empty line this used to write" \
      "$([ -n "$(field binary_commit "$INST4/installed.txt")" ] && echo valued || echo empty)" "valued"
same  "4 ...and that value is unknown" "$(field binary_commit "$INST4/installed.txt")" "unknown"
same  "4 the tree's commit is never written as the binary's" \
      "$([ "$(field binary_commit "$INST4/installed.txt")" = "$T1" ] && echo tree-written || echo not)" "not"
shows "4 binary_commit_why= names what could not be established" "$(field binary_commit_why "$INST4/installed.txt")" "running_source=record"

# --- 5. a full-install record and a silent binary: the record's commit= IS the bytes ---------------
INST5="$(new_install silent-full)"
stub "$INST5" "" ""
record_fixture "$INST5" "$A" "" 0
run_case "$INST5" "$T1"
same  "5 the record finishes (exit)" "$RC" "0"
same  "5 the kept binary's commit comes from the record's commit=" "$(resolved KEPT)" "$A"
same  "5 binary_commit= is that commit" "$(field binary_commit "$INST5/installed.txt")" "$A"
same  "5 commit= is the tree" "$(field commit "$INST5/installed.txt")" "$T1"

# --- 6. a record that disagrees with a binary that can answer: the binary wins, and it is recorded ---
INST6="$(new_install hand-placed)"
stub "$INST6" "$T2" "$T2"             # the bytes here report T2 ...
record_fixture "$INST6" "$T1" "$A" 1    # ... while the record claims binary_commit=A
run_case "$INST6" "$T2"
same  "6 the bytes are the witness" "$(resolved KEPT)" "$T2"
shows "6 the disagreement is recorded, not refused" "$OUT" "the binary is the witness"
hides "6 nothing was refused" "$OUT" "build_commit_mismatch"
same  "6 the record is written from the binary's answer" "$(field binary_commit "$INST6/installed.txt")" "$T2"

printf '\ntest-deploy-luafast-record: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0

