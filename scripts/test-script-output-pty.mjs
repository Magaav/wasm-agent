#!/usr/bin/env node
// A RUN BLOCK'S RESULT IS ONE ROW THE READER OPENS (chat-view-round-2, item 4).
//
// Victor, 23/11: "script output should show 'script output · <n> chars' so we can expand". What the base
// printed for a run block was a preview of its first rows under a corner mark, then
// `operation op-… · exit 0 · the whole result is in /console` - a place the reader is not looking at.
//
// This drives the REAL binary in a real pty (a private tmux server) against a local fixture that plays
// the model, so the row is measured as a reader sees it:
//   * a script that returns 2,549 characters draws exactly ONE row, `⎿ script output · 2,549 chars`,
//     and none of its text;
//   * Ctrl+O opens it in place (the whole output is on the screen) and the same key folds it back -
//     the row's own press does the same thing (host.transcript_expand);
//   * a script that THREW is drawn OPEN, its error first, with no press needed: a fold over a failure
//     would hide the one thing the reader has to act on.
//
// Isolation is scripts/test-diff-card-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, env -i plus an allow-list, and a FAILURE (never a pass) when the fixture served
// nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-script-output-pty.mjs
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
  console.error('script-output-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-script-output-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('script-output-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture: the model, and only the model ------------------------------------------------
// Turn 1: a run block that returns 2,549 characters. Turn 2: a run block that throws. Then a sentence.
const CHARS = 2549;
const PLAN = [
  {tool: 'run', args: {code: 'return "x".repeat(' + CHARS + ');'}, final: 'that is the long one'},
  {tool: 'run', args: {code: 'throw new Error("boom: the script failed");'}, final: 'and that one failed'},
];
let turn = 0;
let step = 0;
let requests = 0;

function sse(res, delta) {
  res.write('data: ' + JSON.stringify({id: 'c', choices: [{index: 0, delta}]}) + '\n\n');
}
function answerCall(res, at) {
  sse(res, {role: 'assistant', content: null,
    tool_calls: [{index: 0, id: 'call_' + turn, type: 'function', function: {name: at.tool, arguments: ''}}]});
  sse(res, {tool_calls: [{index: 0, function: {arguments: JSON.stringify(at.args)}}]});
  sse(res, {});
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
    const at = PLAN[turn];
    if (last === 'tool') {
      // The call settled: this turn's sentence, and the next turn's plan.
      const text = at ? at.final : 'done';
      sse(res, {role: 'assistant', content: text});
      res.write('data: ' + JSON.stringify({id: 'f', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
      turn += 1; step = 0;
    } else if (at) {
      answerCall(res, at);
    } else {
      sse(res, {role: 'assistant', content: 'nothing left to do'});
      res.write('data: ' + JSON.stringify({id: 'f', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
    }
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const COLS = 100, ROWS = 40;
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
  console.log('SKIP test-script-output-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

// The tmux server belongs to this process and dies with it: the one helper that carries the exit handlers
// and reclaims a server left by a SIGKILLed sibling (scripts/test-tmp-cleanliness.mjs, D1).
const {tmux} = tmuxSession('wa-script-output');
const SESSION = 'sout';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const screen = () => capture().join('\n');
async function waitFor(predicate, label, timeout = 90000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(60);
  }
}

let started = false;
try {
  const command = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat'].join(' ');
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', WORK, command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  // ---- turn 1: a long result is ONE row ---------------------------------------------------------
  tmux(['send-keys', '-t', SESSION, 'give me the long one', 'Enter']);
  await waitFor(() => screen().includes(PLAN[0].final), 'the first turn');
  await sleep(300);
  const afterFirst = capture();
  const text1 = afterFirst.join('\n');
  const rows = afterFirst.filter(row => row.includes('script output'));
  check('the result is drawn as one `script output` row', rows.length === 1, text1);
  check('and it says how many characters it is holding', /script output \u00b7 2,549 chars/.test(text1), text1);
  check('nothing of the output is printed under it', !/xxxxx/.test(text1), text1);
  check('and the /console sentence is gone', !text1.includes('the whole result is in /console'), text1);

  // ---- Ctrl+O opens it in place, and the same key folds it back ---------------------------------
  tmux(['send-keys', '-t', SESSION, 'C-o']);
  let opened = false;
  try {
    await waitFor(() => /xxxxx/.test(screen()), 'the opened output', 15000);
    opened = true;
  } catch { opened = false; }
  check('Ctrl+O draws the whole output in place', opened, screen());
  check('and the fold row is gone while it is open', !screen().includes('script output \u00b7 2,549 chars'), screen());
  tmux(['send-keys', '-t', SESSION, 'C-o']);
  let folded = false;
  try {
    await waitFor(() => screen().includes('script output \u00b7 2,549 chars') && !/xxxxx/.test(screen()),
      'the folded row', 15000);
    folded = true;
  } catch { folded = false; }
  check('and the same key folds it back to the one row', folded, screen());

  // ---- turn 2: a failed script is OPEN, its error first -----------------------------------------
  tmux(['send-keys', '-t', SESSION, 'now the failing one', 'Enter']);
  let openFailure = false;
  try {
    await waitFor(() => screen().includes('boom: the script failed'), 'the failure', 60000);
    openFailure = true;
  } catch { openFailure = false; }
  check('a script that threw shows its error with no press at all', openFailure, screen());
  const failureText = screen();
  // The failed block is the part of the screen BELOW the line that asked for it: the first turn's own
  // `script output` row is legitimately still above it.
  const asked = failureText.indexOf('now the failing one');
  const block = asked >= 0 ? failureText.slice(asked) : failureText;
  check('and its error is not hidden behind a fold',
    block.includes('boom: the script failed') && !/script output \u00b7 \d/.test(block), block);
  check('the failed block is still on the screen after the turn ended',
    failureText.includes('boom: the script failed'), failureText);
} catch (error) {
  failed += 1;
  console.error('script-output-pty: FAILED - ' + error.message);
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('script-output-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('script output pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, ' + requests + ' provider requests');
process.exitCode = failed === 0 ? 0 : 1;
