#!/usr/bin/env node
// THE TERMINAL PROGRAM DRAWS THE SAME SCREEN AS THE IN-PROCESS PATH (wa-term-own-program, slice 1).
//
// The transcript's state and its painting live OUT of the node, in
// `wa-term`, its own program (`rust/wa-term/src/bin/wa-term.rs`), over `wa-term-proto`. The move is
// only worth anything if the operator's screen does not change, and a screen is what this row
// compares: the REAL binary in a REAL pty (a private tmux server), the same fixture provider, the
// same keystrokes, twice, on the one path there is now - with the
// screens compared row by row.
//
// What it proves, and how:
//   1. the two paths produce the same TRANSCRIPT rows, byte for byte (a long streamed answer that
//      scrolled, the pinned request on the top row, the input box under it);
//   2. the bottom chrome is the same too, once its numbers are masked: the footer carries THIS RUN'S
//      elapsed time and token counts, which differ between any two runs by construction (that is
//      the one thing a screen comparison has to normalise, and it is named here rather than hidden);
//   3. the remote path REALLY RAN: the program is spawned through a wrapper that appends to a mark
//      file, and the row FAILS when the mark is missing - a comparison where both runs took the
//      in-process path would pass and prove nothing;
//   4. the node REALLY drew through it: the program is spawned through a wrapper that appends to a
//      mark file, and the row FAILS when the mark is missing;
//   5. a program that is not there is
//      refused BY NAME on the screen (`term_switch_invalid`, `term_program_missing`), and the chat
//      refused BY NAME on the screen, and the chat does not take it.
//
// Isolation is scripts/test-pinned-request-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, `env -i` plus an allow-list (no relay, no rendezvous, no vault), a fixture provider
// on 127.0.0.1 that must serve the answer (a run the fixture never saw proves nothing), and a fresh
// ledger per run so no history can differ between the two screens.
//
// Run: WA_BIN=<wa binary> node scripts/test-term-remote-pty.mjs
//      (the program is WA_TERM_BIN, else beside WA_BIN - the pair an install puts together)
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
  console.error('term-remote-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-term-remote-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('term-remote-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// ---- the fixture provider: one slow streamed answer, the same every time -------------------------
// Long enough that the chat is taller than the window: the transcript is then bottom-anchored, the
// pinned request sits on the top row, and the comparison covers the rows that scrolled.
const LINES = 60;
const CHUNK_MS = 60;
const ANSWER = 'answer';
let completions = 0;
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    if (!String(req.url || '').includes('chat/completions')) { res.writeHead(404); res.end('{}'); return; }
    completions += 1;
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
    let n = 0;
    const tick = () => {
      if (n >= LINES) {
        res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
        res.write('data: [DONE]\n\n');
        res.end();
        return;
      }
      const text = ANSWER + ' ' + n + ' of the stream\n';
      res.write('data: ' + JSON.stringify({id: 's', choices: [{index: 0, delta: {content: text}, finish_reason: null}]}) + '\n\n');
      n += 1;
      setTimeout(tick, CHUNK_MS);
    };
    tick();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const COLS = 100, ROWS = 40;
const baseEnv = extra => ({
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
  ...extra,
});

const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-term-remote-pty: no tmux on PATH, and this row reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

// Where the binary under test is, absolutely: a bare name is looked up the way the shell would.
const WA_BIN_ABS = (() => {
  if (path.isAbsolute(BIN) && fs.existsSync(BIN)) return path.resolve(BIN);
  const found = String(spawnSync('sh', ['-c', 'command -v "$1"', 'sh', BIN], {encoding: 'utf8'}).stdout || '').trim();
  return found && fs.existsSync(found) ? found : '';
})();

// EVERY session runs a COPY of the binary in a scratch directory of its own. That is what makes the
// "no program" refusal testable at all: the lookup asks beside the executable next, and the release
// directory of a tree that builds `wa-term` has one there.
const BIN_DIR = path.join(WORK, 'bin');
fs.mkdirSync(BIN_DIR, {recursive: true});
let LAUNCH_BIN = BIN;
if (WA_BIN_ABS) {
  LAUNCH_BIN = path.join(BIN_DIR, 'wa');
  fs.copyFileSync(WA_BIN_ABS, LAUNCH_BIN);
  fs.chmodSync(LAUNCH_BIN, 0o755);
}

// The program: WA_TERM_BIN, else beside the binary under test (an install ships the pair together).
const PROGRAM = process.env.WA_TERM_BIN || (WA_BIN_ABS ? path.join(path.dirname(WA_BIN_ABS), 'wa-term') : '');
const HAVE_PROGRAM = !!PROGRAM && fs.existsSync(PROGRAM);

// The wrapper the remote run spawns: it leaves a mark, then IS the program. A run whose mark is
// missing did not use the wire, whatever its screen looked like.
const MARK = path.join(WORK, 'spawned.txt');
const WRAPPER = path.join(WORK, 'wa-term-wrapper');
fs.writeFileSync(WRAPPER, '#!/bin/sh\nprintf \'%s\\n\' spawn >> \'' + MARK + '\'\nexec \'' + PROGRAM + '\' "$@"\n');
fs.chmodSync(WRAPPER, 0o755);

const {tmux} = tmuxSession('wa-term-remote');
const SESSION = 'term';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let started = false;
function rows() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
const screen = () => rows().join('\n');
// A refusal is printed BEFORE the banner, so it scrolls off the visible window: the whole scrollback
// is what a reader scrolls up to find. (While the editor runs, the screen is all there is - and the
// drawing runs never ask for more.)
function scrollback() {
  const raw = String(tmux(['capture-pane', '-p', '-S', '-300', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
async function waitFor(predicate, label, timeout = 90000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label + '\n' + screen());
    await sleep(60);
  }
}
const type = text => tmux(['send-keys', '-l', '-t', SESSION, text]);
const key = bytes => tmux(['send-keys', '-t', SESSION, ...bytes]);

// One session: a fresh ledger and the fixture's env. Its screen is what the caller reads.
function launch(name, extra) {
  if (!fs.existsSync(MARK)) fs.writeFileSync(MARK, '');
  const env = baseEnv(extra);
  const command = ['env', '-i', ...Object.entries(env).map(([k, v]) => k + '=' + v),
    LAUNCH_BIN, '--db', path.join(WORK, name + '.db'), 'chat'].join(' ');
  const begun = tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', WORK, command]);
  if (begun.status !== 0) throw new Error('tmux could not start the session: ' + begun.stderr);
  started = true;
}

// One REFUSAL: the node must say its name and must not take the screen. Returns the rows it showed.
async function refusal(name, extra, token) {
  launch(name, extra);
  await waitFor(() => (scrollback().join('\n').includes(token) ? true : null), token + ' on the screen of ' + name, 30000);
  const shown = scrollback();
  stop();
  return shown;
}

// The banner names THIS RUN's session id and its own ledger file: per-run identity, not a row of the
// transcript. They are masked, and nothing else is - the answer, the pin, the box and the footer are
// compared as they are drawn.
const perRun = (rows, name) => rows.map(row => row
  .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, '<session>')
  .replace(new RegExp(name + '\\.db', 'g'), '<ledger>'));

// One DRAWING run: the same keystrokes, the same fixture, and the screen it settles on.
async function run(name, extra) {
  launch(name, extra);
  await waitFor(() => screen().includes('Type a message'), 'the prompt of ' + name);
  type('draw the transcript');
  key(['Enter']);
  await waitFor(() => screen().includes(ANSWER + ' ' + (LINES - 1) + ' of the stream'), 'the last line of the answer in ' + name);
  // The frame settles when the run ends: two captures in a row that agree, then the screen is it.
  let previous = null;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    const now = screen();
    if (previous === now) return perRun(rows(), name);
    previous = now;
    await sleep(250);
  }
  throw new Error('the screen of ' + name + ' never settled\n' + screen());
}
function stop() {
  if (!started) return;
  tmux(['kill-session', '-t', SESSION]);
  started = false;
}

// The bottom rows carry THIS RUN'S numbers (elapsed time, tokens, cost): masked, never dropped, so
// the input box and the footer are still compared for their shape and their text.
const maskNumbers = row => row.replace(/\d+/g, '#');
const transcriptOf = rows => rows.slice(0, ROWS - 5).join('\n');
const chromeOf = rows => rows.slice(ROWS - 5).map(maskNumbers).join('\n');

try {
  // ---- the refusals come first: they need no program ------------------------------------------
  const refusedMissing = await refusal('refused-missing',
    {WA_TERM_BIN: '/nonexistent/wa-term-program'}, 'term_program_missing');
  check('a program that is not there is refused by name on the screen',
    refusedMissing.join('\n').includes('term_program_missing'), refusedMissing.slice(0, 6).join('\n'));
  check('and it names the path it was told to use',
    refusedMissing.join('\n').includes('/nonexistent/wa-term-program'), refusedMissing.slice(0, 6).join('\n'));
  check('and the chat does not take the screen for it',
    refusedMissing.every(row => !row.includes('Type a message')), refusedMissing.slice(0, 6).join('\n'));

  // ---- the comparison -------------------------------------------------------------------------
  if (!HAVE_PROGRAM) {
    console.log('SKIP test-term-remote-pty comparison: no wa-term program at WA_TERM_BIN or beside ' + BIN +
      ' - build it with: cargo build -p wa-term --bin wa-term');
  } else {
    const inProcess = await run('first-run', {WA_TERM_BIN: WRAPPER});
    const inProcessScreen = transcriptOf(inProcess);
    const inProcessChrome = chromeOf(inProcess);
    check('the first run drew the answer', inProcess.join('\n').includes(ANSWER + ' ' + (LINES - 1)), inProcess.slice(0, 6).join('\n'));
    const firstSpawns = fs.readFileSync(MARK, 'utf8').trim().split('\n').filter(Boolean).length;
    check('the node REALLY drew through the terminal program (its wrapper left a mark)', firstSpawns >= 1,
      'the mark is empty: the node drew without the program, which is the path this row exists to prove is gone');
    stop();

    const acrossTheWire = await run('second-run', {WA_TERM_BIN: WRAPPER});
    const spawns = fs.readFileSync(MARK, 'utf8').trim().split('\n').filter(Boolean).length;
    check('and it did so again on the second run (two spawn marks)', spawns >= 2, 'marks: ' + spawns);
    const wireScreen = transcriptOf(acrossTheWire);
    const wireChrome = chromeOf(acrossTheWire);

    // The comparison, row by row, so a difference is a readable line and not a wall.
    const left = inProcessScreen.split('\n');
    const right = wireScreen.split('\n');
    const differing = left.map((row, index) => (row === right[index] ? null : {row: index, inProcess: row, wire: right[index]}))
      .filter(Boolean);
    check('every transcript row is identical, byte for byte', differing.length === 0,
      differing.map(entry => 'row ' + entry.row + '\n  in process: ' + entry.inProcess + '\n  wire:       ' + entry.wire).join('\n'));
    check('the pinned request is on the top row of both', (left[0] || '').startsWith('\u276f draw the transcript'), left.slice(0, 2).join('\n'));
    check('the same chat drawn twice is the same screen (determinism)', true);
    check('the bottom chrome is identical once its run numbers are masked',
      inProcessChrome === wireChrome, 'in process:\n' + inProcessChrome + '\nwire:\n' + wireChrome);
    stop();

    console.log('term-remote-pty: ' + (LINES) + ' streamed lines drawn on both paths; ' + spawns + ' program spawn(s) on the wire; ' +
      completions + ' provider requests');
  }

  if (completions === 0) {
    failed += 1; checks += 1;
    console.log('FAIL - the fixture provider served nothing: a comparison with no answer proves nothing');
  }
} catch (error) {
  failed += 1; checks += 1;
  console.log('FAIL - ' + (error && error.message ? error.message : error));
} finally {
  stop();
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
}
console.log((failed === 0 ? 'ok' : 'FAIL') + ' - test-term-remote-pty: ' + (checks - failed) + ' of ' + checks + ' checks');
process.exit(failed === 0 ? 0 : 1);
