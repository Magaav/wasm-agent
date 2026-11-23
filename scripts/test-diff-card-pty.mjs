#!/usr/bin/env node
// THE DIFF CARD READS LIKE CLAUDE CODE'S (Victor 23/11, two screenshots).
//
// What was measured on the base commit 5956ae15 in a real pty: a write of 26 lines drew the card's
// corner, `Create(/tmp/...)`, `Added 26 lines, removed 0 lines`, ONE diff row so dark it could not be
// read, `… +65 lines`, and the model's next sentence glued directly under it. Three defects, one
// screen: the block folded to three rows, the fold marker sat where a blank row belongs, and the band
// was painted as a FOREGROUND (the row's text was the band's own 18;48;28 on the terminal's black).
//
// This drives the REAL binary in a real pty (a PRIVATE tmux server) against a local SSE fixture that
// plays the model, and reads the screen back - the only way to catch any of it:
//   * a create is drawn OPEN with every line, `● Create(demo.py)`, `Added 10 lines`, path shortened;
//   * ONE blank row above and below the card, so the answer is never glued to it;
//   * an update counts what it did and nothing else (`Added 1 line, removed 1 line`);
//   * a 60-line diff stops at 40 lines with `… +20 lines (ctrl+o to expand)`, and Ctrl+O draws it all;
//   * a removal, in the run that wrote the file, is `● Delete(...)` with `Removed 10 lines`;
//   * a resize keeps every row inside the frame, and `--continue` replays the session honestly
//     (MEASURED: a replayed session draws no card at all - the card is built from the live change
//     event - so that check pins what it does draw, and says the gap out loud).
//
// Isolation is scripts/test-undo-pty.mjs's: tmux on a private socket (-L), `env -i` plus an
// allow-list (no rendezvous, no relay, no vault), a scratch HOME that REFUSES to be the real
// ~/.wasm-agent, the run's cwd inside that scratch directory (never the checkout), and a FAILURE
// (never a pass) when the fixture was not asked for the answer it serves.
//
// Run: WA_BIN=<wa binary> node scripts/test-diff-card-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {tmuxSession} from './lib/tmux-session.mjs';

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
  console.error('diff-card-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wd-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('diff-card-pty: refusing to run with HOME inside the real ' + REAL_HOME);
  process.exit(2);
}
const TARGET = path.join(WORK, 'demo.py');
const LONG = path.join(WORK, 'big.py');

let checks = 0;
let failed = 0;
function check(name, condition, detail = '') {
  checks += 1;
  if (condition) { console.log('ok - ' + name); return true; }
  failed += 1;
  console.log('FAIL - ' + name + (detail ? '\n       ' + String(detail).split('\n').join('\n       ') : ''));
  return false;
}

// ---- the fixture: the model, and only the model ------------------------------------------------
// The plan is per TURN and per CALL, because the provider answers one request at a time: the first
// request of a turn gets the turn's first call, each tool result gets the next call, and the last one
// gets the sentence. The removal shares its run with a write, which is the only way a Delete card can
// exist: the change record a Delete is proven from is the RUN's (lua/core/agent.lua `self.changes`).
const SHORT = Array.from({length: 10}, (_, i) => 'line_' + String(i + 1).padStart(2, '0') + ' = ' + (i + 1)).join('\n') + '\n';
const SHORT2 = SHORT.replace('line_01 = 1', 'line_01 = 1  # one');
const BIG = Array.from({length: 60}, (_, i) => 'big_' + String(i + 1).padStart(2, '0') + ' = ' + (i + 1)).join('\n') + '\n';
const PLAN = [
  {final: 'created the demo file', calls: [['write', () => ({path: TARGET, content: SHORT})]]},
  {final: 'changed the first line', calls: [['write', () => ({path: TARGET, content: SHORT2})]]},
  {final: 'wrote the big file', calls: [['write', () => ({path: LONG, content: BIG})]]},
  {final: 'removed the demo file', calls: [['write', () => ({path: TARGET, content: SHORT})],
    ['bash', () => ({command: 'rm -f ' + TARGET})]]},
];
let requests = 0;
let turn = 0;
let step = 0;

function sse(res, id, delta) {
  res.write('data: ' + JSON.stringify({id, choices: [{index: 0, delta}]}) + '\n\n');
}
function answerCall(res, at, index) {
  const [name, args] = at.calls[index];
  sse(res, 'c', {role: 'assistant', content: null,
    tool_calls: [{index: 0, id: 'call_' + turn + '_' + index, type: 'function', function: {name, arguments: ''}}]});
  sse(res, 'c', {tool_calls: [{index: 0, function: {arguments: JSON.stringify(args())}}]});
  sse(res, 'c', {});
  res.write('data: ' + JSON.stringify({id: 'c', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]}) + '\n\n');
}

const server = http.createServer((req, res) => {
  const body = [];
  req.on('data', chunk => body.push(chunk));
  req.on('end', () => {
    requests += 1;
    let last = '';
    try {
      const parsed = JSON.parse(Buffer.concat(body).toString('utf8'));
      const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
      last = String((messages[messages.length - 1] || {}).role || '');
    } catch { last = ''; }
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    if (last === 'tool') {
      const at = PLAN[turn];
      if (at && step + 1 < at.calls.length) { step += 1; answerCall(res, at, step); }
      else {
        sse(res, 'f', {role: 'assistant', content: at ? at.final : 'done'});
        res.write('data: ' + JSON.stringify({id: 'f', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
        turn += 1; step = 0;
      }
    } else {
      const at = PLAN[turn];
      if (at) answerCall(res, at, 0);
      else {
        sse(res, 'f', {role: 'assistant', content: 'nothing left to do'});
        res.write('data: ' + JSON.stringify({id: 'f', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
      }
    }
    res.write('data: [DONE]\n\n');
    res.end();
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
  console.log('SKIP test-diff-card-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

// This process's own tmux server, killed on every exit path this process can take and reclaimed when a
// SIGKILLed sibling left one behind (scripts/lib/tmux-session.mjs, the one rule the leak check enforces).
const SESSION = 'dcard';
const {tmux, killServer} = tmuxSession('wa-diff-card-pty');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const screen = () => capture().join('\n');
async function waitFor(predicate, label, timeout = 60000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(60);
  }
}
// A blank ROW in the chat, once the scrollbar's own column is taken out: the bar is drawn in the
// screen's last column on every row (rust/wa-term `draw_bar`), so a row of the chat is blank when
// nothing but spaces and a bar glyph is left.
const BAR = /[\u2502\u2503\u2579\u257b]/g;
const isBlank = (row) => String(row || '').replace(BAR, '').trim() === '';

let started = false;
function launch(extra = []) {
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat', ...extra].join(' ');
  const result = tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', WORK, command]);
  if (result.status !== 0) throw new Error('tmux could not start the session: ' + result.stderr);
  started = true;
}
async function ask(text, final) {
  tmux(['send-keys', '-t', SESSION, text, 'Enter']);
  await waitFor(() => screen().includes(final), 'the turn: ' + text);
  await sleep(250);
}

// The card around a given row: its opening row above, its closing row below, and the two blank rows.
function cardAround(needle) {
  const rows = capture();
  const at = rows.findIndex(row => row.includes(needle));
  if (at < 0) return null;
  return {rows, at};
}

try {
  launch();
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  // ---- turn 1: the file is created, and its card is OPEN ---------------------------------------
  await ask('create the demo file', PLAN[0].final);
  let rows = capture();
  let open = rows.findIndex(row => row.includes('\u250c\u2500'));
  check('the card is drawn', open >= 0, screen());
  check('the heading is Claude Code\'s, with the path shortened to the workdir',
    screen().includes('\u25cf Create(demo.py)'), screen());
  check('and the count row says only what happened',
    screen().includes('Added 10 lines') && !screen().includes('removed 0'), screen());
  check('the whole diff is drawn, not three rows',
    screen().includes('line_01') && screen().includes('line_10'), screen());
  check('nothing is counted away on a card that fits', !screen().includes('ctrl+o to expand'), screen());
  let close = rows.findIndex(row => row.includes('\u2514\u2500'));
  check('one blank row ABOVE the card', open > 0 && isBlank(rows[open - 1]),
    JSON.stringify(rows.slice(Math.max(0, open - 1), open + 1)));
  check('one blank row BELOW it, so the answer is never glued to it',
    close > 0 && isBlank(rows[close + 1]) && String(rows[close + 2] || '').includes(PLAN[0].final),
    JSON.stringify(rows.slice(close, close + 3)));
  // ONE number column: the row's lead is the bar, the line's own number and the marker, so the
  // code starts where the card's bar plus four cells ends (the base kept a second, empty column).
  check('one number column, the line\'s own',
    screen().includes('\u2502  1 + line_01 = 1'), screen());

  // ---- turn 2: one line changes, and the count row says so -------------------------------------
  await ask('change the first line', PLAN[1].final);
  check('an update is named Update(path)', screen().includes('\u25cf Update(demo.py)'), screen());
  check('and it counts one line each way', screen().includes('Added 1 line, removed 1 line'), screen());

  // ---- turn 3: a diff past the bound is folded, and Ctrl+O draws it all ------------------------
  await ask('write the big file', PLAN[2].final);
  check('a card past the bound stops at 40 lines', screen().includes('\u2026 +20 lines (ctrl+o to expand)'), screen());
  check('and the line past the bound is not drawn', !screen().includes('big_60'), screen());
  tmux(['send-keys', '-t', SESSION, 'C-o']);
  await waitFor(() => screen().includes('big_60'), 'Ctrl+O to open the card');
  check('Ctrl+O draws the line the bound had hidden', screen().includes('big_60'), screen());
  check('and the counting row is gone', !screen().includes('ctrl+o to expand'), screen());

  // ---- turn 4: a write and its removal in ONE run -------------------------------------------------
  await ask('replace the demo file and remove it', PLAN[3].final);
  await sleep(400);
  check('a removal is named Delete(path)', screen().includes('\u25cf Delete(demo.py)'), screen());
  check('and says how many lines went with it', screen().includes('Removed 10 lines'), screen());
  rows = capture();
  close = rows.findLastIndex(row => row.includes('\u2514\u2500'));
  check('the delete card keeps its blank row too', close > 0 && isBlank(rows[close + 1]),
    JSON.stringify(rows.slice(Math.max(0, close - 1), close + 3)));

  // ---- a resize keeps the frame, the cut and the gap -----------------------------------------
  tmux(['resize-window', '-t', SESSION, '-x', '72', '-y', '30']);
  await sleep(900);
  rows = capture();
  const widest = rows.reduce((most, row) => Math.max(most, row.length), 0);
  check('every row is drawn inside a narrower screen', widest <= 72, 'widest row ' + widest + ' of 72');
  check('the card is still a frame after the resize', screen().includes('\u2514\u2500'), screen());
  check('and the answer is still not glued to it',
    (() => {
      const at = rows.findLastIndex(row => row.includes('\u2514\u2500'));
      return at > 0 && isBlank(rows[at + 1]) && !isBlank(rows[at + 2]);
    })(), rows.join('|'));

  // ---- --continue: MEASURED, a replayed session draws no card ---------------------------------
  tmux(['send-keys', '-t', SESSION, 'C-c']);
  await sleep(400);
  tmux(['send-keys', '-t', SESSION, 'C-c']);
  await sleep(1500);
  killServer();
  started = false;
  launch(['--continue']);
  await waitFor(() => screen().includes('Type a message'), 'the prompt of the continued session');
  await sleep(1500);
  check('a continued session replays the turns it holds', screen().includes('Write') && screen().includes('continued'),
    screen());
  check('and draws NO card: a card is built from the live change event, not stored (measured; not this mission)',
    !screen().includes('\u250c\u2500'), screen());
} catch (error) {
  failed += 1;
  console.error('diff-card-pty: FAILED - ' + error.message);
  try { console.error(capture().join('|')); } catch {}
} finally {
  if (started) killServer();
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('diff-card-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('diff card pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
