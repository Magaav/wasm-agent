#!/usr/bin/env node
// The landing queue's journal: one append-only sqlite file that is the WHOLE state of a request.
//
// WHY A JOURNAL AND NOT A DIRECTORY OF FILES (Fable + Victor 27/11). A landing is a state machine -
// queued, merging, rows, pushing, then landed or rejected - and the state that matters most is the one a
// crash leaves behind. Rows in a database with a unique key are recoverable by reading them back; files
// named after a step are a guess about which step ran. So every transition is a ROW with its time and its
// cause, nothing is ever updated in place, and the runner's first act on a restart is to read the tail.
//
// The three rules this file is built around:
//   1. IDEMPOTENT SUBMIT. `submit` on the same (branch, sha) returns the SAME request id and writes nothing
//      new. A worker that submits twice, or resubmits after a wake it missed, cannot fork its own history.
//   2. NO SECOND LIST OF EVENTS. `transitions` IS the event stream: a reader tails it by id. A separate
//      events table would be one more thing to keep in step with the truth.
//   3. THE JOURNAL OUTLIVES THE CODE. The v0 queue (`_orch/q/journal.db`, three tables, 9 requests) is
//      imported rather than abandoned, and importing twice is a no-op.
//
// This module is the queue's state, not its policy: it never decides to run anything and never touches a
// repository. The runner (hunk 3) does that, and reports back here.
import {DatabaseSync} from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

// The v0 schema, verbatim, so the migration imports a shape it can name (
// `_orch/q.sh` created exactly these three tables and no more).
export const V0_TABLES = ['requests', 'transitions', 'verdicts'];

export const SCHEMA = `
CREATE TABLE IF NOT EXISTS requests(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  branch TEXT NOT NULL,
  sha TEXT NOT NULL,
  mission TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT 'plain',      -- plain | compiled | install
  prio INTEGER NOT NULL DEFAULT 0,         -- a revert asks for 1 and jumps the FIFO
  note TEXT,
  policy_hash TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  submitted_at TEXT NOT NULL,
  files TEXT NOT NULL DEFAULT '',
  crates TEXT NOT NULL DEFAULT '',
  compiled INTEGER NOT NULL DEFAULT 0,
  overlap TEXT NOT NULL DEFAULT '',
  migrated_from TEXT,
  UNIQUE(branch, sha)
);
CREATE TABLE IF NOT EXISTS transitions(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  req INTEGER NOT NULL REFERENCES requests(id),
  at TEXT NOT NULL,
  state TEXT NOT NULL,
  cause TEXT,
  evidence TEXT
);
CREATE TABLE IF NOT EXISTS verdicts(
  req INTEGER PRIMARY KEY REFERENCES requests(id),
  at TEXT NOT NULL,
  verdict TEXT NOT NULL,
  cause TEXT,
  payload TEXT,
  main_sha TEXT
);
CREATE TABLE IF NOT EXISTS approvals(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  branch TEXT NOT NULL,
  sha TEXT NOT NULL,
  policy_hash TEXT NOT NULL,
  by TEXT NOT NULL,
  at TEXT NOT NULL,
  UNIQUE(branch, sha, policy_hash)
);
CREATE INDEX IF NOT EXISTS transitions_by_req ON transitions(req, id);
CREATE INDEX IF NOT EXISTS requests_open ON requests(prio DESC, id);
`;

const TERMINAL = new Set(['landed', 'rejected']);

// A journal is open when its file is; the caller decides where. Tests pass a temp path, the runner passes
// `_orch/q/journal.db`, and both get the same pragmas: WAL, a busy timeout, and synchronous=FULL, because a
// crash mid-transition is the one case this file exists for.
export function openJournal(file) {
  if (!file) throw new Error('openJournal needs a path');
  fs.mkdirSync(path.dirname(file), {recursive: true});
  const db = new DatabaseSync(file);
  db.exec('PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
  db.exec(SCHEMA);
  return db;
}

export function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

// Every write that changes more than one row runs inside BEGIN IMMEDIATE: two submitters and the runner
// share this file, and a half-applied transition is exactly the state a crash must not be able to leave.
function immediate(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const out = fn();
    db.exec('COMMIT');
    return out;
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch { /* the transaction was never open */ }
    throw error;
  }
}

// APPEND ONLY. There is no update and no delete on `transitions` in this file, and a row that repeated the
// last state with the same cause would be noise, so the runner may call this freely and the journal stays
// a log rather than a snapshot.
export function transition(db, req, state, cause = null, evidence = null, at = nowIso()) {
  db.prepare('INSERT INTO transitions(req, at, state, cause, evidence) VALUES(?, ?, ?, ?, ?)')
    .run(req, at, state, cause, evidence === null ? null : String(evidence));
  return db.prepare('SELECT last_insert_rowid() AS id').get().id;
}

// SUBMIT, IDEMPOTENT ON (branch, sha). The unique key is the rule; this function is the way to reach it
// without turning a race into an exception: two submitters of the same branch and sha see one request, and
// the second is told it existed (created=false) instead of being given an error it would have to parse.
export function submit(db, {branch, sha, mission = '', kind = 'plain', prio = 0, note = null, files = [], crates = [], compiled = 0, overlap = [], at = nowIso()} = {}) {
  if (!branch) throw new Error('submit needs a branch');
  if (!sha) throw new Error('submit needs a sha');
  return immediate(db, () => {
    const existing = db.prepare('SELECT id FROM requests WHERE branch = ? AND sha = ?').get(branch, sha);
    if (existing) return {id: existing.id, created: false, position: position(db, existing.id)};
    db.prepare(`INSERT INTO requests(branch, sha, mission, kind, prio, note, submitted_at, files, crates, compiled, overlap)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(branch, sha, mission, kind, prio, note, at, files.join(' '), crates.join(' '), compiled ? 1 : 0, overlap.join(' '));
    const id = db.prepare('SELECT last_insert_rowid() AS id').get().id;
    transition(db, id, 'queued', 'submitted', null, at);
    return {id, created: true, position: position(db, id)};
  });
}

// A request is open until it has a verdict. Position counts the open requests that will run before it:
// a higher priority first, then the earlier id. It is the number a submitter is shown, so it must be the
// same number the runner's ORDER BY would produce - hence one definition, used by both.
export function position(db, req) {
  const row = db.prepare('SELECT prio FROM requests WHERE id = ?').get(req);
  if (!row) return null;
  const ahead = db.prepare(`SELECT COUNT(*) AS n FROM requests r
                             WHERE NOT EXISTS (SELECT 1 FROM verdicts v WHERE v.req = r.id)
                               AND (r.prio > ? OR (r.prio = ? AND r.id < ?))`).get(row.prio, row.prio, req);
  return ahead.n;
}

export function openRequests(db) {
  return db.prepare(`SELECT * FROM requests r
                      WHERE NOT EXISTS (SELECT 1 FROM verdicts v WHERE v.req = r.id)
                      ORDER BY r.prio DESC, r.id`).all();
}

// The runner's one question: what runs next? Same ORDER BY as `position`, so the two cannot disagree.
export function nextRequest(db) {
  return openRequests(db)[0] ?? null;
}

export function show(db, req) {
  const row = db.prepare('SELECT * FROM requests WHERE id = ?').get(req);
  if (!row) return null;
  return {
    request: row,
    transitions: db.prepare('SELECT id, at, state, cause, evidence FROM transitions WHERE req = ? ORDER BY id').all(req),
    verdict: db.prepare('SELECT at, verdict, cause, payload, main_sha FROM verdicts WHERE req = ?').get(req) ?? null,
  };
}

export function events(db, sinceId = 0) {
  return db.prepare('SELECT id, req, at, state, cause, evidence FROM transitions WHERE id > ? ORDER BY id').all(sinceId);
}

export function verdict(db, req, {verdict: word, cause = null, payload = null, mainSha = null, at = nowIso()}) {
  return immediate(db, () => {
    db.prepare('INSERT OR REPLACE INTO verdicts(req, at, verdict, cause, payload, main_sha) VALUES(?, ?, ?, ?, ?, ?)')
      .run(req, at, word, cause, payload === null ? null : (typeof payload === 'string' ? payload : JSON.stringify(payload)), mainSha);
    transition(db, req, word, cause, payload === null ? null : (typeof payload === 'string' ? payload : JSON.stringify(payload)), at);
    return word;
  });
}

export function isOpen(db, req) {
  return !db.prepare('SELECT 1 FROM verdicts WHERE req = ?').get(req);
}

export function lastState(db, req) {
  const row = db.prepare('SELECT state FROM transitions WHERE req = ? ORDER BY id DESC LIMIT 1').get(req);
  return row ? row.state : null;
}

export {TERMINAL};

// THE v0 QUEUE IS IMPORTED, NOT ABANDONED. `_orch/q/journal.db` holds real requests in three tables with
// the DDL `_orch/q.sh` created. Every row keeps its own times: a migration that restamped `submitted_at`
// with the moment it ran would destroy the only measurement the v0 queue produced.
//
// Idempotent twice over: the unique (branch, sha) key refuses a duplicate request, and `migrated_from`
// marks every imported row so a second run can see that it already happened and say so instead of
// inserting a parallel history.
export function migrateV0(db, v0File) {
  if (!fs.existsSync(v0File)) return {present: false, requests: 0, transitions: 0, verdicts: 0, skipped: 0};
  const v0 = new DatabaseSync(v0File, {readOnly: true});
  try {
    const requests = v0.prepare('SELECT id, branch, sha, mission, prio, note, submitted_at, files, crates, compiled, overlap FROM requests ORDER BY id').all();
    const transitions = v0.prepare('SELECT req, at, state, cause FROM transitions ORDER BY id').all();
    const verdicts = v0.prepare('SELECT req, at, verdict, cause, payload, main_sha FROM verdicts ORDER BY req').all();
    const result = {present: true, requests: 0, transitions: 0, verdicts: 0, skipped: 0};
    immediate(db, () => {
      const byOld = new Map();
      for (const row of requests) {
        const known = db.prepare('SELECT id, migrated_from FROM requests WHERE branch = ? AND sha = ?').get(row.branch, row.sha);
        if (known) { byOld.set(row.id, known.id); result.skipped += 1; continue; }
        db.prepare(`INSERT INTO requests(branch, sha, mission, kind, prio, note, submitted_at, files, crates, compiled, overlap, migrated_from)
                    VALUES(?, ?, ?, 'plain', ?, ?, ?, ?, ?, ?, ?, 'q-v0')`)
          .run(row.branch, row.sha, row.mission ?? '', row.prio ?? 0, row.note ?? null, row.submitted_at ?? nowIso(),
               row.files ?? '', row.crates ?? '', row.compiled ? 1 : 0, row.overlap ?? '');
        byOld.set(row.id, db.prepare('SELECT last_insert_rowid() AS id').get().id);
        result.requests += 1;
      }
      for (const t of transitions) {
        const req = byOld.get(t.req);
        if (!req) continue;
        db.prepare('INSERT INTO transitions(req, at, state, cause, evidence) VALUES(?, ?, ?, ?, ?)')
          .run(req, t.at ?? nowIso(), t.state, t.cause ?? null, 'migrated from q-v0');
        result.transitions += 1;
      }
      for (const v of verdicts) {
        const req = byOld.get(v.req);
        if (!req) continue;
        db.prepare('INSERT OR REPLACE INTO verdicts(req, at, verdict, cause, payload, main_sha) VALUES(?, ?, ?, ?, ?, ?)')
          .run(req, v.at ?? nowIso(), v.verdict, v.cause ?? null, v.payload ?? null, v.main_sha ?? null);
        result.verdicts += 1;
      }
    });
    return result;
  } finally {
    v0.close();
  }
}
