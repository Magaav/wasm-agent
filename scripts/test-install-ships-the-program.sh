#!/usr/bin/env bash
# THE INSTALL SET IS BOTH, OR NEITHER (wa-term-own-program).
#
# The node draws its terminal by RUNNING `wa-term` from beside itself (capabilities/screen.rs names the
# order: WA_TERM_BIN, beside the executable, PATH). Nothing in an installer used to place that file, so an
# installed node started, answered --version and drew no prompt - the reason the whole branch was reverted
# once (923f2631). This row drives the installer itself and asserts what a scratch install ends with:
#
#   1. a candidate WITHOUT the program is REFUSED by name (term_program_missing), and refuses before it
#      writes anything - the staging tree it was given stays empty;
#   2. a candidate WITH the program stages BOTH, byte for byte, and both are executable;
#   3. the version's member list names wa-term, so a sealed version cannot omit it;
#   4. the staged node answers --version (it is the real binary, run from the tree it was staged into).
#
# Nothing here installs anything into this machine's install directory: it uses WA_VERSION_STAGING, which
# is the deploy's own staging path and exits before any swap or restart.
set -uo pipefail
# THIS ROW DRIVES THE INSTALLER, SO IT RUNS WHERE THE INSTALLER RUNS. upgrade.sh refuses to start inside a turn
# on the node it would replace (its turn guard, by process ancestry), so from a node turn this row says SKIP
# rather than red: the refusal is the guard working, not a missing program. The runner starts it outside one.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if . "$ROOT/scripts/lib/turn-guard.sh" 2>/dev/null && [ "$(turn_owner 2>/dev/null)" = node ]; then
  echo "SKIP test-install-ships-the-program: inside a node turn; upgrade.sh refuses to run here by design"
  exit 0
fi
UPGRADE="$ROOT/scripts/upgrade.sh"
# THE ONE WAY A ROW GIVES AN INSTALLER ITS ENVIRONMENT (scripts/lib/scratch-installer.sh): a scratch HOME,
# XDG dirs, a stub systemctl, its own port and its own turn identity. Calling upgrade.sh from this turn's
# environment is refused by its turn guard - correctly - and reaching the live node would be worse than red.
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/scratch-installer.sh"
# /home, never /tmp: this machine's /tmp is a tmpfs that fills and surfaces as an unrelated failure.
# NOT under ~/.wasm-agent: that is the operator STORE, and the installer harness refuses a scratch root inside
# it by name (refused(real_node_home)) - which is the guard doing its job. NOT /tmp either: a tmpfs here.
WORK="${WA_TEST_DIR:-$HOME/wa-test-scratch/install-set}"
rm -rf "$WORK"; mkdir -p "$WORK" || { echo "cannot create $WORK"; exit 1; }

# The pair under test: a release directory, or this tree's own build output.
SRC="${WA_RELEASE_DIR:-}"
if [ -z "$SRC" ]; then
  for candidate in "$ROOT/.local-target/release" "$ROOT/rust/target/release"; do
    [ -x "$candidate/wa" ] && [ -x "$candidate/wa-term" ] && SRC="$candidate" && break
  done
fi
[ -n "$SRC" ] || { echo "SKIP: no release directory with wa and wa-term (build one, or set WA_RELEASE_DIR)"; exit 0; }
[ -x "$SRC/wa" ] || { echo "FAIL: $SRC/wa is not executable"; exit 1; }
[ -x "$SRC/wa-term" ] || { echo "FAIL: $SRC/wa-term is not executable - the install set has no program"; exit 1; }

# The harness refuses the live port by name; a row picks its own, and these two never bind anything.
ROW_PORT="${WA_TEST_PORT:-18799}"; ROW_CLIENT_PORT="${WA_TEST_CLIENT_PORT:-18800}"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

# ---------------------------------------------------------------------------------------------------
# 1. A CANDIDATE WITHOUT THE PROGRAM IS REFUSED, AND NOTHING IS STAGED.
# ---------------------------------------------------------------------------------------------------
only_node="$WORK/only-node"; mkdir -p "$only_node"
cp -f "$SRC/wa" "$only_node/wa"
mkdir -p "$WORK/scratch-refused"
stage_refused="$WORK/scratch-refused/stage"; mkdir -p "$stage_refused"
out="$(wa_installer_run --root "$WORK/scratch-refused" --port "$ROW_PORT" --client-port "$ROW_CLIENT_PORT" --install-dir "$WORK/scratch-refused/install" \
        --set "WA_VERSION_STAGING=$stage_refused" \
        -- bash "$UPGRADE" "$only_node/wa" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "a candidate without wa-term is refused (exit $rc)" \
                || bad "a candidate without wa-term was ACCEPTED - an install can drop the program"
case "$out" in
  *term_program_missing*) pass "the refusal is named term_program_missing, not a silent skip" ;;
  *) bad "the refusal does not say term_program_missing: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')" ;;
esac
[ -z "$(ls -A "$stage_refused" 2>/dev/null)" ] && pass "nothing was staged by the refused install" \
  || bad "the refused install still wrote: $(ls -A "$stage_refused" | tr '\n' ' ')"

# ---------------------------------------------------------------------------------------------------
# 2. THE PAIR IS STAGED, BYTE FOR BYTE, AND BOTH RUN.
# ---------------------------------------------------------------------------------------------------
mkdir -p "$WORK/scratch-ok"
stage_ok="$WORK/scratch-ok/stage"; mkdir -p "$stage_ok"
# Deploy's own environment: upgrade.sh writes the install record through a writer that lives in the
# deploy, and reads the install it is upgrading from WA_INSTALL_DIR (deploy.sh passes exactly these).
scratch_install="$WORK/scratch-ok/install"; mkdir -p "$scratch_install"
[ -f "$scratch_install/installed.txt" ] || printf 'commit=0000000
' > "$scratch_install/installed.txt"
# upgrade.sh upgrades a node that EXISTS (it never creates one), so the scratch install holds a node of its
# own. A COPY, not a link: the installer compares bytes, and an identical file would read as "nothing to swap".
[ -x "$scratch_install/wa" ] || { cp -f "$SRC/wa" "$scratch_install/wa" && chmod 0755 "$scratch_install/wa"; }
# A RECORDED OVERRIDE, because this row stages and never installs: a tree built from an older commit than
# the running node is normally refused (the freeze guard, and rightly), and the staging path it exercises
# touches no live file.
mkdir -p "$WORK/scratch-ok"
out="$(wa_installer_run --root "$WORK/scratch-ok" --port "$ROW_PORT" --client-port "$ROW_CLIENT_PORT" --install-dir "$WORK/scratch-ok/install" \
        --set "WA_VERSION_STAGING=$stage_ok" \
        --set "WA_UPGRADE_FORCE_REASON=test-install-ships-the-program: staging path only, nothing is installed" \
        -- bash "$UPGRADE" "$SRC/wa" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "a candidate with wa-term beside it stages cleanly" \
                || bad "staging the pair failed (exit $rc): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
for f in wa wa-term; do
  if [ -f "$stage_ok/$f" ]; then pass "the staging tree has $f"; else bad "the staging tree is missing $f"; continue; fi
  [ -x "$stage_ok/$f" ] && pass "$f is executable" || bad "$f is not executable"
  cmp -s "$SRC/$f" "$stage_ok/$f" && pass "$f is the byte-for-byte program that was offered" \
    || bad "$f differs from the candidate"
done

# The node is the real binary, run from the tree it was staged into: it answers, and it is the same node.
if [ -x "$stage_ok/wa" ]; then
  v="$("$stage_ok/wa" --version 2>&1 | head -1)"
  case "$v" in
    *wasm-agent*) pass "the staged node runs: $v" ;;
    *) bad "the staged node did not answer --version: $v" ;;
  esac
fi

# ---------------------------------------------------------------------------------------------------
# 3. THE VERSION NAMES IT, so a sealed version cannot omit the program.
# ---------------------------------------------------------------------------------------------------
if . "$ROOT/scripts/lib/versions.sh" 2>/dev/null && declare -f wa_version_members >/dev/null 2>&1; then
  members="$(wa_version_members 2>/dev/null)"
  case " $members " in
    *wa-term*) pass "the version's member list names wa-term" ;;
    *) bad "the version's member list does NOT name wa-term: $members" ;;
  esac
else
  grep -q 'for name in wa wa-sentinel wa-term' "$ROOT/scripts/lib/versions.sh" \
    && pass "scripts/lib/versions.sh lists wa-term among the version's members" \
    || bad "scripts/lib/versions.sh does not list wa-term among the version's members"
fi

rm -rf "$WORK"
if [ "$fails" -eq 0 ]; then echo "PASS test-install-ships-the-program (4 rows)"; exit 0; fi
echo "FAIL test-install-ships-the-program ($fails row(s) failed)"; exit 1
