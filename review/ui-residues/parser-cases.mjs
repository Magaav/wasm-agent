#!/usr/bin/env node
// The gate parser, attacked directly: which lines does the browser verdict accept?
//
// The delivery claims the parser "anchors on the prefix and requires the stage's subject, pinned with a
// negative case". This runs the delivered `checkVerdict` (imported from scripts/gate-check.mjs, not
// re-implemented) over the delivered negative case plus shapes of my own.
import {checkVerdict} from '../../scripts/gate-check.mjs';

const browser = {verdict: 'browser'};
const cases = [
  ['the real verdict line scripts/test-ui.ps1 prints', 0,
    '  ok   UI structure, mid-run reload, startup recovery, the inspect window, and a view window', true],
  ['a reordered honest sentence', 0, '  ok   UI structure, startup recovery and mid-run reload, with the inspector window and a view window', true],
  ['the delivered negative case (names no stage)', 0, '  ok   UI structure, and then something else entirely', false],
  ['the bare prefix', 0, '  ok   UI structure', false],
  ['MY CASE: the sentence denies the stage it is being read as proof of', 0,
    '  ok   UI structure, but startup recovery was skipped and the mid-run reload never ran', true],
  ['MY CASE: a false stage subject after the prefix', 0, '  ok   UI structure, startup recovery of another check entirely', true],
  ['MY CASE: a subject inside a wordier sentence with no stage of this check', 0,
    '  ok   UI structure, and a mid-run reload of a different page', true],
  ['another check\'s ok line', 0, '  ok   Engine structure is fine', false],
  ['the prefix with a FAIL line anywhere', 0, '  ok   UI structure, mid-run reload, and startup recovery\n  FAIL evidence', false],
  ['the verdict twice', 0, '  ok   UI structure, mid-run reload, startup recovery\n  ok   UI structure, mid-run reload, startup recovery', false],
  ['a non-zero exit with the verdict present', 7, '  ok   UI structure, mid-run reload, and startup recovery', false],
  ['MY CASE: a lowercase fail line and exit 0', 0, '  ok   UI structure, mid-run reload, startup recovery\n  fail: the inspector stage did not run', true],
  ['MY CASE: DEPENDENCY_MISSING lowercase, exit 0', 0, '  ok   UI structure, mid-run reload, startup recovery\n  dependency_missing: no browser', true],
];

let disagreed = 0;
for (const [name, exit, text, expected] of cases) {
  const result = checkVerdict(browser, exit, text);
  const same = result.ok === expected;
  if (!same) disagreed += 1;
  console.log(`${result.ok ? 'ACCEPTED' : 'refused '} ${same ? '(as stated)' : '(UNEXPECTED: expected ' + (expected ? 'accepted' : 'refused') + ')'}  ${name}`);
  console.log(`           ${JSON.stringify(text)}  reason=${result.reason}`);
}
console.log('');
console.log(`${cases.length} lines: ${disagreed} disagreed with the stated expectation`);
