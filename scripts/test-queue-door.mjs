#!/usr/bin/env node
// `landing-queue.mjs submit` puts a request in the queue and lands NOTHING - the door every caller already
// knows, now answering at once instead of running a landing as a side effect of being asked.
//
// WHAT THIS CAN FAIL ON:
//   * a submit that merges or pushes anything (a caller asking "queue this" must not change the repository);
//   * a submit that is not idempotent through the CLI (two ids for one (branch, sha));
//   * a submit that skips the path policy - a reviewed path must stop at needs_review at the door;
//   * `land` disappearing from the command line before hunk 5 retires it deliberately.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';

// THE LANDER RUNS THESE ROWS WITH GIT_DIR EXPORTED (land-quick.sh sets it for its own tree), and `git -C`
// does not override it: a row that spawns git would then read and write the CANONICAL checkout instead of
// its fixture. That is what turned this row red inside the queue (q#42) while it was green by hand, so
// every git call here runs with the workspace variables REMOVED.
const GIT_ENV = {...process.env};
for (const key of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES']) delete GIT_ENV[key];

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-door: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const repo = path.join(path.dirname(new URL(import.meta.url).pathname), '..');
const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-door-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });
const home = path.join(work, 'home');
fs.mkdirSync(home, {recursive: true});
const dbFile = path.join(home, 'lane', 'landing-queue.db');

const git = (...args) => execFileSync('git', ['-C', repo, ...args], {encoding: 'utf8', env: GIT_ENV}).trim();
const mainBefore = git('rev-parse', 'origin/main');
const head = git('rev-parse', 'HEAD');

const run = (args) => {
  try {
    const out = execFileSync(process.execPath, [path.join(repo, 'scripts', 'landing-queue.mjs'), ...args],
      {encoding: 'utf8', env: {...GIT_ENV, HOME: home, WASM_AGENT_HOME: home, TMPDIR: work}});
    return {code: 0, out};
  } catch (error) { return {code: error.status ?? 1, out: `${error.stdout ?? ''}${error.stderr ?? ''}`}; }
};

// ---- 1. the door answers, and lands nothing -----------------------------------------------------------
const first = run(['submit', '--branch', 'change/door-one', '--commit', head, '--mission', 'door', '--repo', repo]);
eq(first.code, 0, `submit exits 0 (${first.out.trim()})`);
ok(/^1 position=0$/m.test(first.out), `and answers with id and position (${first.out.trim().replace(/\s+/g, ' ')})`);
eq(git('rev-parse', 'origin/main'), mainBefore, 'main did not move: submit landed nothing');
eq(git('rev-parse', 'HEAD'), head, 'and the tree under test did not move either');

const again = run(['submit', '--branch', 'change/door-one', '--commit', head, '--mission', 'door', '--repo', repo]);
ok(/^1 \(already queued\) position=0$/m.test(again.out), `a repeat submit is the same request (${again.out.trim().replace(/\s+/g, ' ')})`);

// ---- 2. the journal is the truth, and it has no verdict ------------------------------------------------
const db = new DatabaseSync(dbFile, {readOnly: true});
const requests = db.prepare('SELECT id, branch, sha, mission FROM requests ORDER BY id').all();
eq(requests.length, 1, 'one request in the journal, not two');
eq(requests[0].sha, head, 'naming the sha it was given');
eq(db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n, 0, 'and NO verdict: nothing was landed by the door');
const states = db.prepare('SELECT state FROM transitions WHERE req = 1').all().map((r) => r.state).join(',');
ok(/^queued(,needs_review)?$/.test(states), `the request is only queued (or stopped for review), never merged: ${states}`);

// ---- 3. the path policy applies at the door ------------------------------------------------------------
// This branch changed policies/landing-policy.json, so its own diff must stop for a person - the policy is
// data and changing it is a review. That is the door doing its job, on a real diff of this tree.
if (git('diff', '--name-only', `${mainBefore}...${head}`).includes('policies/landing-policy.json')) {
  const stopped = run(['submit', '--branch', 'change/door-policy', '--commit', head, '--mission', 'door', '--repo', repo]);
eq(stopped.code, 0, 'a reviewed path still gets a request id (it is queued, not refused)');
  ok(/needs_review: .*landing-policy.json/.test(stopped.out), `and the answer names the path and the reason (${stopped.out.split('\n')[0]})`);
  ok(/waiting on review since \d{4}-/.test(stopped.out), 'and says since when, so it is never silent');
  const row = db.prepare("SELECT t.state FROM transitions t JOIN requests r ON r.id = t.req WHERE r.sha = ? ORDER BY t.id DESC LIMIT 1").get(head);
  eq(row.state, 'needs_review', 'and the journal records the state');
} else {
  ok(true, 'this tree does not change the policy file, so the reviewed-path case is carried by test-queue-approval');
}

db.close();

// ---- 4. land is still there, untouched, until hunk 5 retires it ---------------------------------------
const usage = run([]);
eq(usage.code, 75, 'no command is a usage error (75)');
ok(/\bland\b/.test(usage.out), 'the usage line still names land: this hunk adds a door, it does not close one');
ok(/\bsubmit\b/.test(usage.out), 'and names submit');

console.log(`queue door ok (${checks} checks)`);
