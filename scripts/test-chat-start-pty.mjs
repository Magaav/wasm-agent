#!/usr/bin/env node
// THE TURN'S ROW IS ON SCREEN IN UNDER A SECOND OF THE READER'S ENTER (change/chat-start-guard, 22/11).
//
// What Victor saw: 'wa chat', 'hi', and the CLI sat silent for twenty seconds before doing anything. The
// cause was two network reads on the path of the Enter - a live node roster (one probe child per peer,
// each awaited up to 20 s) and the provider's limits (4-7 s) - and 8082b42e moved both to the idle prompt.
// What it left behind is what this test also measures: those reads still ran IN the interpreter, so an
// Enter pressed while one was in flight waited for it (measured on a9d4617d: 4.8 s of silence).
//
// So this drives the REAL binary in a real pty (a PRIVATE tmux server) against a local fixture that is both
// the rendezvous and the provider:
//   * GET /nodes answers a roster of ONE peer whose endpoint is a black hole - a socket that accepts and
//     never answers, so a probe of it costs its whole deadline on the old code;
//   * GET /usage is the provider's limits stub and HOLDS for 5 s, the measured cost of the real one;
//   * the completions request is recorded with the moment it arrived.
// It then reads the screen back: the run's own numbers row must appear within 1 s of the Enter, and the
// provider's request must start within 1 s of it - and neither counts if the answer was faked, so the turn
// has to finish and draw its text.
//
// Isolation is scripts/test-reflow-blocks-pty.mjs's: tmux on a private socket (-L), env -i plus an
// allow-list (no WASM_AGENT_VAULT_URL, no relay), a scratch HOME that REFUSES to be the real
// ~/.wasm-agent, and a FAILURE (never a pass) when the fixture served nothing: a run that reached some
// other endpoint proves nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-chat-start-pty.mjs
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

// This node's TMPDIR points INTO ~/.wasm-agent/tmp, so os.tmpdir() alone would put the ledger and the
// fixture beside real state - which the guard below then (correctly) refuses.
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('chat-start: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-chat-start-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('chat-start: refusing to run with HOME inside the real ' + REAL_HOME);
  process.exit(2);
}

let checks = 0;
let failed = 0;
function check(name, condition, detail = '') {
  checks += 1;
  if (condition) { console.log('ok - ' + name); return true; }
  failed += 1;
  console.log('FAIL - ' + name + (detail ? '\n       ' + String(detail).split('\n').join('\n       ') : ''));
  return false;
}

// ---- the fixture: one port that is the rendezvous AND the provider -------------------------------
//
// The limits stub HOLDS for 5 s (the measured cost of a real provider's /usage). Nothing on the reader's
// path asks for it any more: it is here so that any code that puts it back there shows up as a late row
// instead of hiding.
const LIMITS_HOLD_MS = 5000;
const ANSWER = 'Hello there.';
const arrivals = [];
const usageStarted = () => arrivals.filter(entry => entry.path.startsWith('/usage'));
const nodesReads = () => arrivals.filter(entry => entry.path === '/nodes');
const completions = () => arrivals.filter(entry => entry.path.includes('/chat/completions'));
const t0 = Date.now();
const now = () => Date.now() - t0;

// The peer that never answers: a socket that accepts the connection and then says nothing at all.
let peerConnections = 0;
const blackhole = net.createServer(socket => { peerConnections += 1; socket.on('error', () => {}); });
await new Promise(resolve => blackhole.listen(0, '127.0.0.1', resolve));
const PEER_PORT = blackhole.address().port;

const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const entry = {path: String(req.url || ''), at: now(), method: req.method};
    arrivals.push(entry);
    if (entry.path === '/nodes') {
      // One peer, marked OFFLINE - the measured premise (the brief's node, offline: 20.6 s of silence
      // after Enter) - and its endpoint is a black hole, so a PROBE of it cannot return. The probe is
      // what a turn used to wait on: nodes.list asks every peer in the roster, online or not. Offline is
      // also what keeps this test single-faulted: the fleet catalog skips a peer it knows is not
      // attached, so the only thing that can hold the old path here is the probe.
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({nodes: [{node_id: 'ghost-peer', name: 'ghost', public_key: 'test-only',
        online: false, last_seen: Math.floor(Date.now() / 1000) - 3600,
        endpoints: ['127.0.0.1:' + PEER_PORT]}]}));
      return;
    }
    if (entry.path.startsWith('/usage')) {
      setTimeout(() => {
        entry.answeredAt = now();
        res.writeHead(200, {'content-type': 'application/json'});
        res.end(JSON.stringify({usage: {rolling: {percent: 12, resetsAt: new Date(Date.now() + 3600000).toISOString()}}}));
      }, LIMITS_HOLD_MS);
      return;
    }
    entry.answeredAt = now();
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    const chunks = [
      {id: 'chat-start-1', choices: [{index: 0, delta: {role: 'assistant', content: ANSWER}, finish_reason: null}]},
      {id: 'chat-start-1', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: 'chat-start-1', choices: [], usage: {prompt_tokens: 10, completion_tokens: 3, total_tokens: 13}},
    ];
    for (const chunk of chunks) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
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
  // The rendezvous is the fixture: the roster is the one peer above, and no real node is called.
  WASM_AGENT_RENDEZVOUS: 'http://127.0.0.1:' + PORT,
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  // The opening (Victor 22/11) is measured by its own row (WA_BIN=... cargo test -p wa-term --test
  // opening, and scripts/test-opening.lua); this file drives `wa chat` for something else and should
  // not pay two seconds of animation before the screen it reads.
  WASM_AGENT_CLI_OPENING: 'off',
  COLUMNS: '100',
  LINES: '30',
};

const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-chat-start-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  blackhole.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const {SOCKET, tmux} = tmuxSession('wa-chat-start');   // this process's own server, killed on every exit path
const SESSION = 'chat-start';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
async function waitFor(predicate, label, timeout = 30000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(50);
  }
}
// The run's OWN row: run_started draws the step clock and the numbers a run adds (status_template ->
// run_numbers). The idle footer counts with a SIGMA, the run's row with a DELTA, so this cannot match the
// row that is on screen before the Enter.
const RUN_ROW = /\u0394\u2191\d+/;
const runRow = lines => lines.find(row => RUN_ROW.test(row)) || '';

let started = false;
try {
  const command = [
    'env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat',
  ].join(' ');
  tmux(['kill-server']);
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', '100', '-y', '30', command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;

  await waitFor(() => capture().some(row => row.includes('Type a message')), 'the prompt');
  const promptAt = now();
  check('the prompt is drawn before anything is measured', true);

  // THE PREFETCH AT THE IDLE PROMPT, WITH NOBODY TYPING. The roster is read by a CHILD process, so it
  // arrives while this interpreter is free; the check is that it happens at all, before any key.
  const rosterAt = await waitFor(() => (nodesReads().length > 0 ? nodesReads()[0].at : null),
    'the roster read', 5000).catch(() => null);
  check('the roster is read at the idle prompt, with nobody typing (a supervised child, not this thread)',
    rosterAt !== null, 'roster reads: ' + JSON.stringify(nodesReads()));
  check('the 5 s provider-limits stub is not asked in the background',
    usageStarted().length === 0,
    'a /usage request was made: ' + JSON.stringify(usageStarted()));
  check('the roster peer was never asked for its capabilities on this path (no probe child)',
    peerConnections === 0, 'connections to the black hole: ' + peerConnections);

  // ---- the Enter -------------------------------------------------------------------------------
  const before = capture();
  check('no run row is on screen before the Enter', runRow(before) === '', JSON.stringify(runRow(before)));
  const typedAt = now();
  tmux(['send-keys', '-t', SESSION, 'hi', 'Enter']);

  // BOTH HALVES OF THE SECOND, POLLED TOGETHER, so neither number is the cost of waiting for the other:
  // the row the reader sees (the screen, every 50 ms) and the moment the provider was asked (the
  // fixture's own arrival time, which is the clock the request really started on).
  let rowAt = null;
  let requestAt = null;
  const measureDeadline = Date.now() + 8000;
  while (Date.now() < measureDeadline) {
    if (rowAt === null && runRow(capture()) !== '') rowAt = now();
    if (requestAt === null && completions().length > 0) requestAt = completions()[0].at;
    if (rowAt !== null && requestAt !== null) break;
    await sleep(50);
  }
  const rowMs = rowAt === null ? null : rowAt - typedAt;
  check('the run row (the status row run_started draws) is on screen in under 1 s of the Enter',
    rowMs !== null && rowMs < 1000,
    rowMs === null
      ? 'no run row appeared within 8 s. Screen:\n' + capture().filter(row => row !== '').join('\n')
      : rowMs + ' ms after the Enter');

  check('the provider request starts in under 1 s of the Enter',
    requestAt !== null && (requestAt - typedAt) < 1000,
    requestAt === null
      ? 'no completions request was served within 8 s (arrivals: ' + JSON.stringify(arrivals) + ')'
      : (requestAt - typedAt) + ' ms after the Enter');

  // A fast row proves nothing if the answer never came: the turn has to finish.
  try {
    await waitFor(() => capture().some(row => row.includes(ANSWER)), 'the answer', 30000);
    check('the turn finished and its answer is drawn (the fast row was a real turn)', true);
  } catch (error) {
    check('the turn finished and its answer is drawn (the fast row was a real turn)', false, error.message);
  }
  console.log('prompt at ' + promptAt + ' ms, roster read at ' + rosterAt + ' ms, Enter at ' + typedAt
    + ' ms, run row at ' + rowAt + ' ms');


  // ---- the keypress, read back by a SECOND PROCESS ------------------------------------------------
  // `wa stalls` measures a turn from the keypress the host saw, which crosses three processes: the
  // host's reader thread stamps the line, this chat writes kind=input phase=submit with that stamp, and
  // `wa` run again reads the ledger and pairs the row with the run. A bug that crosses processes needs a
  // test that crosses processes, so the same ledger this chat just wrote is measured by a second binary.
  const stalls = spawnSync('env', ['-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'stalls', '--json'], {encoding: 'utf8', timeout: 120000});
  let measured = null;
  try { measured = JSON.parse(String(stalls.stdout || '').trim().split('\n').pop()); } catch {}
  check('wa stalls reads this chat\'s own ledger (a second process, the same rows)',
    measured && Number(measured.turns) >= 1, String(stalls.stdout || '') + String(stalls.stderr || ''));
  check('the turn was measured FROM THE KEYPRESS, not from the run\'s first record',
    measured && Number(measured.from_keypress) >= 1,
    'from_keypress: ' + JSON.stringify(measured && measured.from_keypress) + ', from_run: '
      + JSON.stringify(measured && measured.from_run));
  const slowest = (measured && Array.isArray(measured.worst) && measured.worst[0]) || {};
  check('its worst row is this turn, and says it was measured from the keypress',
    slowest.from === 'enter' && typeof slowest.gap_ms === 'number' && slowest.gap_ms >= 0,
    JSON.stringify(measured && measured.worst));
  check('the row reports how much of the wait was spent before the run began (a number, not unknown)',
    typeof slowest.pre_run_ms === 'number' && slowest.pre_run_ms >= 0,
    JSON.stringify(slowest));
  // ---- the prefetch really ran, and the parent could use it --------------------------------------
  // The child's own operation row is on disk under this scratch home: a payload of view specs with no
  // problems. The node log carries an 'idle reads:' line only when the parent could NOT use it
  // (lua/core/idle_reads.lua, log_once), so an empty one is the apply's own negative check.
  const operations = path.join(HOME, '.wasm-agent', 'operations');
  const payloads = [];
  let readError = '';
  try {
    for (const entry of fs.readdirSync(operations, {withFileTypes: true})) {
      if (!entry.isDirectory() || !entry.name.startsWith('op-')) continue;
      const stdout = path.join(operations, entry.name, 'stdout');
      if (!fs.existsSync(stdout)) continue;
      for (const line of fs.readFileSync(stdout, 'utf8').split('\n')) {
        if (line.trim() === '') continue;
        try { const value = JSON.parse(line); if (Array.isArray(value.views)) payloads.push(value); } catch {}
      }
    }
  } catch (error) { readError = error.message; }
  const prefetch = payloads[0];
  check('the prefetch child answered with view specs (its operation row is on disk)',
    Boolean(prefetch) && prefetch.views.length > 0,
    readError || ('payloads: ' + payloads.length + ', operations dir: ' + (fs.existsSync(operations) ? 'present' : 'absent')));
  check('the prefetch child named no problem (every view it was asked for was built)',
    Boolean(prefetch) && Array.isArray(prefetch.problems) && prefetch.problems.length === 0,
    prefetch ? JSON.stringify(prefetch.problems) : 'no payload');
  check('every published view is a spec the client can take (a name and a converted stack)',
    Boolean(prefetch) && prefetch.views.every(entry => typeof entry.name === 'string'
      && entry.spec && typeof entry.spec.command === 'string' && Array.isArray(entry.spec.views)),
    prefetch ? JSON.stringify(prefetch.views.map(entry => entry.name)) : 'no payload');
  const logPath = path.join(HOME, '.wasm-agent', 'logs', 'cli-stderr.log');
  const log = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8') : '';
  check('the parent reported no prefetch failure (a usable answer is a silent one)',
    !/idle reads:/.test(log), log.split('\n').filter(line => line.includes('idle reads:')).join('\n'));
} catch (error) {
  failed += 1;
  console.error('chat-start: FAILED - ' + error.message);
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  blackhole.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('chat-start: scratch kept for diagnosis: ' + WORK);
}

console.log('chat-start pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
