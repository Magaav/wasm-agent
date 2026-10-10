// Disposable Chromium proof of opaque UI surfaces; --post checks exact retained evidence.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const repo = path.resolve(__dirname, '..');
assert(process.argv[2], 'provide a fresh evidence directory');
const out = path.resolve(process.argv[2]);
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sources = () => Object.fromEntries([
  'ui/app.js', 'ui/components.js', 'ui/style.css', 'ui/index.html', 'ui/test-fixtures.js',
  'scripts/agent-benchmark-ui-observe.mjs', 'scripts/probe-opaque-ui.js', 'scripts/test-opaque-ui.cjs',
].map(file => [file, hash(path.join(repo, file))]));
if (process.argv.includes('--post')) {
  const receipt = JSON.parse(fs.readFileSync(path.join(out, 'receipt.json')));
  assert(receipt.ok && receipt.checks >= 150 && receipt.skipped === 0);
  assert.deepEqual(receipt.sources, sources());
  for (const file of ['screenshot.png', 'dom.html']) assert.equal(receipt.artifacts[file], hash(path.join(out, file)));
  console.log(JSON.stringify({ ok: true, checks: receipt.checks, skipped: 0, evidence_verified: true }));
} else {
  assert(!fs.existsSync(out), 'fresh evidence generation required');
  fs.mkdirSync(out, { recursive: true });
  const result = spawnSync(process.execPath, [path.join(repo, 'scripts/agent-benchmark-ui-observe.mjs'),
    '--probe', path.join(repo, 'scripts/probe-opaque-ui.js'), '--out', out],
  { cwd: repo, encoding: 'utf8', windowsHide: true, timeout: 150000 });
  fs.writeFileSync(path.join(out, 'stdout.log'), result.stdout || '');
  fs.writeFileSync(path.join(out, 'stderr.log'), result.stderr || '');
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert(!result.error && !result.signal);
  const observation = JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));
  assert(observation.ok && observation.probeStatus === 'pass');
  const proof = JSON.parse(observation.probeText);
  assert(proof.checks >= 150 && proof.skipped === 0);
  fs.writeFileSync(path.join(out, 'receipt.json'), JSON.stringify({ ok: true, ...proof, sources: sources(),
    artifacts: Object.fromEntries(['screenshot.png', 'dom.html'].map(file => [file, hash(path.join(out, file))])),
  }, null, 2));
  console.log(JSON.stringify({ ok: true, ...proof, evidence: out }));
}
