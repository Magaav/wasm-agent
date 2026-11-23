#!/usr/bin/env node
// /UNDO IN `wa chat` PUTS THE FILE BACK (mission remote-undo-works, 23/11).
//
// What was measured on the base commit: the `remote` tool's own description tells the model "the change is
// recorded here, so /undo restores that file there", `changeset` records the change, the window's /diff
// route can undo it - and a chat has no /undo at all. Typing it answered "unknown or incomplete command
// /undo - /help lists them". So this drives the REAL binary in a real pty (a PRIVATE tmux server) against
// a local SSE fixture that plays the model, and reads the screen back:
//
//   * the model writes a file (turn 1), rewrites one line of it (turn 2) - two recorded changes;
//   * `/undo` prints what it put back, naming the file, the machine and the VERSION (the recorded text's
//     own sha256), and the file on disk is byte-for-byte what it was before turn 2, with that version;
//   * `/undo` never reaches the model: the fixture's request count does not move when it is typed;
//   * a second `/undo` refuses BY NAME (`version_moved`) instead of restoring over the reader's state,
//     and changes nothing.
//
// Isolation is scripts/test-chat-start-pty.mjs's: tmux on a private socket (-L), `env -i` plus an
// allow-list (no rendezvous, no relay, no vault), a scratch HOME that REFUSES to be the real
// ~/.wasm-agent, the run's cwd inside that scratch directory (never the checkout), and a FAILURE (never a
// pass) when the fixture was not asked for the answer it serves - a turn that reached some other
// endpoint proves nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-undo-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');

function resolvedBin(name) {
  if (name.includes('/')) return path.resolve(name);
  const found = spawnSync('sh', ['-c', 'command -v ' + name], {encoding: 'utf8'});
  const line = String(found.stdout || '').trim().split('\n')[0];
  return line || name;
}
const BIN = resolvedBin(process.env.WA_BIN || process.env.FAST_BIN || 'wa');

// This node's TMPDIR points INTO ~/.wasm-agent/tmp, so os.tmpdir() alone would put the ledger beside real
// state - which the guard below then (correctly) refuses.
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('undo-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-undo-pty-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('undo-pty: refusing to run with HOME inside the real ' + REAL_HOME);
  process.exit(2);
}
const TARGET = path.join(WORK, 'demo.txt');

let checks = 0;
let failed = 0;
function check(name, condition, detail = '') {
  checks += 1;
  if (condition) { console.log('ok - ' + name); return true; }
  failed += 1;
  console.log('FAIL - ' + name + (detail ? '\n       ' + String(detail).split('\n').join('\n       ') : ''));
  return false;
}
const sha = text => crypto.createHash('sha256').update(text, 'utf8').digest('hex');

// ---- the fixture: the model, and only the model ------------------------------------------------
//
// One SSE answer per request. The rule is the conversation's own shape: the last message is a tool
// result, so the turn has what it asked for and gets a final sentence; otherwise the turn gets the one
// write it makes. Which text it writes is the file's own state - the FIRST write creates three lines, the
// SECOND changes the middle one, the way the operator's own test asks for it.
const V1 = 'one\ntwo\nthree\n';
const V2 = 'one\nTWO\nthree\n';
const FINAL1 = 'created the demo file';
const FINAL2 = 'changed the second line';
let requests = 0;
let writes = 0;
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
    if (last === 'tool') {
      const final = fs.existsSync(TARGET) && fs.readFileSync(TARGET, 'utf8') === V2 ? FINAL2 : FINAL1;
      res.write('data: ' + JSON.stringify({id: 'u2', choices: [{index: 0, delta: {role: 'assistant', content: final}}]}) + '\n\n');
      res.write('data: ' + JSON.stringify({id: 'u2', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
    } else {
      writes += 1;
      const content = fs.existsSync(TARGET) ? V2 : V1;
      const args = JSON.stringify({path: TARGET, content});
      res.write('data: ' + JSON.stringify({id: 'u1', choices: [{index: 0, delta: {role: 'assistant', content: null,
        tool_calls: [{index: 0, id: 'call_undo_' + writes, type: 'function', function: {name: 'write', arguments: ''}}]}}]}) + '\n\n');
      res.write('data: ' + JSON.stringify({id: 'u1', choices: [{index: 0, delta: {tool_calls: [{index: 0,
        function: {arguments: args}}]}}]}) + '\n\n');
      res.write('data: ' + JSON.stringify({id: 'u1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]}) + '\n\n');
    }
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
  // No roster and no relay: nothing here may reach another node, so a real fleet cannot be called.
  WASM_AGENT_RENDEZVOUS: '',
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  WASM_AGENT_CLI_OPENING: 'off',
  COLUMNS: '110',
  LINES: '34',
};

const HAVE_TMUX = spawnSync('tmux', ['-V'], {encoding: 'utf8'}).status === 0;
if (!HAVE_TMUX) {
  console.log('SKIP test-undo-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const SOCKET = 'wa-undo-pty-' + process.pid;
const SESSION = 'undo';
const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], {encoding: 'utf8'});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function capture() {
  const raw = String(tmux(['capture-pane', '-p', '-t', SESSION]).stdout || '').replace(/\r/g, '');
  return raw.split('\n').map(row => row.replace(/\s+$/, ''));
}
async function waitFor(predicate, label, timeout = 45000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await sleep(50);
  }
}
const screen = () => capture().join('\n');
const fileText = () => (fs.existsSync(TARGET) ? fs.readFileSync(TARGET, 'utf8') : null);

let started = false;
let restoredVersion = null;
try {
  restoredVersion = sha(V1);
  // The reader's cwd is the scratch directory, never the checkout: a write that resolves relative to the
  // cwd cannot land in this tree.
  const command = [
    'env', '-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'chat',
  ].join(' ');
  tmux(['kill-server']);
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', '110', '-y', '34', '-c', WORK, command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;

  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  // ---- turn 1: the file is created -------------------------------------------------------------
  tmux(['send-keys', '-t', SESSION, 'create the demo file with three lines', 'Enter']);
  await waitFor(() => screen().includes(FINAL1) && fileText() === V1, 'the first turn to land');
  check('the model wrote the file (three lines) and the chat said so', fileText() === V1, JSON.stringify(fileText()));
  const createdVersion = sha(V1);

  // ---- turn 2: the middle line changes ----------------------------------------------------------
  tmux(['send-keys', '-t', SESSION, 'change the second line', 'Enter']);
  await waitFor(() => screen().includes(FINAL2) && fileText() === V2, 'the second turn to land');
  check('the second turn changed one line', fileText() === V2, JSON.stringify(fileText()));
  check('the file is no longer what the first turn left', sha(fileText()) !== createdVersion);

  // ---- /undo ---------------------------------------------------------------------------------
  const requestsBeforeUndo = requests;
  const rowsBefore = capture().length;
  tmux(['send-keys', '-t', SESSION, '/undo', 'Enter']);
  const answer = await waitFor(() => capture().find(row => row.includes('undo:')), 'the undo answer');
  check('typing /undo is answered by the chat', /undo:/.test(answer), answer);
  check('the answer names the file it put back', answer.includes(TARGET), answer);
  check('it says the file is on this node', answer.includes('this node'), answer);
  check('it names the version the file now holds (the recorded text\'s own sha256)',
    answer.includes('version ' + restoredVersion.slice(0, 12)),
    'restored version ' + restoredVersion.slice(0, 12) + ' not in: ' + answer);
  check('the file on disk is byte-for-byte what it was before the change', fileText() === V1, JSON.stringify(fileText()));
  check('and its version is the one the answer named', sha(fileText()) === restoredVersion);
  // NOTHING about /undo may reach the model: the fixture is the only model, and it counts its requests.
  check('/undo never reached the model (the fixture served no request for it)',
    requests === requestsBeforeUndo,
    'requests ' + requestsBeforeUndo + ' -> ' + requests + '; a slash command is the reader\'s');
  check('the answer appeared as a new row, not by rewriting the screen above it',
    capture().length >= rowsBefore);

  // ---- /undo again: refused by name, and nothing changes ---------------------------------------
  tmux(['send-keys', '-t', SESSION, '/undo', 'Enter']);
  const refusal = await waitFor(() => capture().find(row => row.includes('refused (')),
    'the refusal of a second undo');
  check('a second /undo refuses by name', refusal.includes('refused (version_moved)'), refusal);
  // The reason travels on its own row (a path makes it long, and a narrow terminal would cut the one
  // half that says WHICH file moved), so the whole screen is read for it - not only the row above.
  check('the refusal quotes the reason the record gave', screen().includes('changed_since_turn'), screen());
  check('and the file still holds the text the first undo put back', fileText() === V1, JSON.stringify(fileText()));
  check('the refusal did not reach the model either', requests === requestsBeforeUndo);

  // ---- the promise and the product agree -------------------------------------------------------
  // The model's own instructions still say /undo restores a peer's file, so the row that makes it true
  // has to be in the help a reader is shown. Read from the registry the binary carries (this chat's own
  // /help is a paged balloon, and paging it would be a test of the balloon, not of /undo).
  const help = spawnSync('env', ['-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    BIN, '--db', path.join(WORK, 'ledger.db'), 'status'], {encoding: 'utf8', timeout: 60000});
  const helpScript = path.join(WORK, 'help.lua');
  fs.writeFileSync(helpScript, 'print(dofile("lua/core/commands.lua").help())\n');
  const listed = spawnSync('env', ['-i', ...Object.entries(ENV).map(([key, value]) => key + '=' + value),
    'WA_SCRIPT=' + helpScript, BIN, '--db', path.join(WORK, 'ledger.db')], {encoding: 'utf8', timeout: 60000});
  const helpText = String(listed.stdout || '');
  check('/help lists /undo (the registry the chat reads is the shipped one)',
    /^\s*\/undo\s+\S/m.test(helpText), helpText.split('\n').filter(row => row.includes('undo')).join('\n')
      || ('status ' + help.status + '; ' + String(listed.stderr || '').split('\n')[0]));
} catch (error) {
  failed += 1;
  console.error('undo-pty: FAILED - ' + error.message);
  try { console.error(capture().filter(row => row !== '').join('\n')); } catch {}
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('undo-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('undo pty: ' + (checks - failed) + ' ok, ' + failed + ' failed');
process.exitCode = failed === 0 ? 0 : 1;
