#!/usr/bin/env node
// Repair harness for D1's pre-lease grace (see verify/STATUS-prelease-grace.md).
//
// The scenario is the review's own: a REAL pre-change lane run (main's `scripts/merge-lane.mjs`,
// which mints the pre-lease name `wa-merge-lane-XXXXXX`), alive, holding its own clone, whose clone
// mtime is aged the way a long wait for the gate slot ages it, beside a newer dead leftover (keep=1
// keeps the newest). The SAME scenario is run against two real modules: the delivery tip's
// `sweepClones` and this branch's, and both are printed.
//
//   node verify/prelease-grace.mjs <tipTree> <fixedTree> <preChangeTree> <A|B|C|D>
//
// A  the review's reproduction: the live run is INSIDE ITS GATE, clone aged 2 h
// B  the actual scenario: a real slot is held (a real `gate-lane.mjs acquire` in a scratch store of
//    its own - NOT the live lane's), the run is QUEUED and has no slot yet, clone aged 2 h
// C  evidence over age: an idle pre-lease clone aged past the derived grace (must go) and one held
//    by a real native process (must stay), both older than any grace
// D  the bound: a stale idle pre-lease family still loses all but the newest, and keep=all - the
//    inherited falsifier - keeps everything
//
// Every root is a mkdtemp under this repair's scratch root and every child gets TEMP/TMP/TMPDIR
// pinned to it, so no sweep here can see - let alone delete - a real wa-merge-lane-* / wa-gate-home-*
// family. Each case prints its root, its pids, the family before and after, and cleans up after
// itself.
import fs from 'node:fs';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

const [tipTree, fixedTree, preTree, which = 'A'] = process.argv.slice(2);
if (!tipTree || !fixedTree || !preTree) {
  console.error('usage: node verify/prelease-grace.mjs <tipTree> <fixedTree> <preChangeTree> <A|B|C|D>');
  process.exit(2);
}
const SCRATCH = process.env.WA_REPAIR_SCRATCH || 'C:/Users/Victor/.wasm-agent/wa-repair-c78ab73';
const HOUR = 3600 * 1000;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const listed = root => fs.readdirSync(root).sort().join(', ') || '(empty)';
const isLegacy = name => /^wa-merge-lane-[A-Za-z0-9]{6}$/.test(name);
const age = (dir, ms) => { const when = new Date(Date.now() - ms); fs.utimesSync(dir, when, when); };
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
// The lane prints one JSON object as its last line; that object carries the verdict, which is what a
// pre-change run's own words amount to here (its gate's stdout goes to its own log, not to us).
const verdictOf = out => {
  for (const line of out.split('\n').reverse()) {
    try {
      const json = JSON.parse(line.trim());
      if (json && json.verdict) return `${json.verdict} (exit_code ${json.exit_code}${json.error ? `, ${json.error}` : ''})`;
    } catch { /* not the JSON line */ }
  }
  return '(no verdict object) - the run never got that far';
};

function workRoot(caseName) {
  fs.mkdirSync(SCRATCH, {recursive: true});
  const root = fs.mkdtempSync(path.join(SCRATCH, `case-${caseName}-`));
  fs.mkdirSync(path.join(root, 'temp'));
  return {root, temp: path.join(root, 'temp')};
}
function makeRepo(dir) {
  fs.mkdirSync(dir);
  const git = (...args) => {
    const result = spawnSync('git', ['-c', 'user.name=f', '-c', 'user.email=f@x', ...args], {cwd: dir, encoding: 'utf8', windowsHide: true});
    if (result.status !== 0) throw Error(`git ${args.join(' ')}: ${result.stderr}`);
  };
  git('init', '-q', '--initial-branch=main', '.');
  fs.writeFileSync(path.join(dir, 'a.txt'), 'base\n'); git('add', '-A'); git('commit', '-q', '-m', 'base');
  git('switch', '-q', '-c', 'change/one');
  fs.writeFileSync(path.join(dir, 'b.txt'), 'one\n'); git('add', '-A'); git('commit', '-q', '-m', 'one');
  git('switch', '-q', 'main');
  return dir;
}
// The pre-change lane, as main mints it: `wa-merge-lane-XXXXXX`, no pid in the name, no sweep of its own.
const GATE_COMMAND = 'printf "GATE_STARTED\\n"; sleep 40; '
  + 'if [ -f a.txt ]; then echo "PROBE clone intact"; else echo "PROBE CLONE GONE"; exit 7; fi';

// Run the module under test in a child (its own os.tmpdir()), and report the sweep record it made.
function sweepWith(tree, args) {
  const module = pathToFileURL(path.join(tree, 'scripts', 'merge-lane.mjs')).href;
  const result = spawnSync(process.execPath, ['-e', `
    const {sweepClones} = await import(${JSON.stringify(module)});
    const record = sweepClones(${JSON.stringify(args)});
    const base = p => String(p).split(/[\\\\/]/).pop();
    process.stdout.write('SWEEP ' + JSON.stringify({
      grace_seconds: record.grace_ms / 1000, keep: record.keep, budget_for_others: record.budget_for_others,
      removed: (record.removed || []).map(r => [base(r.path), r.evidence]),
      kept: (record.kept || []).map(r => base(r.path)),
      recent_legacy: (record.recent_legacy || []).map(base),
      live: (record.live || []).length, in_use: (record.in_use || []).map(r => [base(r.path), r.evidence]),
      errors: (record.errors || []).map(e => e.error)}));
  `], {encoding: 'utf8', windowsHide: true, env: {...process.env, TEMP: args.tmp, TMP: args.tmp, TMPDIR: args.tmp}});
  const line = String(result.stdout || '').split('\n').find(l => l.startsWith('SWEEP '));
  if (!line) return `sweep did not report: ${String(result.stderr || '').trim().split('\n').slice(-2).join(' | ')}`;
  return line.slice('SWEEP '.length);
}

function startPreChangeRun(repo, temp, extraEnv = {}) {
  const child = spawn(process.execPath, [path.join(preTree, 'scripts', 'merge-lane.mjs'),
    '--repo', repo, '--base', 'main', '--gate-command', GATE_COMMAND, 'change/one'],
  {cwd: repo, env: {...process.env, TEMP: temp, TMP: temp, TMPDIR: temp, WA_GATE_LANE: 'off', ...extraEnv},
    stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  child.out = '';
  child.stdout.on('data', d => { child.out += d; });
  child.stderr.on('data', d => { child.out += d; });
  return child;
}
const waitExit = child => new Promise(resolve => child.on('exit', code => resolve(code)));

// A: the review's reproduction, one module under test.
async function caseA(tree) {
  const {root, temp} = workRoot('A');
  const repo = makeRepo(path.join(root, 'repo'));
  console.log(`  scratch root / fenced temp root: ${temp}`);
  const live = startPreChangeRun(repo, temp);
  console.log(`  pre-change lane run (main's merge-lane), pid ${live.pid}`);
  await sleep(4000);
  const names = fs.readdirSync(temp).filter(isLegacy);
  if (names.length !== 1) throw Error(`expected one pre-lease clone, saw ${listed(temp)}`);
  const dir = path.join(temp, names[0]);
  age(dir, 2 * HOUR);
  fs.mkdirSync(path.join(temp, 'wa-merge-lane-Cand01'));
  age(path.join(temp, 'wa-merge-lane-Cand01'), 90 * 60 * 1000);
  console.log(`  its clone ${names[0]}: aged to 2.0 h (this gate lane's own record shows slot waits of`);
  console.log('  4909 s and 5399 s), beside the newer dead leftover wa-merge-lane-Cand01 (90 min)');
  console.log(`  BEFORE: ${listed(temp)}`);
  console.log(`  sweep (${tree}): ${sweepWith(tree, {keep: 1, tmp: temp})}`);
  const survived = fs.existsSync(dir);
  const exit = await waitExit(live);
  console.log(`  AFTER:  ${listed(temp)}`);
  console.log(`  the live run's clone exists after the sweep: ${survived}`);
  console.log(`  its exit: ${exit}; the verdict it printed: ${verdictOf(live.out)}`);
  if (fs.existsSync(path.dirname(temp))) fs.rmSync(root, {recursive: true, force: true});
  console.log(`  cleanup: scratch root removed = ${!fs.existsSync(root)}`);
  return {survived};
}

// B: the queue case. One module under test.
async function caseB(tree) {
  const {root, temp} = workRoot('B');
  const repo = makeRepo(path.join(root, 'repo'));
  const store = path.join(root, 'gate-lane');
  console.log(`  scratch root / fenced temp root: ${temp}`);
  console.log(`  scratch gate-lane store (NOT the live lane's): ${store}`);
  const holder = spawn(process.execPath, [path.join(preTree, 'scripts', 'gate-lane.mjs'), 'acquire',
    '--dir', store, '--cwd', root, '--holder-pid', String(process.pid), '--wait-seconds', '900'],
  {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  holder.out = '';
  holder.stdout.on('data', d => { holder.out += d; });
  await sleep(3000);
  console.log(`  slot holder pid ${holder.pid}: a real \`gate-lane.mjs acquire\` holding the only slot`);
  const run = startPreChangeRun(repo, temp,
    {WA_GATE_LANE: '', WA_GATE_LANE_DIR: store, WA_GATE_LANE_CAPACITY: '1', WA_GATE_LANE_WAIT_SECONDS: '900'});
  console.log(`  pre-change lane run pid ${run.pid}: it has made its clone and must WAIT for the slot`);
  await sleep(7000);
  const gateRan = run.out.includes('GATE_STARTED');
  const names = fs.readdirSync(temp).filter(isLegacy);
  console.log(`  queued: the gate has started = ${gateRan}; clone = ${names[0] || '(none)'}`);
  console.log(`  the run's own words: ${(run.out.split('\n').filter(l => l.trim()).slice(-1)[0] || '').trim()}`);
  if (names.length !== 1 || gateRan) throw Error(`the run is not queued (clone=${names[0]}, gate ran=${gateRan})`);
  const dir = path.join(temp, names[0]);
  age(dir, 2 * HOUR);
  fs.mkdirSync(path.join(temp, 'wa-merge-lane-Cand02'));
  age(path.join(temp, 'wa-merge-lane-Cand02'), 90 * 60 * 1000);
  console.log(`  its clone ${names[0]} aged to 2.0 h, beside the newer dead wa-merge-lane-Cand02 (90 min)`);
  console.log(`  BEFORE: ${listed(temp)}`);
  console.log(`  sweep (${tree}): ${sweepWith(tree, {keep: 1, tmp: temp})}`);
  const survived = fs.existsSync(dir);
  console.log(`  AFTER:  ${listed(temp)}`);
  console.log(`  the QUEUED run's clone exists after the sweep: ${survived}; the run is still alive: ${alive(run.pid)}`);
  run.kill(); holder.kill();
  await sleep(1000);
  console.log(`  cleanup (by pid): run ${run.pid} alive=${alive(run.pid)}, holder ${holder.pid} alive=${alive(holder.pid)}`);
  try { run.kill('SIGKILL'); } catch { /* already gone */ }
  try { holder.kill('SIGKILL'); } catch { /* already gone */ }
  fs.rmSync(root, {recursive: true, force: true});
  console.log(`  cleanup: scratch root removed = ${!fs.existsSync(root)}`);
  return {survived};
}

// C: evidence over age. One module under test.
async function caseC(tree) {
  const {root, temp} = workRoot('C');
  const idle = path.join(temp, 'wa-merge-lane-Idle90');
  const held = path.join(temp, 'wa-merge-lane-Held90');
  fs.mkdirSync(idle); fs.mkdirSync(held);
  fs.writeFileSync(path.join(held, 'evidence.txt'), 'the tree this run is building in\n');
  age(idle, 3.5 * HOUR); age(held, 3.5 * HOUR);
  // A real native process whose working directory is the clone - how this lane spawns its own gate
  // (`spawnSync('bash', ..., {cwd: clone.dir})`), measured EBUSY in verify/probe-holders.mjs.
  const holder = spawn(process.execPath, ['-e', `process.chdir(${JSON.stringify(held)}); setTimeout(()=>{}, 60000)`],
    {stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true});
  await sleep(1500);
  console.log(`  scratch root: ${temp}`);
  console.log(`  two pre-lease clones, both aged 3.5 h (past every grace): ${listed(temp)}`);
  console.log(`  one is held by a real process (pid ${holder.pid}, working directory inside it)`);
  console.log(`  sweep keep=0 (${tree}): ${sweepWith(tree, {keep: 0, tmp: temp})}`);
  const idleGone = !fs.existsSync(idle), heldThere = fs.existsSync(held);
  console.log(`  the IDLE stale clone is gone: ${idleGone}; the HELD one is still there: ${heldThere}`);
  holder.kill();
  await sleep(700);
  console.log(`  cleanup (by pid): holder ${holder.pid} alive=${alive(holder.pid)}`);
  fs.rmSync(root, {recursive: true, force: true});
  console.log(`  cleanup: scratch root removed = ${!fs.existsSync(root)}`);
  return {idleGone, heldThere};
}

// D: the bound, and the inherited falsifier. One module under test.
async function caseD(tree) {
  const {root, temp} = workRoot('D');
  const plant = () => ['Oldest', 'Middle', 'Newest'].forEach((name, index) => {
    const dir = path.join(temp, `wa-merge-lane-${name}`);
    fs.mkdirSync(dir, {recursive: true});
    age(dir, (6 - index * 0.5) * HOUR);   // 6 h / 5.5 h / 5 h: all past the derived grace (3 h 1 min)
  });
  plant();
  console.log(`  a stale pre-lease family (all older than the derived grace): ${listed(temp)}`);
  console.log(`  sweep keep=1 (${tree}): ${sweepWith(tree, {keep: 1, tmp: temp})}`);
  const bounded = fs.readdirSync(temp).length === 1 && fs.existsSync(path.join(temp, 'wa-merge-lane-Newest'));
  console.log(`  family after: ${listed(temp)} - newest kept, older two removed: ${bounded}`);
  plant();
  console.log(`  sweep keep=all, the inherited falsifier (${tree}): ${sweepWith(tree, {keep: 'all', tmp: temp})}`);
  const destroyed = fs.readdirSync(temp).length === 3;
  console.log(`  family after the falsifier: ${listed(temp)} - nothing removed: ${destroyed}`);
  fs.rmSync(root, {recursive: true, force: true});
  console.log(`  cleanup: scratch root removed = ${!fs.existsSync(root)}`);
  return {bounded, destroyed};
}

const CASES = {A: caseA, B: caseB, C: caseC, D: caseD};
const selected = which === 'all' ? ['A', 'B', 'C', 'D'] : [which];
const results = {};
for (const name of selected) {
  if (!CASES[name]) { console.error(`unknown case ${name}`); process.exit(2); }
  for (const [label, tree] of [['DELIVERY TIP c78ab731', tipTree], ['THIS BRANCH (the fix)', fixedTree]]) {
    console.log(`\n=== case ${name} | ${label} | ${tree}`);
    try { results[`${name}:${label}`] = await CASES[name](tree); }
    catch (error) { console.log(`  CASE ERROR: ${error.message}`); results[`${name}:${label}`] = {error: error.message}; }
  }
}
console.log(`\nSUMMARY ${JSON.stringify(results)}`);
