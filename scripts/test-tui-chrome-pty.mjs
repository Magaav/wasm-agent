#!/usr/bin/env node
// THE WINDOW'S CHROME, READ FROM A REAL PTY (change/tui-chrome, Victor 21/11 night).
//
//   A. The input box grows with its draft up to max(3, 30% of the window's rows), shows the
//      transcript's scrollbar on its last column past that, takes the wheel when the pointer is over
//      it, and goes back to three rows in a 12-row window.
//   B. A fenced card's copy icon sits AFTER the corner (`┌─ ⧉ bash`), so `┌`, `│` and `└` share a
//      column, and a click on the icon's cell copies the content.
//
// Same isolation as scripts/test-fence-card-pty.mjs: the real binary in a PRIVATE tmux server, a
// local SSE fixture, env -i with an allow-list, a scratch HOME, and a FAIL when the fixture served
// nothing. Run: WA_BIN=<wa binary> node scripts/test-tui-chrome-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');


// ---- the isolation this test lives or dies by ------------------------------------------------
// This node TMPDIR points INTO ~/.wasm-agent/tmp, so os.tmpdir() alone would put the ledger and
// the fixture beside real state - which the guard below then (correctly) refuses.
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('tui-chrome: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-tui-chrome-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('tui-chrome: refusing to run with HOME inside the real ' + REAL_HOME);
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


const TICK = String.fromCharCode(96);
const FENCE = TICK + TICK + TICK;
const CONTENT = 'echo one\necho two';
const ANSWER = ['Here it is:', '', FENCE + 'bash', CONTENT, FENCE, '', 'Done.'].join('\n');

let served = 0;
const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    served += 1;
    const usage = {prompt_tokens: 100, completion_tokens: 50, total_tokens: 150};
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    const chunks = [
      {id: 'chrome-1', choices: [{index: 0, delta: {role: 'assistant', content: ANSWER}, finish_reason: null}]},
      {id: 'chrome-1', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: 'chrome-1', choices: [], usage},
    ];
    for (const chunk of chunks) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const ENV = {
  PATH: '/usr/bin:/bin', HOME, TERM: 'xterm-256color', LANG: 'C.UTF-8',
  WASM_AGENT_HOME: HOME, WASM_AGENT_LUA_ROOT: REPO,
  WASM_AGENT_PROVIDER: 'opencode-go',
  WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + PORT,
  WASM_AGENT_LLM_API_KEY: 'test-only',
  WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE: path.join(WORK, 'no-models-store'),
  WASM_AGENT_RENDEZVOUS: '', WASM_AGENT_RELAY: '', WASM_AGENT_MANAGED: '0',
  WASM_AGENT_PROVIDER_RETRIES: '0', WA_SKIP_UPDATE_CHECK: '1',
  COLUMNS: '80', LINES: '40',
};

if (spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status !== 0) {
  console.log('SKIP test-tui-chrome-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const SOCKET = 'wa-tui-chrome-' + process.pid;
const SESSION = 'chrome';
const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], {encoding: 'utf8'});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const capture = () => String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '').split('\n');
async function waitFor(predicate, label, timeout = 60000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(100);
  }
}
// One SGR mouse report, written to the pane as the terminal would send it (1-based column, row).
const mouse = (button, col, row, up = false) =>
  tmux(['send-keys', '-t', SESSION, '-l', '\x1b[<' + button + ';' + col + ';' + row + (up ? 'm' : 'M')]);
const wheel = (upward, col, row) => mouse(upward ? 64 : 65, col, row);

// The input box on the screen: the rows between its two full-width rules (the last two on screen).
const RULE = /^─{20,}$/;
const BARS = new Set(['│', '┃', '█']);
function box(rows, width) {
  const rules = rows.map((row, index) => (RULE.test(row.trimEnd()) ? index : -1)).filter(index => index >= 0);
  if (rules.length < 2) return null;
  const [top, bottom] = rules.slice(-2);
  const body = rows.slice(top + 1, bottom);
  return {top, bottom, body, lines: body.map(row => (row.match(/line\d\d/) || [''])[0]),
    bars: body.filter(row => row.length >= width && BARS.has(row[width - 1])).length};
}
const transcriptRows = (rows, shape) => rows.slice(0, shape.top).map(row => row.slice(0, 79).trimEnd()).join('\n');

try {
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat', 'show me a snippet'].join(' ');
  tmux(['kill-server']);
  const started = tmux(['new-session', '-d', '-s', SESSION, '-x', '80', '-y', '40', command]);
  if (started.status !== 0) throw new Error('tmux could not start the session: ' + started.stderr);
  await waitFor(() => capture().some(row => /Done\./.test(row)), 'the answer to be drawn');
  await sleep(800);
  check('the fixture served the run (a run that reached any other endpoint proves nothing)', served >= 1,
    'requests served: ' + served);
  // ---- A. the input box ---------------------------------------------------------------------
  const before = capture();
  const empty = box(before, 80);
  check('an empty draft is a one-row box', empty && empty.body.length === 1, before.join('\n'));
  const DRAFT = Array.from({length: 40}, (_, i) => 'line' + String(i + 1).padStart(2, '0')).join('\n');
  tmux(['set-buffer', '-b', 'draft', DRAFT]);
  tmux(['paste-buffer', '-p', '-r', '-b', 'draft', '-t', SESSION]);
  await waitFor(() => capture().some(row => /line40/.test(row)), 'the pasted draft');
  await sleep(500);
  const pasted = capture();
  const grown = box(pasted, 80);
  check('40 lines in an 80x40 window: the box shows 12 rows (30% of 40)', grown && grown.body.length === 12,
    'rows: ' + (grown && grown.body.length) + '\n' + pasted.join('\n'));
  check('the cursor line (the last one) is visible, and the 12 rows are lines 29..40',
    grown && grown.lines[0] === 'line29' && grown.lines[grown.lines.length - 1] === 'line40', JSON.stringify(grown && grown.lines));
  check('every row of the box carries the scrollbar in the last column', grown && grown.bars === grown.body.length,
    'bar cells: ' + (grown && grown.bars) + '\n' + (grown ? grown.body.join('\n') : ''));
  check('the transcript sits right on top of the box, pinned to its bottom',
    grown && pasted.slice(Math.max(0, grown.top - 4), grown.top).some(row => /Done\./.test(row)), pasted.slice(0, grown ? grown.top : 0).join('\n'));
  check('the transcript gave up exactly the rows the box took', empty && grown && empty.top - grown.top === 11,
    'top rule before: ' + (empty && empty.top) + ', after: ' + (grown && grown.top));

  // The wheel over the box moves the draft, not the chat.
  const chatBefore = transcriptRows(pasted, grown);
  wheel(true, 10, grown.top + 3);
  wheel(true, 10, grown.top + 3);
  await sleep(600);
  const wheeled = capture();
  const moved = box(wheeled, 80);
  check('the wheel over the box scrolls the draft (two events up: lines 23..34)',
    moved && moved.body.length === 12 && moved.lines[0] === 'line23' && moved.lines[11] === 'line34', JSON.stringify(moved && moved.lines));
  check('and the transcript did not move', moved && transcriptRows(wheeled, moved) === chatBefore,
    transcriptRows(wheeled, moved || grown) + '\n---- was ----\n' + chatBefore);
  // The wheel over the transcript leaves the draft where it is.
  wheel(true, 10, 3);
  await sleep(500);
  const over = box(capture(), 80);
  check('the wheel over the transcript does not move the draft', over && over.lines[0] === 'line23', JSON.stringify(over && over.lines));
  wheel(false, 10, 3);
  // A key goes back to the cursor's line.
  tmux(['send-keys', '-t', SESSION, '-l', 'x']);
  await sleep(500);
  const typed = box(capture(), 80);
  check('a key brings the cursor line back into view', typed && /line40x/.test(typed.body[typed.body.length - 1]),
    typed ? typed.body.join('\n') : '');

  // A 12-row window: the limit is three rows again.
  tmux(['resize-window', '-t', SESSION, '-x', '80', '-y', '12']);
  await sleep(1500);
  const small = capture();
  const shrunk = box(small, 80);
  check('resized to 80x12 the box shows 3 rows', shrunk && shrunk.body.length === 3,
    'rows: ' + (shrunk && shrunk.body.length) + '\n' + small.join('\n'));
  check('and they are the last three lines, with the scrollbar', shrunk && shrunk.lines[2] === 'line40' && shrunk.bars === 3,
    shrunk ? shrunk.body.join('\n') : '');
} catch (error) {
  failed += 1;
  console.error('tui-chrome: FAILED - ' + error.message);
} finally {
  tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('tui-chrome: scratch kept for diagnosis: ' + WORK);
}

console.log('tui-chrome pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
