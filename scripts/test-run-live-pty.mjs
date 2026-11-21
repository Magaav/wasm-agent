#!/usr/bin/env node
// WHAT THE RUN BLOCK DRAWS WHEN THE MODEL IS REALLY WRITING IT (Victor 21/11).
//
// The operator's own measurement, on main eae9a3a9: `wa chat --once "use code to run bash seq 1 3 and
// uname -r, then tell me"` drew the script, then ONLY `bash ×2 ✓2`, then a ~4 KB wrapped JSON blob
// (operation_id, owner_boot, timing, stdout_path, "stdout_omitted":17 ...). The commands' own output -
// `1 2 3` and the kernel version - was nowhere. In his interactive window the run block showed only the
// script's first line while a call waited, and the scrollbar split in two.
//
// This test drives the REAL binary the way he does it, in a real pty (a PRIVATE tmux server, so it never
// touches the operator's own), and reads the screen back with capture-pane:
//
//   A. `wa chat --once "<prompt>"` - the stdout view, read as the text it printed;
//   B. `wa chat "<prompt>"`        - the interactive window: the whole script WHILE a call waits, each
//                                    settled call's output under its row, and the scrollbar staying ONE
//                                    bar while the reader scrolls.
//
// It cannot reach a model, a relay or the operator's vault: a local SSE fixture answers the requests,
// tmux runs on a private socket (`-L`), and the child gets `env -i` plus an explicit allow-list. It
// REFUSES to run when its scratch root is inside the real ~/.wasm-agent, and FAILS (never passes) when
// the fixture was never asked for the script: a run that reached some other endpoint proves nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-run-live-pty.mjs
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
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('run-live-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-run-live-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('run-live-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the script the model writes, and the two answers ----------------------------------------
// Four lines, so "only the first line is drawn" is a visible failure, and one call that WAITS, so the
// frame can be read while the block is unfinished - which is exactly the state Victor photographed.
const SCRIPT = [
  "const a = await tools.bash({ command: 'seq 1 3' });",
  "const b = await tools.bash({ command: 'uname -r' });",
  "const c = await tools.bash({ command: 'sleep 20; echo done' });",
  'return { seq: a, uname: b, slow: c };',
].join('\n');
const KERNEL = os.release();
const ARGS = JSON.stringify({code: SCRIPT});
const FRAGMENTS = [];
for (let at = 0; at < ARGS.length; at += 24) FRAGMENTS.push(ARGS.slice(at, at + 24));
// A long preamble before the call, so the transcript overflows the 40-row pane and scrolling has
// somewhere to go - the state in which the scrollbar was seen to split.
const PREAMBLE = Array.from({length: 40}, (_, i) => 'preamble line ' + (i + 1) + ' of the run block test').join('\n');
const FINAL = 'Both commands ran: 1 2 3, and the kernel version above. The slow one printed done.';

let requests = 0;
let askedForScript = 0;
let answeredFinal = 0;
// WHICH ANSWER, decided from the REQUEST and never from a counter: a node also asks its provider other
// things, and an answer handed to the wrong request is a run that never happens.
function wantsScript(body) {
  let request = null;
  try { request = JSON.parse(body); } catch { return false; }
  if (!request || !Array.isArray(request.messages)) return false;
  const hasRun = Array.isArray(request.tools) && request.tools.some(t => t && t.function && t.function.name === 'run');
  const hasResult = request.messages.some(m => m && m.role === 'tool');
  return hasRun && !hasResult;
}
const server = http.createServer((req, res) => {
  const body = [];
  req.on('data', chunk => body.push(chunk));
  req.on('end', () => {
    requests += 1;
    const text = Buffer.concat(body).toString('utf8');
    const streaming = (() => { try { return JSON.parse(text).stream !== false; } catch { return true; } })();
    const ask = wantsScript(text);
    if (ask) askedForScript += 1; else answeredFinal += 1;
    if (!streaming) {
      // A non-streaming caller gets one JSON answer; the shape is the provider's, not this test's.
      const message = ask
        ? {role: 'assistant', content: null, tool_calls: [{id: 'call_run_live_1', type: 'function',
            function: {name: 'run', arguments: ARGS}}]}
        : {role: 'assistant', content: FINAL};
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({id: 'rl', object: 'chat.completion', created: 1, model: 'deepseek-v4.1-flash',
        choices: [{index: 0, message, finish_reason: ask ? 'tool_calls' : 'stop'}],
        usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}));
      return;
    }
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    const chunks = [];
    if (ask) {
      chunks.push({id: 'rl-1', choices: [{index: 0, delta: {role: 'assistant', content: PREAMBLE + '\n\n'}}]});
      chunks.push({id: 'rl-1', choices: [{index: 0, delta: {tool_calls: [{index: 0, id: 'call_run_live_1',
        type: 'function', function: {name: 'run', arguments: ''}}]}}]});
      for (const fragment of FRAGMENTS) {
        chunks.push({id: 'rl-1', choices: [{index: 0, delta: {tool_calls: [{index: 0,
          function: {arguments: fragment}}]}}]});
      }
      chunks.push({id: 'rl-1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]});
    } else {
      chunks.push({id: 'rl-2', choices: [{index: 0, delta: {role: 'assistant', content: FINAL}}]});
      chunks.push({id: 'rl-2', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]});
    }
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
  // The TREE's Lua. A process started from a checkout reads every module from it - including the UI
  // modules the run block is drawn by - so this test exercises the code under review, and says so.
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
const envArgs = ['env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value)];
const DB = path.join(WORK, 'ledger.db');
const PROMPT = 'use code to run bash seq 1 3 and uname -r, then tell me';

const ANSI = /\u001b\[[0-9;?]*[A-Za-z]|\u001b\][^\u0007]*\u0007/g;
const plain = text => String(text).replace(ANSI, '').replace(/\r/g, '');

// What the block must never draw by default: the operation envelope (Victor 21/11).
const ENVELOPE = ['operation_id', 'owner_boot', 'stdout_path', 'stderr_path', 'cleanup_budget_ms',
  'containment', 'output_omitted', 'stdout_omitted', 'schema_version', 'unattributed_ms',
  'env_withheld_note'];
const envelopeFields = text => ENVELOPE.filter(field => text.includes(field));

// ---- the pty this test reads ----------------------------------------------------------------
const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-run-live-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  console.log('run live pty: 0 ok, 0 failed (skipped)');
  process.exit(0);
}
const SOCKET = 'wa-run-live-' + process.pid;
const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], {encoding: 'utf8'});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
// The scrollbar is drawn in the LAST column of the transcript's rows. One bar means ONE contiguous run
// of rows that end in it; a split bar is two groups with a plain row between them, which is what the
// operator's screenshot shows under the main bar beside the waiting call.
const BAR = new Set(['\u2502', '\u2503']);
const hasBar = row => {
  const text = row.replace(/\s+$/, '');
  return text !== '' && BAR.has(text[text.length - 1]);
};
function barGroups(rows) {
  const groups = [];
  let open = null;
  rows.forEach((row, index) => {
    if (!hasBar(row)) { open = null; return; }
    if (!open) { open = [index]; groups.push(open); } else { open.push(index); }
  });
  return groups;
}
const screen_rows = name => {
  const text = String(tmux(['capture-pane', '-p', '-S', '-400', '-t', name]).stdout || '');
  return plain(text);
};

// ---- A. the --once view, exactly the command the operator ran --------------------------------
try {
  tmux(['kill-server']);
  const once = [...envArgs, BIN, '--db', DB, 'chat', '--once', PROMPT].join(' ');
  // The pane outlives the run: `--once` exits, and a session whose only process exited takes its
  // scrollback with it, so the printed text is held by a shell that is still there.
  const command = "bash -c '" + once + "; echo __ONCE_DONE__; sleep 300'";
  const started = tmux(['new-session', '-d', '-s', 'once', '-x', '100', '-y', '60', command]);
  if (started.status !== 0) throw new Error('tmux could not start the session: ' + started.stderr);
  const deadline = Date.now() + 180000;
  let out = '';
  for (;;) {
    out = screen_rows('once');
    if (out.includes('__ONCE_DONE__') || Date.now() > deadline) break;
    await sleep(200);
  }
  await sleep(500);
  out = screen_rows('once');
  fs.writeFileSync(path.join(WORK, 'once.txt'), out);
  tmux(['kill-server']);
  check('the --once run asked the fixture for the script and got the result back (a run against any '
    + 'other endpoint proves nothing)', askedForScript >= 1 && answeredFinal >= 1,
    'script requested: ' + askedForScript + ', final answered: ' + answeredFinal + ', requests: ' + requests + '\n' + out);
  check('the script the model wrote is drawn, whole',
    SCRIPT.split('\n').every(line => out.includes(line)), out);
  check('the first command\'s own output is drawn, one row per line',
    /\n\s*1\s*\n\s*2\s*\n\s*3\s*\n/.test(out), out);
  check('and so is the kernel version the second one printed', out.includes(KERNEL), out);
  check('each call is a row of its own, ticked', (out.match(/\u2713 bash/g) || []).length >= 2,
    (out.match(/\u2713 bash.*/g) || []).join('\n'));
  const envelope = envelopeFields(out);
  check('no operation envelope is drawn anywhere', envelope.length === 0,
    'fields drawn: ' + envelope.join(', ') + '\n' + out);
  const longest = out.split('\n').reduce((a, b) => (b.length > a.length ? b : a), '');
  check('no wrapped JSON blob (the longest row is a row, not four kilobytes)', longest.length < 400,
    'longest row: ' + longest.length + ' chars: ' + longest.slice(0, 300));
  check('the answer the model then gave is drawn', out.includes('Both commands ran'), out);
} catch (error) {
  failed += 1;
  console.error('run-live-pty: the --once half FAILED - ' + error.message);
  try { tmux(['kill-server']); } catch {}
}

// ---- B. the interactive window ----------------------------------------------------------------
try {
  tmux(['kill-server']);
  const command = [...envArgs, BIN, '--db', DB, 'chat', PROMPT].join(' ');
  const started = tmux(['new-session', '-d', '-s', 'live', '-x', '100', '-y', '40', command]);
  if (started.status !== 0) throw new Error('tmux could not start the session: ' + started.stderr);

  // The script has to be on screen WHILE the third call waits: that is the state that showed only the
  // first line. `sleep 20` gives a wide window to read the frame in.
  const deadline = Date.now() + 120000;
  let waiting = '';
  for (;;) {
    waiting = screen_rows('live');
    if (waiting.includes('sleep 20')) break;
    if (Date.now() > deadline) throw new Error('timed out waiting for the script to be drawn');
    await sleep(100);
  }
  await sleep(400);
  waiting = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'pty-waiting.txt'), waiting);
  const lost = SCRIPT.split('\n').filter(line => !waiting.includes(line));
  check('in the interactive window the WHOLE script is drawn while a call waits', lost.length === 0,
    'missing lines: ' + JSON.stringify(lost) + '\n' + waiting);
  check('the waiting call is a row of its own', /\u23f3/.test(waiting),
    waiting);

  // Each call that has already settled shows what it printed, in the same frame.
  check('the first call\'s output is drawn under its row while the slow one waits',
    /\u2713 bash/.test(waiting) && /\n\s*1\s*\n\s*2\s*\n\s*3\s*\n/.test(waiting), waiting);
  check('and the second call\'s kernel version with it', waiting.includes(KERNEL), waiting);
  const envelope = envelopeFields(waiting);
  check('and no envelope field is drawn in the window', envelope.length === 0,
    'fields drawn: ' + envelope.join(', ') + '\n' + waiting);

  // THE BAR: one bar, and it stays one bar while the reader scrolls during the wait.
  const rows = waiting.split('\n');
  const groups = barGroups(rows);
  check('the scrollbar is ONE bar while a call waits', groups.length === 1,
    'bar groups: ' + JSON.stringify(groups) + '\n' + waiting);
  const topBefore = rows.slice(0, 6).join('\n');
  tmux(['send-keys', '-t', 'live', 'PPage']);
  await sleep(900);
  const scrolled = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'pty-scrolled.txt'), scrolled);
  const topAfter = scrolled.split('\n').slice(0, 6).join('\n');
  check('PgUp scrolls the transcript while the call is still waiting', topAfter !== topBefore,
    'before:\n' + topBefore + '\nafter:\n' + topAfter);
  const groupsAfter = barGroups(scrolled.split('\n'));
  check('and the bar is still ONE bar after scrolling', groupsAfter.length === 1,
    'bar groups: ' + JSON.stringify(groupsAfter) + '\n' + scrolled);

  // Let the run finish, so nothing is left running when this test ends, and read the settled frame.
  const settledDeadline = Date.now() + 180000;
  let settled = '';
  for (;;) {
    settled = screen_rows('live');
    if (settled.includes('Both commands ran') || Date.now() > settledDeadline) break;
    await sleep(200);
  }
  await sleep(600);
  settled = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'pty-settled.txt'), settled);
  check('after the last call returns the block still shows the script',
    SCRIPT.split('\n').every(line => settled.includes(line)), settled);
  check('each call\'s output is still under its row', settled.includes(KERNEL), settled);
  check('the slow command\'s own output is drawn too', /\ndone\n/.test(settled), settled);
  check('and no envelope field is drawn in the settled block', envelopeFields(settled).length === 0,
    settled);
} catch (error) {
  failed += 1;
  console.error('run-live-pty: the interactive half FAILED - ' + error.message);
  try { console.error('---- the screen ----\n' + screen_rows('live')); } catch {}
} finally {
  tmux(['kill-server']);
}

server.close();
if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
else console.error('run-live-pty: scratch kept for diagnosis: ' + WORK);
console.log('run live pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
