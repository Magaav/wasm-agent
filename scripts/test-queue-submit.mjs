#!/usr/bin/env node
// The door: `submit` is idempotent, it says where the request sits, and its wait is CAPPED and says so.
//
// WHAT THIS CAN FAIL ON:
//   * a submit that gives two ids for one (branch, sha), or that answers without a position;
//   * a `--wait` that returns before there is a verdict, or that hangs past its own cap - law 15's whole
//     point is that a wait has an end and that the end is reported (exit 4, with the state it last saw);
//   * a verdict delivered to the wrong request.
//
// The CLI is driven as a process, the way a session drives it, and the verdict is written by the journal
// the way the runner will write it - so the two halves are joined by the same file, not by a stub.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {openJournal, verdict} from './lib/queue/journal.mjs';

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-submit: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-submit-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });
const home = path.join(work, 'home');
fs.mkdirSync(home, {recursive: true});
const dbFile = path.join(home, 'lane', 'landing-queue.db');
const repo = execFileSync('git', ['rev-parse', '--show-toplevel'], {encoding: 'utf8'}).trim();
const sha = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();

const run = (args, options = {}) => {
  try {
    const out = execFileSync(process.execPath, [new URL(import.meta.url).pathname.replace(/test-queue-submit\.mjs$/, 'queue.mjs'), ...args],
      {encoding: 'utf8', env: {...process.env, WASM_AGENT_HOME: home, TMPDIR: work}, ...options});
    return {code: 0, out};
  } catch (error) {
    return {code: error.status ?? 1, out: `${error.stdout ?? ''}${error.stderr ?? ''}`};
  }
};

// ---- 1. submit answers with an id and a position ------------------------------------------------------
const first = run(['submit', 'change/q-one', sha, 'mission-one', '--repo', repo]);
eq(first.code, 0, `submit exits 0 (${first.out.trim()})`);
const firstLine = first.out.trim().split('\n')[0];
ok(/^1\s+position=0$/.test(firstLine), `the first submit is id 1 at position 0 (got ${JSON.stringify(firstLine)})`);
const repeat = run(['submit', 'change/q-one', sha, 'mission-one', '--repo', repo]);
ok(/^1 \(already queued\) position=0$/.test(repeat.out.trim()), `a repeat submit is the same id (got ${JSON.stringify(repeat.out.trim())})`);

const second = run(['submit', 'change/q-two', sha, 'mission-two', '--repo', repo]);
ok(/^2\s+position=1$/.test(second.out.trim().split('\n')[0]), `the second submitter is behind the first (got ${JSON.stringify(second.out.trim())})`);

const priority = run(['submit', 'change/q-revert', sha, 'mission-health', '--priority', '--repo', repo]);
ok(/^3\s+position=0$/.test(priority.out.trim().split('\n')[0]), `a priority request jumps the FIFO (got ${JSON.stringify(priority.out.trim())})`);

const status = run(['status', '--json']);
const open = JSON.parse(status.out);
eq(open.length, 3, 'status shows the three open requests');
eq(open[0].id, 3, 'the revert is first in the runner order');

// ---- 2. the wait is capped and says so ----------------------------------------------------------------
const started = Date.now();
const capped = run(['submit', 'change/q-three', sha, 'mission-three', '--wait', '1', '--repo', repo]);
const waited = Date.now() - started;
eq(capped.code, 4, 'a wait that runs out exits 4');
ok(waited >= 900 && waited <= 8000, `and it waited about its cap, not forever (${waited} ms)`);
ok(/ran out: request \d+ is (queued|unknown)/.test(capped.out), `and it names the state it last saw (${JSON.stringify(capped.out.trim())})`);

// ---- 3. the verdict reaches the request that waited ----------------------------------------------------
const db = openJournal(dbFile);
const waiting = Number(capped.out.match(/request (\d+)/)[1]);
verdict(db, waiting, {verdict: 'rejected', cause: 'own_rows_red', payload: {rows: ['x']}});
db.close();
const answered = run(['submit', 'change/q-three', sha, 'mission-three', '--wait', '5', '--repo', repo]);
eq(answered.code, 0, 'a submit whose verdict is already in answers at once');
ok(/rejected \(own_rows_red\)/.test(answered.out), `and names the verdict and the cause (${JSON.stringify(answered.out.trim())})`);
ok(/^\d+ \(already queued\)/.test(answered.out.trim()), 'without creating a second request');

// ---- 4. a verdict closes the request, and the queue moves ----------------------------------------------
const afterOne = run(['show', '1', '--json']);
eq(afterOne.code, 0, 'show finds request 1');
const one = JSON.parse(afterOne.out);
eq(one.verdict, null, 'request 1 is still open');
const notThere = run(['show', '999']);
eq(notThere.code, 3, 'show on a request that does not exist exits 3');

const table = run(['table']);
eq(table.code, 0, 'table renders');
ok(/requests 4 \| landed 0 \| rejected 1 \| open 3/.test(table.out), `and counts them (${JSON.stringify(table.out.split('\n').pop())})`);

console.log(`queue submit ok (${checks} checks)`);
