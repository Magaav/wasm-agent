#!/usr/bin/env bash
# Does `deploy.sh` consult a release proof only when it is asked to?
#
# The policy this pins (2026-10-02, after the owner's "deploy should not be bound to the release gate"):
# release and deploy are two stages. A deploy installs what origin/main carries, now, and it does not look a
# release up at all - speed is the default path - while `scripts/wave-release.mjs` is what runs the full gate
# and names the exact tree it certified. `WA_DEPLOY_REQUIRE_RELEASE_PROOF=1` is the only way to ask for the
# strict path, and there the deploy is refused by name when the tree carries no proof.
#
# Both halves are tested by RUNNING the block, not by describing it: the proof block is read out of
# `deploy.sh` between its own markers and given a scratch ROOT that is a real Git repository with a real
# `rust/Cargo.toml`. The proof script is a POISONED stand-in that writes a marker file when it is invoked,
# so "the default does not look a release up" is measured by the ABSENCE of that marker rather than by
# reading the branch that would have run it.
#
# Hermetic: a temp repository per run, no cargo, no network, no sentinel, no model.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"

checks=0
fail() { echo "test-deploy-gate-policy: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }

[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"
# The block starts at its own heading and ends at the first unindented `fi` - the outer one of the
# proof `if`, because the nested `if` bodies are indented.
BLOCK="$(awk '/^# 4\. Build\.$/{on=1} on{print} on && /^fi$/{exit}' "$DEPLOY")"
printf '%s' "$BLOCK" | grep -q 'full-gate-proof.mjs' || fail "could not read the proof block out of deploy.sh (the marker moved?)"
printf '%s' "$BLOCK" | grep -q 'WA_DEPLOY_REQUIRE_RELEASE_PROOF' || fail "the strict knob is gone from the proof block"
# The lookup must sit BEHIND the knob, not beside it, and the knob must be read by VALUE (finding F5 of the
# review of change/deploy-unbound: the guard used to be `-n "${WA_DEPLOY_REQUIRE_RELEASE_PROOF:-}"`, so
# `=0` was truthy and an operator who wrote 0 to say "off" got the strict path). These are structural
# readings; the cases below measure the behaviour.
printf '%s' "$BLOCK" | grep -q '1|true|yes|on) REQUIRE_PROOF=1' \
  || fail "the proof block no longer reads the knob by value (only 1/true/yes/on may be ON)"
printf '%s' "$BLOCK" | grep -q 'if \[ "$REQUIRE_PROOF" = "1" \]' \
  || fail "the proof lookup is no longer guarded by the value-read knob"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-gate-policy-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# A scratch ROOT that looks like this repository where it matters: a Git tree with a commit, a Rust
# workspace (which is what makes the block run at all), and a poisoned proof lookup that records that it ran.
SCRATCH="$WORK/root"
mkdir -p "$SCRATCH/scripts/lib" "$SCRATCH/rust" || fail "cannot stage a scratch tree"
printf '[workspace]\n' > "$SCRATCH/rust/Cargo.toml"
cat > "$SCRATCH/scripts/lib/full-gate-proof.mjs" <<'POISON'
#!/usr/bin/env node
// A POISONED stand-in for the real proof lookup: being invoked is the observation.
import fs from 'node:fs';
if (process.env.WA_TEST_PROOF_MARKER) fs.writeFileSync(process.env.WA_TEST_PROOF_MARKER, `${process.argv.slice(2).join(' ')}\n`);
console.log(JSON.stringify({verified: false, reason: 'poisoned stand-in: this fixture has no release receipt'}));
POISON
git -C "$SCRATCH" init -q --initial-branch=main || fail "cannot init the scratch repository"
git -C "$SCRATCH" add -A >/dev/null 2>&1
git -C "$SCRATCH" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture: a source tree" || fail "cannot commit the scratch tree"

run_block() { # knob-value-or-EMPTY -> the block's output; its exit status is the deploy's own
  local knob="$1" wrapper="$WORK/run.sh"
  rm -f "$WORK/proof-was-invoked"
  {
    echo 'set -uo pipefail'
    echo "ROOT=\"$SCRATCH\""
    # The block resolves the tree with `git rev-parse HEAD^{tree}` in its CURRENT directory, and the proof
    # lookup walks that repository's worktrees. Without this the fixture would read whichever repository the
    # caller happened to be in - and a real receipt for that tree would make these assertions about a scratch
    # tree pass or fail on the state of somebody else's checkout.
    echo "cd \"$SCRATCH\" || exit 3"
    echo "export WA_TEST_PROOF_MARKER=\"$WORK/proof-was-invoked\""
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    echo 'note() { echo "NOTE: $*"; }'
    printf '%s\n' "$BLOCK"
    echo 'echo "CONTINUED"'
  } > "$wrapper"
  if [ -n "$knob" ]; then WA_DEPLOY_REQUIRE_RELEASE_PROOF="$knob" bash "$wrapper" 2>&1; else bash "$wrapper" 2>&1; fi
}

# 1. Default: the release proof is NOT consulted - not looked up and not refused about - and the deploy goes
#    on to the build. The marker is the measurement: a poisoned lookup records its own invocation.
DEFAULT_OUT="$(run_block '')"; DEFAULT_STATUS=$?
echo "$DEFAULT_OUT" | sed 's/^/    /'
[ "$DEFAULT_STATUS" = 0 ] || fail "a deploy with no release proof was refused (status $DEFAULT_STATUS)"
echo "$DEFAULT_OUT" | grep -q '^CONTINUED$' || fail "the block did not reach the build"
echo "$DEFAULT_OUT" | grep -qi 'REFUSED' && fail "the default path refused"
DIRECT_INVOKED=0
[ -f "$WORK/proof-was-invoked" ] && DIRECT_INVOKED=1
[ "$DIRECT_INVOKED" = "0" ] || fail "the DEFAULT deploy consulted a release proof: the lookup ran and recorded [$(cat "$WORK/proof-was-invoked")]"
echo "$DEFAULT_OUT" | grep -q 'release proof' && fail "the default path still reports on a release proof it was not asked about"
ok "the default deploy does not consult a release proof" "the poisoned proof lookup was never invoked"
DIRECT_INVOKED=0

# 2. Strict: the same tree, the same absence of proof, and now the lookup runs and refuses BY NAME.
STRICT_OUT="$(run_block 1)"; STRICT_STATUS=$?
echo "$STRICT_OUT" | sed 's/^/    /'
[ "$STRICT_STATUS" = 3 ] || fail "WA_DEPLOY_REQUIRE_RELEASE_PROOF=1 did not refuse (status $STRICT_STATUS)"
[ -f "$WORK/proof-was-invoked" ] || fail "the strict path refused without ever consulting the proof lookup"
ok "the strict path consults the proof lookup when the knob is set" "it was invoked with $(cat "$WORK/proof-was-invoked")"
echo "$STRICT_OUT" | grep -q 'REFUSED: complete gate proof required' || fail "the strict refusal does not name the missing proof"
echo "$STRICT_OUT" | grep -q 'WA_DEPLOY_REQUIRE_RELEASE_PROOF is set' || fail "the strict refusal does not say which knob refused"
echo "$STRICT_OUT" | grep -q '^CONTINUED$' && fail "the strict path continued past the refusal"
ok "the strict path refuses a tree with no release proof, naming the knob" "complete gate proof required for source tree …"

# 3. The value, not the emptiness. Every OFF value must behave exactly like unset, and every ON value must
#    refuse by name - measured with the same poisoned lookup, so "did not consult it" is an observation.
assert_off() { # value
  local value="$1" out status
  out="$(run_block "$value")"; status=$?
  [ "$status" = 0 ] || fail "WA_DEPLOY_REQUIRE_RELEASE_PROOF=$value was treated as ON (status $status): $out"
  [ -f "$WORK/proof-was-invoked" ] && fail "WA_DEPLOY_REQUIRE_RELEASE_PROOF=$value consulted the release proof"
  echo "$out" | grep -q '^CONTINUED$' || fail "WA_DEPLOY_REQUIRE_RELEASE_PROOF=$value did not reach the build: $out"
  ok "WA_DEPLOY_REQUIRE_RELEASE_PROOF=$value is OFF" "read by value: the proof lookup was not invoked"
}
assert_on() { # value
  local value="$1" out status
  out="$(run_block "$value")"; status=$?
  [ "$status" = 3 ] || fail "WA_DEPLOY_REQUIRE_RELEASE_PROOF=$value did not refuse (status $status): $out"
  echo "$out" | grep -q 'REFUSED: complete gate proof required' || fail "WA_DEPLOY_REQUIRE_RELEASE_PROOF=$value refused with other words: $out"
  ok "WA_DEPLOY_REQUIRE_RELEASE_PROOF=$value is ON" "refused by name after consulting the lookup"
}
assert_off 0
assert_off false
assert_off off
assert_on true
assert_on on

echo "test-deploy-gate-policy: ALL PASS ($checks checks; the default never looks a release up, the knob refuses by name)"
