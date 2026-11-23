#!/usr/bin/env node
// THE LAST REQUEST STAYS ON THE TOP ROW, WITH THE NOTICE ROW ABOVE IT (Victor, 23/11 11:20Z).
//
// Victor, with a Claude Code screenshot: "claude code shows sticked to the top the last user input
// turn. we want that. and we want on top of that sticked user input a line reserved to TUI messages
// that are currently being printed on top of the session status bar like 'Copied <n> characters' ...
// so we never lose vision of the session status bar".
//
// This drives the REAL binary in a real pty (a private tmux server) against a local fixture that
// plays the provider with a SLOW stream, so the answer scrolls past the request while the reader
// looks at it:
//   1. a session with no request yet has no pinned row at all;
//   2. during the run the request is the top row of the window, and the row under it is the chat's;
//   3. a copy is announced on the notice row, ABOVE the pinned request, and the session status bar
//      keeps its own line in every frame of that window;
//   4. the message goes after about two seconds and the pinned request is the top row again;
//   5. an ERROR stays until the next key;
//   6. a resize keeps both rows and the status bar;
//   7. a wide-character request is pinned on one row;
//   8. `--continue` pins the last request of a resumed session.
//
// Isolation is scripts/test-status-midrun-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, env -i plus an allow-list, and a FAILURE (never a pass) when the fixture served
// nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-pinned-request-pty.mjs
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
  console.error('pinned-request-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-pinned-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('pinned-request-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: a provider that streams slowly ------------------------------------------------
const LINES = 70;
const CHUNK_MS = 90;
let completions = 0;
function answerFor(request) {
  const words = String(request || '').slice(0, 40) || 'answer';
  return Array.from({length: LINES}, (_, n) => `answer ${n} to ${words}`);
}
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const url = String(req.url || '');
    if (!url.includes('chat/completions')) { res.writeHead(404); res.end('{}'); return; }
    let asked = '';
    try {
      const parsed = JSON.parse(body);
      const last = (parsed.messages || []).filter(m => m.role === 'user').pop();
      asked = String((last && last.content) || '');
    } catch { asked = ''; }
    completions += 1;
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    const lines = answerFor(asked);
    let n = 0;
    const tick = () => {
      if (n >= lines.length) {
        res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
        res.write('data: [DONE]\n\n');
        res.end();
        return;
      }
      const text = lines[n] + (n === lines.length - 1 ? '' : '\n');
      res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {content: text}, finish_reason: null}]}) + '\n\n');
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
  console.log('SKIP test-pinned-request-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const {tmux} = tmuxSession('wa-pinned');
const SESSION = 'pin';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function rows() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const screen = () => rows().join('\n');
const veryTop = () => (rows()[0] || '');
// The session status bar is the LAST row the app owns: the screen is ROWS tall, and a capture
// leaves one trailing empty line after it.
const footer = () => (rows()[ROWS - 1] || '');
// The run's own line, the one directly above the input box (`▸ 1·4s Δ↑0 ↓0 ...`).
const runRow = () => rows().find(row => row.includes('Δ↑')) || '';
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
const launch = (extra = []) => {
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat', ...extra].join(' ');
  return tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', WORK, command]);
};
const key = bytes => tmux(['send-keys', '-t', SESSION, ...bytes]);
const type = text => tmux(['send-keys', '-l', '-t', SESSION, text]);
// The bar's own text, on the left while idle and on the right while a run is in flight: the model
// in use. It is what a message must never take away.
const STATUS = 'deepseek-v4.1-flash';

let started = false;
try {
  const begun = launch();
  if (begun.status !== 0) throw new Error('tmux could not start the session: ' + begun.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  // ---- a session with no request yet: nothing to pin ---------------------------------------------
  const first = rows().slice(0, 4);
  check('no request yet, so no pinned row', !first.some(row => row.trimStart().startsWith('\u276f')), first.join('\n'));

  // ---- the run: the request is the top row while the answer scrolls -----------------------------
  type('stream me a long answer');
  key(['Enter']);
  await waitFor(() => screen().includes('answer 40 to'), 'the answer to scroll past the screen');
  const during = rows();
  check('the request is pinned on the first row of the window',
    veryTop().startsWith('\u276f stream me a long answer'), during.slice(0, 3).join('\n'));
  check('the row under it is the chat\'s own row, not a second copy of the pin',
    !during[1].startsWith('\u276f stream me a long answer'), during.slice(0, 3).join('\n'));
  check('the newest output is on screen too', during.join('\n').includes('answer 40 to'), during.join('\n'));
  check('the session status bar keeps its line during the run', footer().includes(STATUS), footer());
  check('and the run’s own line is above the box, untouched', runRow().includes('Δ↑'), runRow());

  // ---- a copy is announced ABOVE the pinned request ----------------------------------------------
  type('hello world');
  key(['C-a']);   // select the draft
  key(['C-c']);   // copy it (OSC 52) -> the notice row
  let sawNotice = null;
  try {
    await waitFor(() => (veryTop().includes('Copied 11 characters') ? veryTop() : null), 'the copy notice', 6000);
    sawNotice = veryTop();
  } catch { sawNotice = null; }
  check('the copy is announced on the very top row', !!sawNotice, rows().slice(0, 3).join('\n'));
  const withNotice = rows();
  check('the pinned request is the row UNDER the message',
    (withNotice[1] || '').startsWith('\u276f stream me a long answer'), withNotice.slice(0, 3).join('\n'));
  check('the session status bar is untouched by the message',
    footer().includes(STATUS) && !footer().includes('Copied'), footer());
  check('and so is the run’s own line', runRow().includes('Δ↑') && !runRow().includes('Copied'), runRow());
  check('and the message is not on the status bar', !footer().includes('Copied'), footer());
  // Every frame of the window it shows: the status bar keeps its line.
  let framesOk = 0, frames = 0;
  for (let n = 0; n < 8; n += 1) {
    frames += 1;
    if (footer().includes(STATUS) && !footer().includes('Copied') && runRow().includes('Δ↑')) framesOk += 1;
    await sleep(120);
  }
  check('the status bar keeps its text in every frame the message is up',
    framesOk === frames, framesOk + '/' + frames);

  // ---- about two seconds later it is gone, and the pin is the top row again ----------------------
  await waitFor(() => (!screen().includes('Copied 11 characters') ? true : null), 'the message to go', 8000);
  check('the message goes after about two seconds', true);
  check('and the pinned request is the top row again',
    veryTop().startsWith('\u276f stream me a long answer'), rows().slice(0, 3).join('\n'));

  // ---- an ERROR stays until the next key ---------------------------------------------------------
  key(['C-v']);  // no WAYLAND_DISPLAY/DISPLAY in this scratch env: the clipboard refuses
  let sawError = null;
  try {
    await waitFor(() => (/DISPLAY/.test(veryTop()) ? veryTop() : null), 'the clipboard refusal', 8000);
    sawError = veryTop();
  } catch { sawError = null; }
  check('a refused paste says so on the notice row', !!sawError, rows().slice(0, 3).join('\n'));
  check('and the status bar keeps its line under the error', footer().includes(STATUS), footer());
  check('and the run’s own line is not replaced either', runRow().includes('Δ↑') && !runRow().includes('DISPLAY'), runRow());
  await sleep(3000);
  check('an error does not time out: it is still there after three seconds',
    /DISPLAY/.test(veryTop()), rows().slice(0, 3).join('\n'));
  type('x');
  await waitFor(() => (!/DISPLAY/.test(veryTop()) ? true : null), 'the error to go on the next key', 6000);
  check('the next key takes it away', !/DISPLAY/.test(veryTop()), rows().slice(0, 3).join('\n'));
  key(['C-u']);

  // ---- a resize keeps the pin and the status bar -------------------------------------------------
  tmux(['resize-window', '-t', SESSION, '-x', '70', '-y', '30']);
  await sleep(900);
  const resized = rows();
  check('a narrower window still pins the request on the top row',
    (resized[0] || '').startsWith('\u276f stream me a long answer'), resized.slice(0, 3).join('\n'));
  check('and the status bar is still the last row the app owns', (resized[29] || '').includes(STATUS),
    resized[29] || '');
  tmux(['resize-window', '-t', SESSION, '-x', String(COLS), '-y', String(ROWS)]);
  await sleep(900);

  // ---- a wide-character request is pinned on ONE row ---------------------------------------------
  type('\u4f60\u597d\u4e16\u754c \u4f60\u597d\u4e16\u754c \u4f60\u597d\u4e16\u754c \u4f60\u597d\u4e16\u754c');
  key(['Enter']);
  // The fixture echoes the request, so a line naming the WIDE request is proof this is the
  // second run and not a leftover of the first.
  // 55 lines is more than the region holds, so the request has really left the viewport.
  await waitFor(() => screen().includes('answer 55 to 你好'), 'the second answer to scroll past');
  const wide = rows();
  check('a wide-character request is pinned too',
    (wide[0] || '').startsWith('\u276f \u4f60\u597d\u4e16\u754c'), wide.slice(0, 3).join('\n'));
  check('and it is ONE row: the row under it is the chat\u2019s',
    !(wide[1] || '').startsWith('\u276f'), wide.slice(0, 3).join('\n'));

  // ---- --continue: a resumed session pins the last request of its replay ------------------------
  await waitFor(() => (screen().includes('answer 69 to') ? true : null), 'the second answer to finish', 60000);
  tmux(['send-keys', '-t', SESSION, 'C-d']);
  await sleep(1500);
  tmux(['kill-session', '-t', SESSION]);
  await sleep(400);
  const again = launch(['--continue']);
  if (again.status !== 0) throw new Error('tmux could not start the resumed session: ' + again.stderr);
  await waitFor(() => screen().includes('Type a message'), 'the resumed prompt');
  await sleep(1500);
  const resumed = rows();
  check('a resumed session pins the LAST request of its replay',
    (resumed[0] || '').startsWith('\u276f \u4f60\u597d\u4e16\u754c'), resumed.slice(0, 4).join('\n'));
  check('and its status bar keeps its line', (resumed[ROWS - 1] || '').includes(STATUS),
    resumed[ROWS - 1] || '');
} catch (error) {
  failed += 1;
  console.error('pinned-request-pty: FAILED - ' + error.message);
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('pinned-request-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('pinned request pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, ' + completions + ' provider requests');
process.exitCode = failed === 0 ? 0 : 1;
