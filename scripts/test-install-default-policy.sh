#!/usr/bin/env bash
# Does the deploy's default-policy install keep the operator's file and still install one where there
# is none? (`docs/GRANT-POLICY.md`, "The shipped default".)
#
# The rule this pins: a policy file's PRESENCE is what turns the policy layer on
# (`wa-host/src/node_policy.rs`, `Mode`), so the release ships a default that keeps the components of
# this tree working - and it may only ever create that file. An operator's `policy.json` is never
# overwritten, refreshed, renamed or touched, and a default is never installed underneath a path that
# already exists as something else.
#
# Both halves RUN the code the deploy runs (`scripts/lib/install-default-policy.sh`), against scratch
# directories; "untouched" is measured by content, mode and mtime, not by reading the branch.
# Hermetic: temp directories, no cargo, no node, no network.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/lib/install-default-policy.sh"
DEFAULT="$ROOT_DIR/policies/default.json"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"

checks=0
fail() { echo "test-install-default-policy: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }
# File identity for "untouched": content, size, permission bits and mtime. `stat` is GNU here and
# BSD there; either answer is fine, a missing one is not (an unmeasurable file is not "unchanged").
stamp() { # file -> content|size|mode|mtime
  local file="$1" content size mode mtime
  content="$(cksum < "$file")" || fail "cannot read $file"
  size="$(wc -c < "$file" | tr -d ' ')" || fail "cannot size $file"
  mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)"
  mtime="$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)"
  [ -n "$mode" ] && [ -n "$mtime" ] || fail "cannot stat $file"
  printf '%s|%s|%s|%s' "$content" "$size" "$mode" "$mtime"
}

[ -f "$HELPER" ] || fail "no $HELPER to test"
[ -f "$DEFAULT" ] || fail "no $DEFAULT: the release ships no default policy"
[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"
# shellcheck disable=SC1090
. "$HELPER" || fail "cannot source $HELPER"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-default-policy-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# --- the shipped file itself -------------------------------------------------------------------
# The install helper copies bytes, so the JSON is not its business; the parseability is checked where
# it is enforced (`cargo test -p wa-host node_policy::tests`, which also drives the calls the
# components in this tree make). What is checked here is that the file is a file the deploy can name.
[ -s "$DEFAULT" ] || fail "policies/default.json is empty"
grep -q '"version": 1' "$DEFAULT" || fail "policies/default.json does not declare schema version 1"
for component in wa-whatsapp mcp-whatsapp svc-echo mcp-echo; do
  grep -q "\"$component\"" "$DEFAULT" || fail "policies/default.json does not name $component"
done
ok "the shipped default names the components this tree installs"

# --- a node with no policy file gets the default, once ------------------------------------------
NODE="$WORK/fresh/.wasm-agent"
install_default_policy "$DEFAULT" "$NODE/policy.json" > "$WORK/fresh.out" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "installing into an empty state directory answered $status: $(cat "$WORK/fresh.out")"
cmp -s "$DEFAULT" "$NODE/policy.json" || fail "the installed policy is not byte-identical to the shipped default"
ok "a state directory with no policy file gets the default, byte for byte"

# Installing again is a no-op that says "kept", not a second write.
before="$(stamp "$NODE/policy.json")"
install_default_policy "$DEFAULT" "$NODE/policy.json" > "$WORK/again.out" 2>&1 || fail "the second install failed: $(cat "$WORK/again.out")"
grep -q 'kept' "$WORK/again.out" || fail "a second install did not say it kept the file: $(cat "$WORK/again.out")"
[ "$(stamp "$NODE/policy.json")" = "$before" ] || fail "a second install rewrote the policy file"
ok "a second deploy keeps the file it installed"

# --- an operator's policy file is never touched ------------------------------------------------
# The real hazard: the operator ranked their own limits (a lower send cap, an extra chat), and a
# release that "updates the default" would silently widen or narrow them. Content, mode and mtime
# must all survive.
OP="$WORK/operator/.wasm-agent"
mkdir -p "$OP"
printf '%s\n' '{"version":1,"components":{"wa-whatsapp":{"capabilities":{"whatsapp.send":{"allow":["chat:self"],"rate":{"per_minute":3}}}}}}' > "$OP/policy.json"
printf '{"version":1,"components":{}}\n' > "$OP/grant-policy.state.json"
chmod 640 "$OP/policy.json"
# A mtime far enough in the past that a rewrite cannot look like an untouched file.
touch -t 202001020304.05 "$OP/policy.json" 2>/dev/null || true
op_before="$(stamp "$OP/policy.json")"
install_default_policy "$DEFAULT" "$OP/policy.json" > "$WORK/operator.out" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "an existing operator policy made the install answer $status: $(cat "$WORK/operator.out")"
grep -q 'kept' "$WORK/operator.out" || fail "an existing operator policy did not answer 'kept': $(cat "$WORK/operator.out")"
[ "$(stamp "$OP/policy.json")" = "$op_before" ] \
  || fail "the operator's policy file changed (content, size, mode or mtime): $(stamp "$OP/policy.json") vs $op_before"
grep -q 'per_minute":3' "$OP/policy.json" || fail "the operator's own rate limit is gone"
[ ! -e "$OP/policy.json.install.$$" ] || fail "the install left a staged file beside the operator's policy"
ok "an operator's policy.json is kept: content, mode and mtime unchanged"

# Even a broken file is the operator's: the node refuses its sensitive capabilities and says why
# (`Mode::Policy`), and a deploy that replaced it with a default would hide that.
BROKEN="$WORK/broken/.wasm-agent"
mkdir -p "$BROKEN"
printf '{"version":1,"components":{"x":{"capabilities":{"kv.write":{"per_minutes":1}}}}}' > "$BROKEN/policy.json"
install_default_policy "$DEFAULT" "$BROKEN/policy.json" > "$WORK/broken.out" 2>&1 || fail "a broken operator policy made the install fail"
grep -q 'per_minutes' "$BROKEN/policy.json" || fail "a broken operator policy was replaced"
ok "a policy file that does not parse is still the operator's, and is not replaced"

# A path that exists as something else (a directory, or a dangling symlink) is not something to write
# through, and is not ours to remove.
mkdir -p "$WORK/dir/.wasm-agent/policy.json"
install_default_policy "$DEFAULT" "$WORK/dir/.wasm-agent/policy.json" > "$WORK/dir.out" 2>&1 \
  || fail "a directory at the policy path made the install fail: $(cat "$WORK/dir.out")"
[ -d "$WORK/dir/.wasm-agent/policy.json" ] || fail "a directory at the policy path was removed"
ok "a directory at the policy path is left alone"

# --- no default in this tree is a note, not a silently empty install ---------------------------
NOTHING="$WORK/nothing/.wasm-agent"
install_default_policy "$WORK/there-is-no-such-default.json" "$NOTHING/policy.json" > "$WORK/none.out" 2>&1
[ $? -eq 2 ] || fail "a missing default did not answer 2 (nothing installed)"
[ ! -e "$NOTHING/policy.json" ] || fail "a missing default still created a policy file"
ok "a tree without policies/default.json installs nothing and says so"

# --- the deploy calls it, and says why it matters --------------------------------------------
# Structural, and deliberately so: the deploy cannot be run here (it installs). What must not regress
# is that the call exists, that it is the helper, and that the reason for "only if absent" is written
# beside it - the next person to "keep the default fresh" has to delete a paragraph, not a line.
grep -q 'install_default_policy' "$DEPLOY" || fail "deploy.sh no longer installs the default policy"
grep -q 'scripts/lib/install-default-policy.sh' "$DEPLOY" || fail "deploy.sh no longer uses the tested helper"
grep -q 'manifest mode' "$DEPLOY" || fail "deploy.sh no longer says what a node without a policy file does"
grep -q 'policy_unlisted_components' "$DEPLOY" || fail "deploy.sh no longer names installed components the policy does not"
ok "deploy.sh installs the default through the helper and names the unruled components"

# --- a component the shipped default does not name is named ------------------------------------
# This is the sentence that turns "wa-whatsapp stopped writing kv after the upgrade" into a line
# read before the restart: the file exists, so an unlisted component loses its sensitive
# capabilities (no_policy) until a rule is added for it.
COMPONENTS="$WORK/components"
mkdir -p "$COMPONENTS"
: > "$COMPONENTS/wa-whatsapp.wasm"
: > "$COMPONENTS/some-new-component.wasm"
unlisted="$(policy_unlisted_components "$DEFAULT" "$COMPONENTS")"
[ "$unlisted" = "some-new-component" ] || fail "unlisted components answered '$unlisted'"
ok "an installed component the policy does not name is reported"

echo "test-install-default-policy: $checks checks passed"
