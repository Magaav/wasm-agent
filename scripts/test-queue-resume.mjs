#!/usr/bin/env node
// A crash in the middle of a landing leaves NO half state, and the runner proves it from main, not from a file.
//
// WHAT THIS CAN FAIL ON:
//   * a request left at `merging`/`rows`/`pushing` after a restart - it would run forever or never;
//   * a re-run that cannot tell "it landed" from "it did not" - main is the only fact that cannot be stale, so
//     the row asks main, with a real repository and a real sha;
//   * a step that fails leaving the request open (a verdict is what closes it);
//   * a rejection that loses its cause, which is the rework the worker acts on.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {openJournal, submit, transition, verdict, lastState, show} from './lib/queue/journal.mjs';
import {resumeInFlight, runOnce, runRequest} from './q-runner.mjs';
import {mainContains, CAPS} from './lib/queue/steps.mjs';

// THE LANDER RUNS THESE ROWS WITH GIT_DIR EXPORTED (land-quick.sh sets it for its own tree), and `git -C`
// does not override it: a row that spawns git would then read and write the CANONICAL checkout instead of
// its fixture. That is what turned this row red inside the queue (q#42) while it was green by hand, so
// every git call here runs with the workspace variables REMOVED.
const GIT_ENV = {...process.env};
for (const key of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES']) delete GIT_ENV[key];

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-resume: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-resume-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });

// A REAL repository, because "is this sha in main?" is the one question this row cannot fake: two commits, a
// main branch, and a sha that is in main versus one that is not.
const repo = path.join(work, 'repo');
fs.mkdirSync(repo, {recursive: true});
const git = (...args) => execFileSync('git', ['-C', repo, ...args], {encoding: 'utf8', env: GIT_ENV}).trim();
git('init', '-q', '--initial-branch=main');
git('config', 'user.email', 'row@example.invalid');
git('config', 'user.name', 'row');
fs.writeFileSync(path.join(repo, 'a.txt'), 'one\n');
git('add', '.'); git('commit', '-qm', 'one');
const inMain = git('rev-parse', 'HEAD');
fs.writeFileSync(path.join(repo, 'a.txt'), 'two\n');
git('add', '.'); git('commit', '-qm', 'two');
const notInMain = git('rev-parse', 'HEAD');
git('update-ref', 'refs/remotes/origin/main', inMain);

// ---- 1. the question main answers, both ways ----------------------------------------------------------
eq(await mainContains(repo, inMain), true, 'a sha in origin/main is reported in');
eq(await mainContains(repo, notInMain), false, 'a sha that is only local is not');
eq(CAPS.rows >= 600000, true, 'the rows cap is a real bound, not zero');

// ---- 2. a crash leaves an in-flight state, and the restart resolves it from main ----------------------
const db = openJournal(path.join(work, 'journal.db'));
const landedOne = submit(db, {branch: 'change/landed', sha: inMain, mission: 'm'});
transition(db, landedOne.id, 'merging', 'runner took it');
transition(db, landedOne.id, 'rows', 'merged');
const pendingOne = submit(db, {branch: 'change/pending', sha: notInMain, mission: 'm'});
transition(db, pendingOne.id, 'merging', 'runner took it');
const untouched = submit(db, {branch: 'change/queued', sha: notInMain, mission: 'm'});

eq(lastState(db, landedOne.id), 'rows', 'the first request is mid-flight when the crash happens');
eq(lastState(db, pendingOne.id), 'merging', 'so is the second');

const resolved = await resumeInFlight(db, {repo});
eq(resolved.length, 2, 'the restart resolves both in-flight requests');
eq(lastState(db, landedOne.id), 'landed', 'the one main already has is closed as landed');
eq(show(db, landedOne.id).verdict.verdict, 'landed', 'with a verdict row, not just a state');
eq(lastState(db, pendingOne.id), 'queued', 'the one main does not have goes back in the queue');
eq(lastState(db, untouched.id), 'queued', 'and a queued request is not touched');
const again = await resumeInFlight(db, {repo});
eq(again.length, 0, 'a second restart resolves nothing (no half state to resolve)');
// The two requests main does not have are CLOSED here, so the next sections start from an empty queue and
// each assertion below is about the request it names.
verdict(db, pendingOne.id, {verdict: 'rejected', cause: 'other'});
verdict(db, untouched.id, {verdict: 'rejected', cause: 'other'});

// ---- 3. a step that fails CLOSES the request, with its cause ------------------------------------------
const failing = submit(db, {branch: 'change/red-rows', sha: notInMain, mission: 'm'});
const stepsFailing = {
  merge: async () => ({ok: true, detail: 'merged'}),
  rows: async () => ({ok: false, cause: 'own_rows_red', detail: 'FAIL test-x: nope', rows: 'test-x'}),
  push: async () => ({ok: true}),
};
const outcome = await runOnce(db, {repo, steps: stepsFailing});
eq(outcome.id, failing.id, 'the runner takes the oldest runnable request');
eq(outcome.outcome, 'rejected', 'a red own-row rejects the request');
const rejected = show(db, failing.id).verdict;
eq(rejected.cause, 'own_rows_red', 'with the cause the worker acts on');
eq(lastState(db, failing.id), 'rejected', 'and the request is closed');
ok(/test-x/.test(rejected.payload), `the row name is IN the payload (${rejected.payload})`);

// ---- 4. a clean run lands, and main's sha is recorded ------------------------------------------------
const good = submit(db, {branch: 'change/good', sha: notInMain, mission: 'm'});
const stepsGood = {
  merge: async () => ({ok: true, detail: 'merged onto the tip'}),
  rows: async () => ({ok: true, detail: 'own rows green (7)'}),
  push: async () => ({ok: true, mainSha: 'abc12345'}),
};
const done = await runOnce(db, {repo, steps: stepsGood});
eq(done.id, good.id, 'the next runnable request');
eq(done.outcome, 'landed', 'a clean run lands');
const states = show(db, good.id).transitions.map((t) => t.state);
eq(states.join('>'), 'queued>merging>rows>pushing>landed', 'and the journal records every phase in order');
eq(show(db, good.id).verdict.main_sha, 'abc12345', 'with the sha main became');

// ---- 5. a push that loses the race is a rejection, not a crash ---------------------------------------
const race = submit(db, {branch: 'change/race', sha: notInMain, mission: 'm'});
const stepsRace = {
  merge: async () => ({ok: true}),
  rows: async () => ({ok: true}),
  push: async () => ({ok: false, cause: 'stale_sha', detail: 'push refused: not a fast-forward'}),
};
const lost = await runOnce(db, {repo, steps: stepsRace});
eq(lost.outcome, 'rejected', 'a refused push rejects');
eq(show(db, race.id).verdict.cause, 'stale_sha', 'as stale_sha');
eq(await runOnce(db, {repo, steps: stepsRace}), null, 'and the queue is empty afterwards');
db.close();
console.log(`queue resume ok (${checks} checks)`);
