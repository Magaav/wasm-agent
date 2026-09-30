#!/usr/bin/env node
// The trigger's deterministic pass: read every delivery record, apply the admission rule, write the
// decision back into the record, and emit ONE event per newly-admitted delivery.
//
// WHY THIS IS A `run` AND NOT A `wake`. Every step here is decidable: read a record, read git, compare
// two shas, write the decision. None of it needs an opinion, so none of it may cost a model turn
// (skills/automation-jobs/SKILL.md: "if a step can be decided without judgement, it must not cost a
// token"). The judgement - whether to land it, in what order, with what caveats - is the wake the
// emitted event causes, and it is the only part that is budgeted.
//
// A durable outbox intent precedes emission. Only the expected subscriber's exact
// revision/event/payload receipt acknowledges it; exit 0 or queued 0 never does.
// Reconciliation reads the existing effect before retrying the idempotent enqueue.
// This acknowledges queue arrival, not review, gate execution or publication.
//
// Usage:
//   node scripts/delivery-trigger.mjs [--store <dir>] [--repo <path>] [--limit <n>] [--no-emit]
//                                     [--emit-command <exe>] [--subscriber <id>] [--json <path>]
//                                     [--receipt-db <path>]
//
//   --store <dir>       the record store (default: $WA_DELIVERY_STORE, else <sentinel>/deliveries)
//   --repo <path>       only records whose `repository` is this path
//   --limit <n>         at most n newly-admitted deliveries per pass (default 8)
//   --no-emit           decide and record, emit nothing (a rehearsal: the output says so)
//   --emit-command <x>  the sentinel binary used to emit (default `wa-sentinel`), recorded verbatim
//   --subscriber <id>   exact enabled event subscriber (default delivery-lane)
//   --receipt-db <path> explicit temporary read-only observation for a legacy sentinel
//
// Exit codes: 0 a completed pass - including one where every delivery was refused, because a refusal is
// an answer; 4 usage, unreadable state, unacknowledged event or repository error. Admission refusal
// whose history is a wall of failures is a job nobody can read.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {nowIso, listRecords, slug, storeDir, writeRecord} from './lib/delivery-store.mjs';
import {evaluate} from './delivery-admission.mjs';
import {eventIdentity,subscriber,acknowledged} from './lib/delivery-outbox.mjs';

const SCHEMA = 1;
const TOPIC = 'delivery.admitted';

function note(text) { process.stderr.write(`${text}\n`); }

function parse(argv) {
  const options = {store: null, repo: null, limit: 8, emit: true, emitCommand: 'wa-sentinel', json: null,subscriber:'delivery-lane'};
  const flags = new Map([['--store', 'store'], ['--repo', 'repo'], ['--limit', 'limit'],
    ['--emit-command', 'emitCommand'], ['--json', 'json'], ['--subscriber','subscriber'], ['--receipt-db','receiptDb']]);
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--no-emit') { options.emit = false; continue; }
    if (flags.has(token)) { options[flags.get(token)] = argv[index + 1] ?? ''; index += 1; continue; }
    throw Error(`unknown option ${token}`);
  }
  options.limit = Number(options.limit);
  if (!Number.isFinite(options.limit) || options.limit < 0) throw Error('--limit wants a whole number');
  return options;
}

/// The payload the wake reads. It carries the whole admission - both shas, the reviewer, the caveats -
/// and the exact merge-lane command for this tip, so the judgement starts from artifacts rather than
/// from a re-derivation.
function payloadFor(record, result, dir) {
  return {
    delivery: record.delivery,
    branch: record.branch,
    repository: result.repository,
    tip: result.observed.tip,
    tree: result.observed.tree,
    producer: record.producer,
    review: result.review,
    caveats: result.caveats,
    decision: result.decision,
    record: path.join(dir, `${slug(record.delivery)}.json`),
    lane: {
      command: `node scripts/merge-lane.mjs --repo ${result.repository} ${result.observed.tip}`,
      note: 'the lane gates the merged tree in a disposable clone and never pushes; installing its job is an operator act.',
    },
  };
}

function emit(record, result, options, store) {
  const eventId = record.admission.event.id;
  const payloadFile = record.admission.event.payload_file;
  const args = ['job', 'emit', TOPIC, eventId, payloadFile];
  const command = `${options.emitCommand} ${args.join(' ')}`;
  const run = spawnSync(options.emitCommand, args, {encoding: 'utf8', windowsHide: true, timeout: 60000});
  const stdout = (run.stdout || '').trim();
  let queued = null;
  try { queued = JSON.parse(stdout).queued ?? null; } catch { queued = null; }
  const outcome = {
    id: eventId, topic: TOPIC, payload: payloadFile, command,
    queued, exit: run.status, stdout: stdout || null,
    error: run.error ? String(run.error.message) : (run.status === 0 ? null : (run.stderr || '').trim() || null),
    at: nowIso(),
  };
  return outcome;
}

function main() {
  let options;
  try { options = parse(process.argv.slice(2)); }
  catch (error) { note(`usage: delivery-trigger.mjs [--store <dir>] [--repo <path>] [--limit <n>] [--no-emit] [--json <path>]\n       ${error.message}`); process.exit(4); }
  const store = options.store ? path.resolve(options.store) : storeDir();
  const repositoryFilter = options.repo ? path.resolve(options.repo).replace(/\\/g, '/') : null;

  let records;
  try { records = listRecords(store); }
  catch (error) { note(`store unreadable: ${store}: ${error.message}`); process.exit(4); }

  const result = {schema: SCHEMA, generated_at: nowIso(), store, topic: TOPIC,
    emit: options.emit, emit_command: options.emitCommand, repository_filter: repositoryFilter,
    limit: options.limit, counts: {records: records.length, admitted: 0, admitted_with_caveat: 0,pending_events:0,write_errors:0,
    refused: 0, emitted: 0, skipped: 0, unreadable: 0}, admitted: [], refused: [], skipped: [], emitted: []};
  let eventAttempts=0;

  for (const record of records) {
    if (record.unreadable) {
      result.counts.unreadable += 1;
      result.skipped.push({record: record.path, reason: 'unreadable', detail: record.unreadable});
      note(`${record.delivery}: unreadable record: ${record.unreadable}`);
      continue;
    }
    const repository = String(record.repository || '').replace(/\\/g, '/');
    if (repositoryFilter && repository !== repositoryFilter) {
      result.counts.skipped += 1;
      result.skipped.push({delivery: record.delivery, reason: 'other_repository', detail: repository});
      continue;
    }
    if (record.landing && record.landing.sha) {
      result.counts.skipped += 1;
      result.skipped.push({delivery: record.delivery, reason: 'already_landed', detail: record.landing.sha});
      continue;
    }

    let decision;
    try { decision = evaluate({repo: repository, record}); }
    catch (error) {
      result.counts.skipped += 1;
      result.skipped.push({delivery: record.delivery, reason: 'repository_unreadable', detail: String(error.message)});
      note(`${record.delivery}: ${error.message}`);
      continue;
    }

    let subscription=null,subscriptionError=null;
    if (options.emit && decision.decision!=='refused') {
      try { subscription=subscriber(options.emitCommand,options.subscriber); }
      catch(error) { subscriptionError=error.message; }
    }
    const eventId = eventIdentity(record,decision,subscription);
    const alreadyEmitted = record.outbox?.[eventId]?.state==='acknowledged';
    const previous = record.admission;
    const isNewDecision = previous && (previous.state !== decision.decision || previous.tip !== decision.observed.tip);
    record.admission = {
      state: decision.decision,
      condition: decision.condition,
      refusal: decision.refusal,
      by: 'delivery-trigger',
      tip: decision.observed.tip,
      tree: decision.observed.tree,
      caveats: decision.caveats,
      event: decision.decision === 'refused' ? null : (record.outbox?.[eventId] || null),
      at: decision.at,
    };
    if (isNewDecision) record.admission_history = [...(record.admission_history || []), previous].slice(-5);

    const newlyAdmitted = decision.decision !== 'refused' && !alreadyEmitted;
    if (decision.decision === 'refused') {
      result.counts.refused += 1;
      result.refused.push({delivery: record.delivery, condition: decision.condition, refusal: decision.refusal,
        tip: decision.observed.tip, tree: decision.observed.tree});
      note(decision.refusal);
    } else {
      const bucket = decision.decision === 'admitted' ? 'admitted' : 'admitted_with_caveat';
      result.counts[bucket] += 1;
      if (newlyAdmitted && eventAttempts < options.limit) {
        if (options.emit) {
          eventAttempts++;
          const intent=record.admission.event || {id:eventId,subscription,state:'pending',attempts:0,at:nowIso()};
          intent.payload=intent.payload || payloadFor(record,decision,store);
          intent.payload_file=path.join(store,'events',`${slug(eventId)}.json`);
          record.outbox={...(record.outbox || {}),[eventId]:intent};record.admission.event=intent;
          try {
            writeRecord(store,record); // intent is durable before queue/external observation
            if (subscriptionError) throw Error(subscriptionError);
            const events=path.join(store,'events');fs.mkdirSync(events,{recursive:true});
            const payloadFile=intent.payload_file;
            if (!fs.existsSync(payloadFile)) {
              const fd=fs.openSync(payloadFile,'wx');
              try{fs.writeFileSync(fd,JSON.stringify(intent.payload)+'\n');fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
            }
            let receipt=acknowledged({command:options.emitCommand,subscription,id:eventId,payloadFile,receiptDb:options.receiptDb});
            if (!receipt.acknowledged) {
              intent.attempts++;intent.last_attempt=emit(record,decision,options,store);
              receipt=acknowledged({command:options.emitCommand,subscription,id:eventId,payloadFile,receiptDb:options.receiptDb});
            }
            intent.receipt=receipt;
            if (receipt.acknowledged) {
              intent.state='acknowledged';intent.acknowledged_at=nowIso();
              record.emitted_events=[...(record.emitted_events || []),eventId];
              result.counts.emitted++;result.emitted.push({delivery:record.delivery,event:intent});
            } else throw Error('event_not_acknowledged: expected subscription has no exact durable enqueue effect');
          } catch(error) {
            intent.error=error.message;result.counts.pending_events++;
            result.skipped.push({delivery:record.delivery,reason:'event_pending',detail:error.message});
            note(`${record.delivery}: event pending - ${error.message}`);
          }
        } else {
          result.emitted.push({delivery: record.delivery, event: null, suppressed: true});
          note(`${record.delivery}: ${decision.decision} - emission suppressed (--no-emit)`);
        }
      } else {
        note(`${record.delivery}: ${decision.decision}${newlyAdmitted ? ' (event already emitted)' : ' (unchanged; no new event)'}`);
      }
      result.admitted.push({delivery: record.delivery, state: decision.decision, tip: decision.observed.tip,
        tree: decision.observed.tree, reviewer: decision.review?.reviewer ?? null,
        review_commit: decision.review?.commit ?? null, caveats: decision.caveats,
        event: record.admission.event ? record.admission.event.id : null, newly_admitted: newlyAdmitted});
    }
    try { writeRecord(store, record); }
    catch(error) {
      result.counts.write_errors++;
      result.skipped.push({delivery:record.delivery,reason:'record_write_failed',detail:error.message});
      note(`${record.delivery}: record not settled - ${error.message}`);
    }
  }

  if (options.json) fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(result, null, 2)}\n`);
  note(`delivery trigger: ${result.counts.records} record(s), ${result.counts.admitted + result.counts.admitted_with_caveat} admitted, ${result.counts.refused} refused, ${result.counts.emitted} emitted, ${result.counts.skipped} skipped`);
  console.log(JSON.stringify(result, null, 2));
  process.exitCode=result.counts.pending_events || result.counts.write_errors ? 4 : 0;
}

main();
