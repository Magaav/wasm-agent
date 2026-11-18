#!/usr/bin/env bash
# Review of 18/11, item 9: deploy must CHECK the canonical runtime binding again at install, after the long
# build, and compare that answer with the one the preflight chose.
#
# The defect (62c3c064): the preflight exported WA_RUNTIME_WORKTREE, so the install-time block read a value that
# was already set and skipped itself - the "clean and equal to main" re-check that step exists for was gone, and
# a second worktree appearing during the build could not be caught. Nothing about it was visible: the deploy
# succeeded.
#
# WHAT IS RUN. The comparison itself (scripts/lib/runtime-binding.sh) is executed here, case by case, in a
# scratch directory. The WIRING in scripts/deploy.sh is asserted as structure - which block holds the preflight
# answer, whether anything exports it before step 6, and that step 6 calls the comparison with both answers -
# because reaching step 6 means a full cargo build and an install, which no test may do to this machine. Both
# halves are needed: the function alone would keep passing if deploy.sh stopped calling it.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"
LIB="$ROOT_DIR/scripts/lib/runtime-binding.sh"
fail() { echo "test-deploy-runtime-recheck: $*" >&2; exit 1; }
checks=0
ok() { checks=$((checks + 1)); }
[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"

W="$(mktemp -d "${TMPDIR:-/tmp}/wa-runtime-recheck-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tree" "$W/second" || fail "cannot stage the scratch directories"

# ---- the wiring in deploy.sh ---------------------------------------------------------------------------
# The preflight answer is kept in its own variable, and NOT exported as the binding before step 6 runs.
preflight_line="$(grep -n '^WA_RUNTIME_PREFLIGHT=' "$DEPLOY" | head -1 | cut -d: -f1)"
[ -n "$preflight_line" ] || fail "ITEM 9: the preflight answer is not kept in WA_RUNTIME_PREFLIGHT"
ok
install_line="$(grep -n 'deploy: installing through upgrade.sh' "$DEPLOY" | head -1 | cut -d: -f1)"
[ -n "$install_line" ] || fail "ITEM 9: cannot find the install phase in deploy.sh"
ok
early_export="$(sed -n "1,${install_line}p" "$DEPLOY" | grep -c 'export WA_RUNTIME_WORKTREE' || true)"
[ "$early_export" = "0" ] \
  || fail "ITEM 9: the preflight still exports WA_RUNTIME_WORKTREE, so the install-time check skips itself"
ok
recheck_line="$(grep -n 'wa_runtime_binding_recheck' "$DEPLOY" | cut -d: -f1 | head -1)"
[ -n "$recheck_line" ] || fail "ITEM 9: deploy.sh never re-checks the binding at install"
[ "$recheck_line" -gt "$install_line" ] || fail "ITEM 9: the re-check is not in the install phase"
ok
grep -q 'wa_runtime_binding_recheck "$WA_RUNTIME_PREFLIGHT" "$WA_RUNTIME_WORKTREE"' "$DEPLOY" \
  || fail "ITEM 9: the re-check does not compare the install answer with the preflight answer"
ok
grep -q 'BINDING_RECHECK' "$DEPLOY" || fail "ITEM 9: the re-check result is not read (a refusal must fail the deploy)"
ok

# ---- the comparison itself ------------------------------------------------------------------------------
[ -f "$LIB" ] || fail "ITEM 9: no $LIB to source"
# shellcheck disable=SC1090
. "$LIB"
command -v wa_runtime_binding_recheck >/dev/null 2>&1 || fail "ITEM 9: the lib defines no re-check"

out="$(wa_runtime_binding_recheck "$W/tree" "$W/tree")" && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "ITEM 9: the same answer twice is not a refusal: $out"
[ -z "$out" ] || fail "ITEM 9: a passing re-check said something: $out"
ok

out="$(cd "$W" && wa_runtime_binding_recheck tree "$W/tree")" && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "ITEM 9: two spellings of one directory are treated as a change: $out"
ok

out="$(wa_runtime_binding_recheck "$W/tree" "$W/second")" && rc=0 || rc=$?
[ "$rc" = "1" ] || fail "ITEM 9: a binding that changed during the build was not refused"
case "$out" in
  *"$W/tree"*) : ;;
  *) fail "ITEM 9: the refusal does not name the preflight answer: $out" ;;
esac
case "$out" in
  *"$W/second"*) : ;;
  *) fail "ITEM 9: the refusal does not name the install answer: $out" ;;
esac
case "$out" in
  *"nothing was installed"*) : ;;
  *) fail "ITEM 9: the refusal does not say that nothing was installed: $out" ;;
esac
ok

out="$(wa_runtime_binding_recheck "" "$W/tree")" && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "ITEM 9: an operator-chosen binding (no preflight answer) is refused: $out"
ok

# A checkout that disappeared during the build is a change too: the install answer names a path that is gone.
out="$(wa_runtime_binding_recheck "$W/tree" "$W/gone")" && rc=0 || rc=$?
[ "$rc" = "1" ] || fail "ITEM 9: a binding that no longer exists is not refused"
ok

echo "deploy runtime re-check ok ($checks checks)"
