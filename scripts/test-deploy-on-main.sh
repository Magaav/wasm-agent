#!/usr/bin/env bash
# Does `deploy.sh` refuse a HEAD that is not on `origin/main` - even when `WA_INSTALL_DIR` is set?
#
# THE FAILURE THIS PINS (finding F5 of the review of change/deploy-unbound). The check read
#
#     if [ -z "${WA_INSTALL_DIR:-}" ] || [ "$REQUIRE_MAIN" = "1" ]; then <refuse> fi
#
# so the environment variable an operator sets to say WHERE to install also switched off the rule about WHAT
# may be installed - and the deploy that needs the rule most is one into another directory, which is exactly
# the case that skipped it. The owner's rule is "we must merge before install". The check is unconditional
# now; `--require-main` is still accepted, as a no-op, for callers that pass it.
#
# WHAT IS RUN. The REAL `scripts/deploy.sh`, in the idiom of `scripts/test-deploy-preconditions.sh`: a private
# HOME, a private install directory, `WA_DEPLOY_ROOT` pinned at a scratch Git repository, and a PATH without
# cargo, so no case can reach a build. The scratch repository HAS an `origin/main`, and its HEAD can be a
# commit that `origin/main` does not contain - the state an unmerged `change/` branch makes.
#
# Two cases, opposite directions:
#   * HEAD not on origin/main, WA_INSTALL_DIR set -> refused BY NAME, and nothing installed;
#   * HEAD IS origin/main, same WA_INSTALL_DIR    -> past that check (it stops later, at the missing
#     toolchain) - a check that always refused would fail here.
#
# Hermetic: temp directories, no cargo, no network, no model, no port, and the live install is never named.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"
checks=0
fail() { echo "test-deploy-on-main: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }

[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-on-main-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# A scratch repository: `main` at A, `feature` at B (a child of A), origin/main pinned at A. B is therefore
# zero commits behind origin/main and still NOT on it - the shape that the ancestry check exists for.
TREE="$WORK/tree"; mkdir -p "$TREE/scripts" "$TREE/rust"
printf 'the first commit\n' > "$TREE/README"
git -C "$TREE" init -q --initial-branch=main || fail "cannot init the scratch repository"
git -C "$TREE" config user.name "on-main fixture"
git -C "$TREE" config user.email "on-main@example.invalid"
git -C "$TREE" add -A >/dev/null 2>&1
git -C "$TREE" commit -qm "fixture: main" || fail "cannot commit the fixture"
MAIN_SHA="$(git -C "$TREE" rev-parse HEAD)"
git -C "$TREE" checkout -q -b feature
printf 'an unmerged change\n' >> "$TREE/README"
git -C "$TREE" commit -qam "fixture: the unmerged change" || fail "cannot commit the feature"
FEATURE_SHA="$(git -C "$TREE" rev-parse HEAD)"
git -C "$TREE" update-ref refs/remotes/origin/main "$MAIN_SHA" || fail "cannot pin origin/main"
git -C "$TREE" checkout -q --detach "$FEATURE_SHA"
[ "$FEATURE_SHA" != "$MAIN_SHA" ] || fail "the fixture did not make two commits"
[ "$(git -C "$TREE" rev-list --count HEAD..origin/main)" = "0" ] \
  || fail "the fixture is behind origin/main, which would refuse earlier and prove nothing about the ancestry rule"

# The toolchain must be absent (so no case can build) and git must be present (so the rules about the tree
# can be answered at all): git's own directory is added to a PATH that would otherwise hold neither.
GIT_BIN="$(dirname "$(command -v git)")"
TEST_PATH="/usr/bin:/bin:$GIT_BIN"
command -v cargo >/dev/null 2>&1 && case "$TEST_PATH" in *"$(dirname "$(command -v cargo)")"*) fail "the fixture PATH would still find cargo" ;; esac

RUN_STATUS=0; RUN_OUT=""; RUN_INSTALL=""
run_deploy() { # label head-sha -> status in RUN_STATUS, output in RUN_OUT
  local label="$1" head="$2" home="$WORK/home-$1" install="$WORK/install-$1"
  mkdir -p "$home" "$install" || fail "cannot stage the private home/install for $label"
  git -C "$TREE" checkout -q --detach "$head" || fail "cannot check out $head"
  RUN_INSTALL="$install"
  RUN_OUT="$WORK/out-$label.txt"
  env -u LOCALAPPDATA -u APPDATA -u USERPROFILE -u WA_PORT -u WA_INSTALL_DIR -u WASM_AGENT_IN_TURN \
    HOME="$home" WASM_AGENT_HOME="$home" PATH="$TEST_PATH" \
    WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$install" \
    WA_PORT=8977 WA_CLIENT_PORT=8978 TMPDIR="$home/tmp" \
    bash "$DEPLOY" --reason "test-deploy-on-main $label" > "$RUN_OUT" 2>&1
  RUN_STATUS=$?
  echo "  [$label] exit $RUN_STATUS"
  sed 's/^/      /' "$RUN_OUT" | head -8
}

# 1. The rule, with the variable that used to waive it set exactly as an operator would set it.
run_deploy unmerged "$FEATURE_SHA"
[ "$RUN_STATUS" -ne 0 ] || fail "a deploy from a commit that is not on origin/main was allowed"
grep -q 'is not on origin/main' "$RUN_OUT" \
  || fail "the refusal does not name the on-main rule: $(tail -3 "$RUN_OUT")"
ok "an unmerged HEAD is refused by name with WA_INSTALL_DIR set" "$(tail -1 "$RUN_OUT" | cut -c1-120)"
[ ! -f "$RUN_INSTALL/installed.txt" ] || fail "a refused deploy wrote an install record"
{ [ ! -f "$RUN_INSTALL/wa.exe" ] && [ ! -f "$RUN_INSTALL/wa" ]; } || fail "a refused deploy placed a binary"
ok "the refused deploy installed nothing" "no installed.txt and no binary in $RUN_INSTALL"

# 2. The control: the same fixture, the same variable, and HEAD IS origin/main. Without this the file could
#    pass by refusing everything.
run_deploy on-main "$MAIN_SHA"
grep -q 'is not on origin/main' "$RUN_OUT" && fail "a HEAD equal to origin/main was refused for not being on it"
grep -q 'refused(cargo_unavailable)' "$RUN_OUT" \
  || fail "the control run did not get past the on-main check: $(tail -3 "$RUN_OUT")"
ok "a HEAD that IS origin/main gets past the check" "it stops later, at refused(cargo_unavailable)"

echo "test-deploy-on-main: ALL PASS ($checks checks; the rule is not waivable by WA_INSTALL_DIR)"
