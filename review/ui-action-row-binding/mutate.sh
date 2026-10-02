#!/usr/bin/env bash
# One-thing-reverted mutations against the delivery's own scripts/test-ui.ps1.
# Each mutation is applied to THIS worktree's ui/, the test is run, the tree is restored.
# Run from the worktree root.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
echo "worktree: $ROOT"
echo "tree state: $(git status --porcelain | wc -l) modified file(s)"

run_mutation() {
  local name="$1"; shift
  local file="$1"; shift
  python - "$file" "$@" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding='utf-8', newline='').read()
if old not in text:
    print('MUTATION TARGET ABSENT: ' + old[:80]); sys.exit(2)
if text.count(old) != 1:
    print('MUTATION TARGET NOT UNIQUE: %d' % text.count(old)); sys.exit(3)
open(path, 'w', encoding='utf-8', newline='').write(text.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then echo "  !! could not apply $name"; git checkout -- ui/ ; return; fi
  echo "--- mutation: $name"
  echo "    diff:"; git diff --stat -- ui/ | sed 's/^/    /'
  local out
  out=$(powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 2>&1 | tail -6)
  echo "    verdict: $out" | sed 's/^/  /'
  git checkout -- ui/
  echo "    restored: $(git status --porcelain | wc -l) modified file(s)"
}

# M1 - the action row states its own height (an action-specific rule).
run_mutation "M1 the actions get their own height (.chat-control[data-action])" ui/style.css \
".chat-actions { display: flex; align-items: center; gap: var(--gap); }" \
".chat-actions { display: flex; align-items: center; gap: var(--gap); }
.chat-control[data-action] { height: 34px; }"

# M2 - the append-file control stops coming from chatControl() (hand-built, old class).
run_mutation "M2 the append-file control leaves chatControl()" ui/components.js \
'    this._attach = chatControl({ part: "attach", name: "Append a file", title: "Append a file", icon: CHAT_ATTACH_ICON });' \
'    this._attach = document.createElement("button");
    this._attach.type = "button";
    this._attach.className = "icon-btn";
    this._attach.setAttribute("data-part", "attach");
    this._attach.title = "Append a file";
    this._attach.setAttribute("aria-label", "Append a file");
    this._attach.innerHTML = CHAT_ATTACH_ICON;'

# M3 - the child pane builds its own row again.
run_mutation "M3 the pane builds its own row again" ui/components.js \
'    const actions = document.createElement("wa-chat-actions");
    actions.setAttribute("data-slot", "footer-right");
    for (const [action, label] of [["steer", "Steer"], ["cancel", "Cancel task"]]) {
      const declaration = document.createElement("button");
      declaration.type = "button";
      declaration.dataset.action = action;
      declaration.textContent = label;
      actions.append(declaration);
    }' \
'    const actions = document.createElement("div");
    actions.className = "chat-actions";
    for (const [action, label] of [["steer", "Steer"], ["cancel", "Cancel task"]]) {
      const declaration = document.createElement("button");
      declaration.type = "button";
      declaration.className = "chat-action";
      declaration.dataset.action = action;
      declaration.textContent = label;
      actions.append(declaration);
    }'

# M4 - the deleted #steer-only rule comes back.
run_mutation "M4 a #steer-only box rule is restored" ui/style.css \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }' \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }
#steer { border: 1px solid var(--line); border-radius: var(--radius); padding: var(--pad); background: var(--panel-2); color: var(--text); cursor: pointer; }'

# M5 - a higher-specificity rule reaches ONE control (the pane's, inside wa-orchestrator).
run_mutation "M5 a higher-specificity rule moves the pane's control alone" ui/style.css \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }' \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }
wa-orchestrator button[data-action] { padding: var(--space); }'

# M6 - a second, scoped --control-size.
run_mutation "M6 a second --control-size for the row" ui/style.css \
'.chat-actions { display: flex; align-items: center; gap: var(--gap); }' \
'.chat-actions { display: flex; align-items: center; gap: var(--gap); --control-size: 40px; }'

echo "final tree state: $(git status --porcelain | wc -l) modified file(s)"
