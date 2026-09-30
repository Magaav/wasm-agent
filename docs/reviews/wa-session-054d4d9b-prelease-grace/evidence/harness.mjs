// INDEPENDENT review harness for the pre-lease grace repair (branch tip 62868e3c).
// Written by the reviewer, not by the delivery. Nothing here reads the delivery's verify/.
// Every root is a mkdtemp under REVIEW_SCRATCH; every child gets TEMP/TMP/TMPDIR pinned to a scratch
// "temp" dir and WA_GATE_LANE_DIR pinned to a scratch gate-lane store, so no sweep and no gate-lane
// call here can see the live wa-merge-lane-* / wa-gate-home-* families or the live gate-lane store.
// usage: node harness.mjs <queued|gate|bound|msys|probe> <treeDir> <label> [sweeperWaitEnv]
import fs from 'node:fs';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';

const SCRATCH = process.env.REVIEW_SCRATCH || 'C:/Users/Victor/.wasm-agent/wa-review-054d4d9b/cases';
const PRE = process.env.REVIEW_PRE_TREE || 'C:/Users/Victor/.wasm-agent/wa-review-054d4d9b/pre';
const SWEEP = 'C:/Users/Victor/.wasm-agent/wa-review-054d4d9b/sweep.mjs';
const PROBECHILD = 'C:/Users/Victor/.wasm-agent/wa-review-054d4d9b/probe-child.mjs';
const NODE = process.execPath;
const HOUR = 3600 * 1000;
const [which, treeArg, label, extra] = process.argv.slice(2);
const TREE = path.resolve(treeArg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.log(...a);
const base = p => String(p).split(/[\/]/).pop();
const listing = dir => { try { return fs.readdirSync(dir).sort(); } catch (e) { return ['<' + e.code + '>']; } };
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const age = (dir, ms) => { const when = new Date(Date.now() - ms); fs.utimesSync(dir, when, when); };
const legacy = name => /^wa-merge-lane-[A-Za-z0-9]{6}$/.test(name);

function fencedEnv(temp, store, extraEnv = {}) {
  const env = {...process.env, TEMP: temp, TMP: temp, TMPDIR: temp};
  delete env.WA_GATE_LANE_DIR; delete env.WA_GATE_LANE_CAPACITY; delete env.WA_GATE_LANE_WAIT_SECONDS;
  delete env.WA_GATE_LANE; delete env.GATE_LANE_HELD; delete env.WA_MERGE_LANE_KEEP;
  if (store) env.WA_GATE_LANE_DIR = store;
  return {...env, ...extraEnv};
}
function workRoot(caseName) {
  fs.mkdirSync(SCRATCH, {recursive: true});
  const root = fs.mkdtempSync(path.join(SCRATCH, 'case-' + caseName + '-'));
  const temp = path.join(root, 'temp');
  fs.mkdirSync(temp);
  return {root, temp};
}
function makeRepo(dir) {
  fs.mkdirSync(dir);
  const git = (...args) => {
    const r = spawnSync('git', ['-c', 'user.name=f', '-c', 'user.email=f@x', ...args],
      {cwd: dir, encoding: 'utf8', windowsHide: true});
    if (r.status !== 0) throw Error('git ' + args.join(' ') + ': ' + r.stderr);
  };
  git('init', '-q', '--initial-branch=main', '.');
  fs.writeFileSync(path.join(dir, 'a.txt'), 'base\n'); git('add', '-A'); git('commit', '-q', '-m', 'base');
  git('switch', '-q', '-c', 'change/one');
  fs.writeFileSync(path.join(dir, 'b.txt'), 'one\n'); git('add', '-A'); git('commit', '-q', '-m', 'one');
  git('switch', '-q', 'main');
  return dir;
}
const CHILDREN = [];
function capture(child) {
  CHILDREN.push(child);
  child.out = '';
  child.stdout.on('data', d => { child.out += d; });
  child.stderr.on('data', d => { child.out += d; });
  return child;
}
const GATE = 'printf "GATE_STARTED\n"; sleep 5; if [ -f a.txt ]; then echo "GATE PROBE clone intact"; '
  + 'else echo "GATE PROBE CLONE GONE"; exit 7; fi; echo "smoke ok"';
const GATE25 = 'printf "GATE_STARTED\n"; sleep 25; if [ -f a.txt ]; then echo "GATE PROBE clone intact"; '
  + 'else echo "GATE PROBE CLONE GONE"; exit 7; fi; echo "smoke ok"';
function preChangeRun(repo, temp, store, extraEnv = {}, gateCmd = GATE) {
  return capture(spawn(NODE, [path.join(PRE, 'scripts', 'merge-lane.mjs'),
    '--repo', repo, '--base', 'main', '--gate-command', gateCmd, '--timeout-seconds', '3600', 'change/one'],
  {cwd: repo, env: fencedEnv(temp, store, extraEnv), stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true}));
}
function sweep(tmp, keep, waitEnv) {
  const env = fencedEnv(tmp, null);
  const r = spawnSync(NODE, [SWEEP, TREE, tmp, String(keep), waitEnv === undefined ? '' : waitEnv],
    {encoding: 'utf8', windowsHide: true, env});
  const line = String(r.stdout || '').split('\n').find(l => l.startsWith('SWEEP '));
  return line ? JSON.parse(line.slice(6)) : {error: String(r.stderr || r.stdout || '').split('\n').slice(-3).join(' | ')};
}
const exitSoon = async (child, ms) => {
  if (child.exitCode !== null && child.exitCode !== undefined) return child.exitCode;
  return Promise.race([new Promise(r => child.on('exit', c => r(c))), sleep(ms).then(() => 'still-running')]);
};
function killTree(pid) {
  if (!pid) return 'no pid';
  const r = spawnSync('taskkill', ['/F', '/T', '/PID', String(pid)], {encoding: 'utf8', windowsHide: true});
  return 'taskkill pid ' + pid + ': exit ' + r.status + '; '
    + String(r.stdout || r.stderr || '').trim().split('\n').join(' / ');
}
const verdictOf = out => {
  for (const line of String(out).split('\n').reverse()) {
    try { const j = JSON.parse(line.trim());
      if (j && j.verdict) return 'verdict=' + j.verdict + ' exit_code=' + j.exit_code + ' error=' + (j.error ?? 'none'); } catch {}
  }
  return '(no verdict JSON in the run output)';
};
const tail = (out, n = 3) => String(out).split('\n').filter(l => l.trim()).slice(-n).map(l => l.trim());

async function caseQueued() {
  const {root, temp} = workRoot('queued');
  const repo = makeRepo(path.join(root, 'repo'));
  const store = path.join(root, 'gate-lane');
  log('  tree under test: ' + TREE);
  log('  scratch root:    ' + root);
  log('  fenced temp:     ' + temp + '   (TEMP/TMP/TMPDIR of every child)');
  log('  scratch store:   ' + store + "  (WA_GATE_LANE_DIR of every child - NOT the live lane's)");
  const holder = capture(spawn(NODE, [path.join(TREE, 'scripts', 'gate-lane.mjs'), 'acquire',
    '--dir', store, '--cwd', root, '--holder-pid', String(process.pid), '--wait-seconds', '1800'],
  {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true}));
  await sleep(3000);
  log('  SLOT HOLDER pid ' + holder.pid + ' alive=' + alive(holder.pid) + ': ' + (tail(holder.out, 1)[0] || '(none)'));
  const runWait = process.env.REVIEW_RUN_WAIT || '7200';
  const run = preChangeRun(repo, temp, store, {WA_GATE_LANE_WAIT_SECONDS: runWait});
  log('  the queued run has exported WA_GATE_LANE_WAIT_SECONDS=' + runWait + ' as its OWN wait budget');
  log("  pre-change lane run (main's merge-lane) pid " + run.pid + '; wait budget = the node default 7200 s');
  let clone = null;
  for (let i = 0; i < 45 && !clone; i += 1) {
    await sleep(1000);
    const names = listing(temp).filter(legacy);
    if (names.length === 1 && /waiting \(\d+s\)/.test(run.out)) clone = names[0];
  }
  if (!clone) throw Error('never queued: ' + JSON.stringify(listing(temp)) + ' / ' + JSON.stringify(tail(run.out, 3)));
  const dir = path.join(temp, clone);
  log('  QUEUED: clone=' + clone + ' gate_log_exists=' + fs.existsSync(path.join(dir, '.git', 'wa-merge-lane-gate.log')) + ' run_alive=' + alive(run.pid));
  log("  the run's own words: " + tail(run.out, 1)[0]);
  const ps = spawnSync('powershell', ['-NoProfile', '-Command',
    "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*gate-lane.mjs*' -and $_.CommandLine -like '*"
    + clone + "*' } | Select-Object ProcessId,ParentProcessId | Format-List"], {encoding: 'utf8', windowsHide: true});
  log('  live native processes whose command line names that clone (the acquirer child, spawned with');
  log('  cwd = the clone):\n' + String(ps.stdout || '').trim().split('\n').map(l => '    ' + l).join('\n'));
  const ageHours = Number(process.env.REVIEW_AGE_HOURS || '2'); age(dir, ageHours * HOUR);
  log('  the queued run s clone aged to ' + ageHours + ' h, beside a newer dead leftover wa-merge-lane-Cand01 (90 min)');
  fs.mkdirSync(path.join(temp, 'wa-merge-lane-Cand01'));
  const decoyMinutes = Number(process.env.REVIEW_DECOY_MINUTES || '90');
  age(path.join(temp, 'wa-merge-lane-Cand01'), decoyMinutes * 60 * 1000);
  log('  the dead decoy wa-merge-lane-Cand01 is aged ' + decoyMinutes + ' min');
  log("  the queued run's clone aged to 2.0 h, beside a newer dead leftover wa-merge-lane-Cand01 (90 min)");
  log('  BEFORE: ' + JSON.stringify(listing(temp)));
  const record = sweep(temp, 1, extra);
  log('  SWEEP ' + JSON.stringify(record));
  const survived = fs.existsSync(dir);
  log("  the QUEUED run's clone exists after the sweep: " + survived + '; run still alive: ' + alive(run.pid));
  const id = (holder.out.match(/#(\d+) granted/) || [])[1] || '1';
  const rel = spawnSync(NODE, [path.join(TREE, 'scripts', 'gate-lane.mjs'), 'release', '--dir', store, '--id', id, '--exit', '0'], {encoding: 'utf8', windowsHide: true, env: fencedEnv(temp, null)});
  log('  scratch slot released cleanly (gate-lane release --id ' + id + '): exit ' + rel.status + ' ' + JSON.stringify(String(rel.stdout || rel.stderr).trim().split(/\r?\n/).slice(-2)));
  log('  the holder process is killed after its slot is released: ' + killTree(holder.pid));
  log('  the holder process is killed after its slot is released: ' + killTree(holder.pid));
  const exit = await exitSoon(run, 90000);
  log("  the run's last words: " + JSON.stringify(tail(run.out, 2)));
  log('  cleanup: ' + killTree(run.pid));
  await sleep(700);
  log('  cleanup: run alive=' + alive(run.pid) + ' holder alive=' + alive(holder.pid));
  fs.rmSync(root, {recursive: true, force: true});
  log('  cleanup: scratch root removed = ' + !fs.existsSync(root));
  return {label, tree: TREE, clone, survived, exit, last_words: tail(run.out, 2), run_pid: run.pid, holder_pid: holder.pid,
    sweep: {grace_seconds: record.grace_seconds, removed: record.removed, kept: record.kept,
      recent_legacy: record.recent_legacy, in_use: record.in_use, errors: record.errors}};
}

async function caseGate() {
  const {root, temp} = workRoot('gate');
  const repo = makeRepo(path.join(root, 'repo'));
  log('  tree under test: ' + TREE);
  log('  fenced temp:     ' + temp);
  const run = preChangeRun(repo, temp, null, {WA_GATE_LANE: 'off'}, GATE25);
  log('  pre-change lane run pid ' + run.pid + ', WA_GATE_LANE=off: inside its gate, gate child cwd = the clone');
  let clone = null;
  for (let i = 0; i < 45 && !clone; i += 1) {
    await sleep(1000);
    const names = listing(temp).filter(legacy);
    if (names.length === 1 && fs.existsSync(path.join(temp, names[0], '.git', 'wa-merge-lane-gate.log'))) clone = names[0];
  }
  if (!clone) throw Error('no gate-started clone: ' + JSON.stringify(listing(temp)) + ' / ' + JSON.stringify(tail(run.out, 3)));
  const dir = path.join(temp, clone);
  age(dir, 2 * HOUR);
  fs.mkdirSync(path.join(temp, 'wa-merge-lane-Cand02'));
  age(path.join(temp, 'wa-merge-lane-Cand02'), 90 * 60 * 1000);
  log('  GATE RUNNING: clone=' + clone + ' aged to 2.0 h, beside a newer dead leftover (90 min)');
  log('  BEFORE: ' + JSON.stringify(listing(temp)));
  const record = sweep(temp, 1, extra);
  log('  SWEEP ' + JSON.stringify(record));
  const survived = fs.existsSync(dir);
  log("  the LIVE run's clone exists after the sweep: " + survived);
  const exit = await exitSoon(run, 90000);
  log("  the run's exit: " + JSON.stringify(exit) + '  ' + verdictOf(run.out));
  log("  the run's last words: " + JSON.stringify(tail(run.out, 2)));
  log('  cleanup: ' + killTree(run.pid));
  fs.rmSync(root, {recursive: true, force: true});
  log('  cleanup: scratch root removed = ' + !fs.existsSync(root));
  return {label, tree: TREE, clone, survived, exit, last_words: tail(run.out, 2), run_pid: run.pid,
    sweep: {grace_seconds: record.grace_seconds, removed: record.removed, kept: record.kept,
      recent_legacy: record.recent_legacy, in_use: record.in_use, errors: record.errors}};
}

async function caseBound() {
  const {root, temp} = workRoot('bound');
  log('  tree under test: ' + TREE);
  log('  fenced temp:     ' + temp);
  const plant = () => ['Oldest', 'Middle', 'Newest'].forEach((name, i) => {
    const dir = path.join(temp, 'wa-merge-lane-' + name);
    fs.mkdirSync(dir, {recursive: true});
    age(dir, (6 - i * 0.5) * HOUR);
  });
  plant();
  log('  family: ' + JSON.stringify(listing(temp)) + ' (6 h / 5.5 h / 5 h, all older than the flat hour)');
  const bounded = sweep(temp, 1, extra);
  log('  SWEEP keep=1 ' + JSON.stringify(bounded));
  log('  family after: ' + JSON.stringify(listing(temp)));
  plant();
  const falsifier = sweep(temp, 'all', extra);
  log('  SWEEP keep=all (the inherited falsifier) ' + JSON.stringify(falsifier));
  log('  family after: ' + JSON.stringify(listing(temp)));
  fs.rmSync(temp, {recursive: true, force: true}); fs.mkdirSync(temp);
  plant();
  const raised = sweep(temp, 1, '1000000');
  log("  SWEEP keep=1 with the sweeper's WA_GATE_LANE_WAIT_SECONDS=1000000 " + JSON.stringify(raised));
  log('  family after: ' + JSON.stringify(listing(temp)));
  fs.rmSync(root, {recursive: true, force: true});
  log('  cleanup: scratch root removed = ' + !fs.existsSync(root));
  return {label, tree: TREE, bounded: {grace: bounded.grace_seconds, removed: bounded.removed, after: bounded.after},
    falsifier: {removed: falsifier.removed.length, after: falsifier.after},
    raised: {grace: raised.grace_seconds, removed: raised.removed, recent_legacy: raised.recent_legacy, after: raised.after}};
}

async function caseMsys() {
  const {root, temp} = workRoot('msys');
  const BASH = 'C:/Program Files/Git/bin/bash.exe';
  const cdDir = path.join(temp, 'wa-merge-lane-Cd0001');
  const spawnDir = path.join(temp, 'wa-merge-lane-Sp0001');
  for (const d of [cdDir, spawnDir]) { fs.mkdirSync(d); fs.writeFileSync(path.join(d, 'tree.txt'), 'x\n'); }
  log('  tree under test: ' + TREE);
  log('  fenced temp:     ' + temp);
  const cdChild = capture(spawn(BASH, ['-c', 'cd "$(cygpath -u \'' + cdDir + '\')" && echo IN && while :; do sleep 1; done'],
    {stdio: ['ignore', 'pipe', 'pipe']}));
  const spawnChild = capture(spawn(BASH, ['-c', 'echo IN; while :; do sleep 1; done'],
    {cwd: spawnDir, stdio: ['ignore', 'pipe', 'pipe']}));
  for (let i = 0; i < 40 && !(cdChild.out.includes('IN') && spawnChild.out.includes('IN')); i += 1) await sleep(250);
  age(cdDir, 3.5 * HOUR); age(spawnDir, 3.5 * HOUR);
  log('  MSYS bash that cd-ed in:       pid ' + cdChild.pid + ' (cwd = ' + base(cdDir) + '), dir aged 3.5 h');
  log('  MSYS bash spawned with cwd in: pid ' + spawnChild.pid + ' (cwd = ' + base(spawnDir) + '), dir aged 3.5 h');
  const record = sweep(temp, 0, extra);
  log('  SWEEP keep=0 ' + JSON.stringify(record));
  log('  AFTER: ' + JSON.stringify(listing(temp)));
  const cdThere = fs.existsSync(cdDir), spThere = fs.existsSync(spawnDir);
  log('  cd-ed-in holder dir (' + base(cdDir) + ') exists = ' + cdThere + '; shell alive = ' + alive(cdChild.pid));
  log('  spawned-in holder dir (' + base(spawnDir) + ') exists = ' + spThere + '; shell alive = ' + alive(spawnChild.pid));
  log('  cleanup: ' + killTree(cdChild.pid) + ' | ' + killTree(spawnChild.pid));
  fs.rmSync(root, {recursive: true, force: true});
  log('  cleanup: scratch root removed = ' + !fs.existsSync(root));
  return {label, tree: TREE, cd_survived: cdThere, spawn_survived: spThere,
    removed: record.removed, in_use: record.in_use, recent_legacy: record.recent_legacy, errors: record.errors};
}

async function caseProbe() {
  const {root, temp} = workRoot('probe');
  log('  tree under test: ' + TREE);
  log('  fenced temp:     ' + temp);
  const target = path.join(temp, 'wa-merge-lane-Probe1');
  fs.mkdirSync(target); fs.writeFileSync(path.join(target, 'tree.txt'), 'x\n');
  age(target, 5 * HOUR);
  log("  one stale pre-lease clone (5 h). The probe's own rename target <dir>.in-use-<pid> is created");
  log('  NON-EMPTY inside the sweeping child, so the rename cannot be answered at all:');
  const c1 = spawnSync(NODE, [PROBECHILD, TREE, temp, 'leftover'], {encoding: 'utf8', windowsHide: true, env: fencedEnv(temp, null)});
  const l1 = String(c1.stdout || '').split('\n').find(l => l.startsWith('SWEEP '));
  log('  first sweep (rename unanswerable):  ' + (l1 ? l1.slice(6) : JSON.stringify(String(c1.stderr).split('\n').slice(-3))));
  log('  AFTER: ' + JSON.stringify(listing(temp)));
  const c2 = spawnSync(NODE, [PROBECHILD, TREE, temp, 'plain'], {encoding: 'utf8', windowsHide: true, env: fencedEnv(temp, null)});
  const l2 = String(c2.stdout || '').split('\n').find(l => l.startsWith('SWEEP '));
  log('  second sweep (rename answerable):   ' + (l2 ? l2.slice(6) : JSON.stringify(String(c2.stderr).split('\n').slice(-3))));
  log('  AFTER: ' + JSON.stringify(listing(temp)));
  fs.rmSync(root, {recursive: true, force: true});
  log('  cleanup: scratch root removed = ' + !fs.existsSync(root));
  return {label, tree: TREE, first: l1 ? JSON.parse(l1.slice(6)) : String(c1.stderr),
    second: l2 ? JSON.parse(l2.slice(6)) : String(c2.stderr)};
}

const CASES = {queued: caseQueued, gate: caseGate, bound: caseBound, msys: caseMsys, probe: caseProbe};
if (!CASES[which]) { console.error('unknown case ' + which); process.exit(2); }
log('\n=== case ' + which + ' | ' + label + ' | ' + TREE);
try {
  const result = await CASES[which]();
  log('RESULT ' + JSON.stringify(result));
} catch (error) {
  log('CASE ERROR: ' + error.stack);
  log('RESULT ' + JSON.stringify({label, tree: TREE, error: error.message}));
}
log('  harness cleanup: every child this harness started');
for (const c of CHILDREN) { if (c.pid && alive(c.pid)) log('  ' + killTree(c.pid)); }
process.exit(0);
