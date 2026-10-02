#!/usr/bin/env bash
# The mutation battery of the deploy-unbound review (8 red, 1 green = a gap).
# Run from a scratch clone at the tip:  bash mutations.sh <scratch-clone>
set -uo pipefail
C="${1:?usage: mutations.sh <scratch-clone>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$C" || exit 1
run() { # suite...
  local out st; out="$("$@" 2>&1)"; st=$?
  printf '  exit=%s last=[%s]\n' "$st" "$(printf '%s\n' "$out" | tail -2 | tr '\n' '|' | cut -c1-200)"
}
spec() { node -e "$1" > /tmp/mut-spec.json && node "$HERE/mutate.mjs" "$C" "$(cat /tmp/mut-spec.json)" || { echo "MUTATION DID NOT LAND - stopping"; exit 9; }; }
rep() { git -C "$C" checkout -q -- .; }

echo "=== M1: the deploy's own record says via=upgrade.sh (a field, not the structure) ==="
spec 'const BS=String.fromCharCode(92);console.log(JSON.stringify([{file:"scripts/deploy.sh",from:"record_role=final"+BS+"nvia=deploy.sh",to:"record_role=final"+BS+"nvia=upgrade.sh"}]))'
run bash scripts/test-deploy-record.sh; rep

echo "=== M2: the early record_installed call removed (only the last act writes) ==="
spec 'const NL=String.fromCharCode(10);console.log(JSON.stringify([{file:"scripts/deploy.sh",from:NL+"record_installed"+NL+NL+"# Ship one file beside",to:NL+NL+"# Ship one file beside"}]))'
run bash scripts/test-deploy-record.sh; rep

echo "=== M3: a comment moved back INSIDE the invocation continuation ==="
spec 'const BS=String.fromCharCode(92),NL=String.fromCharCode(10);console.log(JSON.stringify([{file:"scripts/deploy.sh",from:"  WA_UPGRADE_REASON=\"$REASON\" WA_UPGRADE_VIA=deploy.sh "+BS+NL+"  bash \"$UPGRADE\"",to:"  WA_UPGRADE_REASON=\"$REASON\" WA_UPGRADE_VIA=deploy.sh "+BS+NL+"  # a comment that must not be here"+NL+"  bash \"$UPGRADE\""}]))'
run bash scripts/test-deploy-record.sh; rep

echo "=== M4a: ship_file reverted to an in-place cp over the destination ==="
spec 'const NL=String.fromCharCode(10);console.log(JSON.stringify([{file:"scripts/deploy.sh",from:"  staged=\"$destination.ship.$$\"\n  cp -f \"$source\" \"$staged\" || { rm -f \"$staged\"; fail \"node installed, but could not stage $what\"; }\n  if mv -f \"$staged\" \"$destination\" && cmp -s \"$source\" \"$destination\"; then\n    return 0\n  fi\n  rm -f \"$staged\"\n",to:"  cp -f \"$source\" \"$destination\" || fail \"node installed, but could not ship $what\"\n"}]))'
run bash scripts/test-deploy-self-ship.sh; rep

echo "=== M4b: the helper rewrites the destination in place AND stages+renames ==="
spec 'console.log(JSON.stringify([{file:"scripts/deploy.sh",from:"  staged=\"$destination.ship.$$\"\n",to:"  cp -f \"$source\" \"$destination\" 2>/dev/null || true\n  staged=\"$destination.ship.$$\"\n"}]))'
run bash scripts/test-deploy-self-ship.sh; rep

echo "=== M5: the knob no longer guards the lookup, but its text is still there ==="
spec 'console.log(JSON.stringify([{file:"scripts/deploy.sh",from:"if [ -n \"${WA_DEPLOY_REQUIRE_RELEASE_PROOF:-}\" ] && [ -f \"$ROOT/rust/Cargo.toml\" ]; then",to:"if [ -n \"${WA_DEPLOY_REQUIRE_RELEASE_PROOF:-}\" ] || [ -f \"$ROOT/rust/Cargo.toml\" ]; then"}]))'
run bash scripts/test-deploy-gate-policy.sh; rep

echo "=== M6: upgrade.sh always records final (no role ownership) ==="
spec 'console.log(JSON.stringify([{file:"scripts/upgrade.sh",from:"  if [ \"$via\" = \"deploy.sh\" ]; then role=interim; else role=final; fi\n",to:"  role=final\n"}]))'
run bash scripts/test-deploy-record.sh; rep

echo "=== M7: verify-install.sh calls an interim record ok ==="
spec 'console.log(JSON.stringify([{file:"scripts/verify-install.sh",from:"    interim) record fail \"the install record is its owner\u0027s final one\" \\",to:"    interim) record ok \"the install record is its owner\u0027s final one\" \\"}]))'
run node scripts/test-verify-install.mjs; rep

echo "=== M8: the record step writes installed.txt NON-atomically (expected GREEN: the gap) ==="
spec 'const BS=String.fromCharCode(92),NL=String.fromCharCode(10);console.log(JSON.stringify([{file:"scripts/deploy.sh",from:"    > \"$record_tmp\" && mv -f \"$record_tmp\" \"$INSTALL_DIR/installed.txt\" "+BS+NL+"    || fail",to:"    > \"$INSTALL_DIR/installed.txt\" "+BS+NL+"    || fail"}]))'
run bash scripts/test-deploy-record.sh; rep
echo "--- restored: $(git -C "$C" status --porcelain | wc -l) dirty files ---"
