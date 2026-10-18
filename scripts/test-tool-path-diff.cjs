// Focused browser suite: a tool row says which file it touched, and an edit shows what it changed.
//
//   node scripts/test-tool-path-diff.cjs <evidence-dir>
//   node scripts/test-tool-path-diff.cjs <evidence-dir> --post
//
// The first run renders the checkout's unmodified ui/ through the disposable browser and the probe in
// scripts/probe-tool-path-diff.js, and writes a receipt naming the exact sources and artifacts it
// observed. The `--post` run re-reads that receipt and refuses if the sources have moved on since, so a
// pass cannot be claimed against files that are no longer the ones that passed.
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict'),
  crypto = require('node:crypto'), { spawnSync } = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const out = path.resolve(process.argv[2]);
const hash = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sources = () => Object.fromEntries(['ui/app.js', 'ui/components.js', 'ui/style.css',
  'scripts/probe-tool-path-diff.js', 'scripts/test-tool-path-diff.cjs']
  .map((file) => [file, hash(path.join(repo, file))]));
const MIN_CHECKS = 57;

if (process.argv.includes('--post')) {
  const receipt = JSON.parse(fs.readFileSync(path.join(out, 'receipt.json')));
  assert(receipt.ok && receipt.checks >= MIN_CHECKS && receipt.skipped === 0);
  assert.deepEqual(receipt.sources, sources());
  for (const artifact of ['dom.html', 'screenshot.png']) {
    assert.equal(receipt.artifacts[artifact], hash(path.join(out, artifact)));
  }
  console.log(JSON.stringify({ ok: true, checks: receipt.checks, skipped: 0, evidence_verified: true }));
  process.exit();
}

assert(!fs.existsSync(path.join(out, 'receipt.json')));
fs.mkdirSync(out, { recursive: true });
const run = spawnSync(process.execPath, [path.join(repo, 'scripts/agent-benchmark-ui-observe.mjs'),
  '--probe', path.join(repo, 'scripts/probe-tool-path-diff.js'), '--out', out],
  { cwd: repo, encoding: 'utf8', windowsHide: true, timeout: 180000 });
fs.writeFileSync(path.join(out, 'stdout'), run.stdout || '');
fs.writeFileSync(path.join(out, 'stderr'), run.stderr || '');
assert.equal(run.status, 0, (run.stdout || '') + (run.stderr || ''));
assert(!run.error && !run.signal);
const observed = JSON.parse(run.stdout.trim().split(/\r?\n/).at(-1));
const proof = JSON.parse(observed.probeText);
assert(proof.checks >= MIN_CHECKS && proof.skipped === 0, JSON.stringify(proof));
fs.writeFileSync(path.join(out, 'receipt.json'), JSON.stringify({
  ok: true, ...proof, sources: sources(),
  artifacts: Object.fromEntries(['dom.html', 'screenshot.png']
    .map((name) => [name, hash(path.join(out, name))])),
}, null, 2));
console.log(JSON.stringify({ ok: true, ...proof, evidence: out }));
