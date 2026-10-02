#!/usr/bin/env node
// Review probe v2: drive the REAL observe -> store -> compose path. The emit command is the real sentinel,
// the store is a real isolated wa_jobs store, and the payload is read back out of it with node:sqlite.
const fs = require('node:fs');
const path = require('node:path');
const {DatabaseSync} = require('node:sqlite');
const {spawn, spawnSync} = require('node:child_process');

const HOOK = process.argv[2];
const SENTINEL = process.argv[3];
const REPO = process.argv[4];
const scratch = process.argv[5];
const probe = path.join(scratch, 'probe');
const runs = path.join(scratch, 'runs2');
fs.rmSync(runs, {recursive: true, force: true});
fs.mkdirSync(runs, {recursive: true});

const git = (...a) => {
  const r = spawnSync('git', a, {encoding: 'utf8', timeout: 60000, windowsHide: true});
  if (r.status !== 0) throw new Error(`git ${a.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function checkout(name, changed, opts = {}) {
  const dir = path.join(scratch, 'co2', name);
  fs.rmSync(dir, {recursive: true, force: true});
  fs.mkdirSync(dir, {recursive: true});
  git('init', '-q', '-b', 'main', dir);
  git('-C', dir, 'config', 'user.email', 'p@e.invalid');
  git('-C', dir, 'config', 'user.name', 'p');
  fs.writeFileSync(path.join(dir, 'README.md'), 'base\n');
  git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', 'base');
  git('-C', dir, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  git('-C', dir, 'checkout', '-qb', `change/${name}`);
  if (changed) {
    const t = path.join(dir, changed);
    fs.mkdirSync(path.dirname(t), {recursive: true});
    fs.writeFileSync(t, `changed by ${name}\n`);
    if (opts.commit !== false) { git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', `work ${name}`); }
  }
  if (opts.dirty) {
    const t = path.join(dir, opts.dirty);
    fs.mkdirSync(path.dirname(t), {recursive: true});
    fs.writeFileSync(t, 'uncommitted\n');
  }
  return {worktree: dir, branch: `change/${name}`, head: git('-C', dir, 'rev-parse', 'HEAD')};
}

const F = {};
F.equals_main = checkout('equals-main', null);
F.equals_main_dirty = {...checkout('equals-main-dirty', null, {dirty: 'ui/app.js'}), dirty: 1};
F.shipped_script = checkout('shipped-script', 'scripts/whatsapp-read.mjs');
F.test_file = checkout('test-file', 'tests/probe.cjs');
F.job_definition = checkout('job-definition', 'jobs/on-subagent-return.json');
F.wave_script = checkout('wave-script', 'scripts/wave-probe.sh');
F.ship_wave = checkout('ship-wave', 'scripts/ship-wave.mjs');
F.lib_module = checkout('lib-module', 'scripts/lib/probe.cjs');
F.lib_nested = checkout('lib-nested', 'scripts/lib/nested/probe.cjs');
F.deploy_sh = checkout('deploy-sh', 'scripts/deploy.sh');
{
  const dir = F.equals_main.worktree;
  git('-C', dir, 'checkout', '-q', '--orphan', 'orphan');
  fs.rmSync(path.join(dir, 'README.md'));
  fs.writeFileSync(path.join(dir, 'unrelated.txt'), 'orphan\n');
  git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', 'orphan root');
  F.orphan = {worktree: dir, branch: 'orphan', head: git('-C', dir, 'rev-parse', 'HEAD')};
  git('-C', dir, 'checkout', '-q', 'change/equals-main');
}
const raw = (o) => ({raw: o});
const CASES = [
  ['c1_no_branch_no_worktree', 'no recorded branch and no worktree', raw({available: true, managed: true, state: 'clean', worktree: '', branch: '', head: ''})],
  ['c2_no_completion_packet', 'completion packet absent', null],
  ['c3_worktree_gone', 'recorded worktree no longer exists', raw({available: true, managed: true, worktree: path.join(scratch, 'gone-repo'), branch: 'change/gone', head: 'a'.repeat(40)})],
  ['c4_tip_equals_main', 'tip equals main (branch at main, no commits)', F.equals_main],
  ['c4b_tip_equals_main_dirty', 'tip equals main, uncommitted ui/** change in the worktree', F.equals_main_dirty],
  ['c5_tip_unreachable_from_main', 'tip not reachable from origin/main (orphan commit)', F.orphan],
  ['c6_only_shipped_script', 'ONLY scripts/whatsapp-read.mjs', F.shipped_script],
  ['c7_only_test_file', 'ONLY tests/probe.cjs', F.test_file],
  ['c8_only_job_definition', 'ONLY jobs/on-subagent-return.json', F.job_definition],
  ['c9_only_wave_script', 'ONLY scripts/wave-probe.sh', F.wave_script],
  ['c10_ship_wave_mjs', 'ONLY scripts/ship-wave.mjs', F.ship_wave],
  ['c11_lib_module', 'ONLY scripts/lib/probe.cjs', F.lib_module],
  ['c12_lib_nested', 'ONLY scripts/lib/nested/probe.cjs', F.lib_nested],
  ['c13_deploy_sh', 'ONLY scripts/deploy.sh', F.deploy_sh],
];
const artifactsOf = (f) => f === null ? {available: false, reason: 'artifact_facts_failed: no session record'}
  : f.raw ? f.raw
  : {available: true, managed: true, state: 'clean', worktree: f.worktree, recorded_branch: f.branch,
     branch: f.branch, head: f.head, ahead: 1, behind: 0, pushed: false, dirty: f.dirty || 0, untracked: 0};

function cli(env, ...args) {
  const r = spawnSync(SENTINEL, ['job', ...args], {env, encoding: 'utf8', timeout: 30000, windowsHide: true});
  if (r.status !== 0) throw new Error(`job ${args.join(' ')}: ${r.stderr || r.stdout}`);
  return JSON.parse(r.stdout);
}
function envFor(run, extra = {}) {
  const env = {...process.env, WASM_AGENT_HOME: path.join(run, 'home'), WASM_AGENT_PORT: '1',
    WA_SENTINEL_BIN: SENTINEL, WA_SENTINEL_AUTH_SESSION: 'probe-auth',
    WA_SENTINEL_SCRIPTS: `${path.join(REPO, 'scripts')};${scratch}`,
    WA_SENTINEL_RETURN_STATE: path.join(run, 'cursor.json'), ...extra};
  delete env.WA_SENTINEL_JOB_WAKE_BUDGET; delete env.WA_SENTINEL_WAKE_BUDGET;
  return env;
}
function putJob(run, mutate = () => {}) {
  const def = JSON.parse(fs.readFileSync(path.join(REPO, 'jobs', 'on-subagent-return.json'), 'utf8'));
  def.action.session = 'probe-coordinator';
  def.action.prepare.script = path.join(REPO, 'scripts', 'subagent-return-prepare.sh');
  mutate(def);
  const file = path.join(run, `job-${Date.now()}.json`);
  fs.writeFileSync(file, JSON.stringify(def));
  return file;
}
function deliveries(run) {
  const file = path.join(run, 'home', '.wasm-agent', 'sentinel', 'jobs.db');
  if (!fs.existsSync(file)) return [];
  const db = new DatabaseSync(file, {readOnly: true});
  const rows = db.prepare('SELECT id,revision,event_id,state,payload FROM deliveries ORDER BY id').all();
  db.close();
  return rows;
}
async function observeOnce(run, artifacts, id) {
  const task = {subagent_id: id, state: 'completed', settled: true, session_id: `session-${id}`,
    profile: 'task-worker', parent_session_id: 'session-orchestrator', execution_node: 'local'};
  const spec = [{task, completion: artifacts === null ? undefined : {child_id: id, state: 'completed', detail: '{}',
    packet: JSON.stringify({child: {id, state: 'completed'}, session: {id: `session-${id}`, parent: 'session-orchestrator'},
      artifacts})}}];
  const specFile = path.join(run, `spec-${id}.json`);
  const portFile = path.join(run, `port-${id}`);
  fs.rmSync(portFile, {force: true});
  fs.writeFileSync(specFile, JSON.stringify(spec));
  const node = spawn(process.execPath, [path.join(probe, 'fake-node.cjs'), specFile, portFile],
    {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  let port = '';
  for (let i = 0; i < 100 && !port; i += 1) { await sleep(50); if (fs.existsSync(portFile)) port = fs.readFileSync(portFile, 'utf8').trim(); }
  const r = spawnSync(process.execPath, [HOOK, '--observe', '--node', `http://127.0.0.1:${port}`,
    '--state', path.join(run, 'cursor.json'), '--emit-command', SENTINEL],
    {env: envFor(run), encoding: 'utf8', timeout: 60000, windowsHide: true});
  node.kill();
  if (r.status !== 0) throw new Error(`observe ${id}: ${r.stderr || r.stdout}`);
  return JSON.parse(r.stdout);
}

function observeAt(run, port) {
  const r = spawnSync(process.execPath, [HOOK, '--observe', '--node', `http://127.0.0.1:${port}`,
    '--state', path.join(run, 'cursor.json'), '--emit-command', SENTINEL],
    {env: envFor(run), encoding: 'utf8', timeout: 60000, windowsHide: true});
  if (r.status !== 0) throw new Error(`observe: ${r.stderr || r.stdout}`);
  return JSON.parse(r.stdout);
}
function composePayload(payload) {
  const file = path.join(runs, `payload-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(file, JSON.stringify(payload));
  const r = spawnSync(process.execPath, [HOOK, '--compose', '--event', file], {encoding: 'utf8', windowsHide: true});
  fs.rmSync(file, {force: true});
  if (r.status !== 0) throw new Error(`compose: ${r.stderr}`);
  return JSON.parse(r.stdout);
}
async function main() {
  for (const [id, description, fixture] of CASES) {
    const run = path.join(runs, id);
    fs.mkdirSync(run, {recursive: true});
    const env = envFor(run);
    cli(env, 'put', putJob(run));
    cli(env, 'enable', 'onSubagentReturn');
    const report = await observeOnce(run, artifactsOf(fixture), id);
    const rows = deliveries(run);
    const row = rows.find((r) => r.event_id === id);
    console.log(`### ${id} - ${description}`);
    console.log(`pass: observed=${report.observed} settled=${report.settled} emitted=${report.emitted} duplicates=${report.duplicates} unreadable=[${report.unreadable}] errors=[${report.errors}]`);
    console.log(`store: deliveries=${rows.length} event_id=${row ? row.event_id : '(none)'} state=${row ? row.state : '-'}`);
    if (row) {
      const p = JSON.parse(row.payload);
      console.log(`payload: changed_paths=${p.changed_paths ? JSON.stringify(p.changed_paths) : 'ABSENT'} changed_paths_error=${p.changed_paths_error || '-'}`);
      console.log(`payload: source=${p.changed_paths_source || '-'}`);
      const composed = composePayload(p);
      const block = composed.instruction.split('\n').filter((l) => l.startsWith('DEPLOY VERDICT') || l.startsWith('artifacts:') || l.startsWith('changed paths'));
      console.log(`composed verdict: ${composed.verdict}${composed.reason ? ' (' + composed.reason + ')' : ''}`);
      for (const line of block) console.log(`  | ${line}`);
    }
    console.log('');
  }
}

const wakes = (file) => !fs.existsSync(file) ? [] : fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
async function waitFor(f, ms = 40000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (f()) return true; await sleep(200); }
  return false;
}
async function dedupeScenario() {
  const run = path.join(runs, 'dedupe');
  fs.mkdirSync(run, {recursive: true});
  const wakeFile = path.join(run, 'wakes.jsonl');
  const specFile = path.join(run, 'spec.json');
  const portFile = path.join(run, 'port');
  const id = 'child-dedupe';
  const midId = 'child-midrun';
  const taskFor = (cid) => ({subagent_id: cid, state: 'completed', settled: true, session_id: `session-${cid}`,
    profile: 'task-worker', parent_session_id: 'session-orchestrator', execution_node: 'local'});
  const task = taskFor(id);
  const packetFor = (cid) => ({child: {id: cid, state: 'completed'}, session: {id: `session-${cid}`, parent: 'session-orchestrator'},
    artifacts: artifactsOf(F.shipped_script)});
  const writeSpec = (tasks) => fs.writeFileSync(specFile, JSON.stringify(tasks.map((t) => ({task: t,
    completion: {child_id: t.subagent_id, state: t.state, detail: '{}', packet: JSON.stringify(packetFor(t.subagent_id))}}))));
  writeSpec([task]);
  const node = spawn(process.execPath, [path.join(probe, 'fake-node2.cjs'), specFile, portFile, wakeFile],
    {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  let port = '';
  for (let i = 0; i < 100 && !port; i += 1) { await sleep(50); if (fs.existsSync(portFile)) port = fs.readFileSync(portFile, 'utf8').trim(); }
  const env = envFor(run, {WASM_AGENT_PORT: port, WASM_AGENT_RELAY: '', WASM_AGENT_RENDEZVOUS: '',
    WASM_AGENT_MANAGED: '0', WA_SENTINEL_WAKE_BUDGET: '24', WA_SENTINEL_JOB_WAKE_BUDGET: '24',
    WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: '1'});
  delete env.WA_SCRIPT; delete env.WASM_AGENT_LUA_ROOT;
  cli(env, 'put', putJob(run));
  cli(env, 'enable', 'onSubagentReturn');
  const watcher = spawn(SENTINEL, ['watch'], {env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  console.log('### d0_one_wake_per_settle');
  const first = await observeOnce(run, artifactsOf(F.shipped_script), id);
  await waitFor(() => wakes(wakeFile).length >= 1);
  console.log(`pass1: emitted=${first.emitted} duplicates=${first.duplicates} deliveries=${deliveries(run).length} wakes=${wakes(wakeFile).length}`);
  fs.rmSync(path.join(run, 'cursor.json'), {force: true});
  const second = await observeOnce(run, artifactsOf(F.shipped_script), id);
  await sleep(2500);
  console.log(`pass2 after the cursor file is deleted: emitted=${second.emitted} duplicates=${second.duplicates} deliveries=${deliveries(run).length} wakes=${wakes(wakeFile).length}`);
  fs.rmSync(path.join(run, 'cursor.json'), {force: true});
  const changed = cli(env, 'put', putJob(run, (d) => { d.name = 'onSubagentReturn (re-put, revision 2)'; }));
  cli(env, 'enable', 'onSubagentReturn');
  const third = await observeOnce(run, artifactsOf(F.shipped_script), id);
  await waitFor(() => wakes(wakeFile).length >= 2);
  const rows = deliveries(run);
  console.log(`after a re-put (revision ${changed.revision}) and a lost cursor: emitted=${third.emitted} duplicates=${third.duplicates}`);
  console.log(`store rows for ${id}: ${rows.map((r) => `rev${r.revision}#${r.id}:${r.state}`).join(' ')}`);
  console.log(`wakes for one settle: ${wakes(wakeFile).length}`);
  for (const w of wakes(wakeFile)) {
    console.log(`  wake -> ${w.thread}: ${w.text.split('\n').find((l) => l.startsWith('DEPLOY VERDICT'))}`);
  }
  console.log('### d1_settles_while_the_pass_is_mid_run');
  const before = wakes(wakeFile).length;
  writeSpec([{...taskFor(midId), state: 'running', settled: false}]);
  const mid1 = observeAt(run, port);
  writeSpec([task, taskFor(midId)]);   // it settled between the two passes
  const mid2 = observeAt(run, port);
  await waitFor(() => wakes(wakeFile).length > before);
  console.log(`pass A while it was still running: observed=${mid1.observed} settled=${mid1.settled} emitted=${mid1.emitted}`);
  console.log(`pass B after it settled: observed=${mid2.observed} settled=${mid2.settled} emitted=${mid2.emitted} wakes=${wakes(wakeFile).length - before}`);
  const mid3 = observeAt(run, port);   // and the same pass again: the cursor must hold
  console.log(`pass C (same children again): emitted=${mid3.emitted} duplicates=${mid3.duplicates} wakes=${wakes(wakeFile).length - before}`);
  console.log('### d2_settles_and_leaves_the_record_before_a_pass');
  const goneId = 'child-gone';
  writeSpec([task, {...taskFor(goneId), state: 'running', settled: false}]);
  const g1 = observeAt(run, port);
  writeSpec([task]);   // it settled and the node's record no longer lists it
  const g2 = observeAt(run, port);
  await sleep(1500);
  console.log(`pass A while ${goneId} was running: settled=${g1.settled} emitted=${g1.emitted}`);
  console.log(`pass B after it settled and left the record: observed=${g2.observed} settled=${g2.settled} emitted=${g2.emitted}`);
  console.log(`wakes for ${goneId}: ${wakes(wakeFile).length - before - 1} -> a settle that leaves the record before a pass is never reported`);
  watcher.kill(); node.kill();
}
main().then(() => dedupeScenario()).then(() => { process.exitCode = 0; })
  .catch((error) => { console.error(error.stack); process.exitCode = 1; });
