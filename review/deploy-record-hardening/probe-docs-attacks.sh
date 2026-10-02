#!/usr/bin/env bash
# Can `scripts/check-deploy-docs.mjs` be made to PASS while the document is wrong?
#
# Three attacks, each against a PRIVATE copy of the tree (nothing in the worktree is touched):
#   A. the stale claim reworded inside the one paragraph the checker reads;
#   B. the stale claim restored BYTE FOR BYTE two paragraphs later, where the checker never looks;
#   C. a promise of a release-proof lookup added to the SKILL, whose check is two loose regexes.
#
# Usage: bash review/deploy-record-hardening/probe-docs-attacks.sh   (from the repository root)
set -uo pipefail
W="$(cd "$(dirname "$0")/../.." && pwd)"
D="$(mktemp -d "${TMPDIR:-/tmp}/wa-docattack-XXXXXX")"
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/docs" "$D/scripts"
cp -f "$W/docs/RECOVERY-THROUGHPUT.md" "$D/docs/"; cp -f "$W/lane-policy.json" "$D/"; cp -f "$W/scripts/deploy.sh" "$D/scripts/"
mkdir -p "$D/skills"; cp -rf "$W/skills/self-update" "$D/skills/"
cd "$D" || exit 1

echo "=== 0. baseline: the delivered doc ==="
node "$W/scripts/check-deploy-docs.mjs" | tail -1

echo
echo "=== A. the stale claim REWORDED inside the checked paragraph ==="
python - <<'PY'
import io
p='docs/RECOVERY-THROUGHPUT.md'; s=io.open(p,encoding='utf-8',newline='').read()
a='and only then is a tree without a complete exact-tree receipt refused by name.'
assert s.count(a)==1
s=s.replace(a, a+' In practice a deploy looks a discoverable complete proof up for a real Rust source workspace and records what it found, so the receipt is usually present.')
io.open(p,'w',encoding='utf-8',newline='').write(s)
print('   the doc now also says: "a deploy looks a discoverable complete proof up ... and records what it found"')
PY
node "$W/scripts/check-deploy-docs.mjs" | tail -1; echo "   exit=$?"
cp -f "$W/docs/RECOVERY-THROUGHPUT.md" "$D/docs/"

echo
echo "=== B. the ORIGINAL stale sentence, byte for byte, two paragraphs later ==="
python - <<'PY'
import io
p='docs/RECOVERY-THROUGHPUT.md'; s=io.open(p,encoding='utf-8',newline='').read()
a='PID/artifact. No focused receipt authorizes installation.'
assert s.count(a)==1
i=s.index(a)+len(a)
io.open(p,'w',encoding='utf-8',newline='').write(s[:i]+'\n\n`deploy.sh` *looks up* discoverable complete proof for a real Rust source workspace and records\nwhat it found, but does not require it: a deploy is the preview path.\n'+s[i:])
print('   restored verbatim, outside the paragraph the checker slices')
PY
node "$W/scripts/check-deploy-docs.mjs" | tail -1; echo "   exit=$?"
cp -f "$W/docs/RECOVERY-THROUGHPUT.md" "$D/docs/"

echo
echo "=== C. a release-proof lookup promised in the SKILL ==="
python - <<'PY'
import io
p='skills/self-update/SKILL.md'; s=io.open(p,encoding='utf-8',newline='').read()
a='A `final` record is not by itself a finished deploy'
assert s.count(a)==1
s=s.replace(a,'Before landing, deploy.sh looks up a discoverable complete proof receipt for this tree and records what it found beside the install. '+a)
io.open(p,'w',encoding='utf-8',newline='').write(s)
print('   the skill now promises the lookup the code does not do')
PY
node "$W/scripts/check-deploy-docs.mjs" | tail -1; echo "   exit=$?"
echo
echo "Each 'ok' above is the checker accepting a tree whose documentation contradicts the deploy path."
