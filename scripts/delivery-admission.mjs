#!/usr/bin/env node
// The admission rule: may this delivery enter the merge lane, and if not, which condition failed.
//
// THE RULE, IN ONE PARAGRAPH. A delivery may enter only when (a) its branch is pushed - the tip the
// record names is the tip `origin` holds; (b) an independent review exists and names the SAME TREE as
// that tip - where "independent" means a reviewer that is not the producer, identified by a commit
// that is published in this repository and whose `Agent:` trailer names that reviewer; and (c) no
// finding of the class `summary_exceeds_code` ("the summary claims more than the code") is unresolved.
// A producer cannot admit its own work. Every failure is a named refusal with a reason - a missing
// review, a review of a different tree and an unresolved finding are each visible, never a skip.
//
// THE THREE OUTCOMES. `admitted` (all conditions hold, nothing to carry), `admitted_with_caveat` (all
// conditions hold, and the review left named caveats - an unverifiable claim, a boundary gap, a claim
// it narrowed), `refused` (a condition failed; `condition` names it and `refusal` is the sentence an
// operator reads). A caveat is not a refusal: it is what the merger must carry into the landing.
//
// WHAT THIS PROGRAM DOES NOT DO. It does not merge, push, gate or delete anything, and it does not
// decide whether a delivery *should* land - that is the reserved merger's judgement
// (`docs/FACTORY.md`, "What needs judgement"). It reads git and a record and answers one question.
//
// Usage:
//   node scripts/delivery-admission.mjs check <delivery> [--repo <path>] [--store <dir>] [--tip-ref <ref>]
//   node scripts/delivery-admission.mjs admit <delivery> --by <session> [same options]
//
//   --repo <path>     the repository whose refs are read (default: the record's own `repository`)
//   --store <dir>     the record store (default: $WA_DELIVERY_STORE, else <sentinel>/deliveries)
//   --tip-ref <ref>   A TEST/REHEARSAL SEAM: read "what is pushed" from this ref instead of
//                     refs/remotes/origin/<branch>. Recorded verbatim in the output as
//                     `observed.source`, so a run that used it cannot be mistaken for a real one.
//   --json <path>     also write the result there
//
// Exit codes: 0 admitted (with or without caveats); 2 a named refusal; 4 usage or repository error.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {nowIso, readRecord, storeDir, writeRecord} from './lib/delivery-store.mjs';

import {checkWaveAdmission} from './lib/wave-guard.mjs';
import {verifyProducer,verifyReviewedFocused} from './producer-admission.mjs';
import {mainOnly, managedLocal} from './lib/delivery-local.mjs';
const SCHEMA = 1;

/// The one finding class that blocks. It is the class the operator named: a summary that claims more
/// than the code does. Any other unresolved finding is carried as a caveat instead - a named risk is
/// information for the merger, and refusing on it would turn every honest "I could not verify X" into
/// a delivery that never lands.
const BLOCKING_CLASS = 'summary_exceeds_code';
// Harness names are provenance, not identity: the session is the review anchor.
const AGENT_TRAILER = /^Agent:[ \t]*[^\s]+[ \t]+([^\r\n]+)$/m;

const REMEDY = {
  record_missing: 'create one with scripts/delivery-record.mjs before the delivery can be admitted.',
  branch_not_pushed: 'push the branch; the reviewed tip on origin is the delivery.',
  tip_moved_since_record: 'record the tip that is pushed, and have it reviewed there.',
  review_missing: 'a review by a lane that did not produce the delivery is required; nothing is admitted on a claim.',
  review_verdict_not_accepted: 'obtain a passed or narrowed independent review; a refusal cannot enter the merge lane.',
  review_not_independent: 'a producer cannot review or admit its own work; ask another lane.',
  review_not_in_repository: 'the review must be a commit in this repository; a verdict that lives only in a message is not an artifact.',
  review_not_published: 'publish the review (merge or push it); an unpublished commit is not evidence another lane can read.',
  review_anchor_names_another_session: 'the reviewer named in the record is not the session whose commit the review is: one of the two is wrong.',
  review_names_a_different_tree: 'a review of a different tree is not a review of this delivery - re-review the pushed tip, or push the tip that was reviewed.',
  self_admission_refused: 'a producer cannot admit its own work; an independent lane admits it.',
};

function note(text) { process.stderr.write(`${text}\n`); }

function git(cwd, args, label, allowFailure = false) {
  const result = spawnSync('git', args, {cwd, encoding: 'utf8', windowsHide: true, maxBuffer: 16 * 1024 * 1024});
  if (result.error) throw Error(`${label || `git ${args[0]}`}: ${result.error.message}`);
  if (result.status !== 0 && !allowFailure) {
    throw Error(`${label || `git ${args[0]}`}: ${(result.stderr || '').trim() || `exit ${result.status}`}`);
  }
  return result.status === 0 ? result.stdout.trim() : null;
}

/// The reviewer's session, read from the `Agent:` trailer the commit guard already requires on every
/// commit here. This is the part of "independent" that is a fact rather than a declared field: a
/// record can say any session id, and this says whose commit the review actually is.
function anchorSession(repo, commit) {
  const body = git(repo, ['show', '--no-patch', '--format=%B', commit], 'review commit body');
  const match = (body || '').trimEnd().split(/\r?\n/).pop().match(AGENT_TRAILER);
  if (!match) return null;
  const sessions=[...match[1].matchAll(/(?:^|[ \t])session=([^ \t\r\n]+)(?=$|[ \t])/g)];
  return sessions.length===1 ? sessions[0][1] : null;
}

function refusal(delivery, condition, detail, remedy) {
  const lead = detail && !/[.!?]$/.test(detail) ? `${detail}.` : detail;
  return `${delivery}: refused - ${condition}. ${lead}${remedy ? ` ${remedy}` : ''}`;
}

/// Read what the repository says, then decide. `tipRef` is the seam above.
export function evaluate({repo, record, tipRef = null,phase='admit', sessionDb=null, recovery=null}) {
  if (!repo) throw Error('record names no repository: a record written before that field existed cannot be read');
  if(!['admit','observe'].includes(phase))throw Error('unsupported_delivery_evaluation_phase');
  const wave=checkWaveAdmission(repo,{phase,recovery});
  if(!wave.ok)return {schema:SCHEMA,delivery:record.delivery,decision:'refused',condition:'wave_admission_refused',refusal:wave.reason,wave,conditions:[],caveats:[],requires_combined_gate:false,gate_verified:false,release_verified:false};
  const branch = record.branch || record.delivery;
  const pushedRef = `refs/remotes/origin/${branch}`;
  const local=mainOnly(repo) && !tipRef;
  const refName = tipRef || (local ? `refs/heads/${branch}` : pushedRef);
  const observations = {ref: refName, source: tipRef ? `seam:${tipRef}` : local ? 'managed_local_unpublished' : 'pushed', fetched: false,
    tip: null, tree: null, local_ref: null, review_commit_contains_tip: null};
  const conditions = [];
  const add = (name, ok, detail, blocking = true) => {
    conditions.push({name, ok, detail, blocking, remedy: REMEDY[name] || ''});
    return ok;
  };

  const review = record.review;
  add('record_missing', Boolean(record.delivery && record.producer),
    `record for ${record.delivery} (producer ${record.producer})`);

  // -- what the repository holds ------------------------------------------------------------------
  const refTip = git(repo, ['rev-parse', '--verify', '--quiet', `${refName}^{commit}`], 'pushed tip', true);
  observations.tip = refTip;
  observations.local_ref = git(repo, ['rev-parse', '--verify', '--quiet', `refs/heads/${branch}^{commit}`], 'local tip', true);
  const pushed = add('branch_not_pushed', Boolean(refTip),
    refTip ? `${refName} = ${refTip}` : `${refName} does not exist`);
  if (refTip) observations.tree = git(repo, ['rev-parse', `${refTip}^{tree}`], 'tip tree', true);
  const sameTip = Boolean(refTip) && refTip === record.tip;
  if (refTip) {
    add('tip_moved_since_record', sameTip,
      sameTip ? `the pushed tip is the recorded tip ${record.tip}`
        : `${refName} is ${refTip}, the record names ${record.tip}: the branch moved after the record was written`);
  }

  if(local) {
    try {
      observations.producer_local=managedLocal(repo,record.producer,record.tip,sessionDb,branch);
      add('record_tree_matches_tip',record.tree===observations.producer_local.tree,'exact recorded tree');
      add('record_repository_matches',fs.realpathSync(git(repo,['rev-parse','--path-format=absolute','--git-common-dir']))===fs.realpathSync(git(record.repository,['rev-parse','--path-format=absolute','--git-common-dir'])),'same shared repository');
    } catch(error){add('local_producer_binding',false,error.message);}
    add('producer_receipt_required',Boolean(record.producer_checks),'main-only requires source-bound producer checks');
    add('producer_receipt_exact_tip',(record.producer_checks?.head===record.tip || (record.producer_checks?.kind==='retained-full' && record.producer_checks?.candidate_head===record.tip)),'receipt must name the exact commit');
  }
  // -- the review ---------------------------------------------------------------------------------
  add('review_missing', Boolean(review),
    review ? `review by ${review.reviewer} of tip ${review.tip} (tree ${review.tree})`
      : 'the record carries no review');
  if (review) {
    add('review_verdict_not_accepted', ['passed', 'narrowed'].includes(review.verdict),
      `the review verdict is ${review.verdict || '(missing)'}`);
    add('review_not_independent', Boolean(review.reviewer) && review.reviewer !== record.producer,
      `reviewer ${review.reviewer || '(nobody)'}, producer ${record.producer}`);
    const commit = review.commit
      ? git(repo, ['rev-parse', '--verify', '--quiet', `${review.commit}^{commit}`], 'review commit', true)
      : null;
    if (add('review_not_in_repository', Boolean(commit), commit ? `review commit ${commit}` : `review commit ${review.commit || '(none)'} is not in ${repo}`)) {
      const contained = git(repo, ['branch', '-r', '--contains', commit], 'review publication', true);
      if(local) {
        try{observations.reviewer_local=managedLocal(repo,review.reviewer,review.commit,sessionDb);}
        catch(error){add('local_reviewer_binding',false,error.message);}
      }
      add('review_not_published', local || Boolean(contained && contained.trim()),
        contained && contained.trim() ? `contained in ${contained.split('\n').map(line => line.trim()).join(', ')}`
          : `review commit ${commit} is in no pushed ref`);
      const session = anchorSession(repo, commit);
      add('review_anchor_names_another_session', Boolean(session) && session === review.reviewer,
        `the commit's Agent: trailer names ${session || '(no Agent: trailer)'}, the record names ${review.reviewer}`);
      // Evidence, not a condition: a review commit that contains the reviewed tip is a stronger
      // artifact, but a reviewer may legitimately review a tip it never merged.
      observations.review_commit_contains_tip = git(repo, ['merge-base', '--is-ancestor', record.tip, commit], 'ancestry', true) === '';
    }
    // THE BINDING. A gate receipt is bound to a tree, and so is a review: the branch's tree and the
    // reviewed tree are the same object only when the content is the same. This is the condition the
    // whole front of the lane exists for, and it is the one a falsification has to remove.
    const sameTree = Boolean(observations.tree) && review.tree === observations.tree;
    add('review_names_a_different_tree', sameTree,
      `the review names tree ${review.tree}, ${refName} is tree ${observations.tree || '(no ref)'}`);
    // Informational, deliberately NOT blocking: a review of a different commit with the same tree is a
    // review of the same content - that is what binding to a tree means.
    add('review_tip_is_the_tip', review.tip === refTip,
      `the review is of commit ${review.tip}, the pushed tip is ${refTip} (same tree: ${sameTree})`, local);
  }

  // -- findings: one blocking class, everything else carried --------------------------------------
  const findings = review?.findings || [];
  const caveats = [];
  for (const finding of findings) {
    const blocking = finding.class === BLOCKING_CLASS && finding.status !== 'resolved';
    add(blocking ? `finding_unresolved:${finding.class}` : `finding:${finding.class}:${finding.status}`, !blocking,
      `${finding.status}: ${finding.text}`);
    caveats.push({class: finding.class, status: finding.status, text: finding.text});
  }
  if (review?.verdict === 'narrowed' && !findings.length) {
    caveats.push({class: 'review_narrowed', status: 'narrowed',
      text: 'the review narrowed a claim; the record carries no finding text for the narrowing'});
  }

  // -- a producer cannot admit its own work -------------------------------------------------------
  const admission = record.admission || null;
  if (admission && admission.by && admission.by === record.producer) {
    // (`admit` refuses this before writing; this catches a record that got there another way.)
    add('self_admission_refused', false,
      `the recorded admission was written by the producer ${admission.by} (tip ${admission.tip})`);
  }

  // New focused receipts are opt-in during bootstrap. They prove producer checks,
  // never combined-tree verification; old reviewed records remain compatible.
  let producerProof = null;
  if (record.producer_checks) {
    if(record.producer_checks.focused_scope)add('focused_scope_independently_reviewed',JSON.stringify(review?.focused_scope)===JSON.stringify(record.producer_checks.focused_scope),'independent exact-source review must name the executed focused scope');
    producerProof = verifyProducer(observations.producer_local?.worktree || repo, record.producer_checks, refTip || record.tip);
    if(record.producer_checks.focused_scope&&producerProof.admission_verified)producerProof=verifyReviewedFocused(observations.producer_local?.worktree||repo,record.producer_checks,review,refTip||record.tip,record.producer);
    add('producer_checks_verified', producerProof.admission_verified === true,
      producerProof.error || `focused checks verified for tree ${producerProof.tree}`);
  }
  const failed = conditions.find(item => item.blocking && !item.ok) || null;
  const decision = failed ? 'refused' : (caveats.length ? 'admitted_with_caveat' : 'admitted');
  return {
    schema: SCHEMA,
    delivery: record.delivery,
    repository: repo,
    producer: record.producer,
    record: {tip: record.tip, tree: record.tree},
    review: review ? {reviewer: review.reviewer, commit: review.commit, tip: review.tip, tree: review.tree,
      verdict: review.verdict, findings: findings.length} : null,
    observed: observations,
    authority: observations.producer_local?.source?.kind==='private-fixture' ? 'private-fixture-only' : local ? 'runtime-managed-local' : tipRef ? 'rehearsal' : 'published',
    wave,
    producer_checks: producerProof,
    requires_combined_gate: false,
    gate_verified: false,
    release_verified: false,
    conditions,
    decision,
    condition: failed ? failed.name : 'admitted',
    refusal: failed ? refusal(record.delivery, failed.name, failed.detail, failed.remedy) : null,
    caveats,
    at: nowIso(),
  };
}

// ------------------------------------------------------------------------------------------------
function parse(argv) {
  const options = {positional: [], store: null, repo: null, tipRef: null, json: null, by: null, producerProof: null};
  const flags = new Map([['--repo', 'repo'], ['--store', 'store'], ['--tip-ref', 'tipRef'],
    ['--json', 'json'], ['--by', 'by'], ['--producer-proof','producerProof'], ['--session-db','sessionDb'], ['--recovery-receipt','recoveryReceipt']]);
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (flags.has(token)) { options[flags.get(token)] = argv[index + 1] ?? ''; index += 1; continue; }
    if (token.startsWith('--')) throw Error(`unknown option ${token}`);
    options.positional.push(token);
  }
  return options;
}

function main() {
  const [verb, delivery] = process.argv.slice(2);
  let options;
  try { options = parse(process.argv.slice(3)); }
  catch (error) { note(`usage: ${error.message}`); process.exit(4); }
  if (!['check', 'admit'].includes(verb) || !delivery) {
    note('usage: delivery-admission.mjs check|admit <delivery> [--repo <path>] [--store <dir>] [--tip-ref <ref>] [--by <session>]');
    process.exit(4);
  }
  const store = options.store || storeDir();
  let record;
  try { record = readRecord(store, delivery); }
  catch (error) { note(String(error.message)); process.exit(4); }
  if (!record) {
    const result = {schema: SCHEMA, delivery, store, decision: 'refused', condition: 'record_missing',
      refusal: refusal(delivery, 'record_missing', `no record in ${store}`, REMEDY.record_missing),
      conditions: [], caveats: [], at: nowIso()};
    note(result.refusal);
    if (options.json) fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(result, null, 2)}\n`);
    console.log(JSON.stringify(result, null, 2));
    process.exit(2);
  }
  const repo = options.repo ? path.resolve(options.repo) : record.repository;
  let result;
  try {
    if (options.producerProof) record.producer_checks=JSON.parse(fs.readFileSync(path.resolve(options.producerProof),'utf8'));
    result = evaluate({repo, record, tipRef: options.tipRef, sessionDb:options.sessionDb, recovery:options.recoveryReceipt ? {receipt_file:options.recoveryReceipt,delivery:record.delivery,tip:record.tip,tree:record.tree,review_commit:record.review?.commit,reviewer:record.review?.reviewer,expected_main:git(repo,['rev-parse','origin/main'])} : null});
  }
  catch (error) { note(`${delivery}: ${error.message}`); process.exit(4); }

  if (verb === 'admit') {
    if (!options.by) { note('admit needs --by <session id>: an admission is an act somebody owns'); process.exit(4); }
    result.by = options.by;
    if (result.decision !== 'refused' && options.by === record.producer) {
      result.decision = 'refused';
      result.condition = 'self_admission_refused';
      result.refusal = refusal(delivery, 'self_admission_refused',
        `the producer ${record.producer} is the one asking`, REMEDY.self_admission_refused);
    }
    if (result.decision === 'refused') {
      record.admission_history=[...(record.admission_history||[]),{...result,revision:record.revision,at:nowIso()}];
      writeRecord(store,record);
      note(result.refusal);
    } else {
      const fresh=evaluate({repo,record,tipRef:options.tipRef,sessionDb:options.sessionDb,recovery:options.recoveryReceipt ? {receipt_file:options.recoveryReceipt,delivery:record.delivery,tip:record.tip,tree:record.tree,review_commit:record.review?.commit,reviewer:record.review?.reviewer,expected_main:git(repo,['rev-parse','origin/main'])} : null});
      if(fresh.decision==='refused')throw Error(fresh.refusal);
      if(record.admission)record.admission_history=[...(record.admission_history||[]),record.admission];
      record.admission = {state: result.decision, condition: 'admitted', by: options.by,
        tip: result.observed.tip, tree: result.observed.tree, caveats: result.caveats, event: null, at: nowIso()};

      writeRecord(store, record);
      result.admitted = {state: result.decision, by: options.by, tip: result.observed.tip, tree: result.observed.tree};
      note(`${delivery}: ${result.decision} by ${options.by} (tip ${(result.observed.tip || '').slice(0, 7)}, tree ${(result.observed.tree || '').slice(0, 8)}${result.caveats.length ? `, ${result.caveats.length} named caveat(s)` : ''})`);
    }
  } else if (result.decision === 'refused') {
    note(result.refusal);
  } else {
    note(`${delivery}: ${result.decision}${result.caveats.length ? ` with ${result.caveats.length} named caveat(s)` : ''}`);
  }

  if (options.json) fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.decision === 'refused' ? 2 : 0);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
