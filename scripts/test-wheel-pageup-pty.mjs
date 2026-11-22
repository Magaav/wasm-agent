#!/usr/bin/env node
// THE WHEEL AND PageUp MOVE THE TRANSCRIPT THE SAME WAY (change/wheel-like-pageup, Victor 22/11):
//
//   "scroll with mouse should behave exactly the same as pg up pg down from keyboard (which is
//    correct), same amount of scroll from both endings."
//
// Read from a REAL pty, over a transcript several screens long:
//   A. three notches up from the bottom and three PageUps show the same first row (one notch = one
//      page), and both differ from the row the reader came from;
//   B. driven past the top, both stop on the same first row - the chat's own first row, with the
//      answer's first line on screen - and one more step of either moves neither, so neither can
//      reach a row the other cannot;
//   C. back down, both end where the transcript resumes following the newest output: the newest row
//      on screen and nothing below it (the "N more lines" hint gone).
//
// WHY C IS READ OFF THE SCREEN AND NOT DRIVEN BY A NEW ANSWER: submitting syncs the transcript to
// the bottom itself (host.rs, the Submit arm calls to_bottom), so a submit proves nothing about how
// the reader got home. What "at the bottom" means is the transcript's own rule (transcript.rs: a view
// whose first row is the bottom row, outside navigation, drops its freeze and follows again).
//
// Same isolation as scripts/test-tui-chrome-pty.mjs: the real binary in a PRIVATE tmux server, a
// local SSE fixture that must have served the run, env -i with an allow-list, and a scratch HOME that
// refuses to be the real one. Run: WA_BIN=<wa binary> node scripts/test-wheel-pageup-pty.mjs
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
// This node's TMPDIR points INTO ~/.wasm-agent/tmp, so os.tmpdir() alone would put the ledger and the
// fixture beside real state - which the guard below then (correctly) refuses.
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('wheel-pageup: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-wheel-pageup-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('wheel-pageup: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: one answer several screens long ---------------------------------------------
// Every row is a list item, so it is ONE row of the transcript (prose lines are re-flowed together)
// and it carries a number that names it wherever the reader has scrolled to.
const ROWS = 180;
const rowLine = n => '- row' + String(n).padStart(3, '0') + ' the quick brown fox';
let served = 0;
const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    served += 1;
    const lines = [];
    for (let n = 1; n <= ROWS; n += 1) lines.push(rowLine(n));
    lines.push('TAIL-' + served);
    const usage = {prompt_tokens: 100, completion_tokens: 50, total_tokens: 150};
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    const chunks = [
      {id: 'wheel-' + served, choices: [{index: 0, delta: {role: 'assistant', content: lines.join('\n')}, finish_reason: null}]},
      {id: 'wheel-' + served, choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: 'wheel-' + served, choices: [], usage},
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
  // The opening (Victor 22/11) is measured by its own row (WA_BIN=... cargo test -p wa-term --test
  // opening, and scripts/test-opening.lua); this file drives `wa chat` for something else and should
  // not pay two seconds of animation before the screen it reads.
  WASM_AGENT_CLI_OPENING: 'off',
  COLUMNS: '80', LINES: '40',
};

if (spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status !== 0) {
  console.log('SKIP test-wheel-pageup-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const SOCKET = 'wa-wheel-pageup-' + process.pid;
const SESSION = 'wheel';
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
// One mouse report, written to the pane as the terminal would send it (1-based column, row).
const mouse = (button, col, row, up = false) =>
  tmux(['send-keys', '-t', SESSION, '-l', '\x1b[<' + button + ';' + col + ';' + row + (up ? 'm' : 'M')]);
const wheelNotch = up => mouse(up ? 64 : 65, 20, 3);
// The keyboard's own sequences, byte for byte (wa_term::keymap: PageUp \x1b[5~, PageDown \x1b[6~,
// Ctrl+PageDown \x1b[6;5~ = back to the live bottom).
const key = seq => tmux(['send-keys', '-t', SESSION, '-l', seq]);
const PAGE_UP = '\x1b[5~';
const PAGE_DOWN = '\x1b[6~';
const BOTTOM = '\x1b[6;5~';
// The input box on the screen: the rows between its two full-width rules (the last two on screen).
const RULE = /^─{20,}$/;
function box(rows) {
  const rules = rows.map((row, index) => (RULE.test(row.trimEnd()) ? index : -1)).filter(index => index >= 0);
  if (rules.length < 2) return null;
  const [top, bottom] = rules.slice(-2);
  return {top, bottom, body: rows.slice(top + 1, bottom)};
}
// What the reader sees: the transcript above the box, its first drawn row, the rows below the
// newest one (the "N more lines" hint), and whether the newest row is on screen.
function view() {
  const rows = capture();
  const shape = box(rows);
  if (!shape) throw new Error('no input box on screen:\n' + rows.join('\n'));
  const transcript = rows.slice(0, shape.top).map(row => row.slice(0, 79).trimEnd());
  const nonBlank = transcript.filter(row => row.length > 0);
  return {rows, shape, transcript, nonBlank, top: nonBlank[0] || '',
    hint: nonBlank.some(row => /more lines/.test(row)),
    hasRow: n => transcript.some(row => row.includes('row' + String(n).padStart(3, '0') + ' ')),
    hasTail: () => transcript.some(row => /^\s*TAIL-\d+\s*$/.test(row) || /TAIL-\d+/.test(row))};
}
async function settle(ms = 700) { await sleep(ms); return view(); }
async function notches(up, count) {
  for (let n = 0; n < count; n += 1) wheelNotch(up);
  return settle(500 + count * 40);
}
async function pages(seq, count) {
  for (let n = 0; n < count; n += 1) key(seq);
  return settle(500 + count * 40);
}
const tick = v => v.transcript.join('\n');

try {
  const command = ['env', '-i', ...Object.entries(ENV).map(([k, v]) => k + '=' + v),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat', 'read the list'].join(' ');
  tmux(['kill-server']);
  const started = tmux(['new-session', '-d', '-s', SESSION, '-x', '80', '-y', '40', command]);
  if (started.status !== 0) throw new Error('tmux could not start the session: ' + started.stderr);
  await waitFor(() => capture().some(row => /TAIL-1/.test(row)), 'the answer to be drawn');
  const bottom = await settle();

  check('the fixture served the run (a run that reached any other endpoint proves nothing)', served >= 1,
    'requests served: ' + served);
  check('the transcript is several screens long, its newest row on screen and nothing below it',
    bottom.transcript.filter(row => /row\d{3}/.test(row)).length >= 30 && bottom.hasTail() && !bottom.hint,
    tick(bottom));

  // ---- A. one wheel notch = one PageUp --------------------------------------------------------
  const fromBottom = bottom.top;
  const afterPages = await pages(PAGE_UP, 3);
  await pages(BOTTOM, 1);
  const back = await view();
  check('the Ctrl+PageDown that starts the second reading really goes back to the bottom',
    back.hasTail() && !back.hint && back.top === fromBottom,
    'top row now: ' + JSON.stringify(back.top) + ', was ' + JSON.stringify(fromBottom));
  const afterWheel = await notches(true, 3);
  check('three notches up show the same first row as three PageUps (one notch = one page)',
    afterPages.top === afterWheel.top && afterPages.top !== fromBottom,
    'PageUp x3: ' + JSON.stringify(afterPages.top) + '\n       wheel x3: ' + JSON.stringify(afterWheel.top) +
    '\n       bottom before both: ' + JSON.stringify(fromBottom));

  // ---- B. the same top, and neither goes past it ----------------------------------------------
  // 20 steps: more than the rows between the bottom and the chat's first row (154 in an 80x40
  // window) at one page a step, and only 60 of them at the three-row step this change removes.
  const pagesTop = await pages(PAGE_UP, 20);
  const pagesAgain = await pages(PAGE_UP, 1);
  await pages(BOTTOM, 1);
  const wheelTop = await notches(true, 20);
  const wheelAgain = await notches(true, 1);
  check('driven past the top, both stop on the same first row',
    pagesTop.top === wheelTop.top,
    'PageUp x20: ' + JSON.stringify(pagesTop.top) + '\n       wheel x20: ' + JSON.stringify(wheelTop.top));
  check('and one more step of either moves neither (the wheel reaches no row PageUp cannot)',
    pagesAgain.top === pagesTop.top && wheelAgain.top === wheelTop.top,
    'PageUp then PageUp: ' + JSON.stringify(pagesTop.top) + ' -> ' + JSON.stringify(pagesAgain.top) +
    '\n       wheel then wheel: ' + JSON.stringify(wheelTop.top) + ' -> ' + JSON.stringify(wheelAgain.top));
  check('the row they stop on is the chat\'s first (the answer\'s own first line is on that screen)',
    pagesTop.hasRow(1) && wheelTop.hasRow(1),
    'top row, wheel: ' + JSON.stringify(wheelTop.top) + '\n       top row, PageUp: ' + JSON.stringify(pagesTop.top) +
    '\n       first line on screen: wheel ' + wheelTop.hasRow(1) + ', PageUp ' + pagesTop.hasRow(1));

  // ---- C. back down: both end at the bottom, where following resumes --------------------------
  // Both readings start at home (the bottom), so the eight steps up are the same eight rows.
  await pages(BOTTOM, 1);
  const wheelUp = await notches(true, 8);
  check('eight notches up leave the newest row behind (the view really is scrolled back)',
    !wheelUp.hasTail() && wheelUp.hint,
    'hint: ' + wheelUp.hint + ', tail on screen: ' + wheelUp.hasTail() + '\n' + tick(wheelUp));
  const wheelHome = await notches(false, 8);
  check('eight notches down come home: the newest row on screen and nothing below it',
    wheelHome.hasTail() && !wheelHome.hint,
    'hint: ' + wheelHome.hint + '\n' + tick(wheelHome));
  const wheelUpAgain = await notches(true, 8);
  check('eight notches up again land on the same row (one notch, one step, both ways)',
    wheelUpAgain.top === wheelUp.top,
    'up: ' + JSON.stringify(wheelUp.top) + '\n       up again: ' + JSON.stringify(wheelUpAgain.top));
  const pagesHome = await pages(PAGE_DOWN, 8);
  check('PageDown from the same place ends where the wheel did, row for row',
    pagesHome.top === wheelHome.top && pagesHome.hasTail() && !pagesHome.hint,
    'wheel\'s way home: ' + JSON.stringify(wheelHome.top) + '\n       PageDown\'s way home: ' + JSON.stringify(pagesHome.top) +
    '\n       hint: ' + pagesHome.hint);
} catch (error) {
  failed += 1;
  console.error('wheel-pageup: FAILED - ' + error.message);
} finally {
  tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('wheel-pageup: scratch kept for diagnosis: ' + WORK);
}

console.log('wheel-pageup pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
