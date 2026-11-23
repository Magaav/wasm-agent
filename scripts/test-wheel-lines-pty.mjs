#!/usr/bin/env node
// THE WHEEL MOVES THE CHAT LINE BY LINE (change/wheel-scrolls-lines, Victor 22/11 20:30Z):
//
//   "the mouse scroll on TUI chat content is jumping way further than the pg up/down which ticks
//    1/3 of the content by each tick" ... "scroll from mouse should scroll line by line".
//
// This REPLACES the wish it was built on one round earlier (change/wheel-like-pageup: one notch =
// one PageUp). A terminal sends SEVERAL mouse reports for one notch - foot multiplies them by its
// scrollback `multiplier` (7.0 in the operator's foot.ini) - so one row per report is one notch of
// seven lines, and a page per report was more than two screens.
//
// Read from a REAL pty, over a transcript several screens long whose every row carries a number:
//   A. ONE mouse report moves the chat ONE row (not a page);
//   B. a foot notch, seven reports as foot sends with multiplier=7.0, moves seven rows - and that is
//      not the distance PageUp moves, which is still a third of the chat's rows;
//   C. driven past the top the wheel stops on the chat's own first row and one more report moves
//      nothing, so it can reach no row the keys cannot;
//   D. as many reports down as up come home: the newest row on screen, nothing below it (the
//      "N more lines" hint gone), and the same first row the reader started on.
//
// WHY D IS READ OFF THE SCREEN AND NOT DRIVEN BY A NEW ANSWER: submitting syncs the transcript to
// the bottom itself (host.rs, the Submit arm calls to_bottom), so a submit proves nothing about how
// the reader got home. What "at the bottom" means is the transcript's own rule (transcript.rs: a view
// whose first row is the bottom row, outside navigation, drops its freeze and follows again).
//
// Same isolation as scripts/test-tui-chrome-pty.mjs: the real binary in a PRIVATE tmux server, a
// local SSE fixture that must have served the run, env -i with an allow-list, and a scratch HOME that
// refuses to be the real one. Run: WA_BIN=<wa binary> node scripts/test-wheel-lines-pty.mjs
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

// ---- the isolation this test lives or dies by ------------------------------------------------
// This node's TMPDIR points INTO ~/.wasm-agent/tmp, so os.tmpdir() alone would put the ledger and the
// fixture beside real state - which the guard below then (correctly) refuses.
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('wheel-lines: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-wheel-lines-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('wheel-lines: refusing to run with HOME inside the real ' + REAL_HOME);
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
  console.log('SKIP test-wheel-lines-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const {tmux} = tmuxSession('wa-wheel-lines');   // this process's own server, killed on every exit path
const SESSION = 'wheel';
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
const wheelUp = () => mouse(64, 20, 3);
const wheelDown = () => mouse(65, 20, 3);
// The keyboard's own sequences, byte for byte (wa_term::keymap: PageUp \x1b[5~, PageDown \x1b[6~,
// Ctrl+PageDown \x1b[6;5~ = back to the live bottom).
const key = seq => tmux(['send-keys', '-t', SESSION, '-l', seq]);
const PAGE_UP = '\x1b[5~';
const BOTTOM = '\x1b[6;5~';
// FOOT'S NOTCH: the operator's foot.ini has [scrollback] multiplier=7.0, and foot multiplies mouse
// scrolling by it while the app is on the normal screen (wa chat never enters the alternate one), so
// one notch is SEVEN of the reports below - the number a reader's one turn of the wheel sends.
const NOTCH = 7;
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
// The number of the fixture row at the top of the chat, which is how far a scroll went.
function topRow(v) {
  const row = v.transcript.find(line => /row\d{3}/.test(line));
  const found = row && /row(\d{3})/.exec(row);
  return found ? Number(found[1]) : null;
}
async function settle(ms = 700) { await sleep(ms); return view(); }
async function reports(up, count) {
  for (let n = 0; n < count; n += 1) { if (up) wheelUp(); else wheelDown(); }
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
  const home = topRow(bottom);
  const chat = bottom.transcript.length;
  check('the chat has rows to scroll through and a numbered first row on screen',
    typeof home === 'number' && chat > 10, 'first row: ' + home + ', chat rows on screen: ' + chat);

  // ---- A. ONE report is ONE row ---------------------------------------------------------------
  wheelUp();
  const one = await settle();
  check('one mouse report moves the chat ONE row (Victor: "scroll from mouse should scroll line by line")',
    topRow(one) === home - 1,
    'one report: ' + JSON.stringify(one.top) + ' (row ' + topRow(one) + '), the bottom was row ' + home);

  // ---- B. a foot notch is seven rows, and PageUp is still a third ------------------------------
  await pages(BOTTOM, 1);
  const notch = await reports(true, NOTCH);
  check('a foot notch (' + NOTCH + ' reports, multiplier=7.0) moves the chat ' + NOTCH + ' rows, not screens',
    topRow(notch) === home - NOTCH,
    'a notch: ' + JSON.stringify(notch.top) + ' (row ' + topRow(notch) + '), expected row ' + (home - NOTCH));
  await pages(BOTTOM, 1);
  const page = await pages(PAGE_UP, 1);
  const step = Math.max(1, Math.floor(chat / 3));
  check('PageUp still moves a third of the chat: ' + chat + ' rows on screen, ' + step + ' per press',
    topRow(page) === home - step,
    'PageUp: ' + JSON.stringify(page.top) + ' (row ' + topRow(page) + '), expected row ' + (home - step));
  check('a notch is not a page any more (that is the change this row was written for)',
    topRow(notch) !== topRow(page),
    'notch: row ' + topRow(notch) + ', PageUp: row ' + topRow(page));

  // ---- C. driven past the top: the chat's first row, and no further ---------------------------
  const top = await reports(true, ROWS + 40);
  const topAgain = await reports(true, 1);
  check('driven past the top, the wheel stops on the chat\'s own first row',
    top.hasRow(1), 'top row: ' + JSON.stringify(top.top) + '\n' + tick(top));
  check('and one more report moves nothing (the wheel reaches no row the keys cannot)',
    topAgain.top === top.top,
    'before: ' + JSON.stringify(top.top) + '\n       after: ' + JSON.stringify(topAgain.top));

  // ---- D. as many reports down as up come home ------------------------------------------------
  await pages(BOTTOM, 1);
  const up = await reports(true, 8);
  check('eight reports up leave the newest row behind (the view really is scrolled back)',
    !up.hasTail() && up.hint && topRow(up) === home - 8,
    'row: ' + topRow(up) + ', hint: ' + up.hint + ', tail on screen: ' + up.hasTail() + '\n' + tick(up));
  const back = await reports(false, 8);
  check('eight reports down come home: the newest row on screen and nothing below it',
    back.hasTail() && !back.hint,
    'hint: ' + back.hint + '\n' + tick(back));
  check('and home is the row it started on, following its newest output again',
    back.top === bottom.top,
    'home: ' + JSON.stringify(bottom.top) + '\n       back: ' + JSON.stringify(back.top));
} catch (error) {
  failed += 1;
  console.error('wheel-lines: FAILED - ' + error.message);
} finally {
  tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('wheel-lines: scratch kept for diagnosis: ' + WORK);
}

console.log('wheel-lines pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
