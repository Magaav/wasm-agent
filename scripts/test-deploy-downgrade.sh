#!/usr/bin/env bash
# Does the gate refuse to replace a newer install with an older tree?
#
# The failure this exists for: a deploy from main replaced an install built from a branch that was AHEAD of
# main, and silently undid three fixes - the in-turn refusal, installed.txt's provenance fields, and the
# sentinel's capture of the upgrade's own output. deploy.sh refused a dirty tree and a tree behind main, and
# had no opinion about the install being replaced, so both deploys were the same command.
#
# The fixture is a commit this tree does not contain, made with `git commit-tree`: its *parent* is HEAD,
# which is exactly the shape of the real incident - the install was ahead of the tree being deployed - and
# it needs nothing outside the repository it runs in.
#
# The test asserts both directions, because a check that refuses everything is as wrong as one that refuses
# nothing: an install that IS an ancestor must get past the check, and the three cases where the gate cannot
# tell (no record, a record with no commit=, a commit this tree does not have) must say so rather than
# refuse. Refusing because the answer is unknown would block the first install on a machine that never had
# one, and "never refuse because you cannot tell" is the rule the check was written to.
#
# Usage:  bash scripts/test-deploy-downgrade.sh
# Needs:  a clean tree that is not behind origin/main (the gate checks both first), and git. No build: every
#         case stops at or before the build, so this runs in about a second.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEPLOY="${WA_DEPLOY_SH:-$ROOT/scripts/deploy.sh}"
LIVE_INSTALL="${WA_LIVE_INSTALL_DIR:-${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}}"
[ -d "$LIVE_INSTALL" ] || LIVE_INSTALL="$HOME/.local/share/wasm-agent"
# Snapshotted before anything runs, so the isolation assertion compares against the state this test found.
LIVE_HASH_BEFORE="$(sha256sum < "$LIVE_INSTALL/wa.exe" 2>/dev/null | awk '{print $1}')"
LIVE_RECORD_BEFORE="$(cat "$LIVE_INSTALL/installed.txt" 2>/dev/null)"

checks=0
failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }

# The gate asks about the tree before it asks about the install, so this test needs a tree that passes those
# two questions. Exit 3, not 1: this is "the check could not be reached in this tree", which is a skip and is
# reported as one - the suite counts it instead of printing the verdict a run that tested something prints.
# It is not inferred from a missing tool; it is the tree's own state.
DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
BEHIND="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo unknown)"
if [ "$DIRTY" != "0" ] || { [ "$BEHIND" != "unknown" ] && [ "$BEHIND" != "0" ]; }; then
  echo "deploy downgrade gate SKIPPED - needs a clean tree that is not behind origin/main (here: $DIRTY uncommitted file(s), $BEHIND commit(s) behind)"
  exit 3
fi

S="$(mktemp -d)"
FIXTURE_REF="refs/wasm-agent-test/downgrade-$$"
cleanup() {
  # The fixture commit is kept reachable by a ref while the test runs, so no gc can prune it mid-run; the
  # ref goes away with the test.
  git update-ref -d "$FIXTURE_REF" 2>/dev/null
  rm -rf "$S"
}
trap cleanup EXIT

mkdir -p "$S/install" "$S/home"

NEWER="$(printf 'fixture: an install ahead of this tree\n' | git commit-tree "$(git rev-parse HEAD^{tree})" -p HEAD)"
git update-ref "$FIXTURE_REF" "$NEWER"
HEAD_COMMIT="$(git rev-parse --short HEAD)"
ANCESTOR="$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)"
UNKNOWN_COMMIT="0123456789abcdef0123456789abcdef01234567"

# The installed binary is a placeholder and deliberately not executable. If the check is missing, the run
# continues into the build and then stops at upgrade.sh's "nothing installed" - so a missing check makes this
# test fail on its assertions instead of starting a node and swapping a binary underneath it.
printf 'placeholder installed binary\n' > "$S/install/wa.exe"
PLACEHOLDER_HASH="$(sha256sum < "$S/install/wa.exe" | awk '{print $1}')"

write_record() { printf 'commit=%s\nbranch=fixture\nsha256=deadbeef\nat=1970-01-01T00:00:00Z\nreason=fixture\n' "$1" > "$S/install/installed.txt"; }

# Run the gate against the fixture install. `env -u WASM_AGENT_IN_TURN` because this test is often run from
# inside a turn, and the gate refuses there first - the subject here is the downgrade check, not that one.
# The narrowed PATH keeps the cases that legitimately get past the check from spending a real cargo build:
# they must reach the build, not complete it.
last_exit=0
last_out=""
run_deploy() {
  ( cd "$ROOT" && env -u WASM_AGENT_IN_TURN PATH="$(dirname "$(command -v git)"):/usr/bin:/bin" \
      WA_INSTALL_DIR="$S/install" WA_PORT=18991 WA_CLIENT_PORT=18992 \
      bash "$DEPLOY" --reason "downgrade gate test" ) >"$S/out.txt" 2>&1
  last_exit=$?
  last_out="$(cat "$S/out.txt")"
}

# --- 1. the install is ahead of this tree: refuse, and name both commits --------------------------
printf 'fixture commit ahead of this tree: %s (this tree: %s)\n' "$(git rev-parse --short "$NEWER")" "$HEAD_COMMIT"
write_record "$NEWER"
: > "$S/install/deploy.log"
run_deploy
# The refusal line itself is what gets asserted against, not the whole output: the banner line prints this
# tree's commit on every run, so a test that greps the output as a whole passes without the check.
REFUSAL="$(grep -m1 'downgrade refused' <<<"$last_out")"
ok "$([ "$last_exit" != "0" ] && grep -q 'downgrade refused' <<<"$last_out" && echo 1 || echo 0)" \
  "a tree that does not contain the installed commit is refused, for that reason" "exit $last_exit"
ok "$([ -n "$REFUSAL" ] && echo 1 || echo 0)" "the refusal says what it is" "${REFUSAL:0:120}"
ok "$(grep -q "$(git rev-parse --short "$NEWER")" <<<"$REFUSAL" && echo 1 || echo 0)" "it names the installed commit"
ok "$(grep -q "$HEAD_COMMIT" <<<"$REFUSAL" && echo 1 || echo 0)" "it names this tree's commit"
ok "$(grep -q 'running turn' <<<"$last_out" && echo 0 || echo 1)" "and it is the downgrade check that refused, not the turn guard"
ok "$(grep -q 'downgrade refused' "$S/install/deploy.log" 2>/dev/null && echo 1 || echo 0)" "the refusal is recorded in deploy.log" "$(tail -1 "$S/install/deploy.log" 2>/dev/null | cut -c1-90)"
ok "$([ "$(sha256sum < "$S/install/wa.exe" | awk '{print $1}')" = "$PLACEHOLDER_HASH" ] && echo 1 || echo 0)" "the installed binary was not touched"
ok "$(grep -q 'deploy: building' <<<"$last_out" && echo 0 || echo 1)" "and nothing was built" "it refused before the build"

# --- 2. the install is an ancestor: this must get past the check -----------------------------------
write_record "$ANCESTOR"
run_deploy
ok "$(grep -q 'downgrade refused' <<<"$last_out" && echo 0 || echo 1)" "an ancestor in the record is not a downgrade" "record $ANCESTOR"
ok "$(grep -q 'deploy: building' <<<"$last_out" && echo 1 || echo 0)" "it got past the check and reached the build"
ok "$([ "$(sha256sum < "$S/install/wa.exe" | awk '{print $1}')" = "$PLACEHOLDER_HASH" ] && echo 1 || echo 0)" "the installed binary is still untouched"

# --- 3. no record at all: a first install, not a downgrade ----------------------------------------
rm -f "$S/install/installed.txt"
: > "$S/install/deploy.log"
run_deploy
ok "$(grep -q 'downgrade refused' <<<"$last_out" && echo 0 || echo 1)" "a missing record is not a downgrade"
ok "$(grep -q 'first install, not a downgrade' <<<"$last_out" && echo 1 || echo 0)" "it says which case it is" "$(grep -m1 'first install' <<<"$last_out")"

# --- 4. a record with no commit= line: say so, do not guess ---------------------------------------
printf 'branch=fixture\nsha256=deadbeef\nat=1970-01-01T00:00:00Z\n' > "$S/install/installed.txt"
: > "$S/install/deploy.log"
run_deploy
ok "$(grep -q 'downgrade refused' <<<"$last_out" && echo 0 || echo 1)" "a record without commit= is not a downgrade"
ok "$(grep -q 'names no commit' <<<"$last_out" && echo 1 || echo 0)" "it says the record does not say" "$(grep -m1 'names no commit' <<<"$last_out" | cut -c1-100)"
ok "$(grep -q 'note: ' "$S/install/deploy.log" 2>/dev/null && echo 1 || echo 0)" "and the note is recorded, so a blind gate is visible afterwards"

# --- 5. a commit this tree does not have: say which case, do not refuse on ignorance ---------------
write_record "$UNKNOWN_COMMIT"
: > "$S/install/deploy.log"
run_deploy
ok "$(grep -q 'downgrade refused' <<<"$last_out" && echo 0 || echo 1)" "an unresolvable commit is not a downgrade" "record $UNKNOWN_COMMIT"
ok "$(grep -q 'does not have' <<<"$last_out" && echo 1 || echo 0)" "it names the case (shallow clone, other repo, unfetched branch)" "$(grep -m1 'does not have' <<<"$last_out" | cut -c1-110)"
ok "$(grep -q 'note: ' "$S/install/deploy.log" 2>/dev/null && echo 1 || echo 0)" "and it is recorded as a note, not as a refusal"

# --- 6. isolation: the real install was never the fixture's business -------------------------------
if [ -x "$LIVE_INSTALL/wa.exe" ] || [ -f "$LIVE_INSTALL/installed.txt" ]; then
  ok "$([ "$(sha256sum < "$LIVE_INSTALL/wa.exe" 2>/dev/null | awk '{print $1}')" = "$LIVE_HASH_BEFORE" ] && echo 1 || echo 0)" \
    "the live install's binary is unchanged" "$LIVE_INSTALL"
  ok "$([ "$(cat "$LIVE_INSTALL/installed.txt" 2>/dev/null)" = "$LIVE_RECORD_BEFORE" ] && echo 1 || echo 0)" \
    "and so is its record"
else
  echo "  note: no live install at $LIVE_INSTALL - the isolation assertion is about the fixture only"
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
  echo "deploy downgrade gate ok ($checks checks)"
else
  echo "deploy downgrade gate FAILED ($failed of $checks)"
fi
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"
