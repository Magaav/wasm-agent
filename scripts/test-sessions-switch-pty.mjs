#!/usr/bin/env node
// SWITCHING THREADS IN ONE PROCESS (sessions-is-a-balloon): opened from /sessions, proven on the wire.
//
// Before this, a thread was entered at start and left only by starting the CLI again - /session could
// print the id and nothing else. This drives the REAL binary in a real pty with two seeded sessions and
// a fixture provider, and measures:
//   1. /sessions draws a page with this session marked first;
//   2. Enter on the other session switches: the line says so, and that thread's own rows are drawn;
//   3. a turn typed after the switch lands in the NEW session's ledger, not the old one's (read by a
//      second process, so the check is not the UI's word for it);
//   4. /sessions now offers "<- back to <alpha>" first, and Enter there goes back;
//   5. the turn after going back lands in alpha again.
//
// Isolation is the same as scripts/test-status-midrun-pty.mjs: a scratch HOME outside the real
// ~/.wasm-agent, env -i with an allow-list, and a FAILURE (never a pass) when the fixture served nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-sessions-switch-pty.mjs
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
  console.error('sessions-switch-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-sessions-switch-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
const DB = path.join(WORK, 'ledger.db');
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('sessions-switch-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: every completion answers at once, and counts what it served --------------------
const KEY = 'sk-sessions-switch-fixture-key';
let completions = 0;
// One held completion (the third: two turns have already run above it): the turn that is still running
// while the reader switches away.
const HOLD_MS = 9000;
const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const index = completions;
    completions += 1;
    const answer = () => {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {role: 'assistant', content: 'answer ' + index}, finish_reason: null}]}) + '\n\n');
      res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
      res.write('data: [DONE]\n\n');
      res.end();
    };
    // The third answer is HELD: that is the turn a switch happens in the middle of.
    if (index === 2) setTimeout(answer, HOLD_MS);
    else answer();
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
  // THE TREE'S OWN LUA, not the copy embedded in whatever binary this is: a row on a worktree must
  // exercise the lua/ the branch carries, or it silently tests the last build instead.
  WASM_AGENT_LUA_ROOT: REPO,
  WASM_AGENT_PROVIDER: 'opencode-go',
  WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + PORT,
  WASM_AGENT_LLM_API_KEY: KEY,
  WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE: path.join(WORK, 'no-models-store'),
  WASM_AGENT_RENDEZVOUS: '',
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  WASM_AGENT_CLI_OPENING: 'off',
  COLUMNS: '100',
  LINES: '44',
};
const ENVLIST = Object.entries(ENV).map(([key, value]) => key + '=' + value);

// ---- two seeded sessions, and a reader that can count a thread's messages from outside ----------
const SEED = path.join(WORK, 'seed.lua');
fs.writeFileSync(SEED, [
  "local json = dofile('lua/vendor/json.lua')",
  "local memory = dofile('lua/core/memory.lua')",
  'memory.setup()',
  "local a = memory.start_session('node-x', 'chat', { user_id = 'master', title = 'alpha' })",
  "local b = memory.start_session('node-x', 'chat', { user_id = 'master', title = 'beta' })",
  // A COMPLETE pair each: a lone user turn is an "unanswered question", and the CLI rightly spends the
  // first seconds recovering it - which would swallow the /sessions this test types.
  "memory.append_turn(a, { role = 'user', content = 'alpha one' })",
  "memory.append_turn(a, { role = 'assistant', content = 'alpha reply' })",
  "memory.append_turn(b, { role = 'user', content = 'beta one' })",
  "memory.append_turn(b, { role = 'assistant', content = 'beta reply' })",
  'print(json.encode({ a = a, b = b }))',
  '',
].join('\n'));
const READ = path.join(WORK, 'read.lua');
fs.writeFileSync(READ, [
  "local json = dofile('lua/vendor/json.lua')",
  "local memory = dofile('lua/core/memory.lua')",
  'memory.setup()',
  'local out = {}',
  'for _, id in ipairs(json.decode(host.getenv("IDS") or "{}")) do',
  '  local s = memory.session(id)',
  '  out[#out + 1] = { count = memory.message_count(id), title = s and s.title or "" }',
  'end',
  'print(json.encode(out))',
  '',
].join('\n'));

function lua(script, extraEnv = {}) {
  const run = spawnSync('env', ['-i', ...ENVLIST, ...Object.entries(extraEnv).map(([k, v]) => k + '=' + v),
    BIN, '--db', DB], {encoding: 'utf8', timeout: 120000});
  if (run.status !== 0) throw new Error('lua ' + script + ' failed: ' + (run.stderr || run.stdout));
  return String(run.stdout || '').trim().split('\n').pop();
}
const ids = JSON.parse(lua(SEED, {WA_SCRIPT: SEED}));
const counts = () => JSON.parse(lua(READ, {WA_SCRIPT: READ, IDS: JSON.stringify([ids.a, ids.b])}));

const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-sessions-switch-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const {tmux} = tmuxSession('wa-sessions-switch');
const SESSION = 'sw';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const screen = () => String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
async function waitFor(predicate, label, timeout = 90000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label + '\n--- screen ---\n' + screen());
    await sleep(60);
  }
}

let started = false;
try {
  const command = ['env', '-i', ...ENVLIST, BIN, '--db', DB, 'chat', '--session', ids.a].join(' ');
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', '100', '-y', '44', '-c', WORK, command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  await waitFor(() => screen().includes('alpha one'), 'the resumed thread', 30000);
  check('the chat opens on alpha and draws its row', true);

  // ---- 1. the page, from /sessions ---------------------------------------------------------------
  tmux(['send-keys', '-t', SESSION, '/sessions', 'Enter']);
  await waitFor(() => screen().includes('beta'), 'the sessions page', 30000);
  check('the page lists the other session', true);

  // ---- 2. Enter on beta switches ----------------------------------------------------------------
  tmux(['send-keys', '-t', SESSION, 'Down']);
  await sleep(200);
  tmux(['send-keys', '-t', SESSION, 'Enter']);
  await waitFor(() => screen().includes('switched to beta'), 'the switch line', 30000);
  check('the switch says where it went', true);
  await waitFor(() => screen().includes('beta one'), 'beta thread drawn', 30000);
  check('the thread that was switched to is drawn', true);

  // ---- 3. a turn typed now lands in BETA --------------------------------------------------------
  const before = counts();
  tmux(['send-keys', '-t', SESSION, 'after the switch', 'Enter']);
  await waitFor(() => completions >= 1, 'the model call after the switch', 60000);
  await waitFor(() => screen().includes('answer 0'), 'the answer after the switch', 60000);
  const after = counts();
  check('the turn after the switch landed in beta', after[1].count === before[1].count + 2, 'counts ' + JSON.stringify(before) + ' -> ' + JSON.stringify(after));
  check('and not in alpha', after[0].count === before[0].count, 'counts ' + JSON.stringify(before) + ' -> ' + JSON.stringify(after));

  // ---- 4. the way back --------------------------------------------------------------------------
  tmux(['send-keys', '-t', SESSION, '/sessions', 'Enter']);
  await waitFor(() => screen().includes('back to alpha'), 'the back row', 30000);
  check('the page offers the way back', true);
  // The panel needs its keys on the screen it drew: a key sent in the same instant the row appears is read
  // by the prompt behind it.
  await sleep(800);
  tmux(['send-keys', '-t', SESSION, 'Enter']);
  await waitFor(() => screen().includes('switched to alpha'), 'the switch back', 30000);
  check('Enter on the back row returns', true);
  // ---- 5. and a turn now lands in ALPHA ---------------------------------------------------------
  const before2 = counts();
  tmux(['send-keys', '-t', SESSION, 'back again', 'Enter']);
  await waitFor(() => completions >= 2, 'the model call after going back', 60000);
  await waitFor(() => screen().includes('answer 1'), 'the answer after going back', 60000);
  const after2 = counts();
  check('the turn after going back landed in alpha', after2[0].count === before2[0].count + 2, 'counts ' + JSON.stringify(before2) + ' -> ' + JSON.stringify(after2));
  check('and not in beta', after2[1].count === before2[1].count, 'counts ' + JSON.stringify(before2) + ' -> ' + JSON.stringify(after2));

  // ---- 6. c copies the id of the row the cursor is on, and does not switch --------------------
  tmux(['send-keys', '-t', SESSION, '/sessions', 'Enter']);
  await waitFor(() => screen().includes('c copies the id'), 'the page with its keys', 30000);
  check('the page names its keys', true);
  await sleep(800);
  // The transcript above the page already says "switched to beta" from step 2, so the count is what
  // says whether THIS key moved the reader: a copy that picked a row would add one.
  const switches_before = (screen().match(/switched to/g) || []).length;
  tmux(['send-keys', '-t', SESSION, 'c']);
  await waitFor(() => screen().includes('copied ' + ids.a.slice(0, 8)), 'the copy confirmation', 30000);
  check('c copies the id of this session and says so', true);
  const switches_after = (screen().match(/switched to/g) || []).length;
  check('and a copy does not switch', switches_after === switches_before,
    'switch lines ' + switches_before + ' -> ' + switches_after);
  // The panel's cancel is a DOUBLE Esc (one is the first byte of a sequence): one would leave the page
  // drawn and swallow the next command. Pressed twice, and waited for, before the next step.
  tmux(['send-keys', '-t', SESSION, 'Escape', 'Escape']);
  await waitFor(() => !screen().includes('c copies the id'), 'the page to close', 15000);
  check('a double Esc closes the page', true);

  // ---- 7. r renames the thread, and the ledger agrees ---------------------------------------
  tmux(['send-keys', '-t', SESSION, '/sessions', 'Enter']);
  await waitFor(() => screen().includes('c copies the id'), 'the page again', 30000);
  await sleep(800);
  tmux(['send-keys', '-t', SESSION, 'r']);
  await waitFor(() => screen().includes('Enter saves'), 'the rename field', 30000);
  check('r opens the name field', true);
  await sleep(400);
  tmux(['send-keys', '-t', SESSION, 'alpha renamed', 'Enter']);
  await waitFor(() => screen().includes('renamed to alpha renamed'), 'the rename confirmation', 30000);
  check('Enter in the field renames and says so', true);
  check('the ledger holds the new name', counts()[0].title === 'alpha renamed',
    'titles ' + JSON.stringify(counts().map(entry => entry.title)));
  // The list came back after the rename (that is the design: an action letter finishes the page and the
  // arm re-opens it), so the reader closes it before typing a message.
  tmux(['send-keys', '-t', SESSION, 'Escape', 'Escape']);
  await sleep(600);

  // ---- 8. switching away from a RUNNING turn leaves it running, and it lands where it started -------
  const before3 = counts();
  // The prompt must be its own before a line is typed into it: a key sent while the arm above is still
  // finishing is read by nothing, and the turn never starts.
  await waitFor(() => screen().includes('Type a message'), 'the prompt before the slow turn', 30000);
  await sleep(400);
  tmux(['send-keys', '-t', SESSION, 'a slow one']);
  await sleep(400);
  tmux(['send-keys', '-t', SESSION, 'Enter']);
  await waitFor(() => completions >= 3, 'the held model call', 60000);
  // The turn is in flight now (its answer is held). The reader opens the list and leaves for beta.
  tmux(['send-keys', '-t', SESSION, '/sessions', 'Enter']);
  await waitFor(() => screen().includes('c copies the id'), 'the page mid-run', 30000);
  await sleep(600);
  tmux(['send-keys', '-t', SESSION, 'Down']);
  await sleep(300);
  tmux(['send-keys', '-t', SESSION, 'Enter']);
  await waitFor(() => screen().includes('switched to beta'), 'the switch mid-run', 30000);
  check('a switch is possible while a turn runs', true);
  // The held answer lands with the finish line: the turn is not stopped by the switch.
  await waitFor(() => screen().includes('answer 2'), 'the held answer on screen', 60000);
  check('the running turn finishes after the switch', true);
  const after3 = counts();
  check('and its turn landed in alpha, where it started', after3[0].count === before3[0].count + 2,
    'counts ' + JSON.stringify(before3) + ' -> ' + JSON.stringify(after3));
  check('not in the thread the reader switched to', after3[1].count === before3[1].count,
    'counts ' + JSON.stringify(before3) + ' -> ' + JSON.stringify(after3));

  check('the fixture served every model call', completions >= 3, 'completions=' + completions);
  check('the provider key is in no file the session wrote', !spawnSync('grep', ['-rlF', KEY, WORK], {encoding: 'utf8'}).stdout);
} catch (error) {
  check('the run completed without an exception', false, error && error.message);
} finally {
  if (started) tmux(['kill-session', '-t', SESSION]);
  server.close();
  const kept = process.env.KEEP ? WORK : null;
  if (kept) { console.log('kept ' + kept); } else { fs.rmSync(WORK, {recursive: true, force: true}); }
}

console.log((failed === 0 ? 'sessions switch pty ok (' : 'sessions switch pty FAILED (') + checks + ' checks, ' + failed + ' failed)');
process.exit(failed === 0 ? 0 : 1);
