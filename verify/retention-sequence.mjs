#!/usr/bin/env node
// Independent reviewer harness: reproduce c78ab731's retention bound with a REAL sequence of
// scripts/merge-lane.mjs runs, real clones, and real bytes, then falsify the bound with its own knob.
// Nothing of the machine's own temp or of anyone else's clone is touched: every child runs with
// TEMP/TMP/TMPDIR pointed at a root of this harness's own, and the gate lane is disabled by name.
// Usage: node verify/retention-sequence.mjs <tree-with-merge-lane> <workdir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const [treeArg, workArg] = process.argv.slice(2);
const tree = path.resolve(treeArg);
const work = path.resolve(workArg);
fs.rmSync(work, {recursive: true, force: true});
const temp = path.join(work, 'temp');
const repo = path.join(work, 'repo');
fs.mkdirSync(temp, {recursive: true});
fs.mkdirSync(repo, {recursive: true});
const LANE = path.join(tree, 'scripts', 'merge-lane.mjs');

const git = (cwd, ...args) => {
  const r = spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', ...args],
    {cwd, encoding: 'utf8', windowsHide: true});
  if (r.status !== 0) throw Error(`git ${args.join(' ')}: ${r.stderr || r.stdout}`);
  return (r.stdout || '').trim();
};
git(repo, 'init', '-q', '--initial-branch=main', '.');
git(repo, 'config', 'core.autocrlf', 'false');
fs.writeFileSync(path.join(repo, 'a.txt'), 'base\n');
git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'base');
git(repo, 'switch', '-q', '-c', 'change/one');
fs.writeFileSync(path.join(repo, 'b.txt'), 'one\n');
git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'one');
git(repo, 'switch', '-q', 'main');

// A real 400 MB write inside the clone: the size the commit names for one clone's payload
// (`rust/target` in a real run), so my numbers and theirs are comparable.
const PAYLOAD = 400;
const writePayload = `node -e "require('fs').writeFileSync('payload.bin',Buffer.alloc(${PAYLOAD}*1024*1024,7))"`;
const FAIL_GATE = `${writePayload}; exit 1`;
const PASS_GATE = `${writePayload}; printf 'smoke ok (0 skipped)\\n'; exit 0`;

function dirBytes(root) {
  let total = 0;
  let st;
  try { st = fs.statSync(root); } catch { return 0; }
  if (!st.isDirectory()) return st.size;
  for (const e of fs.readdirSync(root, {withFileTypes: true})) {
    const p = path.join(root, e.name);
    try { total += e.isDirectory() ? dirBytes(p) : fs.statSync(p).size; } catch {}
  }
  return total;
}
const family = () => fs.readdirSync(temp).filter(n => n.startsWith('wa-merge-lane-')).sort();
const familyBytes = () => family().reduce((s, n) => s + dirBytes(path.join(temp, n)), 0);
const mb = b => `${(b / 1048576).toFixed(1)} MB`;
const freeKb = () => Number(spawnSync('df', ['-Pk', work], {encoding: 'utf8'}).stdout.trim().split('\n').pop().split(/\s+/)[3]);

function lane(gate, env = {}) {
  const r = spawnSync(process.execPath, [LANE, '--repo', repo, '--base', 'main', '--gate-command', gate, 'change/one'],
    {cwd: repo, encoding: 'utf8', windowsHide: true, timeout: 600000, maxBuffer: 128 * 1024 * 1024,
      env: {...process.env, TEMP: temp, TMP: temp, TMPDIR: temp, WA_GATE_LANE: 'off', ...env}});
  let json = null;
  try { json = JSON.parse(r.stdout.trim().split('\n').pop()); } catch {}
  return {status: r.status, json, stderr: r.stderr || ''};
}

console.log(`tree: ${tree}\nharness temp: ${temp}\npayload per clone: ${PAYLOAD} MB\n`);
let failed = 0;
const ok = (c, label, detail) => { if (c) console.log(`  ok       ${label}`); else { failed += 1; console.log(`  FAIL     ${label}${detail ? ` - ${detail}` : ''}`); } };

console.log('A. the bound, default WA_MERGE_LANE_KEEP (a real sequence of three FAILING runs)');
const bounded = [];
for (let i = 1; i <= 3; i += 1) {
  const free0 = freeKb();
  const run = lane(FAIL_GATE);
  bounded.push(familyBytes());
  const names = family();
  console.log(`  run ${i}: exit ${run.status}, verdict ${run.json?.verdict}, family=${names.length} dir(s) ${mb(bounded[i - 1])},`
    + ` budget_for_others=${run.json?.retention?.sweeps?.map(s => s.budget_for_others).join('/')}, free fell ${(free0 - freeKb())} KiB`);
  if (i === 1) ok(/^wa-merge-lane-\d+-[A-Za-z0-9]{6}$/.test(names[0] || ''), 'the clone name carries the owning pid (the lease)', names[0]);
}
ok(bounded[2] === bounded[1] && bounded[1] === bounded[0], 'the family is bounded: the same bytes after each run',
  bounded.map(mb).join(' -> '));
ok(family().length === 1, 'exactly one clone is retained (the newest failure)', JSON.stringify(family()));
ok(bounded[0] > 300 * 1048576 && bounded[0] < 500 * 1048576, `one retained clone is ~${PAYLOAD} MB + git`, mb(bounded[0]));

console.log('\nB. the falsifier: WA_MERGE_LANE_KEEP=all (the bound removed, same three runs)');
fs.rmSync(temp, {recursive: true, force: true}); fs.mkdirSync(temp);
const unbounded = [];
for (let i = 1; i <= 3; i += 1) {
  const run = lane(FAIL_GATE, {WA_MERGE_LANE_KEEP: 'all'});
  unbounded.push(familyBytes());
  console.log(`  run ${i}: exit ${run.status}, family=${family().length} dir(s), ${mb(unbounded[i - 1])}`);
}
ok(unbounded[2] > unbounded[0], 'under the falsifier the family grows', unbounded.map(mb).join(' -> '));
ok(unbounded[2] > 2.5 * unbounded[0] / 2, 'and it grows by roughly one clone per run', mb(unbounded[2] - unbounded[0]));

console.log('\nC. a PASSING run removes its own clone (and keeps the newest leftover)');
fs.rmSync(temp, {recursive: true, force: true}); fs.mkdirSync(temp);
const pass = lane(PASS_GATE);
const afterPass = family();
console.log(`  exit ${pass.status}, verdict ${pass.json?.verdict}, clone.removed=${pass.json?.clone?.removed}, family=${JSON.stringify(afterPass)}, ${mb(familyBytes())}`);
ok(pass.status === 0 && afterPass.length === 0, 'a passing run leaves no clone at all (an empty family, not one clone)');
const failAfter = lane(FAIL_GATE);
const mixed = lane(PASS_GATE);
console.log(`  a failure then a pass: exit ${failAfter.status}/${mixed.status}, family=${JSON.stringify(family())}, ${mb(familyBytes())}`);
ok(family().length === 1, 'the failure it did not create survives the passing run (newest 1), and the pass added nothing');

console.log('\nD. keep=0 (a red gate with no tree) and an invalid knob');
const zero = lane(FAIL_GATE, {WA_MERGE_LANE_KEEP: '0'});
console.log(`  WA_MERGE_LANE_KEEP=0: exit ${zero.status}, family=${JSON.stringify(family())}`);
ok(zero.status === 3 && family().length === 0, 'keep=0 leaves nothing behind and still gates');
const bad = lane(FAIL_GATE, {WA_MERGE_LANE_KEEP: 'twelve'});
console.log(`  WA_MERGE_LANE_KEEP=twelve: exit ${bad.status}, ${JSON.stringify((bad.json?.error || '').slice(0, 90))}`);
ok(bad.status === 4, 'a knob that is not a count is refused before anything is made', `exit ${bad.status}`);

console.log('\nE. a live sibling clone is not pruned by a concurrent run (real processes)');
fs.rmSync(temp, {recursive: true, force: true}); fs.mkdirSync(temp);
const {spawn} = await import('node:child_process');
const holder = spawn(process.execPath, ['-e', 'setTimeout(()=>{},180000)'], {stdio: 'ignore'});
await new Promise(r => setTimeout(r, 400));
const liveDir = path.join(temp, `wa-merge-lane-${holder.pid}-Live11`);
fs.mkdirSync(liveDir); fs.writeFileSync(path.join(liveDir, 'payload.bin'), Buffer.alloc(600 * 1048576, 3));
const run = lane(FAIL_GATE);
const swept = run.json?.retention?.sweeps?.map(s => ({live: s.live.length, removed: s.removed.length, kept: s.kept.length}));
console.log(`  sweeps: ${JSON.stringify(swept)}`);
ok(fs.existsSync(liveDir), 'THE LIVE SIBLING CLONE SURVIVED a real concurrent run that failed');
ok(family().length === 2, 'and the run kept its own beside it (1 live + 1 own)', JSON.stringify(family()));
holder.kill();

console.log(`\n${failed ? `${failed} check(s) FAILED` : 'all checks passed'}`);
if (process.env.KEEP_HARNESS !== '1') fs.rmSync(work, {recursive: true, force: true});
process.exitCode = failed ? 1 : 0;
