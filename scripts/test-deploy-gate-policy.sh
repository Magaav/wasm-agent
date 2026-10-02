#!/usr/bin/env bash
# Does `deploy.sh` still refuse when it is asked to, and *not* refuse when it is not?
#
# The policy this pins (2026-10-02): the full gate is a RELEASE's, not a deploy's, so a deploy builds,
# proves the binary answers on a scratch port and installs it - and it records whether the tree carried
# a complete exact-tree release proof instead of refusing without one. `WA_DEPLOY_REQUIRE_RELEASE_PROOF=1`
# restores the old refusal for whoever wants it, and it is never selected automatically.
#
# Both halves are tested by RUNNING the block, not by describing it: the proof block is read out of
# `deploy.sh` between its own markers, given a scratch ROOT that is a real Git repository with a real
# `rust/Cargo.toml`, and executed with the deploy's own `fail`/`note` functions. The proof lookup is the
# real `scripts/lib/full-gate-proof.mjs`, so "there is no receipt" is the verifier's own answer.
#
# Hermetic: a temp repository per run, no cargo, no network, no sentinel, no model.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"

fail() { echo "test-deploy-gate-policy: $*" >&2; exit 1; }

[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"
# The block starts at its own heading and ends at the first unindented `fi` - the outer one of the
# proof `if`, because the nested `if` bodies are indented.
BLOCK="$(awk '/^# 4\. Build\.$/{on=1} on{print} on && /^fi$/{exit}' "$DEPLOY")"
printf '%s' "$BLOCK" | grep -q 'full-gate-proof.mjs' || fail "could not read the proof block out of deploy.sh (the marker moved?)"
printf '%s' "$BLOCK" | grep -q 'WA_DEPLOY_REQUIRE_RELEASE_PROOF' || fail "the strict knob is gone from the proof block"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-gate-policy-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# A scratch ROOT that looks like this repository where it matters: a Git tree with a commit, the real
# proof script, and a Rust workspace (which is what makes the block run at all).
SCRATCH="$WORK/root"
mkdir -p "$SCRATCH/scripts/lib" "$SCRATCH/rust" || fail "cannot stage a scratch tree"
cp -f "$ROOT_DIR/scripts/lib/full-gate-proof.mjs" "$SCRATCH/scripts/lib/" || fail "cannot stage the proof script"
printf '[workspace]\n' > "$SCRATCH/rust/Cargo.toml"
git -C "$SCRATCH" init -q --initial-branch=main || fail "cannot init the scratch repository"
git -C "$SCRATCH" add -A >/dev/null 2>&1
git -C "$SCRATCH" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture: a source tree" || fail "cannot commit the scratch tree"

run_block() { # strict(0|1) -> the block's output; its exit status is the deploy's own
  local strict="$1" wrapper="$WORK/run.sh"
  {
    echo 'set -uo pipefail'
    echo "ROOT=\"$SCRATCH\""
    # The block resolves the tree with `git rev-parse HEAD^{tree}` in its CURRENT directory, and the proof
    # lookup walks that repository's worktrees. Without this the fixture would read whichever repository
    # the caller happened to be in - and a real receipt for that tree would make these assertions about a
    # scratch tree pass or fail on the state of somebody else's checkout.
    echo "cd \"$SCRATCH\" || exit 3"
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    echo 'note() { echo "NOTE: $*"; }'
    printf '%s\n' "$BLOCK"
    echo 'echo "CONTINUED"'
  } > "$wrapper"
  if [ "$strict" = 1 ]; then WA_DEPLOY_REQUIRE_RELEASE_PROOF=1 bash "$wrapper" 2>&1; else bash "$wrapper" 2>&1; fi
}

# 1. Default: no release proof for this tree, and the deploy goes on - naming what it did not verify.
DEFAULT_OUT="$(run_block 0)"; DEFAULT_STATUS=$?
echo "$DEFAULT_OUT" | sed 's/^/    /'
[ "$DEFAULT_STATUS" = 0 ] || fail "a deploy without a release proof was refused (status $DEFAULT_STATUS)"
# The scratch repository is the one under test: if the block resolved its tree anywhere else, the
# scratch's own tree would not appear here and the next assertions would prove nothing about it.
SCRATCH_TREE="$(git -C "$SCRATCH" rev-parse 'HEAD^{tree}')"
echo "$DEFAULT_OUT" | grep -q "$SCRATCH_TREE" || fail "the block did not resolve the scratch tree $SCRATCH_TREE (harmless path resolution?) "
echo "$DEFAULT_OUT" | grep -q '^CONTINUED$' || fail "the block did not reach the build"
echo "$DEFAULT_OUT" | grep -qi 'REFUSED' && fail "the default path refused"
echo "$DEFAULT_OUT" | grep -q 'not release-verified' || fail "the default path did not RECORD that the tree is not release-verified"
echo "$DEFAULT_OUT" | grep -q '"verified":false' || fail "the refusal reason was not carried into the note"

# 2. Strict: the same tree, the same absence of proof, and now it is refused BY NAME.
STRICT_OUT="$(run_block 1)"; STRICT_STATUS=$?
echo "$STRICT_OUT" | sed 's/^/    /'
[ "$STRICT_STATUS" = 3 ] || fail "WA_DEPLOY_REQUIRE_RELEASE_PROOF=1 did not refuse (status $STRICT_STATUS)"
echo "$STRICT_OUT" | grep -q 'REFUSED: complete gate proof required' || fail "the strict refusal does not name the missing proof"
echo "$STRICT_OUT" | grep -q 'WA_DEPLOY_REQUIRE_RELEASE_PROOF is set' || fail "the strict refusal does not say which knob refused"
echo "$STRICT_OUT" | grep -q '^CONTINUED$' && fail "the strict path continued past the refusal"

echo "deploy gate policy ok (default deploys as a preview and records it; the strict knob refuses by name)"
