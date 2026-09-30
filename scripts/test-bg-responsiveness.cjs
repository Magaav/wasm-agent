#!/usr/bin/env node
// Hermetic listener/admission and background/read routing probes. No builds or live node access.
// node scripts/test-bg-responsiveness.cjs <wa-binary> [--expect-reproduction]
//   [--phase all|routing|admission|pressure] [--compiled-serve-sha256 <build-time serve.rs hash>]
//   [--report <JSON path>] [--keep]
// Default: post-fix verification. Baseline mode requires reproduction in each selected phase.
// Admission pressure runs only in verification (all or pressure), with queue depth 2 and a
// 1.8s deadline. A timed-out holder keeps Lua busy until explicitly released; expired queued
// tokens must never enter Lua, take run ownership, or invoke the local provider afterwards.
// The caller-supplied compiled hash is an external build attestation, not extracted from wa.
// An installed binary without that attestation is historical evidence, never current-source proof.
// Minimal Lua fixtures replace application logic, retaining the binary's real serve/scheduler/
// provider host paths. Results concern these host paths, not full application/provider behavior.
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');

const root = path.resolve(__dirname, '..');
const options = { phase: 'all', expect: false, keep: false };
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === '--expect-reproduction') options.expect = true;
  else if (arg === '--keep') options.keep = true;
  else if (['--phase', '--report', '--compiled-serve-sha256'].includes(arg)) {
    const value = process.argv[++i];
    if (!value || value.startsWith('--')) throw new Error('Missing value for ' + arg);
    options[arg.slice(2)] = value;
  } else if (!arg.startsWith('--') && !options.binary) options.binary = arg;
  else throw new Error('Unknown argument: ' + arg);
}
assert.ok(['all', 'routing', 'admission', 'pressure'].includes(options.phase), 'invalid --phase');
assert.ok(!(options.expect && options.phase === 'pressure'), 'pressure is a verify-only phase');
if (options['compiled-serve-sha256']) assert.match(options['compiled-serve-sha256'], /^[a-f0-9]{64}$/i);
const binary = path.resolve(options.binary || path.join(root, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-bg-responsiveness-'));
const started = performance.now();
const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const elapsed = () => Math.round(performance.now() - started);
const children = [], reservations = [], sockets = new Set();
let mock, backgroundResponse, backgroundReleased = false, backgroundSeen = false;
let mockRequests = 0;
let stopping = false, stopPromise, fatal;
const report = {
  schema: 1, mode: options.expect ? 'expect-reproduction' : 'verify', phase: options.phase,
  work, binary: { path: binary }, phases: {}, childPids: [],
  bounds: { totalMs: 8000, barrierMs: 600, requestMs: 2200, admissionTimeoutMs: 1800,
    admissionQueueDepth: 2, pressureReadMs: 300, pressureDeadlineSlackMs: 300 },
  skippedPhases: options.expect ? ['pressure: verify-only'] : [],
};

// Remove provider configuration, proxies, and all node/test knobs; never print their values.
const clean = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
  !/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_|GEMINI_|GOOGLE_|AZURE_|AWS_|COHERE_|MISTRAL_|GROQ_|DEEPSEEK_|OLLAMA_|OPENROUTER_|XAI_|CODEX_|PI_)/i.test(key)
  && !/^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|NODE_OPTIONS)$/i.test(key)
  && !/(PROVIDER|LLM|MODEL)/i.test(key)
  && !/(API_KEY|ACCESS_TOKEN|AUTH_TOKEN)$/i.test(key)));

async function until(condition, label, budget = 2000) {
  const deadline = performance.now() + budget;
  do {
    if (fatal) throw fatal;
    if (await condition()) return;
    await sleep(10);
  } while (performance.now() < deadline);
  throw new Error('Timed out waiting for ' + label);
}

// Disable pooling: each measurement has its own socket accepted by the listener.
// The explicit wall-clock timer includes time in the kernel accept backlog.
function request(port, route, { method = 'GET', body = '', session = '', headers = {}, timeout = 2200 } = {}) {
  const measurement = { route, session, method, startedMs: elapsed(), done: false };
  const begin = performance.now();
  measurement.promise = new Promise((resolve) => {
    let settled = false;
    const settle = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      Object.assign(measurement, result, { ms: Math.round(performance.now() - begin), done: true });
      resolve(measurement);
    };
    const req = http.request({ host: '127.0.0.1', port, path: route, method, agent: false,
      headers: { connection: 'close', 'content-length': Buffer.byteLength(body), 'x-wa-session': session, ...headers } }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { text += chunk; });
      res.on('end', () => {
        let value;
        try { value = JSON.parse(text); } catch { value = text; }
        settle({ status: res.statusCode, value });
      });
      res.on('error', (error) => settle({ error: error.message }));
    });
    req.on('socket', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
    req.on('error', (error) => settle({ error: error.message }));
    req.on('finish', () => { measurement.sentMs = elapsed(); });
    const timer = setTimeout(() => { settle({ timedOut: true }); req.destroy(); }, timeout);
    req.end(body);
  });
  return measurement;
}
function json(measurement) {
  const { promise, ...value } = measurement;
  return value;
}
function healthy(measurement) {
  assert.equal(measurement.status, 200, JSON.stringify(json(measurement)));
  assert.ok(!measurement.error && !measurement.timedOut);
  assert.ok(!measurement.value?.error, JSON.stringify(json(measurement)));
  return measurement.value;
}
function threads(health) { return health.node_threads || health.workers || []; }
function snapshot(health) {
  return { ok: health.ok, queue: health.queue, runs: health.runs, run_ids: health.run_ids,
    run_limits: health.run_limits, node_threads: threads(health) };
}
async function reservePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  if ([8799, 8800].includes(port)) { await new Promise((resolve) => server.close(resolve)); return reservePort(); }
  reservations.push(server);
  return { port, release: () => new Promise((resolve) => server.close(resolve)) };
}
function releaseFile(name) { fs.writeFileSync(path.join(work, name + '.release'), 'release\n'); }
function releaseBackground() {
  backgroundReleased = true;
  if (!backgroundResponse || backgroundResponse.writableEnded || backgroundResponse.destroyed) return;
  backgroundResponse.end('data: ' + JSON.stringify({ choices: [{ delta: { content: 'fixture' }, finish_reason: 'stop' }] }) + '\n\ndata: [DONE]\n\n');
}

function writeFixture() {
  const luaRoot = path.join(work, 'lua-root');
  fs.mkdirSync(path.join(luaRoot, 'lua/core'), { recursive: true });
  fs.mkdirSync(path.join(luaRoot, 'lua/vendor'), { recursive: true });
  fs.copyFileSync(path.join(root, 'lua/vendor/json.lua'), path.join(luaRoot, 'lua/vendor/json.lua'));
  fs.writeFileSync(path.join(luaRoot, 'lua/core/subagents.lua'), '-- isolated fixture: no subagents\n');
  fs.writeFileSync(path.join(luaRoot, 'lua/core/server.lua'), `
local json = dofile('lua/vendor/json.lua')
local instance = host.uuid()
local scratch = assert(host.getenv('WASM_AGENT_HOME'))
local function barrier(name)
  assert(host.write_file(scratch .. '/' .. name .. '.entered', instance))
  local start = host.monotonic_ms()
  while not host.read_file(scratch .. '/' .. name .. '.release') do
    if host.monotonic_ms() - start > 6000 then error('fixture barrier deadline: ' .. name) end
    host.sleep(10)
  end
end
local function read(session)
  if session == 'hold-reader-zero' then barrier('reader') end
  return json.encode({fixture=true, instance=instance, session=session})
end
function wa_me(session) return read(session) end
function wa_models(session) return read(session) end
function wa_model(node, session) return read(session) end
function wa_sessions(session) return read(session) end
function wa_identity() return json.encode({user={id='fixture-owner'}}) end
function wa_admission(session, node, body)
  local args = json.decode(body)
  if args.probe == 'pressure' then
    assert(type(args.token) == 'string' and args.token:match('^[a-z0-9%-]+$'))
    assert(host.write_file(scratch .. '/' .. args.token .. '.entered', instance))
    if args.token == 'pressure-holder' then barrier('pressure') end
    if args.token == 'pressure-recovery' then return json.encode({error='fixture_pressure_recovered'}) end
  end
  if args.probe == 'admission' then
    barrier('admission')
    return json.encode({error='fixture_admission_released'})
  end
  return json.encode({conversation=args.thread, user={id='fixture-owner'}})
end
function wa_reply(body)
  local args = json.decode(body)
  if args.probe == 'pressure' then
    assert(host.write_file(scratch .. '/' .. args.token .. '.run-entered', instance))
  end
  local answer = host.http_stream('POST', assert(host.getenv('WASM_AGENT_LLM_BASE_URL')) .. '/v1/chat/completions', '{}', body)
  if type(answer) == 'string' then answer = json.decode(answer) end
  assert(not answer.error and answer.status == 200, json.encode(answer))
  return json.encode({fixture=true, instance=instance, content=answer.content})
end
function wa_sync_tick() return '{}' end
function wa_orchestrator_tick() return '{}' end
`);
  fs.mkdirSync(path.join(work, 'ui'));
  fs.writeFileSync(path.join(work, 'ui/index.html'), '<!doctype html><title>scratch fixture</title>');
  return luaRoot;
}

async function routingProbe(port) {
  const phase = report.phases.routing = {};
  const bg = request(port, '/chat', { method: 'POST', timeout: 6000,
    headers: { 'x-wa-run-class': 'background' }, body: JSON.stringify({ thread: 'fixture-background', probe: 'background' }) });
  await until(() => backgroundSeen, 'mock provider entered');
  const before = healthy(await request(port, '/health').promise);
  const run = (before.runs || []).find((r) => r.conversation === 'fixture-background');
  assert.ok(run && run.class === 'background' && run.node_thread >= 2, 'background must use nonzero reserved worker');
  phase.backgroundWorker = run.node_thread;
  phase.before = snapshot(before);
  const idleRead = await request(port, '/me', { session: 'paired-before' }).promise;
  healthy(idleRead);
  phase.pairedBefore = json(idleRead);
  assert.ok(!bg.done && !backgroundReleased, 'background must remain active during paired read');

  // Node-thread 0 is held in a harmless read, not an additional model or busy-loop wedge.
  const zero = request(port, '/me', { session: 'hold-reader-zero', timeout: 6000 });
  await until(() => fs.existsSync(path.join(work, 'reader.entered')), 'worker 0 read barrier');
  const held = healthy(await request(port, '/health').promise);
  assert.equal(threads(held).find((t) => t.id === 0)?.label, 'GET /me', 'read barrier must own worker 0');
  const idleReaders = threads(held).filter((t) => t.id > 0 && t.id < 4 && !t.label);
  assert.ok(idleReaders.length >= 1, 'must have an idle reader alongside held background worker');
  phase.held = snapshot(held);
  phase.idleReaderIds = idleReaders.map((t) => t.id);
  const reads = Array.from({ length: 6 }, (_, i) => request(port, ['/me', '/models', '/sessions'][i % 3], { session: 'routing-' + i }));
  await sleep(report.bounds.barrierMs);
  phase.pendingWhileHeld = reads.filter((r) => !r.done).map((r) => r.session);
  const healthDuring = await request(port, '/health').promise;
  const assetDuring = await request(port, '/').promise;
  healthy(assetDuring);
  const during = healthy(healthDuring);
  phase.healthDuring = json(healthDuring);
  phase.assetDuring = json(assetDuring);
  phase.during = snapshot(during);
  assert.ok(!bg.done && !zero.done && !backgroundReleased, 'both barriers must still be held');
  assert.ok((during.runs || []).some((r) => r.conversation === 'fixture-background' && r.node_thread === run.node_thread));
  assert.ok(reads.some((r) => r.done && r.status === 200), 'paired healthy Lua read required while background held');
  phase.releaseMs = elapsed();
  releaseBackground();
  await Promise.all(reads.map((r) => r.promise));
  const bgResult = await bg.promise;
  phase.background = json(bgResult);
  const backgroundInstance = healthy(bgResult).instance;
  assert.ok(backgroundInstance && bgResult.value.fixture, 'mock provider run must finish successfully');
  assert.equal(bgResult.value.content, 'fixture');
  for (const r of reads) healthy(r);
  for (const r of reads) assert.equal(r.value.session, r.session, 'read must return its fixture token');
  const queuedBehindBackground = reads.filter((r) => phase.pendingWhileHeld.includes(r.session) && r.value.instance === backgroundInstance);
  phase.reads = reads.map(json);
  phase.background = json(bgResult);
  phase.queuedBehindBackground = queuedBehindBackground.map((r) => r.session);
  phase.reproduced = queuedBehindBackground.length > 0;
  phase.attribution = 'listener/static replies stayed healthy; read response interpreter matches the held background run';
  releaseFile('reader');
  healthy(await zero.promise);
  const recovered = await request(port, '/me', { session: 'routing-recovered' }).promise;
  healthy(recovered);
  phase.recovered = json(recovered);
  phase.passed = options.expect ? phase.reproduced : phase.pendingWhileHeld.length === 0;
}

async function admissionProbe(port) {
  const phase = report.phases.admission = {};
  const before = healthy(await request(port, '/health').promise);
  assert.equal((before.runs || []).length, 0, 'admission probe must start without active runs');
  phase.before = snapshot(before);
  const paired = await request(port, '/me', { session: 'admission-before' }).promise;
  healthy(paired);
  phase.pairedBefore = json(paired);
  const admission = request(port, '/chat', { method: 'POST', body: JSON.stringify({ probe: 'admission', thread: 'never-admitted' }) });
  await until(() => fs.existsSync(path.join(work, 'admission.entered')), 'resolver barrier');
  const probes = [request(port, '/health'), request(port, '/', {}), request(port, '/me', { session: 'admission-read' })];
  await sleep(report.bounds.barrierMs);
  assert.ok(!admission.done && !fs.existsSync(path.join(work, 'admission.release')), 'resolver must remain held');
  phase.pendingWhileHeld = probes.filter((r) => !r.done).map((r) => r.route);
  phase.releaseMs = elapsed();
  releaseFile('admission');
  await Promise.all([admission.promise, ...probes.map((r) => r.promise)]);
  assert.equal(admission.status, 400, JSON.stringify(json(admission)));
  assert.equal(admission.value.error, 'fixture_admission_released', 'must refuse before run admission');
  for (const p of probes) healthy(p);
  phase.admission = json(admission);
  phase.probes = probes.map(json);
  phase.reproduced = phase.pendingWhileHeld.includes('/health') && phase.pendingWhileHeld.includes('/');
  phase.attribution = 'resolver entered before probes; static health and asset do not route through Lua workers; run was refused before admission/inference';
  const recovery = await request(port, '/health').promise;
  const after = healthy(recovery);
  assert.equal((after.runs || []).length, 0);
  phase.recovered = json(recovery);
  phase.passed = options.expect ? phase.reproduced : phase.pendingWhileHeld.length === 0;
}

async function pressureProbe(port) {
  const phase = report.phases.pressure = {
    queueDepth: report.bounds.admissionQueueDepth, deadlineMs: report.bounds.admissionTimeoutMs,
    responsive: [], inferenceBefore: mockRequests,
  };
  const tokenEntered = (token) => fs.existsSync(path.join(work, token + '.entered'));
  const ownsPressure = (health) => (health.runs || []).some((run) => run.conversation.startsWith('pressure-'));
  const pressureIds = (health) => (health.run_ids || []).filter((run) => run.conversation.startsWith('pressure-'));
  const submit = (token) => request(port, '/chat', { method: 'POST', session: token,
    timeout: phase.deadlineMs + report.bounds.pressureDeadlineSlackMs + 200,
    body: JSON.stringify({ probe: 'pressure', token, thread: token }) });
  const timelyReads = async (label) => {
    const probes = [request(port, '/health', { timeout: report.bounds.pressureReadMs }),
      request(port, '/', { timeout: report.bounds.pressureReadMs }),
      request(port, '/me', { session: 'pressure-read-' + label, timeout: report.bounds.pressureReadMs })];
    await Promise.all(probes.map((probe) => probe.promise));
    phase.responsive.push({ label, probes: probes.map(json) });
    for (const probe of probes) healthy(probe);
    const health = probes[0].value;
    assert.ok(!ownsPressure(health), 'pressure requests must not own run lanes');
    assert.equal(pressureIds(health).length, 0, 'pressure requests must not create even settled run IDs');
    assert.equal(probes[2].value.session, 'pressure-read-' + label);
    return health;
  };

  const before = await timelyReads('before');
  assert.equal((before.runs || []).length, 0, 'pressure must start with no active run');
  phase.before = snapshot(before);
  const holder = submit('pressure-holder');
  await until(() => tokenEntered('pressure-holder') && tokenEntered('pressure'), 'pressure resolver holder');

  // Stagger enqueue times so each waiting job reaches the dispatcher with remaining budget.
  // That also tests expired jobs already queued on the separate Lua resolver, not only jobs
  // dropped in the outer admission queue. Finish + read fences keep overflow behind both jobs.
  await sleep(200);
  const waitingA = submit('pressure-wait-a');
  await until(() => waitingA.sentMs !== undefined, 'first pressure request sent', 300);
  await timelyReads('waiting-a');
  await sleep(200);
  const waitingB = submit('pressure-wait-b');
  await until(() => waitingB.sentMs !== undefined, 'second pressure request sent', 300);
  await timelyReads('waiting-b');
  assert.ok(!holder.done && !waitingA.done && !waitingB.done, 'queue must be held before overflow');

  const overflow = submit('pressure-overflow');
  await overflow.promise;
  phase.overflow = json(overflow);
  assert.equal(overflow.status, 503, JSON.stringify(phase.overflow));
  assert.equal(overflow.value?.error, 'admission_busy', 'overflow must have a named admission_busy refusal');
  assert.ok(overflow.ms < report.bounds.pressureReadMs, 'overflow must refuse promptly without waiting for resolver');
  assert.ok(!tokenEntered('pressure-overflow'), 'overflow must never execute Lua');
  await timelyReads('overflow');

  await Promise.all([holder.promise, waitingA.promise, waitingB.promise]);
  phase.expired = [holder, waitingA, waitingB].map(json);
  for (const expired of [holder, waitingA, waitingB]) {
    assert.equal(expired.status, 503, JSON.stringify(json(expired)));
    assert.equal(expired.value?.error, 'admission_timeout', 'waiting requests must expire with a named admission_timeout');
    assert.ok(expired.ms >= phase.deadlineMs - 100, 'must wait for the admission deadline, not refuse early');
    assert.ok(expired.ms <= phase.deadlineMs + report.bounds.pressureDeadlineSlackMs,
      'queue residence must count toward the deadline; resolver must not get a fresh budget');
  }
  assert.ok(!fs.existsSync(path.join(work, 'pressure.release')), 'resolver must remain held after caller timeouts');
  phase.beforeRelease = snapshot(await timelyReads('expired-still-held'));
  phase.enteredBeforeRelease = ['pressure-holder', 'pressure-wait-a', 'pressure-wait-b', 'pressure-overflow'].filter(tokenEntered);
  assert.deepEqual(phase.enteredBeforeRelease, ['pressure-holder']);
  assert.equal(mockRequests, phase.inferenceBefore, 'expired requests must not invoke provider');

  phase.releaseMs = elapsed();
  releaseFile('pressure');
  const recovery = submit('pressure-recovery');
  await recovery.promise;
  phase.recovery = json(recovery);
  assert.equal(recovery.status, 400, JSON.stringify(phase.recovery));
  assert.equal(recovery.value?.error, 'fixture_pressure_recovered', 'resolver must recover after draining expired jobs');
  assert.ok(tokenEntered('pressure-recovery'), 'recovery must actually execute Lua after expired resolver jobs');
  phase.enteredAfterRecovery = ['pressure-holder', 'pressure-wait-a', 'pressure-wait-b', 'pressure-overflow', 'pressure-recovery'].filter(tokenEntered);
  assert.deepEqual(phase.enteredAfterRecovery, ['pressure-holder', 'pressure-recovery'], 'expired queued resolver jobs must never execute Lua later');
  phase.runEnteredTokens = ['pressure-holder', 'pressure-wait-a', 'pressure-wait-b', 'pressure-overflow'].filter((token) =>
    fs.existsSync(path.join(work, token + '.run-entered')));
  assert.equal(phase.runEnteredTokens.length, 0, 'expired requests must never enter run Lua');
  phase.inferenceAfter = mockRequests;
  assert.equal(phase.inferenceAfter, phase.inferenceBefore, 'pressure requests must not trigger inference, even after release');
  phase.afterRecovery = snapshot(await timelyReads('recovered'));
  phase.attribution = 'depth-2 dispatcher overflow; queue plus resolver wait use one deadline; recovery passed expired resolver jobs without Lua entry, run IDs or inference';
  phase.passed = true;
}

function stop() {
  if (stopPromise) return stopPromise;
  stopping = true;
  stopPromise = (async () => {
    releaseFile('reader');
    releaseFile('admission');
    releaseFile('pressure');
    releaseBackground();
    for (const socket of sockets) socket.destroy();
    // Kill only exact children owned by this invocation; never process names or trees.
    const exited = await Promise.all(children.map(async (child) => {
      if (child.exitCode !== null || child.signalCode !== null) return true;
      return new Promise((resolve) => {
        const timer = setTimeout(() => resolve(false), 1200);
        child.once('exit', () => { clearTimeout(timer); resolve(true); });
        child.kill('SIGKILL');
      });
    }));
    report.cleanup = { childPidsExited: exited.every(Boolean) };
    if (mock) { mock.closeAllConnections(); await new Promise((resolve) => mock.close(resolve)); }
    for (const reservation of reservations) if (reservation.listening) await new Promise((resolve) => reservation.close(resolve));
    if (!report.cleanup.childPidsExited) { options.keep = true; report.cleanup.error = 'child exit not proven'; }
  })();
  return stopPromise;
}

async function main() {
  const bytes = fs.readFileSync(binary);
  report.binary.sha256 = sha256(bytes);
  const serveHash = sha256(fs.readFileSync(path.join(root, 'rust/wa-host/src/serve.rs')));
  const compiledHash = options['compiled-serve-sha256']?.toLowerCase() || null;
  report.source = { serveSha256: serveHash, compiledServeSha256: compiledHash,
    alignment: compiledHash ? (compiledHash === serveHash ? 'caller-attested-match' : 'mismatch') : 'unknown-historical-binary',
    lua: 'scratch fixture loaded explicitly via WASM_AGENT_LUA_ROOT; application modules not exercised',
    symbolsInspected: ['choose_node_thread', 'pick_run_node_thread', 'resolve_with', 'resolve_admission', 'run/listener.incoming'],
    scope: 'real Rust listener/scheduler/provider host with minimal deterministic Lua handlers' };
  if (compiledHash) assert.equal(compiledHash, serveHash, 'compiled-source alignment mismatch');
  const luaRoot = writeFixture();
  mock = http.createServer((req, res) => {
    if (req.method !== 'POST' || req.url !== '/v1/chat/completions') { res.writeHead(404); res.end(); return; }
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      mockRequests++;
      if (!body.includes('fixture-background') || backgroundSeen) { res.writeHead(400); res.end(); return; }
      backgroundSeen = true;
      backgroundResponse = res;
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.flushHeaders();
      if (backgroundReleased) releaseBackground();
    });
  });
  await new Promise((resolve, reject) => { mock.once('error', reject); mock.listen(0, '127.0.0.1', resolve); });
  assert.ok(![8799, 8800].includes(mock.address().port));
  const nodePort = await reservePort(), clientPort = await reservePort();
  report.ports = { node: nodePort.port, client: clientPort.port, mock: mock.address().port };
  const env = { ...clean, HOME: work, USERPROFILE: work, APPDATA: work, LOCALAPPDATA: work,
    XDG_CONFIG_HOME: work, XDG_DATA_HOME: work, XDG_CACHE_HOME: work,
    WASM_AGENT_HOME: work, WASM_AGENT_LUA_ROOT: luaRoot, WA_GRAPH_WATCH: '0', WA_GRAPH_ROOT: work,
    WA_GRAPH_DB: path.join(work, 'graph.db'), WASM_AGENT_LLM_MODEL: 'fixture',
    WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + mock.address().port,
    WASM_AGENT_LLM_API_KEY: 'fixture-only', WASM_AGENT_WORKERS: '3', WASM_AGENT_WORKERS_MAX: '4',
    WASM_AGENT_INTERACTIVE_RESERVE: '2', WASM_AGENT_CONTROL_WORKERS: '1',
    WASM_AGENT_WORKERS_IDLE_SECONDS: '60', WASM_AGENT_WORKER_STALL_SECONDS: '30',
    WASM_AGENT_WORKER_STALL_EXIT_SECONDS: '0', WASM_AGENT_ADMISSION_TIMEOUT_MS: String(report.bounds.admissionTimeoutMs),
    WASM_AGENT_ADMISSION_QUEUE_DEPTH: String(report.bounds.admissionQueueDepth) };
  await nodePort.release();
  await clientPort.release();
  const log = fs.openSync(path.join(work, 'serve.log'), 'w');
  let child;
  try {
    // --db first also avoids installed runtime-worktree.txt redirection triggered by args[0]=serve.
    child = spawn(binary, ['--db', path.join(work, 'scratch.db'), 'serve', '--port', String(nodePort.port),
      '--client-port', String(clientPort.port), '--ui', path.join(work, 'ui')],
    { cwd: work, env, windowsHide: true, stdio: ['ignore', log, log] });
  } finally { fs.closeSync(log); }
  children.push(child);
  report.childPids.push(child.pid);
  child.on('error', (error) => { fatal = error; });
  child.on('exit', (code, signal) => { if (!stopping) fatal = new Error('scratch node exited: ' + code + '/' + signal); });
  await until(async () => (await request(nodePort.port, '/health', { timeout: 150 }).promise).status === 200, 'scratch listener', 3500);
  await until(async () => threads(healthy(await request(nodePort.port, '/health').promise)).length >= 4, 'warm readers');
  assert.equal(healthy(await request(nodePort.port, '/me', { session: 'fixture-check' }).promise).fixture, true,
    'must load scratch Lua, not embedded application logic');
  if (['all', 'routing'].includes(options.phase)) await routingProbe(nodePort.port);
  if (['all', 'admission'].includes(options.phase)) await admissionProbe(nodePort.port);
  if (!options.expect && ['all', 'pressure'].includes(options.phase)) await pressureProbe(nodePort.port);
  for (const [name, phase] of Object.entries(report.phases)) {
    assert.ok(phase.passed, name + ': ' + (options.expect ? 'expected reproduction absent' : 'requests delayed while barrier held'));
  }
  report.passed = true;
}

const watchdog = setTimeout(() => {
  fatal = new Error('fixture exceeded ' + report.bounds.totalMs + 'ms runtime bound');
  stop().catch((error) => { report.cleanupError = error.message; });
}, report.bounds.totalMs);
process.once('SIGINT', () => { fatal = new Error('interrupted'); stop().catch(() => {}); });
process.once('SIGTERM', () => { fatal = new Error('terminated'); stop().catch(() => {}); });
(async () => {
  try { await main(); }
  catch (error) { report.passed = false; report.error = error.message; options.keep = true; }
  finally {
    clearTimeout(watchdog);
    try { await stop(); } catch (error) { report.passed = false; report.cleanupError = error.message; options.keep = true; }
    report.elapsedMs = elapsed();
    report.retained = options.keep;
    report.mockProviderEntered = backgroundSeen;
    report.mockProviderRequests = mockRequests;
    if (!report.cleanup?.childPidsExited) report.passed = false;
    const text = JSON.stringify(report, null, 2) + '\n';
    fs.writeFileSync(path.join(work, 'measurement.json'), text);
    if (options.report) fs.writeFileSync(path.resolve(options.report), text);
    process.stdout.write(text);
    if (!options.keep) fs.rmSync(work, { recursive: true, force: true });
    process.exitCode = report.passed ? 0 : 1;
  }
})();
