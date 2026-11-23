#!/usr/bin/env node
// A CHANGE REACHES A WORKER THAT IS ALREADY RUNNING, at its next context boundary, once - and a finished
// worker is resumed with it. This file is the fixture for `scripts/mission.sh amend <name> <file>`.
//
// WHY IT EXISTS. Measured on launch-opening 22/11: the worker reads its brief once, piped in at start
// (`stage` -> prompt.md -> `wa chat --once`), so three changes from Victor each waited for the whole turn to
// end and the mission took three passes; the orchestrator could not put a sentence into the live turn
// (`wa chat --session` on a live run is refused `resource_busy`) and killing it leaves a session claimed.
// The product's own steering is the door (`wa steer`, lua/core/steering.lua), and amend is the one command
// that uses it for a mission: append to brief.md with a UTC stamp, then deliver the same text.
//
// WHAT IS REAL HERE, and why it is not a stub: the mission is staged and started by scripts/mission.sh
// itself, the worker is a real `wa chat --once` process against this file's own node store, the note is
// delivered by a real `wa steer` from another process, and the worker's next model request is what proves
// the note arrived. The only lie is the PROVIDER: an SSE fixture (the same shape as
// scripts/test-cli-scripted.mjs reads out of rust/wa-capabilities/src/host.rs), because a fixture may not
// call a model. Nothing here talks to a network, the operator's home, ~/Work/missions or a peer.
//
// Run: WA_BIN=<wa binary> node scripts/test-mission-amend.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || 'wa';
// os.tmpdir() on this node is ${WASM_AGENT_HOME}/tmp - INSIDE the operator's own node home - so the scratch
// directory is made under /tmp and the guard below refuses anything that lands in either real home.
const SCRATCH_BASE = fs.existsSync('/tmp') ? '/tmp' : os.tmpdir();
const WORK = fs.mkdtempSync(path.join(SCRATCH_BASE, 'wa-mission-amend-'));
const HOME = path.join(WORK, 'home');
// The store root is <home>/.wasm-agent (rust/wa-host-support/src/paths.rs: state_root), and WASM_AGENT_HOME
// replaces the home - measured here: WASM_AGENT_HOME=<dir> puts the ledger in <dir>/.wasm-agent/memory.db, and
// a WASM_AGENT_DB pointing anywhere else is not where the node writes.
const NODE = path.join(HOME, '.wasm-agent');
const MISSIONS = path.join(WORK, 'missions');
const GITREPO = path.join(WORK, 'repo');
const DB = path.join(NODE, 'memory.db');
const MISSION = path.join(MISSIONS, 'amendme');

// A fixture that wrote into the operator's own stores would be a real effect, not a test: refuse by name,
// before anything is created.
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
// One SSE stream per request. Request 0 asks for a read-only tool call and is HELD until this file has run
// `mission.sh amend`, so the note is in the node's inbox before the run reaches a context boundary -
// deterministically, not by sleeping. Every later request answers with how many amendments the model was
// actually shown, and those messages are what the checks read.
const requests = [];
// Requests whose answer is HELD until the fixture says so: index 0 belongs to the mission the fixture stages,
// and index 3 to the worker of a mission staged the way the factory's own launcher stages one (see the end).
const held = new Map();
function holdNext(index) {
  let release = () => {};
  const promise = new Promise(resolve => { release = resolve; });
  held.set(index, promise);
  return release;
}
const releaseFirst = holdNext(0);
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', async () => {
    let parsed = {};
    try { parsed = JSON.parse(body); } catch {}
    const index = requests.push({messages: parsed.messages || []}) - 1;
    const usage = {prompt_tokens: 10, completion_tokens: 2, total_tokens: 12};
    const send = chunks => {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      for (const chunk of chunks) res.write(`data: ${JSON.stringify(chunk)}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    };
    if (held.has(index)) await held.get(index);
    if (index === 0) {
      send([
        {id: 'mock-1', choices: [{index: 0, delta: {role: 'assistant', tool_calls: [
          {index: 0, id: 'call-read-1', type: 'function', function: {name: 'read', arguments: JSON.stringify({path: 'brief.md', limit: 2})}},
        ]}, finish_reason: null}]},
        {id: 'mock-1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]},
        {id: 'mock-1', choices: [], usage},
      ]);
      return;
    }
    const shown = (requests[index].messages || [])
      .filter(message => message.role === 'user').map(message => String(message.content || ''))
      .filter(content => /\[amendment \d{4}-\d\d-\d\dT/.test(content));
    send([
      {id: `mock-${index + 1}`, choices: [{index: 0, delta: {role: 'assistant', content: `boundary-${index + 1} saw ${shown.length} amendment(s)`}, finish_reason: null}]},
      {id: `mock-${index + 1}`, choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: `mock-${index + 1}`, choices: [], usage},
    ]);
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

// Every store this run can write is under WORK. The vault wins over the key and the base URL on purpose
// (lua/core/provider.lua), so a fixture that wants its own endpoint takes it out of the picture - otherwise
// this suite would call the operator's real provider.
const ENV = {
  ...process.env,
  HOME,
  WASM_AGENT_HOME: HOME,
  WASM_AGENT_DB: DB,
  MISSION_NODE_HOME: NODE,          // the store scripts/mission.sh reads (node_presence, boot lease)
  MISSION_REPO: GITREPO,
  MISSIONS_DIR: MISSIONS,
  MISSION_ROOT: MISSIONS,
  WA_BIN: BIN,
  MISSION_START_WAIT_SECONDS: '120',   // bounds start's own 10-minute window; it permits nothing
  WASM_AGENT_LUA_ROOT: REPO,
  WASM_AGENT_PROVIDER: 'opencode-go',
  WASM_AGENT_LLM_BASE_URL: `http://127.0.0.1:${PORT}`,
  WASM_AGENT_LLM_API_KEY: 'test-only',
  WASM_AGENT_LLM_MODEL: 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE: path.join(WORK, 'no-models-store'),
  WASM_AGENT_RENDEZVOUS: '',
  WASM_AGENT_RELAY: '',
  WASM_AGENT_MANAGED: '0',
  WA_SKIP_UPDATE_CHECK: '1',
  WASM_AGENT_PROVIDER_RETRIES: '0',
  COLUMNS: '100',
  TERM: 'xterm-256color',
};
for (const key of ['WASM_AGENT_RAW_CODE', 'WASM_AGENT_VAULT_URL', 'WASM_AGENT_VAULT_DIR',
  'WASM_AGENT_OPENAI_BASE_URL', 'OPENCODE_GO_API_KEY', 'OPENAI_API_KEY']) delete ENV[key];

const mission = (...args) => spawnSync('bash', [path.join(REPO, 'scripts', 'mission.sh'), ...args],
  {cwd: REPO, env: ENV, encoding: 'utf8', timeout: 240000, stdio: ['ignore', 'pipe', 'pipe']});
const cli = (...args) => spawnSync(BIN, args, {cwd: REPO, env: ENV, encoding: 'utf8', timeout: 90000});
const git = (...args) => spawnSync('git', args, {cwd: GITREPO, encoding: 'utf8'});
const read = file => { try { return fs.readFileSync(file, 'utf8'); } catch { return ''; } };
const ready = file => { try { return fs.readFileSync(path.join(MISSION, file), 'utf8'); } catch { return ''; } };

function waitFor(predicate, label, timeout = 120000) {
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

// One read of the node's own store, retried: the worker process writes it while this fixture reads it.
function query(sql, ...params) {
  const deadline = Date.now() + 30000;
  for (;;) {
    try {
      const db = new DatabaseSync(DB, {readOnly: true});
      try { return db.prepare(sql).all(...params); } finally { db.close(); }
    } catch (error) {
      if (Date.now() > deadline) throw error;
    }
  }
}

function lockSession() {
  const match = ready('run.lock').match(/^SESSION='([^']*)'$/m);
  return match ? match[1] : '';
}

function steerState(session) {
  const answer = cli('steer', session, '--status', '--json');
  try { return JSON.parse(answer.stdout).target || null; } catch { return null; }
}

// ---- the checks --------------------------------------------------------------------------------------
// Only pids this file started are ever signalled, and only while their cmdline still names this fixture's
// scratch directory (FACTORY rule 17: never by name pattern, and never a number the kernel reused).
let ownPids = [];
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
  // ---- 0. a scratch repository, and a mission staged by the script under test
  fs.mkdirSync(GITREPO, {recursive: true});
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'fixture@example.invalid');
  git('config', 'user.name', 'fixture');
  fs.writeFileSync(path.join(GITREPO, 'README.md'), 'base\n');
  git('add', 'README.md');
  git('commit', '-qm', 'base commit');
  check('the scratch repository has a base commit', git('rev-parse', 'HEAD').status === 0);

  const briefFile = path.join(MISSION, 'brief.md');
  fs.mkdirSync(MISSION, {recursive: true});
  const brief = '# amendme: a fixture mission\n\nDo the fixture work.\n';
  fs.writeFileSync(briefFile, brief);
  const staged = mission('stage', 'amendme', 'HEAD', briefFile);
  check('the mission is staged by scripts/mission.sh itself', staged.status === 0, staged.stdout + staged.stderr);
  const promptStaged = ready('prompt.md');
  check('the staged prompt says what an amendment is: newer than the brief, named in the report by its stamp',
    /## Amendments/.test(promptStaged) && /\[amendment <UTC> from the planner\]/.test(promptStaged)
      && /NEWER than the brief/.test(promptStaged), promptStaged.slice(-600));

  // ---- 1. a real worker turn, held at its first model request
  // The node's store has to exist before a launch: `start` reads session_presence and refuses [unknown]
  // when it cannot (measured here: a scratch node with no memory.db at all refuses the first launch). Asking
  // the node one question creates it the way the node always does - the fixture does not write the store by
  // hand.
  cli('sessions', '100');
  check('the scratch node answers and has a store of its own', fs.existsSync(DB), DB);
  const started = mission('start', 'amendme');
  check('start launches the worker the mission will steer', started.status === 0, started.stdout + started.stderr);
  for (const file of ['run.pid', 'launch.pid']) {
    const pid = Number(ready(file).trim());
    if (Number.isInteger(pid) && pid > 0) ownPids.push(pid);
  }
  await waitFor(() => requests.length >= 1, "the worker's first model request");
  // The session the worker is, from the NODE: the CLI prints "wa: session <id> ok" when its turn ENDS, so a
  // live turn is named nowhere the mission could read (measured here: run.lock's SESSION stays empty for the
  // whole first turn). That is why amend asks the node, under the mission's own title.
  const session = await waitFor(() => {
    const rows = query("SELECT session_id FROM steering_runs WHERE state='active' LIMIT 1");
    return rows.length ? String(rows[0].session_id) : null;
  }, 'the node to record the run in flight');
  check('the running worker is a session the node records as in flight', /^[0-9a-f-]{36}$/.test(session), session);
  console.log(`note - run.lock while the turn runs: SESSION=${JSON.stringify(lockSession())}`);
  await waitFor(() => {
    const target = steerState(session);
    return target && target.state === 'active';
  }, 'the node to say the run is in flight');
  check('the node says a run is in flight for that session before the amendment is sent', true);

  // ---- 2. THE TURN IS RUNNING AND THE CHANGE ARRIVES NOW
  const promptBefore = fs.readFileSync(path.join(MISSION, 'prompt.md'));
  const briefBefore = fs.readFileSync(briefFile, 'utf8');
  const note1 = 'Use the matrix green for the star, not the white one.';
  const note1File = path.join(WORK, 'note1.txt');
  fs.writeFileSync(note1File, note1 + '\n');
  const a1 = mission('amend', 'amendme', note1File);
  check('amend reports the amendment as queued for the run in flight', a1.status === 0 && /queued for run/.test(a1.stdout),
    `${a1.status} ${a1.stdout}${a1.stderr}`);
  check('and it steered the session the node says is in flight, not one guessed from a log', a1.stdout.includes(session), a1.stdout);
  const stamp1 = (a1.stdout.match(/amendment (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)/) || [])[1];
  check('the amendment is stamped in UTC', Boolean(stamp1), a1.stdout);
  const briefAfter = fs.readFileSync(briefFile, 'utf8');
  check('the amendment is APPENDED to brief.md under its stamp, and the brief only grew',
    briefAfter.startsWith(briefBefore)
      && briefAfter.includes(`## Amendment ${stamp1} (from the planner)`)
      && briefAfter.trimEnd().endsWith(note1), briefAfter.slice(briefBefore.length));
  check("the worker's prompt prefix is untouched: prompt.md is byte-identical across the amend",
    Buffer.compare(promptBefore, fs.readFileSync(path.join(MISSION, 'prompt.md'))) === 0);
  const inbox = query('SELECT state, text FROM steering_inbox WHERE session_id=?', session);
  check('the note is a durable inbox row for the run in flight, before anything is delivered',
    inbox.length === 1 && inbox[0].state === 'queued', JSON.stringify(inbox));
  check('and the door was handed it labelled as an amendment from the planner',
    inbox.length === 1 && String(inbox[0].text) === `[amendment ${stamp1} from the planner] ${note1}`, JSON.stringify(inbox));
  check('amend.log keeps the delivery with its receipt',
    /^[0-9a-f]{16} \S+ queued \S+ \S+ run=\S+$/m.test(ready('amend.log').trim()), ready('amend.log'));

  // ---- 3. the boundary: the worker's NEXT model request is where it is seen
  releaseFirst();
  await waitFor(() => /rc=0/.test(ready('done')), 'the worker to finish its turn', 240000);
  check('the worker finished the turn it was already running', /rc=0/.test(ready('done')), ready('done'));
  const atBoundary = (requests[1] || {messages: []}).messages;
  const seenStamped = atBoundary.filter(m => m.role === 'user' && String(m.content || '').includes(stamp1));
  check('the worker sees the amendment at its next context boundary - exactly once', seenStamped.length === 1,
    JSON.stringify(atBoundary).slice(0, 900));
  check('what it sees is the labelled amendment, not a paraphrase',
    seenStamped.length === 1 && String(seenStamped[0].content) === `[amendment ${stamp1} from the planner] ${note1}`,
    JSON.stringify(seenStamped));
  const transcript = query("SELECT content FROM messages WHERE session_id=? AND role='user'", session)
    .filter(row => String(row.content).includes(stamp1));
  check('it is in the transcript once, as a user row: durable context, not only a delivery', transcript.length === 1,
    JSON.stringify(transcript));
  const receipt = query('SELECT state, message_seq FROM steering_inbox WHERE session_id=?', session);
  check("the node's own receipt says the run read it, with the message it became",
    receipt.length === 1 && receipt[0].state === 'read' && Number(receipt[0].message_seq) > 0, JSON.stringify(receipt));

  // ---- 4. never two deliveries of the same amendment
  const sizeBefore = fs.statSync(briefFile).size;
  const a2 = mission('amend', 'amendme', note1File);
  check('the same amendment passed again is not a second one', a2.status === 0 && /already amended/.test(a2.stdout),
    `${a2.status} ${a2.stdout}${a2.stderr}`);
  check("and it says what became of the first, from the node's receipt", /read by the worker/.test(a2.stdout), a2.stdout);
  check('and it appends nothing', fs.statSync(briefFile).size === sizeBefore);
  check('and it delivers nothing: one inbox row, one transcript row',
    query('SELECT id FROM steering_inbox WHERE session_id=?', session).length === 1
      && query("SELECT content FROM messages WHERE session_id=? AND role='user'", session)
        .filter(row => String(row.content).includes(stamp1)).length === 1);

  // ---- 5. a worker that has FINISHED: the command says so and resumes it with the amendment
  const note2 = 'Also make the wording say 0.1.0.';
  const note2File = path.join(WORK, 'note2.txt');
  fs.writeFileSync(note2File, note2 + '\n');
  const doneMtime = fs.statSync(path.join(MISSION, 'done')).mtimeMs;
  const a3 = mission('amend', 'amendme', note2File);
  const stamp2 = (a3.stdout.match(/amendment (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)/) || [])[1];
  check('a finished worker is named as finished and RESUMED with the amendment',
    a3.status === 0 && /RESUMED/.test(a3.stdout), `${a3.status} ${a3.stdout}${a3.stderr}`);
  check('the resume reports the turn it ended on and the session it resumed',
    new RegExp(session).test(a3.stdout) && /done says rc=/.test(a3.stdout), a3.stdout);
  await waitFor(() => requests.length >= 3, "the resumed turn's model request", 240000);
  const resumedMessages = (requests[2] || {messages: []}).messages;
  const resumedUser = resumedMessages.filter(m => m.role === 'user');
  const lastMessage = resumedUser[resumedUser.length - 1] || {};
  check('the amendment is the message of its next turn',
    String(lastMessage.content || '') === `[amendment ${stamp2} from the planner] ${note2}`,
    JSON.stringify(resumedUser.slice(-2)));
  check('and the resumed turn sees that amendment exactly once',
    resumedUser.filter(m => String(m.content || '').includes(stamp2)).length === 1);
  await waitFor(() => {
    try {
      const stat = fs.statSync(path.join(MISSION, 'done'));
      return stat.mtimeMs > doneMtime && /rc=0/.test(ready('done'));
    } catch { return null; }
  }, 'the resumed turn to end', 240000);
  check('the resumed turn ran to its own rc', /rc=0/.test(ready('done')), ready('done'));
  check('the second amendment is in the transcript once',
    query("SELECT content FROM messages WHERE session_id=? AND role='user'", session)
      .filter(row => String(row.content).includes(stamp2)).length === 1);
  const briefFinal = fs.readFileSync(briefFile, 'utf8');
  check('brief.md carries both amendments, in the order they were sent, and only grew',
    briefFinal.startsWith(briefAfter) && briefFinal.includes(`## Amendment ${stamp2} (from the planner)`)
      && briefFinal.indexOf(stamp1) < briefFinal.indexOf(stamp2));
  const a4 = mission('amend', 'amendme', note2File);
  check('an amendment that was used to resume a turn is never delivered again',
    a4.status === 0 && /already amended/.test(a4.stdout) && /resumed with/.test(a4.stdout),
    `${a4.status} ${a4.stdout}${a4.stderr}`);

  // ---- 6. the refusals: unknown is not yes, and nothing is called delivered that was not
  const note3 = path.join(WORK, 'note3.txt');
  fs.writeFileSync(note3, 'a note for a mission that was never started\n');
  const nosess = path.join(MISSIONS, 'nosess');
  fs.mkdirSync(nosess, {recursive: true});
  fs.writeFileSync(path.join(nosess, 'brief.md'), '# nosess\n');
  const n1 = mission('amend', 'nosess', note3);
  check('a mission with no session running or recorded is refused by name, with nothing delivered',
    n1.status === 1 && /no session of this mission is running or recorded/.test(n1.stdout)
      && /nothing was delivered/.test(n1.stdout),
    `${n1.status} ${n1.stdout}${n1.stderr}`);
  check('and the text is still in that brief, which is what the operator asked for',
    fs.readFileSync(path.join(nosess, 'brief.md'), 'utf8').trimEnd().endsWith('a note for a mission that was never started'));
  check('and amend.log records the attempt as undelivered, so a later call delivers it once',
    / undelivered .*no_session/.test(fs.readFileSync(path.join(nosess, 'amend.log'), 'utf8').trim()));
  const emptyFile = path.join(WORK, 'empty.txt');
  fs.writeFileSync(emptyFile, '   \n\n');
  const nosessBefore = fs.readFileSync(path.join(nosess, 'brief.md'), 'utf8');
  const e1 = mission('amend', 'nosess', emptyFile);
  check('an amendment with no words in it is refused, and appends nothing',
    e1.status === 1 && /is empty/.test(`${e1.stdout}${e1.stderr}`)
      && fs.readFileSync(path.join(nosess, 'brief.md'), 'utf8') === nosessBefore,
    `${e1.status} ${e1.stdout}${e1.stderr}`);
  const nobrief = path.join(MISSIONS, 'nobrief');
  fs.mkdirSync(nobrief, {recursive: true});
  const b1 = mission('amend', 'nobrief', note3);
  check('a mission with no brief.md is refused by name',
    b1.status === 1 && /no brief at/.test(`${b1.stdout}${b1.stderr}`));
  const u1 = mission('amend', 'onlyname');
  check('amend with no file is its usage',
    u1.status === 1 && /usage: mission.sh amend/.test(`${u1.stdout}${u1.stderr}`));

  // ---- 7. a mission staged the way the FACTORY'S OWN launcher stages one: brief first, no title marker
  // The launcher the driver uses today (~/Work/missions/launch.sh) writes the brief as the prompt's first line
  // and "Where you are" after it, so the node's session title matches no marker. The session then comes from
  // the node's own presence record - which pid works in the mission's directory - and this row is what proves
  // amend reaches the missions the factory actually runs, not only the ones this script stages.
  const oldstyle = path.join(MISSIONS, 'oldstyle');
  fs.mkdirSync(path.join(oldstyle, 'wt'), {recursive: true});
  const oldBrief = '# oldstyle: a fixture mission staged the old way\n\nDo the work.\n';
  fs.writeFileSync(path.join(oldstyle, 'brief.md'), oldBrief);
  fs.writeFileSync(path.join(oldstyle, 'prompt.md'), oldBrief);
  const heldIndex = requests.length;                  // its first model request is the next index
  const releaseOldstyle = holdNext(heldIndex);
  const worker = spawn(BIN, ['chat', '--once', oldBrief], {cwd: oldstyle, env: ENV, stdio: ['ignore', 'pipe', 'pipe']});
  ownPids.push(worker.pid);
  let workerErr = '';
  worker.stderr.on('data', chunk => { workerErr += String(chunk); });
  const workerEnded = new Promise(resolve => worker.on('close', code => resolve(code)));
  await waitFor(() => requests.length > heldIndex, "the old-style worker's first model request");
  const oldstyleSession = await waitFor(() => {
    const rows = query("SELECT session_id FROM steering_runs WHERE state='active' LIMIT 1");
    return rows.length ? String(rows[0].session_id) : null;
  }, 'the node to record the old-style run in flight');
  check('a worker whose prompt carries no title marker is named nowhere in its mission directory',
    !fs.existsSync(path.join(oldstyle, 'run.lock')) && !fs.existsSync(path.join(oldstyle, 'err.log')));
  const note4 = 'The old-style mission gets a change too.';
  const note4File = path.join(WORK, 'note4.txt');
  fs.writeFileSync(note4File, note4 + '\n');
  const a5 = mission('amend', 'oldstyle', note4File);
  const stamp4 = (a5.stdout.match(/amendment (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)/) || [])[1];
  check("amend finds the session from the node's own presence record when the prompt has no marker",
    a5.status === 0 && /queued for run/.test(a5.stdout) && a5.stdout.includes(oldstyleSession),
    `${a5.status} ${a5.stdout}${a5.stderr}`);
  check('the old-style brief ends with the amendment', fs.readFileSync(path.join(oldstyle, 'brief.md'), 'utf8')
    .trimEnd().endsWith(note4));
  releaseOldstyle();
  const oldstyleCode = await workerEnded;
  check('that worker finished the turn it was given', oldstyleCode === 0, `${oldstyleCode} ${workerErr.slice(-400)}`);
  const oldBoundary = (requests[heldIndex + 1] || {messages: []}).messages;
  check('and it saw the amendment at its next context boundary, once',
    oldBoundary.filter(message => message.role === 'user' && String(message.content || '').includes(stamp4)).length === 1,
    JSON.stringify(oldBoundary).slice(-700));

  console.log(`mission amend: ${passed} checks passed`);
} catch (error) {
  console.error(`mission amend: FAILED after ${passed} checks: ${error.message}`);
  console.error(`fixture kept for diagnosis: ${WORK}`);
  console.error(`--- mission out.log (last 40 lines)\n${ready('out.log').split('\n').slice(-40).join('\n')}`);
  console.error(`--- mission err.log (last 20 lines)\n${ready('err.log').split('\n').slice(-20).join('\n')}`);
  process.exitCode = 1;
} finally {
  server.close();
  killOwn();
  if (!process.exitCode) fs.rmSync(WORK, {recursive: true, force: true});
}
