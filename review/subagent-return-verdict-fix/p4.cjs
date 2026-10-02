#!/usr/bin/env node
// Re-verification probe for change/subagent-return-verdict-fix: the real hook, a real store, a fake node.
const fs = require('node:fs');
const path = require('node:path');
const {DatabaseSync} = require('node:sqlite');
const {spawn, spawnSync} = require('node:child_process');
const HOOK = process.argv[2], SENTINEL = process.argv[3], REPO = process.argv[4], scratch = process.argv[5];
const runs = path.join(scratch, 'runs'); fs.rmSync(runs, {recursive: true, force: true}); fs.mkdirSync(runs, {recursive: true});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const git = (...a) => { const r = spawnSync('git', a, {encoding: 'utf8', timeout: 60000, windowsHide: true});
  if (r.status !== 0) throw new Error(`git ${a.join(' ')}: ${r.stderr}`); return r.stdout.trim(); };
function cli(env, ...args) {
  const r = spawnSync(SENTINEL, ['job', ...args], {env, encoding: 'utf8', timeout: 30000, windowsHide: true});
  return {status: r.status, out: r.stdout || '', err: (r.stderr || '') + (r.stdout || '')};
}
function envFor(run, extra = {}) {
  const env = {...process.env, WASM_AGENT_HOME: path.join(run, 'home'), WASM_AGENT_PORT: '1',
    WA_SENTINEL_BIN: SENTINEL, WA_SENTINEL_AUTH_SESSION: 'probe-auth',
    WA_SENTINEL_SCRIPTS: `${path.join(REPO, 'scripts')};${scratch}`,
    WA_SENTINEL_RETURN_STATE: path.join(run, 'cursor.json'), ...extra};
  delete env.WA_SENTINEL_JOB_WAKE_BUDGET; delete env.WA_SENTINEL_WAKE_BUDGET; return env;
}
function putJob(run, mutate = () => {}) {
  const def = JSON.parse(fs.readFileSync(path.join(REPO, 'jobs', 'on-subagent-return.json'), 'utf8'));
  def.action.session = 'probe-coordinator';
  def.action.prepare.script = path.join(REPO, 'scripts', 'subagent-return-prepare.sh');
  mutate(def);
  const file = path.join(run, `job-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(file, JSON.stringify(def)); return file;
}
function deliveries(run) {
  const file = path.join(run, 'home', '.wasm-agent', 'sentinel', 'jobs.db');
  if (!fs.existsSync(file)) return [];
  const db = new DatabaseSync(file, {readOnly: true});
  const rows = db.prepare('SELECT id,revision,event_id,state,detail,payload FROM deliveries ORDER BY id').all();
  db.close(); return rows;
}
const posix = (q) => '/' + q[0].toLowerCase() + q.slice(2).replaceAll(String.fromCharCode(92), '/');
function checkout(name, changed, opts = {}) {
  const dir = path.join(scratch, 'co', name); fs.rmSync(dir, {recursive: true, force: true}); fs.mkdirSync(dir, {recursive: true});
  git('init', '-q', '-b', 'main', dir); git('-C', dir, 'config', 'user.email', 'p@e.invalid'); git('-C', dir, 'config', 'user.name', 'p');
  fs.writeFileSync(path.join(dir, 'README.md'), 'base\n');
  git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', 'base');
  git('-C', dir, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  git('-C', dir, 'checkout', '-qb', `change/${name}`);
  if (changed) { const t = path.join(dir, changed); fs.mkdirSync(path.dirname(t), {recursive: true});
    fs.writeFileSync(t, `changed by ${name}\n`); if (opts.commit !== false) { git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', `work ${name}`); } }
  if (opts.dirty) { const t = path.join(dir, opts.dirty); fs.mkdirSync(path.dirname(t), {recursive: true}); fs.writeFileSync(t, 'uncommitted\n'); }
  return {worktree: dir, branch: `change/${name}`, head: git('-C', dir, 'rev-parse', 'HEAD')};
}

function specFor(id, artifacts, state = 'completed') {
  const task = {subagent_id: id, state, settled: state !== 'running', session_id: `session-${id}`,
    profile: 'task-worker', parent_session_id: 'session-orchestrator', execution_node: 'local'};
  const completion = {child_id: id, state, detail: '{}', packet: JSON.stringify({
    child: {id, state, profile: 'task-worker'}, session: {id: `session-${id}`, parent: 'session-orchestrator'},
    artifacts})};
  return [{task, completion}];
}
async function withNode(run, spec, fn) {
  const specFile = path.join(run, `spec-${Math.random().toString(36).slice(2)}.json`);
  const portFile = `${specFile}.port`; const wakeFile = path.join(run, 'wakes.jsonl');
  fs.writeFileSync(specFile, JSON.stringify(spec));
  const node = spawn(process.execPath, [path.join(scratch, 'probe', 'fake-node.cjs'), specFile, portFile, wakeFile],
    {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  let port = ''; for (let i = 0; i < 100 && !port; i += 1) { await sleep(50); if (fs.existsSync(portFile)) port = fs.readFileSync(portFile, 'utf8').trim(); }
  try { return await fn(port, wakeFile, specFile); } finally { node.kill(); }
}
function observe(run, port) {
  const r = spawnSync(process.execPath, [HOOK, '--observe', '--node', `http://127.0.0.1:${port}`,
    '--state', path.join(run, 'cursor.json'), '--emit-command', SENTINEL],
    {env: envFor(run), encoding: 'utf8', timeout: 60000, windowsHide: true});
  if (r.status !== 0) throw new Error(`observe: ${r.stderr || r.stdout}`);
  return JSON.parse(r.stdout);
}
function compose(payload, manifest) {
  const file = path.join(runs, `p-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(file, JSON.stringify(payload));
  const args = [HOOK, '--compose', '--event', file];
  if (manifest) args.push('--manifest', manifest);
  const r = spawnSync(process.execPath, args, {encoding: 'utf8', windowsHide: true});
  fs.rmSync(file, {force: true});
  if (r.status !== 0) throw new Error(`compose: ${r.stderr}`);
  return JSON.parse(r.stdout);
}
const wakesOf = (f) => !fs.existsSync(f) ? [] : fs.readFileSync(f, 'utf8').split('\n').filter(Boolean);
async function waitFor(f, ms = 40000) { const end = Date.now() + ms;
  while (Date.now() < end) { if (f()) return true; await sleep(200); } return false; }

const F = {};
F.equals_main = checkout('equals-main', null);
F.equals_main_dirty = checkout('equals-main-dirty', null, {dirty: 'ui/app.js'});
F.clean_but_recorded_dirty = checkout('clean-but-dirty-recorded', null);
F.shipped_script = checkout('shipped-script', 'scripts/whatsapp-read.mjs');
{
  const dir = F.equals_main.worktree;
  git('-C', dir, 'checkout', '-q', '--orphan', 'orphan'); fs.rmSync(path.join(dir, 'README.md'));
  fs.writeFileSync(path.join(dir, 'unrelated.txt'), 'orphan\n');
  git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', 'orphan root');
  F.orphan = {worktree: dir, branch: 'orphan', head: git('-C', dir, 'rev-parse', 'HEAD')};
  git('-C', dir, 'checkout', '-q', 'change/equals-main');
}
const art = (f, extra = {}) => ({available: true, managed: true, state: 'clean', worktree: f.worktree,
  recorded_branch: f.branch, branch: f.branch, head: f.head, ahead: 1, behind: 0, pushed: false, dirty: 0, untracked: 0, ...extra});
async function caseVerdict(id, description, artifacts, fixture) {
  const run = path.join(runs, id); fs.mkdirSync(run, {recursive: true});
  const env = envFor(run); cli(env, 'put', putJob(run)); cli(env, 'enable', 'onSubagentReturn');
  return withNode(run, specFor(id, artifacts), async (port) => {
    const report = observe(run, port);
    const rows = deliveries(run); const row = rows.find((r) => r.event_id === id);
    const payload = row ? JSON.parse(row.payload) : null;
    const composed = payload ? compose(payload) : null;
    console.log(`### ${id} - ${description}`);
    console.log(`pass: observed=${report.observed} settled=${report.settled} emitted=${report.emitted} errors=[${report.errors}]`);
    if (payload) {
      console.log(`payload: changed_paths=${payload.changed_paths ? JSON.stringify(payload.changed_paths) : 'ABSENT'} uncommitted=${JSON.stringify(payload.uncommitted_paths || null)} error=${payload.changed_paths_error || '-'} head_moved=${payload.head_moved ? 'yes' : 'no'}`);
      console.log(`VERDICT: ${composed.verdict}${composed.reason ? ' (' + composed.reason + ')' : ''}`);
    } else console.log('VERDICT: (no delivery)');
    console.log('');
  });
}
async function partA() {
  await caseVerdict('a1_orphan', 'tip with no merge base against origin/main', art(F.orphan));
  await caseVerdict('a2_tip_equals_main_uncommitted_ui', 'tip equals main, uncommitted ui/** change', art(F.equals_main_dirty));
  await caseVerdict('a3_dirty_recorded_but_clean', 'the record says dirty=1, the checkout is clean', art(F.clean_but_recorded_dirty, {dirty: 1}));
  await caseVerdict('a4_shipped_script', 'ONLY scripts/whatsapp-read.mjs (control)', art(F.shipped_script));
  console.log('### a5_pure_predicate - my old counterexamples');
  const v = (paths) => JSON.parse(spawnSync(process.execPath, [HOOK, '--verdict', ...paths.flatMap((p) => ['--path', p])],
    {encoding: 'utf8', windowsHide: true}).stdout);
  for (const p of ['jobs/on-subagent-return.json', 'jobs/subagent-return-observe.json', 'jobs/whatsapp-copilot.json', 'scripts/upgrade.sh']) {
    console.log(`  ${p} -> ${v([p]).verdict}`);
  }
  console.log(`  docs/JOBS.md -> ${v(['docs/JOBS.md']).verdict}   tests/x.cjs -> ${v(['tests/x.cjs']).verdict}`);
  console.log('### a6_unreadable_manifest');
  const payload = {schema: 1, child_id: 'x', state: 'completed', settled: true, session: 's', parent_session: 'p',
    artifacts: art(F.shipped_script), changed_paths: ['ui/app.js']};
  const broken = compose(payload, path.join(scratch, 'no-such-manifest.json'));
  console.log(`  manifest missing -> ${broken.verdict} (${broken.reason})`);
  const malformed = path.join(scratch, 'malformed.json'); fs.writeFileSync(malformed, '{"schema":1}');
  const bad = compose(payload, malformed);
  console.log(`  manifest malformed -> ${bad.verdict} (${bad.reason})`);
}

function partB() {
  const run = path.join(runs, 'b_put'); fs.mkdirSync(run, {recursive: true});
  const env = envFor(run);
  const good = path.join(REPO, 'scripts', 'subagent-return-prepare.sh');
  const write = (name, def) => { const f = path.join(run, `${name}.json`); fs.writeFileSync(f, JSON.stringify(def)); return f; };
  const put = (name, def) => { const r = cli(env, 'put', write(name, def)); return `${r.status === 0 ? 'accepted' : 'REFUSED'}: ${r.err.trim().split('\n').pop().slice(0, 90)}`; };
  console.log('### b1_prepare_and_dedupe_key_placement_at_job_put');
  console.log(`  wake + prepare                        -> ${put('w1', {id: 'w1', name: 'w1', trigger: {kind: 'event', topic: 't1'}, action: {kind: 'wake', session: 's', prompt: 'p', prepare: {script: good, timeout_seconds: 20}}})}`);
  console.log(`  run + prepare                         -> ${put('r1', {id: 'r1', name: 'r1', trigger: {kind: 'event', topic: 't2'}, action: {kind: 'run', script: good, timeout_seconds: 20, prepare: {script: good}}})}`);
  console.log(`  run + dedupe_key                      -> ${put('r2', {id: 'r2', name: 'r2', trigger: {kind: 'event', topic: 't3'}, action: {kind: 'run', script: good, timeout_seconds: 20, dedupe_key: 'child_id'}})}`);
  console.log(`  pipeline run step + prepare           -> ${put('p1', {id: 'p1', name: 'p1', trigger: {kind: 'event', topic: 't4'}, action: {kind: 'pipeline', steps: [{kind: 'run', script: good, timeout_seconds: 20, prepare: {script: good}}]}})}`);
  console.log(`  pipeline foreach inner + prepare      -> ${put('p2', {id: 'p2', name: 'p2', trigger: {kind: 'event', topic: 't5'}, action: {kind: 'pipeline', steps: [{kind: 'run', script: good, returns: 'events'}, {kind: 'foreach', from: 'events', key: 'id', max: 1, step: {kind: 'subagent', profile: 'task-worker', prompt: 'x', prepare: {script: good}}}]}})}`);
  console.log(`  pipeline step + dedupe_key            -> ${put('p3', {id: 'p3', name: 'p3', trigger: {kind: 'event', topic: 't6'}, action: {kind: 'pipeline', steps: [{kind: 'run', script: good, timeout_seconds: 20, dedupe_key: 'child_id'}]}})}`);
  console.log(`  wake + bad dedupe_key name            -> ${put('w2', {id: 'w2', name: 'w2', trigger: {kind: 'event', topic: 't7'}, action: {kind: 'wake', session: 's', prompt: 'p', dedupe_key: 'child id!'}})}`);
  console.log('### b2_the_two_shipped_definitions_install_disabled');
  for (const name of ['on-subagent-return', 'subagent-return-observe']) {
    const def = fs.readFileSync(path.join(REPO, 'jobs', `${name}.json`), 'utf8')
      .replaceAll('PREPARED_BY_INSTALL', REPO.replaceAll(String.fromCharCode(92), '/')).replaceAll('COORDINATOR_SESSION_ID', 'probe-coordinator');
    const file = path.join(run, `${name}.json`); fs.writeFileSync(file, def);
    const r = cli(env, 'put', file);
    const listed = JSON.parse(cli(env, 'list').out).find((j) => j.id === (name === 'on-subagent-return' ? 'onSubagentReturn' : 'subagent-return-observe'));
    console.log(`  ${name}: put status=${r.status} enabled=${listed && listed.enabled} revision=${listed && listed.revision} supersedes=${listed && listed.supersedes} dedupe_key=${listed && listed.action && listed.action.dedupe_key}`);
  }
}

function ledgerPath(run) { return path.join(run, 'home', '.wasm-agent', 'sentinel', 'wake-dedupe-onSubagentReturn.json'); }
async function partC() {
  const run = path.join(runs, 'c_dedupe'); fs.mkdirSync(run, {recursive: true});
  const id = 'child-dedupe'; const wakeFile = path.join(run, 'wakes.jsonl');
  const specFile = path.join(run, 'spec.json'); const portFile = path.join(run, 'spec.port');
  fs.writeFileSync(specFile, JSON.stringify(specFor(id, art(F.shipped_script))));
  const node = spawn(process.execPath, [path.join(scratch, 'probe', 'fake-node.cjs'), specFile, portFile, wakeFile],
    {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  let port = ''; for (let i = 0; i < 100 && !port; i += 1) { await sleep(50); if (fs.existsSync(portFile)) port = fs.readFileSync(portFile, 'utf8').trim(); }
  const env = envFor(run, {WASM_AGENT_PORT: port, WASM_AGENT_RELAY: '', WASM_AGENT_RENDEZVOUS: '',
    WASM_AGENT_MANAGED: '0', WA_SENTINEL_WAKE_BUDGET: '24', WA_SENTINEL_JOB_WAKE_BUDGET: '24', WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: '1'});
  delete env.WA_SCRIPT; delete env.WASM_AGENT_LUA_ROOT;
  cli(env, 'put', putJob(run)); cli(env, 'enable', 'onSubagentReturn');
  const watcher = spawn(SENTINEL, ['watch'], {env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  console.log('### c1_one_wake_per_settle_then_a_re_put_plus_a_lost_cursor');
  const first = observe(run, port);
  await waitFor(() => wakesOf(wakeFile).length >= 1);
  const rev1 = JSON.parse(cli(env, 'list').out).find((j) => j.id === 'onSubagentReturn').revision;
  console.log(`  pass1: emitted=${first.emitted} duplicates=${first.duplicates} deliveries=${deliveries(run).length} wakes=${wakesOf(wakeFile).length} revision=${rev1}`);
  console.log(`  ledger: ${fs.existsSync(ledgerPath(run)) ? fs.readFileSync(ledgerPath(run), 'utf8').replace(/\s+/g, ' ') : '(absent)'}`);
  const storedPayload = JSON.parse(deliveries(run)[0].payload);
  fs.rmSync(path.join(run, 'cursor.json'), {force: true});
  const rep = cli(env, 'put', putJob(run, (d) => { d.name = 'onSubagentReturn (re-put)'; }));
  cli(env, 'enable', 'onSubagentReturn');
  const second = observe(run, port);
  await waitFor(() => deliveries(run).length >= 2); await sleep(2500);
  const rows = deliveries(run);
  console.log(`  re-put revision=${JSON.parse(cli(env, 'list').out).find((j) => j.id === 'onSubagentReturn').revision} pass2: emitted=${second.emitted} duplicates=${second.duplicates}`);
  console.log(`  deliveries: ${rows.map((r) => `rev${r.revision}#${r.id}:${r.state}:${String(r.detail).slice(0, 60)}`).join(' | ')}`);
  console.log(`  wakes for one settle: ${wakesOf(wakeFile).length}`);
  console.log('### c2_kill_mid_emit_convergence (pending intent, same payload)');
  const revision = JSON.parse(cli(env, 'list').out).find((j) => j.id === 'onSubagentReturn').revision;
  fs.writeFileSync(path.join(run, 'cursor.json'), JSON.stringify({schema: 1, reported: {},
    pending: {[id]: {event_id: id, at: new Date().toISOString(), revision, payload: storedPayload}}}));
  const c2a = observe(run, port); const c2b = observe(run, port);
  console.log(`  pass A: emitted=${c2a.emitted} reconciled=${c2a.reconciled} duplicates=${c2a.duplicates} errors=[${c2a.errors}]`);
  console.log(`  pass B: emitted=${c2b.emitted} reconciled=${c2b.reconciled} duplicates=${c2b.duplicates} errors=[${c2b.errors}]`);
  const stateAfter = JSON.parse(fs.readFileSync(path.join(run, 'cursor.json'), 'utf8'));
  console.log(`  cursor: reported=[${Object.keys(stateAfter.reported)}] pending=[${Object.keys(stateAfter.pending)}]`);
  console.log('### c3_the_same_intent_when_the_child_measurably_changed (payload no longer matches)');
  fs.mkdirSync(path.join(F.shipped_script.worktree, 'ui'), {recursive: true});
  fs.writeFileSync(path.join(F.shipped_script.worktree, 'ui', 'later.js'), 'changed after the emit\n');
  fs.writeFileSync(path.join(run, 'cursor.json'), JSON.stringify({schema: 1, reported: {},
    pending: {[id]: {event_id: id, at: new Date().toISOString(), revision, payload: storedPayload}}}));
  const c3a = observe(run, port); const c3b = observe(run, port);
  console.log(`  pass A: emitted=${c3a.emitted} reconciled=${c3a.reconciled} duplicates=${c3a.duplicates} errors=[${c3a.errors}]`);
  console.log(`  pass B: emitted=${c3b.emitted} reconciled=${c3b.reconciled} duplicates=${c3b.duplicates} errors=[${c3b.errors}]`);
  const after3 = JSON.parse(fs.readFileSync(path.join(run, 'cursor.json'), 'utf8'));
  console.log(`  cursor: reported=[${Object.keys(after3.reported)}] pending=[${Object.keys(after3.pending)}]  wakes=${wakesOf(wakeFile).length}`);
  watcher.kill(); node.kill();
}
async function partD() {
  const run = path.join(runs, 'd_marker'); fs.mkdirSync(run, {recursive: true});
  const env = envFor(run);
  const marker = path.join(run, 'home', '.wasm-agent', 'sentinel', 'completion-wake-superseded');
  cli(env, 'put', putJob(run));
  cli(env, 'enable', 'onSubagentReturn');
  console.log('### d1_the_supersede_marker_from_the_stores_own_enabled_state');
  console.log(`  right after enable, before any tick: marker exists=${fs.existsSync(marker)}`);
  const watcher = spawn(SENTINEL, ['watch'], {env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  await waitFor(() => fs.existsSync(marker), 20000);
  console.log(`  after a watcher tick: ${fs.existsSync(marker) ? fs.readFileSync(marker, 'utf8').replace(/\s+/g, ' ') : '(still absent)'}`);
  cli(env, 'disable', 'onSubagentReturn');
  await waitFor(() => !fs.existsSync(marker), 20000);
  console.log(`  after disable: marker exists=${fs.existsSync(marker)}`);
  watcher.kill();
}

const MODE = process.argv[6] || 'all';
(async () => {
  if (MODE === 'all' || MODE === 'A') await partA();
  if (MODE === 'all' || MODE === 'B') partB();
  if (MODE === 'all' || MODE === 'C') await partC();
  if (MODE === 'all' || MODE === 'D') await partD();
  process.exit(0);
})().catch((error) => { console.error(error.stack); process.exit(1); });
