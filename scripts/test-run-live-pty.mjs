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
let skipped = 0;
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
  // The opening (Victor 22/11) is measured by its own row (WA_BIN=... cargo test -p wa-term --test
  // opening, and scripts/test-opening.lua); this file drives `wa chat` for something else and should
  // not pay two seconds of animation before the screen it reads.
  WASM_AGENT_CLI_OPENING: 'off',
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
// A row as the reader reads it: the scrollbar's column is the screen's, not the block's, so it comes
// off before a check asks whether a row holds a value.
const body = text => text.split('\n')
  .map(row => row.replace(/\s*[\u2502\u2503]\s*$/, '')).join('\n');

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
  const text = String(tmux(['capture-pane', '-p', '-t', name]).stdout || '');
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
    // The moment this half is about: the script is on screen and the slow call has not answered.
    if (waiting.includes('sleep 20') && !waiting.includes('Both commands ran')) break;
    if (Date.now() > deadline) throw new Error('timed out waiting for the script to be drawn');
    await sleep(100);
  }
  // Long enough for the two quick calls to answer (the slow one sleeps 20s), short enough to read the
  // block while it is still unfinished - the state that showed only the first line.
  await sleep(3000);
  waiting = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'pty-waiting.txt'), waiting);
  const lost = SCRIPT.split('\n').filter(line => !waiting.includes(line));
  check('in the interactive window the WHOLE script is drawn while a call waits', lost.length === 0,
    'missing lines: ' + JSON.stringify(lost) + '\n' + waiting);
  check('the waiting call is a row of its own', /\u23f3/.test(waiting),
    waiting);

  // Each call that has already settled is ONE row, and what it printed is one click on that row
  // away (Victor 21/11 night: "duplicated info, unnecessary ... the compressed one is better and if
  // we wish we expand it" - the rows under each call were a second copy of the script's result).
  // The click is the terminal's own: an SGR press and release on the row.
  const click = async row => {
    for (const final of ['M', 'm']) {
      const bytes = Buffer.from('\u001b[<0;6;' + row + final, 'latin1');
      tmux(['send-keys', '-t', 'live', '-H', ...[...bytes].map(b => b.toString(16))]);
      await sleep(60);
    }
    await sleep(500);
    return screen_rows('live');
  };
  const tickedRows = text => text.split('\n').map((row, index) => (/\u2713 bash/.test(row) ? index + 1 : 0)).filter(Boolean);
  check('a settled call is one row: its output is not drawn under it by default',
    tickedRows(waiting).length === 2 && !/\n\s*1\s*\n\s*2\s*\n\s*3\s*\n/.test(body(waiting)), waiting);
  const firstOpen = await click(tickedRows(waiting)[0]);
  check('a click on the first call\'s row shows its output while the slow one waits',
    /\n\s*1\s*\n\s*2\s*\n\s*3\s*\n/.test(body(firstOpen)), firstOpen);
  const firstFolded = await click(tickedRows(firstOpen)[0]);
  const secondOpen = await click(tickedRows(firstFolded)[1]);
  check('and a click on the second call\'s row shows the kernel version', secondOpen.includes(KERNEL), secondOpen);
  waiting = await click(tickedRows(secondOpen)[1]);
  const envelope = envelopeFields(waiting);
  check('and no envelope field is drawn in the window', envelope.length === 0,
    'fields drawn: ' + envelope.join(', ') + '\n' + waiting);

  // THE BAR: one bar, and it stays one bar while the reader scrolls during the wait.
  const rows = waiting.split('\n');
  const groups = barGroups(rows);
  // A HARD ASSERTION (it was a recorded SKIP for three rounds): the host counted the waiting mark
  // U+23F3 as one cell where a terminal draws two, padded the row one cell too far, and the bar's
  // glyph wrapped onto the next row - a stub under the waiting row, and a pane scrolled by one.
  check('the scrollbar is ONE bar while a call waits', groups.length === 1,
    'bar groups: ' + JSON.stringify(groups) + '\n' + waiting);
  tmux(['send-keys', '-t', 'live', 'End']);
  await sleep(400);
  const bottom = screen_rows('live');
  const topBefore = bottom.split('\n').slice(0, 6).join('\n');
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
  //
  // THIS WAIT USED TO RUN ITS WHOLE 180 s ON EVERY RUN AND THEN GO ON IN SILENCE (measured 21/11: the
  // answer was never on screen when the deadline passed). The PgUp above left the transcript scrolled
  // up, a scrolled transcript does not follow its tail, and the answer is the LAST row - so the text
  // this loop polled for could not appear however long it waited. Two changes, both the reader's own:
  // every poll first goes back to the bottom with PgDn (the TUI's binding, the pair of the PgUp this
  // half proved), and a wait that expires is a FAILED check carrying the last frame, never a pass.
  // The slow call is `sleep 20`, so the answer is due some 20-25 s after dispatch; 90 s is the ceiling.
  const settleStarted = Date.now();
  const settledDeadline = settleStarted + 90000;
  let settled = '';
  let answered = false;
  for (;;) {
    tmux(['send-keys', '-t', 'live', 'NPage']);
    await sleep(200);
    settled = screen_rows('live');
    answered = settled.includes('Both commands ran');
    if (answered || Date.now() > settledDeadline) break;
  }
  const settleSeconds = ((Date.now() - settleStarted) / 1000).toFixed(1);
  console.log('run-live-pty: the run settled ' + settleSeconds + 's after the scroll check'
    + (answered ? '' : ' - NOT: the answer never reached the screen'));
  check('the run finishes and its answer is drawn at the bottom of the window'
    , answered, 'waited ' + settleSeconds + 's of 90 (the slow call sleeps 20); ' +
    'final answers the fixture served: ' + answeredFinal + ', requests: ' + requests
    + '\n---- the last frame ----\n' + settled);
  // Back to the bottom before reading it: the frame this half checked earlier was scrolled up by
  // its own PgUp, and a scrolled frame is not the answer to "what does the block say".
  // To the bottom the way the reader goes there: PgDn (the TUI's own binding, the one this test
  // proved above by scrolling up with PgUp). The frame that has the last call's output is the one
  // the block ends on.
  settled = screen_rows('live');
  for (let step = 0; step < 8 && !/\n\s*done\s*\n/.test(body(settled)); step += 1) {
    tmux(['send-keys', '-t', 'live', 'PPage', 'PPage'].slice(0, 3));
    tmux(['send-keys', '-t', 'live', 'NPage']);
    await sleep(400);
    settled = screen_rows('live');
  }
  const atBottom = settled;
  // The block is longer than the pane once every call has answered: scroll up to it (the reader's
  // own gesture) and read the four script rows where they are.
  for (let step = 0; step < 6 && !settled.includes(SCRIPT.split('\n')[0]); step += 1) {
    tmux(['send-keys', '-t', 'live', 'PPage']);
    await sleep(400);
    settled = screen_rows('live');
  }
  fs.writeFileSync(path.join(WORK, 'pty-settled.txt'), settled);
  // The transcript is longer than the pane once the block has every call in it, and the block is
  // append-only: a row either frame shows is a row of this block, so each fact is read from the union
  // of the two frames this test captured itself (never from a frame that shows neither).
  // The slow call's own output is one click on its row away, like the others'.
  let slowOpen = '';
  {
    const ticked = tickedRows(screen_rows('live'));
    if (ticked.length >= 3) slowOpen = await click(ticked[2]);
  }
  const seen = waiting + '\n' + firstOpen + '\n' + secondOpen + '\n' + atBottom + '\n' + settled + '\n' + slowOpen;
  check('after the last call returns the block still shows the script',
    SCRIPT.split('\n').every(line => seen.includes(line)), settled);
  check('each call\'s output is still reachable from its row', seen.includes(KERNEL), settled);
  check('the slow command\'s own output is drawn too', /\n\s*done\s*\n/.test(body(seen)), settled);
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
console.log('run live pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, ' + skipped + ' skipped');
process.exitCode = failed === 0 ? 0 : 1;
