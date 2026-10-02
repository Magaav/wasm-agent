#!/usr/bin/env node
// Review probe 3: the `prepare` boundary, driven through the real sentinel job machinery (isolated home).
const fs = require('node:fs');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');
const HOOK = process.argv[2];
const SENTINEL = process.argv[3];
const REPO = process.argv[4];
const scratch = process.argv[5];
const runs = path.join(scratch, 'runs3');
fs.rmSync(runs, {recursive: true, force: true});
fs.mkdirSync(path.join(scratch, 'allow'), {recursive: true});
fs.mkdirSync(path.join(scratch, 'outside'), {recursive: true});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const posix = (q) => '/' + q[0].toLowerCase() + q.slice(2).replaceAll(String.fromCharCode(92), '/');
const MARKER = path.join(scratch, 'INJECTED');
const MARKER2 = path.join(scratch, 'RAN_AS_FILE');
fs.rmSync(MARKER, {force: true}); fs.rmSync(MARKER2, {force: true});

function cli(env, ...args) {
  const r = spawnSync(SENTINEL, ['job', ...args], {env, encoding: 'utf8', timeout: 30000, windowsHide: true});
  return {status: r.status, out: r.stdout || '', err: (r.stderr || '') + (r.stdout || '')};
}
function envFor(run, port) {
  const env = {...process.env, WASM_AGENT_HOME: path.join(run, 'home'), WASM_AGENT_PORT: String(port),
    WA_SENTINEL_BIN: SENTINEL, WA_SENTINEL_AUTH_SESSION: 'probe-auth',
    WA_SENTINEL_SCRIPTS: `${path.join(REPO, 'scripts')};${path.join(scratch, 'allow')}`,
    WA_SENTINEL_RETURN_STATE: path.join(run, 'cursor.json'), WASM_AGENT_RELAY: '', WASM_AGENT_RENDEZVOUS: '',
    WASM_AGENT_MANAGED: '0', WA_SENTINEL_WAKE_BUDGET: '24', WA_SENTINEL_JOB_WAKE_BUDGET: '24',
    WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: '1'};
  delete env.WA_SCRIPT; delete env.WASM_AGENT_LUA_ROOT; delete env.WASM_AGENT_LUA_ROOT;
  return env;
}
async function startNode(run) {
  const wakeFile = path.join(run, 'wakes.jsonl');
  const specFile = path.join(run, 'spec.json');
  const portFile = path.join(run, 'port');
  fs.writeFileSync(specFile, '[]');
  const handle = spawn(process.execPath, [path.join(scratch, 'probe', 'fake-node2.cjs'), specFile, portFile, wakeFile],
    {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  let port = '';
  for (let i = 0; i < 100 && !port; i += 1) { await sleep(50); if (fs.existsSync(portFile)) port = fs.readFileSync(portFile, 'utf8').trim(); }
  return {handle, port, wakeFile};
}
const wakesOf = (f) => !fs.existsSync(f) ? [] : fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).length;
async function deliver(id, job, payload = {text: 'data'}) {
  const run = path.join(runs, id);
  fs.mkdirSync(run, {recursive: true});
  const node = await startNode(run);
  const env = envFor(run, node.port);
  const jobFile = path.join(run, 'job.json');
  fs.writeFileSync(jobFile, JSON.stringify(job));
  const put = cli(env, 'put', jobFile);
  const enable = cli(env, 'enable', job.id);
  const eventFile = path.join(run, 'event.json');
  fs.writeFileSync(eventFile, JSON.stringify(payload));
  const watcher = spawn(SENTINEL, ['watch'], {env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
  const emit = cli(env, 'emit', job.trigger.topic, `${id}-1`, eventFile);
  let row = null;
  for (let i = 0; i < 150; i += 1) {
    await sleep(200);
    const history = cli(env, 'history');
    let parsed = null;
    try { parsed = JSON.parse(history.out); } catch { parsed = null; }
    row = parsed && parsed.find((e) => e.job_id === job.id);
    if (row && row.state !== 'queued' && row.state !== 'running') break;
  }
  await sleep(700);
  watcher.kill(); node.handle.kill();
  return {put, enable, emit, row, wakes: wakesOf(node.wakeFile)};
}

async function main() {
  const good = path.join(REPO, 'scripts', 'subagent-return-prepare.sh');
  const outside = path.join(scratch, 'outside', 'not-allowed.sh');
  fs.writeFileSync(outside, '#!/usr/bin/env bash\necho "{\\"instruction\\":\\"OUTSIDE\\"}"\n');
  // p1: a prepare whose script is outside WA_SENTINEL_SCRIPTS
  const p1 = await deliver('p1_outside_allowlist', {id: 'p1', name: 'p1', trigger: {kind: 'event', topic: 'p1'},
    action: {kind: 'wake', session: 'probe-coordinator', prompt: 'P1', prepare: {script: outside, timeout_seconds: 20}}});
  console.log(`### p1_outside_allowlist put=${p1.put.status} delivery=${p1.row && p1.row.state} wakes=${p1.wakes}`);
  console.log(`  detail: ${p1.row && p1.row.detail}`);

  // p2: a prepare whose script path carries a shell metacharacter, as a REAL file inside the allow-list
  const meta = path.join(scratch, 'allow', 'evil.sh;exit 42');
  fs.writeFileSync(meta, `#!/usr/bin/env bash
touch ${posix(path.join(scratch, 'RAN_AS_FILE'))}
printf '{"instruction":"METACHAR_SCRIPT_RAN"}
'
`);
  const p2 = await deliver('p2_metachar', {id: 'p2', name: 'p2', trigger: {kind: 'event', topic: 'p2'},
    action: {kind: 'wake', session: 'probe-coordinator', prompt: 'P2', prepare: {script: meta, timeout_seconds: 20}}});
  console.log(`### p2_metachar put=${p2.put.status} delivery=${p2.row && p2.row.state} wakes=${p2.wakes}`);
  console.log(`  detail: ${p2.row && p2.row.detail}`);
  const wakeFile2 = path.join(runs, 'p2_metachar', 'wakes.jsonl');
  const metaWakes = fs.existsSync(wakeFile2) ? fs.readFileSync(wakeFile2, 'utf8').split('\\n').filter(Boolean) : [];
  console.log(`  named file itself ran=${fs.existsSync(path.join(scratch, 'RAN_AS_FILE'))}  instruction in the wake=${metaWakes.some((l) => l.includes('METACHAR_SCRIPT_RAN'))}  (if a shell had run 'evil.sh;exit 42' the delivery would fail with code 42 and there would be no wake)`);
  // and the same metacharacter in a path that does not resolve at all
  const missing = path.join(scratch, 'allow', 'nope.sh;exit 42');
  const p2b = await deliver('p2b_metachar_missing', {id: 'p2b', name: 'p2b', trigger: {kind: 'event', topic: 'p2b'},
    action: {kind: 'wake', session: 'probe-coordinator', prompt: 'P2B', prepare: {script: missing, timeout_seconds: 20}}});
  console.log(`### p2b_metachar_missing put=${p2b.put.status} delivery=${p2b.row && p2b.row.state} wakes=${p2b.wakes}`);
  console.log(`  detail: ${p2b.row && p2b.row.detail}`);

  // p3: a prepare with an absurd timeout, against a run action with the same absurd timeout
  const p3 = await deliver('p3_huge_timeout', {id: 'p3', name: 'p3', trigger: {kind: 'event', topic: 'p3'},
    action: {kind: 'wake', session: 'probe-coordinator', prompt: 'P3', prepare: {script: good, timeout_seconds: 999999999}}});
  console.log(`### p3_huge_timeout put=${p3.put.status} delivery=${p3.row && p3.row.state} wakes=${p3.wakes}`);
  console.log(`  detail: ${p3.row && p3.row.detail}`);
  fs.mkdirSync(path.join(runs, 'p3'), {recursive: true});
  const runEnv = envFor(path.join(runs, 'p3'), 1);
  const runJob = path.join(runs, 'p3', 'run-huge.json');
  fs.writeFileSync(runJob, JSON.stringify({id: 'run-huge', name: 'run huge', trigger: {kind: 'event', topic: 'x'},
    action: {kind: 'run', script: good, timeout_seconds: 999999999}}));
  const runPut = cli(runEnv, 'put', runJob);
  console.log(`  for comparison, a RUN action with timeout_seconds=999999999: put status=${runPut.status} says: ${runPut.err.trim().split('\n').pop()}`);

  // p4: a prepare on a run action (the class the code says it refuses by name)
  const p4 = await deliver('p4_prepare_on_run', {id: 'p4', name: 'p4', trigger: {kind: 'event', topic: 'p4'},
    action: {kind: 'run', script: good, timeout_seconds: 20, prepare: {script: good, timeout_seconds: 20}}});
  console.log(`### p4_prepare_on_run put=${p4.put.status} delivery=${p4.row && p4.row.state} wakes=${p4.wakes}`);
  console.log(`  detail: ${p4.row && p4.row.detail}`);

  // p5: a prepare nested in a pipeline step (accepted at put; is it read?)
  const stepMarker = path.join(scratch, 'STEP_PREPARE_RAN');
  fs.rmSync(stepMarker, {force: true});
  const stepPrepare = path.join(scratch, 'allow', 'step-prepare.sh');
  fs.writeFileSync(stepPrepare, `#!/usr/bin/env bash
touch ${posix(stepMarker)}
printf '{"instruction":"STEP_PREPARE"}'
`);
  const stepRun = path.join(scratch, 'allow', 'step-run.sh');
  fs.writeFileSync(stepRun, '#!/usr/bin/env bash\nprintf \'{"events":[]}\n\'\n');
  const p5 = await deliver('p5_pipeline_step_prepare', {id: 'p5', name: 'p5', trigger: {kind: 'event', topic: 'p5'},
    action: {kind: 'pipeline', steps: [{kind: 'run', script: stepRun, timeout_seconds: 20,
      prepare: {script: stepPrepare, timeout_seconds: 20}}]}});
  console.log(`### p5_pipeline_step_prepare put=${p5.put.status} delivery=${p5.row && p5.row.state} wakes=${p5.wakes}`);
  console.log(`  detail: ${p5.row && p5.row.detail}`);
  console.log(`  the step's prepare script ran=${fs.existsSync(stepMarker)}  (its marker file)`);

  // p6: a relative prepare script
  const p6 = await deliver('p6_relative_script', {id: 'p6', name: 'p6', trigger: {kind: 'event', topic: 'p6'},
    action: {kind: 'wake', session: 'probe-coordinator', prompt: 'P6',
      prepare: {script: 'scripts/subagent-return-prepare.sh', timeout_seconds: 20}}});
  console.log(`### p6_relative_script put=${p6.put.status} delivery=${p6.row && p6.row.state} wakes=${p6.wakes}`);
  console.log(`  detail: ${p6.row && p6.row.detail}`);
}
main().catch((e) => { console.error(e.stack); process.exitCode = 1; });
