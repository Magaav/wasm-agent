// This is a vocabulary check, not proof that the execution contracts are implemented.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const terms = {
  Node: 'An identity, authority boundary and supervised runtime.',
  Session: 'An independently resumable conversation.',
  Run: 'One execution within a session.',
  Subagent: 'A supervised child task with its own context and execution state.',
  Job: 'A reusable automation definition that can execute deterministic steps and invoke subagents.',
  Delivery: 'One durable occurrence of a job, pinned to its revision and source event.',
  Operation: 'Supervised external execution, such as a shell process.',
};
let checks = 0;
function validate(text, label) {
  for (const [term, definition] of Object.entries(terms)) {
    const rows = text.split('\n').filter(line => line.replaceAll('**', '').startsWith(`| ${term} |`));
    assert.equal(rows.length, 1, `${label}: exactly one canonical ${term} row`);
    assert.equal(rows[0].replaceAll('**', '').split('|')[2].trim(), definition, `${label}: definition of ${term}`);
  }
}
for (const file of ['ARCHITECTURE.md', 'docs/EXECUTION.md']) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  validate(text, file);
  checks += Object.keys(terms).length * 2;
  for (const definition of Object.values(terms)) {
    assert.throws(() => validate(text.replace(definition, 'An unrelated concept.'), file));
    checks++;
  }
}
const execution = fs.readFileSync(path.join(root, 'docs/EXECUTION.md'), 'utf8');
assert.ok(execution.includes('not an OS sandbox')); checks++;
assert.ok(execution.includes('not conversation identifiers')); checks++;
assert.ok(execution.includes('does not claim') || execution.includes('Never treat a design requirement as a passed test')); checks++;
console.log(`execution terminology ok (${checks} checks, 0 skipped; vocabulary only, not behavior)`);
