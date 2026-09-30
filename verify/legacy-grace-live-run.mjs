#!/usr/bin/env node
// Independent reviewer harness: the pre-lease grace is measured from MTIME, not from "this run is alive".
//
// A clone minted by the PRE-CHANGE merge-lane (main's code, which other lanes are running right now) is
// named `wa-merge-lane-XXXXXX` - no pid to ask about - so the only thing protecting a LIVE run's clone
// from c78ab731's sweep is that its directory mtime is younger than an hour. This machine's own gate-lane
// waits already exceed an hour (status showed waits of 1390 s, 4909 s, 5399 s today), the clone is made
// BEFORE the slot is waited for, and writes inside the clone (rust/target) do not touch the clone root's
// mtime. Measured on this machine: 87 pre-lease `wa-merge-lane-*` leftovers, 69 of them older than an hour.
//
// This harness holds a REAL pre-change lane run open in a temp root of its own, ages its clone the way a
// long slot wait would, gives it a newer dead leftover to compete with (keep=1 keeps the newest), and runs
// c78ab731's own sweep over that root.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync, spawn} from 'node:child_process';

const [mainTree, b1Tree, workArg] = process.argv.slice(2);
const work = path.resolve(workArg);
fs.rmSync(work, {recursive: true, force: true});
const temp = path.join(work, 'temp');
const repo = path.join(work, 'repo');
fs.mkdirSync(temp, {recursive: true});
fs.mkdirSync(repo, {recursive: true});
const {sweepClones} = await import(new URL('./b1-merge-lane.mjs', import.meta.url).href);

const git = (cwd, ...a) => {
  const r = spawnSync('git', ['-c', 'user.name=f', '-c', 'user.email=f@x', ...a], {cwd, encoding: 'utf8', windowsHide: true});
  if (r.status !== 0) throw Error(`git ${a.join(' ')} ${r.stderr}`);
};
git(repo, 'init', '-q', '--initial-branch=main', '.');
fs.writeFileSync(path.join(repo, 'a.txt'), 'base\n'); git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'base');
git(repo, 'switch', '-q', '-c', 'change/one');
fs.writeFileSync(path.join(repo, 'b.txt'), 'one\n'); git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'one');
git(repo, 'switch', '-q', 'main');

// A pre-change lane run, alive, whose gate reports whether its own clone is still there at the end.
const probe = 'sleep 6; if [ -f a.txt ]; then echo "PROBE clone intact"; else echo "PROBE CLONE GONE"; exit 7; fi';
console.log(`temp root for the live pre-lease run: ${temp}`);
const live = spawn(process.execPath, [path.join(mainTree, 'scripts', 'merge-lane.mjs'), '--repo', repo, '--base', 'main',
  '--gate-command', probe, 'change/one'],
  {cwd: repo, env: {...process.env, TEMP: temp, TMP: temp, TMPDIR: temp, WA_GATE_LANE: 'off'}, stdio: ['ignore', 'pipe', 'pipe']});
let out = '';
live.stdout.on('data', d => { out += d; });
live.stderr.on('data', d => { out += d; });
await new Promise(r => setTimeout(r, 3500));   // it is inside its gate now, holding its clone

const cloneName = fs.readdirSync(temp).find(n => n.startsWith('wa-merge-lane-'));
const clone = path.join(temp, cloneName);
console.log(`live run's clone: ${cloneName} (pre-lease name: no pid to ask about)  exists=${fs.existsSync(clone)}`);

const leftover = path.join(temp, 'wa-merge-lane-Cand01');   // a DEAD leftover that is newer
fs.mkdirSync(leftover);
const half = new Date(Date.now() - 90 * 60 * 1000);
fs.utimesSync(leftover, half, half);
const old = new Date(Date.now() - 2 * 60 * 60 * 1000);      // what a 2-hour slot wait produces
fs.utimesSync(clone, old, old);
console.log(`aged the live clone's mtime to ${((Date.now() - fs.statSync(clone).mtimeMs) / 3600000).toFixed(1)} h ago; the run is STILL ALIVE (pid ${live.pid})`);
console.log(`a newer dead leftover beside it: ${path.basename(leftover)} (90 min), so keep=1 keeps that one`);

const rec = sweepClones({keep: 1, tmp: temp});
console.log('sweep record:', JSON.stringify({keep: rec.keep, live: rec.live.length,
  kept: rec.kept.map(k => path.basename(k.path)), removed: rec.removed.map(r => path.basename(r.path)),
  recent_legacy: rec.recent_legacy.map(p => path.basename(p)),
  errors: rec.errors.map(e => `${path.basename(e.path)}: ${e.error}`)}));

const exit = await new Promise(resolve => live.on('exit', c => resolve(c)));
await new Promise(r => setTimeout(r, 200));
const probeLine = out.split('\n').find(l => l.includes('PROBE')) || '(no probe line)';
console.log(`live run's exit: ${exit}; its own gate reported: ${probeLine.trim()}`);
console.log(`live run's clone after the sweep: exists=${fs.existsSync(clone)}`);
console.log(fs.existsSync(clone)
  ? 'RESULT: the live pre-lease clone survived'
  : 'RESULT: THE LIVE RUN\'S CLONE WAS DELETED by the sweep while its owner was alive');
if (process.env.KEEP_HARNESS !== '1') fs.rmSync(work, {recursive: true, force: true});
