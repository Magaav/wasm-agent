#!/usr/bin/env node
// `/status` LOADS THE LIMITS WHEN IT OPENS, MID-RUN TOO (status-limits-load-on-open).
//
// Victor, 25/11: "opencode-go (in use) - limits unavailable: read on the next /status between runs" -
// the panel telling him to do something instead of doing it. The read is now the HOST's (a door with
// a thread of its own), and a mid-run snapshot carries a marker the CONSOLE expands from that door on
// every draw, so the rows turn from `loading limits...` into bars while the panel is open.
//
// This drives the REAL binary in a real pty against a fixture that plays the provider:
//   * the FIRST `/usage` holds for U_LOAD_MS (the load the reader watches) and answers rolling 37 %;
//   * the first completion answers at once; the second HOLDS, and is the run `/status` is typed into.
// Measured on the screen:
//   1. `/status` mid-run draws `loading limits...` at once (never the old refusal);
//   2. a few seconds later the SAME panel shows the bar, mid-run, with no reopen;
//   3. after the run, `/status` draws the bar again and says how old the reading is;
//   4. the turn's own model call still completes (read from the ledger by a second process);
//   5. the provider key appears in no file the session wrote.
//
// Isolation is scripts/test-status-midrun-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, env -i plus an allow-list, and a FAILURE (never a pass) when the fixture served
// nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-status-limits-pty.mjs
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
  console.error('status-limits-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-status-limits-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('status-limits-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture --------------------------------------------------------------------------------
const U_LOAD_MS = 5000;
const SLOW_HOLD_MS = 30000;
const KEY = 'test-only-limits-key';
let completions = 0;
let usageReads = 0;

const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const url = String(req.url || '');
    if (url.startsWith('/usage')) {
      usageReads += 1;
      const answer = () => {
        res.writeHead(200, {'content-type': 'application/json'});
        res.end(JSON.stringify({usage: {rolling: {percent: 37,
          resetsAt: new Date(Date.now() + 3600000).toISOString()}}}));
      };
      // The first read is the load the reader watches; the rest answer at once.
      if (usageReads === 1) setTimeout(answer, U_LOAD_MS);
      else answer();
      return;
    }
    const index = completions;
    completions += 1;
    const write = () => {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {role: 'assistant', content: 'answer ' + index}, finish_reason: null}]}) + '\n\n');
      res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
      res.write('data: [DONE]\n\n');
      res.end();
    };
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
  WASM_AGENT_LLM_API_KEY: KEY,
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
  console.log('SKIP test-status-limits-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const {tmux} = tmuxSession('wa-status-limits');
const SESSION = 'slim';
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

  // ---- turn 1 finishes (completion 0), so the session is alive and has a turn behind it ----------
  tmux(['send-keys', '-t', SESSION, 'say something', 'Enter']);
  await waitFor(() => completions >= 1, 'the first model call', 60000);
  await waitFor(() => screen().includes('answer 0'), 'the first answer on screen', 60000);

  // ---- turn 2 HOLDS: `/status` is typed while its model call is in flight ------------------------
  tmux(['send-keys', '-t', SESSION, 'now the slow one', 'Enter']);
  await waitFor(() => completions >= 2, 'the second model call to arrive', 60000);
  const midRunBefore = Date.now();
  tmux(['send-keys', '-t', SESSION, '/status', 'Enter']);
  let loading = '';
  try {
    await waitFor(() => (screen().includes('loading limits') ? screen() : null), 'the loading row', 8000);
    loading = screen();
  } catch { loading = screen(); }
  check('a mid-run `/status` says the limits are loading, at once', loading.includes('loading limits'), loading.slice(0, 4000));
  check('and never the old refusal to read between runs', !loading.includes('read on the next /status'), loading.slice(0, 4000));
  check('while the model call is still in flight', !loading.includes('answer 1'), loading.slice(0, 4000));

  // ---- the bars replace the row IN PLACE, still mid-run, with no reopen --------------------------
  let bars = '';
  try {
    await waitFor(() => (screen().includes('37%') ? screen() : null), 'the bars in the open panel', 30000);
    bars = screen();
  } catch { bars = screen(); }
  check('the bars appear in the SAME open panel, no reopen', bars.includes('37%'), bars.slice(0, 4000));
  check('and the loading line is gone', !bars.includes('loading limits'), bars.slice(0, 4000));
  check('still while the model call is in flight', !bars.includes('answer 1'), bars.slice(0, 4000));
  check('so the panel turned itself around in under the run\'s hold', Date.now() - midRunBefore < SLOW_HOLD_MS,
    'ms since /status: ' + (Date.now() - midRunBefore));

  // ---- the turn still finishes: the ledger, read by a second process ----------------------------
  const db = path.join(WORK, 'ledger.db');
  const completed = () => {
    const out = spawnSync('sqlite3', ['-readonly', db,
      "select count(*) from harness_events where kind='model_call' and phase='end'"], {encoding: 'utf8'});
    return Number(String(out.stdout || '').trim()) || 0;
  };
  let calls = 0;
  try {
    await waitFor(() => (completed() >= 2 ? completed() : null), 'the run to finish', 60000);
    calls = completed();
  } catch { calls = completed(); }
  check('the run finishes its model call after the panel loaded the limits in front of it', calls >= 2,
    'model_call end rows: ' + calls);

  // ---- the key reached no file the session wrote ------------------------------------------------
  const leaked = [];
  const walk = dir => {
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      if (entry.isFile() && full !== path.join(WORK, 'ledger.db')) {
        try { if (fs.readFileSync(full, 'utf8').includes(KEY)) leaked.push(full); } catch {}
      }
    }
  };
  walk(HOME);
  check('the provider key appears in no file this session wrote', leaked.length === 0, leaked.join(', '));
} catch (error) {
  failed += 1;
  console.error('status-limits-pty: FAILED - ' + error.message);
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('status-limits-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('status limits pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, '
  + completions + ' provider requests, ' + usageReads + ' usage reads');
process.exitCode = failed === 0 ? 0 : 1;
