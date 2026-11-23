#!/usr/bin/env node
// /UNDO IN A CHAT PUTS A PEER'S FILE BACK, ON THE PEER (mission remote-undo-works, 23/11).
//
// The promise this mission measured: `lua/core/tools.lua` tells the model "an edit there is the edit you
// know here ... the change is recorded here, so /undo restores that file there". The window's /diff route
// could do it; a chat could not - there was no /undo. This drives the REAL binary in a real pty (a private
// tmux server) as the CALLER, with a REAL scratch peer on this machine: a second `wa serve` with its own
// HOME, a private rendezvous, both nodes registered there, and every call signed and relayed over
// loopback. Nothing of the operator's fleet is touched or reachable (no rendezvous but this one, no relay
// but the one in this temp dir, WASM_AGENT_MANAGED=0).
//
// What it pins:
//   * the model reads a page on the peer and edits one line of it there (a real capability call, admitted
//     by the peer's own rules);
//   * `/undo` answers with the file, the NODE it restored it on and the VERSION it now holds, and the file
//     is byte-for-byte what it was before the edit;
//   * the restore CROSSED THE WIRE: the peer's own log gains a /node/call for it. On one machine a local
//     write of the same path would leave the same bytes, so the bytes alone prove nothing - the peer's
//     record of receiving the call is what tells the two apart;
//   * /undo never reaches the model (the fixture counts its requests).
//
// Isolation: `env -i` plus an allow-list, scratch HOMEs that REFUSE to be the real ~/.wasm-agent, fresh
// ports never 8799/8800/8890, and only children this script started are killed, by pid.
//
// Run: WA_BIN=<wa binary> node scripts/test-undo-remote-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
function resolvedBin(name) {
  if (name.includes('/')) return path.resolve(name);
  const found = spawnSync('sh', ['-c', 'command -v ' + name], {encoding: 'utf8'});
  const line = String(found.stdout || '').trim().split('\n')[0];
  return line || name;
}
const BIN = resolvedBin(process.env.WA_BIN || process.env.FAST_BIN || 'wa');

const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('undo-remote-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
// THE ANSWER ROW HAS TO FIT ON THE SCREEN. The chat CLIPS a row to the terminal width, and the check
// that the restored version is named reads ONE row: a longer scratch path (fast.sh's TMPDIR is
// ~/.wa-scratch/wa-fast-XXXX/tmp, some thirty characters deeper than /tmp) pushed "version <hex>" off
// the clipped row, and both /undo rows failed in every fast.sh run while passing by hand. So: 200
// columns, not 110, and the shortest scratch name this root allows. Nothing the rows check is loosened -
// the same version, on the same row, with room to be read.
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wur-'));
const HOMES = {caller: path.join(WORK, 'caller'), peer: path.join(WORK, 'peer'), registry: path.join(WORK, 'registry')};
for (const [name, dir] of Object.entries(HOMES)) {
  if (path.resolve(dir) === path.resolve(REAL_HOME) || dir.startsWith(REAL_HOME + path.sep)) {
    console.error('undo-remote-pty: refusing a HOME inside the real ' + REAL_HOME + ' (' + name + ')');
    process.exit(2);
  }
  fs.mkdirSync(path.join(dir, '.wasm-agent'), {recursive: true});
  // The name the roster knows a node by. `wa serve` re-registers itself under this, so it is set before
  // anything starts (measured: a serve started in /tmp registered itself as 'tmp').
  fs.writeFileSync(path.join(dir, '.wasm-agent', 'node.name'), name);
}
const PEER_NAME = 'peer';
const TARGET = path.join(WORK, 'data', 'demo.txt');
fs.mkdirSync(path.dirname(TARGET), {recursive: true});
const V1 = 'alpha\nbeta\ngamma\n';
const V2 = 'alpha\nBETA\ngamma\n';
fs.writeFileSync(TARGET, V1);

const BASE = {PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', TERM: 'xterm-256color', WA_SKIP_UPDATE_CHECK: '1',
  WASM_AGENT_MANAGED: '0', WASM_AGENT_LUA_ROOT: REPO};
const envFor = dir => ({...BASE, HOME: dir, WASM_AGENT_HOME: dir});

let checks = 0;
let failed = 0;
function check(name, condition, detail = '') {
  checks += 1;
  if (condition) { console.log('ok - ' + name); return true; }
  failed += 1;
  console.log('FAIL - ' + name + (detail ? '\n       ' + String(detail).split('\n').join('\n       ') : ''));
  return false;
}
const sha = text => crypto.createHash('sha256').update(text, 'utf8').digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const children = [];

async function freePort() {
  const s = net.createServer();
  await new Promise(r => s.listen(0, '127.0.0.1', r));
  const p = s.address().port;
  await new Promise(r => s.close(r));
  return p === 8799 || p === 8800 || p === 8890 ? freePort() : p;
}
async function waitHealth(url, tries = 200) {
  for (let i = 0; i < tries; i++) {
    try { if ((await fetch(url, {signal: AbortSignal.timeout(1500)})).status === 200) return true; } catch {}
    await sleep(100);
  }
  return false;
}
function startNode(dir, args, log, extra = {}) {
  const fd = fs.openSync(path.join(WORK, log), 'a');
  const child = spawn(BIN, args, {env: {...envFor(dir), ...extra}, cwd: dir, stdio: ['ignore', fd, fd]});
  fs.closeSync(fd);
  children.push(child);
  return child;
}

// ---- the model fixture: read the page, then edit one line, on the peer --------------------------
const requests = [];
const server = http.createServer((req, res) => {
  const body = [];
  req.on('data', chunk => body.push(chunk));
  req.on('end', () => {
    let messages = [];
    try { messages = JSON.parse(Buffer.concat(body).toString('utf8')).messages || []; } catch {}
    const last = String((messages[messages.length - 1] || {}).role || '');
    const toolResults = messages.filter(message => message.role === 'tool').length;
    requests.push({last, toolResults});
    const chunks = [];
    if (last === 'tool' && toolResults < 2) {
      // The read came back: now the edit, through the same remote capability.
      chunks.push({id: 'r2', choices: [{index: 0, delta: {role: 'assistant', content: null,
        tool_calls: [{index: 0, id: 'call_edit', type: 'function', function: {name: 'remote', arguments: ''}}]}}]});
      chunks.push({id: 'r2', choices: [{index: 0, delta: {tool_calls: [{index: 0, function: {arguments: JSON.stringify({
        node: PEER_NAME, capability: 'edit', path: TARGET,
        edits: [{old_text: 'beta', new_text: 'BETA'}],
      })}}]}}]});
      chunks.push({id: 'r2', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]});
    } else if (last === 'tool') {
      chunks.push({id: 'r3', choices: [{index: 0, delta: {role: 'assistant', content: 'edited the second line there'}}]});
      chunks.push({id: 'r3', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]});
    } else {
      chunks.push({id: 'r1', choices: [{index: 0, delta: {role: 'assistant', content: null,
        tool_calls: [{index: 0, id: 'call_read', type: 'function', function: {name: 'remote', arguments: ''}}]}}]});
      chunks.push({id: 'r1', choices: [{index: 0, delta: {tool_calls: [{index: 0, function: {arguments: JSON.stringify({
        node: PEER_NAME, capability: 'read', path: TARGET, offset: 1, limit: 10,
      })}}]}}]});
      chunks.push({id: 'r1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]});
    }
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    for (const chunk of chunks) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const MODEL_PORT = server.address().port;

const SOCKET = 'wa-undo-remote-' + process.pid;
const SESSION = 'undo-remote';
const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], {encoding: 'utf8'});
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const screen = () => capture().join('\n');
async function waitFor(predicate, label, timeout = 90000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(100);
  }
}
const peerCalls = () => {
  const log = path.join(WORK, 'peer.log');
  if (!fs.existsSync(log)) return 0;
  return (fs.readFileSync(log, 'utf8').match(/\[relay\] dispatch .*POST \/node\/call/g) || []).length;
};
const fileText = () => (fs.existsSync(TARGET) ? fs.readFileSync(TARGET, 'utf8') : null);

let started = false;
let service = '';
try {
  const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
  if (!HAVE_TMUX) {
    console.log('SKIP test-undo-remote-pty: no tmux on PATH, and this test reads a real pty through it');
    server.close();
    fs.rmSync(WORK, {recursive: true, force: true});
    process.exit(0);
  }

  // ---- the private network: this temp dir's rendezvous, and two scratch nodes on it -------------
  const identity = name => JSON.parse(String(spawnSync(BIN, ['node'], {env: envFor(HOMES[name]), cwd: HOMES[name],
    encoding: 'utf8', timeout: 60000}).stdout || '{}'));
  const callerId = identity('caller'), peerId = identity('peer'), registryId = identity('registry');
  check('two scratch nodes have their own identities, apart from the operator\'s',
    Boolean(callerId.node_id) && Boolean(peerId.node_id) && callerId.node_id !== peerId.node_id);

  const registryPort = await freePort();
  const peerPort = await freePort();
  const peerClientPort = await freePort();
  service = 'http://127.0.0.1:' + registryPort;
  // The two scratch nodes are the ONLY ones this rendezvous admits as master: without this list every
  // node registers as a guest and no peer may command another (`forbidden_role`), which is the refusal
  // the first run of this file measured.
  startNode(HOMES.registry, ['rendezvous', '--port', String(registryPort)], 'registry.log',
    {WASM_AGENT_NETWORK_ADMINS: callerId.node_id + ',' + peerId.node_id});
  if (!await waitHealth(service + '/health')) throw new Error('the private rendezvous did not start: '
    + String(fs.readFileSync(path.join(WORK, 'registry.log'), 'utf8')).slice(-500));
  check('a private rendezvous is up on loopback (no fleet rendezvous is configured)', true);

  const netEnv = {...BASE, WASM_AGENT_RENDEZVOUS: service, WASM_AGENT_RELAY: service};
  async function register(dir, id, name, endpoints) {
    const ts = Math.floor(Date.now() / 1000);
    const message = 'v2|' + id.node_id + '|' + ts + '|' + name + '|' + JSON.stringify(endpoints);
    const signature = String(spawnSync(BIN, ['node', 'sign', message], {env: {...envFor(dir), ...netEnv}, cwd: dir,
      encoding: 'utf8', timeout: 60000}).stdout || '').trim();
    const answer = await fetch(service + '/register', {method: 'POST', headers: {'content-type': 'application/json'},
      body: JSON.stringify({node_id: id.node_id, public_key: id.public_key, name, endpoints, ts, signature})});
    return answer.status;
  }
  check('the caller registers on the private rendezvous (a peer verifies its calls by it)',
    await register(HOMES.caller, callerId, 'caller', []) === 200);
  // No endpoint: every call reaches the peer through the relay in this temp dir, which is what makes the
  // restore observable. The peer's own log names each call it dispatches, and on ONE machine the file
  // cannot tell a local write from a remote one - both processes share the filesystem and the uid, so
  // both would leave the same bytes. The call the peer ran is the evidence; the bytes are not.
  check('the scratch peer registers on the private rendezvous',
    await register(HOMES.peer, peerId, PEER_NAME, []) === 200);

  // netEnv, not only its own HOME: the peer has to know the rendezvous and the relay, or it never polls
  // the relay and every call to it answers `node_not_attached` (measured on the first run of this file).
  startNode(HOMES.peer, ['serve', '--port', String(peerPort), '--client-port', String(peerClientPort),
    '--ui', path.join(REPO, 'ui')], 'peer.log', netEnv);
  if (!await waitHealth('http://127.0.0.1:' + peerPort + '/health')) throw new Error('the scratch peer did not start');
  check('a second wasm-agent node is serving on this machine, from its own HOME', true);

  // ---- the caller in a real pty -----------------------------------------------------------------
  const ENV = {
    ...BASE, ...netEnv,
    HOME: HOMES.caller,
    WASM_AGENT_HOME: HOMES.caller,
    WASM_AGENT_PROVIDER: 'opencode-go',
    WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + MODEL_PORT,
    WASM_AGENT_LLM_API_KEY: 'test-only',
    WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
    WASM_AGENT_PI_MODELS_STORE: path.join(WORK, 'no-models-store'),
    WASM_AGENT_PROVIDER_RETRIES: '0',
    WASM_AGENT_CLI_OPENING: 'off',
    COLUMNS: '200',
    LINES: '34',
  };
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(HOMES.caller, 'ledger.db'), 'chat'].join(' ');
  tmux(['kill-server']);
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', '200', '-y', '34', '-c', WORK, command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  const before = peerCalls();
  tmux(['send-keys', '-t', SESSION, 'on the peer, change the second line of the demo file', 'Enter']);
  await waitFor(() => fileText() === V2 && screen().includes('edited the second line there'),
    'the remote edit to land');
  check('the model read a page on the peer and edited the second line there', fileText() === V2,
    JSON.stringify(fileText()));
  check('the peer received those calls itself (its log names each /node/call)', peerCalls() > before,
    'peer calls before ' + before + ', after ' + peerCalls());

  const callsAfterEdit = peerCalls();
  check('the peer dispatched the read and the edit itself (its log names each call it ran)',
    callsAfterEdit >= 2, 'peer dispatches ' + callsAfterEdit);

  const requestsBeforeUndo = requests.length;
  tmux(['send-keys', '-t', SESSION, '/undo', 'Enter']);
  const answer = await waitFor(() => capture().find(row => row.includes('undo:')), 'the undo answer');
  check('the chat answers /undo', /undo:/.test(answer), answer);
  check('it names the peer as the machine it restored on', answer.includes('on ' + PEER_NAME), answer);
  check('it names the version the peer now holds (the recorded text\'s own sha256)',
    answer.includes('version ' + sha(V1).slice(0, 12)), 'wanted ' + sha(V1).slice(0, 12) + ' in: ' + answer);
  check('the file is byte-for-byte what the peer held before the edit', fileText() === V1, JSON.stringify(fileText()));
  check('the restore went to the peer as a call, not as a local write', peerCalls() > callsAfterEdit,
    'peer dispatches ' + callsAfterEdit + ' -> ' + peerCalls() + ' (the undo asks for the digest, then writes)');
  check('/undo never reached the model', requests.length === requestsBeforeUndo,
    'requests ' + requestsBeforeUndo + ' -> ' + requests.length);
} catch (error) {
  failed += 1;
  console.error('undo-remote-pty: FAILED - ' + error.message);
  try { console.error(screen().split('\n').filter(row => row !== '').join('\n')); } catch {}
  try {
    for (const log of ['peer.log', 'registry.log']) {
      const file = path.join(WORK, log);
      if (fs.existsSync(file)) console.error('--- ' + log + '\n' + fs.readFileSync(file, 'utf8').slice(-1200));
    }
  } catch {}
} finally {
  if (started) tmux(['kill-server']);
  for (const child of children.reverse()) {
    try { child.kill(); } catch {}
  }
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('undo-remote-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('undo remote pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
