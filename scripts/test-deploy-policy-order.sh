#!/usr/bin/env bash
# The deploy's ordering contract, checked by reading the script (`docs/KERNEL.md`, "the 06/11 bug").
#
# A deploy that installs `policy.json` *after* the node restart leaves the node on the policy it loaded
# at start-up: on 06/11 the node started at 14:55:13, the file was written at 14:55:37, and every
# WhatsApp send was refused from then on with nothing on the node saying why. The order is therefore a
# contract, not an incidental sequence, and an ordering contract is exactly the kind of thing that gets
# undone by a refactor that "tidies up" the tail of a 1,500-line script.
#
# What this checks (no network, no node, no build):
#   1. the script parses (`bash -n`);
#   2. the policy installer runs before `bash "$UPGRADE"` (which is the restart);
#   3. the installer is still guarded (never a refusal of the deploy) and still says so out loud when it
#      does not install;
#   4. the reload watcher exists in the kernel and is what the second half of the fix is - the source
#      check, because a deploy is not the only thing that can write the file.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEPLOY="$ROOT/scripts/deploy.sh"
fails=0
checks=0
ok() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }
line_of() { grep -n -- "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1; }

[ -f "$DEPLOY" ] || { echo "FAIL no deploy.sh at $DEPLOY"; exit 1; }

if bash -n "$DEPLOY" 2>/dev/null; then ok "deploy.sh parses"; else bad "deploy.sh does not parse"; fi

install_line=$(line_of 'install_default_policy "\$ROOT/policies/default.json"' "$DEPLOY")
upgrade_line=$(line_of 'bash "\$UPGRADE" "\$CANDIDATE"' "$DEPLOY")
if [ -n "$install_line" ] && [ -n "$upgrade_line" ]; then
  if [ "$install_line" -lt "$upgrade_line" ]; then
    ok "policy.json is installed (line $install_line) before the restart (line $upgrade_line)"
  else
    bad "policy.json is installed at line $install_line, AFTER the restart at line $upgrade_line - a node would keep the old policy"
  fi
else
  bad "could not find the policy install (${install_line:-missing}) or the upgrade invocation (${upgrade_line:-missing})"
fi

# The installer must stay a *best effort* with a visible outcome: a deploy must not refuse because a
# policy could not be installed (a node with no policy file runs in manifest mode), and it must say so.
for needle in \
  'policy.json was not installed; the node runs in manifest mode' \
  'policy.json could not be installed at'; do
  if grep -qF -- "$needle" "$DEPLOY"; then ok "a failed install is reported: ${needle:0:40}…"; else bad "no report for: $needle"; fi
done

# The second fix: the node reloads the file. A source check, so the claim in the comment above cannot rot.
POLICY_RS="$ROOT/rust/wa-governance/src/node_policy.rs"
if [ -f "$POLICY_RS" ]; then
  for needle in 'pub fn reload' 'fn fingerprint' 'set_policy(policy)' 'wa-policy-reload'; do
    if grep -qF -- "$needle" "$POLICY_RS"; then ok "policy reload present: $needle"; else bad "policy reload missing: $needle"; fi
  done
else
  bad "no rust/wa-governance/src/node_policy.rs to check the reload against"
fi

printf '\ndeploy policy order: %s (%s checks)\n' "$([ "$fails" -eq 0 ] && echo ok || echo FAILED)" "$checks"
[ "$fails" -eq 0 ]
