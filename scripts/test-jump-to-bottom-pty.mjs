#!/usr/bin/env node
// JUMP TO BOTTOM: A PILL AT THE FOOT OF THE TRANSCRIPT, WITH THE KEY FROM THE KEYMAP
// (Fable, 23/11; Victor: "we want a sticked to the bottom 'Jump to bottom' as Claude Code ...
// ours are like ctrl+PgDn").
//
// This drives the REAL binary in a real pty (a private tmux server) against a local fixture that
// streams an answer slowly, so output keeps arriving while the reader is away from the bottom:
//   1. scrolled up during a streaming run: the pill is on the region's last row, names the key the
//      keymap binds to Bottom (READ from the table, never a literal), and says how much is below;
//   2. the pill never takes the session status bar (the last row the app owns keeps its text);
//   3. the key (Ctrl+PageDown today) goes back to the bottom, following again, and the pill goes;
//   4. a CLICK on the pill does the same.
//
// Isolation is scripts/test-pinned-request-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, env -i plus an allow-list, and a FAILURE (never a pass) when the fixture served
// nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-jump-to-bottom-pty.mjs
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
  console.error('jump-to-bottom-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-jump-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('jump-to-bottom-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: a provider that streams for a while -------------------------------------------
const LINES = 90;
const CHUNK_MS = 90;
let completions = 0;
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    if (!String(req.url || '').includes('chat/completions')) { res.writeHead(404); res.end('{}'); return; }
    completions += 1;
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    let n = 0;
    const tick = () => {
      if (n >= LINES) {
        res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
        res.write('data: [DONE]\n\n');
        res.end();
        return;
      }
      res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {content: 'line ' + n + ' of a long answer\n'}, finish_reason: null}]}) + '\n\n');
      n += 1;
      setTimeout(tick, CHUNK_MS);
    };
    tick();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const COLS = 100, ROWS = 40;
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
  console.log('SKIP test-jump-to-bottom-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const {tmux} = tmuxSession('wa-jump');
const SESSION = 'jump';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function rows() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const screen = () => rows().join('\n');
const footer = () => (rows()[ROWS - 1] || '');
const pillRow = () => rows().findIndex(row => row.includes('Jump to bottom'));
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
// A mouse report is bytes on the pane's input: SGR, one-based column and row.
const mouse = (button, col, row) => tmux(['send-keys', '-t', SESSION, '-l',
  `\u001b[<${button};${col};${row}${button === 64 || button === 65 ? 'M' : 'M'}`]);
const wheelUp = times => { for (let n = 0; n < times; n += 1) mouse(64, 40, 20); };

let started = false;
try {
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat'].join(' ');
  const begun = tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', WORK, command]);
  if (begun.status !== 0) throw new Error('tmux could not start the session: ' + begun.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  tmux(['send-keys', '-l', '-t', SESSION, 'stream something long']);
  tmux(['send-keys', '-t', SESSION, 'Enter']);
  await waitFor(() => screen().includes('line 40 of a long answer'), 'the answer to fill the screen');
  check('a run is streaming and the view follows it at the bottom', !screen().includes('Jump to bottom'),
    rows().slice(-6).join('\n'));

  // ---- scrolled up during the stream: the pill --------------------------------------------------
  wheelUp(12);
  let pill = null;
  try {
    await waitFor(() => (pillRow() >= 0 ? pillRow() : null), 'the pill', 8000);
    pill = pillRow();
  } catch { pill = -1; }
  check('scrolled away from the newest output, the pill is drawn', pill >= 0, rows().slice(-10).join('\n'));
  const pillText = pill >= 0 ? rows()[pill] : '';
  check('the pill names the key the KEYMAP binds to Bottom, not a literal',
    pillText.includes('Ctrl+PageDown'), pillText);
  check('the pill sits at the foot of the transcript, above the box', pill > 0 && pill < ROWS - 3, pill + ': ' + pillText);
  check('and says how much is below', /\d+ more lines/.test(pillText), pillText);
  check('the session status bar keeps its line while the pill shows', footer().includes('deepseek-v4.1-flash'), footer());
  check('and the pill is not on the status bar', !footer().includes('Jump to bottom'), footer());
  // Output arriving while the reader is away is counted.
  const before = (() => { const m = /(\d+) more lines/.exec(pillText); return m ? Number(m[1]) : 0; })();
  await sleep(1200);
  const after = (() => { const m = /(\d+) more lines/.exec(rows()[pillRow()] || ''); return m ? Number(m[1]) : 0; })();
  check('and the count grows while new output arrives', after > before, before + ' -> ' + after);

  // ---- the key goes back to the bottom -----------------------------------------------------------
  tmux(['send-keys', '-t', SESSION, '-H', '1b', '5b', '36', '3b', '35', '7e']);  // ESC [ 6 ; 5 ~
  let gone = false;
  try {
    await waitFor(() => (pillRow() < 0 ? true : null), 'the pill to go on the key', 8000);
    gone = true;
  } catch { gone = false; }
  check('the mapped key goes back to the bottom and the pill goes', gone, rows().slice(-8).join('\n'));
  const newest = () => {
    const text = screen();
    const numbers = [...text.matchAll(/line (\d+) of a long answer/g)].map(m => Number(m[1]));
    return numbers.length ? Math.max(...numbers) : -1;
  };
  const at1 = newest();
  await sleep(1200);
  const followsAgain = newest() > at1;
  check('and the view follows the model again (new output appears without scrolling)', followsAgain,
    at1 + ' -> ' + newest());
  check('the status bar is still its own row', footer().includes('deepseek-v4.1-flash'), footer());

  // ---- a CLICK on the pill does the same --------------------------------------------------------
  wheelUp(12);
  let clicked = -1;
  try {
    await waitFor(() => (pillRow() >= 0 ? pillRow() : null), 'the pill again', 8000);
    clicked = pillRow();
  } catch { clicked = -1; }
  check('scrolled up again, the pill is back', clicked >= 0, rows().slice(-8).join('\n'));
  if (clicked >= 0) {
    const text = rows()[clicked];
    const col = text.indexOf('Jump to bottom') + 3;
    mouse(0, col, clicked + 1);   // a press on the pill
    let closed = false;
    try {
      await waitFor(() => (pillRow() < 0 ? true : null), 'the pill to go on the click', 8000);
      closed = true;
    } catch { closed = false; }
    check('a click on the pill goes back to the bottom, and the pill goes', closed, rows().slice(-8).join('\n'));
    const at2 = newest();
    await sleep(1200);
    check('and a click leaves the view following too', newest() > at2, at2 + ' -> ' + newest());
  }
} catch (error) {
  failed += 1;
  console.error('jump-to-bottom-pty: FAILED - ' + error.message);
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('jump-to-bottom-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('jump to bottom pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, ' + completions + ' provider requests');
process.exitCode = failed === 0 ? 0 : 1;
