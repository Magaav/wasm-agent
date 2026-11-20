#!/usr/bin/env node
// A FENCED CODE CARD STAYS WHOLE AT ANY WIDTH (change/fence-card, PHASE 0).
//
// Victor 19/11 (screenshot ~/Work/missions/tui-polish-3/fence-broken-2026-11-19.png): a card laid
// out at the width the chat had is re-wrapped by the HOST PROSE wrapper when it is drawn narrower -
// a focused topic is boxed two columns in, and a resize redraws at the new width. The prose
// wrapper breaks at a space, and the space after the card bar is a space: the code line loses its
// bar and the bar is left alone on a row of its own.
//
// This drives the REAL path, never a fake: a real wa process in a real pty (a PRIVATE tmux
// server), a local SSE provider answering with a markdown answer that holds the cards, and the
// screen read back with tmux capture-pane. It cannot reach a model, a relay or the operator vault:
//
//   * tmux runs on a private socket (-L), so it never inherits the environment of the operator own
//     tmux server - the leak that put the live vault URL in front of an earlier probe (19/11);
//   * the child gets env -i plus an explicit allow-list: no WASM_AGENT_VAULT_URL, no inherited key;
//   * it REFUSES to run when its scratch root is inside the real ~/.wasm-agent, and FAILS (never
//     passes) when the fixture served no request: a run that reached some other endpoint proves
//     nothing about this one.
//
// Run: WA_BIN=<wa binary> node scripts/test-fence-card-pty.mjs
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
  console.error('fence-card: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-fence-card-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('fence-card: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: one SSE answer per request, and a count the test insists on ----------------
const TICK = String.fromCharCode(96);
const FENCE = TICK + TICK + TICK;
const CODE = 'for f in a b c; do echo "one rather long line of shell here to push past the border"; done';
// A code line exactly as wide as the card holds at 100 columns (screen 100, card 98, bar + space 2).
const EXACT = 'e'.repeat(96);
const ANSWER = [
  'A paragraph above the cards, so a card is not the first thing in the block.',
  '',
  'An untagged card:',
  '',
  FENCE,
  'alpha',
  'beta with a much longer body that must keep its bar when the screen narrows',
  'gamma',
  FENCE,
  '',
  'An untagged ONE-LINE card (no language, one row):',
  '',
  FENCE,
  'untagged-one-line',
  FENCE,
  '',
  'A tagged one-line card:',
  '',
  FENCE + 'bash',
  CODE,
  FENCE,
  '',
  '- a card inside a list item:',
  '',
  '  ' + FENCE + 'js',
  '  const exact = "' + EXACT + '";',
  '  ' + FENCE,
  '',
  // A table small enough to fit at the narrowest width this test drives: a table is laid out at
  // compose width (markdown.lua), so a WIDER one is prose-wrapped on a shrink - a pre-existing rule
  // this change must not touch, and not something this test can read a card frame out of.
  'A table, painted with the same border role and never cut as a card:',
  '',
  '| head a | head b |',
  '| --- | --- |',
  '| cell one | cell two |',
  
  'Done.',
].join('\n');

let served = 0;
const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    served += 1;
    const usage = {prompt_tokens: 100, completion_tokens: 50, total_tokens: 150};
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    const chunks = [
      {id: 'fence-1', choices: [{index: 0, delta: {role: 'assistant', content: ANSWER}, finish_reason: null}]},
      {id: 'fence-1', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: 'fence-1', choices: [], usage},
    ];
    for (const chunk of chunks) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

// The child whole environment, written out. Nothing is inherited: the vault URL that won over the
// fixture in the 19/11 probe is a variable of the operator shell, and env -i is what removes it.
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
  COLUMNS: '100',
  LINES: '40',
};

// ---- can this machine run the test at all ------------------------------------------------------
// The screen is read back from a real pty, and tmux is the pty this test knows how to drive. A machine
// without it is not a machine that failed: it is one that cannot answer, so the test SKIPS BY NAME and
// exits 0 (the fast path prints the row as a skip and counts it as a skip, never a pass).
const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-fence-card-pty: no tmux on PATH, and this test reads a real pty through it ' +
    '(install tmux; a browser-less or container node has none)');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const SOCKET = 'wa-fence-card-' + process.pid;
const SESSION = 'fence';
const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], {encoding: 'utf8'});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function capture() {
  return String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
}
// The whole scrollback, banner included: a big answer scrolls the banner off the visible pane, and the
// isolation checks are about what the process was TOLD, not about what still fits on screen.
function captureAll() {
  return String(tmux(['capture-pane', '-p', '-S', '-2000', '-t', SESSION]).stdout || '').replace(/\r/g, '');
}
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

// ---- what a card row must look like on the screen --------------------------------------------
// The transcript draws a scrollbar in the LAST column of every row, so a blank chat row reads as
// spaces and a bar. It is not a card row and never was: the scrollbar column comes off first.
const BAR = '\u2502';
const SCROLLBAR = new Set(['\u2502', '\u2503']);
function stripScrollbar(row) {
  const text = row.replace(/\s+$/, '');
  if (text === '') return '';
  return SCROLLBAR.has(text[text.length - 1]) ? text.slice(0, -1) : text;
}
// A CARD row: after any list indent, it opens with the card bar.
const barRow = row => new RegExp('^\\s*' + BAR).test(stripScrollbar(row));
// The screenshot row: a bar with nothing after it.
const emptyBar = rows => rows.filter(row => new RegExp('^\\s*' + BAR + '\\s*$').test(stripScrollbar(row)));
// A card code line drawn WITHOUT its bar - the defect this whole test exists for. The framing
// is what makes it checkable at every width and with every phrasing: every screen row BETWEEN
// a card open corner and its close corner must open with the bar. A row that does not is a
// card row the host re-wrapped as prose, whatever words it happens to carry.
// A card's frame, told apart from a TABLE's, which wears the same border role: a table rule carries a
// column divider or a closing corner (┬ ┼ ┴ ┐ ┘ ┤) and a table row ends in its own border bar.
// This is the same discriminator the host uses (transcript.rs card_edge) - a check that could not tell
// them apart would report a table as a broken card.
const OPEN = /^\s*\u250c[^\u252c\u2510]*$/;
const CLOSE = /^\s*\u2514[^\u2534\u2518]*$/;
function tableRow(text) {
  const body = text.replace(/\s+$/, '');
  return /^\s*\u2502/.test(body) && body.endsWith('\u2502') && !/^\s*\u2502\s*\u2502?\s*$/.test(body);
}
function cardInteriorOrphans(rows) {
  const found = [];
  let open = false;
  for (const row of rows) {
    const text = stripScrollbar(row);
    if (OPEN.test(text)) { open = true; continue; }
    if (CLOSE.test(text)) { open = false; continue; }
    if (!open || text.trim() === '') continue;
    if (tableRow(text)) { open = false; continue; }
    if (!barRow(text)) found.push(row);
  }
  return found;
}
// The named lines, as a second net: a check that stopped finding the frame cannot pass as clean.
const orphans = (rows, pattern) => rows.filter(row => pattern.test(stripScrollbar(row)) && !barRow(row));

try {
  const command = [
    'env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat', 'draw the cards',
  ].join(' ');
  tmux(['kill-server']);
  const started = tmux(['new-session', '-d', '-s', SESSION, '-x', '100', '-y', '40', command]);
  if (started.status !== 0) throw new Error('tmux could not start the session: ' + started.stderr);

  // The banner FIRST: a long answer scrolls the chat region, and the rows the process was told about
  // are gone from the pane once it has. Read them while they are still the only thing on screen.
  // The whole scrollback, not the visible pane and not its first rows: the chat region is
  // bottom-anchored, so the welcome banner sits under the blank rows above it, and a long answer
  // scrolls it out of the region entirely.
  const banner = () => captureAll();
  await waitFor(() => /memory:/.test(banner()), 'the welcome banner');
  const welcome = banner();
  check('the banner names the fixture endpoint, not a vault route', welcome.includes('127.0.0.1:' + PORT),
    welcome);
  // The banner shortens a long path with a trailing ellipsis (a fast-path scratch under a long TMPDIR
  // is ~120 characters and the pane is 100 wide), so the full WORK path is only there when it fits.
  // What this check is about is unchanged: the `memory:` value is the scratch ledger - all of it, or a
  // prefix of it at least 60 characters long (or the whole scratch root when that is shorter), the banner
  // keeping ~90 - and never anything under the real home.
  const shown = ((welcome.match(/memory:\s*(\S+)/) || [])[1] || '').replace(/…$/, '');
  const ledger = path.join(WORK, 'ledger.db');
  check('the ledger is in the scratch root, not in the real home',
    shown.length >= Math.min(SCRATCH_ROOT.length, 60) && ledger.startsWith(shown) && !shown.startsWith(REAL_HOME + path.sep),
    'memory: ' + shown + '\nexpected (a prefix of): ' + ledger + '\n' + welcome);
  check('the banner names no vault route', !/VAULT_URL|:8810/.test(welcome),
    (welcome.match(/.*(VAULT|:8810).*/g) || []).join('\n'));

  await waitFor(() => /Done\./.test(capture()), 'the answer to be drawn');
  await sleep(800);

  check('the fixture served the run (a run that reached any other endpoint proves nothing)', served >= 1,
    'requests served: ' + served);
  const head = capture();

  const rows = head.split('\n');
  check('the cards are drawn', rows.filter(barRow).length >= 4, rows.filter(barRow).join('\n'));
  check('at 100 columns no row is an empty bar (the screenshot row)', emptyBar(rows).length === 0, emptyBar(rows).join('\n'));
  const brokenLong = orphans(rows, /here to push past the border/);
  check('at 100 columns the long tagged code line keeps its bar', brokenLong.length === 0, brokenLong.join('\n'));
  const brokenBeta = orphans(rows, /beta with a much longer body/);
  check('at 100 columns the untagged card long line keeps its bar', brokenBeta.length === 0, brokenBeta.join('\n'));
  check('at 100 columns the untagged one-line card is drawn with its bar',
    rows.some(row => barRow(row) && stripScrollbar(row).includes('untagged-one-line')),
    rows.filter(barRow).join('\n'));

  // ---- the widths the brief names, and the shrink of ten columns ------------------------------
  for (const columns of [80, 60, 90, 120]) {
    if (columns === 90) tmux(['resize-window', '-t', SESSION, '-x', '100', '-y', '40']);
    tmux(['resize-window', '-t', SESSION, '-x', String(columns), '-y', '40']);
    await sleep(1400);
    const screen = capture().split('\n');
    const shown = screen.filter(row => stripScrollbar(row).trim() !== '').join('\n');
    check('at ' + columns + ' columns no row is an empty bar', emptyBar(screen).length === 0, shown);
    check('at ' + columns + ' columns the card is still drawn', screen.some(barRow), shown);
    const lost = cardInteriorOrphans(screen);
    check('at ' + columns + ' columns every row inside a card keeps its bar', lost.length === 0,
      'orphans: ' + JSON.stringify(lost) + '\n' + shown);
    const named = orphans(screen, /(push past the border|much longer body|alpha|gamma)/);
    check('at ' + columns + ' columns no card code line is drawn outside its card', named.length === 0,
      'outside: ' + JSON.stringify(named) + '\n' + shown);
  }
  // A focused block is boxed two columns in, which is the width that broke the card - but a fence
  // lands in the ANSWER block and only a tool call or a thought is a topic, so nothing in this
  // answer can be focused. That path is covered by the Rust test
  // a_focused_card_is_cut_two_columns_narrower, which boxes the same card at width-2 through the
  // real rows_with_copies.
  console.log('\n---- the screen at 120 columns ----\n' + capture());
} catch (error) {
  failed += 1;
  console.error('fence-card: FAILED - ' + error.message);
} finally {
  tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('fence-card: scratch kept for diagnosis: ' + WORK);
}

console.log('fence-card pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
