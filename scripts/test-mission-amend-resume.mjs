#!/usr/bin/env node
// A MISSION STARTED THE FACTORY'S WAY IS AMENDED, AND ITS RESUME REALLY RUNS A TURN.
//
// WHY THIS FILE EXISTS (measured 23/11, mission-resume-keeps-provider). `scripts/mission.sh amend` was used for
// real twice and failed both times in the same way: the mission had been started by the factory's own launcher
// (~/Work/missions/launch.sh + start.sh), which keeps wa-serve's environment in `serve.env` and writes NO `env`,
// so the runner amend wrote died at its line 5 - "<mission>/env: No such file or directory" - while amend.log
// already said "resumed" and the command exited 0. No turn ran and no model request was made.
//
// WHAT IS REAL HERE. The mission is laid out exactly as the factory lays one out: brief.md, prompt.md (the brief
// with the "Where you are" block after it, so no title marker), serve.env holding the whole environment the
// worker runs with, and a run.sh that sources serve.env and runs `wa chat --once` - the shape of
// ~/Work/missions/launch.sh's own run.sh, which cannot be called from a fixture (it needs systemd and the
// operator's missions root). The worker is a real `wa chat` process against this fixture's own node store, the
// amendment is delivered by the real `scripts/mission.sh amend` and the real `wa mission amend`, and the proof
// that a turn ran is the model request the fixture itself receives. The only lie is the PROVIDER: an SSE fixture,
// because a fixture may not call a model. Nothing here talks to a network, the operator's home, ~/Work/missions
// or a peer: the caller's own environment carries a DEAD provider URL on purpose, so a turn that read the
// caller's environment instead of serve.env cannot reach this fixture at all.
//
// Run: WA_BIN=<wa binary> node scripts/test-mission-amend-resume.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || 'wa';
const SCRATCH_BASE = fs.existsSync('/tmp') ? '/tmp' : os.tmpdir();
const WORK = fs.mkdtempSync(path.join(SCRATCH_BASE, 'wa-mission-amend-resume-'));
const HOME = path.join(WORK, 'home');
const NODE = path.join(HOME, '.wasm-agent');
const MISSIONS = path.join(WORK, 'missions');
const GITREPO = path.join(WORK, 'repo');

// A fixture that writes into the operator's own stores would be a real effect, not a test: refuse by name.
for (const [label, dir] of [['HOME', HOME], ['WASM_AGENT_HOME', NODE]]) {
  const resolved = path.resolve(dir);
  const operatorNode = path.join(path.resolve(os.homedir()), '.wasm-agent');
  if (resolved === path.resolve(os.homedir()) || resolved === operatorNode
    || resolved.startsWith(operatorNode + path.sep) || resolved === path.dirname(path.resolve(HOME))) {
    throw new Error(`the fixture refuses ${label}=${dir}: that is, or is inside, the operator's own home`);
  }
}
fs.mkdirSync(HOME, {recursive: true});
fs.mkdirSync(MISSIONS, {recursive: true});

let passed = 0;
function check(name, condition, detail = '') {
  if (!condition) throw new Error(`${name}${detail ? `: ${detail}` : ''}`);
  passed += 1;
  console.log(`ok - ${name}`);
}

// ---- the provider fixture ---------------------------------------------------------------------------
// One SSE answer per request. The FIRST request of a turn asks for a read-only tool call, so the turn has a
// context boundary inside it - which is where a steering note is consumed; the request after the tool result is
// the boundary itself, and it answers with how many amendments the model was actually shown. Request 0 is HELD
// until this file has run amend, so the note is in the node's inbox while the turn is genuinely in flight -
// deterministically, not by sleeping.
const requests = [];
function holdIndex(index) {
  let release = () => {};
  const promise = new Promise(resolve => { release = resolve; });
  held.set(index, promise);
  return release;
}
const held = new Map();
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', async () => {
    let parsed = {};
    try { parsed = JSON.parse(body); } catch {}
    const messages = parsed.messages || [];
    const index = requests.push({messages}) - 1;
    const usage = {prompt_tokens: 10, completion_tokens: 2, total_tokens: 12};
    const send = chunks => {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      for (const chunk of chunks) res.write(`data: ${JSON.stringify(chunk)}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    };
    if (held.has(index)) await held.get(index);
    const last = messages[messages.length - 1] || {};
    if (last.role !== 'tool') {
      send([
        {id: `mock-${index}`, choices: [{index: 0, delta: {role: 'assistant', tool_calls: [
          {index: 0, id: `call-read-${index}`, type: 'function', function: {name: 'read', arguments: JSON.stringify({path: 'brief.md', limit: 2})}},
        ]}, finish_reason: null}]},
        {id: `mock-${index}`, choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]},
        {id: `mock-${index}`, choices: [], usage},
      ]);
      return;
    }
    const shown = messages.filter(message => message.role === 'user')
      .map(message => String(message.content || ''))
      .filter(content => /\[amendment \d{4}-\d\d-\d\dT/.test(content));
    send([
      {id: `mock-${index}`, choices: [{index: 0, delta: {role: 'assistant', content: `boundary-${index} saw ${shown.length} amendment(s)`}, finish_reason: null}]},
      {id: `mock-${index}`, choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: `mock-${index}`, choices: [], usage},
    ]);
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;
const LIVE = `http://127.0.0.1:${PORT}`;
// A port nothing listens on: the CALLER's environment points here, serve.env points at the fixture, so a turn
// that used the wrong one makes no request this file can see.
const DEAD = 'http://127.0.0.1:1';

const BASE_ENV = {
  ...process.env,
  HOME,
  WASM_AGENT_HOME: HOME,
  WASM_AGENT_DB: path.join(NODE, 'memory.db'),
  MISSION_NODE_HOME: NODE,
  MISSION_REPO: GITREPO,
  MISSIONS_DIR: MISSIONS,
  MISSION_ROOT: MISSIONS,
  WA_BIN: BIN,
  WASM_AGENT_LUA_ROOT: REPO,
  WASM_AGENT_PROVIDER: 'opencode-go',
  WASM_AGENT_LLM_API_KEY: 'test-only',
  WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE: path.join(WORK, 'no-models-store'),
  WASM_AGENT_RENDEZVOUS: '',
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  WASM_AGENT_PROVIDER_CONNECT_RETRIES: '0',
  COLUMNS: '100',
  TERM: 'xterm-256color',
};
for (const key of ['WASM_AGENT_RAW_CODE', 'WASM_AGENT_VAULT_URL', 'WASM_AGENT_VAULT_DIR',
  'WASM_AGENT_OPENAI_BASE_URL', 'OPENCODE_GO_API_KEY', 'OPENAI_API_KEY']) delete BASE_ENV[key];
// The caller (the orchestrator's shell) cannot reach a provider: only serve.env can.
const ENV = {...BASE_ENV, WASM_AGENT_LLM_BASE_URL: DEAD};

const mission = (...args) => spawnSync('bash', [path.join(REPO, 'scripts', 'mission.sh'), ...args],
  {cwd: REPO, env: ENV, encoding: 'utf8', timeout: 300000, stdio: ['ignore', 'pipe', 'pipe']});
const cli = (...args) => spawnSync(BIN, args, {cwd: REPO, env: ENV, encoding: 'utf8', timeout: 120000});
const git = (...args) => spawnSync('git', args, {cwd: GITREPO, encoding: 'utf8'});
const read = file => { try { return fs.readFileSync(file, 'utf8'); } catch { return ''; } };
const readOpt = (file, options) => { try { return fs.readFileSync(file, options); } catch { return Buffer.alloc(0); } };

function waitFor(predicate, label, timeout = 180000) {
  const deadline = Date.now() + timeout;
  return new Promise((resolve, reject) => {
    const tick = () => {
      let value = null;
      try { value = predicate(); } catch { value = null; }
      if (value) return resolve(value);
      if (Date.now() > deadline) return reject(new Error(`timed out waiting for ${label}`));
      setTimeout(tick, 50);
    };
    tick();
  });
}

// ---- a mission laid out the way the factory's launcher and start.sh lay one out ---------------------
// brief.md, prompt.md (brief first: no title marker), serve.env (wa-serve's environment, provider settings in
// it), and a run.sh that sources serve.env and runs one `wa chat --once`, its rc landing in `done`.
let ownPids = [];
function factoryMission(name, {baseUrl = LIVE, brief} = {}) {
  const dir = path.join(MISSIONS, name);
  fs.mkdirSync(dir, {recursive: true});
  const text = brief || `# ${name}: a fixture mission started the factory way\n\nDo the fixture work.\n`;
  fs.writeFileSync(path.join(dir, 'brief.md'), text);
  fs.writeFileSync(path.join(dir, 'prompt.md'),
    `${text}\n## Where you are\nYour code is the git worktree ${dir}/wt; build and test HERE.\n`);
  // serve.env IS wa-serve's environment, as start.sh writes it: KEY=value lines that the mission's runner and
  // every resumed turn source in their own shell. The values are single-quoted here (start.sh writes them bare)
  // because a scratch HOME carries paths and a terminal carries words with spaces in them, and a sourced line
  // has to be one shell word to survive - a fixture detail, not a product one.
  const serve = {...BASE_ENV, WASM_AGENT_LLM_BASE_URL: baseUrl};
  fs.writeFileSync(path.join(dir, 'serve.env'),
    Object.entries(serve).filter(([, value]) => typeof value === 'string')
      .map(([key, value]) => `${key}='${value.replace(/'/g, `'\\''`)}'`).join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'run.sh'), `#!/usr/bin/env bash
# the factory's shape: start.sh hands this unit wa-serve's environment (serve.env) and nothing else.
set -uo pipefail
M=${dir}
cd "$M" || exit 96
set -a
. "$M/serve.env" || exit 98
set +a
unset WASM_AGENT_RAW_CODE
"${BIN}" chat --once "$(cat "$M/prompt.md")" >> "$M/out.log" 2>> "$M/err.log"
rc=$?
printf 'rc=%s %s\n' "$rc" "$(date -u +%FT%TZ)" > "$M/done"
exit "$rc"
`);
  return dir;
}

function startWorker(dir) {
  const worker = spawn('bash', [path.join(dir, 'run.sh')], {cwd: dir, env: ENV, stdio: ['ignore', 'ignore', 'ignore']});
  if (Number.isInteger(worker.pid) && worker.pid > 0) ownPids.push(worker.pid);
  return worker;
}

const doneAt = dir => { try { return fs.statSync(path.join(dir, 'done')).mtimeMs; } catch { return 0; } };

// Only pids this file started are signalled, and only while their cmdline still names this fixture's scratch
// directory (FACTORY rule 17: never a name pattern, and never a number the kernel reused).
function killOwn() {
  for (const pid of ownPids) {
    if (!Number.isInteger(pid) || pid <= 0) continue;
    let cmd = '';
    try { cmd = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').join(' '); } catch { continue; }
    if (!cmd.includes(WORK)) continue;
    try { process.kill(pid, 'SIGTERM'); } catch {}
  }
}

try {
  fs.mkdirSync(GITREPO, {recursive: true});
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'fixture@example.invalid');
  git('config', 'user.name', 'fixture');
  fs.writeFileSync(path.join(GITREPO, 'README.md'), 'base\n');
  git('add', 'README.md');
  git('commit', '-qm', 'base commit');
  cli('sessions', '5');
  check('the scratch node answers and has a store of its own', fs.existsSync(path.join(NODE, 'memory.db')));

  // ---- 1. A WORKER IN FLIGHT IS STEERED, NOT RESUMED (the factory's own shape) ----------------------
  const inflight = factoryMission('inflight');
  check('the factory-style mission keeps its provider settings in serve.env and has no env file',
    fs.existsSync(path.join(inflight, 'serve.env')) && !fs.existsSync(path.join(inflight, 'env')));
  const releaseFirst = holdIndex(0);
  startWorker(inflight);
  await waitFor(() => requests.length >= 1, "the factory worker's first model request");
  const note1 = 'Use the matrix green for the star, not the white one.';
  const note1File = path.join(WORK, 'note1.txt');
  fs.writeFileSync(note1File, note1 + '\n');
  const a1 = mission('amend', 'inflight', note1File);
  const stamp1 = (a1.stdout.match(/amendment (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)/) || [])[1];
  check('amend delivers to a factory worker whose run is in flight, by steering it',
    a1.status === 0 && /queued for run/.test(a1.stdout), `${a1.status} ${a1.stdout}${a1.stderr}`);
  check('and it starts no resume: no runner was written for a worker that is running',
    !fs.existsSync(path.join(inflight, 'amend-run.sh')), a1.stdout);
  check('and amend.log records it queued with the node receipt',
    / queued \S+ \S+ run=\S+/.test(read(path.join(inflight, 'amend.log'))), read(path.join(inflight, 'amend.log')));
  check('and the node says the receipt is queued or read', /the node says (queued|read)/.test(a1.stdout), a1.stdout);
  releaseFirst();
  await waitFor(() => /rc=0/.test(read(path.join(inflight, 'done'))), 'the in-flight turn to finish');
  const boundary1 = requests[requests.length - 1].messages;
  check('the worker saw the amendment at its next context boundary, exactly once',
    boundary1.filter(message => String(message.content || '').includes(stamp1)).length === 1,
    JSON.stringify(boundary1).slice(-600));
  check('and what it saw is the labelled amendment, not a paraphrase',
    boundary1.some(message => String(message.content || '') === `[amendment ${stamp1} from the planner] ${note1}`));

  // ---- 2. A SETTLED FACTORY WORKER IS RESUMED, AND THE TURN REALLY RUNS ----------------------------
  const note2 = 'Also make the wording say 0.1.0.';
  const note2File = path.join(WORK, 'note2.txt');
  fs.writeFileSync(note2File, note2 + '\n');
  const before2 = requests.length;
  const doneBefore2 = doneAt(inflight);
  const a2 = mission('amend', 'inflight', note2File);
  const stamp2 = (a2.stdout.match(/amendment (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)/) || [])[1];
  check('a settled factory worker is resumed with the amendment',
    a2.status === 0 && /RESUMED/.test(a2.stdout) && /that turn is running now/.test(a2.stdout),
    `${a2.status} ${a2.stdout}${a2.stderr}`);
  check('and amend.log records it resumed, with the pid it started',
    / resumed \S+ \S+ pid=\d+/.test(read(path.join(inflight, 'amend.log'))), read(path.join(inflight, 'amend.log')));
  await waitFor(() => requests.length > before2, "the resumed turn's model request", 120000);
  const resumed = requests[before2].messages;
  const resumedUser = resumed.filter(message => message.role === 'user');
  check('the resumed turn is a real model request, and the amendment is its message',
    String((resumedUser[resumedUser.length - 1] || {}).content || '')
      === `[amendment ${stamp2} from the planner] ${note2}`, JSON.stringify(resumedUser.slice(-2)));
  await waitFor(() => doneAt(inflight) > doneBefore2 && /rc=0/.test(read(path.join(inflight, 'done'))),
    'the resumed turn to end with its own rc');
  check("the resumed turn ran to its own rc=0 - the runner found the mission's provider settings in serve.env",
    /rc=0/.test(read(path.join(inflight, 'done'))), read(path.join(inflight, 'done')) + read(path.join(inflight, 'err.log')).slice(-500));

  // ---- 3. A RESUME WHOSE TURN NEVER STARTS IS resume_failed, AND THE COMMAND EXITS NON-ZERO --------
  const dead = factoryMission('deadprovider', {baseUrl: DEAD});
  const deadWorker = startWorker(dead);
  await new Promise(resolve => deadWorker.on('close', resolve));
  check('a mission whose provider answers nothing settles with its own rc', fs.existsSync(path.join(dead, 'done')),
    read(path.join(dead, 'out.log')).slice(-400) + read(path.join(dead, 'err.log')).slice(-400));
  const note3 = 'A change into a mission whose provider is not there.';
  const note3File = path.join(WORK, 'note3.txt');
  fs.writeFileSync(note3File, note3 + '\n');
  const a3 = mission('amend', 'deadprovider', note3File);
  check('a resume that never runs a turn is resume_failed, not resumed',
    a3.status !== 0 && /resume_failed/.test(a3.stdout) && !/RESUMED/.test(a3.stdout),
    `${a3.status} ${a3.stdout}${a3.stderr}`);
  check('and it quotes what the runner said instead of a success line',
    /it said:/.test(a3.stdout), a3.stdout);
  check('and amend.log records resume_failed',
    / resume_failed \S+ \S+ pid=\d+/.test(read(path.join(dead, 'amend.log'))), read(path.join(dead, 'amend.log')));
  const briefOnce = read(path.join(dead, 'brief.md'));
  const a3b = mission('amend', 'deadprovider', note3File);
  check('running it again retries the same text without appending it twice',
    fs.readFileSync(path.join(dead, 'brief.md'), 'utf8') === briefOnce && /without appending it twice/.test(a3b.stdout),
    `${a3b.status} ${a3b.stdout}${a3b.stderr}`);

  // ---- 4. NO ENVIRONMENT AT ALL IS REFUSED BY NAME, BEFORE ANYTHING SAYS RESUMED --------------------
  // A SETTLED WORKER WHOSE MISSION HAS NO ENVIRONMENT AT ALL: its session is recorded (the logs name one), so
  // amend gets as far as the resume - and must refuse there by name instead of starting a turn that cannot run.
  const bare = factoryMission('noenv');
  const bareWorker = startWorker(bare);
  await new Promise(resolve => bareWorker.on('close', resolve));
  check('the mission to be stripped ran a turn of its own first', /rc=0/.test(read(path.join(bare, 'done'))),
    read(path.join(bare, 'done')));
  fs.rmSync(path.join(bare, 'serve.env'));
  const a4 = mission('amend', 'noenv', note3File);
  check('a mission with neither env nor serve.env is refused by name, before anything says resumed',
    a4.status === 1 && /neither .*\/env nor .*\/serve.env/.test(a4.stdout) && !/RESUMED/.test(a4.stdout),
    `${a4.status} ${a4.stdout}${a4.stderr}`);
  check('and nothing was resumed: no runner was written', !fs.existsSync(path.join(bare, 'amend-run.sh')));
  check('and amend.log keeps it as undelivered/no_provider_env, so a later call delivers it once',
    / undelivered \S+ \S+ no_provider_env/.test(read(path.join(bare, 'amend.log'))), read(path.join(bare, 'amend.log')));

  // ---- 5. `wa mission resume` KEEPS THE PROVIDER SETTINGS -----------------------------------------
  const CLI = (...args) => spawnSync(BIN, args, {cwd: REPO, env: ENV, encoding: 'utf8', timeout: 300000});
  const before5 = requests.length;
  const doneBefore5 = doneAt(inflight);
  const r5 = CLI('mission', 'resume', 'inflight', '--force', '--msg', 'continue from the CLI');
  let answer5 = {};
  try { answer5 = JSON.parse(r5.stdout); } catch {}
  check('wa mission resume resumes a mission staged the factory way (serve.env, no env file)',
    r5.status === 0 && answer5.ok === true, `${r5.status} ${r5.stdout}${r5.stderr}`);
  await waitFor(() => requests.length > before5, "the CLI resume's model request", 120000);
  const cliTurn = requests[before5].messages.filter(message => message.role === 'user');
  check('and that turn really runs: the model request reaches the fixture with the CLI message',
    String((cliTurn[cliTurn.length - 1] || {}).content || '') === 'continue from the CLI',
    JSON.stringify(cliTurn.slice(-2)));
  await waitFor(() => doneAt(inflight) > doneBefore5 && /rc=0/.test(read(path.join(inflight, 'done'))),
    'the CLI resumed turn to end with its own rc');

  // ---- 6. `wa mission amend`: THE SAME CODE, THROUGH THE CLI VERB ----------------------------------
  const note6 = 'The CLI door carries the same amendment.';
  const before6 = requests.length;
  const a6 = CLI('mission', 'amend', 'inflight', '--text', note6);
  let answer6 = {};
  try { answer6 = JSON.parse(a6.stdout); } catch {}
  check('wa mission amend runs the same code and reports its exit code',
    a6.status === 0 && answer6.exit === 0 && /RESUMED/.test(String(answer6.output || '')),
    `${a6.status} ${a6.stdout}${a6.stderr}`);
  check('and it names the script it ran', /\/scripts\/mission\.sh$/.test(String(answer6.script || '')));
  await waitFor(() => requests.length > before6, "the door's resumed turn", 120000);
  const doorTurn = requests[before6].messages.filter(message => message.role === 'user');
  check('and the amendment it delivered is the message of the turn it started',
    /^\[amendment \d{4}-\d\d-\d\dT/.test(String((doorTurn[doorTurn.length - 1] || {}).content || ''))
      && String((doorTurn[doorTurn.length - 1] || {}).content || '').endsWith(note6),
    JSON.stringify(doorTurn.slice(-1)));
  await waitFor(() => /rc=0/.test(read(path.join(inflight, 'done'))), 'the door turn to end');

  // ---- 7. THE DOOR'S REFUSALS, BY NAME ------------------------------------------------------------
  const n1 = CLI('mission', 'amend', 'nothere', note1File);
  check('a mission that is not there is refused by name', n1.status === 1 && /no_mission/.test(n1.stdout),
    `${n1.status} ${n1.stdout}${n1.stderr}`);
  const n2 = CLI('mission', 'amend', 'inflight');
  check('amend with neither a file nor --text is its usage',
    n2.status === 1 && /file_required/.test(n2.stdout) && /--text/.test(n2.stdout), `${n2.status} ${n2.stdout}`);
  const n3 = CLI('mission', 'amend', 'inflight', '--script', path.join(WORK, 'no-such-mission.sh'), '--text', 'x');
  check('a script named with --script that cannot be read is refused by name, never silently replaced',
    n3.status === 1 && /amend_script_missing/.test(n3.stdout) && /no-such-mission\.sh/.test(n3.stdout),
    `${n3.status} ${n3.stdout}${n3.stderr}`);

  console.log(`mission amend/resume (factory shape): ${passed} checks passed`);
} catch (error) {
  console.error(`mission amend/resume: FAILED after ${passed} checks: ${error.message}`);
  console.error(`fixture kept for diagnosis: ${WORK}`);
  for (const name of ['inflight', 'deadprovider', 'noenv']) {
    const dir = path.join(MISSIONS, name);
    console.error(`--- ${name}/amend.log\n${read(path.join(dir, 'amend.log'))}`);
    console.error(`--- ${name}/out.log (last 20 lines)\n${read(path.join(dir, 'out.log')).split('\n').slice(-20).join('\n')}`);
    console.error(`--- ${name}/err.log (last 10 lines)\n${read(path.join(dir, 'err.log')).split('\n').slice(-10).join('\n')}`);
  }
  process.exitCode = 1;
} finally {
  server.close();
  killOwn();
  if (!process.exitCode) fs.rmSync(WORK, {recursive: true, force: true});
}
