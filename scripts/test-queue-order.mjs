#!/usr/bin/env node
// Order is deterministic: priority first, then the id, one at a time - and a revert jumps the FIFO.
//
// WHAT THIS CAN FAIL ON:
//   * two submitters landing in an order that depends on timing rather than on the journal;
//   * a priority request that queues behind the FIFO (a health revert must not wait for a train);
//   * a request that is picked twice, or a request waiting on review that is picked at all.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {openJournal, submit, transition, position, nextRunnable, isOpen, lastState} from './lib/queue/journal.mjs';
import {runOnce} from './q-runner.mjs';

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-order: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-order-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });
const db = openJournal(path.join(work, 'journal.db'));
const repo = work;
const steps = {
  merge: async () => ({ok: true}),
  rows: async () => ({ok: true}),
  push: async ({request}) => ({ok: true, mainSha: request.sha.slice(0, 8)}),
};

// ---- 1. strict FIFO among equals -----------------------------------------------------------------------
const a = submit(db, {branch: 'change/a', sha: '1'.repeat(40), mission: 'one'});
const b = submit(db, {branch: 'change/b', sha: '2'.repeat(40), mission: 'two'});
const c = submit(db, {branch: 'change/c', sha: '3'.repeat(40), mission: 'three'});
eq(position(db, a.id), 0, 'the first submitter is first');
eq(position(db, c.id), 2, 'the third is third');
const run1 = await runOnce(db, {repo, steps});
eq(run1.id, a.id, 'the runner takes a first, not c');
eq((await runOnce(db, {repo, steps})).id, b.id, 'then b');
eq((await runOnce(db, {repo, steps})).id, c.id, 'then c');
eq(await runOnce(db, {repo, steps}), null, 'and nothing is left');

// ---- 2. submit order does not decide it: the id does -----------------------------------------------
// Two requests made in the same millisecond still have an order, because the journal assigned it.
const d = submit(db, {branch: 'change/d', sha: '4'.repeat(40), mission: 'four'});
const e = submit(db, {branch: 'change/e', sha: '5'.repeat(40), mission: 'five'});
ok(e.id > d.id, 'ids are monotonic');
eq(nextRunnable(db).id, d.id, 'and the lower id runs first even when the timestamps match');

// ---- 3. a revert jumps the FIFO -----------------------------------------------------------------------
const revert = submit(db, {branch: 'change/revert', sha: '6'.repeat(40), mission: 'health', prio: 1});
eq(nextRunnable(db).id, revert.id, 'a priority request goes first');
eq(position(db, d.id), 1, 'and the FIFO moves down by one, not by its own');
const first = await runOnce(db, {repo, steps});
eq(first.id, revert.id, 'the runner takes the revert before d');

// ---- 4. a request waiting on a person is never picked -------------------------------------------------
const needs = submit(db, {branch: 'change/deploy-touch', sha: '7'.repeat(40), mission: 'seven', files: ['scripts/deploy.sh']});
transition(db, needs.id, 'needs_review', 'policy_refused', 'scripts/deploy.sh');
const before = nextRunnable(db);
eq(before.id, d.id, 'the runner skips the one waiting on review and takes d');
await runOnce(db, {repo, steps});
eq(nextRunnable(db).id, e.id, 'then e');
await runOnce(db, {repo, steps});
eq(nextRunnable(db), null, 'and with only the needs_review request open, there is nothing to run');
eq(isOpen(db, needs.id), true, 'which is still open');
eq(lastState(db, needs.id), 'needs_review', 'and still waiting');

// ---- 5. one at a time: a request is never run twice ------------------------------------------------
const after = submit(db, {branch: 'change/after', sha: '8'.repeat(40), mission: 'eight'});
transition(db, needs.id, 'queued', 'approved by the review lane');
const order = [];
for (let i = 0; i < 2; i += 1) { const r = await runOnce(db, {repo, steps}); if (r) order.push(r.id); }
eq(order.length, 2, 'two runnable requests run twice, not more');
eq(order[0], needs.id, 'the approved one comes first (its id is lower)');
eq(order[1], after.id, 'then the newcomer');
eq(await runOnce(db, {repo, steps}), null, 'and the queue drains');

const ids = db.prepare('SELECT id FROM requests ORDER BY id').all().map((r) => r.id).join(',');
eq(ids, '1,2,3,4,5,6,7,8', 'no request was created or lost along the way');
db.close();
console.log(`queue order ok (${checks} checks)`);
