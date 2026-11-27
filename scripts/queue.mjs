#!/usr/bin/env node
// The landing queue's command line. `submit` is the door; `status`, `show`, `events` and `table` are how a
// submitter or the orchestrator reads it back. This file decides nothing about a landing - it writes and
// reads the journal (scripts/lib/queue/journal.mjs) and hands the verdict to whoever asked.
//
// Usage:
//   node scripts/queue.mjs submit <branch> <sha> <mission> [--priority] [--note <text>] [--json] [--wait <s>]
//   node scripts/queue.mjs status [--json]
//   node scripts/queue.mjs show <id> [--json]
//   node scripts/queue.mjs events [--since <id>] [--json]
//   node scripts/queue.mjs approve <branch> <sha> [--repo <dir>]   (the review lane's token decides)
//   node scripts/queue.mjs review [--json]                         (what waits on a person, and since when)
//   node scripts/queue.mjs table
//   node scripts/queue.mjs migrate --from <v0-journal.db> [--json]
//
// The journal is `$WASM_AGENT_HOME/lane/landing-queue.db` by default (`--db` overrides it). It is NOT the
// canonical checkout: the runner has its own clone (hunk 3) and the journal outlives both.
//
// Exit codes: 0 ok; 2 usage; 3 no such request; 4 the wait ran out (law 15: every wait is capped and says so).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {openJournal, submit, position, openRequests, show, events, migrateV0, transition, lastState,
        recordApproval, approvalFor, awaitingReview} from './lib/queue/journal.mjs';
import {loadPolicy, policyHash, evaluate, policyPath} from './lib/queue/policy.mjs';
import {reviewLane} from './lib/queue/lane.mjs';

function defaultDb() {
  const home = process.env.WASM_AGENT_HOME || path.join(os.homedir(), '.wasm-agent');
  return path.join(home, 'lane', 'landing-queue.db');
}

function parseArgs(argv) {
  const out = {_: [], flags: {}};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const key = a.slice(2);
    const booleans = new Set(['json', 'priority']);
    if (booleans.has(key)) { out.flags[key] = true; continue; }
    out.flags[key] = argv[i + 1];
    i += 1;
  }
  return out;
}

function say(...parts) { process.stdout.write(`${parts.join(' ')}\n`); }
function die(code, message) { process.stderr.write(`${message}\n`); process.exit(code); }

// What the request touches is the branch's business, and the queue must know it to report the branch kind
// (a compiled branch parks the tree before it lands). Read from the repo the caller names, never guessed.
function branchFacts(repo, branch, sha) {
  const git = (...args) => execFileSync('git', ['-C', repo, ...args], {encoding: 'utf8'}).trim();
  try {
    const base = git('rev-parse', 'origin/main');
    const files = git('diff', '--name-only', `${base}...${sha}`).split('\n').filter(Boolean);
    const crates = [...new Set(files.filter((f) => f.startsWith('rust/')).map((f) => f.split('/')[1]))].sort();
    const compiled = files.some((f) => /^rust\//.test(f) || f.endsWith('.wit')) ? 1 : 0;
    return {files, crates, compiled};
  } catch {
    return {files: [], crates: [], compiled: 0};
  }
}

/// The policy answer for a request's diff, and whether an approval already covers exactly this triple.
function policyFor(repoDir, files, branch, sha) {
  const file = policyPath(repoDir);
  if (!fs.existsSync(file)) return {present: false, needsReview: false, refuses: false, review: [], refused: [], hash: null};
  const policy = loadPolicy(file);
  const verdict = evaluate(policy, files);
  const hash = policyHash(file);
  const approved = approvalFor(db, {branch, sha, policyHash: hash});
  return {...verdict, present: true, hash, approved};
}

function fmtRequest(db, row) {
  const ahead = position(db, row.id);
  return `${String(row.id).padStart(4)}  prio=${row.prio}  ${row.branch}@${row.sha.slice(0, 12)}  ${row.mission || '-'}  position=${ahead}`;
}

// A WAIT IS A CAP. `--wait <s>` polls the journal's transitions by id, and when the seconds run out it says
// so with exit 4 and the state it last saw - never "still working" forever, and never a silent timeout.
function waitFor(db, req, seconds) {
  const deadline = Date.now() + seconds * 1000;
  for (;;) {
    const one = show(db, req);
    if (one && one.verdict) return one.verdict;
    if (Date.now() >= deadline) {
      const last = one && one.transitions.length ? one.transitions[one.transitions.length - 1] : null;
      die(4, `wait ${seconds}s ran out: request ${req} is ${last ? last.state : 'unknown'} (cap reached, nothing else is implied)`);
    }
    // A wait that is a value, not a promise chain: this loop runs in a plain script, and 100 ms of sleep
    // with Atomics.wait costs nothing and cannot drift into a busy spin.
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
  }
}

const argv = parseArgs(process.argv.slice(2));
const cmd = argv._[0];
if (!cmd) { process.stderr.write(fs.readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1, 20).join('\n')); process.exit(2); }
const db = openJournal(argv.flags.db || defaultDb());
const repo = argv.flags.repo || process.cwd();

try {
  if (cmd === 'submit') {
    const [, branch, want, mission = ''] = argv._;
    if (!branch || !want) die(2, 'usage: queue.mjs submit <branch> <sha> <mission> [--priority] [--note <text>] [--json] [--wait <s>]');
    let sha = want;
    try { sha = execFileSync('git', ['-C', repo, 'rev-parse', `${want}^{commit}`], {encoding: 'utf8'}).trim(); } catch { /* a full sha needs no resolution */ }
    const facts = branchFacts(repo, branch, sha);
    const kind = facts.compiled ? 'compiled' : 'plain';
    const out = submit(db, {branch, sha, mission, kind, prio: argv.flags.priority ? 1 : 0, note: argv.flags.note ?? null, ...facts});
    // THE POLICY IS DATA, APPLIED AT THE DOOR: a request whose diff touches a reviewed path stops at
    // needs_review before anything runs, unless an approval already names this exact (branch, sha, hash).
    const policy = policyFor(repo, facts.files, branch, sha);
    if (policy.refuses) die(5, `refused by policy: ${policy.refused.map((r) => r.file).join(', ')} is never a landing`);
    if (policy.needsReview && !policy.approved && lastState(db, out.id) !== 'needs_review') {
      const paths = policy.review.map((r) => `${r.file} (${r.why})`).join(', ');
      transition(db, out.id, 'needs_review', 'policy_refused', paths);
      if (!argv.flags.json) process.stdout.write(`needs_review: ${paths}\nwaiting on review since ${new Date().toISOString().replace(/\.\d+Z$/, 'Z')} — approve with the review lane's token\n`);
    }
    if (argv.flags.wait) {
      const verdict = waitFor(db, out.id, Number(argv.flags.wait));
      if (argv.flags.json) say(JSON.stringify({...out, verdict, verdictPayload: verdict.payload ? JSON.parse(verdict.payload) : null}));
      else { say(`${out.id}${out.created ? '' : ' (already queued)'} position=${out.position}`); say(`${verdict.verdict}${verdict.cause ? ` (${verdict.cause})` : ''}`); }
      process.exit(0);
    }
    if (argv.flags.json) say(JSON.stringify(out));
    else say(`${out.id}${out.created ? '' : ' (already queued)'} position=${out.position}`);
    process.exit(0);
  }

  if (cmd === 'status') {
    const rows = openRequests(db);
    if (argv.flags.json) say(JSON.stringify(rows));
    else { if (!rows.length) say('no open requests'); for (const row of rows) say(fmtRequest(db, row)); }
    process.exit(0);
  }

  if (cmd === 'show') {
    const req = Number(argv._[1]);
    const one = show(db, req);
    if (!one) die(3, `no request ${req}`);
    if (argv.flags.json) { say(JSON.stringify(one)); process.exit(0); }
    say(`#${one.request.id} ${one.request.branch}@${one.request.sha.slice(0, 12)} (${one.request.mission || '-'}) kind=${one.request.kind} prio=${one.request.prio}`);
    for (const t of one.transitions) say(`  ${t.at}  ${t.state.padEnd(13)} ${t.cause ?? ''}${t.evidence ? `  ${t.evidence}` : ''}`);
    if (one.verdict) say(`verdict: ${one.verdict.verdict}${one.verdict.cause ? ` (${one.verdict.cause})` : ''} at ${one.verdict.at}`);
    else say('verdict: - still open');
    process.exit(0);
  }

  if (cmd === 'events') {
    const rows = events(db, Number(argv.flags.since || 0));
    if (argv.flags.json) say(JSON.stringify(rows));
    else for (const e of rows) say(`${e.id}  req ${e.req}  ${e.at}  ${e.state}${e.cause ? `  ${e.cause}` : ''}`);
    process.exit(0);
  }

  if (cmd === 'approve') {
    const [, branch, want] = argv._;
    if (!branch || !want) die(2, 'usage: queue.mjs approve <branch> <sha> [--repo <dir>]');
    const lane = reviewLane();
    if (!lane.ok) die(6, `approve refused: ${lane.why}`);
    let sha = want;
    try { sha = execFileSync('git', ['-C', repo, 'rev-parse', `${want}^{commit}`], {encoding: 'utf8'}).trim(); } catch { /* full sha */ }
    const row = db.prepare('SELECT * FROM requests WHERE branch = ? AND sha = ?').get(branch, sha);
    if (!row) die(3, `no request for ${branch}@${sha.slice(0, 12)}`);
    const facts = {files: row.files ? row.files.split(' ') : []};
    const policy = policyFor(repo, facts.files, branch, sha);
    if (!policy.present) die(3, `no ${policyPath(repo)} in this tree, so there is nothing to approve against`);
    if (!policy.needsReview) die(3, `${branch}@${sha.slice(0, 12)} touches no reviewed path under this policy - nothing to approve`);
    const approved = recordApproval(db, {branch, sha, policyHash: policy.hash, by: lane.by});
    if (lastState(db, row.id) === 'needs_review') transition(db, row.id, 'queued', `approved by ${lane.by}`, policy.hash);
    if (argv.flags.json) say(JSON.stringify({...approved, policyHash: policy.hash, by: lane.by}));
    else say(`${approved.created ? 'approved' : 'already approved'} ${branch}@${sha.slice(0, 12)} policy=${policy.hash.slice(0, 12)} by ${lane.by}`);
    process.exit(0);
  }

  if (cmd === 'review') {
    const rows = awaitingReview(db);
    if (argv.flags.json) say(JSON.stringify(rows));
    else if (!rows.length) say('nothing waiting on review');
    else for (const row of rows) say(`${String(row.id).padStart(4)}  ${row.branch}@${row.sha.slice(0, 12)}  ${row.mission || '-'}  waiting on review since ${row.submitted_at}`);
    process.exit(0);
  }

  if (cmd === 'table') {
    const rows = db.prepare(`SELECT r.id, r.branch, r.mission, r.kind, r.prio, r.submitted_at,
        (SELECT at FROM verdicts v WHERE v.req = r.id) AS verdict_at,
        (SELECT verdict FROM verdicts v WHERE v.req = r.id) AS verdict,
        (SELECT cause FROM verdicts v WHERE v.req = r.id) AS cause
      FROM requests r ORDER BY r.id`).all();
    say('id\tbranch\tmission\tkind\tprio\tsubmitted\tverdict\tcause\tminutes');
    for (const r of rows) {
      const minutes = r.verdict_at ? Math.round((Date.parse(r.verdict_at) - Date.parse(r.submitted_at)) / 60000 * 10) / 10 : '';
      say([r.id, r.branch, r.mission || '-', r.kind, r.prio, r.submitted_at, r.verdict || 'open', r.cause || '', minutes].join('\t'));
    }
    const s = db.prepare(`SELECT COUNT(*) AS n,
        SUM(CASE WHEN (SELECT verdict FROM verdicts v WHERE v.req = r.id) = 'landed' THEN 1 ELSE 0 END) AS landed,
        SUM(CASE WHEN (SELECT verdict FROM verdicts v WHERE v.req = r.id) = 'rejected' THEN 1 ELSE 0 END) AS rejected
      FROM requests r`).get();
    say(`requests ${s.n} | landed ${s.landed ?? 0} | rejected ${s.rejected ?? 0} | open ${s.n - (s.landed ?? 0) - (s.rejected ?? 0)}`);
    process.exit(0);
  }

  if (cmd === 'migrate') {
    const from = argv.flags.from;
    if (!from) die(2, 'usage: queue.mjs migrate --from <v0-journal.db>');
    const out = migrateV0(db, from);
    if (argv.flags.json) say(JSON.stringify(out));
    else say(`migrated ${out.requests} request(s), ${out.transitions} transition(s), ${out.verdicts} verdict(s); ${out.skipped} already present`);
    process.exit(0);
  }

  die(2, `unknown command ${cmd}`);
} finally {
  db.close();
}
