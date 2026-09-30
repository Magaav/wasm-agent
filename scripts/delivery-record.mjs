#!/usr/bin/env node
// The record: one durable file per delivery, updated in place, readable by an operator.
//
// What the record is FOR: the merge lane's front has three facts that nothing connected before -
// "this delivery settled", "an independent review exists, of this exact tree", "this may land". Each
// is a field here, and the fields are written by the lane that owns them (the producer creates the
// record, the reviewer writes the verdict, the rule writes the admission, the lane writes its own
// outcome and the landing sha). The store is `scripts/lib/delivery-store.mjs`; see its header for why
// it is the sentinel's store and not another one.
//
// Usage:
//   node scripts/delivery-record.mjs create <branch> --repo <path> --tip <sha> --producer <session>
//   node scripts/delivery-record.mjs review <branch> --reviewer <session> --commit <review-sha>
//                                              --tip <sha> [--verdict passed|narrowed|refused]
//                                              [--finding <class>:<status>:<text>]...
//   node scripts/delivery-record.mjs lane   <branch> --verdict <name> [--tree <sha>]
//                                              [--exit <n>] [--report <path>]
//   node scripts/delivery-record.mjs land   <branch> --sha <sha>
//   node scripts/delivery-record.mjs get    <branch>
//   node scripts/delivery-record.mjs list
//
// Options: --repo <path> (default: the git root of the cwd), --store <dir> (default: $WA_DELIVERY_STORE
// or <sentinel store>/deliveries), --json <path> (also write the result there).
//
// The tree is never typed by hand: every verb that needs one derives it from the commit it names with
// `git rev-parse <sha>^{tree}`. A record cannot hold a tree the repository does not have.
//
// Exit codes: 0 ok; 2 a named refusal (record_exists, record_missing, ...); 4 usage or repository error.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {listRecords, nowIso, readRecord, recordPath, storeDir, writeRecord} from './lib/delivery-store.mjs';

const SCHEMA = 1;

function note(text) { process.stderr.write(`${text}\n`); }

function fail(code, condition, detail) {
  const result = {ok: false, condition, detail};
  note(`${condition}: ${detail}`);
  console.log(JSON.stringify(result, null, 2));
  process.exit(code);
}

function git(cwd, args, label) {
  const result = spawnSync('git', args, {cwd, encoding: 'utf8', windowsHide: true, maxBuffer: 16 * 1024 * 1024});
  if (result.error || result.status !== 0) {
    throw Error(`${label || `git ${args[0]}`}: ${(result.error?.message || result.stderr || '').trim() || `exit ${result.status}`}`);
  }
  return result.stdout.trim();
}

function repoRoot(start) {
  return git(start, ['rev-parse', '--show-toplevel'], 'repository').replace(/\\/g, '/');
}

function parse(argv) {
  const options = {positional: [], store: null, repo: null, json: null, findings: []};
  const flags = new Map([
    ['--repo', 'repo'], ['--store', 'store'], ['--json', 'json'], ['--tip', 'tip'],
    ['--producer', 'producer'], ['--reviewer', 'reviewer'], ['--commit', 'commit'],
    ['--verdict', 'verdict'], ['--tree', 'tree'], ['--exit', 'exit'], ['--report', 'report'],
    ['--sha', 'sha'], ['--at', 'at'],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--finding') {
      options.findings.push(argv[index + 1] ?? '');
      index += 1;
      continue;
    }
    if (flags.has(token)) {
      options[flags.get(token)] = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (token.startsWith('--')) fail(4, 'usage', `unknown option ${token}`);
    options.positional.push(token);
  }
  return options;
}

function emit(result, options, code = 0) {
  if (options.json) fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result, null, 2));
  process.exit(code);
}

/// `class:status:text` - status is one of `unresolved` or `resolved`. Split on the first two colons
/// only, so the text may contain anything, including colons and newlines.
function parseFinding(raw) {
  const first = raw.indexOf(':');
  const second = raw.indexOf(':', first + 1);
  if (first < 1 || second < 0) fail(4, 'usage', `--finding wants <class>:<status>:<text>, got '${raw}'`);
  const finding = {class: raw.slice(0, first), status: raw.slice(first + 1, second), text: raw.slice(second + 1)};
  if (!['resolved', 'unresolved'].includes(finding.status)) {
    fail(4, 'usage', `--finding status must be resolved or unresolved, got '${finding.status}'`);
  }
  return finding;
}

/// The store is always needed; the repository is only needed by the verbs that derive a tree or a
/// landing commit from it, so it is resolved lazily - `lane`, `land`, `get` and `list` work from a
/// directory that is not a checkout at all.
function open(options) {
  const store = options.store || storeDir();
  const repo = () => (options.repo ? path.resolve(options.repo) : repoRoot(process.cwd()));
  return {store, repo};
}

const [verb, ...rest] = process.argv.slice(2);
const options = parse(rest);
const delivery = options.positional[0];

switch (verb) {
  case 'create': {
    if (!delivery) fail(4, 'usage', 'create needs the delivery (its branch name)');
    const {store, repo} = open(options);
    let tip = options.tip;
    if (!tip) fail(4, 'usage', 'create needs --tip <sha>: the reviewed tip is the delivery');
    tip = git(repo(), ['rev-parse', '--verify', `${tip}^{commit}`], 'tip');
    const tree = git(repo(), ['rev-parse', `${tip}^{tree}`], 'tree');
    if (!options.producer) fail(4, 'usage', 'create needs --producer <session id>: a delivery nobody produced cannot be admitted');
    const existing = readRecord(store, delivery);
    if (existing) fail(2, 'record_exists', `${recordPath(store, delivery)} already holds a record for ${delivery} (tip ${existing.tip}); update it instead of recreating it`);
    const record = {
      schema: SCHEMA,
      delivery,
      branch: delivery,
      repository: repo(),
      tip,
      tree,
      producer: options.producer,
      review: null,
      admission: null,
      lane: null,
      landing: null,
      created_at: nowIso(),
    };
    writeRecord(store, record);
    note(`${delivery}: record created in ${store} (tip ${tip.slice(0, 7)}, tree ${tree.slice(0, 8)})`);
    emit({ok: true, action: 'create', store, record}, options);
    break;
  }

  case 'review': {
    if (!delivery) fail(4, 'usage', 'review needs the delivery (its branch name)');
    const {store, repo} = open(options);
    if (!options.reviewer) fail(4, 'usage', 'review needs --reviewer <session id>: an unattributed review is not an independent one');
    if (!options.commit) fail(4, 'usage', 'review needs --commit <review-sha>: the published commit that makes the reviewer identifiable');
    if (!options.tip) fail(4, 'usage', 'review needs --tip <sha>: the exact commit the reviewer reviewed');
    const commit = git(repo(), ['rev-parse', '--verify', `${options.commit}^{commit}`], 'review commit');
    const tip = git(repo(), ['rev-parse', '--verify', `${options.tip}^{commit}`], 'reviewed tip');
    const tree = git(repo(), ['rev-parse', `${tip}^{tree}`], 'reviewed tree');
    const verdict = options.verdict || 'passed';
    if (!['passed', 'narrowed', 'refused'].includes(verdict)) {
      fail(4, 'usage', `--verdict must be passed, narrowed or refused, got '${verdict}'`);
    }
    const record = readRecord(store, delivery);
    if (!record) fail(2, 'record_missing', `no record for ${delivery} in ${store}`);
    record.review = {
      reviewer: options.reviewer,
      commit,
      tip,
      tree,
      verdict,
      findings: options.findings.map(parseFinding),
      at: options.at || nowIso(),
    };
    // A new review of a new tip is a new delivery state: any admission of the old one no longer
    // describes it, and is cleared rather than left to look current.
    record.admission = null;
    writeRecord(store, record);
    note(`${delivery}: review recorded - reviewer ${options.reviewer}, tip ${tip.slice(0, 7)}, tree ${tree.slice(0, 8)}, verdict ${verdict}, ${record.review.findings.length} finding(s)`);
    emit({ok: true, action: 'review', store, review: record.review}, options);
    break;
  }

  case 'lane': {
    if (!delivery) fail(4, 'usage', 'lane needs the delivery (its branch name)');
    const {store, repo} = open(options);
    const record = readRecord(store, delivery);
    if (!record) fail(2, 'record_missing', `no record for ${delivery} in ${store}`);
    record.lane = {
      verdict: options.verdict || 'unknown',
      exit: options.exit === undefined ? null : Number(options.exit),
      tree: options.tree || record.tree,
      report: options.report || null,
      at: options.at || nowIso(),
    };
    writeRecord(store, record);
    note(`${delivery}: merge-lane outcome recorded - ${record.lane.verdict} (exit ${record.lane.exit})`);
    emit({ok: true, action: 'lane', store, lane: record.lane}, options);
    break;
  }

  case 'land': {
    if (!delivery) fail(4, 'usage', 'land needs the delivery (its branch name)');
    const {store, repo} = open(options);
    if (!options.sha) fail(4, 'usage', 'land needs --sha <sha>: the landing commit');
    const sha = git(repo(), ['rev-parse', '--verify', `${options.sha}^{commit}`], 'landing sha');
    const record = readRecord(store, delivery);
    if (!record) fail(2, 'record_missing', `no record for ${delivery} in ${store}`);
    record.landing = {sha, at: options.at || nowIso()};
    writeRecord(store, record);
    note(`${delivery}: landed as ${sha}`);
    emit({ok: true, action: 'land', store, landing: record.landing}, options);
    break;
  }

  case 'get': {
    if (!delivery) fail(4, 'usage', 'get needs the delivery (its branch name)');
    const {store} = open(options);
    const record = readRecord(store, delivery);
    if (!record) fail(2, 'record_missing', `no record for ${delivery} in ${store}`);
    emit({ok: true, action: 'get', store, record}, options);
    break;
  }

  case 'list': {
    const {store} = open(options);
    const records = listRecords(store);
    emit({ok: true, action: 'list', store, count: records.length, deliveries: records.map(record => ({
      delivery: record.delivery, tip: record.tip, tree: record.tree, producer: record.producer,
      reviewer: record.review?.reviewer ?? null, verdict: record.review?.verdict ?? null,
      admission: record.admission?.state ?? null, lane: record.lane?.verdict ?? null,
      landing: record.landing?.sha ?? null, unreadable: record.unreadable ?? null,
    }))}, options);
    break;
  }

  default:
    fail(4, 'usage', 'verbs: create | review | lane | land | get | list');
}
