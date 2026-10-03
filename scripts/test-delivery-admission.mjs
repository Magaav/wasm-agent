#!/usr/bin/env node
// The admission rule, against deliveries where every answer is known in advance.
//
// What this pins, in the order the rule decides it: a reviewed delivery whose review names the pushed
// tip's tree is ADMITTED; a delivery with no review is REFUSED, naming `review_missing`; a delivery
// whose review names a DIFFERENT TREE is REFUSED, naming `review_tree_matches_tip`, with both trees in
// the refusal text; a review that narrowed a claim and left an unverifiable one is admitted WITH the
// named caveat; an unresolved finding of the class "the summary claims more than the code" BLOCKS; a
// producer cannot admit its own work; and the tree binding is load-bearing - removing it wrongly admits
// the wrong-tree delivery, which is the falsification below.
//
// FIXTURE SHAS ARE DETERMINISTIC (fixed author/committer dates), so the recorded JSON this test can
// write is the same artifact on a second run. The recorded sample lives beside this file.
//
// Usage:  node scripts/test-delivery-admission.mjs [--record <path>]   (about 20 s, no network, no build)
// NOTE: scripts/test.sh discovers tests explicitly rather than by convention, so a file no gate names runs
// nowhere - this one ran nowhere until `bcdda53` wired `node scripts/test-delivery-admission.mjs` into the
// gate's repository-tooling block, beside `test-gate-lane.cjs` and `test-merge-lane.mjs`.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

import './test-delivery-local.mjs';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ADMISSION = path.join(HERE, 'delivery-admission.mjs');
const RECORD = path.join(HERE, 'delivery-record.mjs');
const TRIGGER = path.join(HERE, 'delivery-trigger.mjs');
const DATE = '2026-09-29T12:00:00Z';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-delivery-admission-test-'));
let checks = 0, failed = 0;
const ok = (condition, label, detail) => {
  checks += 1;
  if (condition) console.log(`  ok   ${label}`);
  else { failed += 1; console.log(`  FAIL ${label}${detail ? ` - ${detail}` : ''}`); }
};

function git(cwd, ...args) {
  const result = spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', ...args],
    {cwd, encoding: 'utf8', windowsHide: true,
      env: {...process.env, GIT_AUTHOR_DATE: DATE, GIT_COMMITTER_DATE: DATE}});
  if (result.status !== 0) throw Error(`git ${args.join(' ')}: ${result.stderr || result.stdout}`);
  return result.stdout.trim();
}
function node(script, args, environment = {}) {
  const result = spawnSync(process.execPath, [script, ...args],
    {cwd: root, encoding: 'utf8', windowsHide: true, env: {...process.env, ...environment}});
  let json = null;
  try { json = JSON.parse(result.stdout.trim()); } catch { /* a usage refusal need not be JSON */ }
  return {status: result.status, json, stderr: result.stderr, stdout: result.stdout};
}
const write = (file, text) => fs.writeFileSync(file, text);

// ---- the fixture repository: a real bare origin, a real clone, real pushes ----------------------
const work = path.join(root, 'work');
const origin = path.join(root, 'origin.git');
const store = path.join(root, 'store');
fs.mkdirSync(work);
git(root, 'init', '-q', '--initial-branch=main', work);
git(work, 'config', 'core.autocrlf', 'false');
write(path.join(work, 'seed.txt'), 'seed\n');
git(work, 'add', 'seed.txt');
git(work, 'commit', '-q', '-m', 'seed\n\nAgent: wasm-agent node=fixture session=fixture-base');
git(root, 'clone', '-q', '--bare', work, origin);
git(work, 'remote', 'add', 'origin', origin);
git(work, 'push', '-q', '-u', 'origin', 'main');

const base = git(work, 'rev-parse', 'main');
const sessions = {producerA: 'aaaaaaaa-0000-4000-8000-000000000001', reviewerA: 'bbbbbbbb-0000-4000-8000-000000000002',
  producerC: 'cccccccc-0000-4000-8000-000000000003', reviewerC: 'dddddddd-0000-4000-8000-000000000004',
  producerD: 'eeeeeeee-0000-4000-8000-000000000005', reviewerD: 'ffffffff-0000-4000-8000-000000000006',
  producerF: '11111111-0000-4000-8000-000000000007', reviewerF: '22222222-0000-4000-8000-000000000008'};
const branches = {A: 'change/fixture-admitted', B: 'change/fixture-no-review', C: 'change/fixture-wrong-tree',
  D: 'change/fixture-caveat', F: 'change/fixture-excess-claim'};

/// A delivery: a branch, a commit, a push, and a record whose tip is `reviewedTip` (which is the pushed
/// tip unless the fixture is about a branch that moved after review).
function delivery(branch, {file, text, producer, reviewedTip = null}) {
  git(work, 'switch', '-q', '-c', branch, base);
  write(path.join(work, file), text);
  git(work, 'add', file);
  git(work, 'commit', '-q', '-m', `${branch}: fixture content\n\nAgent: wasm-agent node=fixture session=${producer}`);
  const tip = git(work, 'rev-parse', 'HEAD');
  git(work, 'push', '-q', '-u', 'origin', branch);
  const created = node(RECORD, ['create', branch, '--repo', work, '--store', store,
    '--tip', reviewedTip || tip, '--producer', producer]);
  if (created.status !== 0) throw Error(`record create failed: ${created.stderr}`);
  return {branch, tip, record: created.json.record};
}

/// A review: a published commit on its own branch, whose `Agent:` trailer names the reviewer - the
/// artifact the rule reads, not the record's sentence about it.
function review(branch, {reviewer, tip, verdict = 'passed', findings = [], harness = 'wasm-agent', trailer = null}) {
  const name = `review/${branch.replace(/[^A-Za-z0-9-]/g, '-')}`;
  git(work, 'switch', '-q', '-c', name, tip);
  write(path.join(work, 'REVIEW.md'), `# Review of ${branch}\n\nReviewed tip ${tip}.\n`);
  git(work, 'add', 'REVIEW.md');
  git(work, 'commit', '-q', '-m', `review(${branch}): fixture verdict\n\nReview of ${branch} (${tip}).\n\n${trailer || `Agent: ${harness} node=fixture session=${reviewer}`}`);
  const commit = git(work, 'rev-parse', 'HEAD');
  git(work, 'push', '-q', '-u', 'origin', name);
  const args = ['review', branch, '--repo', work, '--store', store, '--reviewer', reviewer,
    '--commit', commit, '--tip', tip, '--verdict', verdict];
  for (const finding of findings) args.push('--finding', finding);
  const applied = node(RECORD, args);
  if (applied.status !== 0) throw Error(`record review failed: ${applied.stderr}`);
  return {commit, branch: name};
}

function check(branch, environment = {}) {
  return node(ADMISSION, ['check', branch, '--store', store], environment);
}

/// The recorded sample: only the facts that do not depend on where the fixture ran.
function exposed(result) {
  return {
    delivery: result.delivery, decision: result.decision, condition: result.condition,
    refusal: result.refusal, caveats: result.caveats,
    observed: {ref: result.observed.ref, source: result.observed.source, tip: result.observed.tip,
      tree: result.observed.tree, review_commit_contains_tip: result.observed.review_commit_contains_tip},
    review: result.review,
    conditions: result.conditions.map(item => ({name: item.name, ok: item.ok, blocking: item.blocking})),
  };
}

const recorded = {schema: 1, at: new Date().toISOString(), note: 'fixture shas are deterministic (fixed author/committer dates); the temp root is not recorded', cases: []};

try {
  // ---- 1. a review of the pushed tip's tree: ADMITTED -------------------------------------------------
  console.log('1. a reviewed delivery, review naming the tip tree');
  const A = delivery(branches.A, {file: 'a.txt', text: 'a\n', producer: sessions.producerA});
  const reviewA = review(branches.A, {reviewer: sessions.reviewerA, tip: A.tip});
  const admitted = check(branches.A);
  recorded.cases.push({name: 'admitted', exit: admitted.status, verdict: exposed(admitted.json)});
  ok(admitted.status === 0 && admitted.json?.decision === 'admitted',
    'decision admitted, exit 0', JSON.stringify({exit: admitted.status, decision: admitted.json?.decision, condition: admitted.json?.condition}));
  ok(admitted.json?.observed.ref === `refs/remotes/origin/${branches.A}` && admitted.json?.observed.source === 'pushed',
    'the tip is read from the pushed ref, not from a seam', JSON.stringify(admitted.json?.observed));
  ok(admitted.json?.observed.tip === A.tip && admitted.json?.observed.tree === git(work, 'rev-parse', `${A.tip}^{tree}`),
    'the tip is the pushed commit and the tree is read from git');
  ok(admitted.json?.review?.reviewer === sessions.reviewerA && admitted.json?.review?.commit === reviewA.commit,
    'the record names the reviewer and the published review commit');
  ok(admitted.json?.conditions.every(item => item.ok) === true, 'every condition held');
  ok(admitted.json?.condition === 'admitted' && admitted.json?.refusal === null, 'no refusal is invented for a pass');

  // ---- 2. no review at all: REFUSED, visibly -----------------------------------------------------
  console.log('2. no review');
  const B = delivery(branches.B, {file: 'b.txt', text: 'b\n', producer: sessions.producerA});
  const noReview = check(branches.B);
  recorded.cases.push({name: 'no_review', exit: noReview.status, verdict: exposed(noReview.json)});
  ok(noReview.status === 2 && noReview.json?.decision === 'refused', 'refused, exit 2', String(noReview.status));
  ok(noReview.json?.condition === 'review_missing', 'the failed condition is named: review_missing', noReview.json?.condition);
  ok(String(noReview.json?.refusal).includes(branches.B) && String(noReview.json?.refusal).startsWith(`${branches.B}: refused - review_missing.`),
    'the refusal names the delivery and the condition', noReview.json?.refusal);
  ok(String(noReview.stderr).includes('refused - review_missing.'), 'and the operator sees it on stderr');
  ok(noReview.json?.observed.tip === B.tip, 'the branch itself was pushed: only the review is missing');

  // ---- 3. a review of a DIFFERENT TREE: REFUSED --------------------------------------------------
  console.log('3. a review of a different tree');
  git(work, 'switch', '-q', '-c', branches.C, base);
  write(path.join(work, 'c.txt'), 'c-v1\n');
  git(work, 'add', 'c.txt');
  git(work, 'commit', '-q', '-m', `c v1\n\nAgent: wasm-agent node=fixture session=${sessions.producerC}`);
  const cOld = git(work, 'rev-parse', 'HEAD');
  write(path.join(work, 'c.txt'), 'c-v2\n');
  git(work, 'add', 'c.txt');
  git(work, 'commit', '-q', '-m', `c v2\n\nAgent: wasm-agent node=fixture session=${sessions.producerC}`);
  const cNew = git(work, 'rev-parse', 'HEAD');
  git(work, 'push', '-q', '-u', 'origin', branches.C);
  const createdC = node(RECORD, ['create', branches.C, '--repo', work, '--store', store,
    '--tip', cNew, '--producer', sessions.producerC]);
  ok(createdC.status === 0, 'the record names the tip that is pushed', createdC.stderr.trim());
  const reviewC = review(branches.C, {reviewer: sessions.reviewerC, tip: cOld});
  const wrongTree = check(branches.C);
  recorded.cases.push({name: 'wrong_tree', exit: wrongTree.status, verdict: exposed(wrongTree.json)});
  const oldTree = git(work, 'rev-parse', `${cOld}^{tree}`);
  const newTree = git(work, 'rev-parse', `${cNew}^{tree}`);
  ok(oldTree !== newTree, 'the fixture really is two different trees', `${oldTree} vs ${newTree}`);
  ok(wrongTree.status === 2 && wrongTree.json?.condition === 'review_names_a_different_tree',
    'refused, naming the tree binding', JSON.stringify({exit: wrongTree.status, condition: wrongTree.json?.condition}));
  ok(String(wrongTree.json?.refusal).includes(oldTree) && String(wrongTree.json?.refusal).includes(newTree),
    'the refusal text carries both trees', wrongTree.json?.refusal);
  ok(String(wrongTree.json?.refusal).includes('a review of a different tree is not a review of this delivery'),
    'and says why it matters');
  ok(wrongTree.json?.review?.tree === oldTree && wrongTree.json?.observed.tree === newTree,
    'the record and the observation disagree about the tree, which is the refusal');
  ok(wrongTree.json?.observed.review_commit_contains_tip === false,
    'the review commit does not even contain the pushed tip (recorded as evidence, not as a condition)');

  // ---- 4. a narrowed review with a named caveat: ADMITTED WITH CAVEAT -----------------------------
  console.log('4. a narrowed review, with what it left open');
  const D = delivery(branches.D, {file: 'd.txt', text: 'd\n', producer: sessions.producerD});
  review(branches.D, {reviewer: sessions.reviewerD, tip: D.tip, verdict: 'narrowed', findings: [
    `summary_exceeds_code:resolved:the doc said the retry always reuses the shell; it reuses it when the key matches`,
    `unverifiable_claim:unresolved:the cross-node resolve hop was reasoned, not measured on this machine`,
  ]});
  const caveat = check(branches.D);
  recorded.cases.push({name: 'admitted_with_caveat', exit: caveat.status, verdict: exposed(caveat.json)});
  ok(caveat.status === 0 && caveat.json?.decision === 'admitted_with_caveat',
    'admitted with caveat, exit 0', JSON.stringify({exit: caveat.status, decision: caveat.json?.decision, condition: caveat.json?.condition}));
  ok(caveat.json?.caveats.length === 2 && caveat.json?.caveats.some(item => item.class === 'unverifiable_claim'),
    'both findings are carried as named caveats', JSON.stringify(caveat.json?.caveats));
  ok(caveat.json?.conditions.every(item => item.ok) === true,
    'a resolved excess-claim finding and an unverifiable claim do not block');

  // ---- 5. an UNRESOLVED excess-claim finding: REFUSED, and named ---------------------------------
  console.log('5. an unresolved "the summary claims more than the code"');
  const F = delivery(branches.F, {file: 'f.txt', text: 'f\n', producer: sessions.producerF});
  review(branches.F, {reviewer: sessions.reviewerF, tip: F.tip, findings: [
    `summary_exceeds_code:unresolved:the doc says the tick is capped; the loop is uncapped (orchestrator.lua:145-165)`,
  ]});
  const excess = check(branches.F);
  recorded.cases.push({name: 'unresolved_excess_claim', exit: excess.status, verdict: exposed(excess.json)});
  ok(excess.status === 2 && excess.json?.condition === 'finding_unresolved:summary_exceeds_code',
    'refused, naming the class that blocks', JSON.stringify({exit: excess.status, condition: excess.json?.condition}));
  ok(String(excess.json?.refusal).includes('the loop is uncapped'),
    'the refusal carries the finding text, so the reader can act on it', excess.json?.refusal);

  // ---- 6. a producer cannot admit its own work ----------------------------------------------------
  console.log('6. the producer tries to admit its own delivery');
  const selfAdmit = node(ADMISSION, ['admit', branches.A, '--store', store, '--by', sessions.producerA]);
  recorded.cases.push({name: 'self_admission', exit: selfAdmit.status,
    verdict: {decision: selfAdmit.json?.decision, condition: selfAdmit.json?.condition, refusal: selfAdmit.json?.refusal}});
  ok(selfAdmit.status === 2 && selfAdmit.json?.condition === 'self_admission_refused',
    'refused, naming self_admission_refused');
  ok(String(selfAdmit.json?.refusal).includes(sessions.producerA), 'the refusal names the session that asked');
  const stored = node(RECORD, ['get', branches.A, '--store', store]);
  ok(stored.json?.record?.admission === null, 'and nothing was written into the record');
  const byReviewer = node(ADMISSION, ['admit', branches.A, '--store', store, '--by', sessions.reviewerA]);
  recorded.cases.push({name: 'independent_admission', exit: byReviewer.status,
    verdict: {decision: byReviewer.json?.decision, condition: byReviewer.json?.condition, by: byReviewer.json?.by}});
  ok(byReviewer.status === 0 && byReviewer.json?.decision === 'admitted', 'a lane that is not the producer admits it, exit 0');
  ok(node(RECORD, ['get', branches.A, '--store', store]).json?.record?.admission?.by === sessions.reviewerA,
    'the admission is in the record, with who made it');

  // ---- 7. the trigger: one pass, then a second, then the shape of its output ----------------------
  console.log('7. the deterministic pass');
  const first = node(TRIGGER, ['--store', store, '--no-emit']);
  recorded.cases.push({name: 'trigger_rehearsal', exit: first.status,
    verdict: {counts: first.json?.counts, refused: first.json?.refused}});
  ok(first.status === 0, 'the pass completes even though deliveries were refused', String(first.status));
  ok(first.json?.counts.records === 5, 'it read every record', JSON.stringify(first.json?.counts));
  ok(first.json?.counts.refused === 3, 'three deliveries are refused on this store (no review, wrong tree, excess claim)',
    JSON.stringify(first.json?.counts));
  for (const name of ['no_review', 'wrong_tree', 'unresolved_excess_claim']) {
    const wanted = recorded.cases.find(item => item.name === name).verdict.condition;
    ok(first.json?.refused.some(item => item.condition === wanted), `the pass reports ${wanted}`, JSON.stringify(first.json?.refused));
  }
  ok(first.json?.counts.emitted === 0 && first.json?.emit === false, 'nothing was emitted in a rehearsal');
  ok(node(RECORD, ['get', branches.B, '--store', store]).json?.record?.admission?.condition === 'review_missing',
    'a refusal is written into the record, never skipped');
  const second = node(TRIGGER, ['--store', store, '--no-emit']);
  ok(second.json?.counts.records === 5 && second.json?.counts.refused === 3, 'a second pass is the same pass (idempotent)');

  // ---- 8. the falsification: remove the tree binding ----------------------------------------------
  console.log('8. falsification - the tree binding removed');
  const spliced = path.join(root, 'spliced', 'scripts');
  fs.mkdirSync(path.join(spliced, 'lib'), {recursive: true});
  const source = fs.readFileSync(ADMISSION, 'utf8');
  fs.copyFileSync(path.join(HERE, 'lib', 'delivery-store.mjs'), path.join(spliced, 'lib', 'delivery-store.mjs'));
  for(const file of ['producer-admission.mjs','gate-check.mjs','gate-checks.mjs','lib/test-verdict.cjs','lib/wave-guard.mjs','lib/delivery-local.mjs','lib/delivery-producer-proof.mjs'])
    fs.copyFileSync(path.join(HERE,file),path.join(spliced,file));
  const binding = [
    '    const sameTree = Boolean(observations.tree) && review.tree === observations.tree;',
    "    add('review_names_a_different_tree', sameTree,",
    "      `the review names tree ${review.tree}, ${refName} is tree ${observations.tree || '(no ref)'}`);",
  ].join('\n');
  const weakened = source.replace(binding, '    const sameTree = false;');
  ok(source.includes(binding) && weakened !== source && !weakened.includes("add('review_names_a_different_tree'"),
    'the splice really removed the tree binding from the copy (the original is untouched)',
    `binding found: ${source.includes(binding)}; changed: ${weakened !== source}`);
  fs.writeFileSync(path.join(spliced, 'delivery-admission.mjs'), weakened);
  const weakenedResult = node(path.join(spliced, 'delivery-admission.mjs'), ['check', branches.C, '--store', store]);
  recorded.cases.push({name: 'falsification_no_tree_binding', exit: weakenedResult.status,
    verdict: {decision: weakenedResult.json?.decision, condition: weakenedResult.json?.condition, refusal: weakenedResult.json?.refusal}});
  ok(weakenedResult.status === 0 && weakenedResult.json?.decision === 'admitted',
    'WITHOUT the tree binding the wrong-tree delivery is wrongly ADMITTED',
    JSON.stringify({exit: weakenedResult.status, decision: weakenedResult.json?.decision}));
  ok(weakenedResult.json?.observed.tree !== weakenedResult.json?.review?.tree,
    'and the two trees still disagree in the same output - the check was the only thing refusing it');
  const restored = fs.readFileSync(ADMISSION, 'utf8');
  ok(restored === source && crypto.createHash('sha256').update(restored).digest('hex') === crypto.createHash('sha256').update(source).digest('hex'),
    'the original is byte-identical after the falsification (nothing was edited in place)');
  const afterFalsification = check(branches.C);
  ok(afterFalsification.status === 2 && afterFalsification.json?.decision === 'refused',
    'and with the tree binding in place the same delivery is refused again');

  // Outside harnesses must retain their real provenance, including session IDs with colons.
  for (const harness of ['codex', 'pi', 'claude']) {
    const branch = `change/fixture-${harness}-review`;
    const produced = delivery(branch, {file: `${harness}.txt`, text: `${harness}\n`, producer: sessions.producerA});
    const reviewer = `${harness}:review:independent`;
    review(branch, {reviewer, tip: produced.tip, harness});
    const accepted = check(branch);
    ok(accepted.status === 0 && accepted.json?.decision === 'admitted', `${harness} review keeps authentic harness provenance`);
    const file = path.join(store, `${branch.replace(/[^A-Za-z0-9._-]/g, '-')}.json`);
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    record.review.reviewer = 'another-session';
    write(file, JSON.stringify(record));
    const mismatch = check(branch);
    ok(mismatch.status === 2 && mismatch.json?.condition === 'review_anchor_names_another_session',
      `${harness} still refuses an unrelated reviewer identity`);
  }

  const refusedBranch = 'change/fixture-refused-review';
  const refusedDelivery = delivery(refusedBranch, {file: 'refused.txt', text: 'refused\n', producer: sessions.producerA});
  review(refusedBranch, {reviewer: sessions.reviewerA, tip: refusedDelivery.tip, verdict: 'refused', harness: 'codex'});
  const refusedReview = check(refusedBranch);
  ok(refusedReview.status === 2 && refusedReview.json?.condition === 'review_verdict_not_accepted',
    'a published Codex review with a refused verdict remains refused');

  for (const [kind,trailer] of [
    ['substring','Agent: codex nosession=external'],
    ['legacy','Agent: codex external'],
    ['ambiguous','Agent: codex session=external session=external'],
    ['body-spoof','Agent: codex session=external\n\nA quoted identity is not the footer.\n\nAgent: codex session=another-reviewer'],
  ]) {
    const branch=`change/fixture-${kind}-session`;
    const source=delivery(branch,{file:`${kind}.txt`,text:kind,producer:sessions.producerA});
    review(branch,{reviewer:'external',tip:source.tip,trailer});
    const refusal=check(branch);
    ok(refusal.status===2 && refusal.json?.condition==='review_anchor_names_another_session',`${kind} provenance cannot impersonate an explicit session token`);
  }

  // ---- 9. nothing was changed anywhere but the scratch store ---------------------------------------
  console.log('9. the fixture repository is intact');
  ok(git(work, 'status', '--porcelain') === '', 'the fixture worktree is clean');
  ok(git(work, 'rev-parse', branches.C) === cNew && git(work, 'rev-parse', `${branches.C}^{tree}`) === newTree,
    'no fixture branch moved and no tree changed');
  ok(git(work, 'rev-parse', `${branches.C}~1`) === cOld, 'the reviewed tip is still the tip that was reviewed');
  ok(fs.existsSync(store), 'the record store is scratch, and it is where this test put it');
  ok(Object.keys(JSON.parse(fs.readFileSync(path.join(store, `${branches.A.replace(/[^A-Za-z0-9._-]/g, '-')}.json`), 'utf8'))).includes('producer'),
    'one file per delivery: the record is a durable, readable object');
} catch (error) {
  failed += 1;
  console.log(`  FAIL harness - ${error.message}`);
} finally {
  const recordAt = process.argv.indexOf('--record');
  if (recordAt > 0 && process.argv[recordAt + 1]) {
    fs.writeFileSync(path.resolve(process.argv[recordAt + 1]), `${JSON.stringify(recorded, null, 2)}\n`);
    console.log(`recorded: ${path.resolve(process.argv[recordAt + 1])}`);
  }
  if (!process.env.WA_DELIVERY_TEST_KEEP) fs.rmSync(root, {recursive: true, force: true});
  else console.log(`fixture retained: ${root}`);
  console.log(failed ? `delivery admission: ${checks - failed}/${checks} ok, ${failed} FAILED`
    : `delivery admission ok (${checks} checks)`);
  process.exitCode = failed ? 1 : 0;
}
