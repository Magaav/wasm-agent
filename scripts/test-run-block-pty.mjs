#!/usr/bin/env node
// THE RUN BLOCK AS THE OPERATOR READS IT (Victor 21/11 night, mission tui-run-block).
//
// Three things he saw in his own window, each measured here in a real pty (a PRIVATE tmux server)
// against a local SSE fixture that sends the `run` call's code argument in MANY deltas with a pause
// between them - the way a model writes:
//
//   1. the script appears WHILE it is written: at least three different partial frames of it are
//      read before the call is dispatched (it used to be printed in one piece);
//   2. the output is shown ONCE: a call is one row, the result is ONE row naming its exact size
//      (`⎿ script output · 91 chars` - chat-view-round-2, item 4, and never a JSON-quoted string with
//      \n in it), a click opens it to every line and a second click folds it; a call's own row opens
//      the same way; `--once` (a pipe) prints the output once, whole;
//   3. the scrollbar is ONE bar while a call waits, and after PgUp.
//
// Isolation is test-run-live-pty.mjs's: `env -i` plus an allow-list, a scratch HOME outside the real
// ~/.wasm-agent, a fixture that must have been asked for the script or the run proves nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-run-block-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync, spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {tmuxSession} from './lib/tmux-session.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');

// ---- the isolation this test lives or dies by ------------------------------------------------
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('run-block-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-run-block-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('run-block-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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
const LINES = Array.from({length: 12}, (_, i) => 'line ' + (i + 1));
const SLOW_SECONDS = Number(process.env.RUN_BLOCK_SLOW || 6);
// What the slow command prints, exactly: twelve lines and `end`, each ended by a newline. The result row
// names its length (`⎿ script output · N chars`), and N is this string's length.
const OUTPUT = [...LINES, 'end'].join('\n') + '\n';
const SCRIPT = [
  "const quick = await tools.bash({ command: 'echo quick-one' });",
  "// a comment line, so the script has rows to arrive one by one",
  "const loop = 'for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo line $i; done';",
  "const slow = await tools.bash({ command: loop + '; sleep " + SLOW_SECONDS + "; echo end' });",
  'return slow.stdout;',
].join('\n');
const KERNEL = os.release();
const ARGS = JSON.stringify({code: SCRIPT});
const FRAGMENTS = [];
for (let at = 0; at < ARGS.length; at += 24) FRAGMENTS.push(ARGS.slice(at, at + 24));
// A long preamble before the call, so the transcript overflows the 40-row pane and scrolling has
// somewhere to go - the state in which the scrollbar was seen to split.
const PREAMBLE = Array.from({length: 40}, (_, i) => 'preamble no. ' + (i + 1) + ' of the run block test').join('\n');
const FINAL = 'Both commands ran; the loop printed twelve lines and then end.';

const DELTA_PAUSE_MS = 120;
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
    (async () => {
      // PACED: one delta, then a pause, the way a model writes - so a frame can be read between them.
      for (const chunk of chunks) {
        res.write('data: ' + JSON.stringify(chunk) + '\n\n');
        if (ask) await new Promise(resolve => setTimeout(resolve, DELTA_PAUSE_MS));
      }
      res.write('data: [DONE]\n\n');
      res.end();
    })();
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
const PROMPT = 'use code to run a bash loop, then tell me';

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
  console.log('SKIP test-run-block-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  console.log('run live pty: 0 ok, 0 failed (skipped)');
  process.exit(0);
}
const {tmux} = tmuxSession('wa-run-block');   // this process's own server, killed on every exit path
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



const count = (text, pattern) => (text.match(pattern) || []).length;
const LINE_1 = /line 1(?!\d)/g;
// The quick call's OUTPUT row (the script's own text names the word too, inside a command).
const QUICK_OUT = /^\s*quick-one\s*[\u2502\u2503]?\s*$/m;
const mouse = async (name, col, row) => {
  // An SGR mouse press and release at a 1-based cell, as the terminal sends them.
  for (const final of ['M', 'm']) {
    const bytes = Buffer.from('\u001b[<0;' + col + ';' + row + final, 'latin1');
    tmux(['send-keys', '-t', name, '-H', ...[...bytes].map(b => b.toString(16))]);
    await sleep(60);
  }
  await sleep(500);
};
const rowOf = (text, pattern) => text.split('\n').findIndex(row => pattern.test(row)) + 1;

// ---- A. `--once`: a pipe cannot click, so the output is printed once and whole ------------------
try {
  const child = spawn('env', [...envArgs.slice(1), BIN, '--db', DB, 'chat', '--once', PROMPT],
    {stdio: ['ignore', 'pipe', 'pipe']});
  let out = '';
  child.stdout.on('data', chunk => { out += chunk; });
  child.stderr.on('data', chunk => { out += chunk; });
  const code = await new Promise(resolve => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); resolve('timeout'); }, 90000);
    child.on('exit', status => { clearTimeout(timer); resolve(status); });
  });
  out = plain(out);
  fs.writeFileSync(path.join(WORK, 'once.txt'), out);
  check('the --once run asked the fixture for the script and got its answer', askedForScript >= 1 && answeredFinal >= 1 && code === 0,
    'exit: ' + code + ', script requested: ' + askedForScript + ', final answered: ' + answeredFinal + '\n' + out);
  const missing = [...LINES, 'end'].filter(line => !new RegExp('(^|\\n)\\s*(\\S+ )?' + line + '\\s*(\\n|$)').test(out));
  check('--once prints every line of the output', missing.length === 0, 'missing: ' + JSON.stringify(missing) + '\n' + out);
  check('--once prints the output ONCE', count(out, /line 7/g) === 1 && count(out, LINE_1) === 1,
    'line 7 x' + count(out, /line 7/g) + ', line 1 x' + count(out, LINE_1) + '\n' + out);
  check('--once never prints the JSON-quoted string', !out.includes('\\n'), out);
} catch (error) {
  failed += 1;
  console.error('run-block-pty: the --once half FAILED - ' + error.message);
}

// ---- B. the interactive window ------------------------------------------------------------------
try {
  tmux(['kill-server']);
  const asked = askedForScript;
  const command = [...envArgs, BIN, '--db', path.join(WORK, 'live.db'), 'chat', PROMPT].join(' ');
  const started = tmux(['new-session', '-d', '-s', 'live', '-x', '100', '-y', '40', command]);
  if (started.status !== 0) throw new Error('tmux could not start the session: ' + started.stderr);

  // 1. THE SCRIPT STREAMS: frames read while the fixture is still sending the argument.
  const scriptLines = SCRIPT.split('\n');
  const partial = new Set();
  const deadline = Date.now() + 90000;
  let frame = '';
  for (;;) {
    frame = screen_rows('live');
    const drawn = scriptLines.filter(line => frame.includes(line)).length;
    const dispatched = /[⏳✓✗] bash/.test(frame);
    if (!dispatched && drawn > 0 && drawn < scriptLines.length) partial.add(drawn);
    if (/⏳ bash/.test(frame) && /✓ bash/.test(frame)) break;
    if (Date.now() > deadline) throw new Error('timed out waiting for the waiting call');
    await sleep(25);
  }
  check('the interactive run asked the fixture for the script', askedForScript > asked,
    'script requested: ' + askedForScript);
  check('the script is drawn WHILE the model writes it: three or more different partial frames before the call is dispatched',
    partial.size >= 3, 'partial frames (script rows drawn): ' + JSON.stringify([...partial]));

  // 3. THE BAR, while the slow call waits.
  await sleep(700);
  const waiting = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'waiting.txt'), waiting);
  check('the frame was read while a call waits', /⏳ bash/.test(waiting), waiting);
  const groups = barGroups(waiting.split('\n'));
  check('the scrollbar is ONE bar while a call waits', groups.length === 1,
    'bar groups: ' + JSON.stringify(groups) + '\n' + waiting);
  const waitRow = waiting.split('\n').find(row => /⏳ bash/.test(row)) || '';
  check('and the waiting row itself ends in the bar', hasBar(waitRow), JSON.stringify(waitRow));
  check('no row starts with a bar glyph', !waiting.split('\n').some(row => BAR.has(row[0])), waiting);
  const topBefore = waiting.split('\n').slice(0, 6).join('\n');
  tmux(['send-keys', '-t', 'live', 'PPage']);
  await sleep(900);
  const scrolled = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'scrolled.txt'), scrolled);
  check('PgUp scrolls the transcript while the call is still waiting',
    scrolled.split('\n').slice(0, 6).join('\n') !== topBefore, scrolled);
  const groupsAfter = barGroups(scrolled.split('\n'));
  check('and the bar is still ONE bar after scrolling', groupsAfter.length === 1,
    'bar groups: ' + JSON.stringify(groupsAfter) + '\n' + scrolled);

  // 2. ONE COPY OF THE OUTPUT, and the click.
  const settleBy = Date.now() + (SLOW_SECONDS + 30) * 1000;
  let settled = '';
  for (;;) {
    settled = screen_rows('live');
    if (settled.includes('Both commands ran') && !settled.includes('(PgDn)')) break;
    if (Date.now() > settleBy) throw new Error('timed out waiting for the run to settle');
    // Back to the bottom the way the reader goes there (the PgUp above left the view scrolled).
    if (settled.includes('(PgDn)')) tmux(['send-keys', '-t', 'live', 'NPage']);
    await sleep(150);
  }
  await sleep(700);
  settled = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'settled.txt'), settled);
  // THE RESULT IS ONE ROW NOW (chat-view-round-2, item 4): no line of it is printed until the reader
  // opens it, so "exactly once" became "not at all by default", and the count below names the size.
  check('settled: no line of the output is on screen until the row is opened', count(settled, LINE_1) === 0,
    'line 1 x' + count(settled, LINE_1) + '\n' + settled);
  check('settled: no output lines under the call rows (line 2 is a click away)',
    count(settled, /line 2(?!\d)/g) === 0 && !QUICK_OUT.test(settled), settled);
  // The count is the size of the result the model got, CHARACTER for character: no line is drawn here,
  // so a row that counted the rows it drew would count nothing.
  check('settled: the result row names the exact size and is not a JSON-quoted string',
    settled.includes('⎿ script output · ' + OUTPUT.length + ' chars') && !settled.includes('\\n'), settled);
  check('settled: both calls are one ticked row each', count(settled, /✓ bash · /g) === 2, settled);

  const resultRow = rowOf(settled, /⎿ script output/);
  await mouse('live', 6, resultRow);
  let opened = screen_rows('live');
  fs.writeFileSync(path.join(WORK, 'opened.txt'), opened);
  // A row of the opened result starts at the frame's own column (the text is drawn as it is, with no
  // marker in front): the old pattern required a space before the line, which only the `⎿ `-marked
  // first row had. Same intent, every line of the output must be on the screen.
  const lost = [...LINES, 'end'].filter(line => !new RegExp('(^|\\n)\\s*' + line + '\\s').test(opened));
  check('a click on the result row shows every line of the output', lost.length === 0,
    'missing: ' + JSON.stringify(lost) + '\n' + opened);
  check('opened: still one copy', count(opened, /line 7/g) === 1, opened);
  // Every row the opened result covers answers the click (rust/wa-term `rows_with_copies`), so the fold
  // is reached from a row of the text itself - the `⎿ ` row is not drawn while it is open.
  await mouse('live', 6, rowOf(opened, /line 1(?!\d)/));
  const folded = screen_rows('live');
  check('a second click folds it to the one row again',
    count(folded, /line 7/g) === 0 && folded.includes('⎿ script output · ' + OUTPUT.length + ' chars'), folded);

  // Each call's own output is one click on ITS row away.
  const quickRow = rowOf(folded, /✓ bash · /);
  await mouse('live', 6, quickRow);
  const quickOpen = screen_rows('live');
  check('a click on a call row shows what that call said', QUICK_OUT.test(quickOpen), quickOpen);
  await mouse('live', 6, rowOf(quickOpen, /✓ bash · /));
  const quickFolded = screen_rows('live');
  check('and a second click hides it', !QUICK_OUT.test(quickFolded), quickFolded);
  check('the bar is one bar in the settled frame too', barGroups(quickFolded.split('\n')).length === 1, quickFolded);
} catch (error) {
  failed += 1;
  console.error('run-block-pty: the interactive half FAILED - ' + error.message);
  try { console.error('---- the screen ----\n' + screen_rows('live')); } catch {}
} finally {
  tmux(['kill-server']);
}

server.close();
if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
else console.error('run-block-pty: scratch kept for diagnosis: ' + WORK);
console.log('run block pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, ' + skipped + ' skipped');
process.exitCode = failed === 0 ? 0 : 1;
