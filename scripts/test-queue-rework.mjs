#!/usr/bin/env node
// A REJECTION REACHES ITS WORKER: the file says what to fix, the wake reaches a session whose turn has ended,
// and the third rejection for a mission is the orchestrator's.
//
// WHAT THIS CAN FAIL ON:
//   * a payload that drops the cause, the row names or the last lines - the worker would have to read a log;
//   * a wake that is scheduled with the wrong arguments (a mission the runner made up, a unit name two
//     requests can collide on);
//   * an escalation that fires at the wrong count, or that never fires;
//   * a rejection delivered to a mission directory that is not there - that must be reported, not thrown into
//     the runner's face mid-queue.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {openJournal, submit} from './lib/queue/journal.mjs';
import {renderRework, writeRework, escalate, reworkPath} from './lib/queue/rework.mjs';
import {wakeSession, wakeCommand, wakeUnitName} from './lib/queue/wake.mjs';
import {runOnce, deliverRejection} from './q-runner.mjs';

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-rework: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-rework-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });
const missions = path.join(work, 'missions');
fs.mkdirSync(path.join(missions, '_orch'), {recursive: true});
fs.mkdirSync(path.join(missions, 'my-mission'), {recursive: true});

// ---- 1. the payload says what to fix -------------------------------------------------------------
const payload = {cause: 'own_rows_red', branch: 'change/x', sha: 'a1b2c3d4e5f6', files: ['lua/core/status.lua'], rows: 'status mid-run', detail: 'line 1\nline 2\nFAIL test-status-midrun: the row was red'};
const text = renderRework({id: 7, payload, mission: 'my-mission'});
ok(/REJECTED: own_rows_red/.test(text), 'the cause is the first thing in it');
ok(/branch change\/x at a1b2c3d4e5f6/.test(text), 'with the branch and the sha');
ok(/files: lua\/core\/status\.lua/.test(text), 'the files a conflict or a review named');
ok(/rows: status mid-run/.test(text), 'the row names');
ok(/FAIL test-status-midrun/.test(text), 'and the last lines, which is what a worker actually reads');
ok(/put READY <new sha> on line 1/.test(text), 'and the one action to take');

// ---- 2. it is written where the mission will look ------------------------------------------------
const written = writeRework({missionsDir: missions, mission: 'my-mission', id: 7, payload});
eq(written.written, true, 'the rework file is written');
eq(written.file, reworkPath({missionsDir: missions, mission: 'my-mission', id: 7}), 'at the mission\'s own path');
ok(fs.readFileSync(written.file, 'utf8').includes('own_rows_red'), 'with the payload in it');
const orphan = writeRework({missionsDir: missions, mission: 'no-such-mission', id: 8, payload});
eq(orphan.written, false, 'a mission directory that is not there is REPORTED, not thrown');
ok(/not there/.test(orphan.why), 'and says why');

// ---- 3. the wake is one command, and it says what it starts --------------------------------------
const spec = wakeCommand({missionsDir: missions, mission: 'my-mission', file: '/tmp/rework-1.txt', id: 7});
eq(spec.unit, 'orch-rework-q7', 'the unit is named after the request');
eq(wakeUnitName(7), 'orch-rework-q7', 'one name, defined once');
ok(spec.args.includes(`WorkingDirectory=${missions}`), 'the unit runs in the missions directory');
ok(spec.args.join(' ').includes('resume-when-idle.sh my-mission /tmp/rework-1.txt'), 'and carries exactly (mission, file) to the carrier');
ok(spec.args.join(' ').includes('timeout 10800'), 'with a cap on the resume itself');
const dry = wakeSession({missionsDir: missions, mission: 'my-mission', file: '/tmp/x', id: 9, dryRun: true});
eq(dry.started, false, 'a dry run starts nothing');
eq(dry.unit, 'orch-rework-q9', 'but returns the unit it would have started');

// ---- 4. the third rejection is the orchestrator's --------------------------------------------------
const attention = path.join(missions, '_orch', 'ATTENTION');
fs.writeFileSync(attention, '');
const one = escalate({missionsDir: missions, mission: 'my-mission', id: 1, cause: 'own_rows_red', count: 1});
eq(one.escalated, false, 'one rejection is not an escalation');
const two = escalate({missionsDir: missions, mission: 'my-mission', id: 2, cause: 'own_rows_red', count: 2});
eq(two.escalated, false, 'nor two');
eq(fs.readFileSync(attention, 'utf8'), '', 'and nothing is written yet');
const three = escalate({missionsDir: missions, mission: 'my-mission', id: 3, cause: 'conflict', count: 3});
eq(three.escalated, true, 'the third escalates');
const line = fs.readFileSync(attention, 'utf8');
ok(/QUEUE: my-mission has 3 rejections \(latest q#3 conflict\)/.test(line), `and says which, in one line (${line.trim()})`);

// ---- 5. end to end: a rejected run delivers, once, with all three effects ---------------------------
const db = openJournal(path.join(work, 'journal.db'));
const req = submit(db, {branch: 'change/red', sha: 'f'.repeat(40), mission: 'my-mission'});
const steps = {merge: async () => ({ok: true}), rows: async () => ({ok: false, cause: 'own_rows_red', detail: 'FAIL test-a: red', rows: 'test-a'}), push: async () => ({ok: true})};
const spawned = [];
const outcome = await runOnce(db, {repo: work, steps, missionsDir: missions, spawn: (cmd, args) => { spawned.push({cmd, args}); return {unref() {}, on() {}}; }});
eq(outcome.outcome, 'rejected', 'the run is rejected');
ok(outcome.delivered.file && fs.existsSync(outcome.delivered.file), 'the rework file exists');
eq(outcome.delivered.woke, true, 'the wake was started');
eq(spawned.length, 1, 'once');
eq(spawned[0].cmd, 'systemd-run', 'through the carrier decision 4 keeps');
ok(spawned[0].args.join(' ').includes('my-mission'), 'naming the mission');

db.close();
console.log(`queue rework ok (${checks} checks)`);
