#!/usr/bin/env bash
# Direct measurement of the real deploy.sh, no extraction, no structural reading: does =0 / =false / =off
# keep the proof lookup OFF, and does =true turn it ON? Private installs, no cargo.
set -uo pipefail
REPO="$1"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-knob-XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/tree"; mkdir -p "$TREE/rust" "$TREE/scripts"
printf 'the tree\n' > "$TREE/README"; printf '[package]\nname="fixture"\n' > "$TREE/rust/Cargo.toml"
git -C "$TREE" init -q --initial-branch=main; git -C "$TREE" config user.name f; git -C "$TREE" config user.email f@x.invalid
git -C "$TREE" add -A >/dev/null 2>&1; git -C "$TREE" commit -qm fixture
git -C "$TREE" update-ref refs/remotes/origin/main "$(git -C "$TREE" rev-parse HEAD)"
GIT_BIN="$(dirname "$(command -v git)")"
for V in UNSET 0 false off no 1 true on; do
  INSTALL="$WORK/install-$V"; HOMED="$WORK/home-$V"; mkdir -p "$INSTALL" "$HOMED"
  if [ "$V" = UNSET ]; then ENVV="env -u WA_DEPLOY_REQUIRE_RELEASE_PROOF"; else ENVV="env WA_DEPLOY_REQUIRE_RELEASE_PROOF=$V"; fi
  ( cd "$TREE" && env -u WASM_AGENT_IN_TURN HOME="$HOMED" WASM_AGENT_HOME="$HOMED" PATH="/usr/bin:/bin:$GIT_BIN" \
      WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$INSTALL" WA_PORT=8991 WA_CLIENT_PORT=8992 $ENVV \
      bash "$REPO/scripts/deploy.sh" --reason "knob-direct $V" > "$WORK/out-$V.txt" 2>&1 ); ST=$?
  KIND="reached the build (proof NOT consulted)"; grep -q 'WA_DEPLOY_REQUIRE_RELEASE_PROOF is set' "$WORK/out-$V.txt" && KIND="REFUSED for the release proof"
  printf '  WA_DEPLOY_REQUIRE_RELEASE_PROOF=%-6s exit=%-3s %s\n' "$V" "$ST" "$KIND"
done
echo "  (the OFF runs' last line: $(tail -1 "$WORK/out-0.txt" | cut -c1-95))"
echo "  (the ON  run's last line: $(tail -1 "$WORK/out-true.txt" | cut -c1-95))"
