#!/usr/bin/env node
// Session liveness is a running process, not a ledger row's `ended_at`.
//
// Measured on wasm_the_first, 10/11: the landing queue refused a live session (`owner_ended`)
// because its ledger row was closed when the node restarted; a duplicate wake closed another row
// while that session's turn was running; and a piped `wa chat` closed its caller's own row on the
// way out. The row was never a statement about a process - it is a statement about a conversation.
//
// `resolveOwner` therefore asks the process first: the session's `session_presence` row (written and
// heartbeated by the process that serves it, lua/core/memory.lua) whose pid must be alive. Only when
// no live process is left does `ended_at` mean anything. This suite pins that order against a real
// SQLite ledger, a real live pid and a real dead one - no mocks of the thing under test.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {resolveOwner} from './lib/landing-queue.mjs';

const SESSION = '11111111-2222-3333-4444-555555555555';
const OTHER = '22222222-3333-4444-5555-666666666666';
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-session-liveness-'));
const now = () => Math.floor(Date.now() / 1000);

let passed = 0;
const failures = [];
function check(name, condition, detail = '') {
  if (condition) { passed += 1; return }
  failures.push(`${name}${detail ? `: ${detail}` : ''}`);
}

// A ledger with the node's own shape. `presence` is [pid, heartbeat_seconds_ago]; `withTable=false`
// is a ledger written by an older binary, which has no presence table at all.
function ledger(name, {ended = null, updated = null, presence = null, withTable = true} = {}) {
  const file = path.join(WORK, `${name}.db`);
  const db = new DatabaseSync(file);
  db.exec('CREATE TABLE sessions(id TEXT PRIMARY KEY, started_at REAL, ended_at REAL, updated_at REAL);');
  if (withTable) {
    db.exec('CREATE TABLE session_presence(session_id TEXT PRIMARY KEY, pid INTEGER NOT NULL, boot TEXT NOT NULL DEFAULT \'\', role TEXT NOT NULL DEFAULT \'\', started_at REAL NOT NULL, heartbeat_at REAL NOT NULL);');
  }
  db.prepare('INSERT INTO sessions VALUES(?,?,?,?)').run(SESSION, now() - 600, ended, updated === null ? now() - 5 : updated);
  if (presence) {
    db.prepare('INSERT INTO session_presence VALUES(?,?,?,?,?,?)')
      .run(SESSION, presence[0], 'boot-fixture', 'master', now() - 600, now() - presence[1]);
  }
  db.close();
  return file;
}
function owner(file, extra = {}) {
  return resolveOwner({owner: SESSION, ledger: file, env: {}, ownerMaxAge: 900, ...extra});
}
function refusal(fn) {
  try { fn(); return null } catch (error) { return {code: error.code, message: error.message} }
}
// A pid that is certainly gone: a process this one started and reaped.
const deadPid = spawnSync(process.execPath, ['-e', '0']).pid;

// ---- 1. a live process wins over an ended row (the 10/11 regression) -----------------------------
{
  const file = ledger('live-ended', {ended: now() - 3600, presence: [process.pid, 2]});
  const answer = owner(file);
  check('a live process is accepted even though the row says ended', answer.source === 'live-process', JSON.stringify(answer));
  check('the answer names the pid, not the row', answer.evidence.pid === process.pid, JSON.stringify(answer.evidence));
  check('the heartbeat age is reported', answer.evidence.heartbeat_seconds_ago >= 2, JSON.stringify(answer.evidence));
}

// ---- 2. a dead pid plus an ended row is still a refusal, and it names the pid ---------------------
{
  const file = ledger('dead-ended', {ended: now() - 60, presence: [deadPid, 60]});
  const error = refusal(() => owner(file));
  check('a dead process with an ended row is refused', error && error.code === 'owner_ended', JSON.stringify(error));
  check('the refusal names the dead pid', error && error.message.includes(`pid ${deadPid}`), error && error.message);
  check('the refusal says why it is not live', error && /not alive|no running process/.test(error.message), error && error.message);
}

// ---- 3. a live pid whose heartbeat stopped is not a live session ---------------------------------
{
  const file = ledger('stale-beat', {updated: now() - 4000, presence: [process.pid, 4000]});
  const error = refusal(() => owner(file));
  check('a stopped heartbeat is not liveness', error && error.code === 'owner_stale', JSON.stringify(error));
  check('and the refusal reports the presence age', error && /heartbeat is 4000s old/.test(error.message), error && error.message);
}

// ---- 4. no presence at all: the row is all there is, and it says died ----------------------------
{
  const file = ledger('no-presence-ended', {ended: now() - 30});
  const error = refusal(() => owner(file));
  check('an ended row with no process is refused', error && error.code === 'owner_ended', JSON.stringify(error));
  check('the refusal names the missing evidence', error && /no session_presence row/.test(error.message), error && error.message);
}

// ---- 5. an older ledger (no presence table) keeps the old, narrower answer -----------------------
{
  const file = ledger('old-ledger', {withTable: false});
  const answer = owner(file);
  check('a ledger without session_presence still accepts a fresh open session', answer.source === 'ledger-live-session', JSON.stringify(answer));
  const stale = ledger('old-ledger-stale', {withTable: false, updated: now() - 4000});
  const error = refusal(() => owner(stale));
  check('and still refuses a stale one', error && error.code === 'owner_stale', JSON.stringify(error));
}

// ---- 6. the other refusals are unchanged ---------------------------------------------------------
{
  const file = ledger('unknown');
  const error = refusal(() => resolveOwner({owner: OTHER, ledger: file, env: {}}));
  check('an unknown session id is refused by name', error && error.code === 'owner_unknown_to_harness', JSON.stringify(error));
  const marker = resolveOwner({owner: SESSION, ledger: file, env: {WASM_AGENT_SESSION_ID: SESSION}});
  check('the harness environment still identifies the caller without the ledger', marker.source === 'harness-env', JSON.stringify(marker));
}

fs.rmSync(WORK, {recursive: true, force: true});
if (failures.length > 0) {
  console.error(`FAIL session-liveness: ${failures.length} failure(s); ${passed} passed`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log(`ok session-liveness: ${passed} checks`);
