#!/usr/bin/env node
// The journal is append-only, idempotent, and it imports the v0 queue without inventing a second history.
//
// WHAT THIS CAN FAIL ON, one by one:
//   * a transition that is UPDATEd or DELETEd - the log would stop being evidence of what happened;
//   * a second submit of the same (branch, sha) that makes a second request - a worker that was woken twice
//     would fork its own history and one of the two copies would land;
//   * a migration that restamps `submitted_at`, or that runs twice and duplicates rows;
//   * `position` disagreeing with the runner's own order - the number a submitter is shown has to be the
//     number that decides when it runs.
//
// The v0 fixture is written with the exact DDL `_orch/q.sh` created, so the migration is tested against the
// shape that exists on this node, not against a shape invented here.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {openJournal, submit, transition, verdict, position, nextRequest, openRequests, show, migrateV0, lastState} from './lib/queue/journal.mjs';

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-journal: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-journal-'));
const cleanup = () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } };
process.on('exit', cleanup);

const db = openJournal(path.join(work, 'journal.db'));

// ---- 1. append-only ---------------------------------------------------------------------------------
const first = submit(db, {branch: 'change/a', sha: 'a'.repeat(40), mission: 'm1', files: ['lua/core/x.lua']});
eq(first.created, true, 'a new (branch, sha) is a new request');
transition(db, first.id, 'merging', 'runner took it');
transition(db, first.id, 'rows', 'merged');
const rowsBefore = db.prepare('SELECT id, state, cause FROM transitions WHERE req = ? ORDER BY id').all(first.id);
eq(rowsBefore.length, 3, 'three transitions are three rows');
// Nothing in the module may rewrite one: the table has no update path, and this proves the statement itself.
const sql = fs.readFileSync(new URL('./lib/queue/journal.mjs', import.meta.url), 'utf8');
ok(!/UPDATE\s+transitions/i.test(sql), 'the module never UPDATEs a transition');
ok(!/DELETE\s+FROM\s+transitions/i.test(sql), 'the module never DELETEs a transition');
eq(lastState(db, first.id), 'rows', 'the last state is the newest row');

// ---- 2. idempotent submit ---------------------------------------------------------------------------
const again = submit(db, {branch: 'change/a', sha: 'a'.repeat(40), mission: 'm1'});
eq(again.id, first.id, 'the same (branch, sha) is the same request');
eq(again.created, false, 'and it says it already existed');
eq(db.prepare('SELECT COUNT(*) AS n FROM requests').get().n, 1, 'a repeat submit writes no second request');
eq(db.prepare('SELECT COUNT(*) AS n FROM transitions').get().n, 3, 'and no second queued row');

// ---- 3. position agrees with the runner's order -------------------------------------------------------
const second = submit(db, {branch: 'change/b', sha: 'b'.repeat(40), mission: 'm2'});
const revert = submit(db, {branch: 'change/revert', sha: 'c'.repeat(40), mission: 'health', prio: 1});
eq(position(db, first.id), 1, 'one request runs before the first (the revert)');
eq(position(db, revert.id), 0, 'the revert is next');
eq(position(db, second.id), 2, 'and the second submitter is behind both');
eq(nextRequest(db).id, revert.id, 'the runner asks the same question and gets the revert');
verdict(db, revert.id, {verdict: 'landed', cause: null, mainSha: 'd'.repeat(40)});
eq(openRequests(db).length, 2, 'a verdict closes the request');
eq(position(db, first.id), 0, 'and the queue moves up by one');
eq(nextRequest(db).id, first.id, 'the next request is the one that was behind it');

// ---- 4. the v0 import --------------------------------------------------------------------------------
const v0File = path.join(work, 'v0-journal.db');
const v0 = new DatabaseSync(v0File);
v0.exec(`create table if not exists requests(id integer primary key, branch text, sha text, mission text, prio integer default 0,
  note text, submitted_at text, files text, crates text, compiled integer, overlap text, unique(branch, sha));
create table if not exists transitions(id integer primary key, req integer, at text, state text, cause text);
create table if not exists verdicts(req integer primary key, at text, verdict text, cause text, payload text, main_sha text);`);
v0.prepare(`insert into requests(branch, sha, mission, prio, note, submitted_at, files, crates, compiled, overlap)
             values(?,?,?,?,?,?,?,?,?,?)`).run('change/old-one', 'e'.repeat(40), 'old-mission', 0, null, '2026-11-27T09:00:00Z', 'lua/a.lua', '', 0, '');
v0.prepare('insert into transitions(req, at, state, cause) values(1, ?, ?, ?)').run('2026-11-27T09:00:10Z', 'merging', 'runner took it');
v0.prepare('insert into verdicts(req, at, verdict, cause, payload, main_sha) values(1, ?, ?, ?, ?, ?)').run('2026-11-27T09:05:00Z', 'landed', null, '{}', 'f'.repeat(40));
v0.close();

const imported = migrateV0(db, v0File);
eq(imported.present, true, 'the v0 journal is found');
eq(imported.requests, 1, 'its one request is imported');
eq(imported.transitions, 1, 'with its transition');
eq(imported.verdicts, 1, 'and its verdict');
const old = db.prepare("SELECT * FROM requests WHERE branch = 'change/old-one'").get();
eq(old.submitted_at, '2026-11-27T09:00:00Z', 'the imported request keeps its OWN submit time');
eq(old.migrated_from, 'q-v0', 'and is marked as imported');
const oldVerdict = db.prepare('SELECT verdict, at FROM verdicts WHERE req = ?').get(old.id);
eq(oldVerdict.verdict, 'landed', 'its verdict came across');
eq(oldVerdict.at, '2026-11-27T09:05:00Z', 'with its own time');

const twice = migrateV0(db, v0File);
eq(twice.requests, 0, 'a second import adds no request');
eq(twice.skipped, 1, 'it reports the one it skipped');
eq(db.prepare("SELECT COUNT(*) AS n FROM requests WHERE branch = 'change/old-one'").get().n, 1, 'and there is still exactly one');
eq(db.prepare('SELECT COUNT(*) AS n FROM transitions WHERE req = ?').get(old.id).n, 2, 'no duplicate transitions either');
const missing = migrateV0(db, path.join(work, 'nope.db'));
eq(missing.present, false, 'a v0 journal that is not there is reported, not an error');

// ---- 5. the unique key is the mechanism, not a convention ----------------------------------------------
let refused = false;
try { db.prepare("INSERT INTO requests(branch, sha, submitted_at) VALUES('change/a', ?, 'now')").run('a'.repeat(40)); } catch { refused = true; }
ok(refused, 'the database itself refuses a duplicate (branch, sha)');

const one = show(db, first.id);
eq(one.transitions.length, 3, 'show returns the transitions in order');
db.close();
console.log(`queue journal ok (${checks} checks)`);
