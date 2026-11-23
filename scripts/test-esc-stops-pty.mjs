#!/usr/bin/env node
// ESC ENDS A RUN AT ONCE (change/esc-stops-now, 23/11).
//
// Victor: "stopping the mid flight run took a significant amount of time, i think we are able to ... get
// it instantaneous". This drives the REAL binary in a real pty (a PRIVATE tmux server) against a fixture
// that is both the rendezvous and the provider, presses Esc in the middle of each way a run can wait, and
// measures Esc-to-prompt for every one of them:
//
//   headers  - the provider accepted the request and sent no response headers at all (30 s hold)
//   stream   - one content chunk arrived, then ten seconds of silence mid-stream
//   bash     - a local shell call (sleep 30) is running
//   remote   - tools.remote to a peer endpoint that accepts and never answers
//   subagent - a supervised child whose own provider call is held
//
// It also reads back what the ledger and the screen must say about it: an input|interrupt row stamped
// with the host's clock for the keypress, no provider_retry for a cancellation, and the text that had
// already streamed kept on screen.
//
// Run: node scripts/test-chat-start-pty.mjs style - WA_BIN=<wa binary> node scripts/test-esc-stops-pty.mjs
//      add --measure to print the table and judge nothing (the baseline run on the code before the fix).
//
// Isolation is scripts/test-chat-start-pty.mjs's: tmux on a private socket (-L), env -i plus an
// allow-list, a scratch HOME that REFUSES to be the real ~/.wasm-agent, and a FAILURE (never a pass)
// when the fixture served nothing.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
const MEASURE_ONLY = process.argv.includes('--measure');
// What "instantaneous" means here, on the measure the brief names. The reader publishes its flag after
// its 120 ms lone-Esc lookahead, so a correct implementation lands well inside this.
const LIMIT_MS = 300;
const GIVE_UP_MS = 20000;

const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('esc-stops: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-esc-stops-'));
function scratchHome(name) {
  const home = path.join(WORK, name, 'home');
  fs.mkdirSync(home, {recursive: true});
  if (path.resolve(home) === path.resolve(REAL_HOME) || home.startsWith(REAL_HOME + path.sep)) {
    console.error('esc-stops: refusing to run with HOME inside the real ' + REAL_HOME);
    process.exit(2);
  }
  return home;
}

let checks = 0;
let failed = 0;
function check(name, condition, detail) {
  checks += 1;
  if (condition) { console.log('ok - ' + name); return true; }
  failed += 1;
  console.log('FAIL - ' + name + (detail ? '\n       ' + String(detail).split('\n').join('\n       ') : ''));
  return false;
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// ---- the fixture: one port that is the rendezvous AND the provider --------------------------------
//
// One black hole too: a socket that accepts the connection and then never says a byte. The peer in the
// roster below points at it, so a tools.remote call really blocks on a peer that owes an answer.
let peerConnections = 0;
const blackhole = net.createServer(socket => { peerConnections += 1; socket.on('error', () => {}); });
await new Promise(resolve => blackhole.listen(0, '127.0.0.1', resolve));
const PEER_PORT = blackhole.address().port;

// What the current scenario is, and what the fixture has seen: one scenario at a time, so a stale
// request cannot make the next scenario look ready.
const state = {
  scenario: '', requests: [], chunkSentAt: null, held: [], heldMs: 0,
};
function resetScenario(name, opts) {
  state.scenario = name;
  state.peerHeld = 0;
  state.opts = opts || {};
  state.requests = [];
  state.chunkSentAt = null;
  state.held = [];
  state.heldMs = state.opts.holdMs || 30000;
  peerConnections = 0;
}
const completions = () => state.requests.filter(entry => !entry.child);
const childRequests = () => state.requests.filter(entry => entry.child);
const peerCalls = () => state.requests.filter(entry => entry.path === '/node/call');

function sse(res, chunk) { res.write('data: ' + JSON.stringify(chunk) + '\n\n'); }
function answerChunk(text, finish) {
  return {id: 'esc-1', choices: [{index: 0, delta: finish ? {role: 'assistant'} : {role: 'assistant', content: text},
    finish_reason: finish || null}]};
}
function toolCallChunk(name, args) {
  return {id: 'esc-1', choices: [{index: 0, delta: {role: 'assistant', tool_calls: [{index: 0, id: 'call_1',
    type: 'function', function: {name: name, arguments: JSON.stringify(args)}}]}, finish_reason: null}]};
}
// The tool result of the previous round, as the model would read it back: the child's task id is in
// there, which is how this fixture can ask for a wait on the very child it just started.
function toolResultText(body) {
  try {
    const parsed = JSON.parse(body);
    const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
    for (let i = messages.length - 1; i >= 0; i -= 1) {
      const message = messages[i];
      if (message && message.role === 'tool') return String(message.content || '');
    }
  } catch (error) { /* not a shape this fixture knows: the scenario then has no id and says so */ }
  return '';
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', piece => chunks.push(piece));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const url = String(req.url || '');
    const entry = {path: url, at: Date.now(), method: req.method, body};
    if (process.env.ESC_DEBUG) console.log('arrival +' + (Date.now() - (state.typedAt || Date.now())) + 'ms ' + req.method + ' ' + url
      + (url.includes('completions') ? ' tools=[' + ['remote', 'subagent', 'bash'].filter(n => body.includes('"name":"' + n + '"')).join(',') + ']' : ''));
    if (url === '/nodes') {
      // ONE scenario needs a peer in the roster and every other one must not have any: a peer whose
      // capabilities cannot be read makes the idle prefetch and the turn's own view snapshot wait for
      // it (measured here first: the run never reached the provider), which is a fixture artefact and
      // not the wait this file measures.
      const nodes = state.scenario === 'remote'
        ? [{node_id: 'deadbeefdeadbeef', name: 'ghost', public_key: 'test-only', online: true,
            last_seen: Math.floor(Date.now() / 1000), endpoints: ['127.0.0.1:' + PORT]}]
        : [];
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({nodes}));
      return;
    }
    if (url.startsWith('/node/call')) {
      // The peer that owes an answer. ONLY the read this scenario's tool asks for is held: the CLI also
      // asks a peer for its capabilities through the same route while it prefetches its views, and
      // holding THAT one deadlocks the run before its first model call (measured here first: no
      // completions request ever arrived, and the row said it was waiting for the model).
      state.requests.push({path: '/node/call', at: Date.now(), method: req.method, body});
      if (body.includes('/etc/hostname')) { state.peerHeld += 1; state.held.push(res); return; }
      res.writeHead(200, {'content-type': 'application/json'});
      res.end('{}');
      return;
    }
    if (url.startsWith('/node/')) {
      // Any other peer capability (the roster's capability probe): answered at once, and unsigned, so
      // the caller records why it could not verify it instead of waiting for a peer that is busy.
      res.writeHead(200, {'content-type': 'application/json'});
      res.end('{}');
      return;
    }
    if (url.startsWith('/lookup')) { res.writeHead(404, {'content-type': 'application/json'}); res.end('{"error":"not_found"}'); return; }
    if (url.startsWith('/usage') || url.startsWith('/models') || url.startsWith('/health')) {
      res.writeHead(200, {'content-type': 'application/json'}); res.end('{}'); return;
    }
    entry.child = body.includes('Investigate the task read-only');
    state.requests.push(entry);
    const opts = state.opts;
    if (entry.path === '/node/call') {
      // The peer that owes an answer: held, and this node's own call to it is what Esc must end.
      return;
    }
    if (entry.child) {
      // A supervised child's provider call: silent, so the parent is waiting on the child.
      return;
    }
    const round = completions().length;
    if (opts.reply === 'bash-tool') {
      if (round > 1) return; // the request AFTER the shell: held, and never reached in a passing run
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      sse(res, toolCallChunk('bash', {command: 'sleep 30'}));
      sse(res, {id: 'esc-1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]});
      res.write('data: [DONE]\n\n');
      res.end();
      return;
    }
    if (opts.reply === 'remote-tool') {
      // `remote` is an OUTER FACADE: it is not in the declared tool list at all (measured here: the
      // request declared bash only), and a facade is reached by pinning it with tool_search first - the
      // same path a model takes (docs/TOOL-SURFACE.md). Round 3 is where the run is blocked on the peer,
      // so it is held; a passing run never gets there.
      if (round > 2) return;
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      if (round === 1) {
        sse(res, toolCallChunk('tool_search', {names: ['remote']}));
      } else {
        sse(res, toolCallChunk('remote', {node: 'ghost', capability: 'read', path: '/etc/hostname'}));
      }
      sse(res, {id: 'esc-1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]});
      res.write('data: [DONE]\n\n');
      res.end();
      return;
    }
    if (opts.reply === 'subagent-start') {
      // `subagent` is an outer facade too: pinned by tool_search first, exactly as a model reaches it.
      // Round 3 is the await on the child - the wait under test - so round 4 is never served.
      if (round > 3) return;
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      if (round === 1) {
        sse(res, toolCallChunk('tool_search', {names: ['subagent']}));
      } else if (round === 2) {
        sse(res, toolCallChunk('subagent', {action: 'start', title: 'slow child', prompt: 'count very slowly'}));
      } else {
        const id = (toolResultText(body).match(/"(?:id|attempt_id|task_id)":\s*"([^"]+)"/) || [])[1] || '';
        if (!id) { state.requests.push({path: 'no-child-id', at: Date.now(), body: toolResultText(body)}); }
        sse(res, toolCallChunk('subagent', {action: 'await', id: id, wait_ms: 30000}));
      }
      sse(res, {id: 'esc-1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]});
      res.write('data: [DONE]\n\n');
      res.end();
      return;
    }
    if (opts.reply === 'stream-then-silence') {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      sse(res, answerChunk('the first words ', false));
      state.chunkSentAt = Date.now();
      // Ten seconds of a provider that is thinking - and then, if nobody stopped it, an answer.
      const hold = setTimeout(() => {
        sse(res, answerChunk('and the rest.', 'stop'));
        res.write('data: [DONE]\n\n');
        res.end();
      }, 10000);
      res.on('close', () => clearTimeout(hold));
      return;
    }
    // 'silent': the provider took the request and says nothing at all - not even response headers.
    state.held.push(res);
    if (state.heldMs > 0) setTimeout(() => {
      if (res.writableEnded || res.destroyed) return;
      res.writeHead(504, {'content-type': 'application/json'}); res.end('{"error":"test held nothing back long enough"}');
    }, state.heldMs);
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

// ---- the pty: a PRIVATE tmux server, the real binary, and the screen read back ---------------------
const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-esc-stops-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close(); blackhole.close(); fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}
const SOCKET = 'wa-esc-stops-' + process.pid;
const SESSION = 'esc';
const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], {encoding: 'utf8'});
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const INTERRUPTED = 'Interrupted by user';
function screen() { return capture().filter(row => row !== ''); }
async function waitFor(predicate, label, timeout) {
  const deadline = Date.now() + (timeout || 30000);
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(40);
  }
}

function environment(home) {
  return {
    PATH: '/usr/bin:/bin',
    HOME: home,
    TERM: 'xterm-256color',
    LANG: 'C.UTF-8',
    WASM_AGENT_HOME: home,
    WASM_AGENT_LUA_ROOT: REPO,
    WASM_AGENT_PROVIDER: 'opencode-go',
    WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + PORT,
    WASM_AGENT_LLM_API_KEY: 'test-only',
    WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
    WASM_AGENT_PI_MODELS_STORE: path.join(home, '..', 'no-models-store'),
    WASM_AGENT_RENDEZVOUS: 'http://127.0.0.1:' + PORT,
    WASM_AGENT_RELAY: '',
    WASM_AGENT_MANAGED: '0',
    WA_SKIP_UPDATE_CHECK: '1',
    WASM_AGENT_CLI_OPENING: 'off',
    COLUMNS: '100',
    LINES: '30',
  };
}

// One scenario: a fresh chat against the fixture, its own scratch home and ledger, one Esc.
//
// The measurement is the reader's own: the moment tmux hands the Esc byte to the pty is the moment the
// key was pressed, and the moment 'Interrupted by user' is on screen is the moment the run ended and the
// prompt came back. Both are read back from outside the process, so no number here is the code's claim
// about itself.
async function scenario(entry) {
  const name = entry.name;
  resetScenario(name, entry.opts);
  const home = scratchHome(name);
  const env = environment(home);
  const ledger = path.join(home, '..', 'ledger.db');
  tmux(['kill-server']);
  const command = ['env', '-i', ...Object.entries(env).map(([key, value]) => key + '=' + value),
    BIN, '--db', ledger, 'chat'].join(' ');
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', '100', '-y', '30', command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  await waitFor(() => screen().some(row => row.includes('Type a message')), 'the prompt', 30000);
  // A scenario that needs a PEER in the session's tool list has to let the idle roster read land
  // before the first Enter: the first request of a session freezes the declared tool list
  // (docs/PROMPT-CACHE.md), so a peer discovered after that freeze can never be called in this
  // session - measured here: "remote" was absent from the frozen envelope, the call was dropped and
  // the turn ended as an empty reply. Display-free waiting, and the assertions below prove it worked.
  if (entry.opts.promptWaitMs) await sleep(entry.opts.promptWaitMs);
  const typedAt = Date.now();
  state.typedAt = typedAt;
  tmux(['send-keys', '-t', SESSION, entry.opts.line || 'hi', 'Enter']);
  try {
    await waitFor(() => entry.ready(), 'the ' + name + ' wait to be in flight', 30000);
    if (process.env.ESC_DEBUG) console.log('ready +' + (Date.now() - typedAt) + 'ms');
  } catch (error) {
    const rows = screen();
    tmux(['kill-server']);
    return {name, escMs: null, why: error.message, rows, requests: state.requests.length, typedAt,
      ledger, home, requestsSeen: state.requests.map(entry => entry.path)};
  }
  await sleep(Number(process.env.ESC_SETTLE_MS || entry.opts.settleMs || 250));
  if (process.env.ESC_DEBUG) console.log('screen at Esc:\n' + screen().join('\n'));
  const escAt = Date.now();
  tmux(['send-keys', '-t', SESSION, 'Escape']);
  let backAt = null;
  const deadline = Date.now() + GIVE_UP_MS;
  while (Date.now() < deadline) {
    if (screen().some(row => row.includes(INTERRUPTED))) { backAt = Date.now(); break; }
    await sleep(20);
  }
  const rows = screen();
  tmux(['kill-server']);
  if (process.env.ESC_BODIES) {
    // The probe the display-only rule needs: the request bodies exactly as the provider received them,
    // so two binaries can be compared byte for byte (ESC_BODIES=/tmp/bodies.json).
    fs.writeFileSync(process.env.ESC_BODIES + '.' + name,
      JSON.stringify(state.requests.filter(entry => entry.path.endsWith('/chat/completions')).map(entry => entry.body), null, 1));
  }
  return {name, escMs: backAt === null ? null : backAt - escAt, escAt, rows, ledger, home,
    requests: state.requests.length, typedAt,
    requestsSeen: state.requests.map(entry => entry.path),
    // The provider requests themselves, for the display-only probe below.
    bodies: state.requests.filter(entry => entry.path.endsWith('/chat/completions')).map(entry => entry.body)};
}

// The ledger, read by a second process: what the run itself recorded about the stop.
function ledgerRows(ledger, statement) {
  const read = spawnSync('sqlite3', ['-json', ledger, statement], {encoding: 'utf8'});
  if (read.status !== 0) return null;
  const text = String(read.stdout || '').trim();
  // No rows is an empty answer from sqlite3, not an unreadable one: an unreadable ledger exits
  // non-zero, which is the branch above.
  if (text === '') return [];
  try { return JSON.parse(text); } catch { return null; }
}

const providerCalls = () => state.requests.filter(entry => entry.path.endsWith('/chat/completions') && !entry.child);

const SCENARIOS = [
  {name: 'headers', opts: {holdMs: 30000},
   what: 'Esc before the provider sent any response header (30 s hold)',
   ready: () => providerCalls().length >= 1},
  {name: 'stream', opts: {reply: 'stream-then-silence'},
   what: 'Esc in a 10 s silence after one streamed chunk',
   ready: () => state.chunkSentAt !== null},
  {name: 'bash', opts: {reply: 'bash-tool'},
   what: 'Esc while a local shell call (sleep 30) is running',
   ready: () => screen().some(row => row.includes('sleep 30'))},
  {name: 'remote', opts: {reply: 'remote-tool', promptWaitMs: 3500},
   what: 'Esc while tools.remote waits on a peer that never answers',
   ready: () => state.peerHeld > 0},
  {name: 'subagent', opts: {reply: 'subagent-start'},
   what: 'Esc while the run waits on a supervised child (its own provider call held)',
   ready: () => childRequests().length >= 1 && providerCalls().length >= 3},
];

const ONLY = String(process.env.ESC_ONLY || '').split(',').filter(Boolean);
const RUN = ONLY.length > 0 ? SCENARIOS.filter(entry => ONLY.includes(entry.name)) : SCENARIOS;

const results = [];
let crash = null;
try {
  for (const entry of RUN) {
    console.log('# ' + entry.name + ': ' + entry.what);
    const result = await scenario(entry);
    results.push(result);
    if (result.escMs === null) {
      console.log('     no return to the prompt within ' + (GIVE_UP_MS / 1000) + ' s');
    } else {
      console.log('     Esc -> prompt in ' + result.escMs + ' ms');
    }
  }
} catch (error) {
  crash = error;
} finally {
  tmux(['kill-server']);
}

console.log('');
console.log('scenario   Esc to prompt');
for (const result of results) {
  console.log('  ' + result.name.padEnd(9) + ' ' + (result.escMs === null ? 'never (gave up at ' + (GIVE_UP_MS / 1000) + ' s)' : result.escMs + ' ms'));
}
console.log('');

if (crash) {
  failed += 1;
  console.error('esc-stops: FAILED - ' + crash.message);
} else if (results.length !== RUN.length) {
  failed += 1;
  console.error('esc-stops: FAILED - only ' + results.length + ' of ' + RUN.length + ' scenarios ran');
} else {
  for (const result of results) {
    const detail = result.escMs === null
      ? (result.why ? result.why + '\n' : '') + 'the screen after the give-up:\n' + result.rows.join('\n')
        + '\nprovider requests: ' + JSON.stringify(result.requestsSeen)
      : result.escMs + ' ms (limit ' + LIMIT_MS + ' ms)';
    check(result.name + ': Esc brings the prompt back in under ' + LIMIT_MS + ' ms', result.escMs !== null && result.escMs <= LIMIT_MS, detail);
  }
  // ---- display only: the row's words never reach the provider --------------------------------
  // The status row now names the wait and the key that ends it (item 5). Nothing of that may travel:
  // the request is built from the conversation and the frozen prefix, never from the row, and this is
  // the check that says so with the real request bodies the fixture received.
  const leaked = [];
  for (const result of results) {
    for (const marker of ['waiting for the model', 'esc to stop', 'Interrupting', 'the first reply is slower']) {
      if ((result.bodies || []).some(body => String(body).includes(marker))) leaked.push(result.name + ': ' + marker);
    }
  }
  check('the status row is display only: none of its words is in any provider request',
    leaked.length === 0, 'found in a request body: ' + JSON.stringify(leaked));

  const stream = results.find(result => result.name === 'stream');
  if (stream) {
    check('stream: the text that had already streamed is kept on screen (a stop is not a loss)',
      stream.rows.some(row => row.includes('the first words')), stream.rows.join('\n'));
  }

  // ---- the ledger, read by a second process ------------------------------------------------
  // Item 3: the keypress is its own row, so the next measurement of a stop starts from the key.
  for (const result of results) {
    const rows = ledgerRows(result.ledger,
      "SELECT kind, phase, at FROM harness_events WHERE kind = 'input' ORDER BY seq DESC LIMIT 10");
    const interrupt = Array.isArray(rows) ? rows.find(row => row.phase === 'interrupt') : null;
    check(result.name + ': the ledger records the interrupt as its own input row, stamped with its time',
      Boolean(interrupt) && Number.isFinite(Number(interrupt.at))
        && Math.abs(Number(interrupt.at) - result.escAt / 1000) <= 3,
      rows === null ? 'the ledger could not be read: ' + result.ledger : 'input rows: ' + JSON.stringify(rows));
  }
  // Item 4: a stop is not a failure, so it must not be replayed as one.
  for (const result of results) {
    const rows = ledgerRows(result.ledger,
      "SELECT kind, phase, payload FROM harness_events WHERE kind = 'provider_retry'");
    // A STOP IS NOT A FAILURE, so the replay loop must not have run at all: on the code before this
    // change a cancelled call wrote "provider_retry attempt 1 ... wait_ms 1151" and waited it out.
    check(result.name + ': a cancellation is never logged as a provider retry',
      Array.isArray(rows) && rows.length === 0,
      rows === null ? 'the ledger could not be read: ' + result.ledger : 'provider_retry rows: ' + JSON.stringify(rows));
  }
}

server.close();
blackhole.close();
if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
else console.error('esc-stops: scratch kept for diagnosis: ' + WORK);

console.log('esc-stops pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
