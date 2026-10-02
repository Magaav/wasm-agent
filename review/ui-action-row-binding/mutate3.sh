#!/usr/bin/env bash
# M9: a host sets an inline style on ONE control (the main chat's Steer) - the other way left to
# move one box without the other.
set -u
cd "$(dirname "$0")/../.." || exit 1
python - <<'PY' || exit 2
path = 'ui/app.js'
old = "  document.getElementById('steer').hidden=!value;"
new = old + '\n  document.getElementById("steer").style.height="34px";'
text = open(path, encoding='utf-8', newline='').read()
if text.count(old) != 1:
    print('TARGET NOT UNIQUE (%d)' % text.count(old)); raise SystemExit(2)
open(path, 'w', encoding='utf-8', newline='').write(text.replace(old, new, 1))
print('applied inline style mutation')
PY
git diff --stat -- ui/ | sed 's/^/    /'
out=$(powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 2>&1 | tail -4)
echo "    verdict: $out"
git checkout -- ui/
echo "    restored: $(git status --porcelain | wc -l) modified file(s)"
