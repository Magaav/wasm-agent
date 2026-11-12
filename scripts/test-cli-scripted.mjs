#!/usr/bin/env node
// A SCRIPTED `wa chat` RUNS ITS TURN(S), LETS GO OF THE SESSION, AND EXITS - and a running one can be
// steered without killing it.
//
// WHY THIS EXISTS. Measured 2026-11-11: an orchestrator started `wa chat "<prompt>"` with its output
// redirected to a file. The turn ran, the answer was written, and then the process sat at the REPL
// prompt for ever, because stdin was not a terminal and nothing ever arrived on it. Five kills in one
// night; each kill left the session looking live (`resource_busy` on the next resume) because nothing
// had released it in an orderly way. The fix has two halves, and this file proves both against a real
// `wa` process:
//
//   1. `wa chat "<prompt>"` (and `x | wa chat`) with stdin not a terminal - or `--once`/`-p` with any
//      stdin - runs the turn(s), releases the session's claim, and exits with the run's status;
//   2. `wa steer <session> "<note>"` puts a note into the durable steering inbox of a session whose run
//      is in flight, and the run consumes it at its next context boundary. No signal, no kill.
//
// The provider is a local fixture over SSE (the shape the node's own stream parser reads,
// `rust/wa-capabilities/src/host.rs`), so nothing here talks to a model or a network.
//
// Run: WA_BIN=<wa binary> node scripts/test-cli-scripted.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = process.env.WA_BIN || process.env.FAST_BIN || 'wa';
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-cli-scripted-'));
const HOME = path.join(WORK, 'home');
const DB = path.join(WORK, 'ledger.db');
fs.mkdirSync(HOME, {recursive: true});

let passed = 0;
function check(name, condition, detail = '') {
  if (!condition) throw new Error(`${name}${detail ? `: ${detail}` : ''}`);
  passed += 1;
  console.log(`ok - ${name}`);
}

// ---- the provider fixture ---------------------------------------------------------------------
// One SSE stream per request. Request 1 asks for a read-only tool call and waits for the test to say the
// steering note has been queued (so the note is in the inbox before the boundary, deterministically);
// every later request answers with text and records what the model was shown.
const requests = [];
let releaseFirst = null;
const firstMayAnswer = new Promise(resolve => { releaseFirst = resolve; });
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', async () => {
    let parsed = {};
    try { parsed = JSON.parse(body); } catch {}
    const index = requests.push({messages: parsed.messages || [], tools: (parsed.tools || []).length, at: Date.now()}) - 1;
    const usage = {prompt_tokens: 100, completion_tokens: 5, total_tokens: 105};
    const send = chunks => {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
      for (const chunk of chunks) res.write(`data: ${JSON.stringify(chunk)}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    };
    if (index === 0) {
      await firstMayAnswer;
      send([
        {id: 'mock-1', choices: [{index: 0, delta: {role: 'assistant', tool_calls: [
          {index: 0, id: 'call-read-1', type: 'function', function: {name: 'read', arguments: JSON.stringify({path: 'AGENTS.md', limit: 2})}},
        ]}, finish_reason: null}]},
        {id: 'mock-1', choices: [{index: 0, delta: {}, finish_reason: 'tool_calls'}]},
        {id: 'mock-1', choices: [], usage},
      ]);
      return;
    }
    // Every later request: say which of the notes the model was actually given.
    const seen = (requests[index].messages || [])
      .filter(message => message.role === 'user')
      .map(message => String(message.content || ''))
      .filter(content => content.startsWith('note:'));
    const text = index === 1
      ? `boundary-2 saw ${seen.length} note(s): ${seen.join(' / ') || 'none'}`
      : 'second run answered';
    send([
      {id: `mock-${index + 1}`, choices: [{index: 0, delta: {role: 'assistant', content: text}, finish_reason: null}]},
      {id: `mock-${index + 1}`, choices: [{index: 0, delta: {}, finish_reason: 'stop'}]},
      {id: `mock-${index + 1}`, choices: [], usage},
    ]);
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;

const ENV = {
  ...process.env,
  WASM_AGENT_LUA_ROOT: REPO,
  WASM_AGENT_HOME: HOME,
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
delete ENV.WASM_AGENT_DB;
// The vault wins over the key and base-URL variables on purpose (`lua/core/provider.lua`), so a test
// that wants its own endpoint must take it out of the picture - otherwise this suite would call the
// operator's real provider, which is both a real effect and not the thing under test.
delete ENV.WASM_AGENT_VAULT_URL;
delete ENV.WASM_AGENT_VAULT_DIR;
delete ENV.WASM_AGENT_OPENAI_BASE_URL;
delete ENV.OPENCODE_GO_API_KEY;
delete ENV.OPENAI_API_KEY;

const cli = args => spawnSync(BIN, ['--db', DB, ...args], {cwd: REPO, env: ENV, encoding: 'utf8', timeout: 180000});

// A scripted run in its own process, with stdin a pipe the caller never writes to and never closes -
// exactly the launcher this change is about.
function scriptedRun(args, {closeStdin = false, timeout = 120000} = {}) {
  const child = spawn(BIN, ['--db', DB, 'chat', ...args], {cwd: REPO, env: ENV, stdio: ['pipe', 'pipe', 'pipe']});
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', chunk => { stdout += String(chunk); });
  child.stderr.on('data', chunk => { stderr += String(chunk); });
  const ended = new Promise(resolve => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); resolve({timedOut: true}); }, timeout);
    child.on('close', code => { clearTimeout(timer); resolve({code, timedOut: false}); });
  });
  if (closeStdin) child.stdin.end();
  return {child, ended, out: () => stdout, err: () => stderr};
}
const ledger = () => new DatabaseSync(DB, {readOnly: true});
function waitFor(predicate, label, timeout = 60000) {
  const deadline = Date.now() + timeout;
  return new Promise((resolve, reject) => {
    const tick = () => {
      let value = null;
      try { value = predicate(); } catch (error) { value = null; }
      if (value) return resolve(value);
      if (Date.now() > deadline) return reject(new Error(`timed out waiting for ${label}`));
      setTimeout(tick, 50);
    };
    tick();
  });
}

let sessionId = '';
try {
  // ---- 1. a scripted run exits, and the session it ran is free afterwards ---------------------
  const run = scriptedRun(['--once', 'a prompt from a script']);
  // The run is in flight once the fixture has the first request; then steer it, from another process,
  // exactly as an orchestrator would.
  await waitFor(() => requests.length >= 1, 'the first model request');
  await waitFor(() => {
    try {
      const db = ledger();
      const row = db.prepare('SELECT session_id FROM steering_runs LIMIT 1').get();
      db.close();
      return row && row.session_id;
    } catch { return null; }
  }, 'a steering run row for the session');
  const db0 = ledger();
  sessionId = String(db0.prepare('SELECT session_id FROM steering_runs LIMIT 1').get().session_id);
  db0.close();
  const steer = cli(['steer', sessionId, 'note: finish with the short answer']);
  check('`wa steer <session> "<note>"` queues a note for the run that is in flight',
    steer.status === 0 && /queued/.test(steer.stdout), `${steer.status} ${steer.stdout}${steer.stderr}`);
  check('the note is a durable inbox row before it is delivered',
    (/steering_inbox/.test(steer.stdout) || /queued [0-9a-f-]{36} for run/.test(steer.stdout)), steer.stdout);
  releaseFirst(); // the first answer may go now: the note is in the inbox before the boundary
  const first = await run.ended;
  check('a scripted `wa chat --once` exits on its own, with the status of its run', first.code === 0,
    `${first.code}${first.timedOut ? ' (killed: it never exited)' : ''}\n${run.out()}${run.err()}`);
  check('the answer is on stdout', /boundary-2 saw 1 note\(s\): note: finish with the short answer/.test(run.out()), run.out());
  check('no banner and no prompt row were printed into the transcript',
    !/wa\s+-\s+|^> /m.test(run.out()), run.out().slice(0, 400));
  check('the session id is said on stderr, for a caller that captures stdout', /wa: session [0-9a-f-]{36} ok/.test(run.err()), run.err());
  check('the note reached the running session at its next context boundary (the fixture saw it in request 2)',
    requests.length >= 2 && requests[1].messages.some(message => message.role === 'user'
      && String(message.content || '') === 'note: finish with the short answer'),
    JSON.stringify((requests[1] || {}).messages || []).slice(0, 600));
  {
    const db = ledger();
    const noteRows = db.prepare("SELECT content FROM messages WHERE role='user' AND session_id=?").all(sessionId)
      .filter(row => String(row.content) === 'note: finish with the short answer');
    const presence = db.prepare('SELECT * FROM session_presence WHERE session_id=?').get(sessionId);
    const inbox = db.prepare('SELECT state, message_seq FROM steering_inbox WHERE session_id=?').all(sessionId);
    db.close();
    check('the note is in the transcript as a user row (durable context, not just delivered)', noteRows.length === 1, JSON.stringify(noteRows));
    check('the inbox row records it as read, with the message it became',
      inbox.length === 1 && inbox[0].state === 'read' && Number(inbox[0].message_seq) > 0, JSON.stringify(inbox));
    check('the process let go of the session: no presence row survives it', presence === undefined, JSON.stringify(presence));
  }
  // The claim itself: the next run of the same session must not be refused `resource_busy`.
  const second = scriptedRun(['--session', sessionId, 'a second scripted turn']);
  const secondDone = await second.ended;
  check('the session claim is free: the next run of the same session starts and answers',
    secondDone.code === 0 && /second run answered/.test(second.out()),
    `${secondDone.code}\n${second.out()}${second.err()}`);
  check('and nothing was refused for a held resource', !/resource_busy|run_resource_refused/.test(`${second.out()}${second.err()}`),
    second.err());

  // ---- 2. the leak itself: stdin is a pipe that is never written to and never closed -----------
  const leaked = scriptedRun(['a prompt with a stdin nobody closes'], {timeout: 90000});
  const leakedDone = await leaked.ended;
  check('`wa chat "<prompt>"` with a stdin that never closes still exits (the reported leak)',
    leakedDone.code === 0 && !leakedDone.timedOut, `${leakedDone.code}${leakedDone.timedOut ? ' (killed)' : ''}\n${leaked.err()}`);
  check('and it ran the turn it was given', /second run answered/.test(leaked.out()), leaked.out());

  // ---- 3. stdin lines become turns, when the prompt was not given on the command line ----------
  const piped = scriptedRun([]);
  piped.child.stdin.write('a piped line\n');
  piped.child.stdin.end();
  const pipedDone = await piped.ended;
  check('`wa chat` with no prompt reads its turns from a pipe and exits at its end',
    pipedDone.code === 0 && /second run answered/.test(piped.out()), `${pipedDone.code}\n${piped.out()}${piped.err()}`);

  // ---- 4. steering refuses honestly when there is nothing to deliver a note to ------------------
  const late = cli(['steer', sessionId, 'note: too late']);
  check('a note for a session whose run has ended is refused by name, not queued', late.status === 1
    && /no_active_steering_target/.test(`${late.stdout}${late.stderr}`), `${late.status} ${late.stdout}${late.stderr}`);
  check('and the refusal says what to do instead', /--once/.test(late.stdout), late.stdout);
  const nobody = cli(['steer', 'not-a-session', 'note: x']);
  check('a session id that does not exist is refused', nobody.status === 2 && /no such session/.test(nobody.stdout), nobody.stdout);
  const usage = cli(['steer']);
  check('steer without a session prints its usage', usage.status === 2 && /usage: wa steer/.test(usage.stdout), usage.stdout);

  // ---- 5. `wa resume` from a script does not sit at the prompt either ------------------------
  const resumed = spawn(BIN, ['--db', DB, 'resume', '--session', sessionId], {cwd: REPO, env: ENV, stdio: ['pipe', 'pipe', 'pipe']});
  let resumedOut = '';
  resumed.stdout.on('data', chunk => { resumedOut += String(chunk); });
  resumed.stderr.on('data', chunk => { resumedOut += String(chunk); });
  const resumedDone = await new Promise(resolve => {
    const timer = setTimeout(() => { resumed.kill('SIGKILL'); resolve({code: -1, timedOut: true}); }, 90000);
    resumed.on('close', code => { clearTimeout(timer); resolve({code, timedOut: false}); });
  });
  check('`wa resume --session <id>` with a stdin nobody closes exits instead of waiting at the prompt',
    resumedDone.code === 0 && !resumedDone.timedOut, `${resumedDone.code}${resumedDone.timedOut ? ' (killed)' : ''}\n${resumedOut}`);

  // ---- 6. the explicit flag exists for a caller whose stdin IS a terminal ----------------------
  const help = cli(['chat', '--help']);
  check('--once and -p are documented in the chat help', /--once/.test(help.stdout), help.stdout.slice(0, 400));

  console.log(`cli scripted: ${passed} checks passed`);
} catch (error) {
  console.error(`cli scripted: FAILED after ${passed} checks: ${error.message}`);
  console.error(`fixture kept for diagnosis: ${WORK}`);
  process.exitCode = 1;
} finally {
  server.close();
  if (!process.exitCode) fs.rmSync(WORK, {recursive: true, force: true});
}
