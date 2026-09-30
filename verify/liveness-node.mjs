#!/usr/bin/env node
// Independent reviewer harness. Tests scripts/merge-lane.mjs's sweepClones (taken from
// c78ab731 as raw bytes into ./verify/b1-merge-lane.mjs) on a temp root of my own, with a
// REAL live process holding a real lease, and a real dead pid.
//
// The property under test is the dangerous one: a live run's clone is never pruned.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync, execSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const {sweepClones} = await import(new URL('./b1-merge-lane.mjs', import.meta.url).href);

let checks = 0, failed = 0;
const ok = (c, label, detail) => {
  checks += 1;
  if (c) console.log(`  ok   ${label}`);
  else { failed += 1; console.log(`  FAIL ${label}${detail === undefined ? '' : ` - ${detail}`}`); }
};
const mb = (dir) => Number((dirBytes(dir) / 1048576).toFixed(2));
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

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'verify-liveness-'));
const tmp = path.join(root, 'temp');
fs.mkdirSync(tmp);
console.log(`harness tmp root: ${tmp}`);

// A real live process, and a real pid that can no longer be alive.
const live = spawn(process.execPath, ['-e', 'setTimeout(()=>{}, 120000)'], {stdio: 'ignore'});
await new Promise(r => setTimeout(r, 400));
// a pid that is certainly not running: spawn something short-lived and reap it.
const deadProc = spawnSync(process.execPath, ['-e', 'process.exit(0)']);
const deadPid = spawnSync(process.execPath, ['-e', 'console.log(process.pid)']).stdout.toString().trim();
console.log(`live pid ${live.pid}, dead pid ${deadPid}`);

const mkdir = (name, bytes, ageMs) => {
  const d = path.join(tmp, name);
  fs.mkdirSync(d, {recursive: true});
  fs.writeFileSync(path.join(d, 'blob.bin'), Buffer.alloc(bytes, 7));
  const when = new Date(Date.now() - ageMs);
  fs.utimesSync(d, when, when);
  return d;
};
const M = 1048576;
let seq = 0;
const older = () => 60_000 * (10 + (seq += 1));   // distinct, ordered mtimes

const liveOld = mkdir(`wa-merge-lane-${live.pid}-AAAAAA`, 3 * M, older());   // live, oldest
const liveNew = mkdir(`wa-merge-lane-${live.pid}-ZZZZZZ`, 3 * M, 1000);      // live, newest
const dead1 = mkdir(`wa-merge-lane-${deadPid}-BBBBBB`, 4 * M, older());
const dead2 = mkdir(`wa-merge-lane-${deadPid}-CCCCCC`, 5 * M, older());
const legacyRecent = mkdir('wa-merge-lane-XXXXXX', M, 5 * 60 * 1000);
const legacyOld = mkdir('wa-merge-lane-YYYYYY', M, 3 * 60 * 60 * 1000);
const foreign = mkdir('wa-something-else-123', M, 10 * 60 * 60 * 1000);

console.log('\n1. keep=1 (default), a run of my own that kept nothing (a passing run)');
const sweep1 = sweepClones({keep: 1, tmp});
console.log('   record:', JSON.stringify({keep: sweep1.keep, budget_for_others: sweep1.budget_for_others,
  removed: sweep1.removed.map(r => path.basename(r.path)), kept: sweep1.kept.map(r => path.basename(r.path)),
  live: sweep1.live.map(p => path.basename(p)), recent_legacy: sweep1.recent_legacy.map(p => path.basename(p)),
  errors: sweep1.errors.length}, null, 1));
ok(fs.existsSync(liveOld) && fs.existsSync(liveNew), 'THE LIVE SIBLING SURVIVED: both live-lease clones still exist');
ok(sweep1.live.length === 2, 'the sweep classified both live leases as live', sweep1.live.length);
ok(fs.existsSync(legacyRecent), 'a pre-lease name younger than an hour is not pruned');
ok(!fs.existsSync(legacyOld), 'a pre-lease name older than an hour is pruned');
ok(fs.existsSync(foreign), 'a directory of another family is never touched');
ok(sweep1.removed.length === 2, 'budget 1 for others: the older two dead candidates were removed', sweep1.removed.length);
ok(fs.existsSync(dead1) !== fs.existsSync(dead2), 'exactly one dead clone was kept (the newest)', `${fs.existsSync(dead1)}/${fs.existsSync(dead2)}`);

console.log('\n2. keep=1 with this run keeping its own clone (a failing run): budget_for_others must be 0');
const dead3 = mkdir(`wa-merge-lane-${deadPid}-DDDDDD`, 2 * M, older());
const current = mkdir(`wa-merge-lane-${process.pid}-EEEEEE`, 2 * M, 500);
const sweep2 = sweepClones({keep: 1, tmp, current, currentKept: true});
ok(sweep2.budget_for_others === 0, 'the budget counts this run own clone', sweep2.budget_for_others);
ok(fs.existsSync(dead3), 'so an old dead clone is kept, not pruned: two clones on disk, as the commit says');
ok(fs.existsSync(current), 'and this run own clone is not a candidate');

console.log('\n3. keep=all (the falsifier): nothing is pruned, the family grows');
const before = fs.readdirSync(tmp).length;
const sweep3 = sweepClones({keep: 'all', tmp});
ok(sweep3.removed.length === 0, 'keep=all removed nothing', sweep3.removed.length);
ok(fs.readdirSync(tmp).length === before, 'the family is unchanged');

console.log('\n4. keep=0: nothing survives except a live lease and a recent pre-lease name');
const sweep4 = sweepClones({keep: 0, tmp});
ok(fs.existsSync(liveOld) && fs.existsSync(liveNew), 'the live leases are STILL never pruned at keep=0');
ok(!fs.existsSync(dead1) && !fs.existsSync(dead2) && !fs.existsSync(dead3), 'dead clones are all gone at keep=0');
ok(fs.existsSync(current), 'this run own clone (passed as current) is not a candidate');
console.log('   remaining:', fs.readdirSync(tmp).sort().join(', '));

console.log('\n5. a pid-lease check that is not mine: another live node process mid-flight');
const live2 = spawn(process.execPath, ['-e', 'setTimeout(()=>{}, 120000)'], {stdio: 'ignore'});
await new Promise(r => setTimeout(r, 400));
const live2Dir = mkdir(`wa-merge-lane-${live2.pid}-FFFFFF`, 6 * M, 1000);
const sweep5 = sweepClones({keep: 0, tmp});
ok(fs.existsSync(live2Dir), 'a live clone 6 MB big (the newest, largest) is still held back');
ok(sweep5.live.some(p => path.basename(p) === path.basename(live2Dir)), 'and it is reported in the record as live');

console.log('\n6. pid reuse: a name whose pid belongs to an unrelated live process is kept (safe direction)');
ok(sweep5.live.length === 3, 'three live leases now', sweep5.live.length);

console.log(`\n${checks - failed}/${checks} checks passed`);
console.log(`temp family bytes left: ${mb(tmp)} MB`);
live.kill();
live2.kill();
process.exitCode = failed ? 1 : 0;
