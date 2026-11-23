#!/usr/bin/env node
// A COMMAND A RUN BLOCK RAN SAYS WHICH FILES IT CHANGED - ON THE SCREEN (chat-view-round-2, item 2).
//
// Victor, 23/11: "edit rounds does not get the code diff printed". The diff card existed for a
// `write`/`edit` the model called; a change made by a COMMAND was watched only on the dispatcher's
// direct bash path, and a run block's bash never reaches the end of that path - it starts a managed
// operation and returns. Code mode is the one execution path this node has, so in practice no command
// ever drew a card. Measured on the base: the same command dispatched directly emitted
// `bash_changes[1] tracked.txt`; inside a `run` block it emitted nothing.
//
// This drives the REAL binary in a real pty (a private tmux server) against a local fixture that plays
// the model, in a scratch git work tree, and reads the screen back:
//   1. the script's own call row is there (the per-call rows did not change);
//   2. the file the command CREATED is named by a card on the screen - the base printed nothing, and
//      `git status -uno` used to hide every created file even on the direct path;
//   3. the card is the same one a write draws: a heading naming the path and a count row;
//   4. the model's result did not grow a card into it: the run block still shows its one
//      `script output · N chars` row (the two features do not cancel each other).
//
// Isolation is scripts/test-diff-card-pty.mjs's: a scratch HOME that refuses to be the real
// ~/.wasm-agent, env -i plus an allow-list, and a FAILURE (never a pass) when the fixture served
// nothing.
//
// Run: WA_BIN=<wa binary> node scripts/test-bash-changes-pty.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const REAL_HOME = path.join(os.homedir(), '.wasm-agent');
const SCRATCH_ROOT = [os.tmpdir(), '/tmp', '/var/tmp']
  .find(base => !path.resolve(base).startsWith(REAL_HOME + path.sep));
if (!SCRATCH_ROOT) {
  console.error('bash-changes-pty: no scratch root outside ' + REAL_HOME + '; refusing to run');
  process.exit(2);
}
const WORK = fs.mkdtempSync(path.join(SCRATCH_ROOT, 'wa-bash-changes-'));
const HOME = path.join(WORK, 'home');
fs.mkdirSync(HOME, {recursive: true});
if (path.resolve(HOME) === path.resolve(REAL_HOME) || HOME.startsWith(REAL_HOME + path.sep)) {
  console.error('bash-changes-pty: refusing to run with HOME inside the real ' + REAL_HOME);
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

// The work tree the command runs in: the module reads it with git, and a create is only visible as a
// change when git can list an untracked file.
const TREE = path.join(WORK, 'tree');
fs.mkdirSync(TREE, {recursive: true});
const git = args => spawnSync('git', ['-C', TREE, ...args], {encoding: 'utf8'});
const seeded = [['init', '-q', '.'], ['config', 'user.email', 'test@example.invalid'],
  ['config', 'user.name', 'test']].every(([first, ...rest]) => git([first, ...rest]).status === 0);
if (!seeded) {
  console.log('SKIP test-bash-changes-pty: no git on PATH, and the change watcher reads the work tree with it');
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}
fs.writeFileSync(path.join(TREE, 'seed.txt'), 'seed\n');
git(['add', '-A']);
git(['commit', '-qm', 'seed']);

// ---- the fixture: the model, and only the model ------------------------------------------------
const MADE = 'made-by-a-script.txt';
const PLAN = [
  {final: 'made it with a command', tool: 'run', args: {code:
    'const r = await tools.bash({command:"printf \'hello\\n\' > ' + MADE + '", cwd:'
      + JSON.stringify(TREE) + '}); return "done";'}},
];
let turn = 0;
let requests = 0;

function sse(res, delta) {
  res.write('data: ' + JSON.stringify({id: 'c', choices: [{index: 0, delta}]}) + '\n\n');
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
    if (last === 'tool' || !at) {
      sse(res, {role: 'assistant', content: at ? at.final : 'done'});
      res.write('data: ' + JSON.stringify({id: 'f', choices: [{index: 0, delta: {}, finish_reason: 'stop'}]}) + '\n\n');
      turn += 1;
    } else {
      sse(res, {role: 'assistant', content: null,
        tool_calls: [{index: 0, id: 'call_0', type: 'function', function: {name: at.tool, arguments: ''}}]});
      sse(res, {tool_calls: [{index: 0, function: {arguments: JSON.stringify(at.args)}}]});
      sse(res, {});
      res.write('data: ' + JSON.stringify({id: 'c', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]}) + '\n\n');
    }
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const COLS = 110, ROWS = 44;
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
  console.log('SKIP test-bash-changes-pty: no tmux on PATH, and this test reads a real pty through it');
  server.close();
  fs.rmSync(WORK, {recursive: true, force: true});
  process.exit(0);
}

const SOCKET = 'wa-bash-changes-pty-' + process.pid;
const SESSION = 'bchg';
const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], {encoding: 'utf8'});
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
  const launch = tmux(['new-session', '-d', '-s', SESSION, '-x', String(COLS), '-y', String(ROWS), '-c', TREE, command]);
  if (launch.status !== 0) throw new Error('tmux could not start the session: ' + launch.stderr);
  started = true;
  await waitFor(() => screen().includes('Type a message'), 'the prompt');
  check('the chat is at its prompt', true);

  tmux(['send-keys', '-t', SESSION, 'make the file with a command', 'Enter']);
  await waitFor(() => screen().includes(PLAN[0].final), 'the turn');
  await sleep(600);
  const text = screen();
  check('the file the command created exists on disk (the command really ran)',
    fs.existsSync(path.join(TREE, MADE)), 'listing: ' + fs.readdirSync(TREE).join(', '));
  check('the command\'s own call row is still drawn (per-call rows did not change)',
    /bash/.test(text), text);
  // The heading names the PATH: the command's own row already quotes the file name (the script's
  // source is on the screen), so a bare `text.includes(MADE)` would pass on the base, which drew no
  // card at all. Measured on the base: this check failed, the bare one passed.
  check('a card heading names the created file, the same heading a write draws',
    new RegExp('(Create|Update|Delete)\([^)]*' + MADE.replace(/\./g, '\\.') + '\)').test(text), text);
  check('and its count row', /Added \d+ lines?/.test(text), text);
  check('the run block still shows its result as one `script output` row',
    /script output \u00b7 \d+ chars/.test(text), text);
  check('the change cost the model nothing: the turn ended with its own words',
    text.includes(PLAN[0].final), text);

  // ---- READ THE LEDGER BACK: the card is display only, the result is the model's --------------
  // The tool result the model received carries no change record: a card is the READER's (that rule is
  // the same one scripts/test-script-writes-show-diff.lua pins at the door; here it is read back from
  // a real run's ledger, by a second process).
  const db = path.join(WORK, 'ledger.db');
  const rows = spawnSync('sqlite3', ['-readonly', db,
    "select count(*) from messages where role='tool' and content like '%hello%'"], {encoding: 'utf8'});
  const leaked = Number(String(rows.stdout || '').trim()) || 0;
  check('the model\'s tool result does not carry the file\'s text (the card is the reader\'s)', leaked === 0,
    'tool rows mentioning the file contents: ' + leaked);
} catch (error) {
  failed += 1;
  console.error('bash-changes-pty: FAILED - ' + error.message);
} finally {
  if (started) tmux(['kill-server']);
  server.close();
  if (failed === 0) fs.rmSync(WORK, {recursive: true, force: true});
  else console.error('bash-changes-pty: scratch kept for diagnosis: ' + WORK);
}

console.log('bash changes pty: ' + (checks - failed) + ' ok, ' + failed + ' failed, ' + requests + ' provider requests');
process.exitCode = failed === 0 ? 0 : 1;
