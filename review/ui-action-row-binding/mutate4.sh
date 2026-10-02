#!/usr/bin/env bash
# Re-verify battery on the fix tip (c498f93): my two blind spots, the specificity rule that used to
# win, and two of my own mutations that may still slip through.
set -u
cd "$(dirname "$0")/../.." || exit 1
echo "worktree: $(pwd)  tree state: $(git status --porcelain | grep -v '^A ' | wc -l)"

run() { # run <label> <file> <old> <new>
  local label="$1" file="$2" old="$3" new="$4"
  python - "$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding='utf-8', newline='').read()
if text.count(old) != 1:
    print('TARGET NOT UNIQUE/PRESENT (%d)' % text.count(old)); raise SystemExit(2)
open(path, 'w', encoding='utf-8', newline='').write(text.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then echo "--- $label: NOT APPLIED"; return; fi
  echo "--- $label"
  git diff --stat -- ui/ | tail -1 | sed 's/^/    /'
  local out
  out=$(powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 2>&1 | tail -4)
  echo "    verdict: $out"
  git checkout -- ui/
}

ANCHOR='.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }'

run "M7 one control recoloured alone (was a blind spot)" ui/style.css "$ANCHOR" \
"$ANCHOR
wa-orchestrator .chat-control[data-action] { border-color: #ff0000; }"

run "M8 the shared box stated a second time, identical values (was a blind spot)" ui/style.css "$ANCHOR" \
"$ANCHOR
.footer-right .chat-control[data-action] { height: var(--control-size); min-width: var(--control-size); border: 1px solid var(--line); border-radius: var(--radius-sm); }"

run "M5b the higher-specificity rule that used to move the pane's control alone" ui/style.css "$ANCHOR" \
"$ANCHOR
wa-orchestrator .chat-control[data-action] { padding: var(--space); }"

run "M10 MY OWN: margin-top on the pane's controls alone (outside both audited sets)" ui/style.css "$ANCHOR" \
"$ANCHOR
wa-orchestrator .chat-control[data-action] { margin-top: 4px; }"

run "M11 MY OWN: letter-spacing on the pane's controls alone (widens one surface)" ui/style.css "$ANCHOR" \
"$ANCHOR
wa-orchestrator .chat-control[data-action] { letter-spacing: 3px; }"

run "M4 (control) the deleted #steer-only rule restored" ui/style.css "$ANCHOR" \
"$ANCHOR
#steer { border: 1px solid var(--line); border-radius: var(--radius); padding: var(--pad); background: var(--panel-2); color: var(--text); cursor: pointer; }"

echo "final tree state: $(git status --porcelain | grep -v '^A ' | wc -l)"
