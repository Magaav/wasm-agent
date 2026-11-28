#!/usr/bin/env node
// THE COPY NOTICE, IN A REAL TERMINAL (copied-notice-floats, Victor today).
//
// "Copied N characters" is a BALLOON at the top of the TUI: a title, dividers, the words centred - and it
// RESERVES its rows, pushing the chat and the pinned last message down while it shows and giving the space
// back when it goes. This row drives the real binary in a real pty (a PRIVATE tmux server), makes a copy
// happen the way a reader makes one (a press on a code fence's icon), and reads the screen.
//
// MEASURED first, because it shaped the fixture: a DRAFT copy (type, ctrl+a, ctrl+c) raises no notice at
// all. The notice comes from a copy in the TRANSCRIPT, so the row needs a fence - and a fence comes from
// the assistant's own text, the way scripts/test-fence-card-pty.mjs builds one.
//
// Run: WA_BIN=<wa> node scripts/test-copied-notice-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {tmuxSession} from './lib/tmux-session.mjs';
import {fileURLToPath} from 'node:url';

const REPO = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
// THE BINARY UNDER TEST IS THIS TREE'S, NEVER 'WHATEVER IS INSTALLED'. Measured twice: run against
// the installed node (older than the change) this row found a notice with no frame and looked like a
// failure of the balloon; run with WA_BIN unset it silently tested somebody else's build. The default
// is this tree's release build, and when there is none the row REFUSES by name.
const WA = process.env.WA_BIN || [path.join(REPO, '.local-target', 'release', 'wa'),
  path.join(REPO, 'rust', 'target', 'release', 'wa')].find(candidate => fs.existsSync(candidate)) || '';
if (!WA) {
  console.error('refused(no_binary_under_test): build this tree first (cargo build --release --manifest-path rust/Cargo.toml), or set WA_BIN to the binary to test');
  process.exit(2);
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const TICK = '`';
const FENCE = TICK + TICK + TICK;
const ANSWER = [
  'A paragraph above the card, so the card is not the first thing in the block.',
  '',
  FENCE,
  'echo one',
  'echo two',
  FENCE,
].join('\n');

let round = 0;
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', piece => chunks.push(piece));
  req.on('end', () => {
    if (String(req.url || '').includes('completions') && req.method === 'POST') {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      round += 1;
      res.write('data: ' + JSON.stringify({id: 'n', choices: [{index: 0, delta: {role: 'assistant', content: ANSWER}, finish_reason: null}]}) + '\n\n');
      res.write('data: ' + JSON.stringify({id: 'n', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
      res.end();
      return;
    }
    res.writeHead(200, {'content-type': 'application/json'}).end('{"nodes":[]}');
  });
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const PORT = server.address().port;

const home = fs.mkdtempSync(path.join(os.homedir(), '.wa-copied-notice-'));
const env = {
  PATH: '/usr/bin:/bin', HOME: home, TERM: 'xterm-256color', LANG: 'C.UTF-8',
  WASM_AGENT_HOME: home, WASM_AGENT_LUA_ROOT: REPO, WASM_AGENT_PROVIDER: 'opencode-go',
  WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + PORT, WASM_AGENT_LLM_API_KEY: 'test-only',
  WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE: path.join(home, '..', 'none'),
  WASM_AGENT_RENDEZVOUS: 'http://127.0.0.1:' + PORT, WASM_AGENT_RELAY: '', WASM_AGENT_MANAGED: '0',
  WA_SKIP_UPDATE_CHECK: '1', WASM_AGENT_CLI_OPENING: 'off', COLUMNS: '100', LINES: '30',
  ...(process.env.WASM_AGENT_IN_TURN ? {WASM_AGENT_IN_TURN: process.env.WASM_AGENT_IN_TURN} : {}),
};
const {tmux, killServer} = tmuxSession('wa-copied-notice');
const SESSION = 'n';
const command = ['env', '-i', ...Object.entries(env).map(([k, v]) => k + '=' + v), WA, '--db', path.join(home, 'l.db'), 'chat'].join(' ');
tmux(['new-session', '-d', '-s', SESSION, '-x', '100', '-y', '30', command]);

const screen = () => String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '').split('\n');
const results = [];
function check(name, ok, detail) {
  results.push({name, ok: !!ok});
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (detail ? '  ::  ' + detail : ''));
}
async function waitFor(predicate, label, timeout = 40000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (predicate(screen())) return true;
    await sleep(120);
  }
  throw new Error('timed out waiting for ' + label + '\n' + screen().join('\n'));
}

let status = 0;
try {
  await waitFor(rows => rows.some(r => r.includes('Type a message')), 'the prompt');
  tmux(['send-keys', '-t', SESSION, '-l', 'show me a fence']);
  tmux(['send-keys', '-t', SESSION, 'Enter']);
  await waitFor(rows => rows.some(r => r.includes('\u29c9')), 'the fence and its copy icon');
  const before = screen();
  const iconRow = before.findIndex(r => r.includes('\u29c9'));
  const iconCol = before[iconRow].indexOf('\u29c9');

  // A REAL MOUSE PRESS on the icon: SGR 1006, left button, 1-based row and column.
  tmux(['send-keys', '-t', SESSION, '-l', `\x1b[<0;${iconCol + 1};${iconRow + 1}M`]);
  // THE NOTICE IS THE SIGNAL, not a stopwatch (27/11 health red): a fixed 500 ms is what made
  // this row go red on a loaded machine - the press landed, the balloon had not drawn yet. The
  // wait is on the words the balloon itself writes, so a slow machine waits and a broken one fails.
  await waitFor(rows => rows.some(r => /Copied \d+ characters?/.test(r)), 'the copy notice after the press');
  const during = screen();
  const words = during.findIndex(r => /Copied \d+ characters?/.test(r));
  const title = during.findIndex(r => r.includes('Copied') && !/\d+ characters?/.test(r));
  check('a press on a fence\'s copy icon opens the notice balloon', words >= 0 && title >= 0 && title < words,
    words >= 0 ? `title at ${title}, words at ${words}` : 'no notice on screen');
  // THE BALLOON'S OWN FRAME: a divider above the title and one under the words, the panel's shape.
  const divider = row => typeof row === 'string' && row.trim().length > 10 && /^[\u2500\s]+$/.test(row);
  check('and its frame is drawn: a divider above the title and one under the words',
    title > 0 && divider(during[title - 1]) && /^[\u2500\s]+$/.test(during[words + 1] || ''),
    `above: ${JSON.stringify(during[title - 1])}, below: ${JSON.stringify(during[words + 1])}`);
  check('and the chat below it moved down by the balloon\'s rows',
    during.filter((row, at) => at >= 4 && before[at - 4] === row).length > 2,
    'the chat is four rows lower while the balloon shows');

  // ITS OWN EXPIRY IS THE SIGNAL: the notice holds for a fixed time by design, and this row used to
  // sleep past it. It now waits for the words to be GONE, so the check is about the behaviour and
  // not about a stopwatch that a busy machine can outrun.
  await waitFor(rows => !rows.some(r => /Copied \d+ characters?/.test(r)), 'the notice to expire');
  const after = screen();
  check('and the space comes back when it expires', !after.some(r => /Copied \d+ characters?/.test(r)),
    'the notice is gone');
} catch (error) {
  console.error('\nFAIL test-copied-notice-pty: ' + (error && error.message ? error.message : error));
  status = 1;
} finally {
  const failed = results.filter(r => !r.ok).length;
  if (results.length && !failed && !status) console.log(`\nPASS test-copied-notice-pty (${results.length} checks)`);
  else if (results.length) { console.log(`\nFAIL test-copied-notice-pty (${failed} of ${results.length})`); status = 1; }
  try { killServer(); } catch {}
  server.close();
  process.exit(status);
}
