#!/usr/bin/env node
// The factory's own temp, bounded - and countable. This pins the two retentions that filled a 477 GB
// disk, in the order the policy states them:
//
//   * scripts/merge-lane.mjs: a passing run removes its own clone; a failing run keeps its own; a run
//     sweeps the family and keeps the newest WA_MERGE_LANE_KEEP leftovers (default 1). A clone whose
//     directory name carries a LIVE pid is never a candidate (the lease), and a name from before the
//     lease is left alone for a grace DERIVED from the two budgets a live run can spend while it holds
//     its clone (gate lane wait + this lane's gate timeout + slack, 10860 s by default) - and past
//     that grace it is still kept whenever this machine can prove the directory is in use.
//   * scripts/test.sh: the same policy for the gate's isolated home, in an EXIT trap that must not
//     change the gate's exit status and must not print one byte after the `smoke ok` verdict line.
//
// The gate half is tested by slicing the REAL file at the marker line that ends its gate-home block
// (`# ---- end of the bounded gate-home block`) and running those exact bytes with a body of one line
// instead of a 20-minute gate. `checkSlice()` fails if the slice no longer ends with the trap, so the
// fixture cannot quietly stop covering the code it claims to cover.
//
// What it also does, because "the bound holds" is a claim about a sequence: it runs N real lane runs
// and prints the size of the family after each one, under the bound and under WA_MERGE_LANE_KEEP=all.
//
// Every run is fenced into a temp root of this file's own (TEMP/TMP/TMPDIR), so it counts its own
// artifacts and can delete nothing of anyone else's.
//
// Usage:  node scripts/test-merge-lane-retention.mjs      (about 40 s, no network, no build)
// NOTE: scripts/test.sh discovers its tests explicitly, and this change was not allowed to alter its
// invocations, so this file is not named by the gate yet: wiring `node scripts/test-merge-lane-retention.mjs`
// beside `node scripts/test-merge-lane.mjs` in scripts/test.sh is what puts it in the gate.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath, pathToFileURL} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const LANE = path.join(here, 'merge-lane.mjs');
const GATE = path.join(here, 'test.sh');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-retention-test-'));
const temp = path.join(root, 'temp');
fs.mkdirSync(temp);
let checks = 0, failed = 0;
const ok = (condition, label, detail) => {
  checks += 1;
  if (condition) console.log(`  ok   ${label}`);
  else { failed += 1; console.log(`  FAIL ${label}${detail ? ` - ${detail}` : ''}`); }
};
function git(cwd, ...args) {
  const result = spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', ...args],
    {cwd, encoding: 'utf8', windowsHide: true});
  if (result.status !== 0) throw Error(`git ${args.join(' ')}: ${result.stderr || result.stdout}`);
  return result.stdout.trim();
}
// Every child runs with this file's temp root as its temp root, so the families below are the only
// ones a sweep can see.
const fenced = extra => ({...process.env, TEMP: temp, TMP: temp, TMPDIR: temp, ...extra, WA_MERGE_LANE_GATE_MODE:'',WA_GATE_LANE_DIR:path.join(root,'gate-lane'),GATE_LANE_HELD:'',GATE_LANE_ORIGIN:'',WA_GATE_LANE_WAIT_SECONDS:'15',WA_GATE_LANE_SAMPLE_SECONDS:'0'});
function lane(repo, args, extra = {}) {
  const result = spawnSync(process.execPath, [LANE, '--repo', repo, '--gate-mode', 'full', '--no-reuse-tree', '--gate-command', 'exit 1', ...args],
    {cwd: repo, encoding: 'utf8', windowsHide: true, env: fenced(extra)});
  let json = null;
  try { json = JSON.parse(result.stdout.trim()); } catch { /* a refusal is JSON too */ }
  return {status: result.status, json, stderr: result.stderr};
}
const family = prefix => fs.readdirSync(temp).filter(name => name.startsWith(prefix)).sort();
function dirBytes(dir) {
  let total = 0;
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const child = path.join(dir, entry.name);
    try { total += entry.isDirectory() ? dirBytes(child) : fs.statSync(child).size; } catch { /* a race is not a size */ }
  }
  return total;
}
const familyBytes = prefix => family(prefix).reduce((sum, name) => sum + dirBytes(path.join(temp, name)), 0);
const mb = bytes => `${(bytes / 1048576).toFixed(1)} MB`;

try {
  // ---- the gate half: the real block, sliced, with a one-line body ---------------------------------
  console.log('gate home (scripts/test.sh, the sliced block)');
  const source = fs.readFileSync(GATE, 'utf8').split('\n');
  const marker = source.findIndex(line => line.startsWith('# ---- end of the bounded gate-home block'));
  ok(marker > 0, 'the slice marker is in scripts/test.sh', String(marker));
  const slice = source.slice(0, marker).join('\n');
  ok(slice.trimEnd().endsWith('trap gate_exit EXIT'),
    'the sliced block ends with the EXIT trap it is testing (the fixture cannot drift from the code)');
  ok(slice.includes('wa-gate-home-$$-XXXXXX') && slice.includes('WA_GATE_HOME_KEEP'),
    'the slice carries the pid lease and the bound');
  fs.mkdirSync(path.join(root,'scripts'),{recursive:true});
  fs.copyFileSync(path.join(here,'check-disk-floor.sh'),path.join(root,'scripts','check-disk-floor.sh'));
  function gateRun(name, body, extra = {}, directory = temp) {
    const script = path.join(root, 'scripts', `${name}.sh`);
    fs.writeFileSync(script, `${slice}\n${body}\n`);
    const result = spawnSync('bash', [script], {cwd: root, encoding: 'utf8', windowsHide: true, env: fenced(extra)});
    return {status: result.status, stdout: result.stdout || '', stderr: result.stderr || '', script};
  }
  const passBody = 'printf \'smoke ok (2 skipped)\\n\'\nexit 0';

  // 1. a failing run keeps its own home, and the EXIT trap does not change what the gate exited with
  const failOne = gateRun('gate-fail-1', 'exit 3');
  ok(failOne.status === 3, 'the trap preserves the exit status it was given', `exit ${failOne.status}`);
  const afterFailOne = family('wa-gate-home-');
  ok(afterFailOne.length === 1, 'a failing run keeps exactly one home (its own)', JSON.stringify(afterFailOne));
  ok(/^wa-gate-home-\d+-[A-Za-z0-9]{6}$/.test(afterFailOne[0] || ''),
    'the home name carries the pid of the run that owns it (the lease)', afterFailOne[0]);
  ok(failOne.stderr.includes(afterFailOne[0] || '\u0000') && failOne.stderr.includes('kept'),
    'and the failing run says where its evidence is', failOne.stderr.trim().split('\n').pop());

  // 2. a passing run costs nothing after the fact, and says nothing after its verdict
  const passOne = gateRun('gate-pass-1', passBody);
  ok(passOne.status === 0, 'a passing run exits 0', `exit ${passOne.status}`);
  ok(passOne.stdout.includes('gate isolated home:'), 'it did make a home (the next check is not vacuous)');
  ok(passOne.stdout.trimEnd().endsWith('smoke ok (2 skipped)'),
    'the verdict line is the LAST line of a passing run: the lane reads a trailing notice as gate_failed',
    JSON.stringify(passOne.stdout.trimEnd().split('\n').slice(-2)));
  ok(passOne.stderr === '', 'a passing run prints nothing on stderr either', JSON.stringify(passOne.stderr));
  ok(family('wa-gate-home-').length === 1 && fs.existsSync(path.join(temp, afterFailOne[0])),
    'the passing run removed its own home and left the failure it did not create', JSON.stringify(family('wa-gate-home-')));

  // 3. a real sequence of N runs: the bound is the newest failure, not one home per failure
  const sequence = [gateRun('gate-fail-2', 'exit 3'), gateRun('gate-fail-3', 'exit 3'), gateRun('gate-fail-4', 'exit 3')];
  ok(sequence.every(run => run.status === 3), 'three more failing runs, each keeping its own at first',
    JSON.stringify(sequence.map(run => run.status)));
  const bounded = family('wa-gate-home-');
  ok(bounded.length === 1, 'after four failing runs the family holds exactly one home', JSON.stringify(bounded));
  ok(sequence.some(run => run.stderr.includes('gate home: removed')),
    'a failing run narrates the home the bound took away (the bound is observable)',
    JSON.stringify(sequence.map(run => run.stderr.trim().split('\n')[0]).slice(0, 2)));
  ok(!fs.existsSync(path.join(temp, afterFailOne[0])), 'the first failure is the one the bound dropped');

  // 4. FALSIFY A: keep everything - the bound gone, the disk grows with the number of runs
  const allOne = gateRun('gate-all-1', 'exit 3', {WA_GATE_HOME_KEEP: 'all'});
  const allTwo = gateRun('gate-all-2', 'exit 3', {WA_GATE_HOME_KEEP: 'all'});
  const allPass = gateRun('gate-all-3', passBody, {WA_GATE_HOME_KEEP: 'all'});
  ok([allOne, allTwo, allPass].every(run => run.status === (run === allPass ? 0 : 3)), 'WA_GATE_HOME_KEEP=all runs');
  ok(family('wa-gate-home-').length === 4,
    'WA_GATE_HOME_KEEP=all keeps every home again (three more, beside the bounded one)',
    JSON.stringify(family('wa-gate-home-').length));

  // 5. FALSIFY B: keep nothing - a failure with nothing left to diagnose
  const zeroOne = gateRun('gate-zero-1', 'exit 3', {WA_GATE_HOME_KEEP: '0'});
  ok(zeroOne.status === 3 && zeroOne.stderr.includes('gate isolated home:') === false,
    'WA_GATE_HOME_KEEP=0 leaves a red gate with no home to point at',
    JSON.stringify(zeroOne.stderr.trim().split('\n').slice(-1)));
  ok(family('wa-gate-home-').length === 0, 'and it removes the family it can remove', JSON.stringify(family('wa-gate-home-')));

  // 6. liveness: a live sibling's home is never a candidate, whatever the bound says
  //    (`>/dev/null` on the child, or the orphan's inherited pipe would keep the probe's parent alive
  //    until the sleep ended - and the "live" pid would be dead by the time the sweep looked at it.)
  const live = spawnSync('bash', ['-c', 'sleep 5 >/dev/null 2>&1 & echo "wa-gate-home-$!-AAbbCc"'],
    {encoding: 'utf8', windowsHide: true, env: fenced()});
  const liveName = String(live.stdout).trim();
  const livePath = path.join(temp, liveName);
  fs.mkdirSync(livePath);
  fs.writeFileSync(path.join(livePath, 'evidence.txt'), 'a live sibling wrote this\n');
  const liveRun = gateRun('gate-live', 'exit 3', {WA_GATE_HOME_KEEP: '0'});
  ok(liveRun.status === 3, 'the sweep ran while a sibling was alive');
  ok(fs.existsSync(livePath), 'a home whose pid is still running is never pruned, not even by WA_GATE_HOME_KEEP=0',
    JSON.stringify(family('wa-gate-home-')));

  // 7. the pre-lease name: kept while it could belong to a run the previous script started, pruned after
  const legacyYoung = path.join(temp, 'wa-gate-home-YYbbCC');
  const legacyOld = path.join(temp, 'wa-gate-home-ZZccDD');
  fs.mkdirSync(legacyYoung); fs.mkdirSync(legacyOld);
  const old = new Date(Date.now() - 2 * 60 * 60 * 1000);
  fs.utimesSync(legacyOld, old, old);
  const legacyRun = gateRun('gate-legacy', 'exit 3', {WA_GATE_HOME_KEEP: '0'});
  ok(legacyRun.status === 3 && fs.existsSync(legacyYoung),
    'a pre-lease home younger than the grace window is left alone (a rollout cannot delete a live gate\'s home)');
  ok(!fs.existsSync(legacyOld), 'a pre-lease home older than an hour is pruned');

  // 8. a knob that is not a count and not `all` is refused before a home is made
  const bad = gateRun('gate-bad-knob', passBody, {WA_GATE_HOME_KEEP: 'twelve'});
  ok(bad.status === 4 && bad.stderr.includes('WA_GATE_HOME_KEEP must be'),
    'a knob that is neither a count nor `all` is refused, not guessed', `exit ${bad.status}`);

  // ---- the merge lane's half: the same policy on the clone ----------------------------------------
  console.log('merge-lane clones (a real sequence of lane runs)');
  const repo = path.join(root, 'repo');
  fs.mkdirSync(repo);
  git(root, 'init', '-q', '--initial-branch=main', repo);
  git(repo, 'config', 'core.autocrlf', 'false');
  fs.writeFileSync(path.join(repo, 'a.txt'), 'base\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'base');
  git(repo, 'switch', '-q', '-c', 'change/one');
  fs.writeFileSync(path.join(repo, 'b.txt'), 'one\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'one');
  git(repo, 'switch', '-q', 'main');

  // The payload is what a real gate puts in a clone: `rust/target`, ~1.1 GB. It stands in for the
  // build so that this sequence costs seconds; the bytes below are real bytes on this disk.
  const payload = 'python -c "open(\'payload.bin\',\'wb\').truncate(20*1024*1024)"';
  const failGate = [`--gate-command`, payload];
  const run1 = lane(repo, ['--base', 'main', 'change/one', ...failGate]);
  ok(run1.status === 3, 'the lane gates the merged tree and the gate fails', `exit ${run1.status}`);
  const held1 = family('wa-merge-lane-');
  ok(held1.length === 1 && /^wa-merge-lane-\d+-[A-Za-z0-9]{6}$/.test(held1[0]),
    'the failing run keeps its own clone, named with its lease', JSON.stringify(held1));
  ok(run1.json?.retention?.keep === 1 && run1.json?.clone?.retained === true,
    'the record says what it kept and what the bound is', JSON.stringify(run1.json?.retention?.keep));
  const sizeOfOne = familyBytes('wa-merge-lane-');

  // A real sequence under the bound: each failing run takes the family over, so N runs cost one clone.
  const held = [];
  for (const round of [2, 3, 4]) {
    const run = lane(repo, ['--base', 'main', 'change/one', ...failGate]);
    held.push(`${round}: ${family('wa-merge-lane-').length} clones, ${mb(familyBytes('wa-merge-lane-'))}`);
    ok(run.status === 3 && family('wa-merge-lane-').length === 1,
      `run ${round} of 4: one clone retained, not ${round}`, JSON.stringify(family('wa-merge-lane-')));
  }
  console.log(`       bounded:  ${['1: 1 clone, ' + mb(sizeOfOne), ...held].join(' | ')}`);

  const before = family('wa-merge-lane-');
  const passing = lane(repo, ['--base', 'main', 'change/one', '--gate-command', 'printf \'smoke ok\\n\'']);
  ok(passing.status === 0 && passing.json?.verdict === 'pass', 'a passing run is a pass', JSON.stringify(passing.json?.verdict));
  ok(passing.json?.clone === null || passing.json?.clone?.removed === true,
    'a passing run removes its own clone', JSON.stringify(passing.json?.clone));
  ok(JSON.stringify(family('wa-merge-lane-')) === JSON.stringify(before),
    'and it left the failure that was already there exactly as it was', JSON.stringify(family('wa-merge-lane-')));

  // FALSIFY A: keep everything - four more failing runs, four more ~1.1 GB clones on a real gate
  const unbounded = [];
  for (const round of [1, 2, 3, 4]) {
    const run = lane(repo, ['--base', 'main', 'change/one', ...failGate], {WA_MERGE_LANE_KEEP: 'all'});
    unbounded.push(`${round}: ${family('wa-merge-lane-').length} clones, ${mb(familyBytes('wa-merge-lane-'))}`);
    ok(run.status === 3, `keep-everything run ${round} still gates and fails`, `exit ${run.status}`);
  }
  console.log(`       unbounded: ${unbounded.join(' | ')}`);
  ok(family('wa-merge-lane-').length === 5,
    'WA_MERGE_LANE_KEEP=all reproduces the leak: every failing run keeps its clone forever',
    JSON.stringify(family('wa-merge-lane-').length));

  // FALSIFY B: keep nothing - the red run's tree is gone, and nothing says which tree it was
  const nothing = lane(repo, ['--base', 'main', 'change/one', ...failGate], {WA_MERGE_LANE_KEEP: '0'});
  ok(nothing.status === 3 && nothing.json?.clone?.retained === false && nothing.json?.clone?.removed === true,
    'WA_MERGE_LANE_KEEP=0 removes even the failing run\'s clone', JSON.stringify(nothing.json?.clone));
  ok(family('wa-merge-lane-').length === 0, 'and the family is empty: nothing left to re-run or inspect',
    JSON.stringify(family('wa-merge-lane-')));

  // 6'. the lease, observed rather than asserted: a live lane's clone and a foreign family are untouched.
  //     The sleeper is a node process because that is what a lane is: the lease is readable by the same
  //     runtime that wrote it (`process.kill(pid, 0)`), and a pid from another runtime is not a lease.
  const sweeper = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 6000)'], {stdio: 'ignore', env: fenced()});
  sweeper.unref();
  const liveClone = path.join(temp, `wa-merge-lane-${sweeper.pid}-ddEEff`);
  const foreign = path.join(temp, 'wa-merge-lane-test-ABCDEF');
  const dead = spawnSync(process.execPath, ['-e', ''], {encoding: 'utf8', windowsHide: true, env: fenced()});
  const deadClone = path.join(temp, `wa-merge-lane-${dead.pid}-ggHHii`);
  fs.mkdirSync(liveClone); fs.mkdirSync(foreign); fs.mkdirSync(deadClone);
  const sweepRun = lane(repo, ['--base', 'main', 'change/one', ...failGate], {WA_MERGE_LANE_KEEP: '0'});
  ok(sweepRun.status === 3, 'the sweep ran');
  ok(fs.existsSync(liveClone), 'a clone of a live run is never a candidate, whatever the bound says',
    JSON.stringify(family('wa-merge-lane-')));
  ok(fs.existsSync(foreign), 'the fixture family wa-merge-lane-test-* is not this lane\'s to delete');
  ok(fs.existsSync(deadClone) === false, 'a clone whose owner is gone is pruned');
  try { sweeper.kill(); } catch { /* it is a probe */ }

  // 9. the pre-lease grace: DERIVED from the budgets it must beat, and never the only evidence.
  //    D1 of the review (verify/REVIEW-disk-temp.md) reproduced the defect this pins: the flat hour
  //    was shorter than the gate lane's own 2 h wait budget (7200 s) while a clone is made BEFORE the
  //    slot is waited for, so a LIVE pre-change run's clone was deleted by the sweep.
  const laneModule = await import(pathToFileURL(LANE).href);
  const DERIVED = (7200 + 3600 + 60) * 1000;
  ok(laneModule.legacyGraceMs({waitSeconds: 7200, gateTimeoutSeconds: 3600}) === DERIVED,
    'the pre-lease grace is the gate lane wait (7200) + the gate timeout (3600) + 60 s slack = 10860 s',
    String(laneModule.legacyGraceMs({waitSeconds: 7200, gateTimeoutSeconds: 3600})));
  ok(laneModule.legacyGraceMs({waitSeconds: 60, gateTimeoutSeconds: 30}) === 150 * 1000,
    'and it follows the budgets it is made of instead of being a round number',
    String(laneModule.legacyGraceMs({waitSeconds: 60, gateTimeoutSeconds: 30})));
  ok(laneModule.legacyGraceMs({waitSeconds: 7200, gateTimeoutSeconds: 60}) === (7200 + 60 + 60) * 1000,
    'this lane own --timeout-seconds moves it',
    String(laneModule.legacyGraceMs({waitSeconds: 7200, gateTimeoutSeconds: 60})));
  ok(run1.json?.retention?.sweeps?.length &&
    run1.json.retention.sweeps.every(sweep => sweep.grace_ms > 3600 * 1000),
    'every sweep a real run made recorded a grace longer than a gate alone can live',
    JSON.stringify(run1.json?.retention?.sweeps?.map(sweep => sweep.grace_seconds)));
  const idleOld = path.join(temp, 'wa-merge-lane-Idle09');
  const heldOld = path.join(temp, 'wa-merge-lane-Held09');
  fs.mkdirSync(idleOld); fs.mkdirSync(heldOld);
  fs.writeFileSync(path.join(heldOld, 'target.bin'), 'the tree a live run is building in\n');
  for (const dir of [idleOld, heldOld]) {
    const when = new Date(Date.now() - 3.5 * 60 * 60 * 1000);   // past EVERY grace, old and new
    fs.utimesSync(dir, when, when);
  }
  // A native process whose working directory is that clone: measured EBUSY for a same-parent rename,
  // and `rm -rf` is refused by Windows in that state only sometimes - which is why the sweep asks.
  const worker = spawn(process.execPath,
    ['-e', `process.chdir(${JSON.stringify(heldOld)}); setTimeout(() => {}, 8000)`], {stdio: 'ignore', env: fenced()});
  worker.unref();
  await new Promise(resolve => setTimeout(resolve, 1500));
  const evidenceSweep = laneModule.sweepClones({keep: 0, tmp: temp});
  ok(!fs.existsSync(idleOld), 'an idle pre-lease clone past the grace is still pruned: the bound is not gone',
    JSON.stringify(family('wa-merge-lane-')));
  ok(fs.existsSync(heldOld),
    'a pre-lease clone a live process is WORKING IN is not pruned, whatever its age',
    JSON.stringify(family('wa-merge-lane-')));
  ok(evidenceSweep.in_use.some(entry => entry.path.includes('Held09') && /EBUSY|EPERM/.test(entry.evidence)),
    'and the record names the evidence instead of the clock',
    JSON.stringify(evidenceSweep.in_use.map(entry => entry.evidence)));
  try { worker.kill(); } catch { /* it is a probe */ }
} catch (error) {
  failed += 1;
  console.log(`  FAIL harness - ${error.message}`);
} finally {
  fs.rmSync(root, {recursive: true, force: true});
  console.log(failed ? `temp retention: ${checks - failed}/${checks} ok, ${failed} FAILED` : `temp retention ok (${checks} checks)`);
  process.exitCode = failed ? 1 : 0;
}
