#!/usr/bin/env node
// Does what the docs say about a deploy's release proof match what a deploy DOES?
//
// THE FINDING THIS PINS (F2 of the review of change/deploy-unbound). After the default path stopped looking a
// release proof up at all, `docs/RECOVERY-THROUGHPUT.md` still said "`deploy.sh` *looks up* discoverable
// complete proof for a real Rust source workspace and records what it found, but does not require it" - a
// document describing a lookup the script no longer performs is how the next reader puts one back, and two
// of that review's six findings were documentation that had stopped being true. So this is a check, not
// another edit.
//
// It reads the doc's own paragraph and the script's own guard, and fails when they disagree in EITHER
// direction: the doc claiming a lookup the code does not do, or the code ceasing to read the knob by value
// while the doc still promises that `1` means on.
//
// Usage: node scripts/check-deploy-docs.mjs   (from the repository root)
import fs from 'node:fs';

const DOC = 'docs/RECOVERY-THROUGHPUT.md';
const SKILL = 'skills/self-update/SKILL.md';
const DEPLOY = 'scripts/deploy.sh';
const POLICY = 'lane-policy.json';

let checks = 0;
const ok = (message) => { checks += 1; console.log(`ok   ${message}`); };
const fail = (message) => { console.error(`check-deploy-docs: ${message}`); process.exit(1); };
const read = (file) => { try { return fs.readFileSync(file, 'utf8'); } catch (error) { fail(`cannot read ${file}: ${error.message}`); } };

const doc = read(DOC), skill = read(SKILL), deploy = read(DEPLOY), policy = read(POLICY);

// 1. The paragraph that speaks about deploy.sh and the proof, found by its own opening sentence rather than
//    by line numbers: the finding was about a sentence inside it.
const start = doc.indexOf('A complete identical-tree smoke receipt may be reused');
if (start < 0) fail(`${DOC} no longer contains the paragraph this check reads (the opening sentence moved?)`);
const end = doc.indexOf('\n\n', start);
const paragraph = doc.slice(start, end < 0 ? doc.length : end);

// 2. The stale claim must be gone, in both of the forms it had.
if (/looks up\*{0,2}[^\n]{0,40}discoverable complete proof/.test(paragraph)) {
  fail(`${DOC} still says deploy.sh looks a discoverable complete proof up: a deploy does not consult one at all by default`);
}
if (/does not require it/.test(paragraph)) {
  fail(`${DOC} still describes a lookup that happened and "does not require it" - the default performs no lookup`);
}
ok(`no doc claims the default deploy looks a release proof up (${DOC})`);

// 3. The rule must be stated where a reader looks for it.
if (!/does \*\*not\*\* consult a release proof|does not consult a release proof/.test(paragraph)) {
  fail(`${DOC} does not say that a deploy consults no release proof`);
}
if (!/`1`, `true`, `yes`, `on`/.test(paragraph)) {
  fail(`${DOC} does not say which WA_DEPLOY_REQUIRE_RELEASE_PROOF values are ON`);
}
ok(`the doc states the default and the ON values`);
if (!/does not\s+(consult|look)/.test(skill) || !/release proof/.test(skill)) {
  fail(`${SKILL} does not say that the default deploy consults no release proof`);
}
ok(`the self-update skill says the same thing as the doc`);
if (!/deploy-result\.json/.test(skill) || !/verdict/.test(skill)) {
  fail(`${SKILL} does not say that a final record is judged together with the deploy's own verdict`);
}
ok(`the skill states the record-and-verdict rule the verifier enforces`);

// 4. And the code must still behave the way the doc describes - the other direction of the same drift.
if (!/1\|true\|yes\|on\) REQUIRE_PROOF=1/.test(deploy)) {
  fail(`${DEPLOY} no longer reads WA_DEPLOY_REQUIRE_RELEASE_PROOF by VALUE - the doc's sentence is now false`);
}
if (!/if \[ "\$REQUIRE_PROOF" = "1" \] && \[ -f "\$ROOT\/rust\/Cargo\.toml" \]/.test(deploy)) {
  fail(`${DEPLOY} no longer guards the proof lookup with the value-read knob`);
}
ok(`the script reads the knob by value and looks nothing up by default (${DEPLOY})`);

// 5. The declared policy is the third place this rule lives, and it must not contradict the other two.
if (!/not a step of the release gate/.test(policy)) fail(`${POLICY} no longer declares a deploy as a stage of its own`);
if (!/WA_DEPLOY_REQUIRE_RELEASE_PROOF=1 \(OFF by default/.test(policy)) fail(`${POLICY} does not declare the knob OFF by default`);
if (!/"on": "release"/.test(policy)) fail(`${POLICY} no longer declares gate.on = release (the full gate is a release's)`);
ok(`the declared lane policy agrees (${POLICY})`);

console.log(`deploy docs check ok (${checks} checks; the doc, the skill and the deploy path say the same thing)`);
