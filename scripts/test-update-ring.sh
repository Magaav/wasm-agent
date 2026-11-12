#!/usr/bin/env bash
# Ring 1 of the torus (docs/TORUS.md §5), the part that can be proved without a deploy: the deploy's
# binary decision, the phases its record carries, and the structure that keeps them true.
#
#   bash scripts/test-update-ring.sh
#
# Hermetic: a fixture git repository, a private install directory, no network, no cargo, no sentinel, no
# node. Nothing here runs a deploy; each claim is either a function called with fixtures or a fact read
# out of the script that ships.
#
# Why these claims:
#
#   1. `wa_node_binary_reuse` (scripts/lib/node-binaries.sh) is the ONE decision "does this commit need a
#      new binary". It answers content-addressed first - the record's `binary_inputs=` digest against this
#      commit's compiled-inputs digest - and falls back to classifying changed paths only for an install
#      that records no digest. A Lua-only change must say `unchanged` by BOTH routes; a Rust change must
#      say `needed` by both. That is what makes a Lua-only release skip the binary instead of fetching a
#      build of it.
#   2. `wa_phase` used to be a number printed at the moment it happened, so the only record of where a
#      deploy's minutes went was the stdout of whoever watched it. It now also keeps the same measurement
#      in WA_PHASE_TRACE, and `write_result` puts it in deploy-result.json: every deploy record says what
#      it did AND where the time went, read from the record rather than from someone's scrollback.
#   3. The structure: on the reuse path the deploy must call the decision and NOT the resolver/downloader,
#      or "the staged update does no download and no proof on the critical path" is a comment.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR" || exit 1
. scripts/lib/node-binaries.sh

# extract <file> <function>: the function's own bytes, counted by braces rather than by "a line that is
# exactly }" - deploy.sh closes an inner block at column 0 inside record_installed, and an extraction that
# stopped there would run the rest of the deploy script in this test's own shell (measured here: it did).
extract() {
  awk -v fname="$2" '
    index($0, fname "() {") == 1 { on = 1 }
    on {
      line = $0; opens = gsub(/\{/, "{", line)
      line = $0; closes = gsub(/\}/, "}", line)
      depth += opens - closes
      print
      if (depth <= 0) exit
    }
  ' "$1"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-update-ring-XXXXXX")" || { echo "test-update-ring: no scratch directory" >&2; exit 1; }
printf 'test-update-ring\n' > "$WORK/MARKER"
cleanup() { [ -f "$WORK/MARKER" ] && rm -rf "$WORK"; }
trap cleanup EXIT

checks=0
fail() { echo "test-update-ring: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); }
# Quoted `case` patterns, not `printf | grep -q`: under `set -o pipefail` grep exits at the first match,
# printf then dies of SIGPIPE, and the pipeline reports 141 - so `grep -q` answers "not found" for exactly
# the large haystacks this test reads (measured here on deploy.sh's 135 KB). `case` is a literal substring
# match in the shell, with no process to be killed.
contains() { # <text> <needle> <what>
  case "$1" in
    *"$2"*) ok ;;
    *) fail "$3: '$2' not in the ${#1} bytes it read" ;;
  esac
}
lacks() { # <text> <needle> <what>
  case "$1" in
    *"$2"*) fail "$3: '$2' is present in the ${#1} bytes it read" ;;
    *) ok ;;
  esac
}

# ---- a fixture repository whose two kinds of change are known --------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/lua/core" "$REPO/rust/src"
git init -q "$REPO"
git -C "$REPO" config user.email ring@example.invalid
git -C "$REPO" config user.name "ring test"
git -C "$REPO" config commit.gpgsign false
printf 'module\n' > "$REPO/lua/core/agent.lua"
printf 'fn main() {}\n' > "$REPO/rust/src/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'module -- a Lua-only change\n' > "$REPO/lua/core/agent.lua"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "lua only"
LUA_ONLY="$(git -C "$REPO" rev-parse HEAD)"
printf 'fn main() { println!("compiled"); }\n' > "$REPO/rust/src/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a compiled change"
RUST_CHANGE="$(git -C "$REPO" rev-parse HEAD)"

BASE_DIGEST="$(wa_compiled_inputs_digest "$REPO" "$BASE")"
LUA_DIGEST="$(wa_compiled_inputs_digest "$REPO" "$LUA_ONLY")"
RUST_DIGEST="$(wa_compiled_inputs_digest "$REPO" "$RUST_CHANGE")"
case "$BASE_DIGEST$LUA_DIGEST$RUST_DIGEST" in *[!0-9a-f]*|"")
  fail "the fixture's compiled-inputs digests are not sha256 values: $BASE_DIGEST $LUA_DIGEST $RUST_DIGEST" ;; esac
[ "$BASE_DIGEST" = "$LUA_DIGEST" ] || fail "a Lua-only change must not change the compiled-inputs digest"
[ "$BASE_DIGEST" != "$RUST_DIGEST" ] || fail "a Rust change must change the compiled-inputs digest"
ok

record() { # <install> <commit> [digest]
  mkdir -p "$1"
  { printf 'commit=%s\n' "$2"
    [ -z "${3:-}" ] || printf 'binary_inputs=%s\n' "$3"
  } > "$1/installed.txt"
}

# ---- 1. the decision ------------------------------------------------------------------------
inst="$WORK/inst-digest"
record "$inst" "$BASE" "$BASE_DIGEST"
out="$(wa_node_binary_reuse "$REPO" "$LUA_ONLY" "$inst")"; rc=$?
[ "$rc" = 0 ] || fail "a Lua-only commit on a recorded digest must reuse the binary (rc=$rc): $out"
contains "$out" "binary: unchanged (compiled_inputs=$LUA_DIGEST" "the digest route says unchanged, and names the digest"

out="$(wa_node_binary_reuse "$REPO" "$RUST_CHANGE" "$inst")"; rc=$?
[ "$rc" = 1 ] || fail "a compiled change must need a binary (rc=$rc): $out"
contains "$out" "binary: needed" "the digest route says needed"
contains "$out" "the installed binary was built from $BASE_DIGEST" "and names what the record says"

# The record is the only source: a digest that is not 64 hex is not a digest.
inst_bad="$WORK/inst-short-digest"
mkdir -p "$inst_bad"; printf 'commit=%s\nbinary_inputs=abc\n' "$BASE" > "$inst_bad/installed.txt"
out="$(wa_node_binary_reuse "$REPO" "$LUA_ONLY" "$inst_bad")"; rc=$?
[ "$rc" = 0 ] || fail "a malformed digest must fall back to the path rule, not refuse (rc=$rc): $out"
contains "$out" "paths were classified" "a record without a usable digest says which rule answered"

# The fallback: no digest recorded.
inst_none="$WORK/inst-no-digest"
record "$inst_none" "$BASE"
out="$(wa_node_binary_reuse "$REPO" "$LUA_ONLY" "$inst_none")"; rc=$?
[ "$rc" = 0 ] || fail "no digest, Lua-only: the path rule must reuse (rc=$rc): $out"
contains "$out" "no compiled input changed since the installed commit" "the path rule names what it classified"

out="$(wa_node_binary_reuse "$REPO" "$RUST_CHANGE" "$inst_none")"; rc=$?
[ "$rc" = 1 ] || fail "no digest, Rust change: the path rule must need a binary (rc=$rc): $out"
contains "$out" "1 compiled input(s) changed" "the path rule counts the compiled change"

# Nothing to compare with is a reason, never "unchanged".
out="$(wa_node_binary_reuse "$REPO" "$LUA_ONLY" "$WORK/inst-empty")"; rc=$?
[ "$rc" = 1 ] || fail "an install with no record must need a binary (rc=$rc): $out"
contains "$out" "records no commit and no compiled-inputs digest" "an empty record is named"

# A divergent installed commit cannot have its paths classified.
git -C "$REPO" checkout -q -b divergent "$BASE"
printf 'module -- divergent\n' > "$REPO/lua/core/agent.lua"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "divergent"
DIVERGENT="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -
inst_div="$WORK/inst-divergent"
record "$inst_div" "$DIVERGENT"
out="$(wa_node_binary_reuse "$REPO" "$LUA_ONLY" "$inst_div")"; rc=$?
[ "$rc" = 1 ] || fail "an installed commit that is not an ancestor must need a binary (rc=$rc): $out"
contains "$out" "is not an ancestor of" "the refusal names why the paths cannot be classified"

# ---- 2. the phases the record carries -------------------------------------------------------
PHASE_RUN="$WORK/phase-run.sh"
cat > "$PHASE_RUN" <<'SH'
set -uo pipefail
. "$ROOT_DIR/scripts/lib/build-status.sh"
wa_phase preflight
wa_phase fetching
wa_phase ""
printf 'TRACE=%s\n' "$(wa_phases_json)"
SH
out="$(ROOT_DIR="$ROOT_DIR" bash "$PHASE_RUN" 2>&1)"
contains "$out" "deploy: [phase] preflight" "a phase still prints its measured line"
phases="${out##*TRACE=}"
case "$phases" in
  '[{"name":"preflight","ms":'*',{"name":"fetching","ms":'*'}]') ok ;;
  *) fail "the phases record is not the two phases in order: $phases" ;;
esac
printf '%s' "$phases" | grep -qE '"ms":[0-9]+' || fail "a phase carries no numeric measurement: $phases"
ok

# A label that is not a bare word is dropped rather than escaped into a JSON record, and an empty trace is
# an empty array (never an absent field).
# The trace is set AFTER sourcing: build-status.sh starts every process with an empty trace, which is the
# behaviour a deploy depends on (a fresh script measures its own phases, never an earlier process's).
out="$(ROOT_DIR="$ROOT_DIR" bash -c '. "$ROOT_DIR/scripts/lib/build-status.sh"; WA_PHASE_TRACE="weird name 5;ok 7;"; wa_phases_json')"
[ "$out" = '[{"name":"ok","ms":7}]' ] || fail "a bad phase label was not dropped: $out"
ok
out="$(ROOT_DIR="$ROOT_DIR" bash -c '. "$ROOT_DIR/scripts/lib/build-status.sh"; wa_phases_json')"
[ "$out" = '[]' ] || fail "an empty trace must render []: $out"
ok

# ---- 3. deploy-result.json carries them (the real write_result, read out of deploy.sh) --------
DEPLOY="$ROOT_DIR/scripts/deploy.sh"
[ -f "$DEPLOY" ] || fail "no $DEPLOY"
extract "$DEPLOY" write_result > "$WORK/write_result.sh"
[ -s "$WORK/write_result.sh" ] || fail "the write_result function could not be read out of deploy.sh"
run_result() { # <install> [trace]
  # Plain assignments, not `VAR=... . lib`: that form scopes the variables to the source command alone and
  # the sourced function then sees them unset (measured here: `REQUEST_ID: unbound variable`).
  ( INSTALL_DIR="$1"
    SENTINEL_CONFIG="$1"
    COMMIT=0123456789abcdef BRANCH=main HASH=aa SENTINEL_HASH=bb REASON="ring test" EXPECTED_SHA="" REQUEST_ID="ring-1"
    . "$ROOT_DIR/scripts/lib/build-status.sh" >/dev/null 2>&1
    WA_PHASE_TRACE="${2:-}"
    . "$WORK/write_result.sh"
    write_result true "phase record" )
}
inst_result="$WORK/inst-result"; mkdir -p "$inst_result"
run_result "$inst_result" "preflight 1200;compiling 32800;installing 96000;"
RESULT="$inst_result/deploy-result.json"
[ -f "$RESULT" ] || fail "write_result wrote no deploy-result.json"
node -e '
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (value.ok !== true) throw new Error("ok is not true");
const want = [["preflight",1200],["compiling",32800],["installing",96000]];
if (!Array.isArray(value.phases)) throw new Error("phases is not an array");
if (value.phases.length !== want.length) throw new Error(`expected ${want.length} phases, got ${value.phases.length}`);
want.forEach(([name,ms], index) => {
  if (value.phases[index].name !== name) throw new Error(`phase ${index} is ${value.phases[index].name}, wanted ${name}`);
  if (value.phases[index].ms !== ms) throw new Error(`phase ${index} ms is ${value.phases[index].ms}, wanted ${ms}`);
});
if (value.request_id !== "ring-1") throw new Error("the record lost its request id");
' "$RESULT" || fail "deploy-result.json does not carry the phases the deploy measured"
ok
# The protocol copy beside the sentinel's own record is the same bytes.
cmp -s "$RESULT" "$inst_result/sentinel/deploy-protocol/ring-1/result.json" \
  || fail "the sentinel's deploy-protocol copy is not the same record"
ok
# A refusal (no phases measured yet) still writes a record, with an empty array - never a missing field.
inst_empty="$WORK/inst-result-empty"; mkdir -p "$inst_empty"
run_result "$inst_empty" ""
node -e '
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!Array.isArray(value.phases) || value.phases.length !== 0) throw new Error("phases should be [] before any phase ran");
if (!("phases" in value)) throw new Error("the field is missing");
' "$inst_empty/deploy-result.json" || fail "a record written before any phase does not carry an empty phases array"
ok

# ---- 4. the structure: the reuse path does no download, and no proof of a binary --------------
# The block that decides to keep the installed binary, read by its own markers.
# index(), not a regex: `[` inside the pattern is a bracket expression in awk, and a pattern that silently
# matches nothing extracts the whole script - which then "proves" whatever the rest of deploy.sh says.
awk '
  $0 == "LUA_FAST=0" { on = 1 }
  on && index($0, "if [ \"$LUA_FAST\" = 1 ]; then") == 1 { exit }
  on { print }
' "$DEPLOY" > "$WORK/reuse-block.sh"
[ -s "$WORK/reuse-block.sh" ] || fail "the reuse block could not be read out of deploy.sh"
block="$(cat "$WORK/reuse-block.sh")"
contains "$block" "wa_node_binary_reuse" "the reuse decision is the lib's function, not a copy"
lacks "$block" "wa_node_binaries_prepare" "the reuse path never calls the resolver"
lacks "$block" "wa_node_binary_download" "the reuse path never downloads a binary"
lacks "$block" "wa_node_verify_dir" "the reuse path never re-verifies release bytes"
# ...and the resolver is still reached on the path that DOES need a binary: the test cannot be passed by
# deleting the download step altogether.
full_block="$(cat "$DEPLOY")"
contains "$full_block" 'wa_node_binaries_prepare "$ROOT"' "the binary path still resolves a release"
contains "$full_block" "wa_phase proving" "the binary path still proves its candidate"

# The digest the next deploy reads is written by the record step.
extract "$DEPLOY" record_installed > "$WORK/record.sh"
contains "$(cat "$WORK/record.sh")" "binary_inputs=" "the install record names the compiled-inputs digest"

# The record step's own digest is the commit the record names: a fixture proves the line lands with the
# digest of that commit, and not with the empty string a failed substitution would leave behind.
inst_record="$WORK/inst-record"; mkdir -p "$inst_record"
out="$(
  cd "$REPO" || exit 1
  ROOT="$REPO" SOURCE_ROOT="$REPO" INSTALL_DIR="$inst_record" COMMIT="$LUA_ONLY" BINARY_PROVENANCE="" \
    BRANCH=main DIRTY=0 HASH=aa SENTINEL_HASH=bb UPGRADE_HASH=cc WA_SERVICE_DIR=unverified BUILD_PIN=unpinned \
    REASON="record test" RELEASE="" LUA_FAST=1 COMPONENT_NAMES="" \
    WA_COMPONENTS_DIR="$inst_record/components" \
    bash -c '
      . "'"$ROOT_DIR"'/scripts/lib/node-binaries.sh"
      . "'"$WORK"'/record.sh"
      fail() { echo "FAILED: $*" >&2; exit 1; }
      note() { :; }
      wa_components_record_names() { :; }
      record_installed
    ' 2>&1
)"
[ -f "$inst_record/installed.txt" ] || fail "the record step wrote no installed.txt: $out"
recorded="$(sed -n 's/^binary_inputs=//p' "$inst_record/installed.txt" | head -1)"
[ "$recorded" = "$LUA_DIGEST" ] || fail "installed.txt binary_inputs=$recorded, wanted $LUA_DIGEST"
ok
# ...and the record it wrote is one the next deploy can decide from: the loop closes.
out="$(wa_node_binary_reuse "$REPO" "$LUA_ONLY" "$inst_record")"; rc=$?
[ "$rc" = 0 ] || fail "the record this deploy wrote is not one the next deploy can reuse (rc=$rc): $out"
contains "$out" "binary: unchanged (compiled_inputs=$LUA_DIGEST" "a written record answers the next deploy by digest"
out="$(wa_node_binary_reuse "$REPO" "$RUST_CHANGE" "$inst_record")"; rc=$?
[ "$rc" = 1 ] || fail "the same record must still need a binary for a compiled change (rc=$rc): $out"

echo "update ring ok: $checks checks"
