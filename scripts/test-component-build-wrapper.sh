#!/usr/bin/env bash
# The component build's rustc wrapper, and the fallback build on a node that cannot have one.
#
# THE DEFECT THIS PINS (24/11, work 20:56Z). `wa update` downloaded and verified node-9a0c589adfa0, found no
# components bundle for its lock (components-df6f97708c72, HTTP 404), started the fallback build, waited two
# minutes for a toolchain, and died with
#
#   could not execute process `wa-remap-rustc` ... Permission denied (os error 13)
#   error: component codemode did not compile; nothing installed
#
# The wrapper install trusted a file it had not tested and a directory it had not tested at all, so a wrapper
# left without its execute bit - or a directory this process may not execute files from (a noexec /tmp, a
# fixed /tmp path another user created first) - became cargo's `Permission denied`, naming none of it. And the
# build was started at all on a node with no cargo: the two minutes were a toolchain fetch it could never use.
#
# What runs here, in order:
#   * a fresh wrapper directory: created 0700, the wrapper installed 0755, reused (not reinstalled) next run;
#   * a wrapper whose execute bit is gone is REPAIRED and named, instead of being handed to cargo;
#   * a directory that cannot be written is refused with its reason, never silently chmod-ed, and an explicit
#     WA_REMAP_DIR is a refusal rather than a quiet move to another directory (an override nobody can read
#     later is not a decision);
#   * a symlinked or group/world-writable wrapper directory is refused by name (the path is fixed and
#     guessable, so another local user can create it first - a wrapper they can write is a compiler
#     invocation they choose, and its bytes become a published artifact);
#   * the default path falls back from an unusable TMPDIR to the home cache, printing which candidate it
#     refused and why; with no usable candidate at all the answer is `wa_remap_wrapper_unusable`, and a
#     directory is never printed;
#   * and the deploy's side: with no cargo and no rustup on PATH, the component staging step refuses AT ONCE
#     with `component_build_impossible` and NEVER starts scripts/build-components.sh (a tripwire proves it
#     was not started), instead of fetching a toolchain for two minutes.
#
# NOT TESTABLE HERE, AND SAID SO RATHER THAN FAKED: a noexec mount cannot be created without root, so the
# rows above reach `wa_remap_dir_runs_files` through directories that cannot be written by this process
# (same code path, same refusal, different errno) and the probe itself is exercised for real wherever it
# succeeds. The one measurement that would name work's exact cause is in the report: `findmnt -no
# TARGET,OPTIONS /tmp` on work, and the mode of /tmp/wa-remap-rustc/<hash>/wa-remap-rustc.
#
# No network, no cargo build, no node. Scratch HOME/WASM_AGENT_HOME through scripts/lib/scratch-home.sh.
#
#   bash scripts/test-component-build-wrapper.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/component-remap-wrapper.sh"
. "$ROOT/scripts/lib/deploy-components.sh"

root="$(wa_scratch_root wa-component-build-wrapper)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
cleanup() { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
# Nothing here builds, but HOME decides where the fallback wrapper directory would go: a scratch home, proven
# distinct from the operator store before anything is created under it.
REAL_HOME="${HOME:-}"
export HOME="$W/home"
mkdir -p "$HOME"
# The guard asks whether the home THIS TEST HANDS OVER is the operator one, so it reads the operator
# home: HOME is the scratch one by now, and comparing the scratch home against itself refuses everything.
HOME="$REAL_HOME" wa_scratch_home_guard "$W/home" || exit 2
export WASM_AGENT_HOME="$HOME"
unset WA_REMAP_DIR

checks=0; failed=0
ok()   { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
hash="$(wa_remap_wrapper_hash "$ROOT")"
[ -n "$hash" ] || { echo 'test-component-build-wrapper: cannot hash the wrapper sources' >&2; exit 2; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# ---- 1. a fresh directory: 0700, the wrapper 0755, and the same directory next time -----------------
v1="$W/one"
mkdir -p "$v1"
out1="$(WA_REMAP_DIR="$v1" wa_remap_wrapper_dir "$ROOT" 2>"$W/one.err")"; rc1=$?
ok "$([ "$rc1" = 0 ] && echo 1)" "an empty WA_REMAP_DIR receives the wrapper" "rc=$rc1 $(cat "$W/one.err")"
ok "$([ "$out1" = "$v1/$hash" ] && echo 1)" "the directory is the wrapper's content hash under it" "got '$out1'"
ok "$([ -x "$v1/$hash/wa-remap-rustc" ] && echo 1)" "the wrapper is installed and executable"
ok "$([ "$(mode "$v1/$hash/wa-remap-rustc")" = 755 ] && echo 1)" "with mode 755, not the mode of whatever it was copied from" "mode $(mode "$v1/$hash/wa-remap-rustc")"
ok "$([ "$(mode "$v1/$hash")" = 700 ] && echo 1)" "in a directory only this user writes (0700)" "mode $(mode "$v1/$hash")"
grep -q 'component build wrapper:' "$W/one.err" && ok 1 "the build log names the directory it used" || ok 0 "the build log names the directory it used" "$(cat "$W/one.err")"
WA_REMAP_DIR="$v1" wa_remap_wrapper_dir "$ROOT" 2>"$W/two.err" >/dev/null
ok "$(grep -q 'reused' "$W/two.err" && echo 1)" "a second run reuses the same wrapper instead of reinstalling it" "$(cat "$W/two.err")"

# ---- 2. THE SHAPE WORK DIED OF: an existing wrapper without its execute bit -----------------------------
chmod 644 "$v1/$hash/wa-remap-rustc"
out2="$(WA_REMAP_DIR="$v1" wa_remap_wrapper_dir "$ROOT" 2>"$W/repair.err")"; rc2=$?
ok "$([ "$rc2" = 0 ] && echo 1)" "a wrapper left without its execute bit is repaired, not handed to cargo" "rc=$rc2 $(cat "$W/repair.err")"
ok "$([ -x "$v1/$hash/wa-remap-rustc" ] && echo 1)" "and the file is executable afterwards"
ok "$(grep -q 'wa_remap_wrapper_not_executable' "$W/repair.err" && echo 1)" "the repair is named in the log" "$(cat "$W/repair.err")"

# ---- 3. a directory that cannot be written: refused by name, never chmod-ed ---------------------------
v3="$W/three"
mkdir -p "$v3/$hash"
chmod 500 "$v3/$hash"
out3="$(WA_REMAP_DIR="$v3" wa_remap_wrapper_dir "$ROOT" 2>"$W/ro.err")"; rc3=$?
ok "$([ "$rc3" = 1 ] && [ -z "$out3" ] && echo 1)" "an explicit WA_REMAP_DIR that cannot be written is a refusal, and no directory is printed" "rc=$rc3 out='$out3'"
ok "$(grep -qE 'wa_remap_dir_unwritable|wa_remap_wrapper_install_failed' "$W/ro.err" && echo 1)" "the refusal says the directory cannot be written" "$(cat "$W/ro.err")"
ok "$([ "$(mode "$v3/$hash")" = 500 ] && echo 1)" "and the directory was not chmod-ed behind the operator" "mode $(mode "$v3/$hash")"

# ---- 4. an explicit WA_REMAP_DIR that is a symlink, or writable by others, is refused -----------------
v4="$W/four"
mkdir -p "$v4"
ln -s "$W/one" "$v4/$hash"
WA_REMAP_DIR="$v4" wa_remap_wrapper_dir "$ROOT" 2>"$W/symlink.err" >/dev/null; rc4=$?
ok "$([ "$rc4" = 1 ] && echo 1)" "a symlinked wrapper directory is refused" "rc=$rc4 $(cat "$W/symlink.err")"
ok "$(grep -q 'wa_remap_dir_is_a_symlink' "$W/symlink.err" && echo 1)" "by name" "$(cat "$W/symlink.err")"
v5="$W/five"
mkdir -p "$v5/$hash"
chmod 777 "$v5/$hash"
WA_REMAP_DIR="$v5" wa_remap_wrapper_dir "$ROOT" 2>"$W/777.err" >/dev/null; rc5=$?
ok "$([ "$rc5" = 1 ] && echo 1)" "a group- or world-writable wrapper directory is refused" "rc=$rc5 $(cat "$W/777.err")"
ok "$(grep -q 'wa_remap_dir_group_or_world_writable' "$W/777.err" && echo 1)" "by name" "$(cat "$W/777.err")"

# ---- 5. the default path: an unusable TMPDIR falls back to the home cache, and says why --------------
ro="$W/ro-tmp"
mkdir -p "$ro/wa-remap-rustc/$hash"
chmod 500 "$ro/wa-remap-rustc/$hash"
out6="$(TMPDIR="$ro" wa_remap_wrapper_dir "$ROOT" 2>"$W/fallback.err")"; rc6=$?
ok "$([ "$rc6" = 0 ] && echo 1)" "an unusable TMPDIR does not stop the build" "rc=$rc6 $(cat "$W/fallback.err")"
ok "$([ "$out6" = "$HOME/.cache/wa-remap-rustc/$hash" ] && echo 1)" "it falls back to the home cache" "got '$out6'"
ok "$(grep -q "is unusable, trying the next directory" "$W/fallback.err" && echo 1)" "and the refused candidate is printed with its reason, not skipped in silence" "$(cat "$W/fallback.err")"
ok "$([ -x "$out6/wa-remap-rustc" ] && echo 1)" "the fallback wrapper is executable"
# ...and with no usable candidate at all, the answer is one refusal that names what to do.
rohome="$W/ro-home"
mkdir -p "$rohome"
chmod 500 "$rohome"
out7="$(TMPDIR="$ro" HOME="$rohome" wa_remap_wrapper_dir "$ROOT" 2>"$W/none.err")"; rc7=$?
ok "$([ "$rc7" = 1 ] && [ -z "$out7" ] && echo 1)" "with no usable directory at all the answer is a refusal and no directory" "rc=$rc7 out='$out7'"
ok "$(grep -q 'wa_remap_wrapper_unusable' "$W/none.err" && echo 1)" "the refusal is named (cargo would have said 'Permission denied')" "$(cat "$W/none.err")"
chmod 700 "$rohome"

# ---- 6. the deploy side: no toolchain means refuse AT ONCE, before any build is started ---------------
# The fixture tree has a lock that pins a component and a scripts/build-components.sh that RECORDS being run.
# On the code before this fix the staging step started that script (two minutes of toolchain fetch on work);
# the row is that it is never started, so the tripwire file must not exist.
fixture="$W/fixture"
mkdir -p "$fixture/scripts"
printf 'svc-fixture %064d 3\n' 0 > "$fixture/components.lock"
cat > "$fixture/scripts/build-components.sh" <<'SH'
#!/usr/bin/env bash
touch "$WA_BUILD_TRIPWIRE"
exit 1
SH
chmod 755 "$fixture/scripts/build-components.sh"
blockers="$(PATH=/usr/bin:/bin WA_COMPONENT_TOOLCHAIN= wa_component_build_blockers)"; rc8=$?
# This host HAS cargo in ~/.cargo/bin (measured 24/11) but not on /usr/bin:/bin, which is the point: the
# question is about PATH, not about the machine.
ok "$([ "$rc8" = 1 ] && echo 1)" "a PATH without cargo or rustup is a blocker" "rc=$rc8 blockers='$blockers'"
ok "$(printf '%s' "$blockers" | grep -q cargo && printf '%s' "$blockers" | grep -q rustup && echo 1)" "and the blocker names both" "blockers='$blockers'"
WA_BUILD_TRIPWIRE="$W/built" PATH=/usr/bin:/bin wa_component_stage "$fixture" svc-fixture "$W/stage" 2>"$W/stage.err" >/dev/null; rc9=$?
ok "$([ "$rc9" = 4 ] && echo 1)" "the staging step refuses a component it cannot get (rc 4)" "rc=$rc9 $(cat "$W/stage.err")"
ok "$(grep -q 'component_build_impossible' "$W/stage.err" && echo 1)" "by name: component_build_impossible" "$(cat "$W/stage.err")"
ok "$(grep -qE 'components-[0-9a-f]{12}' "$W/stage.err" && echo 1)" "and it names the bundle that would have made the build unnecessary" "$(cat "$W/stage.err")"
ok "$([ ! -f "$W/built" ] && echo 1)" "and scripts/build-components.sh was never started (no toolchain was fetched, nothing was compiled)"

printf 'component build wrapper ok (%d checks, %d failed)\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
