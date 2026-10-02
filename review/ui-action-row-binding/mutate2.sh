#!/usr/bin/env bash
# Second round: a faithful M3 (the pane's own row, in the place the old code put it), and the
# specificity question - how much does a rule need to win over the shared box, and does the
# delivery's test see it.
set -u
cd "$(dirname "$0")/../.." || exit 1
echo "worktree: $(pwd)  tree state: $(git status --porcelain | wc -l)"

apply() { # apply <file> <old> <new> ... pairs, each triple quoted via python argv
  python - "$@" <<'PY'
import sys
args = sys.argv[1:]
path = args[0]
for i in range(1, len(args), 2):
    old, new = args[i], args[i+1]
    text = open(path, encoding='utf-8', newline='').read()
    if text.count(old) != 1:
        print('TARGET NOT UNIQUE/PRESENT (%d): %r' % (text.count(old), old[:70])); sys.exit(2)
    open(path, 'w', encoding='utf-8', newline='').write(text.replace(old, new, 1))
PY
}

verdict() {
  local out
  out=$(powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 2>&1 | tail -6)
  echo "    verdict: $out"
  git checkout -- ui/
  echo "    restored: $(git status --porcelain | wc -l) modified file(s)"
}

echo "--- M3b the pane builds its own row again, where the old code put it"
apply ui/components.js \
'    const actions = document.createElement("wa-chat-actions");
    actions.setAttribute("data-slot", "footer-right");
    for (const [action, label] of [["steer", "Steer"], ["cancel", "Cancel task"]]) {
      const declaration = document.createElement("button");
      declaration.type = "button";
      declaration.dataset.action = action;
      declaration.textContent = label;
      actions.append(declaration);
    }
    this.shell.append(actions);
' '' \
'    this.shell.host.append(this.preview, this.statusLine, this.notice);
' '    this.shell.host.append(this.preview, this.statusLine, this.notice);
    const actions = document.createElement("div");
    actions.className = "chat-actions";
    for (const [action, label] of [["steer", "Steer"], ["cancel", "Cancel task"]]) {
      const button = document.createElement("button");
      button.type = "button"; button.className = "chat-action"; button.dataset.action = action; button.textContent = label;
      actions.append(button);
    }
    this.shell.footerRight.prepend(actions);
' && { git diff --stat -- ui/ | sed 's/^/    /'; verdict; }

echo "--- M5b a higher-specificity rule that really wins: wa-orchestrator .chat-control[data-action]"
apply ui/style.css \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }' \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }
wa-orchestrator .chat-control[data-action] { padding: var(--space); }' && { git diff --stat -- ui/ | sed 's/^/    /'; verdict; }

echo "--- M7 one control recoloured alone (appearance, not the box) - expected to stay green"
apply ui/style.css \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }' \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }
wa-orchestrator .chat-control[data-action] { border-color: #ff0000; }' && { git diff --stat -- ui/ | sed 's/^/    /'; verdict; }

echo "--- M8 the shared box stated a second time, identical values (a duplicate, not a change)"
apply ui/style.css \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }' \
'.chat-control:disabled:hover { color: var(--muted); border-color: var(--line); }
.footer-right .chat-control[data-action] { height: var(--control-size); min-width: var(--control-size); border: 1px solid var(--line); border-radius: var(--radius-sm); }' && { git diff --stat -- ui/ | sed 's/^/    /'; verdict; }

echo "final tree state: $(git status --porcelain | wc -l)"
