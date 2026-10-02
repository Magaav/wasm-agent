#!/usr/bin/env bash
# The mutation run: apply one change to this checkout (a clone of the delivered tip), run the DELIVERED
# suites unmodified, record the verdict, revert. Nothing here edits the producer's worktree, the running
# window or the installed UI - only the tree this review branch owns.
set -u
cd "$(dirname "$0")/../.." || exit 1
evidence=review/ui-residues/evidence
port=8931
client=8831
pass=0
fail=0

suite() {   # $1 = label
  port=$((port + 2)); client=$((client + 2))
  out=$(powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 -Port "$port" -ClientPort "$client" 2>&1)
  code=$?
  line=$(printf '%s\n' "$out" | grep -E '^ +(ok|FAIL|!)' | tail -1)
  printf '  %s\n  test-ui.ps1 exit=%s verdict: %s\n' "$1" "$code" "$line"
  printf '%s\nexit=%s\n%s\n' "$1" "$code" "$out" > "$evidence/mutation-$(echo "$1" | tr -cd 'a-z0-9-').log"
  if [ "$code" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
}

git status --short | tee "$evidence/mutation-baseline-status.txt"
echo "== M1: margin-top on the pane's controls alone (the residue the delivery names) =="
printf '\nwa-agent-session .chat-control { margin-top: 4px; }\n' >> ui/style.css
git diff -- ui/style.css | tee "$evidence/mutation-m1-margin-top.patch"
suite "M1 margin-top on the pane's controls alone"
git checkout -- ui/style.css

echo "== M2: letter-spacing on the pane's controls alone (the other named residue) =="
printf '\nwa-agent-session .chat-control { letter-spacing: .4px; }\n' >> ui/style.css
git diff -- ui/style.css | tee "$evidence/mutation-m2-letter-spacing.patch"
suite "M2 letter-spacing on the pane's controls alone"
git checkout -- ui/style.css

echo "== M3: the busy-unknown outcome removed (the false alarm comes back) =="
python - <<'PY'
import io
p = 'ui/app.js'
s = io.open(p, encoding='utf-8').read()
old = '  if (worker && worker !== "alive") return "busy-unknown";'
assert old in s
s = s.replace(old, '  if (false && worker && worker !== "alive") return "busy-unknown";')
io.open(p, 'w', encoding='utf-8', newline='').write(s)
PY
git diff -- ui/app.js | tee "$evidence/mutation-m3-no-busy-unknown.patch"
suite "M3 busy-unknown removed"
git checkout -- ui/app.js

echo "== M4: the gate parser back to the prefix alone =="
python - <<'PY'
import io
p = 'scripts/gate-check.mjs'
s = io.open(p, encoding='utf-8').read()
old = '    const markers=text.split(/\\r?\\n/).filter(line=>prefix.test(line)&&subjects.some(subject=>subject.test(line)));'
assert old in s, 'parser anchor missing'
s = s.replace(old, '    const markers=text.split(/\\r?\\n/).filter(line=>prefix.test(line));')
io.open(p, 'w', encoding='utf-8', newline='').write(s)
PY
git diff -- scripts/gate-check.mjs | tee "$evidence/mutation-m4-prefix-only.patch"
node scripts/test-gate-check.mjs > "$evidence/mutation-m4-test-gate-check.log" 2>&1
m4=$?
node scripts/gate-check.mjs run ui-browser > "$evidence/mutation-m4-gate-ui-browser.log" 2>&1
m4b=$?
printf '  M4 prefix-only parser\n  node scripts/test-gate-check.mjs exit=%s\n  node scripts/gate-check.mjs run ui-browser exit=%s\n' "$m4" "$m4b"
tail -2 "$evidence/mutation-m4-test-gate-check.log"
[ "$m4" -ne 0 ] && fail=$((fail + 1)) || pass=$((pass + 1))
[ "$m4b" -eq 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))
git checkout -- scripts/gate-check.mjs

echo "== M5: a rule the audits cannot enumerate - a pseudo-element on the pane's controls alone =="
printf '\nwa-agent-session .chat-control::before { content: "!"; color: red; letter-spacing: 6px; }\n' >> ui/style.css
git diff -- ui/style.css | tee "$evidence/mutation-m5-pseudo-element.patch"
suite "M5 pseudo-element glyph on the pane's controls alone (expected to SLIP)"
node review/ui-residues/probe-runner.mjs review/ui-residues/probe-coverage.js --ui ui --budget 20000 > "$evidence/probe-coverage-m5.log" 2>&1
printf '  M5 coverage probe exit=%s\n' "$?"
grep -E '"(paneBefore|mainBefore|matchesThrows|matchesFalse|paneLetterSpacing|paneMarginTop)"' "$evidence/probe-coverage-m5.log"
git checkout -- ui/style.css

echo "== M6: the same glyph on the MAIN control instead (the audits' own direction) =="
printf '\n#attach::before { content: "!"; color: red; }\n' >> ui/style.css
suite "M6 pseudo-element glyph on the main control alone"
git checkout -- ui/style.css

echo
echo "clean tree after the run:"; git status --short
echo "suites that passed: $pass   that failed: $fail"
