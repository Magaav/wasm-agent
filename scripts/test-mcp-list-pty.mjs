#!/usr/bin/env node
// HOW LONG DOES /mcp TAKE IN A FRESH CHAT? (mission mcp-list-is-fast, 25/11)
//
// MEASURED (the orchestrator, 25/11): /mcp between runs was 16-19 s on a1857d15, because the in-chat path
// refreshed the peer catalogue inside the interpreter before drawing anything. This row drives the REAL
// binary in a real pty (a private tmux server) against a fixture rendezvous that names four ONLINE peers
// whose endpoints are black holes - a socket that accepts and never answers. A path that asks them pays each
// peer's whole deadline; a path that reads the cache cannot pay anything at all.
//
// It prints one line a reader can quote:  mcp list pty: <ms> ms  (and the marker it waited for).
//
// Isolation is scripts/test-chat-start-pty.mjs's: tmux on a private socket (-L), env -i plus an allow-list,
// a scratch HOME outside the real ~/.wasm-agent, and a FAILURE - never a pass - when the list never arrived.
//
// Run: WA_BIN=<wa binary> node scripts/test-mcp-list-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {tmuxSession} from './lib/tmux-session.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp'].find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) { console.error('mcp-list-pty: no scratch root outside ' + REAL_HOME); process.exit(2); }
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-mcp-list-pty-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (HOME.startsWith(REAL_HOME + path.sep)) { console.error('mcp-list-pty: refusing HOME inside ' + REAL_HOME); process.exit(2); }

const t0 = Date.now();
const now = () => Date.now() - t0;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// Four peers that accept and never answer: the catalogue refresh cannot finish while they are asked.
const PEERS = [1, 2, 3, 4];
const blackholes = [];
const peerConnections = {count: 0};
for (const _ of PEERS) {
  const socket = net.createServer(s => { peerConnections.count += 1; s.on('error', () => {}); });
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  blackholes.push(socket);
}
const roster = PEERS.map((n, i) => ({node_id: 'quiet-' + n, name: 'quiet-' + n, public_key: 'test-only',
  online: true, last_seen: Math.floor(Date.now() / 1000),
  endpoints: ['127.0.0.1:' + blackholes[i].address().port]}));

const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const url = String(req.url || '');
    if (url.startsWith('/nodes')) {
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({nodes: roster}));
      return;
    }
    if (url.startsWith('/usage')) {
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({usage: {rolling: {percent: 10, resetsAt: new Date(Date.now() + 3600000).toISOString()}}}));
      return;
    }
    // A provider answer, so the chat itself is usable if a turn is ever typed.
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    for (const chunk of [
      {id: 'x', choices: [{index: 0, delta: {role: 'assistant', content: 'Hello.'}, finish_reason: null}]},
      {id: 'x', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
    ]) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const ENV = {
  PATH: '/usr/bin:/bin',
  HOME,
  TERM: 'xterm-256color',
  LANG: 'C.UTF-8',
  WASM_AGENT_HOME: HOME,
  WASM_AGENT_LUA_ROOT: REPO,
  WASM_AGENT_PROVIDER: 'opencode-go',
  WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + PORT,
  WASM_AGENT_LLM_API_KEY: 'test-only',
  WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE: path.join(WORK, 'no-models-store'),
  WASM_AGENT_RENDEZVOUS: 'http://127.0.0.1:' + PORT,
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  WASM_AGENT_CLI_OPENING: 'off',
  COLUMNS: '100',
  LINES: '30',
};

function finish(code) {
  for (const socket of blackholes) { try { socket.close(); } catch {} }
  try { server.close(); } catch {}
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(code);
}

if (spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status !== 0) {
  console.log('SKIP mcp-list-pty: no tmux on PATH, and this row reads a real pty through it');
  finish(0);
}

const {tmux} = tmuxSession('wa-mcp-list-pty');
const SESSION = 'mcp-list';
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
async function waitFor(predicate, label, timeout) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(50);
  }
}

// The list's own words, whichever version draws it: a version that finds nothing, one that has rows, or the
// line that says where the peer half came from.
const MARKERS = ['no MCP servers', 'connector', 'other nodes:', 'peers not answering'];
const listOn = lines => {
  const row = lines.find(line => MARKERS.some(marker => line.includes(marker)));
  return row || null;
};

let started = false;
try {
  const command = ['env', '-i', ...Object.entries(ENV).map(([k, v]) => k + '=' + v),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat'].join(' ');
  tmux(['kill-server']);
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', '100', '-y', '30', command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;
  await waitFor(() => capture().some(row => row.includes('Type a message')), 'the prompt', 60000);
  await sleep(1500);   // let the idle prompt settle: the measurement is the command, not the start

  const typedAt = now();
  tmux(['send-keys', '-t', SESSION, '/mcp', 'Enter']);
  const marker = await waitFor(() => listOn(capture()), 'the /mcp list', 90000);
  const ms = now() - typedAt;
  console.log('mcp list pty: ' + ms + ' ms (waited for: "' + marker.trim().slice(0, 60) + '")');
  console.log('mcp list pty: peers asked during /mcp = ' + peerConnections.count + ' of ' + PEERS.length);
  console.log('mcp list pty ok (1 measurement)');
  tmux(['send-keys', '-t', SESSION, 'C-c']);
  finish(0);
} catch (error) {
  if (started) {
    console.log('FAIL - ' + error.message);
    console.log('       screen: ' + JSON.stringify(capture().slice(-12)));
  } else {
    console.log('FAIL - ' + error.message);
  }
  try { tmux(['kill-server']); } catch {}
  finish(1);
}
