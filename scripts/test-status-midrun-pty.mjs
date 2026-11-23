#!/usr/bin/env node
// `/status` DURING A RUN: THE LIMITS IT ALREADY HAS, WITH THEIR AGE - AND THE COST THE PROVIDER NAMED
// (chat-view-round-2, item 1).
//
// Victor, 23/11 11:05Z, mid-run: "Usage in 342.6k · out 6.7k · cache 92% · cost unknown", then
// "limits unavailable: read on the next /status between runs". Two refusals to say a number the
// process already had: the limits read the panel keeps for exactly this moment was shown with no age
// at all, and the provider's own per-call price (`opencode.list_cost`) was dropped, so every session
// read "cost unknown".
//
// This drives the REAL binary in a real pty (a private tmux server) against a local fixture that
// plays the provider:
//   * `/usage` answers a rolling window at 37 %;
//   * the first completion answers at once, with a usage block carrying `opencode.list_cost`;
//   * the second completion HOLDS for 9 s, which is the run the reader types `/status` into.
// Measurements, all on the screen:
//   1. `/status` between runs draws the bar (37 %) and, after the turn, the provider's list cost -
//      never "cost unknown";
//   2. `/status` pressed MID-RUN draws the same bar with its age ("just now" / "as of N min ago")
//      while the model call is still in flight, and never "limits unavailable";
//   3. the mid-run snapshot costs the network nothing: the fixture's `/usage` count does not move.
//
// On the base, 1 fails (cost unknown) and 2 fails (no age row) - measured by scripts/lib/row-at-sha.sh
// and this file on the base commit.
//
// Isolation is scripts/test-diff-card-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, env -i plus an allow-list, and a FAILURE (never a pass) when the fixture served
// nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-status-midrun-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {tmuxSession} from './lib/tmux-session.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('status-midrun-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-status-midrun-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('status-midrun-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: the provider, and only the provider -------------------------------------------
const LIST_COST = 0.00102713;
const SLOW_HOLD_MS = 9000;
const ANSWERS = ['first answer', 'slow answer'];
let completions = 0;
let usageReads = 0;

const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const url = String(req.url || '');
    if (url.startsWith('/usage')) {
      usageReads += 1;
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({usage: {rolling: {percent: 37,
        resetsAt: new Date(Date.now() + 3600000).toISOString()}}}));
      return;
    }
    const index = completions;
    completions += 1;
    const text = ANSWERS[Math.min(index, ANSWERS.length - 1)];
    const write = () => {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      const chunks = [
        {id: 's', choices: [{index: 0, delta: {role: 'assistant', content: text}, finish_reason: null}]},
        {id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
        // The usage block a real opencode-go call carries: the provider's own price for the call.
        {id: 's', choices: [], usage: {prompt_tokens: 1000, completion_tokens: 100,
          total_tokens: 1100, opencode: {list_cost: LIST_COST}}},
      ];
      for (const chunk of chunks) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
      res.write('data: [DONE]\n\n');
      res.end();
    };
    // The SECOND completion is the run the reader types into: it holds, so the model call is in
    // flight while /status is submitted.
    if (index === 1) setTimeout(write, SLOW_HOLD_MS);
    else write();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const COLS = 100, ROWS = 44;
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
  WASM_AGENT_RENDEZVOUS: '',
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  WASM_AGENT_CLI_OPENING: 'off',
  COLUMNS: String(COLS),
  LINES: String(ROWS),
};

const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-status-midrun-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

// The tmux server belongs to this process and dies with it: the one helper that carries the exit handlers
// and reclaims a server left by a SIGKILLed sibling (scripts/test-tmp-cleanliness.mjs, D1).
const {tmux} = tmuxSession('wa-status-midrun');
const SESSION = 'smid';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
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
    await sleep(60);
  }
}

let started = false;
try {
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat'].join(' ');
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', WORK, command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  // ---- turn 1: one completed call, so the session has a cost to report --------------------------
  tmux(['send-keys', '-t', SESSION, 'say something', 'Enter']);
  await waitFor(() => screen().includes(ANSWERS[0]), 'the first answer');
  check('the first turn finished (one model call is in the ledger)', completions >= 1, 'requests: ' + completions);
  await sleep(400);

  // ---- `/status` between runs: the bar, and the provider's own list cost ------------------------
  tmux(['send-keys', '-t', SESSION, '/status', 'Enter']);
  let between = '';
  try {
    await waitFor(() => (screen().includes('37%') ? screen() : null), 'the limits panel', 30000);
    between = screen();
  } catch { between = screen(); }
  check('a `/status` between runs draws the provider\'s limits', between.includes('37%'), between);
  check('and the age row is not invented for a reading taken now', !/as of \d+ (min|h|d) ago/.test(between), between);
  check('the panel shows the provider list cost instead of "cost unknown"',
    /Cost\s+list \$0\.0010/.test(between) && !/unknown/.test(between), between);
  // The panel is a balloon: Esc closes it, and the next line must reach the chat rather than the page.
  tmux(['send-keys', '-t', SESSION, 'Escape']);
  try {
    await waitFor(() => !screen().includes('(in use)'), 'the panel to close', 8000);
  } catch { /* the next waitFor names the real failure */ }
  const usageBefore = usageReads;

  // ---- the run whose model call holds, and `/status` typed into it ------------------------------
  tmux(['send-keys', '-t', SESSION, 'now the slow one', 'Enter']);
  // The run is in flight: the request arrived and the answer has NOT been written yet.
  await waitFor(() => completions >= 2, 'the second request');
  check('the second model call is in flight and unanswered', !screen().includes(ANSWERS[1]), screen());
  tmux(['send-keys', '-t', SESSION, '/status', 'Enter']);
  let midrun = '';
  try {
    await waitFor(() => (screen().includes('37%') ? screen() : null), 'the mid-run panel', 6000);
    midrun = screen();
  } catch { midrun = screen(); }
  const stillRunning = !midrun.includes(ANSWERS[1]);
  check('the panel is drawn while the model call is still in flight', stillRunning, midrun);
  check('a mid-run `/status` draws the limits it already has', midrun.includes('37%'), midrun);
  check('and says how old the reading is ("just now" / "as of N min ago")',
    /just now|as of \d+ (min|h|d) ago/.test(midrun), midrun);
  check('and never claims the limits are unavailable while it has a reading',
    !midrun.includes('limits unavailable'), midrun.slice(0, 4000));
  check('the mid-run snapshot asked the provider NOTHING (the reading was already in hand)',
    usageReads === usageBefore, 'usage reads before: ' + usageBefore + ', now: ' + usageReads);
  // And the turn still finishes: a snapshot that cost the model its answer would be worse. Measured in
  // the LEDGER, by a second process - the mid-run panel covers the screen the answer is drawn on, and
  // pressing Esc to look would stop the run this check is about.
  const db = path.join(WORK, 'ledger.db');
  const completed = () => {
    const out = spawnSync('sqlite3', ['-readonly', db,
      "select count(*) from harness_events where kind='model_call' and phase='end'"], {encoding: 'utf8'});
    return Number(String(out.stdout || '').trim()) || 0;
  };
  let calls = 0;
  try {
    await waitFor(() => (completed() >= 2 ? completed() : null), 'the second model call to complete', 40000);
    calls = completed();
  } catch { calls = completed(); }
  check('the run finishes its model call after the mid-run panel (the ledger, read by a second process)',
    calls >= 2, 'model_call end rows: ' + calls);
} catch (error) {
  failed += 1;
  console.error('status-midrun-pty: FAILED - ' + error.message);
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('status-midrun-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('status mid-run pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, '
  + completions + ' provider requests, ' + usageReads + ' usage reads');
process.exitCode = failed === 0 ? 0 : 1;
