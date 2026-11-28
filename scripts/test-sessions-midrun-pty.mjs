#!/usr/bin/env node
// `/sessions` OPENS WHILE A TURN IS RUNNING (Victor, 28/11: "open the session list while a turn is
// running ... move between sessions back and forth quickly (the running turn keeps running in its
// session), and come back").
//
// The finding: `wa chat` runs a turn synchronously, so from Enter until the last token this process is
// inside the model call and cannot draw. The host keeps reading the keyboard, so a `/sessions` typed
// mid-run was QUEUED and opened after the turn - which for a long turn is "nothing happened". `/status`
// and the `local_view = true` panels (`/nodes`, `/mcp`, `/help`, `/login`) do not have that problem: the
// spec the client needs is published before the run and the reader thread draws it itself.
//
// This drives the REAL binary in a real pty (a private tmux server) against a local fixture that plays
// the provider, and measures on the screen:
//   1. `/sessions` opens DURING the run, within SESSIONS_OPEN_MS, while the model call is still held;
//   2. it is the sessions list (its own title and its `Enter switches` hint), not a blank panel;
//   3. Esc closes it, and a second `/sessions` opens just as fast - away and back;
//   4. the held turn KEEPS RUNNING across all of that and its answer lands when the fixture releases it.
//
// On the base every one of 1-3 fails: the panel does not appear until the turn ends (measured by
// `scripts/lib/row-at-sha.sh` and this file on the base commit).
//
// Isolation is scripts/test-diff-card-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, `env -i` plus an allow-list, and a FAILURE (never a pass) when the fixture served
// nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-sessions-midrun-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {tmuxSession} from './lib/tmux-session.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('sessions-midrun-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'sessions-midrun-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('sessions-midrun-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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
// The FIRST completion answers at once (so the session has a turn in its transcript). The SECOND one
// holds, and that hold is the run the reader types into.
const HOLD_MS = 20000;
const ANSWERS = ['first answer', 'the slow answer'];
let completions = 0;

const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const index = completions;
    completions += 1;
    const text = ANSWERS[Math.min(index, ANSWERS.length - 1)];
    const write = () => {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      const chunks = [
        {id: 's', choices: [{index: 0, delta: {role: 'assistant', content: text}, finish_reason: null}]},
        {id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      ];
      for (const chunk of chunks) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
      res.write('data: [DONE]\n\n');
      res.end();
    };
    if (index === 1) setTimeout(write, HOLD_MS);
    else write();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

// How long the reader may wait for the panel. Victor's own word is "immediate": a `/status` panel is
// drawn by the reader thread on the next keystroke, so a second is already generous - and a QUEUED
// `/sessions` takes the whole hold (20 s here), which is the failure this bound is set to separate.
const OPEN_MS = 2000;

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
  console.log('SKIP test-sessions-midrun-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const SESSION = 'smid';
const {tmux, killServer} = tmuxSession('wa-sessions-midrun');
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
    await sleep(40);
  }
}

// The sessions list is on screen when its own title row is: `Sessions (N)`, drawn by
// lua/core/sessions_view.lua for the blocking walk AND published to the client for the mid-run one.
const sessionsOnScreen = () => /Sessions \(\d+/.test(screen());
let started = false;

try {
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat'].join(' ');
  const result = tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', WORK, command]);
  if (result.status !== 0) throw new Error('tmux could not start the session: ' + result.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  // ---- a first turn, so the list has a session with a transcript -------------------------------
  tmux(['send-keys', '-t', SESSION, 'say something', 'Enter']);
  await waitFor(() => screen().includes(ANSWERS[0]), 'the first answer');
  check('a first turn lands, so the list has something to show', completions >= 1);

  // ---- the run whose model call HOLDS: the reader types `/sessions` into it ---------------------
  tmux(['send-keys', '-t', SESSION, 'now the slow one', 'Enter']);
  await waitFor(() => completions >= 2, 'the second request');
  const before = screen();
  check('the second turn is in flight and has not answered yet',
    !before.includes(ANSWERS[1]), before);

  const askedAt = Date.now();
  tmux(['send-keys', '-t', SESSION, '/sessions', 'Enter']);
  let openedAt = 0;
  let during = '';
  try {
    await waitFor(() => (sessionsOnScreen() ? true : null), 'the sessions panel', OPEN_MS + 4000);
    openedAt = Date.now();
    // THE PANEL IS DRAWN BY THE READER THREAD, so the first frame can land before its body and the run's
    // own repaint can be captured between them: the row waits for the row that says what Enter does, and
    // only then reads the screen. A timeout here is the SAME failure as no panel at all, never a pass.
    await waitFor(() => (/Enter to select/.test(screen()) ? true : null), 'the sessions list body', 2000);
    during = screen();
  } catch { during = screen(); }
  const waited = openedAt > 0 ? openedAt - askedAt : -1;
  check('`/sessions` opens DURING the run, within ' + OPEN_MS + ' ms',
    openedAt > 0 && waited <= OPEN_MS,
    openedAt > 0 ? ('opened after ' + waited + ' ms\nthe screen:\n' + during) : ('never opened mid-run; the screen:\n' + during));
  // WHAT THE CLIENT DRAWS, not what the blocking balloon prints: the published page carries the title and
  // the session rows, and the reader thread adds its own footer (`↑↓ to move · Enter to select`). The
  // balloon's between-runs hint (`Enter switches · c copies ...`) belongs to the blocking walk and a row
  // that demanded it here would fail a panel that is correct.
  check('and it is the sessions list: its title, a session row, and the client\'s own keys',
    /Sessions \(\d+/.test(during) && /this node/.test(during) && /Enter to select/.test(during), during);
  check('the turn is STILL running under it', !during.includes(ANSWERS[1]), during);

  // ---- away and back: Esc closes it, and the next `/sessions` opens just as fast ---------------
  tmux(['send-keys', '-t', SESSION, 'Escape']);
  try { await waitFor(() => !sessionsOnScreen(), 'the panel to close', 5000); } catch { /* the next check names it */ }
  check('Esc closes it while the run continues', !sessionsOnScreen(), screen());

  const againAt = Date.now();
  tmux(['send-keys', '-t', SESSION, '/sessions', 'Enter']);
  let reopenedAt = 0;
  try {
    await waitFor(() => (sessionsOnScreen() ? true : null), 'the sessions panel again', OPEN_MS + 4000);
    reopenedAt = Date.now();
  } catch { /* named below */ }
  const againWait = reopenedAt > 0 ? reopenedAt - againAt : -1;
  check('and a second `/sessions` opens just as fast - away and back',
    reopenedAt > 0 && againWait <= OPEN_MS,
    reopenedAt > 0 ? ('reopened after ' + againWait + ' ms') : ('never reopened; the screen:\n' + screen()));
  tmux(['send-keys', '-t', SESSION, 'Escape']);
  await sleep(300);

  // ---- the held turn KEPT RUNNING across all of that ------------------------------------------
  await waitFor(() => screen().includes(ANSWERS[1]), 'the held answer', HOLD_MS + 40000);
  check('the turn kept running and its answer landed', screen().includes(ANSWERS[1]), screen());
  check('and the fixture served exactly the two completions this row expects', completions === 2,
    'completions=' + completions);
} catch (error) {
  failed += 1;
  console.log('FAIL - the run threw: ' + (error && error.message ? error.message : error));
  try { console.log(screen()); } catch {}
} finally {
  if (started) { try { killServer(); } catch {} }
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
}

console.log('\nsessions midrun pty: ' + checks + ' ok, ' + failed + ' failed');
process.exit(failed > 0 ? 1 : 0);
