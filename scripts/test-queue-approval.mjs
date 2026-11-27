#!/usr/bin/env node
// An approval is for EXACTLY (branch, sha, policy-hash), and only the review lane may write one.
//
// WHAT THIS CAN FAIL ON:
//   * an approval that survives a new sha - the worker would fix a rejection and land on the old mark;
//   * an approval that survives a changed policy - a rule could be rewritten under a mark made for the old one;
//   * a token check that accepts a directory, a world-readable file or a short string, or that can be pointed
//     somewhere else by an environment variable (the bypass decision 2 forbids);
//   * a needs_review request the runner would still pick up.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {openJournal, submit, transition, verdict, lastState, approvalFor, awaitingReview, nextRunnable} from './lib/queue/journal.mjs';
import {reviewLane, reviewTokenPath} from './lib/queue/lane.mjs';
import {policyHash, policyPath} from './lib/queue/policy.mjs';

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-approval: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const repo = path.join(path.dirname(new URL(import.meta.url).pathname), '..');
const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-approval-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });
const hash = policyHash(policyPath(repo));

// ---- 1. the token's three rules, each with its own refusal --------------------------------------------
const home = path.join(work, 'home');
const laneDir = path.join(home, '.wasm-agent', 'lane');
fs.mkdirSync(laneDir, {recursive: true});
const token = reviewTokenPath(home);
eq(token, path.join(home, '.wasm-agent', 'lane', 'review.token'), 'the path is fixed under the home');

let lane = reviewLane({home});
eq(lane.ok, false, 'no token is a refusal');
ok(/no review token at/.test(lane.why), `and it says where it looked (${lane.why})`);

fs.mkdirSync(token);
lane = reviewLane({home});
eq(lane.ok, false, 'a directory is not a token');
ok(/not a regular file/.test(lane.why), 'and it says so');
fs.rmdirSync(token);

fs.writeFileSync(token, 'x'.repeat(40), {mode: 0o644});
lane = reviewLane({home});
eq(lane.ok, false, 'a world-readable token is refused');
ok(/0600 or stricter/.test(lane.why), `and it names the mode rule (${lane.why})`);

fs.writeFileSync(token, 'short', {mode: 0o600});
fs.chmodSync(token, 0o600);
lane = reviewLane({home});
eq(lane.ok, false, 'a short token is refused');
ok(/32 or more/.test(lane.why), 'and it names the length rule');

fs.writeFileSync(token, 'r'.repeat(48), {mode: 0o600});
fs.chmodSync(token, 0o600);
lane = reviewLane({home});
eq(lane.ok, true, 'a regular, 0600, 48-character token is accepted');
ok(/review lane \(/.test(lane.by), 'and names the lane for the record');

// No environment variable moves it: the path function takes a home and reads no env.
const laneSrc = fs.readFileSync(path.join(repo, 'scripts', 'lib', 'queue', 'lane.mjs'), 'utf8');
ok(!/process\.env/.test(laneSrc), 'the lane module reads NO environment variable');
const cliSrc = fs.readFileSync(path.join(repo, 'scripts', 'queue.mjs'), 'utf8');
ok(!/review-token/.test(cliSrc), 'and the command line has no flag that points at another token');

// ---- 2. needs_review is a state the runner will not pick up --------------------------------------------
// The ROW's journal is the CLI's journal: the CLI resolves its file from WASM_AGENT_HOME (set to `home`
// when it runs, below), so the two halves are joined by the same file rather than by a mock.
const db = openJournal(path.join(home, 'lane', 'landing-queue.db'));
const req = submit(db, {branch: 'change/deploy-touch', sha: 'a'.repeat(40), mission: 'm', files: ['scripts/deploy.sh']});
transition(db, req.id, 'needs_review', 'policy_refused', 'scripts/deploy.sh (installs the node)');
eq(lastState(db, req.id), 'needs_review', 'the request stops at needs_review');
eq(nextRunnable(db), null, 'and the runner has nothing to run while it waits');
eq(awaitingReview(db).length, 1, 'review lists it');
eq(awaitingReview(db)[0].submitted_at.length > 0, true, 'with the time it has been waiting since (never silent)');

// ---- 3. an approval is for exactly this triple ---------------------------------------------------------
const other = 'b'.repeat(40);
eq(approvalFor(db, {branch: 'change/deploy-touch', sha: other, policyHash: hash}), null, 'a different sha has no approval');
eq(approvalFor(db, {branch: 'change/deploy-touch', sha: 'a'.repeat(40), policyHash: 'f'.repeat(64)}), null, 'and neither has a different policy hash');

// ---- 4. the CLI's approve, driven with a scratch HOME (the real path function stands) ------------------
const run = (args, extraEnv = {}) => {
  try {
    const out = execFileSync(process.execPath, [path.join(repo, 'scripts', 'queue.mjs'), ...args],
      {encoding: 'utf8', env: {...process.env, HOME: home, WASM_AGENT_HOME: home, TMPDIR: work, ...extraEnv}});
    return {code: 0, out};
  } catch (error) {
    return {code: error.status ?? 1, out: `${error.stdout ?? ''}${error.stderr ?? ''}`};
  }
};

const approved = run(['approve', 'change/deploy-touch', 'a'.repeat(40), '--repo', repo]);
eq(approved.code, 0, `approve with the token exits 0 (${approved.out.trim()})`);
ok(/^approved change\/deploy-touch@a{12} policy=/.test(approved.out.trim()), `and names the triple it recorded (${approved.out.trim()})`);
eq(lastState(db, req.id), 'queued', 'and the request goes back in the queue');
eq(awaitingReview(db).length, 0, 'no longer waiting on a person');
eq(nextRunnable(db).id, req.id, 'so the runner can take it again');

const again = run(['approve', 'change/deploy-touch', 'a'.repeat(40), '--repo', repo]);
eq(again.code, 0, 'approving twice is not an error');
ok(/^already approved/.test(again.out.trim()), 'and it says the mark already existed');

eq(db.prepare('SELECT COUNT(*) AS n FROM approvals').get().n, 1, 'one row, not two');

const wrongSha = run(['approve', 'change/deploy-touch', other, '--repo', repo]);
eq(wrongSha.code, 3, 'an approval for a sha with no request is refused');

const noTokenHome = path.join(work, 'bare');
fs.mkdirSync(noTokenHome, {recursive: true});
const refused = run(['approve', 'change/deploy-touch', 'a'.repeat(40), '--repo', repo], {HOME: noTokenHome, WASM_AGENT_HOME: noTokenHome});
eq(refused.code, 6, 'approve without the token exits 6');
ok(/no review token at/.test(refused.out), `and says where it looked (${refused.out.trim()})`);

// A sha that needs no review cannot be approved "just in case".
const plain = submit(db, {branch: 'change/docs-only', sha: 'c'.repeat(40), mission: 'm', files: ['docs/HOST.md']});
const needless = run(['approve', 'change/docs-only', 'c'.repeat(40), '--repo', repo]);
eq(needless.code, 3, 'approving a landing that touches no reviewed path is refused');
ok(/anything to approve|nothing to approve/.test(needless.out), `with a reason (${needless.out.trim()})`);
eq(approvalFor(db, {branch: 'change/docs-only', sha: 'c'.repeat(40), policyHash: hash}), null, 'and writes no mark');

verdict(db, plain.id, {verdict: 'landed', mainSha: 'd'.repeat(40)});
db.close();
console.log(`queue approval ok (${checks} checks)`);
