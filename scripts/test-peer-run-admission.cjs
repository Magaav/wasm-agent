// Real authorized peer-run admission: a signed direct POST /node/chat and a signed relayed one,
// between two isolated nodes, against a local rendezvous/relay and a local mock model.
//
//   node scripts/test-peer-run-admission.cjs [wa-binary]
//
// This is the positive half of `scripts/test-run-isolation.sh`'s forged-peer case. That fixture
// proves a forged signature is refused; this one proves the real path runs, and that it runs through
// admission rather than around it:
//
//   * the verified peer author owns the conversation, not the credential or a header;
//   * the body's authenticated `thread` is the scheduling key;
//   * the signature is verified ONCE (a second verification of the same signed request is a replay,
//     so a successful reply is the proof that the run half does not re-verify);
//   * a peer run is forced background and cannot borrow the two interactive slots;
//   * a duplicate is refused, and a body that does not match its signature is refused before
//     admission (no owner is created);
//   * the peer's transcript is filed under the peer author, not the local operator's.
//
// No cloud rendezvous, no paid account: the registry is `wa rendezvous` on loopback and the model is
// a local HTTP fixture. Each node has its own home and its own node.key.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const binary = path.resolve(process.argv[2] || path.join(root, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-peer-run-'));
// A fixture must never inherit the operator's home, credentials or model configuration: the
// coordinator caught a fixture that wrote the real HOME, and this test starts real `wa serve`
// processes. Everything WASM_AGENT_* is dropped, then set explicitly per node.
const clean = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(WASM_AGENT_|WA_|OPENAI_API_KEY$|OPENCODE_GO_API_KEY$)/i.test(key)));

const children = [];
let checks = 0;
let mock = null;
const hash = (text) => crypto.createHash('sha256').update(text).digest('hex');
const now = () => Math.floor(Date.now() / 1000);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function check(value, label) { assert.ok(value, label); console.log('ok   ' + label); checks++; }
function child(name, args, env) {
  const log = fs.openSync(path.join(work, name + '.log'), 'a');
  const process_ = spawn(binary, args, { env, cwd: work, stdio: ['ignore', log, log], windowsHide: true });
  children.push(process_);
  return process_;
}
function cli(env, args) {
  const result = spawnSync(binary, args, { env, cwd: work, encoding: 'utf8', timeout: 60000, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error('CLI ' + args.join(' ') + ': ' + (result.error || result.stderr || result.stdout));
  return { value: args[0] === 'node' && args[1] === 'sign' ? result.stdout.trim() : JSON.parse(result.stdout.trim()) };
}
function fixture(name) {
  const home = path.join(work, name);
  fs.mkdirSync(home, { recursive: true });
  const env = { ...clean, WASM_AGENT_HOME: home };
  const node = { home, env, name };
  Object.assign(node, cli(env, ['node']).value);
  return node;
}
function signature(node, message) { return cli(node.env, ['node', 'sign', message]).value; }
/// `verify_peer` signs `action|node_id|ts`, plus the hash of the body when there is one.
function signedHeaders(node, action, body) {
  const ts = now();
  const suffix = body === undefined ? '' : '|' + hash(body);
  return {
    'content-type': 'application/json',
    'x-wa-node': node.node_id,
    'x-wa-pub': node.public_key,
    'x-wa-ts': String(ts),
    'x-wa-sig': signature(node, action + '|' + node.node_id + '|' + ts + suffix),
  };
}
async function request(url, method = 'GET', body, headers = {}) {
  const response = await fetch(url, { method, headers, body, signal: AbortSignal.timeout(90000) });
  const text = await response.text();
  let value;
  try { value = JSON.parse(text); } catch { value = text; }
  return { status: response.status, value, text };
}
async function until(condition, label, ms = 30000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { if (await condition()) return; } catch { /* keep waiting */ }
    await sleep(100);
  }
  throw new Error('timeout: ' + label);
}
async function stop(process_) {
  if (!process_ || process_.exitCode !== null || process_.signalCode !== null) return;
  const done = new Promise((resolve) => process_.once('exit', resolve));
  process_.kill();
  await done;
}
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

/// A local OpenAI-compatible streaming fixture. It echoes the last `RUN-MARKER-<word>` in the prompt;
/// a marker containing `HOLD` is held so a peer run can be held while local chats run.
function startMock() {
  const server = http.createServer((req, res) => {
    if (req.method === 'GET') { res.end('ready'); return; }
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      const markers = body.match(/RUN-MARKER-[A-Za-z0-9-]+/g) || [];
      const marker = markers.length ? markers[markers.length - 1] : 'ok';
      const hold = marker.includes('HOLD') ? 5000 : 150;
      setTimeout(() => {
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        let index = 0;
        const tick = () => {
          if (index < marker.length) {
            res.write('data: ' + JSON.stringify({ id: 'mock', choices: [{ delta: { content: marker[index] }, finish_reason: null }] }) + '\n\n');
            index += 1;
            setTimeout(tick, 10);
            return;
          }
          res.write('data: ' + JSON.stringify({ id: 'mock', choices: [{ delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }) + '\n\n');
          res.write('data: [DONE]\n\n');
          res.end();
        };
        tick();
      }, hold);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port })));
}

async function register(service, node, role = 'master') {
  const ts = now();
  const payload = {
    node_id: node.node_id, public_key: node.public_key, name: node.name, role, endpoints: [], ts,
    signature: signature(node, node.node_id + '|' + ts),
  };
  return request(service + '/register', 'POST', JSON.stringify(payload), { 'content-type': 'application/json' });
}
function runIds(health) { return (health && health.run_ids) || []; }
function runs(health) { return (health && health.runs) || []; }

(async () => {
  mock = await startMock();
  const rendezvousPort = await freePort();
  const service = 'http://127.0.0.1:' + rendezvousPort;

  const primary = fixture('primary');
  const peer = fixture('peer');
  const guest = fixture('guest');
  const stranger = fixture('stranger');

  // Two real nodes with two real identities in two real homes. If this fails, the rest is meaningless.
  check(primary.node_id !== peer.node_id, 'the two nodes have distinct identities');
  const primaryKey = path.join(primary.home, '.wasm-agent', 'node.key');
  const peerKey = path.join(peer.home, '.wasm-agent', 'node.key');
  check(fs.existsSync(primaryKey) && fs.existsSync(peerKey), 'each node owns a node.key in its own home');
  check(fs.readFileSync(primaryKey, 'utf8') !== fs.readFileSync(peerKey, 'utf8'), 'the two node keys differ');

  // Local rendezvous/relay. The primary and the peer are the configured masters; the guest is not.
  const registry = fixture('registry');
  registry.args = ['rendezvous', '--port', String(rendezvousPort), '--db', path.join(registry.home, 'rendezvous.db')];
  registry.child = child('registry', registry.args, {
    ...registry.env,
    WASM_AGENT_NETWORK_ADMINS: primary.node_id + ',' + peer.node_id,
  });
  await until(async () => (await request(service + '/health')).status === 200, 'local rendezvous');

  check((await register(service, peer, 'master')).status === 200, 'the peer master registers with the local rendezvous');
  check((await register(service, guest, 'master')).status === 200, 'the guest registers');
  const guestLookup = await request(service + '/lookup?node_id=' + guest.node_id, 'GET', undefined, signedHeaders(peer, 'lookup'));
  check(guestLookup.value.role === 'guest', 'a non-admin claiming master is stored as guest, not elevated');

  // The node being called: a real serve process with its own home, a mock model, and relay enabled.
  primary.port = await freePort();
  primary.url = 'http://127.0.0.1:' + primary.port;
  primary.child = child('primary', ['serve', '--port', String(primary.port), '--client-port', String(primary.port + 1), '--ui', path.join(root, 'ui')], {
    ...primary.env,
    WASM_AGENT_RENDEZVOUS: service,
    WASM_AGENT_RELAY: service,
    WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + mock.port,
    WASM_AGENT_LLM_API_KEY: 'test-only',
    WASM_AGENT_LLM_MODEL: 'fixture',
    WASM_AGENT_WORKERS_MAX: '4',
    WASM_AGENT_CONTROL_WORKERS: '1',
  });
  await until(async () => (await request(primary.url + '/health')).status === 200, 'primary server');
  await until(async () => {
    const nodes = (await request(service + '/nodes', 'GET', undefined, signedHeaders(primary, 'nodes'))).value.nodes || [];
    return nodes.some((node) => node.node_id === primary.node_id);
  }, 'primary registration');

  // ---- direct signed /node/chat -----------------------------------------------------------------
  const directThread = 'peer-direct';
  const directBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-DIRECT', thread: directThread });
  const directHeaders = signedHeaders(peer, 'chat', directBody);
  const direct = await request(primary.url + '/node/chat', 'POST', directBody, { ...directHeaders, accept: 'text/event-stream' });
  check(direct.status === 200 && /RUN-MARKER-PEER-DIRECT/.test(direct.text), 'a signed direct /node/chat runs and answers as the verified peer');
  // The verified author owns the conversation: the local operator cannot see or cancel it.
  const operatorStatus = await request(primary.url + '/runs', 'POST', JSON.stringify({ action: 'status', thread: directThread }), { 'content-type': 'application/json' });
  check((operatorStatus.value.runs || []).length === 0, 'the peer conversation is owned by the verified peer, not the local operator');
  // The body's authenticated thread is the scheduling key admission used.
  await until(async () => runIds((await request(primary.url + '/health')).value).some((row) => row.conversation === directThread), 'the direct run is keyed by its body thread');
  check(true, 'the authenticated body thread is preserved as the conversation key');

  // ---- signature verified once (a successful reply is the proof) ---------------------------------
  // If the run half re-verified the same signed request it would be refused as a replay, so the
  // success above already proves single verification. Make it explicit and independent.
  const onceThread = 'peer-once';
  const onceBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-ONCE', thread: onceThread });
  const once = await request(primary.url + '/node/chat', 'POST', onceBody, { ...signedHeaders(peer, 'chat', onceBody), accept: 'text/event-stream' });
  check(once.status === 200 && /RUN-MARKER-PEER-ONCE/.test(once.text) && !/replayed_request/.test(once.text), 'a peer run succeeds, so the signature was verified exactly once (no re-verify replay)');

  // ---- duplicate / replayed request refused ------------------------------------------------------
  const replayThread = 'peer-replay';
  const replayBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-REPLAY', thread: replayThread });
  const replayHeaders = signedHeaders(peer, 'chat', replayBody);
  const first = await request(primary.url + '/node/chat', 'POST', replayBody, { ...replayHeaders, accept: 'text/event-stream' });
  const second = await request(primary.url + '/node/chat', 'POST', replayBody, { ...replayHeaders, accept: 'text/event-stream' });
  check(first.status === 200 && /RUN-MARKER-PEER-REPLAY/.test(first.text), 'the first signed request runs');
  check(second.status === 403 && /replayed_request/.test(second.text), 'the identical signed request is refused as a replay');

  // ---- forged author / unverified body refused before admission ----------------------------------
  const forgedThread = 'peer-forged';
  const forgedBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-FORGED', thread: forgedThread });
  const forgedHeaders = signedHeaders(peer, 'chat', forgedBody);
  // The signature covers the body; changing it invalidates the signature.
  const tampered = await request(primary.url + '/node/chat', 'POST', forgedBody + 'tampered', { ...forgedHeaders, accept: 'text/event-stream' });
  check(tampered.status === 401 || tampered.status === 403, 'a body that does not match its signature is refused before admission');
  check(!runIds((await request(primary.url + '/health')).value).some((row) => row.conversation === forgedThread), 'the forged request created no admission');

  // ---- the verified author, not a header or body marker ------------------------------------------
  const strangerThread = 'peer-stranger';
  const strangerBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-STRANGER', thread: strangerThread });
  const strangerRun = await request(primary.url + '/node/chat', 'POST', strangerBody, { ...signedHeaders(stranger, 'chat', strangerBody), accept: 'text/event-stream' });
  check(strangerRun.status === 403 && /unknown_caller/.test(strangerRun.text), 'an unregistered master is denied before admission');
  const guestThread = 'peer-guest';
  const guestBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-GUEST', thread: guestThread });
  const guestRun = await request(primary.url + '/node/chat', 'POST', guestBody, { ...signedHeaders(guest, 'chat', guestBody), accept: 'text/event-stream' });
  check(guestRun.status === 403 && /forbidden_role/.test(guestRun.text), 'a registered guest cannot command a peer');
  // A peer naming the operator's thread is still owned by the peer: the operator's status sees none.
  const spoofThread = 'operator-session';
  const spoofBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-SPOOF', thread: spoofThread });
  await request(primary.url + '/node/chat', 'POST', spoofBody, { ...signedHeaders(peer, 'chat', spoofBody), accept: 'text/event-stream' });
  const spoofStatus = await request(primary.url + '/runs', 'POST', JSON.stringify({ action: 'status', thread: spoofThread }), { 'content-type': 'application/json' });
  check((spoofStatus.value.runs || []).length === 0, 'a peer run naming another owner\'s thread is not owned by the local operator');

  // ---- peer forced background cannot borrow the two interactive slots ----------------------------
  const holdThread = 'peer-hold';
  const holdBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-HOLD', thread: holdThread });
  const holdRun = request(primary.url + '/node/chat', 'POST', holdBody, { ...signedHeaders(peer, 'chat', holdBody), accept: 'text/event-stream' });
  await until(async () => {
    const health = (await request(primary.url + '/health')).value;
    return runs(health).some((row) => row.conversation === holdThread && row.class === 'background');
  }, 'the peer run is admitted as background');
  const holdHealth = (await request(primary.url + '/health')).value;
  const holdRow = runs(holdHealth).find((row) => row.conversation === holdThread);
  check(holdRow.worker >= 2, 'the peer background run occupies a background worker, not one of the two interactive slots');
  check(true, 'the peer run is admitted into the background lane');
  // Two ordinary interactive chats must both finish while the peer background run is still held.
  const chatA = request(primary.url + '/chat', 'POST', JSON.stringify({ text: 'answer with RUN-MARKER-A', thread: 'chat-a' }), { 'content-type': 'application/json', accept: 'text/event-stream' });
  const chatB = request(primary.url + '/chat', 'POST', JSON.stringify({ text: 'answer with RUN-MARKER-B', thread: 'chat-b' }), { 'content-type': 'application/json', accept: 'text/event-stream' });
  const [resultA, resultB] = await Promise.all([chatA, chatB]);
  const stillHeld = runs((await request(primary.url + '/health')).value).some((row) => row.conversation === holdThread && row.pending > 0);
  check(/RUN-MARKER-A/.test(resultA.text) && /RUN-MARKER-B/.test(resultB.text), 'two local interactive chats complete while the peer background run is held');
  check(stillHeld, 'both local chats progressed before the peer background run was released');
  check(/RUN-MARKER-PEER-HOLD/.test((await holdRun).text), 'the held peer run completes after release');

  // ---- signed relay /node/chat -------------------------------------------------------------------
  const relayThread = 'peer-relay';
  const relayBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-RELAY', thread: relayThread });
  const rid = crypto.randomUUID();
  const envelope = JSON.stringify({ rid, to: primary.node_id, method: 'POST', path: '/node/chat', body: relayBody, headers: signedHeaders(peer, 'chat', relayBody) });
  // The relay envelope's own signature is `relay-send|node_id|ts`: the rendezvous does not include the
  // envelope body, so the sender identity is signed and the inner /node/chat headers sign the prompt.
  const relayAnswer = await request(service + '/relay/send', 'POST', envelope, signedHeaders(peer, 'relay-send'));
  check(relayAnswer.status === 200 && /RUN-MARKER-PEER-RELAY/.test(relayAnswer.value.body || ''), 'a signed relayed /node/chat runs and answers as the verified peer');
  // OBSERVATION (reported, not fixed here): the rendezvous verifies `relay-send|node_id|ts` and does
  // not include the envelope body, so one relay-send signature verifies for any envelope - the `to`
  // and `path` fields are not covered by the transport signature (the inner /node/chat headers still
  // cover the prompt, and the target re-verifies the peer author). A signature made for the first
  // envelope is therefore accepted for a second one; this is a rendezvous-contract observation for
  // the coordinator/runtime owner, not a change to unowned code.
  const crossEnvelope = JSON.stringify({ rid: crypto.randomUUID(), to: primary.node_id, method: 'POST', path: '/node/chat', body: relayBody, headers: signedHeaders(peer, 'chat', relayBody) });
  const crossAnswer = await request(service + '/relay/send', 'POST', crossEnvelope, signedHeaders(peer, 'relay-send'));
  check(crossAnswer.status === 200, 'OBSERVATION: a relay-send signature is independent of the envelope body (to/path are not covered)');
  await until(async () => runIds((await request(primary.url + '/health')).value).some((row) => row.conversation === relayThread), 'the relayed run is keyed by its body thread');
  check(true, 'the relayed run shares the same admission and body-thread key as the direct run');

  // ---- peer data is not the operator transcript --------------------------------------------------
  const operatorSessions = ((await request(primary.url + '/sessions', 'GET')).value.sessions || []).map((session) => session.title || '');
  check(!operatorSessions.some((title) => /RUN-MARKER-PEER-/.test(title)), 'no peer marker appears in the local operator\'s session list');
  check(operatorSessions.some((title) => /RUN-MARKER-A|RUN-MARKER-B/.test(title)), 'the operator\'s own chats are the ones in its session list');

  console.log('peer run admission ok (' + checks + ' checks, 0 skips; two isolated nodes, local rendezvous/relay, local mock model)');
})().catch((error) => {
  console.error(error.stack);
  process.exitCode = 1;
}).finally(async () => {
  await Promise.all(children.map(stop));
  if (mock) await new Promise((resolve) => mock.server.close(resolve));
  if (process.exitCode) console.error('Fixture logs retained at ' + work);
  else fs.rmSync(work, { recursive: true, force: true });
});
