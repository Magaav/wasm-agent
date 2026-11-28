#!/usr/bin/env node
// A CHANGED LINE IS READABLE ON ITS BAND (Victor 23/11, the screenshot this mission came from).
//
// Item 3 of _queue/diff-card-reads-like-claude-code.md: "an added/removed row keeps its full contrast
// when the card is folded or unfocused (the screenshot's row was near-invisible)". The screenshot's row
// was unreadable because the BAND was painted as a FOREGROUND: the row's text was 38;2;18;48;28 on the
// terminal's black, a contrast ratio of 1.4:1. That is fixed (the band is a background now), and this
// row is the measurement that keeps it fixed - it reads the escape sequences a REAL terminal received
// and computes each changed row's own WCAG ratio, rather than trusting a palette table.
//
// MEASURED on main c7f5c8a (this file's base), default theme, 100x44 pty:
//   * added row   bg 48;2;18;48;28  (toolDiffAddedBand)   fg 38;2;78;186;101 (toolDiffAdded)  6.3:1
//   * removed row bg 48;2;58;22;32  (toolDiffRemovedBand) fg 38;2;255;107;128 (toolDiffRemoved) 5.8:1
//   * a COMMENT inside an added row: fg 38;2;106;153;85 (syntaxComment) on the added band - 4.30:1,
//     under the 4.5:1 that plain body text needs. That is what this row reds on before the fix.
//
// What it checks, all read off the screen:
//   1. the band of a changed row is a BACKGROUND, never a foreground (the screenshot's defect);
//   2. the row's own role is the foreground of its marker and of the code that has no syntax colour;
//   3. every glyph on a banded row clears 4.5:1 against the band it is drawn on - the row's role, the
//      syntax colours, and the count row's numbers alike (the frame's two glyphs are structural and
//      are held to 3:1, which is what a non-text contrast rule asks of a frame);
//   4. none of it is drawn faint (`ESC[2m`), which would dim a row to grey without changing its colour;
//   5. an OLDER card - one that is no longer the newest block - keeps its bands and its ratios: this is
//      the "folded or unfocused" half of the item, measured after another turn has been drawn below it.
//
// Isolation is scripts/test-diff-card-pty.mjs's, unchanged: a private tmux server, `env -i` plus an
// allow-list, a scratch HOME that refuses to be the real ~/.wasm-agent, and a local SSE fixture that
// plays the model. Run: WA_BIN=<wa binary> node scripts/test-diff-card-contrast-pty.mjs
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
  console.error('diff-card-contrast-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wd-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('diff-card-contrast-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: a file whose changed line CARRIES A COMMENT ----------------------------------
// The comment is the point: `syntaxComment` is the darkest colour a body row can hold, so it is the
// pair that decides whether the band is light enough to read on. The update changes the comment on
// line 1, so one removed row and one added row both hold one.
const TARGET = path.join(WORK, 'demo.py');
const OTHER = path.join(WORK, 'other.py');
const lines = note => Array.from({length: 10}, (_, i) =>
  'line_' + String(i + 1).padStart(2, '0') + ' = ' + (i + 1) + (i === 0 ? '  # ' + note : '')).join('\n') + '\n';
const FIRST = lines('old note');
const SECOND = lines('new note');
const THIRD = 'alpha = 1\nbeta = 2\n';
const PLAN = [
  {final: 'created the demo file', calls: [['write', () => ({path: TARGET, content: FIRST})]]},
  {final: 'changed the note', calls: [['write', () => ({path: TARGET, content: SECOND})]]},
  {final: 'wrote another file', calls: [['write', () => ({path: OTHER, content: THIRD})]]},
];
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
  console.log('SKIP test-diff-card-contrast-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const SESSION = 'dcontrast';
const {tmux, killServer} = tmuxSession('wa-diff-card-contrast-pty');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const screen = () => capture().join('\n');
// The same rows WITH the escape sequences the terminal received: what a colour is checked against.
function coloured() {
  const raw = String(tmux(['capture-pane', '-p', '-e', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n');
}
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

// ---- the palette, as the palette table states it (lua/core/cli_view.lua THEME) ------------------
// Read from the file rather than hard-coded here, so this row cannot disagree with the thing it is
// checking: the colours it compares against are the colours the view is built from.
function role(name) {
  const source = fs.readFileSync(path.join(REPO, 'lua/core/cli_view.lua'), 'utf8');
  const found = new RegExp('\\b' + name + ' = "([0-9a-fA-F]{6})"').exec(source);
  if (!found) throw new Error('cli_view.lua names no role ' + name);
  return found[1].toLowerCase();
}
const hexToRgb = hex => [0, 2, 4].map(at => parseInt(hex.slice(at, at + 2), 16));
const triple = (prefix, hex) => { const [r, g, b] = hexToRgb(hex); return prefix + ';2;' + r + ';' + g + ';' + b; };

// WCAG 2.x relative luminance and ratio: the arithmetic a reader's eye is measured with.
function luminance([r, g, b]) {
  const line = value => {
    const c = value / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * line(r) + 0.7152 * line(g) + 0.0722 * line(b);
}
function ratio(fg, bg) {
  const a = luminance(fg), b = luminance(bg);
  const [hi, lo] = a > b ? [a, b] : [b, a];
  return (hi + 0.05) / (lo + 0.05);
}

// ---- one row of the screen, as runs of text each carrying its own fg and bg --------------------
// The pty's own defaults are used for a cell that no SGR has coloured yet: the terminal this runs in
// draws on black, and the fixture sets nothing else, so black is the background a reader sees.
const BLACK = [0, 0, 0], WHITE = [255, 255, 255];
function runs(row) {
  const out = [];
  let fg = WHITE, bg = BLACK, faint = false;
  let at = 0;
  const text = [];
  while (at < row.length) {
    const esc = row.indexOf('\u001b', at);
    if (esc < 0) { text.push(row.slice(at)); break; }
    if (esc > at) text.push(row.slice(at, esc));
    const end = row.indexOf('m', esc);
    if (end < 0) break;
    const body = row.slice(esc + 2, end);
    const parts = body.split(';').map(Number);
    for (let i = 0; i < parts.length; i += 1) {
      const code = parts[i];
      if (code === 0) { fg = WHITE; bg = BLACK; faint = false; }
      else if (code === 2) faint = true;
      else if (code === 22) faint = false;
      else if (code === 39) fg = WHITE;
      else if (code === 49) bg = BLACK;
      else if (code === 38 && parts[i + 1] === 2) { fg = parts.slice(i + 2, i + 5); i += 4; }
      else if (code === 48 && parts[i + 1] === 2) { bg = parts.slice(i + 2, i + 5); i += 4; }
    }
    // Everything written before this sequence is carried by the state that was current for it.
    if (text.length) { out.push({text: text.join(''), fg: out.length ? out[out.length - 1].fg : null}); text.length = 0; }
    out.push({mark: true, fg: fg.slice(), bg: bg.slice(), faint});
    at = end + 1;
  }
  if (text.length) out.push({text: text.join('')});
  // Rebuild as runs: each printable chunk takes the state of the mark that precedes it.
  const shaped = [];
  let current = {fg: WHITE, bg: BLACK, faint: false};
  for (const piece of out) {
    if (piece.mark) { current = {fg: piece.fg, bg: piece.bg, faint: piece.faint}; continue; }
    if (piece.text) shaped.push({text: piece.text, fg: current.fg, bg: current.bg, faint: current.faint});
  }
  return shaped;
}
const hex = ([r, g, b]) => [r, g, b].map(v => v.toString(16).padStart(2, '0')).join('');

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
  await sleep(300);
}

// The banded rows of the screen, with the ratio each glyph is actually drawn at.
function banded(rows) {
  const addedBand = triple('48', role('toolDiffAddedBand'));
  const removedBand = triple('48', role('toolDiffRemovedBand'));
  const found = [];
  for (const row of rows) {
    const pieces = runs(row);
    for (const piece of pieces) {
      const band = triple('48', hex(piece.bg));
      if (band !== addedBand && band !== removedBand) continue;
      const text = piece.text.replace(/\s+/g, ' ').trim();
      if (text === '' || text === '\u2502') continue;
      found.push({kind: band === addedBand ? 'added' : 'removed', text, fg: hex(piece.fg), bg: hex(piece.bg),
        ratio: ratio(piece.fg, piece.bg), faint: piece.faint});
    }
  }
  return found;
}

let exitCode = 0;
try {
  launch();
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  // ---- turn 1: a file with a comment on its first line is created -------------------------------
  await ask('create the demo file', PLAN[0].final);
  check('the create card is drawn', screen().includes('Create(demo.py)'), screen());

  // ---- turn 2: the comment changes, so one removed row and one added row both hold one ----------
  await ask('change the note', PLAN[1].final);
  const update = screen();
  check('the update card is drawn', update.includes('Update(demo.py)'), update);

  const bands = banded(coloured());
  const added = bands.filter(piece => piece.kind === 'added');
  const removed = bands.filter(piece => piece.kind === 'removed');
  check('the added rows are on the added band', added.length > 0, JSON.stringify(bands, null, 1));
  check('the removed row is on the removed band', removed.length > 0, JSON.stringify(bands, null, 1));

  // 1. THE SCREENSHOT'S DEFECT: the band must never be a foreground. If the band's own triple showed
  //    up as `38;2;…`, the row's text would BE the band - near-invisible on black, which is what
  //    Victor photographed on 5956ae15.
  const asForeground = [triple('38', role('toolDiffAddedBand')), triple('38', role('toolDiffRemovedBand'))];
  const offenders = coloured().filter(row => asForeground.some(seq => row.includes(seq)));
  check('no row paints a band as its FOREGROUND', offenders.length === 0,
    offenders.map(row => row.split('\u001b').join('ESC')).join('\n'));

  // 2. Nothing is faint: a faint row keeps its colour and loses its weight, and a reader cannot tell
  //    why it went grey.
  const faints = bands.filter(piece => piece.faint);
  check('no banded glyph is drawn faint', faints.length === 0, JSON.stringify(faints, null, 1));

  // 3. THE MEASUREMENT: every glyph on a banded row clears 4.5:1 against the band under it. This is
  //    printed for every row, so the run doubles as the screenshot-equivalent capture the item asks
  //    for: the exact fg/bg pair and the ratio a reader's eye gets.
  // The frame's own glyph is structural, so it is held to the 3:1 a non-text element needs; every
  // other glyph on a banded row - the marker, the number, the code and its syntax colours - is text
  // and is held to 4.5:1.
  const isFrame = piece => piece.text.replace(/│/g, '').trim() === '';
  const weakFrame = bands.filter(piece => isFrame(piece) && piece.ratio < 3.0);
  check('the frame glyph on a banded row clears 3:1', weakFrame.length === 0,
    weakFrame.map(piece => piece.text + ' -> ' + piece.ratio.toFixed(2) + ':1').join('\n'));
  const weak = bands.filter(piece => !isFrame(piece) && piece.ratio < 4.5);
  for (const piece of bands) {
    console.log('     ' + piece.kind.padEnd(7) + ' fg ' + piece.fg + ' on bg ' + piece.bg + '  ' +
      piece.ratio.toFixed(2) + ':1  ' + JSON.stringify(piece.text.slice(0, 48)));
  }
  check('every changed glyph clears 4.5:1 on its band', weak.length === 0,
    weak.map(piece => piece.kind + ' ' + piece.text.slice(0, 40) + ' -> ' + piece.ratio.toFixed(2) + ':1  fg ' +
      piece.fg + ' on ' + piece.bg).join('\n'));

  // The comment is the darkest body colour a changed row can carry, so name it: a row that reads only
  // because its line holds no comment is not a row that reads.
  const comment = bands.find(piece => piece.text.includes('#'));
  check('a changed line that carries a comment is measured too', Boolean(comment), JSON.stringify(bands, null, 1));

  // ---- turn 3: another file, so the update card is no longer the newest block -------------------
  await ask('write another file', PLAN[2].final);
  const later = banded(coloured());
  const laterAdded = later.filter(piece => piece.kind === 'added');
  const laterRemoved = later.filter(piece => piece.kind === 'removed');
  check('the older card keeps its added band', laterAdded.length > 0, JSON.stringify(later, null, 1));
  check('the older card keeps its removed band', laterRemoved.length > 0, JSON.stringify(later, null, 1));
  const laterWeak = later.filter(piece => !isFrame(piece) && piece.ratio < 4.5);
  check('an older card still clears 4.5:1 on every changed glyph', laterWeak.length === 0,
    laterWeak.map(piece => piece.kind + ' ' + piece.text.toString().slice(0, 40) + ' -> ' + piece.ratio.toFixed(2) + ':1').join('\n'));
  check('and nothing dims it: the same ratio as when it was newest',
    laterAdded.every(piece => piece.fg !== '777777' && piece.fg !== '999999'),
    JSON.stringify(laterAdded.slice(0, 4), null, 1));
} catch (error) {
  failed += 1;
  console.log('FAIL - the run threw: ' + (error && error.message ? error.message : error));
  console.log(screen());
} finally {
  if (started) killServer();
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
}

console.log('\ndiff card contrast pty: ' + checks + ' ok, ' + failed + ' failed');
if (failed > 0) exitCode = 1;
process.exit(exitCode);
