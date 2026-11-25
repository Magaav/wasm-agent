#!/usr/bin/env bash
# THE INSTALLER OF A VERSION FOLDER, AND A CUT AT EVERY STEP BOUNDARY (slice (b), requirements 5 and 9).
#
# Row R3 asks one thing: after a cut at ANY point of an install, the node is healthy and updatable. This file
# drives that by running scripts/version-install.sh once to completion and then once per step with
# WA_VERSION_KILL_AFTER_STEP=<n> (a real SIGKILL of the installer), asserting after each:
#   - the install's own wa still answers (--version), so the node starts;
#   - a plain rerun of the installer completes and current names the version (so it is updatable);
#   - the legacy path resolves through the pointer once the rerun is done.
#
# THE CUT INSIDE step 7 (between "rename the real path aside" and "rename the link onto it") is not reachable
# from this hook: it kills between steps, not inside one. That window is what lua/core/version_repair.lua and
# scripts/test-version-repair.lua cover, and the report says which half proves what.
#
# SCRATCH RULE (Fable 25/11). Every scratch install here: WASM_AGENT_DB and XDG_CONFIG_HOME unset, a scratch
# WA_SENTINEL_UNIT_DIR and a stub WA_SENTINEL_UNIT_SYSTEMCTL, and the three operator files (the sentinel unit,
# runtime-worktree.txt, installed.txt) hashed before and after - any difference stops the row.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/versions.sh

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-version-install: $*" >&2; exit 1; }

LIVE_UNIT="$HOME/.config/systemd/user/wa-sentinel.service"
LIVE_MARKER="$HOME/.local/bin/runtime-worktree.txt"
LIVE_RECORD="$HOME/.local/bin/installed.txt"
live_hashes() { sha256sum "$LIVE_UNIT" "$LIVE_MARKER" "$LIVE_RECORD" 2>/dev/null; }
BEFORE="$(live_hashes)"

scratch_parent="${TMPDIR:-/tmp}"
case "$scratch_parent" in */.wasm-agent|*/.wasm-agent/*) scratch_parent=/tmp ;; esac
W="$(mktemp -d "$scratch_parent/wa-vinstall-XXXXXX")" || { echo "FAIL test-version-install: no scratch" >&2; exit 2; }
case "$W" in */.wasm-agent|*/.wasm-agent/*) echo "FAIL test-version-install: scratch inside the data dir" >&2; exit 2;; esac
cleanup() { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

# THE G CONDITION, FIRST (Fable 25/11): the clean prefix, a stub systemctl, and the checker - in the exact
# environment this row will run in - BEFORE anything is installed. Not isolated means nothing runs.
. scripts/lib/scratch-env.sh
wa_scratch_env_apply "$W" >/dev/null
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/systemctl.calls"\nexit 0\n' "$W" > "$WA_SENTINEL_UNIT_SYSTEMCTL"
chmod +x "$WA_SENTINEL_UNIT_SYSTEMCTL"
export WA_SHARE_ROOT="$W/share"
ISOLATION="$(wa_scratch_env_check "$W" 2>&1)" || { printf '%s\n' "$ISOLATION" >&2; fail "the row's environment is NOT ISOLATED: nothing was run"; }

ID=aaaaaaaaaaaa
COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# A STUB PROGRAM, not the installed one: this row is about the INSTALLER's layout and its cut order, and it must
# run from "env -i" under the orchestrator's row runner with no live path in reach. A real program's start path
# is row R5's job (scripts/test-versions.sh), which runs the suite's own binary. The stub answers --version and
# nothing else, so "an executable at this path that runs" is what gets proven here.
BIN="$W/bin/wa-stub"
printf '#!/bin/sh\nprintf "wa-stub\\n"\nexit 0\n' > "$BIN"; chmod +x "$BIN"
[ -x "$BIN" ] || { echo "FAIL test-version-install: the stub program could not be written" >&2; exit 2; }

# A staging tree shaped like what a deploy stages: program, sentinel, lua tree, scripts, ui, and the record.
stage() { # <dir>
  local dir="$1"
  mkdir -p "$dir/lua-core/lua/core" "$dir/scripts" "$dir/ui"
  cp "$BIN" "$dir/wa"
  printf 'sentinel' > "$dir/wa-sentinel"
  printf 'init' > "$dir/lua-core/lua/core/init.lua"
  printf 'big' > "$dir/lua-core/lua/core/big.lua"
  printf 'deploy' > "$dir/scripts/deploy.sh"
  printf 'ui' > "$dir/ui/index.html"
  printf 'commit=%s\nbranch=main\n' "$COMMIT" > "$dir/installed.txt"
}
install_dir() { # <dir>: what today's install looks like before the switch - a real program and record
  local dir="$1"
  mkdir -p "$dir/lua-core/lua/core" "$dir/scripts"
  cp "$BIN" "$dir/wa"
  printf 'old-init' > "$dir/lua-core/lua/core/init.lua"
  printf 'old-deploy' > "$dir/scripts/deploy.sh"
  printf 'commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$dir/installed.txt"
}
run_installer() { # <staging> <install> [<commit>] [extra env...]
  local staging="$1" install="$2" commit="$COMMIT"
  shift 2
  case "${1:-}" in ????????) commit="$1"; shift ;; esac
  env "$@" bash scripts/version-install.sh --staging "$staging" --commit "$commit" --install "$install" --share "$W/share"
}

# --- the install that works -----------------------------------------------------------------------------------
S1="$W/stage1"; I1="$W/install1"; stage "$S1"; install_dir "$I1"
run_installer "$S1" "$I1" WA_VERSION_MARGIN_BYTES=0 > "$W/i1.log" 2>&1 || { sed -n '1,6p' "$W/i1.log" >&2; fail "the install itself must succeed"; }
ok
[ -f "$W/share/versions/$ID/version.txt" ] || fail "the version folder exists with its own record"
[ "$(wa_version_current)" = "$ID" ] || fail "current names the version"
ok
[ -L "$I1/installed.txt" ] || fail "installed.txt is a LINK to the pointer's record, not a second file"
grep -q "^commit=$COMMIT" "$I1/installed.txt" || fail "the record link reads the version's own record"
ok
for name in wa wa-sentinel lua-core scripts; do
  [ -L "$I1/$name" ] || fail "the legacy path $name is a link through the pointer"
  [ "$(readlink -f "$I1/$name")" = "$(readlink -f "$W/share/versions/$ID/$name")" ] || fail "$name resolves through current"
done
ok
[ -x "$I1/wa" ] && "$I1/wa" --version >/dev/null 2>&1 || fail "the install's own wa answers after the switch"
ok
grep -q 'version_prune_done' "$W/i1.log" || fail "retention runs as part of the install"
ok

# A second install of the same commit is refused by the assembler (a version is never rewritten), and the
# installer keeps the folder it already has instead of starting over.
S1b="$W/stage1b"; stage "$S1b"
run_installer "$S1b" "$I1" WA_VERSION_MARGIN_BYTES=0 > "$W/i1b.log" 2>&1 || { sed -n '1,4p' "$W/i1b.log" >&2; fail "a rerun of the same version continues instead of failing"; }
grep -q "already assembled" "$W/i1b.log" || fail "the rerun says it kept the assembled version"
ok

# --- R9: no room is refused BEFORE anything is staged ---------------------------------------------------------
S2="$W/stage2"; I2="$W/install2"; stage "$S2"; install_dir "$I2"
free_kb="$(df -P -k "$W" | awk 'NR==2 {print $4}')"
if run_installer "$S2" "$I2" WA_VERSION_MARGIN_BYTES=$((free_kb * 1024 + 1)) > "$W/i2.log" 2>&1; then
  fail "an install with no room must be refused"
fi
grep -q 'version_no_room free=' "$W/i2.log" || fail "the refusal is named version_no_room with its numbers"
[ ! -d "$W/share/versions/bbbbbbbbbbbb" ] || fail "a refused install wrote no version folder"
ok

# --- FIX 5: a SEALED staging directory left by a cut does not block the retry ----------------------------------
# A cut between the seal and the rename leaves versions/.staging-<id> at 0555; rm -rf then refuses forever and every
# later install of that version dies with version_staging_unwritable. The installer must be able to clear it.
S5="$W/stage5"; I5="$W/install5"; stage "$S5"; install_dir "$I5"
COMMIT_F=cccccccccccccccccccccccccccccccccccccccc; ID_F=cccccccccccc
printf 'commit=%s\nbranch=main\n' "$COMMIT_F" > "$S5/installed.txt"
mkdir -p "$W/share/versions/.staging-$ID_F/left/lua"
printf 'half' > "$W/share/versions/.staging-$ID_F/left/lua/init.lua"
chmod 0555 "$W/share/versions/.staging-$ID_F" "$W/share/versions/.staging-$ID_F/left" "$W/share/versions/.staging-$ID_F/left/lua" 2>/dev/null || true
chmod 0444 "$W/share/versions/.staging-$ID_F/left/lua/init.lua" 2>/dev/null || true
run_installer "$S5" "$I5" "$COMMIT_F" WA_VERSION_MARGIN_BYTES=0 > "$W/i5.log" 2>&1 || { sed -n '1,6p' "$W/i5.log" >&2; fail "fix 5: a sealed staging directory blocked the retry"; }
[ -d "$W/share/versions/.staging-$ID_F" ] && fail "fix 5: the stale staging directory is still there after a successful install"
ok
[ -f "$W/share/versions/$ID_F/version.txt" ] || fail "fix 5: the retry did not assemble the version"
ok

# --- R3: a SIGKILL after each step boundary, then: does the node answer, and can it be installed again? -------
step=1
while [ "$step" -le 8 ]; do
  S="$W/stage-$step"; I="$W/install-$step"
  stage "$S"; install_dir "$I"
  if run_installer "$S" "$I" WA_VERSION_MARGIN_BYTES=0 WA_VERSION_KILL_AFTER_STEP="$step" > "$W/kill-$step.log" 2>&1; then
    fail "step $step: WA_VERSION_KILL_AFTER_STEP did not cut the installer"
  fi
  # (a) the node starts: the install's own wa answers, whatever state the links are in.
  "$I/wa" --version >/dev/null 2>&1 || fail "step $step: the install's wa does not answer after the cut"
  # (b) it is updatable: the same install runs again to the end and current names the version.
  run_installer "$S" "$I" WA_VERSION_MARGIN_BYTES=0 > "$W/rerun-$step.log" 2>&1 || {
    sed -n '1,6p' "$W/rerun-$step.log" >&2; fail "step $step: the install cannot be run again after the cut"; }
  [ "$(wa_version_current)" = "$ID" ] || fail "step $step: after the rerun current does not name the version"
  "$I/wa" --version >/dev/null 2>&1 || fail "step $step: the install's wa does not answer after the rerun"
  # (c) the paths the pointer names resolve once the rerun is done.
  for name in wa lua-core scripts; do
    [ "$(readlink -f "$I/$name")" = "$(readlink -f "$W/share/versions/$ID/$name")" ] || fail "step $step: $name does not resolve after the rerun"
  done
  step=$((step + 1))
done
ok

# --- the scratch rule's own check: the operator's three files are byte-identical -------------------------------
AFTER="$(live_hashes)"
[ "$BEFORE" = "$AFTER" ] || { echo "BEFORE:" >&2; printf '%s\n' "$BEFORE" >&2; echo "AFTER:" >&2; printf '%s\n' "$AFTER" >&2; fail "a live file changed during this row: STOP"; }
ok
[ ! -e "$LIVE_UNIT.wa-vinstall" ] || fail "the row left a file beside the live unit"

echo "version install ok ($n checks)"

