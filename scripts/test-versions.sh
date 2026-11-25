#!/usr/bin/env bash
# THE VERSION FOLDERS (slice (b), Fable's nine requirements - docs/UPDATE-DESIGN.md section 2.0).
#
# What this row is about, in one sentence: an install must never edit the install a running process resolves,
# so a version is a folder made once, "current" is a pointer, and every step that could be cut is either one
# rename or finished by the node at its next start.
#
# It runs on its own scratch root and refuses to run against the operator's home or the real ~/.wasm-agent
# (measured 11/11: a test took its scratch from WASM_AGENT_HOME and deleted the operator's whole home).
#
# THE ROWS (each named in its failure message, so a red says which requirement broke):
#   R1  one variable names the versions dir, beside ui, in the share root (never the PATH dir, never the data dir)
#   R2  a version is made once: assembling an existing id is refused and the folder is not touched
#   R4  installed.txt is a LINK to current's own record and follows a pointer move with no second write
#   R6  an unchanged member is the SAME inode (hard link) and the new version's real disk is far under a copy
#   R7  retention keeps 3, never current, the one before it, a live process's version, or a pinned one
#   R9  no room -> version_no_room by name BEFORE anything is staged
#   R3/R5 (migration with a kill at every boundary) and R8 (the sentinel) are the next commits: they need the
#   binary and a unit, and this file says so rather than pretending.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/versions.sh

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-versions: $*" >&2; exit 1; }

# The scratch root is NEVER inside the data dir: this node TMPDIR is WASM_AGENT_HOME/tmp, and the guard
# below caught exactly that on the first run (a row that took its scratch from the node own data dir).
scratch_parent="${TMPDIR:-/tmp}"
case "$scratch_parent" in */.wasm-agent|*/.wasm-agent/*) scratch_parent=/tmp ;; esac
W="$(mktemp -d "$scratch_parent/wa-versions-XXXXXX")" || { echo "FAIL test-versions: no scratch dir" >&2; exit 2; }
case "$W" in */.wasm-agent|*/.wasm-agent/*) echo "FAIL test-versions: scratch is the real data dir" >&2; exit 2;; esac
LIVE_PID=""
cleanup() { [ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
HOME="$W/home"; export HOME
mkdir -p "$HOME/.local/share"

# --- R1: ONE VARIABLE, IN THE SHARE ROOT BESIDE ui -----------------------------------------------------------
( unset WA_SHARE_ROOT XDG_DATA_HOME; [ "$(wa_share_root)" = "$HOME/.local/share/wasm-agent" ] ) || fail "R1: the default share root is the XDG data dir's wasm-agent"
ok
( WA_SHARE_ROOT="$W/share" XDG_DATA_HOME="$W/xdg"; [ "$(wa_versions_dir)" = "$W/share/versions" ] ) || fail "R1: WA_SHARE_ROOT names the versions dir, and it wins over XDG_DATA_HOME"
ok
case "$(wa_versions_dir)" in */.wasm-agent/*|*/.wasm-agent) fail "R1: the versions dir is in the data dir (state)";; esac
ok
WA_SHARE_ROOT="$W/share"; export WA_SHARE_ROOT
[ "$(wa_version_id abcdef0123456789)" = "abcdef012345" ] || fail "R2: the id is the commit's first 12 hex"
ok
wa_version_id zzz >/dev/null 2>&1 && fail "R2: a non-hex id is refused, not truncated"
ok

# --- the fixture: what an install ships ----------------------------------------------------------------------
stage1="$W/stage1"
mkdir -p "$stage1/lua-core/lua/core" "$stage1/scripts" "$stage1/ui"
printf 'program-v1' > "$stage1/wa"
head -c 4194304 /dev/urandom > "$stage1/lua-core/lua/core/big.lua"
printf 'init-v1' > "$stage1/lua-core/lua/core/init.lua"
printf 'deploy-v1' > "$stage1/scripts/deploy.sh"
printf 'ui-v1' > "$stage1/ui/index.html"
printf 'commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbuild_pin=\n' > "$stage1/installed.txt"

WA_VERSION_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
WA_VERSION_BINARY_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  wa_version_assemble "$stage1" aaaaaaaaaaaa "" > "$W/a1.log" 2>&1 || { cat "$W/a1.log" >&2; fail "R2: assembling the first version"; }
ok
v1="$(wa_version_dir aaaaaaaaaaaa)"
[ "$(wa_version_value "$v1" id)" = "aaaaaaaaaaaa" ] || fail "R1: version.txt names the id"
[ "$(wa_version_value "$v1" binary_commit)" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] || fail "R1: version.txt names binary_commit (a covering release runs another commit's binary)"
[ -n "$(wa_version_value "$v1" assembled_utc)" ] || fail "R1: version.txt is dated"
ok
if ( : > "$v1/written-by-hand" ) 2>/dev/null; then fail "R2: a version folder is read-only once sealed"; fi
ok

# --- R2: an id is made once ----------------------------------------------------------------------------------
wa_version_assemble "$stage1" aaaaaaaaaaaa "" >/dev/null 2>"$W/again.err" && fail "R2: assembling an existing id must refuse"
grep -q 'version_exists' "$W/again.err" || fail "R2: the refusal names version_exists"
[ "$(wc -c < "$v1/lua-core/lua/core/big.lua")" = "4194304" ] || fail "R2: the existing version was not touched"
ok

# --- R6: unchanged members are hard links --------------------------------------------------------------------
stage2="$W/stage2"
cp -a "$stage1" "$stage2"
printf 'program-v2' > "$stage2/wa"
printf 'deploy-v2' > "$stage2/scripts/deploy.sh"
printf 'commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nbuild_pin=\n' > "$stage2/installed.txt"
WA_VERSION_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb wa_version_assemble "$stage2" bbbbbbbbbbbb "$v1" > "$W/a2.log" 2>&1 \
  || { cat "$W/a2.log" >&2; fail "R6: assembling the second version over the first"; }
v2="$(wa_version_dir bbbbbbbbbbbb)"
[ "$(stat -c %i "$v1/lua-core/lua/core/big.lua")" = "$(stat -c %i "$v2/lua-core/lua/core/big.lua")" ] || fail "R6: an unchanged member is the SAME inode (hard link), not a copy"
ok
[ "$(stat -c %i "$v1/scripts/deploy.sh")" != "$(stat -c %i "$v2/scripts/deploy.sh")" ] || fail "R6: a changed member is a new file (never a link into the previous version)"
ok
# The honest disk number is the PAIR's: du counts an inode once per invocation, so `du v2` alone reports the
# 4 MiB member even when it is a link. Two copies would be ~8 MiB; a linked pair is ~4 MiB plus the small
# changed members.
real_both="$(du -s -c -B1 "$v1" "$v2" 2>/dev/null | tail -1 | awk '{print $1}')"
[ "${real_both:-0}" -lt 5242880 ] || fail "R6: the pair's REAL disk is under 5 MiB (two 4 MiB copies would show); measured ${real_both:-?}"
ok
# R9's two numbers are taken HERE, while both versions exist: retention prunes the first one further down, and a
# need measured against a pruned version counts every member (the row caught that ordering on its second run).
need_full="$(wa_version_need_bytes "$stage1" "")"
need_delta="$(wa_version_need_bytes "$stage2" "$v1")"

# --- R4: one atomic thing names current, and the record follows the pointer ----------------------------------
wa_version_point bbbbbbbbbbbb >/dev/null || fail "R4: pointing current at a version"
[ "$(wa_version_current)" = "bbbbbbbbbbbb" ] || fail "R4: current names the version"
ok
install="$W/install"; mkdir -p "$install"
printf 'commit=old\n' > "$install/installed.txt"
wa_version_link_record "$install" >/dev/null || fail "R4: installed.txt becomes a link to current's record"
[ -L "$install/installed.txt" ] || fail "R4: installed.txt IS a link, not a second file"
grep -q '^commit=bbbbbbbbbbbb' "$install/installed.txt" || fail "R4: the link reads current's record"
ok
wa_version_point aaaaaaaaaaaa >/dev/null || fail "R4: pointing back"
grep -q '^commit=aaaaaaaaaaaa' "$install/installed.txt" || fail "R4: after the pointer moves the SAME path reads the new version's record (no second write)"
ok

# --- legacy paths keep working THROUGH the pointer (requirement 3) -------------------------------------------
install2="$W/install2"; mkdir -p "$install2/lua-core/lua" "$install2/scripts"
printf 'old-program' > "$install2/wa"
printf 'old-init' > "$install2/lua-core/lua/init.lua"
printf 'old-deploy' > "$install2/scripts/deploy.sh"
wa_version_link_legacy "$install2" > "$W/legacy.log" 2>&1 || { cat "$W/legacy.log" >&2; fail "R1/3: legacy paths become links through the pointer"; }
[ -L "$install2/wa" ] && [ -L "$install2/lua-core" ] && [ -L "$install2/scripts" ] || fail "R1/3: wa, lua-core and scripts are links"
ok
[ "$(readlink -f "$install2/lua-core")" = "$(readlink -f "$WA_SHARE_ROOT/current/lua-core")" ] || fail "R1/3: the link resolves through current"
ls "$install2"/lua-core.stale.* >/dev/null 2>&1 || fail "R1/5: the real directory was renamed ASIDE (a cut leaves evidence, nothing is deleted)"
ok
[ "$(cat "$install2/lua-core.stale."*/lua/init.lua)" = "old-init" ] || fail "R1/5: the aside copy is the old tree, untouched"
ok

# --- R7: retention -------------------------------------------------------------------------------------------
# Five more versions, one of them the version a LIVE process runs from, one pinned.
sleepbin="$(command -v sleep)"; [ -n "$sleepbin" ] || fail "R7: no sleep binary to keep a version live"
for id in cccccccccccc dddddddddddd eeeeeeeeeeee; do
  mkdir -p "$W/stage-$id"
  cp -a "$stage1/." "$W/stage-$id/"
  printf 'commit=%s\n' "$id$id$id$id" > "$W/stage-$id/installed.txt"
done
mkdir -p "$W/stage-cccccccccccc/live" && cp "$sleepbin" "$W/stage-cccccccccccc/live/sleep" || fail "R7: fixture for a live process"
WA_VERSION_COMMIT=cccccccccccccccccccccccccccccccccccccccc wa_version_assemble "$W/stage-cccccccccccc" cccccccccccc "" >/dev/null 2>&1 || fail "R7: assembling the live version"
"$WA_SHARE_ROOT/versions/cccccccccccc/live/sleep" 30 &
LIVE_PID=$!
sleep 0.2
[ -n "$(wa_version_live_ids)" ] || fail "R7: a process running from a version folder is SEEN as live (its /proc/<pid>/exe)"
grep -qx cccccccccccc <<<"$(wa_version_live_ids)" || fail "R7: the live version is named"
ok
WA_VERSION_COMMIT=dddddddddddddddddddddddddddddddddddddddd wa_version_assemble "$W/stage-dddddddddddd" dddddddddddd "" >/dev/null 2>&1 || fail "R7: assembling the pinned version"
printf 'dddddddddddd\n' > "$WA_SHARE_ROOT/versions/.pinned"
WA_VERSION_COMMIT=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee wa_version_assemble "$W/stage-eeeeeeeeeeee" eeeeeeeeeeee "" >/dev/null 2>&1 || fail "R7: assembling the newest version"
wa_version_point eeeeeeeeeeee >/dev/null || fail "R7: pointing current at the newest"
wa_version_prune 1 > "$W/prune.log" 2>&1 || { cat "$W/prune.log" >&2; fail "R7: prune ran"; }
[ -d "$WA_SHARE_ROOT/versions/eeeeeeeeeeee" ] || fail "R7: current is never pruned"
[ -d "$WA_SHARE_ROOT/versions/cccccccccccc" ] || fail "R7: a LIVE version is never pruned"
[ -d "$WA_SHARE_ROOT/versions/dddddddddddd" ] || fail "R7: a PINNED version is never pruned"
ok
[ ! -d "$WA_SHARE_ROOT/versions/aaaaaaaaaaaa" ] || fail "R7: an old, unpinned, unreferenced version IS pruned"
ok
kill "$LIVE_PID" 2>/dev/null; LIVE_PID=""
grep -q 'version_pruned' "$W/prune.log" || fail "R7: the prune says what it removed"
ok

# --- the legacy copies are not the versions' business --------------------------------------------------------
printf 'wa.prev-kept' > "$W/install/wa.prev.20261101T000000Z"
wa_version_prune 1 >/dev/null 2>&1 || true
[ -f "$W/install/wa.prev.20261101T000000Z" ] || fail "R7: the legacy wa.prev copies are NOT touched by version retention (wa clean lists them)"
ok

# --- R9: the disk is asked BEFORE anything is staged ---------------------------------------------------------
free_kb="$(df -P -k "$WA_SHARE_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
case "$free_kb" in ''|*[!0-9]*) fail "R9: df did not answer";; esac
free_bytes=$((free_kb * 1024))
wa_version_refuse_no_room 1 "$free_bytes" 2>"$W/room.err" && fail "R9: no room must refuse"
grep -q '^version_no_room free=' "$W/room.err" || fail "R9: the refusal is named and carries free/need/margin"
ok
[ -z "$(find "$WA_SHARE_ROOT/versions" -maxdepth 1 -name '.staging-*' 2>/dev/null)" ] || fail "R9: a refused install leaves NO staging dir"
ok
WA_VERSION_MARGIN_BYTES=$((free_bytes + 1)) wa_version_refuse_no_room 0 2>/dev/null && fail "R9: a margin larger than the free space refuses even a zero-byte version"
ok
[ "${need_full:-0}" -gt 4000000 ] || fail "R9: the need is counted in bytes over the members (${need_full:-?})"
ok
[ "${need_delta:-999999}" -lt 1000 ] || fail "R9: the need for a scripts-only version counts only the changed members (${need_delta:-?})"
ok

# --- R5: a cut is finished at the NEXT START, through the real binary and init.lua ---------------------------
# This is the half requirement 5 asks for: not a script (it may be the missing thing), but wa itself. The install
# is a scratch directory named by WA_INSTALL_DIR, the pointer a scratch share root, and the binary is this suite's
# own - so the row runs the product's real start path and nothing of the operator's.
if [ -z "${WA_BIN:-}" ]; then
  echo "  R5 SKIPPED: WA_BIN is not set (the suite sets it; a bare run cannot prove the start path)"
else
  cut="$W/cut"
  mkdir -p "$cut/share/versions/aaaaaaaaaaaa/lua-core" "$cut/share/versions/aaaaaaaaaaaa/scripts" "$cut/install" "$W/home2"
  printf 'id=aaaaaaaaaaaa\ncommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ninstall_dir=%s\n' "$cut/install" > "$cut/share/versions/aaaaaaaaaaaa/version.txt"
  printf 'init' > "$cut/share/versions/aaaaaaaaaaaa/lua-core/init.lua"
  printf 'deploy' > "$cut/share/versions/aaaaaaaaaaaa/scripts/deploy.sh"
  ln -sfn versions/aaaaaaaaaaaa "$cut/share/current"
  # THE PROGRAM MUST BE THAT INSTALL'S OWN (fix 1): a `wa` run from anywhere else now refuses to repair, on purpose,
  # so the row puts the suite's binary into the install it is about and runs THAT.
  cp "$WA_BIN" "$cut/install/wa" || fail "R5: cannot place the program in the scratch install"
  # The cut: the legacy path the pointer names is ABSENT (that is what the two-rename order leaves behind).
  if WA_SHARE_ROOT="$cut/share" WA_INSTALL_DIR="$cut/install" WASM_AGENT_HOME="$W/home2" \
     WASM_AGENT_LUA_ROOT="$(pwd)" timeout 60 "$cut/install/wa" --db "$W/db-cut.sqlite" > "$W/cut.log" 2>&1; then
    ok
  else
    sed -n '1,5p' "$W/cut.log" >&2; fail "R5: wa did not start after the cut"
  fi
  [ -L "$cut/install/lua-core" ] || fail "R5: the absent lua-core link was NOT put back at the next start"
  ok
  [ "$(readlink -f "$cut/install/lua-core")" = "$(readlink -f "$cut/share/versions/aaaaaaaaaaaa/lua-core")" ] || fail "R5: the link put back does not resolve through the pointer"
  ok
  grep -q 'finished a half-done version migration' "$W/cut.log" || fail "R5: the repair did not say what it did"
  ok
  # A real directory is never replaced (today's layout, and evidence of a migration not started).
  # The first run linked scripts too, so the real directory has to replace that link first: this is a node whose
  # install still carries a real scripts/ (today's layout), not a half-done migration.
  rm -f "$cut/install/scripts"
  mkdir -p "$cut/install/scripts"; printf 'mine' > "$cut/install/scripts/deploy.sh"
  WA_SHARE_ROOT="$cut/share" WA_INSTALL_DIR="$cut/install" WASM_AGENT_HOME="$W/home2" \
     WASM_AGENT_LUA_ROOT="$(pwd)" timeout 60 "$cut/install/wa" --db "$W/db-cut2.sqlite" > "$W/cut2.log" 2>&1 || fail "R5: wa did not start with a real scripts dir present"
  [ ! -L "$cut/install/scripts" ] || fail "R5: a REAL directory was replaced by a link"
  [ "$(cat "$cut/install/scripts/deploy.sh")" = "mine" ] || fail "R5: the real directory's content was touched"
  ok
fi

# --- FIX 4: THE PROGRAM IS NEVER ABSENT (Fable 25/11) --------------------------------------------------------
# A node must be able to start itself at every point of a conversion: `wa --version` runs in a loop while 50
# conversions replace the program and the trees, and not one run may fail. The loop is killed by the trap, so it
# leaves no process behind.
conv="$W/conv"; mkdir -p "$conv/share/versions/aaaaaaaaaaaa/lua-core" "$conv/share/versions/aaaaaaaaaaaa/scripts" "$conv/install"
printf 'id=aaaaaaaaaaaa\ncommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ninstall_dir=%s/install\n' "$conv" \
  > "$conv/share/versions/aaaaaaaaaaaa/version.txt"
printf 'init' > "$conv/share/versions/aaaaaaaaaaaa/lua-core/init.lua"
printf 'deploy' > "$conv/share/versions/aaaaaaaaaaaa/scripts/deploy.sh"
ln -sfn versions/aaaaaaaaaaaa "$conv/share/current"
# the install starts in TODAY's shape: a real program and real directories
printf '#!/bin/sh\nprintf "wa-stub\\n"\n' > "$conv/install/wa"; chmod +x "$conv/install/wa"
mkdir -p "$conv/install/lua-core" "$conv/install/scripts"
printf 'old' > "$conv/install/lua-core/init.lua"; printf 'old' > "$conv/install/scripts/deploy.sh"
: > "$conv/failures"
WA_SHARE_ROOT="$conv/share" bash -c '
  while [ ! -f "$1/stop" ]; do
    "$1/install/wa" --version >/dev/null 2>&1 || echo "absent" >> "$1/failures"
  done' _ "$conv" &
loop=$!
trap 'rm -f "$conv/stop"; kill "$loop" 2>/dev/null; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
i=0
while [ "$i" -lt 50 ]; do
  WA_SHARE_ROOT="$conv/share" wa_version_link_legacy "$conv/install" >/dev/null 2>&1 || { touch "$conv/stop"; fail "fix 4: a conversion failed at run $i"; }
  i=$((i + 1))
done
touch "$conv/stop"; wait "$loop" 2>/dev/null; trap - EXIT
[ ! -s "$conv/failures" ] || fail "fix 4: the program was ABSENT during a conversion ($(wc -l < "$conv/failures") runs failed)"
ok
# and the structural half: a FILE is kept by a hard link and replaced by ONE rename, never moved away.
grep -q 'ln "$install/$name" "$install/$name.stale' scripts/lib/versions.sh || fail "fix 4: the program is not kept by a hard link"
# Scoped to the FILE loop: a directory may still be moved aside where the system cannot exchange, and the function
# says so. A file may never be.
file_loop="$(sed -n '/for name in wa wa-sentinel/,/for name in lua-core scripts/p' scripts/lib/versions.sh)"
case "$file_loop" in *'mv "$install/$name" '*) fail "fix 4: the program is still MOVED AWAY before the link";; esac
ok

# --- FIX 6: THE RECORD IS A LINK, and a writer must not replace it (Fable 25/11) ------------------------------
# Every reader is unaffected; the risk is the "temp file, mv onto the record" writer, which would turn the link back
# into a regular file and let the pointer and the record disagree again.
rec_dir="$W/rec"; mkdir -p "$rec_dir/share/versions/aaaaaaaaaaaa" "$rec_dir/install"
printf 'commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$rec_dir/share/versions/aaaaaaaaaaaa/installed.txt"
ln -sfn "$rec_dir/share/versions/aaaaaaaaaaaa/installed.txt" "$rec_dir/install/installed.txt"
if wa_version_refuse_record_replace "$rec_dir/install/installed.txt" 2> "$W/rec.err"; then
  fail "fix 6: a writer was allowed to replace the record LINK"
fi
grep -q 'version_record_is_a_link' "$W/rec.err" || { sed -n '1,3p' "$W/rec.err" >&2; fail "fix 6: the refusal is not named version_record_is_a_link"; }
ok
[ -L "$rec_dir/install/installed.txt" ] || fail "fix 6: the guard itself replaced the link"
wa_version_refuse_record_replace "$rec_dir/install/not-a-link.txt" 2>/dev/null || fail "fix 6: a regular file must be writable"
ok
grep -q 'wa_version_refuse_record_replace' scripts/upgrade.sh || fail "fix 6: upgrade.sh's record writer does not ask the guard"
ok

# --- the report's number: REAL disk, not apparent ------------------------------------------------------------
wa_version_disk eeeeeeeeeeee | grep -q '^version_disk eeeeeeeeeeee real=[0-9]* apparent=' || fail "report: wa_version_disk names real blocks and apparent bytes"
ok

echo "version folders ok ($n checks)"

