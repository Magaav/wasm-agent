#!/usr/bin/env node
// A RUN BOX AND A FENCE FOLLOW THE WINDOW, AND SAY IT THE SAME WAY (Victor 22/11, change/tui-reflow-blocks).
//
// What he saw in his own maximised window: the codeact box and the fenced code block stayed wrapped at
// the OLD width - a line cut at about half the new window stayed cut, with empty space to its right,
// while the prose around them reflowed - and the mark that says "this line goes on below" was drawn two
// ways (at the END of the cut row in the run box, at the START of the next row in the fence).
//
// Both blocks are now stored UNCUT and cut by the host at the width it draws the frame at. This drives
// the REAL binary in a real pty (a PRIVATE tmux server) against a local SSE fixture whose answer holds a
// ```bash card and a ```js run block - the two blocks of the brief - and reads the screen back at 120,
// 60, 120 and 60 columns: each block is whole and unmarked where it fits, cut with ONE mark in the LEFT
// GUTTER of the row the line goes on where it does not, and the second visit to a width draws exactly
// the rows the first one did.
//
// Isolation is scripts/test-fence-card-pty.mjs's, because the failure it prevents was measured there: a
// tmux on a private socket (-L), `env -i` plus an allow-list (no WASM_AGENT_VAULT_URL), a scratch HOME
// that REFUSES to be the real ~/.wasm-agent, and a FAILURE (never a pass) when the fixture served no
// request: a run that reached some other endpoint proves nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-reflow-blocks-pty.mjs
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
  console.error('reflow-blocks: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-reflow-blocks-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('reflow-blocks: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the two blocks ----------------------------------------------------------------------------
// The lines the fixture puts in the two blocks. Each must be LONGER than the narrowest width driven and
// SHORTER than the widest one, or the test would not be measuring what it says: asserted below, never
// assumed.
const FENCE_CODE = "sh -e <<'EOF' | while read -r line; do printf '%s\\n' \"$line\"; done | sort -u | head -20";
const BAND_CODE = "const r = await tools.bash({command: 'sh -e | sort -u | head -20 | wc -l'});";
const NARROW = 60;
const WIDE = 120;

const TICK = String.fromCharCode(96);
const FENCE = TICK + TICK + TICK;
const ANSWER = [
  'Two blocks, one of each kind, so a resize is judged on both.',
  '',
  FENCE + 'bash',
  FENCE_CODE,
  FENCE,
  '',
  'And the run block the model wrote, drawn on its band:',
  '',
  FENCE + 'js',
  BAND_CODE,
  FENCE,
  '',
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
      {id: 'reflow-1', choices: [{index: 0, delta: {role: 'assistant', content: ANSWER}, finish_reason: null}]},
      {id: 'reflow-1', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: 'reflow-1', choices: [], usage},
    ];
    for (const chunk of chunks) res.write('data: ' + JSON.stringify(chunk) + '\n\n');
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

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
  // The opening (Victor 22/11) is measured by its own row (WA_BIN=... cargo test -p wa-term --test
  // opening, and scripts/test-opening.lua); this file drives `wa chat` for something else and should
  // not pay two seconds of animation before the screen it reads.
  WASM_AGENT_CLI_OPENING: 'off',
  COLUMNS: String(WIDE),
  LINES: '40',
};

const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-reflow-blocks-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const {SOCKET, tmux} = tmuxSession('wa-reflow-blocks');   // this process's own server, killed on every exit path
const SESSION = 'reflow';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
// The scrollbar is drawn in the LAST column of every row, so a blank chat row reads as spaces and a bar.
const SCROLLBAR = new Set(['\u2502', '\u2503']);
function stripScrollbar(row) {
  const text = row.replace(/\s+$/, '');
  if (text === '') return '';
  return SCROLLBAR.has(text[text.length - 1]) ? text.slice(0, -1).replace(/\s+$/, '') : text;
}
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(stripScrollbar).map(r => r.replace(/\u29c9/g, '').replace(/\s+$/, ''));
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

// The card's body rows: what is between `┌─` and `└─`, the bar still on each. A card whose row was
// drawn without its bar would not be between them at all, which is why the frame is the delimiter and
// not the row's own glyph.
const CARD_OPEN = /^\u250c\u2500/;
const CARD_CLOSE = /^\u2514\u2500/;
function cardRows(lines) {
  const rows = [];
  let open = false;
  for (const row of lines) {
    if (CARD_OPEN.test(row)) { open = true; continue; }
    if (CARD_CLOSE.test(row)) { open = false; continue; }
    if (open && row !== '') rows.push(row);
  }
  return rows;
}
// The run block's rows: the row the script starts on, then every row under it that opens with the
// continuation mark - the band has no bar to delimit it, and the mark is exactly what joins it.
function bandRows(lines) {
  const at = lines.findIndex(row => row.startsWith(BAND_CODE.slice(0, 16)));
  if (at < 0) return null;
  const rows = [lines[at]];
  for (let i = at + 1; i < lines.length && lines[i].startsWith('\u21aa'); i++) rows.push(lines[i]);
  return rows;
}
const rowsAt = lines => ({card: cardRows(lines), band: bandRows(lines)});
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

try {
  // The fixture's own precondition: a line that fits at one width and not at the other is the only
  // thing that can make "it was not re-cut" a failure, so a fixture that cannot say that is refused.
  if (!check('the fixture lines are longer than ' + NARROW + ' and fit in ' + WIDE + ' columns',
    FENCE_CODE.length > NARROW && FENCE_CODE.length + 2 <= WIDE
    && BAND_CODE.length > NARROW && BAND_CODE.length <= WIDE,
    'fence ' + FENCE_CODE.length + ', band ' + BAND_CODE.length)) {
    throw new Error('the fixture cannot measure what this test claims');
  }
  const command = [
    'env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat', 'draw the two blocks',
  ].join(' ');
  tmux(['kill-server']);
  const started = tmux(['new-session', '-d', '-s', SESSION, '-x', String(WIDE), '-y', '40', command]);
  if (started.status !== 0) throw new Error('tmux could not start the session: ' + started.stderr);

  await waitFor(() => capture().some(row => row.includes('Done.')), 'the answer to be drawn');
  await sleep(1200);
  check('the fixture served the run (a run that reached any other endpoint proves nothing)', served >= 1,
    'requests served: ' + served);

  const seen = {};
  for (const [round, columns] of [[1, WIDE], [1, NARROW], [2, WIDE], [2, NARROW]]) {
    tmux(['resize-window', '-t', SESSION, '-x', String(columns), '-y', '40']);
    await sleep(1400);
    const lines = capture();
    const shown = rowsAt(lines);
    const screen = lines.filter(r => r !== '').join('\n');
    check('at ' + columns + ' columns the fence is drawn', shown.card.length > 0, screen);
    check('at ' + columns + ' columns the run block is drawn', shown.band && shown.band.length > 0, screen);
    if (!shown.band) continue;

    const card = shown.card.join('');
    const band = shown.band.join('');
    check('at ' + columns + ' columns no row carries the mark at its END (the run box used to)',
      !lines.some(row => row.endsWith('\u21aa')), screen);
    check('at ' + columns + ' columns neither block lost a character to the cut',
      card.replace(/^\u2502 /, '').replace(/\u2502\u21aa/g, '') === FENCE_CODE
      && band.replace(/\u21aa/g, '') === BAND_CODE,
      'card: ' + JSON.stringify(card) + '\nband: ' + JSON.stringify(band)
      + '\nexpected fence: ' + JSON.stringify(FENCE_CODE) + '\nexpected band: ' + JSON.stringify(BAND_CODE));

    if (columns === WIDE) {
      check('at ' + columns + ' columns the fence line is ONE row, unmarked',
        shown.card.length === 1 && shown.card[0] === '\u2502 ' + FENCE_CODE, JSON.stringify(shown.card));
      check('at ' + columns + ' columns the run block line is ONE row, unmarked',
        shown.band.length === 1 && shown.band[0] === BAND_CODE, JSON.stringify(shown.band));
    } else {
      check('at ' + columns + ' columns the fence line is cut, and only the row it goes on carries the mark',
        shown.card.length > 1 && !shown.card[0].includes('\u21aa')
        && shown.card.slice(1).every(row => row.startsWith('\u2502\u21aa')), JSON.stringify(shown.card));
      check('at ' + columns + ' columns the run block line is cut, and only the row it goes on carries the mark',
        shown.band.length > 1 && !shown.band[0].includes('\u21aa')
        && shown.band.slice(1).every(row => row.startsWith('\u21aa')), JSON.stringify(shown.band));
      check('at ' + columns + ' columns the cut row still uses the whole line',
        shown.card[0].length >= columns - 2 && shown.band[0].length >= columns - 2,
        'card ' + shown.card[0].length + ' cells, band ' + shown.band[0].length + ' cells, screen ' + columns);
    }
    // The mark is the fence's, in the same place in both blocks: the cell in front of the text the line
    // goes on with, never inside the cut row (checked above, both blocks).
    if (columns === NARROW) {
      // A block with ONE row here failed the two checks above; the mark's place is then simply absent,
      // and saying so is the honest reading (`undefined` is not a pass).
      check('at ' + columns + ' columns both blocks mark the continuation the same way',
        (shown.card[1] || '').startsWith('\u2502\u21aa') && (shown.band[1] || '').startsWith('\u21aa')
        && !shown.card[0].includes('\u21aa') && !shown.band[0].includes('\u21aa'),
        'card: ' + JSON.stringify(shown.card) + '\nband: ' + JSON.stringify(shown.band));
    }
    const key = columns + '#' + round;
    seen[key] = shown;
  }
  // "Re-cut, not remembered": the second visit to a width draws the rows the first visit drew.
  check('going back to ' + WIDE + ' columns draws the rows the first ' + WIDE + ' did',
    seen[WIDE + '#1'] && seen[WIDE + '#2'] && same(seen[WIDE + '#1'], seen[WIDE + '#2']),
    JSON.stringify(seen[WIDE + '#1']) + '\nvs\n' + JSON.stringify(seen[WIDE + '#2']));
  check('going back to ' + NARROW + ' columns draws the rows the first ' + NARROW + ' did',
    seen[NARROW + '#1'] && seen[NARROW + '#2'] && same(seen[NARROW + '#1'], seen[NARROW + '#2']),
    JSON.stringify(seen[NARROW + '#1']) + '\nvs\n' + JSON.stringify(seen[NARROW + '#2']));
  console.log('\n---- the screen at ' + NARROW + ' columns ----\n' + capture().filter(r => r !== '').join('\n'));
} catch (error) {
  failed += 1;
  console.error('reflow-blocks: FAILED - ' + error.message);
} finally {
  tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('reflow-blocks: scratch kept for diagnosis: ' + WORK);
}

console.log('reflow-blocks pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
