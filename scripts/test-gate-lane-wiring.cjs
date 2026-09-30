// The gate lane's two consumers, tested through the paths that actually run: `finish.mjs gate`
// (skills/parallel-evolution/scripts/finish.mjs) and `merge-lane.mjs`. Both spawn `bash scripts/test.sh`
// themselves and neither coordinated with the other, which is why the same four-tree candidate passed
// alone and failed twice under contention. What is under test here is *when* a gate runs, never what
// it is: the gates in these fixtures are stand-ins (`scripts/test.sh` in a fixture, and
// `--gate-command`), the way `scripts/test-gate-lane.cjs` already stands one in for the lane itself.
//
// Each check exists for a way the wiring could lie:
//   * a pair of real consumers requested together: one holds the slot, the other's lane record names
//     the holder, how long it has held it and its depth - not just "queued";
//   * the waiter then runs and its own verdict and skip count are unchanged by having waited;
//   * a gate inside a gate (the repository gate runs `finish.mjs gate` in scripts/test-parallel-
//     finish.mjs) inherits the admission instead of asking again, so it cannot deadlock the gate it
//     runs inside;
//   * a lane that IS reached and refuses a slot is terminal: the gate does NOT run, and both
//     consumers report the holder rather than a pass (finish: gate_verified false; merge lane:
//     verdict gate_refused, exit 6);
//   * a lane that CANNOT be consulted (an unreadable store, a version skew) does not stop the gate:
//     it runs, is still verified, and says it ran without a slot. `WA_GATE_LANE=off` says the same
//     thing on purpose, and neither takes a record in the lane.
//
// Usage: node scripts/test-gate-lane-wiring.cjs   (about 40 s; git fixtures, no network, no build)
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const {spawn, spawnSync} = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const finishRunner = path.join(repo, 'skills', 'parallel-evolution', 'scripts', 'finish.mjs');
const mergeRunner = path.join(repo, 'scripts', 'merge-lane.mjs');
const laneCli = path.join(repo, 'scripts', 'gate-lane.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-gate-lane-wiring-'));
const state = path.join(root, 'lane');                    // the lane this test owns
const notAStore = path.join(root, 'not-a-directory');     // a "store" that cannot be opened
const children = new Set();
let checks = 0;
const check = (value, label, detail) => {
  assert.ok(value, `${label}${detail === undefined ? '' : ` - ${detail}`}`);
  checks += 1;
};
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
// bash, not node, is what runs these paths on Windows too, so paths are handed over as bash sees them.
const sh = value => String(value).replaceAll('\\', '/');
const laneEnv = extra => ({WA_GATE_LANE_DIR: state, ...extra});
// Live consumers, so a failure prints what they said rather than only what the lane recorded.
const live = {};
const said = record => record === undefined ? '(not started)'
  : `status=${record.status} stdout=${String(record.stdout).slice(0, 900)}`
  + ` stderr=${String(record.stderr).slice(0, 900)}`;
const diagnostics = () => ['holder: ' + said(live.holder), 'waiter: ' + said(live.waiter),
  `env GATE_LANE_HELD=${process.env.GATE_LANE_HELD === undefined ? 'unset' : process.env.GATE_LANE_HELD}`]
  .join('\n');

function run(program, args, {cwd = repo, env = laneEnv()} = {}) {
  const result = spawnSync(program, args, {cwd, encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024,
    env: {...process.env, ...env}});
  return {status: result.status, stdout: String(result.stdout || ''),
    stderr: result.error ? result.error.message : String(result.stderr || '')};
}
function git(cwd, ...args) {
  const result = run('git', args, {cwd, env: {}});
  assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr || result.stdout}`);
  return result.stdout.trim();
}
function background(program, args, {cwd = repo, env = laneEnv()} = {}) {
  const child = spawn(program, args, {cwd, windowsHide: true, env: {...process.env, ...env},
    stdio: ['ignore', 'pipe', 'pipe']});
  children.add(child);
  const record = {child, pid: child.pid, stdout: '', stderr: '', status: null};
  child.stdout.on('data', chunk => { record.stdout += chunk; });
  child.stderr.on('data', chunk => { record.stderr += chunk; });
  record.done = new Promise(resolve => child.on('close', code => {
    record.status = code; children.delete(child); resolve(record);
  }));
  return record;
}
const laneSync = (args, env = {}) => run(process.execPath, [laneCli, ...args], {env: laneEnv(env)});
const status = () => JSON.parse(laneSync(['status', '--json', '--limit', '50']).stdout);
const rows = snapshot => [...snapshot.held, ...snapshot.queue, ...snapshot.recent];
const rowOf = (snapshot, label) => rows(snapshot).find(entry => entry.label === label);
const historyOf = request => JSON.parse(laneSync(['history', '--json', '--limit', '200']).stdout)
  .filter(entry => entry.request === request).map(entry => entry.action).reverse();
const jsonOf = text => JSON.parse(text.slice(text.indexOf('{')));
async function until(operation, label, ms = 90000) {
  const deadline = Date.now() + ms;
  let last = null;
  while (Date.now() < deadline) {
    last = await operation();
    if (last) return last;
    await sleep(200);
  }
  throw Error(`timed out waiting for ${label}; last lane state: ${JSON.stringify(status(), null, 1)}`);
}

// A tree `finish.mjs` will agree to gate: clean, published, and current against origin/main. Its gate
// is a stand-in committed in the fixture, never the repository's scripts/test.sh.
function finishFixture(name, gateScript) {
  const remote = path.join(root, `${name}.git`);
  const dir = path.join(root, name);
  fs.mkdirSync(path.join(dir, 'scripts'), {recursive: true});
  git(root, 'init', '--bare', '-q', remote);
  git(root, 'init', '-q', '--initial-branch=main', dir);
  // The machine-wide core.autocrlf here is `true`; a fixture gate with CRLF line endings is not a
  // shell script (`sleep 10\r`). This states what the repository states.
  git(dir, 'config', 'core.autocrlf', 'false');
  git(dir, 'config', 'user.name', 'fixture');
  git(dir, 'config', 'user.email', 'fixture@local.invalid');
  fs.writeFileSync(path.join(dir, 'scripts', 'test.sh'), gateScript);
  git(dir, 'add', '-A');
  git(dir, 'commit', '-qm', `fixture: ${name}`);
  git(dir, 'remote', 'add', 'origin', remote);
  git(dir, 'push', '-q', '-u', 'origin', 'main');
  git(dir, 'switch', '-q', '-c', name);
  git(dir, 'push', '-q', '-u', 'origin', name);
  return {dir, head: git(dir, 'rev-parse', 'HEAD'), file: file => path.join(root, file)};
}

// The merge lane's own seam for discovery is WA_MERGE_LANE_AUDIT (a test seam, by that file's own
// header), so the fixture repository needs no remote and no network.
function mergeFixture() {
  const dir = path.join(root, 'merge-repo');
  fs.mkdirSync(dir);
  git(root, 'init', '-q', '--initial-branch=main', dir);
  git(dir, 'config', 'core.autocrlf', 'false');
  git(dir, 'config', 'user.name', 'fixture');
  git(dir, 'config', 'user.email', 'fixture@local.invalid');
  fs.writeFileSync(path.join(dir, 'base.txt'), 'base\n');
  git(dir, 'add', '-A');
  git(dir, 'commit', '-qm', 'fixture: base');
  git(dir, 'switch', '-q', '-c', 'change/tip');
  fs.writeFileSync(path.join(dir, 'tip.txt'), 'tip\n');
  git(dir, 'add', '-A');
  git(dir, 'commit', '-qm', 'feat(tip): a file');
  git(dir, 'switch', '-q', 'main');
  const audit = path.join(root, 'audit-fixture.mjs');
  fs.writeFileSync(audit, `import {spawnSync} from 'node:child_process';
export function audit(repo,{target='main'}={}) {
  const r=spawnSync('git',['rev-parse','--verify',target+'^{commit}'],{cwd:repo,encoding:'utf8',windowsHide:true});
  return {schema_version:1,repo,target,target_sha:r.status===0?r.stdout.trim():null,discovery_complete:true,
    integration_complete:false,pending_tips:1,errors:[],candidates:[],worktrees:[],
    counts:{candidate_tips:0,pending_tips:1,gate_run_count:0},timings_ms:{total_ms:0}};
}
`);
  return {dir, tip: 'change/tip', env: extra => laneEnv({WA_MERGE_LANE_AUDIT: audit, ...extra})};
}
const merge = (fixture, args, env = {}) => run(process.execPath, [mergeRunner, '--repo', fixture.dir, ...args],
  {env: fixture.env(env)});

async function main() {
  const passGate = "echo \"fixture gate\"; echo \"smoke ok (2 skipped)\"";
  const mergeFixtureA = mergeFixture();

  // ---- 1. Two real consumers at once: one holds the slot, the other is named while it waits -----
  // The holder's own gate contains a nested gate (`finish.mjs gate` on another tree), which is what
  // the repository gate does at scripts/test.sh:48 through scripts/test-parallel-finish.mjs - and the
  // holder's stand-in gate applies the repository gate's own environment fence first, because that
  // fence (scripts/test.sh unsets every WA_*/WASM_AGENT_* variable) is what the admission marker has
  // to survive. The fence text is taken from the real file rather than copied, so a fence that grows
  // to cover the marker fails this test instead of deadlocking a real gate behind its own suite.
  const nested = finishFixture('nested', "printf 'smoke ok (0 skipped)\\n'\n");
  const nestedOut = path.join(root, 'nested.json');
  const nestedErr = path.join(root, 'nested.err');
  const fenceOut = path.join(root, 'fence.txt');
  const fence = path.join(repo, 'scripts', 'test.sh');
  const holder = finishFixture('holder',
    'if [ -f "' + sh(fence) + '" ]; then\n'
    + '  fence="$(sed -n \'/^while IFS= read -r variable; do$/,/^done < <(compgen -e)$/p\' "'
    + sh(fence) + '")"\n'
    + '  printf \'%s\' "$fence" | grep -q "unset" || { echo "wrong gate, not the repository one"; exit 9; }\n'
    + '  eval "$fence"\n'
    + 'fi\n'
    + 'printf \'WA_GATE_LANE_DIR=%s GATE_LANE_HELD=%s WA_GATE_JOBS=%s\\n\' "${WA_GATE_LANE_DIR-unset}"'
    + ' "${GATE_LANE_HELD-unset}" "${WA_GATE_JOBS-unset}" > "' + sh(fenceOut) + '"\n'
    + `sleep 15\n"${sh(process.execPath)}" "${sh(finishRunner)}" gate "${sh(nested.dir)}" "${nested.head}"`
    + ` > "${sh(nestedOut)}" 2> "${sh(nestedErr)}"\nsleep 15\nprintf 'smoke ok (2 skipped)\\n'\n`);
  check(process.env.GATE_LANE_HELD === undefined,
    'this test itself starts outside any gate, so the holder has to ask for its slot');
  const holderRun = background(process.execPath, [finishRunner, 'gate', holder.dir, holder.head],
    {env: laneEnv({WA_GATE_JOBS: '2'})});
  live.holder = holderRun;
  const heldRow = await until(async () => {
    const entry = rowOf(status(), 'finish holder');
    return entry && entry.state === 'running' ? entry : null;
  }, 'the holder to take the slot');
  check(heldRow.mode === 'acquire' && heldRow.holder_pid !== null,
    'the holder asked for a slot with acquire, so it kept its own runner', JSON.stringify(heldRow.mode));

  const foreignRelease=laneSync(['release','--id',String(heldRow.id),'--exit','0']);
  check(foreignRelease.status===1 && /only the acquire holder/.test(foreignRelease.stderr),
    'a sibling cannot release a real reservation by knowing its row number');
  check(rowOf(status(),'finish holder').state==='running','foreign release preserves real work');
  const fake=finishFixture('forged-inheritance',"printf 'smoke ok (0 skipped)\\n'\n");
  const fakeRun=run(process.execPath,[finishRunner,'gate',fake.dir,fake.head],
    {env:laneEnv({GATE_LANE_HELD:`slot:${heldRow.id}`,GATE_LANE_ORIGIN:''})});
  check(jsonOf(fakeRun.stdout).gate_verified===false && /invalid_inheritance/.test(fakeRun.stderr),
    'an unverified marker cannot skip reservation acquisition');
  const copied=finishFixture('copied-inheritance',"printf 'smoke ok (0 skipped)\\n'\n");
  const copiedRun=run(process.execPath,[finishRunner,'gate',copied.dir,copied.head],
    {env:laneEnv({GATE_LANE_HELD:`slot:${heldRow.id}`,GATE_LANE_ORIGIN:JSON.stringify({id:heldRow.id,dir:state,lease:heldRow.lease,holder_pid:heldRow.holder})})});
  check(jsonOf(copiedRun.stdout).gate_verified===false && /invalid_inheritance/.test(copiedRun.stderr),
    'copying a live lease into a sibling does not confer ancestor ownership');
  const inspected=jsonOf(laneSync(['inspect','--json']).stdout);
  check(inspected.read_only===true && inspected.reconciled.length===0 && inspected.held.some(r=>r.id===heldRow.id),
    'inspection observes held work without reconciliation');

  const waiterRun = background(process.execPath,
    [mergeRunner, '--repo', mergeFixtureA.dir, '--base', 'main', mergeFixtureA.tip, '--gate-command', passGate],
    {env: mergeFixtureA.env()});
  live.waiter = waiterRun;
  const waitingRow = await until(async () => {
    const entry = status().queue[0];
    return entry && entry.reason?.includes(`#${heldRow.id}`) ? entry : null;
  }, 'the second consumer to record why it waits');
  check(waitingRow.waits_for === heldRow.id && waitingRow.depth === 1,
    'the waiting record names the slot it waits behind and its depth',
    JSON.stringify({waits_for: waitingRow.waits_for, depth: waitingRow.depth}));
  check(new RegExp(`running #${heldRow.id} \\([^)]*, held \\d+s\\)`).test(waitingRow.reason)
    && /capacity 1 of 1 in use/.test(waitingRow.reason),
  'the reason names the holder and how long it has held the slot', waitingRow.reason);
  check(waiterRun.child.exitCode === null, 'the second consumer is still waiting, not running its gate');

  // The nested gate runs while the holder holds and while the other consumer waits: if it asked for a
  // slot of its own it would wait for the holder, and the holder would wait for it - for two hours.
  const nestedJson = await until(async () => {
    const pending = status();
    if (rowOf(pending, 'finish holder')?.state !== 'running') return null;
    return fs.existsSync(nestedOut) && fs.readFileSync(nestedOut, 'utf8').includes('{')
      ? jsonOf(fs.readFileSync(nestedOut, 'utf8')) : null;
  }, 'the nested gate to finish while its parent still holds the slot');
  check(nestedJson.gate_verified === true && nestedJson.gate_lane.mode === 'inherited'
    && nestedJson.gate_lane.request === heldRow.id && nestedJson.gate_lane.waited_ms === 0,
  'a gate inside a gate inherits the admission and asks for no slot, through the repository gate\'s'
    + ' own environment fence', JSON.stringify(nestedJson.gate_lane));
  check(/inherited slot:\d+/.test(fs.readFileSync(nestedErr, 'utf8')),
    'and it says which slot it inherited', fs.readFileSync(nestedErr, 'utf8').trim().split('\n')[0]);
  // The positive control for the check above: the fence really ran (a WA_ variable that was set is
  // gone, the knob the fence allows through survives) and the marker really survived it. Without
  // this, an inherited nested gate would also read as a pass if the fence were a no-op - and a
  // no-op fence is not what scripts/test.sh is.
  const fenceText = await until(async () => (fs.existsSync(fenceOut) ? fs.readFileSync(fenceOut, 'utf8').trim() : null),
    'the holder\'s gate to report the environment it fenced');
  check(/WA_GATE_LANE_DIR=unset/.test(fenceText) && /WA_GATE_JOBS=2/.test(fenceText),
    'the gate\'s own fence unset a WA_ variable the caller had set, and kept the knob it allows',
    fenceText);
  check(new RegExp(`GATE_LANE_HELD=slot:${heldRow.id}`).test(fenceText),
    'and the admission marker survived it, which is what the nested gate reads', fenceText);
  check(rowOf(status(), 'finish nested') === undefined,
    'no lane request was ever made in the nested tree\'s name');

  // ---- 2. A reached lane that refuses is terminal: the gate does not run, and says which holder ---
  const marker = path.join(root, 'refused-gate-ran');
  const refused = finishFixture('refused', `touch "${sh(marker)}"\nprintf 'smoke ok (0 skipped)\\n'\n`);
  const refusedRun = run(process.execPath, [finishRunner, 'gate', refused.dir, refused.head],
    {env: laneEnv({WA_GATE_LANE_WAIT_SECONDS: '2'})});
  const refusedJson = jsonOf(refusedRun.stdout);
  check(refusedJson.gate_verified === false && refusedJson.gate_lane.mode === 'refused',
    'a refused slot leaves finish.mjs visibly unverified, naming the refusal',
    JSON.stringify({gate_verified: refusedJson.gate_verified, lane: refusedJson.gate_lane}));
  check(new RegExp(`running #${heldRow.id} \\([^)]*, held \\d+s\\)`).test(refusedJson.gate_error || '')
    && /queue depth \d+ \(\d+ ahead\)/.test(refusedJson.gate_error || ''),
  'the refusal names the holder, its elapsed hold and the depth', refusedJson.gate_error);
  check(!fs.existsSync(marker), 'and the gate did not run: a refusal is terminal, not a retry');
  const refusedMerge = merge(mergeFixtureA, ['--base', 'main', mergeFixtureA.tip, '--gate-command', passGate],
    {WA_GATE_LANE_WAIT_SECONDS: '2'});
  const refusedMergeJson = jsonOf(refusedMerge.stdout);
  check(refusedMerge.status === 6 && refusedMergeJson.verdict === 'gate_refused'
    && refusedMergeJson.gate.ran === false && refusedMergeJson.gate.lane.mode === 'refused',
  'the merge lane exits 6 and reports the merged tree as NOT gated, naming the holder',
  JSON.stringify({exit: refusedMerge.status, verdict: refusedMergeJson.verdict, lane: refusedMergeJson.gate.lane}));
  check(new RegExp(`running #${heldRow.id} \\([^)]*, held \\d+s\\)`).test(refusedMergeJson.gate.lane.reason)
    && /queue depth \d+ \(\d+ ahead\)/.test(refusedMergeJson.gate.lane.reason),
  'the merge lane\'s refusal record names the holder, its hold and the depth', refusedMergeJson.gate.lane.reason);

  // ---- 3. Both consumers finish, and what they recorded is what they ran -------------------------
  const holderDone = await holderRun.done;
  const waiterDone = await waiterRun.done;
  const holderJson = jsonOf(holderRun.stdout);
  check(holderDone.status === 0 && holderJson.gate_verified === true && holderJson.skipped === 2,
    'the holder ran its own gate and its own verdict and skip count are what it reports',
    JSON.stringify({exit: holderDone.status, verified: holderJson.gate_verified, skipped: holderJson.skipped}));
  check(holderJson.gate_lane.request === heldRow.id && holderJson.gate_lane.waited_ms < 3000
    && holderJson.gate_ms >= 15000,
  'the holder took the slot at once, and its gate duration is the gate\'s, not the queue\'s',
  JSON.stringify({request: holderJson.gate_lane.request, waited_ms: holderJson.gate_lane.waited_ms,
    gate_ms: holderJson.gate_ms}));
  const receipt = JSON.parse(fs.readFileSync(path.join(holder.dir, '.git', 'wa-finish-gate.json'), 'utf8'));
  check(receipt.passed === true && receipt.gate_lane.request === heldRow.id && receipt.skipped === 2,
    'the gate receipt keeps the lane row that admitted it', JSON.stringify(receipt.gate_lane));
  const waiterJson = jsonOf(waiterRun.stdout);
  check(waiterDone.status === 0 && waiterJson.verdict === 'pass' && waiterJson.gate.ran === true
    && waiterJson.gate.exit === 0 && waiterJson.gate.skipped === 2,
  'the waiter gated the merged tree after the slot freed, with its own verdict untouched',
  JSON.stringify({exit: waiterDone.status, verdict: waiterJson.verdict, gate: waiterJson.gate.exit}));
  check(waiterJson.gate.lane.request !== null && waiterJson.gate.lane.waited_ms >= 5000,
    'and it records that it waited for a named slot',
    JSON.stringify({request: waiterJson.gate.lane.request, waited_ms: waiterJson.gate.lane.waited_ms}));

  // ---- 4. WA_GATE_LANE=off: the gate runs without a slot, and says so ---------------------------
  const override = finishFixture('override', "printf 'smoke ok (0 skipped)\\n'\n");
  const overrideRun = run(process.execPath, [finishRunner, 'gate', override.dir, override.head],
    {env: laneEnv({WA_GATE_LANE: 'off'})});
  const overrideJson = jsonOf(overrideRun.stdout);
  check(overrideJson.gate_verified === true && overrideJson.gate_lane.mode === 'off'
    && overrideJson.gate_lane.request === null,
  'WA_GATE_LANE=off runs the gate with no slot and records exactly that',
  JSON.stringify(overrideJson.gate_lane));
  check(/WA_GATE_LANE=off: the gate runs with no slot, by name/.test(overrideRun.stderr)
    && /WITHOUT a slot|no slot/.test(overrideRun.stderr), 'and it says so on stderr', overrideRun.stderr.trim());
  check(rowOf(status(), 'finish override') === undefined, 'the override takes no record in the lane');
  const overrideMerge = merge(mergeFixtureA, ['--base', 'main', mergeFixtureA.tip, '--gate-command', passGate],
    {WA_GATE_LANE: 'off'});
  check(overrideMerge.status === 0 && jsonOf(overrideMerge.stdout).gate.ran === true
    && jsonOf(overrideMerge.stdout).gate.lane.mode === 'off'
    && jsonOf(overrideMerge.stdout).gate.lane.request === null,
  'the merge lane honours the same override and still gates the merged tree',
  JSON.stringify(jsonOf(overrideMerge.stdout).gate.lane));
  check(/WA_GATE_LANE=off: the gate runs with no slot, by name/.test(overrideMerge.stderr),
    'and says so on stderr', overrideMerge.stderr.trim().split('\n')[0]);

  // ---- 5. A lane that cannot be consulted does not stop the gate ---------------------------------
  fs.writeFileSync(notAStore, 'not a lane directory\n');
  const broken = path.join(root, 'version-skew');
  fs.mkdirSync(path.join(broken, 'scripts'), {recursive: true});
  fs.copyFileSync(mergeRunner, path.join(broken, 'scripts', 'merge-lane.mjs'));
  fs.writeFileSync(path.join(broken, 'scripts', 'gate-lane.mjs'),
    'process.stderr.write("gate lane: unknown option --holder-pid\\n");\nprocess.exit(76);\n');
  const unreadable = finishFixture('unavailable', "printf 'smoke ok (1 skipped)\\n'\n");
  const unreadableRun = run(process.execPath, [finishRunner, 'gate', unreadable.dir, unreadable.head],
    {env: {WA_GATE_LANE_DIR: notAStore}});
  const unreadableJson = jsonOf(unreadableRun.stdout);
  check(unreadableJson.gate_verified === false
    && unreadableJson.gate_lane.mode === 'unavailable',
  'an unreadable reservation store refuses execution without manufacturing gate proof',
  JSON.stringify({verified: unreadableJson.gate_verified, skipped: unreadableJson.skipped,
    lane: unreadableJson.gate_lane}));
  check(/could not be consulted/.test(unreadableRun.stderr) && /did not run/.test(unreadableRun.stderr),
    'and it reports the reservation failure and unexecuted gate', unreadableRun.stderr.trim());
  check(rowOf(status(), 'finish unavailable') === undefined,
    'a lane that could not be consulted took no record, because it was never reached');
  const skewMerge = run(process.execPath, [path.join(broken, 'scripts', 'merge-lane.mjs'),
    '--repo', mergeFixtureA.dir, '--base', 'main', mergeFixtureA.tip, '--gate-command', passGate],
  {env: mergeFixtureA.env()});
  const skewJson = jsonOf(skewMerge.stdout);
  check(skewMerge.status === 0 && skewJson.verdict === 'pass' && skewJson.gate.ran === true
    && skewJson.gate.lane.mode === 'unavailable' && /unknown option --holder-pid/.test(skewJson.gate.lane.reason),
  'a version skew between the lane and its consumer fails open too, and names the skew',
  JSON.stringify({exit: skewMerge.status, verdict: skewJson.verdict, lane: skewJson.gate.lane}));

  // ---- 6. The transitions, from the lane's own history -------------------------------------------
  const holderHistory = historyOf(heldRow.id);
  const waiterHistory = historyOf(waiterJson.gate.lane.request);
  check(holderHistory[0] === 'requested' && holderHistory[1] === 'running'
    && holderHistory[holderHistory.length - 1] === 'done',
  'the holder\'s row moved requested -> running -> done', holderHistory.join(' -> '));
  check(waiterHistory[0] === 'requested' && waiterHistory[1] === 'running'
    && waiterHistory[waiterHistory.length - 1] === 'done',
  'the waiter\'s row moved the same way, in that order', waiterHistory.join(' -> '));
  const after = status();
  check(after.slots_held === 0 && after.waiting === 0, 'the lane is empty again after both settle',
    JSON.stringify({held: after.slots_held, waiting: after.waiting}));
  check(rows(after).filter(entry => entry.label === 'finish nested').length === 0,
    'the whole run left exactly one slot per outer gate and none for the gates inside them');

  console.log(`gate lane wiring ok (${checks} checks, 0 skipped; real consumers, a real queue, a real`);
  console.log('fixture gate as a stand-in for scripts/test.sh, which this file never runs or changes)');
  console.log(`evidence: ${root}`);
  console.log(JSON.stringify({holder: heldRow, waiter: waitingRow, holder_history: holderHistory,
    waiter_history: waiterHistory}, null, 1));
}
main().catch(error => {
  console.error(error.stack);
  console.error(diagnostics());
  process.exitCode = 1;
}).finally(() => {
  for (const child of children) { try { child.kill('SIGKILL'); } catch {} }
  run(process.execPath, [laneCli, 'status'], {}).stdout.split('\n').forEach(line => console.error(line));
  assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
  if (process.exitCode) console.error(`failed fixture retained: ${root}`);
  else fs.rmSync(root, {recursive: true, force: true});
});
