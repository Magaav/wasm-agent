#!/usr/bin/env bash
# Second mutation pass: the blind spot the first pass found. M5 (a ::before glyph on the pane's labelled
# controls) went RED because the glyph widened the button and the property-for-property diff saw `width`.
# These two narrow the same blind spot to a control whose own computed style the glyph does not change, and
# to a state selector - both of which the delivered audits cannot enumerate at all.
set -u
cd "$(dirname "$0")/../.." || exit 1
evidence=review/ui-residues/evidence
port=8971
client=8871

suite() {
  port=$((port + 2)); client=$((client + 2))
  out=$(powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 -Port "$port" -ClientPort "$client" 2>&1)
  code=$?
  line=$(printf '%s\n' "$out" | grep -E '^ +(ok|FAIL|!)' | tail -1)
  printf '  %s\n  test-ui.ps1 exit=%s verdict: %s\n' "$1" "$code" "$line"
  printf '%s\nexit=%s\n%s\n' "$1" "$code" "$out" > "$evidence/mutation-$(echo "$1" | tr -cd 'a-z0-9-').log"
}

echo "== M7: a glyph on the pane's append-file control alone - a control whose box the glyph does not change =="
printf '\nwa-agent-session [data-part="attach"]::before { content: "!"; color: red; }\n' >> ui/style.css
git diff -- ui/style.css | tee "$evidence/mutation-m7-pane-attach-glyph.patch"
suite "M7 glyph on the pane append-file control alone"
node review/ui-residues/probe-runner.mjs review/ui-residues/probe-coverage.js --ui ui --budget 20000 \
  --screenshot review/ui-residues/evidence/m7-pane-attach-glyph.png > "$evidence/probe-coverage-m7.log" 2>&1
printf '  M7 coverage probe exit=%s\n' "$?"
git checkout -- ui/style.css

echo "== M8: a hover rule on the pane's controls alone =="
printf '\nwa-agent-session .chat-control:hover { letter-spacing: 3px; color: red; }\n' >> ui/style.css
git diff -- ui/style.css | tee "$evidence/mutation-m8-hover.patch"
suite "M8 hover rule on the pane's controls alone"
git checkout -- ui/style.css

echo
echo "clean tree after the run:"; git status --short
