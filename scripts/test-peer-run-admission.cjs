// Real authorized peer-run admission: a signed direct POST /node/chat and a signed relayed one,
// between two isolated destination nodes, against a local rendezvous/relay and a local mock model.
//
//   node scripts/test-peer-run-admission.cjs [wa-binary]
//
// This is the positive half of `scripts/test-run-isolation.sh`'s forged-peer case. That fixture
// proves a forged signature is refused; this one proves the real path runs, that it runs through
// admission rather than around it, and that the target node is cryptographically bound:
//
//   * the verified peer author owns the conversation, not the credential or a header;
//   * the body's authenticated `thread` is the scheduling key;
//   * the signature is verified ONCE (a second verification of the same signed request is a replay,
//     so a successful reply is the proof that the run half does not re-verify);
//   * the signed body names `to_node_id`, so a legitimately signed chat for node A that a relay
//     redirects to node B is refused by B before any conversation, admission or inference;
//   * a modified target/path/body, a duplicate, a forged signature and an unregistered master are
//     refused, and a legacy plain-text (unbound) body is refused with a migration error;
//   * a peer run is forced background and cannot borrow the two interactive slots;
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
/// The target-bound `/node/chat` body: the target node id is inside the signed bytes.
function chatEnvelope(targetNodeId, text, thread) {
  const envelope = { to_node_id: targetNodeId, text };
  if (thread) envelope.thread = thread;
  return JSON.stringify(envelope);
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
/// a marker containing `HOLD` is held so a peer run can be held while local chats run. `/seen` lists
/// every prompt it has been asked to infer, so "refused before inference" is observable.
function startMock() {
  const seen = [];
  const server = http.createServer((req, res) => {
    if (req.method === 'GET') {
      if (req.url === '/seen') { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(seen)); return; }
      res.end('ready'); return;
    }
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      const markers = body.match(/RUN-MARKER-[A-Za-z0-9-]+/g) || [];
      const marker = markers.length ? markers[markers.length - 1] : 'ok';
      seen.push(marker);
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
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port, seen })));
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

async function startDestination(node, service, mockPort) {
  node.port = await freePort();
  node.url = 'http://127.0.0.1:' + node.port;
  node.child = child(node.name, ['serve', '--port', String(node.port), '--client-port', String(node.port + 1), '--ui', path.join(root, 'ui')], {
    ...node.env,
    WASM_AGENT_RENDEZVOUS: service,
    WASM_AGENT_RELAY: service,
    WASM_AGENT_ENDPOINT: '127.0.0.1:' + node.port,
    WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + mockPort,
    WASM_AGENT_LLM_API_KEY: 'test-only',
    WASM_AGENT_LLM_MODEL: 'fixture',
    WASM_AGENT_WORKERS_MAX: '4',
    WASM_AGENT_CONTROL_WORKERS: '1',
  });
  await until(async () => (await request(node.url + '/health')).status === 200, node.name + ' server');
  await until(async () => {
    const nodes = (await request(service + '/nodes', 'GET', undefined, signedHeaders(node, 'nodes'))).value.nodes || [];
    return nodes.some((row) => row.node_id === node.node_id);
  }, node.name + ' registration');
  return node;
}

(async () => {
  mock = await startMock();
  const rendezvousPort = await freePort();
  const service = 'http://127.0.0.1:' + rendezvousPort;

  const peer = fixture('peer');
  const guest = fixture('guest');
  const stranger = fixture('stranger');
  const primary = fixture('primary');
  const primaryB = fixture('primary-b');

  const registry = fixture('registry');
  registry.args = ['rendezvous', '--port', String(rendezvousPort), '--db', path.join(registry.home, 'rendezvous.db')];
  registry.child = child('registry', registry.args, {
    ...registry.env,
    // The two destinations and the peer are the masters; the guest is not, so it is stored as guest.
    WASM_AGENT_NETWORK_ADMINS: [peer.node_id, primary.node_id, primaryB.node_id].join(','),
  });
  await until(async () => (await request(service + '/health')).status === 200, 'local rendezvous');
  check((await register(service, peer, 'master')).status === 200, 'the peer master registers with the local rendezvous');
  check((await register(service, guest, 'master')).status === 200, 'the guest registers');
  const guestLookup = await request(service + '/lookup?node_id=' + guest.node_id, 'GET', undefined, signedHeaders(peer, 'lookup'));
  check(guestLookup.value.role === 'guest', 'a non-admin claiming master is stored as guest, not elevated');

  // Two destination nodes, both real `wa serve` processes with their own homes and keys, both
  // trusting the same peer. This is what makes the redirect test meaningful: A and B are both valid
  // recipients for this peer, so only the signed target can tell them apart.
  await startDestination(primary, service, mock.port);
  await startDestination(primaryB, service, mock.port);
  check(primary.node_id !== primaryB.node_id, 'the two destination nodes have distinct identities');
  const primaryKey = path.join(primary.home, '.wasm-agent', 'node.key');
  const primaryBKey = path.join(primaryB.home, '.wasm-agent', 'node.key');
  check(fs.existsSync(primaryKey) && fs.existsSync(primaryBKey) && fs.readFileSync(primaryKey, 'utf8') !== fs.readFileSync(primaryBKey, 'utf8'), 'each destination node owns a distinct node.key in its own home');

  // ---- direct signed /node/chat -----------------------------------------------------------------
  const directThread = 'peer-direct';
  const directBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-DIRECT', directThread);
  const direct = await request(primary.url + '/node/chat', 'POST', directBody, { ...signedHeaders(peer, 'chat', directBody), accept: 'text/event-stream' });
  check(direct.status === 200 && /RUN-MARKER-PEER-DIRECT/.test(direct.text), 'a signed direct /node/chat runs and answers as the verified peer');
  const operatorStatus = await request(primary.url + '/runs', 'POST', JSON.stringify({ action: 'status', thread: directThread }), { 'content-type': 'application/json' });
  check((operatorStatus.value.runs || []).length === 0, 'the peer conversation is owned by the verified peer, not the local operator');
  await until(async () => runIds((await request(primary.url + '/health')).value).some((row) => row.conversation === directThread), 'the direct run is keyed by its body thread');
  check(true, 'the authenticated body thread is preserved as the conversation key');
  const noThreadBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-NOTHREAD');
  const noThread = await request(primary.url + '/node/chat', 'POST', noThreadBody, { ...signedHeaders(peer, 'chat', noThreadBody), accept: 'text/event-stream' });
  check(noThread.status === 200 && /RUN-MARKER-PEER-NOTHREAD/.test(noThread.text), 'a peer run with no body thread still runs');
  await until(async () => runIds((await request(primary.url + '/health')).value).some((row) => row.conversation === 'peer:' + peer.node_id), 'the no-thread run is keyed by the verified author');
  check(true, 'a body with no thread is keyed by the verified peer node id, not the credential');

  // ---- signature verified once -------------------------------------------------------------------
  const onceThread = 'peer-once';
  const onceBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-ONCE', onceThread);
  const once = await request(primary.url + '/node/chat', 'POST', onceBody, { ...signedHeaders(peer, 'chat', onceBody), accept: 'text/event-stream' });
  check(once.status === 200 && /RUN-MARKER-PEER-ONCE/.test(once.text) && !/replayed_request/.test(once.text), 'a peer run succeeds, so the signature was verified exactly once (no re-verify replay)');

  // ---- duplicate / replayed request refused ------------------------------------------------------
  const replayThread = 'peer-replay';
  const replayBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-REPLAY', replayThread);
  const replayHeaders = signedHeaders(peer, 'chat', replayBody);
  const first = await request(primary.url + '/node/chat', 'POST', replayBody, { ...replayHeaders, accept: 'text/event-stream' });
  const second = await request(primary.url + '/node/chat', 'POST', replayBody, { ...replayHeaders, accept: 'text/event-stream' });
  check(first.status === 200 && /RUN-MARKER-PEER-REPLAY/.test(first.text), 'the first signed request runs');
  check(second.status === 403 && /replayed_request/.test(second.text), 'the identical signed request is refused as a replay');

  // ---- the signed target binds the request -------------------------------------------------------
  // A chat legitimately signed for A, delivered to B. B is a valid recipient for this peer and
  // trusts the same peer, so only the signed target distinguishes them. B must refuse before any
  // conversation, admission or inference.
  const redirectThread = 'peer-redirect';
  const redirectBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-REDIRECT', redirectThread);
  const redirectHeaders = signedHeaders(peer, 'chat', redirectBody);
  const directRedirect = await request(primaryB.url + '/node/chat', 'POST', redirectBody, { ...redirectHeaders, accept: 'text/event-stream' });
  check(directRedirect.status === 400 || directRedirect.status === 403, 'a chat signed for A and sent directly to B is refused by B');
  check(/wrong_target/.test(directRedirect.text), 'B names the target mismatch: wrong_target');
  check(!runIds((await request(primaryB.url + '/health')).value).some((row) => row.conversation === redirectThread), 'the redirected direct chat created no admission on B');
  // The relay may transport the legacy unsigned outer envelope, but the target must reject a
  // redirected EXECUTION: the outer `to` is B while the signed inner target is A.
  const redirectRid = crypto.randomUUID();
  const redirectEnvelope = JSON.stringify({ rid: redirectRid, to: primaryB.node_id, method: 'POST', path: '/node/chat', body: redirectBody, headers: redirectHeaders });
  const relayRedirect = await request(service + '/relay/send', 'POST', redirectEnvelope, signedHeaders(peer, 'relay-send'));
  check(relayRedirect.status === 200 && relayRedirect.value.status === 403 && /wrong_target/.test(relayRedirect.value.body || ''), 'a relay envelope whose outer target is B but whose signed target is A is refused by B');
  check(!runIds((await request(primaryB.url + '/health')).value).some((row) => row.conversation === redirectThread), 'the redirected relay chat created no admission on B');
  await sleep(300);
  check(!mock.seen.includes('RUN-MARKER-PEER-REDIRECT'), 'the redirected chat never reached inference on either node');

  // A modified target, path or body invalidates the signature or the request kind.
  const modifiedTarget = JSON.stringify({ to_node_id: primaryB.node_id, text: 'answer with RUN-MARKER-PEER-MODIFIED', thread: 'peer-modified' });
  const modifiedTargetRun = await request(primaryB.url + '/node/chat', 'POST', modifiedTarget, { ...signedHeaders(peer, 'chat', redirectBody), accept: 'text/event-stream' });
  check(modifiedTargetRun.status === 401 || modifiedTargetRun.status === 403, 'changing the signed target invalidates the signature');
  const modifiedBodyRun = await request(primary.url + '/node/chat', 'POST', redirectBody + 'tampered', { ...redirectHeaders, accept: 'text/event-stream' });
  check(modifiedBodyRun.status === 401 || modifiedBodyRun.status === 403, 'changing the signed body invalidates the signature');
  const pathBody = chatEnvelope(primaryB.node_id, 'answer with RUN-MARKER-PEER-PATH', 'peer-path');
  const pathHeaders = signedHeaders(peer, 'chat', pathBody);
  const wrongPathEnvelope = JSON.stringify({ rid: crypto.randomUUID(), to: primaryB.node_id, method: 'POST', path: '/node/call', body: pathBody, headers: pathHeaders });
  const wrongPath = await request(service + '/relay/send', 'POST', wrongPathEnvelope, signedHeaders(peer, 'relay-send'));
  const wrongPathBody = (wrongPath.value && wrongPath.value.body) || '';
  check(wrongPath.status === 200 && /error/.test(wrongPathBody) && !/RUN-MARKER-PEER-PATH/.test(wrongPathBody), 'a relay envelope whose path is changed to /node/call is refused (the chat body is not a call, and the signature is for chat)');
  await sleep(200);
  check(!mock.seen.includes('RUN-MARKER-PEER-PATH'), 'the path-changed request never reached inference');
  // A legacy plain-text body has no signed target and is refused with a visible migration error.
  const legacyBody = 'answer with RUN-MARKER-PEER-LEGACY';
  const legacy = await request(primary.url + '/node/chat', 'POST', legacyBody, { ...signedHeaders(peer, 'chat', legacyBody), accept: 'text/event-stream' });
  check(legacy.status === 400 && /legacy_peer_protocol/.test(legacy.text), 'a legacy plain-text body is refused with a migration error, not run unbound');
  check(!mock.seen.includes('RUN-MARKER-PEER-LEGACY'), 'the legacy body never reached inference');

  // ---- forged / unregistered / guest -------------------------------------------------------------
  const forgedBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-FORGED', 'peer-forged');
  const tampered = await request(primary.url + '/node/chat', 'POST', forgedBody + 'tampered', { ...signedHeaders(peer, 'chat', forgedBody), accept: 'text/event-stream' });
  check(tampered.status === 401 || tampered.status === 403, 'a body that does not match its signature is refused before admission');
  check(!runIds((await request(primary.url + '/health')).value).some((row) => row.conversation === 'peer-forged'), 'the forged request created no admission');
  const strangerBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-STRANGER', 'peer-stranger');
  const strangerRun = await request(primary.url + '/node/chat', 'POST', strangerBody, { ...signedHeaders(stranger, 'chat', strangerBody), accept: 'text/event-stream' });
  check(strangerRun.status === 403 && /unknown_caller/.test(strangerRun.text), 'an unregistered master is denied before admission');
  const guestBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-GUEST', 'peer-guest');
  const guestRun = await request(primary.url + '/node/chat', 'POST', guestBody, { ...signedHeaders(guest, 'chat', guestBody), accept: 'text/event-stream' });
  check(guestRun.status === 403 && /forbidden_role/.test(guestRun.text), 'a registered guest cannot command a peer');
  const spoofThread = 'operator-session';
  const spoofBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-SPOOF', spoofThread);
  await request(primary.url + '/node/chat', 'POST', spoofBody, { ...signedHeaders(peer, 'chat', spoofBody), accept: 'text/event-stream' });
  const spoofStatus = await request(primary.url + '/runs', 'POST', JSON.stringify({ action: 'status', thread: spoofThread }), { 'content-type': 'application/json' });
  check((spoofStatus.value.runs || []).length === 0, 'a peer run naming another owner\'s thread is not owned by the local operator');

  // ---- peer forced background cannot borrow the two interactive slots ----------------------------
  const holdThread = 'peer-hold';
  const holdBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-HOLD', holdThread);
  const holdRun = request(primary.url + '/node/chat', 'POST', holdBody, { ...signedHeaders(peer, 'chat', holdBody), accept: 'text/event-stream' });
  await until(async () => {
    const health = (await request(primary.url + '/health')).value;
    return runs(health).some((row) => row.conversation === holdThread && row.class === 'background');
  }, 'the peer run is admitted as background');
  const holdHealth = (await request(primary.url + '/health')).value;
  const holdRow = runs(holdHealth).find((row) => row.conversation === holdThread);
  check(holdRow.worker >= 2, 'the peer background run occupies a background worker, not one of the two interactive slots');
  const chatA = request(primary.url + '/chat', 'POST', JSON.stringify({ text: 'answer with RUN-MARKER-A', thread: 'chat-a' }), { 'content-type': 'application/json', accept: 'text/event-stream' });
  const chatB = request(primary.url + '/chat', 'POST', JSON.stringify({ text: 'answer with RUN-MARKER-B', thread: 'chat-b' }), { 'content-type': 'application/json', accept: 'text/event-stream' });
  const [resultA, resultB] = await Promise.all([chatA, chatB]);
  const stillHeld = runs((await request(primary.url + '/health')).value).some((row) => row.conversation === holdThread && row.pending > 0);
  check(/RUN-MARKER-A/.test(resultA.text) && /RUN-MARKER-B/.test(resultB.text), 'two local interactive chats complete while the peer background run is held');
  check(stillHeld, 'both local chats progressed before the peer background run was released');
  check(/RUN-MARKER-PEER-HOLD/.test((await holdRun).text), 'the held peer run completes after release');

  // ---- signed relay /node/chat -------------------------------------------------------------------
  const relayThread = 'peer-relay';
  const relayBody = chatEnvelope(primary.node_id, 'answer with RUN-MARKER-PEER-RELAY', relayThread);
  const rid = crypto.randomUUID();
  const envelope = JSON.stringify({ rid, to: primary.node_id, method: 'POST', path: '/node/chat', body: relayBody, headers: signedHeaders(peer, 'chat', relayBody) });
  const relayAnswer = await request(service + '/relay/send', 'POST', envelope, signedHeaders(peer, 'relay-send'));
  check(relayAnswer.status === 200 && /RUN-MARKER-PEER-RELAY/.test(relayAnswer.value.body || ''), 'a signed relayed /node/chat runs and answers as the verified peer');
  await until(async () => runIds((await request(primary.url + '/health')).value).some((row) => row.conversation === relayThread), 'the relayed run is keyed by its body thread');
  check(true, 'the relayed run shares the same admission and body-thread key as the direct run');

  // The native Lua sender (`nodeslib.remote_chat`) is what a local run uses to reach a peer; it must
  // produce the same target-bound envelope, so the real sender path is covered, not only the raw
  // HTTP the fixture constructs. A targets B by its node id, so the run relays to B's endpoint.
  const viaSenderBody = JSON.stringify({ text: 'answer with RUN-MARKER-PEER-VIA-SENDER', thread: 'peer-via-sender' });
  const viaSender = await request(primary.url + '/chat?node=' + encodeURIComponent(primaryB.node_id), 'POST', viaSenderBody, { 'content-type': 'application/json', accept: 'text/event-stream' });
  check(viaSender.status === 200 && /RUN-MARKER-PEER-VIA-SENDER/.test(viaSender.text), 'the native Lua sender reaches a peer with the target-bound envelope');

  // ---- peer data is not the operator transcript --------------------------------------------------
  // The node that RECEIVED the peer run (B, via the native sender) files it under the peer author,
  // not under its local operator.
  const bSessions = ((await request(primaryB.url + '/sessions', 'GET')).value.sessions || []).map((session) => session.title || '');
  check(!bSessions.some((title) => /RUN-MARKER-PEER-VIA-SENDER/.test(title)), 'the peer run is not in the destination operator\'s session list');
  // The operator's own local chats on A are in A's list; the peer runs A received are not.
  const aSessions = ((await request(primary.url + '/sessions', 'GET')).value.sessions || []).map((session) => session.title || '');
  check(aSessions.some((title) => /RUN-MARKER-A|RUN-MARKER-B/.test(title)), 'the operator\'s own chats are in its session list');
  check(!aSessions.some((title) => /RUN-MARKER-PEER-DIRECT|RUN-MARKER-PEER-ONCE|RUN-MARKER-PEER-HOLD|RUN-MARKER-PEER-RELAY/.test(title)), 'a peer run received by the node is not in its operator session list');

  console.log('peer run admission ok (' + checks + ' checks, 0 skips; two isolated destinations, local rendezvous/relay, local mock model)');
})().catch((error) => {
  console.error(error.stack);
  process.exitCode = 1;
}).finally(async () => {
  await Promise.all(children.map(stop));
  if (mock) await new Promise((resolve) => mock.server.close(resolve));
  if (process.exitCode) console.error('Fixture logs retained at ' + work);
  else fs.rmSync(work, { recursive: true, force: true });
});
