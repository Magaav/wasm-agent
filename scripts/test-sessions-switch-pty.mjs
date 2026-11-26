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
const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const index = completions;
    completions += 1;
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {role: 'assistant', content: 'answer ' + index}, finish_reason: null}]}) + '\n\n');
    res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
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
  'for _, id in ipairs(json.decode(host.getenv("IDS") or "{}")) do out[#out + 1] = memory.message_count(id) end',
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
  check('the turn after the switch landed in beta', after[1] === before[1] + 2, 'counts ' + JSON.stringify(before) + ' -> ' + JSON.stringify(after));
  check('and not in alpha', after[0] === before[0], 'counts ' + JSON.stringify(before) + ' -> ' + JSON.stringify(after));

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
  check('the turn after going back landed in alpha', after2[0] === before2[0] + 2, 'counts ' + JSON.stringify(before2) + ' -> ' + JSON.stringify(after2));
  check('and not in beta', after2[1] === before2[1], 'counts ' + JSON.stringify(before2) + ' -> ' + JSON.stringify(after2));

  check('the fixture served both model calls', completions === 2, 'completions=' + completions);
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
