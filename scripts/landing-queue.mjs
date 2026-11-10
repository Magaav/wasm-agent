#!/usr/bin/env node
// The landing queue's command line: who may land on the canonical checkout, in what order, from what
// evidence a dead holder is reclaimed, whether the canonical tree is dirty and owned by nobody, and
// whether an upstream move forces a retest. The mechanics live in scripts/lib/landing-queue.mjs; the
// procedure this wraps is skills/git-orchestrator/SKILL.md, "3. Push under the sole lock".
//
// Usage:
//   node scripts/landing-queue.mjs status [--repo <dir>] [--json]
//   node scripts/landing-queue.mjs acquire --branch <name> [--owner <session id>] [--no-wait]
//                                          [--wait-timeout <s>] [--lease-seconds <s>] [--repo <dir>]
//   node scripts/landing-queue.mjs record --tree <ref> [--command "<what ran>"] [--owner <id>]
//   node scripts/landing-queue.mjs land --branch <name> [--checks "<cmd>"] [--dry-run] [--no-push]
//                                       [--owner <session id>] [--lease-seconds <s>] [--repo <dir>]
//   node scripts/landing-queue.mjs release --id <n> [--result landed|abandoned] [--evidence <text>]
//   node scripts/landing-queue.mjs reconcile --id <n> --evidence <text> [--force]
//   node scripts/landing-queue.mjs classify --from <rev> --to <rev> [--repo <dir>] [--json]
//   node scripts/landing-queue.mjs baseline [--command "<cmd>"] [--commit <rev>] [--record <log>] [--exit-code <n>]
//                                          [--source <label>] [--repo <dir>] [--json]
//   node scripts/landing-queue.mjs history [--limit <n>] [--json] [--repo <dir>]
//
// Exit codes: 0 the command's own success; 75 refused (named, terminal - a refusal is never retried
// by itself); 76 the queue or the repository could not answer.
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {
  QueueError, classifyDelta, treeDigest, candidateTree, canonicalDirt, describeDirt, git, gitOk,
  mainWorktree, openQueue, queueDir, logRow, resolveOwner, holderOf, reclaimPass, grantNext,
  queuePosition, waitingRows, heartbeat, resolveCommit, bootId, hostName, proofOf, recordProof,
  baselineOf, recordBaseline, checkCommandKey,
} from './lib/landing-queue.mjs';
import {parseCheckLog, baselineRecord, judgeRun, describeRun} from './lib/landing-baseline.mjs';
import {holdLease, releaseLease} from './lib/sqlite-lease.mjs';

const now = () => Math.floor(Date.now() / 1000);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const say = line => console.log(`landing-queue: ${line}`);

function parseArgs(argv) {
  const options = {json: false};
  const flags = new Set(['--json', '--no-wait', '--dry-run', '--no-push', '--force']);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) throw new QueueError(`unexpected argument '${arg}'`, 75, 'usage');
    if (flags.has(arg)) { options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = true; continue; }
    const value = argv[++i];
    if (value === undefined) throw new QueueError(`${arg} needs a value`, 75, 'usage');
    options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
  }
  return options;
}

function emit(value, options, human) {
  if (options.json) process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  else if (human) say(human);
  return value;
}

function open(options) {
  const repo = path.resolve(options.repo || process.cwd());
  const canonical = mainWorktree(repo);
  const dir = queueDir(repo, options.dir);
  return {repo, canonical, dir, db: openQueue(dir)};
}

const age = seconds => (seconds === null || seconds === undefined ? 'now' : `${Math.max(0, now() - seconds)}s`);

// ---- the release a landed commit needs ----------------------------------------------------------
//
// A landing is the moment a commit becomes installable, so it is the moment the prebuilt binary for
// it must exist: `scripts/deploy.sh` installs a published release when the commit's compiled inputs
// are covered, and compiles on the node only when there is none. Measured 2026-11-10: neither of
// that day's two landings published anything, and the aarch64 release for 1d23cbed had to be made by
// hand afterwards - so a remote update of openclaw would have fallen back to a build on the node it
// was replacing, which is the path this project does not want.
//
// `--ensure` is what makes this affordable: a commit whose compiled inputs are already covered (every
// Lua-only, docs-only or test-only landing) answers in seconds and builds nothing. A Rust landing
// pays one build here instead of on each node.
//
// It can never fail the landing: the merge is already pushed and read back, and a failed publish is a
// fact about the release, not about main. The outcome - published, covered by an earlier release, or
// why not - is recorded in the queue row and printed, and the publisher's own log is kept beside the
// queue so an operator can read what happened without re-running it.
const RELEASE_TARGET = 'aarch64-unknown-linux-gnu';
const RELEASE_TIMEOUT_MS = 45 * 60 * 1000;

const lastLine = text => String(text || '').trim().split(/\r?\n/).filter(Boolean).slice(-1)[0] || '';

function publishNodeRelease(canonical, commit, dir) {
  const started = Date.now();
  const run = spawnSync('bash', ['scripts/publish-node-binaries.sh', '--ensure', '--publish',
    '--target', RELEASE_TARGET, '--commit', commit],
  {cwd: canonical, encoding: 'utf8', timeout: RELEASE_TIMEOUT_MS, env: process.env});
  const output = `${run.stdout || ''}${run.stderr || ''}`.trim();
  const seconds = Math.round((Date.now() - started) / 1000);
  const log = path.join(dir, `release-${commit.slice(0, 12)}.log`);
  try { fs.writeFileSync(log, `${output}\n`, 'utf8'); } catch { /* the row still carries the reason */ }
  if (run.error && run.error.code === 'ETIMEDOUT') {
    return {state: 'failed', target: RELEASE_TARGET, seconds, detail: `the publisher did not finish within ${RELEASE_TIMEOUT_MS / 60000} min`, log};
  }
  if (run.status !== 0) {
    return {state: 'failed', target: RELEASE_TARGET, seconds, detail: lastLine(output) || `the publisher exited ${run.status}`, log};
  }
  const covered = /covered: \S+ covers the compiled inputs/.test(output);
  const tag = (output.match(/publish-node-binaries ok: (\S+)/) || [])[1]
    || (output.match(/covered: (\S+) covers/) || [])[1] || '';
  return {
    state: covered ? 'covered' : 'published', tag, target: RELEASE_TARGET, seconds, log,
    detail: lastLine(output) || (covered ? `covered by ${tag}` : `published ${tag}`),
  };
}

// ---- status -------------------------------------------------------------------------------------
function commandStatus(options) {
  const {canonical, dir, db} = open(options);
  const reclaimed = reclaimPass(db, dir);
  const holder = holderOf(db, dir);
  const waiting = waitingRows(db);
  const dirt = canonicalDirt(canonical);
  const state = {
    canonical,
    queue_dir: dir,
    holder: holder && {
      id: holder.id, owner: holder.owner, owner_source: holder.owner_source, branch: holder.branch,
      started_at: holder.started_at, held_seconds: now() - holder.started_at,
      heartbeat_seconds_ago: now() - (holder.heartbeat_at || holder.started_at),
      expires_in: Math.max(0, (holder.expires_at || 0) - now()), lease_held: holder.lease_held,
      pid: holder.pid, reason: holder.reason || '',
    },
    waiting: waiting.map((row, index) => ({
      position: index + 1, id: row.id, owner: row.owner, branch: row.branch, waiting_seconds: now() - row.created_at,
    })),
    reclaimed,
    canonical_dirt: {dirty: dirt.dirty, count: dirt.count, files: dirt.files},
    verdict: holder ? 'busy' : 'free',
  };
  if (options.json) return emit(state, options);
  const lines = [];
  lines.push(holder
    ? `holder #${holder.id} ${holder.owner} (${holder.owner_source}) on ${holder.branch}, held ${age(holder.started_at)}${holder.lease_held ? '' : ' [LEASE NOT HELD - reclaimable]'}, expires in ${Math.max(0, (holder.expires_at || 0) - now())}s`
    : 'free: nobody holds the canonical checkout');
  if (waiting.length) {
    lines.push(`waiting ${waiting.length}: ` + waiting.map((row, i) => `#${i + 1} #${row.id} ${row.owner} (${row.branch}, ${age(row.created_at)})`).join(', '));
  }
  lines.push(dirt.dirty
    ? `canonical ${canonical}: DIRTY ${dirt.count} file(s) - ${describeDirt(dirt)}${holder ? ' (the holder is landing, so this may be its merge)' : ' - belongs to nobody holding the lease; a landing is refused until it is clean'}`
    : `canonical ${canonical}: clean`);
  for (const entry of reclaimed) lines.push(`reclaimed #${entry.id} (${entry.owner}): ${entry.reason}`);
  say(lines.join('\nlanding-queue: '));
  return state;
}

// ---- acquire ------------------------------------------------------------------------------------
//
// Enqueues, waits, and then STAYS ALIVE holding the lease until the row ends - the same shape as
// `gate-lane.mjs acquire`, and for the same reason: the lease is the proof of life, so the process
// that owns the claim must be the process that lives through it. A caller that keeps its own runner
// backgrounds this command, does its work, and ends the claim with `release --id <n>`; `land` does
// the same thing in one process instead.
async function commandAcquire(options) {
  const {repo, dir, db} = open(options);
  const {id, lease, row} = await enqueueAndWait(options);
  if (!row) return {granted: false, exit: 75};
  if (options.noHold) return {id, lease, granted: true, row};
  say(`#${id} holding the lease in pid ${process.pid}; end it with \`release --id ${id}\`${options.waitSeconds ? ` (or it ends after ${options.waitSeconds}s)` : ''}`);
  const deadline = options.waitSeconds ? now() + Number(options.waitSeconds) : null;
  for (;;) {
    const current = db.prepare('SELECT state,reason FROM queue WHERE id=?').get(id);
    if (current.state !== 'granted') {
      releaseLease(lease);
      say(`#${id} ended (${current.state}): ${current.reason || ''}`);
      return {id, granted: true, state: current.state};
    }
    if (deadline && now() > deadline) {
      db.prepare("UPDATE queue SET state='abandoned', reason=?, ended_at=? WHERE id=?").run(`acquire released after ${options.waitSeconds}s without a landing`, now(), id);
      logRow(db, id, 'abandoned', `acquire released after ${options.waitSeconds}s without a landing`);
      releaseLease(lease);
      say(`#${id} released after ${options.waitSeconds}s without a landing`);
      return {id, granted: true, state: 'abandoned'};
    }
    await sleep(500);
  }
}

// One place that turns "I want to land" into a row and a held lease, used by both `acquire` and
// `land`. It refuses a dirty tree that belongs to nobody BEFORE queueing (a lander that waits ten
// minutes to be told its destination is dirty has been charged the wait for nothing - the measured
// cost of the same class: ~25 minutes of canonical edits blocked a deploy for ~7).
async function enqueueAndWait(options) {
  if (!options.branch) throw new QueueError('this command needs --branch <name>', 75, 'usage');
  const {repo, canonical, dir, db} = open(options);
  const owner = resolveOwner(options);
  const branch = options.branch;
  const holderBefore = holderOf(db, dir);
  const dirt = canonicalDirt(canonical);
  if (!holderBefore && dirt.dirty) {
    throw new QueueError(
      `dirty_canonical: ${canonical} has ${dirt.count} uncommitted change(s) and nobody holds the landing lease: ${describeDirt(dirt)}.\n`
      + '  The canonical checkout is not an editor: work in your own worktree (a change/<name> branch),'
      + ' commit and push it, and let the landing queue merge it. Whoever these edits belong to must'
      + ' commit them on a branch or revert them before any landing can start.', 75, 'dirty_canonical');
  }
  const base = resolveCommit(repo, 'origin/main');
  if (!base) throw new QueueError(`origin/main is not resolvable in ${repo}; fetch first`, 75, 'no_base');
  const lease = crypto.randomUUID();
  db.prepare(`INSERT INTO queue(owner,owner_source,owner_evidence,branch,worktree,canonical,state,lease,pid,host,boot,base,created_at,lease_seconds)
              VALUES(?,?,?,?,?,?,'waiting',?,?,?,?,?,?,?)`)
    .run(owner.id, owner.source, JSON.stringify(owner.evidence), branch, path.resolve(options.repo || process.cwd()),
      canonical, lease, process.pid, hostName(), bootId(), base, now(), Number(options.leaseSeconds || 1800));
  const id = Number(db.prepare('SELECT last_insert_rowid() AS id').get().id);
  logRow(db, id, 'enqueued', `${owner.id} (${owner.source}) branch ${branch} on ${canonical}, base ${base.slice(0, 12)}`);
  say(`#${id} enqueued for ${owner.id} (${owner.source}): branch ${branch}, base ${base.slice(0, 12)}`);

  if (options.noWait) {
    const position = queuePosition(db, id);
    const holder = holderOf(db, dir);
    db.prepare("UPDATE queue SET state='refused', reason=?, ended_at=? WHERE id=?").run('no-wait: refused without waiting', now(), id);
    logRow(db, id, 'refused', `no-wait; position ${position}, holder ${holder ? `#${holder.id} ${holder.owner}` : 'none'}`);
    emit({id, granted: false, position, holder: holder && {id: holder.id, owner: holder.owner, branch: holder.branch}}, options,
      `#${id} NOT granted (--no-wait): position ${position}, ${holder ? `holder #${holder.id} ${holder.owner} on ${holder.branch}` : 'no holder'}`);
    return {id, granted: false, position, exit: 75};
  }
  const granted = await waitForLease({db, dir, id, lease, options});
  if (!granted.granted) return granted;
  return {id, lease, granted: true, row: db.prepare('SELECT * FROM queue WHERE id=?').get(id)};
}

async function waitForLease({db, dir, id, lease, options}) {
  const deadline = options.waitTimeout ? now() + Number(options.waitTimeout) : null;
  let announced = -1;
  for (;;) {
    const granted = grantNext(db, dir);
    const row = db.prepare('SELECT * FROM queue WHERE id=?').get(id);
    if (row.state !== 'waiting') break;
    const position = queuePosition(db, id);
    const holder = holderOf(db, dir);
    if (granted && granted.id === id) break;
    if (position !== announced) {
      announced = position;
      say(`#${id} waiting: position ${position} of ${waitingRows(db).length + 1}; holder ${holder ? `#${holder.id} ${holder.owner} on ${holder.branch} for ${age(holder.started_at)}` : 'none'}`);
    }
    if (deadline && now() > deadline) {
      db.prepare("UPDATE queue SET state='refused', reason=?, ended_at=? WHERE id=?")
        .run(`waited ${options.waitTimeout}s without the lease`, now(), id);
      logRow(db, id, 'refused', `timeout after ${options.waitTimeout}s; position ${position}`);
      throw new QueueError(`wait_timeout: #${id} waited ${options.waitTimeout}s; position ${position}, holder ${holder ? `#${holder.id} ${holder.owner}` : 'none'}; nothing was landed`, 75, 'wait_timeout');
    }
    await sleep(400);
  }
  // The lease was granted to this row: take the OS lock BEFORE saying so, so the proof of life
  // precedes the claim and a process killed right here leaves a free tree, not a stuck one.
  holdLease(dir, lease);
  db.prepare('UPDATE queue SET pid=?, host=?, boot=? WHERE id=?').run(process.pid, hostName(), bootId(), id);
  const row = db.prepare('SELECT * FROM queue WHERE id=?').get(id);
  const waited = now() - row.created_at;
  const behind = waitingRows(db).filter(other => other.id !== id).length;
  logRow(db, id, 'granted', `after waiting ${waited}s; ${behind} still waiting; expires in ${row.expires_at - now()}s`);
  say(`#${id} GRANTED to ${row.owner} on ${row.branch} after waiting ${waited}s (base ${row.base.slice(0, 12)}, lease ${lease.slice(0, 8)}, expires in ${row.expires_at - now()}s); ${behind} waiting`);
  return {id, lease, dir, granted: true, row, waited};
}

// ---- record -------------------------------------------------------------------------------------
//
// A producer runs its focused checks in its own worktree and records what they proved, keyed by the
// retest digest of the tree they ran on. Any later landing whose candidate has the same
// test-relevant inputs reuses that record instead of re-running - which is what makes a docs-only
// upstream move free, and why a branch that lands on a moved main does not pay for its suite twice.
function commandRecord(options) {
  const {repo, db} = open(options);
  const owner = resolveOwner(options);
  const requested = options.tree || options.branch;
  if (!requested) throw new QueueError('record needs --tree <ref> (the tree your checks ran on)', 75, 'usage');
  const tree = resolveCommit(repo, requested);
  if (!tree) throw new QueueError(`record: cannot resolve ${requested} in ${repo}`, 75, 'record_tree_unknown');
  const digest = treeDigest(repo, tree);
  recordProof(db, {digest: digest.retest, tree, by: owner.id, command: options.command || 'recorded by the producer', log: options.log || ''});
  logRow(db, 0, 'recorded', `${owner.id} recorded a proof for tree ${tree.slice(0, 12)} (retest digest ${digest.retest.slice(0, 12)}, ${digest.retest_inputs} test inputs)`);
  return emit({tree, digest: digest.retest, inputs: digest.retest_inputs, compiled: digest.compiled}, options,
    `recorded a proof for ${requested} (${tree.slice(0, 12)}): retest digest ${digest.retest.slice(0, 12)} over ${digest.retest_inputs} test inputs`);
}

// `release` ends a claim the caller owns. Ownership is the harness session that enqueued the row,
// proven the same way as everywhere else, or the very process that holds the lock: an external runner
// that backgrounded `acquire` releases as its session, and nothing else can release its claim. A row
// claimed by another session is ended by a person with `reconcile --evidence`, which logs why.
function ownedRow(db, options) {
  if (!options.id) throw new QueueError('this command needs --id <n> (the row acquire printed)', 75, 'usage');
  const row = db.prepare('SELECT * FROM queue WHERE id=?').get(Number(options.id));
  if (!row) throw new QueueError(`no queue row #${options.id}`, 75, 'queue_row_missing');
  const owner = resolveOwner(options);
  if (row.pid !== process.pid && row.owner !== owner.id) {
    throw new QueueError(`not_your_lease: #${row.id} belongs to ${row.owner} (pid ${row.pid}); ${owner.id} cannot release it. A person ends another session's claim with \`reconcile --id ${row.id} --evidence <text>\``, 75, 'not_your_lease');
  }
  if (row.state !== 'granted') throw new QueueError(`#${row.id} is ${row.state}, not granted: ${row.reason || ''}`, 75, 'not_granted');
  return row;
}

// ---- classify -----------------------------------------------------------------------------------
function commandClassify(options) {
  if (!options.from || !options.to) throw new QueueError('classify needs --from <rev> --to <rev>', 75, 'usage');
  const repo = path.resolve(options.repo || process.cwd());
  const delta = classifyDelta(repo, options.from, options.to);
  if (options.json) return emit(delta, options);
  say(`${delta.from.slice(0, 12)}..${delta.to.slice(0, 12)}: ${delta.commits} commit(s), ${delta.paths.length} path(s): ${delta.retest.why}`);
  say(`retest ${delta.retest.required ? 'REQUIRED' : 'not required'} (branch suite ${delta.retest.branch_suite ? 'rerun' : 'skipped'}, baseline ${delta.retest.baseline ? 'rerun' : 'skipped'}); compiled inputs ${delta.compiled_moved ? 'changed' : 'unchanged'} (${delta.digest.before_compiled.slice(0, 12)} -> ${delta.digest.after_compiled.slice(0, 12)})`);
  for (const entry of delta.paths.slice(0, 25)) {
    say(`  ${entry.status} ${entry.path} [${entry.class}${entry.test_relevant ? ', can change a check' : ', documentation only'}]`);
  }
  if (delta.paths.length > 25) say(`  ... +${delta.paths.length - 25} more`);
  return delta;
}

// ---- running the checks, and what the tree already fails -----------------------------------------
//
// A landing's checks are judged against the known-failures baseline of the main it lands on
// (scripts/lib/landing-baseline.mjs), not against zero: on wasm_the_first, main itself fails twelve
// Lua checks because the installed node's component set is behind the tree, so "zero failures" is a
// condition no correct branch can reach, and demanding it made five sessions improvise their own
// judge. What a landing must prove is that it is not WORSE than main:
//
//   * no failing check that main does not already fail (a new name, or a passing one now failing);
//   * no more failing checks than main, and no section (rust, prompt-docs, ...) that main passed;
//   * an environment-only failure (`cannot fork`, exit 125/126 - scripts/lib/fast-environment.sh) is
//     never a verdict on the code: it is retried once, serially, and only then named as blocked.
//
// The baseline is recorded per (check command, machine, retest digest of main's tree) and reused, so
// a landing pays for a pristine run only when no measurement exists for that tree - and a landing
// that succeeded records the measurement it just made of the merged tree as the baseline for the new
// main, so the next landing on it pays nothing at all.

function captureCommand({cwd, command, log, env = process.env, echo = true}) {
  return new Promise(resolve => {
    const child = spawn(command, {shell: true, cwd, env});
    let output = '';
    const take = chunk => { const text = chunk.toString(); output += text; if (echo) process.stdout.write(text); };
    child.stdout.on('data', take);
    child.stderr.on('data', take);
    child.on('error', error => {
      try { fs.writeFileSync(log, `${output}\n${error.message}\n`, 'utf8'); } catch { /* the row carries it */ }
      resolve({code: 127, output: `${output}\n${error.message}`, log, error: String(error.message)});
    });
    child.on('close', code => {
      try { fs.writeFileSync(log, output, 'utf8'); } catch { /* the row carries it */ }
      resolve({code: code === null ? 126 : code, output, log});
    });
  });
}

// The same host binary the rest of this machine uses, handed to a pristine tree as WA_BIN only when it
// cannot be found on PATH: a fresh `git worktree` has no `rust/target`, so a baseline run there would
// otherwise answer "no wa binary" and be recorded as a tree with no checks at all. PATH wins when it
// has one, because that is the binary `scripts/fast.sh` itself would pick, and a baseline measured with
// a different build than the candidate is not a comparison.
function checksEnvironment(canonical, extra = {}) {
  const env = {...process.env, ...extra};
  if (env.WA_BIN) return env;
  const dirs = String(process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const onPath = dirs.flatMap(dir => [path.join(dir, 'wa.exe'), path.join(dir, 'wa')])
    .find(candidate => { try { return fs.statSync(candidate).isFile(); } catch { return false; } });
  if (onPath) return env;
  for (const candidate of [path.join(canonical, 'rust', 'target', 'release', 'wa.exe'),
    path.join(canonical, 'rust', 'target', 'release', 'wa'),
    path.join(os.homedir(), '.local', 'bin', 'wa')]) {
    if (fs.existsSync(candidate)) { env.WA_BIN = candidate; break; }
  }
  return env;
}

function judgedRun(captured, what) {
  const run = parseCheckLog(captured.output, {exitCode: captured.code});
  return {run, what, log: captured.log, code: captured.code};
}

// The baseline for the main this landing starts from: the recorded one when the tree's check inputs
// are unchanged, otherwise ONE measurement of that commit in the CANONICAL CHECKOUT, recorded so no
// later landing on the same inputs pays for it again.
//
// Why the canonical checkout and not a fresh `git worktree`: measured here on 2026-11-10 (row #27),
// the same commit checked out in a throw-away worktree failed a DIFFERENT set of checks than the same
// commit in the canonical directory (in the worktree: test-binding-runtime, test-capability-inventory,
// test-changes-roundtrip, test-cli-bash-restart; in the canonical checkout: the graph/codemode/features
// set the installed component set produces). The difference is state the worktree does not have and
// the directory does, and a baseline not measured where the candidate runs refuses correct branches.
// So the baseline is main's own commit, detached, in the canonical checkout, under the lease; the tree
// is put back on `main` before anything else happens. A record whose `source` is `pristine` (the older
// worktree measurement) is never reused: it is not the same environment.
async function ensureBaseline({id, canonical, upstream, command, dir, db, say}) {
  const digest = treeDigest(canonical, upstream).retest;
  const cached = baselineOf(db, {digest, command});
  if (cached && cached.source !== 'pristine') {
    say(`#${id} baseline reused: ${(cached.names || []).length} known failure(s) recorded for main's check inputs ${digest.slice(0, 12)} by ${cached.recorded_by || 'an earlier landing'} (${cached.source || 'recorded'}), measured on ${String(cached.commit || '').slice(0, 12)}; no extra run`);
    return cached;
  }
  say(`#${id} no usable baseline for main ${upstream.slice(0, 12)} with \`${checkCommandKey(command)}\` (check inputs ${digest.slice(0, 12)}); measuring it once, in this checkout`);
  const checkout = git(canonical, ['checkout', '--quiet', '--detach', upstream]);
  if (checkout.status !== 0) {
    throw new QueueError(`baseline_unavailable: cannot put ${canonical} at ${upstream.slice(0, 12)} to measure the baseline: ${String(checkout.stderr || checkout.stdout || '').trim().split('\n').slice(-2).join(' | ')}. Nothing was merged or pushed.`,
      75, 'baseline_unavailable');
  }
  let captured;
  try {
    captured = await captureCommand({
      cwd: canonical, command, env: checksEnvironment(canonical), echo: false,
      log: path.join(dir, `baseline-${upstream.slice(0, 12)}.log`),
    });
  } finally {
    const back = git(canonical, ['checkout', '--quiet', 'main']);
    if (back.status !== 0) {
      throw new QueueError(`baseline_checkout_stuck: measured the baseline but could not put ${canonical} back on main: ${String(back.stderr || back.stdout || '').trim().split('\n').slice(-2).join(' | ')}. Nothing was merged or pushed; the checkout is at ${upstream.slice(0, 12)}, detached, and a person must put it back on main.`,
        76, 'baseline_checkout_stuck');
    }
  }
  const run = parseCheckLog(captured.output, {exitCode: captured.code});
  if (!run.named && !run.ok) {
    throw new QueueError(`baseline_unavailable: '${checkCommandKey(command)}' exited ${captured.code} on ${upstream.slice(0, 12)} without naming a failing test, so a by-name comparison would be a guess. Run a check command that prints \`FAIL <section> <name> (exit N)\` lines (scripts/fast.sh does). Nothing was merged or pushed.`,
      75, 'baseline_unavailable');
  }
  const record = baselineRecord({run, command: checkCommandKey(command), commit: upstream, digest, host: hostName(), source: 'canonical'});
  recordBaseline(db, {digest, command, commit: upstream, record, by: 'queue'});
  logRow(db, 0, 'baseline', `measured on ${upstream.slice(0, 12)} in ${canonical} (check inputs ${digest.slice(0, 12)}) with '${checkCommandKey(command)}': ${record.names.length} known failure(s), exit ${captured.code}`);
  say(`#${id} baseline measured on ${upstream.slice(0, 12)}: ${record.names.length} known failure(s)${record.names.length ? ` (${record.names.slice(0, 4).join(', ')}${record.names.length > 4 ? ', ...' : ''})` : ''}; recorded for check inputs ${digest.slice(0, 12)}`);
  return record;
}

// ---- land ---------------------------------------------------------------------------------------
async function commandLand(options) {
  if (!options.branch) throw new QueueError('land needs --branch <name>', 75, 'usage');
  const {repo, canonical, dir, db} = open(options);
  const owner = resolveOwner(options);
  const acquired = await enqueueAndWait(options);
  if (!acquired.granted) return acquired;
  const id = acquired.id;
  const lease = acquired.lease;
  let released = false;
  const finish = (state, reason, extra = {}) => {
    if (released) return;
    released = true;
    const row = db.prepare('SELECT * FROM queue WHERE id=?').get(id);
    db.prepare('UPDATE queue SET state=?, reason=?, ended_at=?, result=? WHERE id=?').run(state, reason, now(), extra.result || '', id);
    logRow(db, id, state, reason);
    releaseLease(lease);
    const next = waitingRows(db)[0];
    say(`#${id} ${state}: ${reason}${next ? `; next is #${next.id} ${next.owner} (${next.branch}, waiting ${age(next.created_at)})` : '; nobody waiting'}`);
  };
  try {
    // 1. The destination must be ours and at the baseline. A dirty canonical tree here is a refusal
    //    too: the merge has to start from a tree that is exactly origin/main.
    const dirt = canonicalDirt(canonical);
    if (dirt.dirty) {
      finish('refused', `dirty_canonical: ${dirt.count} uncommitted change(s) in ${canonical}: ${describeDirt(dirt)}`);
      throw new QueueError(`dirty_canonical: ${canonical} has ${dirt.count} uncommitted change(s) while holding the lease: ${describeDirt(dirt)}. A landing merges into a clean tree; nothing was merged or pushed.`, 75, 'dirty_canonical');
    }
    const branchRef = gitOk(canonical, ['symbolic-ref', '--short', '-q', 'HEAD']).trim();
    if (branchRef !== 'main') {
      finish('refused', `canonical_not_on_main: HEAD is ${branchRef || 'detached'}`);
      throw new QueueError(`canonical_not_on_main: ${canonical} has HEAD on '${branchRef || 'detached'}'; the canonical checkout must be on main`, 75, 'canonical_not_on_main');
    }
    const fetch = git(canonical, ['fetch', 'origin', '--prune']);
    if (fetch.status !== 0) say(`#${id} warning: git fetch failed (${String(fetch.stderr || '').trim().split('\n').pop()}); classifying against the last known origin/main`);
    let upstream = resolveCommit(canonical, 'origin/main');
    let headAt = resolveCommit(canonical, 'HEAD');
    if (headAt !== upstream) {
      // Another node, or another session's landing, moved main while this row waited. Catching the
      // canonical checkout up is a fast-forward of the same commit - it publishes nothing and merges
      // nothing, so the lander does it under its own lease. A checkout that has diverged is a person's
      // problem and is named as one.
      const ancestor = git(canonical, ['merge-base', '--is-ancestor', headAt, upstream]);
      if (ancestor.status !== 0) {
        finish('refused', `canonical_diverged: HEAD ${headAt.slice(0, 12)} and origin/main ${upstream.slice(0, 12)} have diverged`);
        throw new QueueError(`canonical_diverged: ${canonical} is at ${headAt.slice(0, 12)} and origin/main is ${upstream.slice(0, 12)}, and neither contains the other; reconcile the canonical checkout by hand (nothing was merged or pushed)`, 75, 'canonical_diverged');
      }
      const ff = git(canonical, ['merge', '--ff-only', upstream]);
      if (ff.status !== 0) {
        finish('refused', `canonical_update_failed: ${String(ff.stderr || '').trim().split(String.fromCharCode(10)).slice(-2).join(' | ')}`);
        throw new QueueError(`canonical_update_failed: cannot fast-forward ${canonical} to origin/main ${upstream.slice(0, 12)}: ${String(ff.stderr || '').trim().split(String.fromCharCode(10)).slice(-2).join(' | ')}`, 75, 'canonical_update_failed');
      }
      say(`#${id} canonical fast-forwarded ${headAt.slice(0, 12)}..${upstream.slice(0, 12)} to origin/main (another lander moved it while this row waited)`);
      headAt = resolveCommit(canonical, 'HEAD');
    }

    // 2. What moved upstream while this row waited, and does it force a rerun? The digest decides;
    //    the classification explains it.
    const row = heartbeat(db, id, lease);
    const delta = classifyDelta(canonical, row.base, upstream);
    const tree = candidateTree(canonical, upstream, options.branch);
    if (tree && typeof tree === 'object' && tree.conflict) {
      finish('refused', `conflict: ${options.branch} does not merge onto ${upstream.slice(0, 12)}: ${tree.detail}`);
      throw new QueueError(`merge_conflict: ${options.branch} does not merge cleanly onto origin/main ${upstream.slice(0, 12)} (named blocked input; the queue never resolves a conflict): ${tree.detail}`, 75, 'merge_conflict');
    }
    const digest = treeDigest(canonical, tree);
    const baselineDigest = treeDigest(canonical, upstream);
    const proof = proofOf(db, digest.retest);
    const rerun = !proof;
    const baselineRerun = digest.retest !== baselineDigest.retest && !proofOf(db, baselineDigest.retest);
    if (delta.paths.length === 0) {
      say(`#${id} upstream did not move (${upstream.slice(0, 12)}); ${proof ? `candidate tree ${tree.slice(0, 12)} already proven ${age(proof.verified_at)} ago by ${proof.verified_by}` : 'no proof recorded for this candidate'}`);
    } else {
      say(`#${id} upstream moved ${row.base.slice(0, 12)}..${upstream.slice(0, 12)}: ${delta.retest.why}`
        + ` -> ${rerun ? `RETEST REQUIRED (candidate retest digest ${digest.retest.slice(0, 12)} has no proof)` : `retest skipped (candidate retest digest ${digest.retest.slice(0, 12)} already proven by ${proof.verified_by} ${age(proof.verified_at)} ago, ${proof.command})`}`
        + `; baseline ${baselineRerun ? 'rerun' : 'skipped'}`);
      if (rerun && delta.test_relevant_paths.length) {
        for (const moved of delta.test_relevant_paths.slice(0, 8)) say(`#${id}   changed test input: ${moved}`);
        if (delta.test_relevant_paths.length > 8) say(`#${id}   ... +${delta.test_relevant_paths.length - 8} more`);
      }
    }
    db.prepare('UPDATE queue SET delta=?, candidate_tree=?, rerun=?, verified_digest=? WHERE id=?')
      .run(JSON.stringify({counts: delta.counts, retest: delta.retest, commits: delta.commits, paths: delta.paths.length}), tree, rerun ? 1 : 0, digest.retest, id);

    if (rerun && !options.checks) {
      // The reason a retest is required is the candidate's own digest having no proof, and the reason
      // it lost the proof it had is the delta - both are named, because they are different facts.
      const because = delta.paths.length === 0
        ? `candidate retest digest ${digest.retest.slice(0, 12)} has no proof in this queue`
        : delta.retest.why;
      finish('refused', `retest_required: ${because}; no --checks command was given`);
      throw new QueueError(`retest_required: ${because}, so this landing's result is unknown, and no --checks command was given.\n`
        + `  Run the branch's checks and record them with \`record --tree ${options.branch}\`, or pass \`--checks "bash scripts/fast.sh"\`.`,
      75, 'retest_required');
    }
    if (options.dryRun) {
      finish('refused', `dry-run: would merge ${options.branch} onto ${upstream.slice(0, 12)}` + (rerun ? ' after a retest' : ' with no retest'));
      return {id, granted: true, dry_run: true, rerun, candidate_tree: tree};
    }

    // 3. The merge, the push, the readback - the landing itself. The token is re-read before each
    //    effect: a revoked holder (reconcile --force) must not push.
    heartbeat(db, id, lease);
    const containing = git(canonical, ['merge-base', '--is-ancestor', options.branch, 'HEAD']);
    let merged = headAt;
    if (containing.status === 0) {
      say(`#${id} ${options.branch} is already contained in main at ${headAt.slice(0, 12)}; nothing to merge`);
    } else {
      const subject = gitOk(canonical, ['log', '-1', '--format=%s', options.branch]).trim();
      const merge = git(canonical, ['merge', '--no-ff', '-m', `merge(${options.branch}): ${subject}`, options.branch]);
      if (merge.status !== 0) {
        git(canonical, ['merge', '--abort']);
        finish('refused', `merge_failed: ${String(merge.stderr || merge.stdout || '').trim().split('\n').slice(-3).join(' | ')}`);
        throw new QueueError(`merge_failed: ${options.branch} onto ${upstream.slice(0, 12)}: ${String(merge.stderr || merge.stdout || '').trim().split('\n').slice(-3).join(' | ')}; the merge was aborted and main is unchanged`, 75, 'merge_failed');
      }
      merged = resolveCommit(canonical, 'HEAD');
      say(`#${id} merged ${options.branch} into main at ${merged.slice(0, 12)} (${rerun ? 'after a retest' : 'no rebase, no retest'})`);
    }
    // A required retest runs on the MERGED tree, because that is the tree the landing pushes and the
    // only tree whose result means anything here. It runs before the push, so a failure rolls the
    // merge back to exactly the base the landing started from and nothing is published. It is judged
    // against main's known-failures baseline (see ensureBaseline above), not against zero.
    let candidateRun = null;
    if (rerun) {
      say(`#${id} retest required; running ${options.checks} on the merged tree ${merged.slice(0, 12)}`);
      const started = Date.now();
      let captured = await captureCommand({
        cwd: canonical, command: options.checks, env: checksEnvironment(canonical),
        log: path.join(dir, `checks-${merged.slice(0, 12)}.log`),
      });
      let took = Math.round((Date.now() - started) / 1000);
      let judged = judgedRun(captured, 'merged tree');
      // A green candidate needs no baseline at all: there is nothing to compare. Only a red one has to
      // be read against what main already fails, and only then is the baseline measured (if nobody has
      // recorded one for main's check inputs).
      let baseline = judged.run.ok ? null : await ensureBaseline({id, canonical, upstream, command: options.checks, dir, db, say});
      let outcome = judged.run.ok ? {verdict: 'pass', why: 'the checks passed'} : judgeRun({baseline, run: judged.run});
      if (outcome.verdict === 'environment') {
        // Never a verdict on the code: one serial retry on the same tree (WA_FAST_JOBS=1, which
        // scripts/fast.sh honours), and only then a named "could not run".
        say(`#${id} the failures are the machine, not the tree (${outcome.why}); retrying ${options.checks} once, serially`);
        const retryStarted = Date.now();
        captured = await captureCommand({
          cwd: canonical, command: options.checks, env: checksEnvironment(canonical, {WA_FAST_JOBS: '1', WA_FAST_SERIAL: '1'}),
          log: path.join(dir, `checks-${merged.slice(0, 12)}-retry.log`),
        });
        took = Math.round((Date.now() - retryStarted) / 1000);
        judged = judgedRun(captured, 'merged tree, serial retry');
        outcome = judged.run.ok ? {verdict: 'pass', why: 'the serial retry passed'} : judgeRun({baseline, run: judged.run});
      }
      candidateRun = judged.run;
      if (outcome.verdict !== 'pass') {
        const rollback = git(canonical, ['reset', '--hard', headAt]);
        const detail = describeRun(judged.run);
        if (outcome.verdict === 'environment') {
          finish('refused', `environment_blocked: the checks could not run on ${merged.slice(0, 12)} (unchanged after a serial retry): ${outcome.why}; rolled back to ${headAt.slice(0, 12)}`);
          throw new QueueError(`environment_blocked: ${outcome.why}.\n${detail}\n`
            + `  This is the machine (fork/spawn limits), not a verdict on ${options.branch}: the merge was rolled back to ${headAt.slice(0, 12)} (reset ${rollback.status === 0 ? 'ok' : 'FAILED'}) and nothing was pushed. Retry the landing; no code change is needed. The check log is ${judged.log}.`,
          75, 'environment_blocked');
        }
        finish('refused', `checks_failed: ${outcome.verdict} on ${merged.slice(0, 12)}: ${outcome.why}; rolled back to ${headAt.slice(0, 12)}`);
        throw new QueueError(`checks_failed: ${outcome.why}` + (outcome.baseline_environment && outcome.baseline_environment.length ? ` (main's own environment-only failures: ${outcome.baseline_environment.join(', ')})` : '') + `.\n${detail}\n`
          + `  ${options.branch} is WORSE than main's baseline for check inputs ${treeDigest(canonical, upstream).retest.slice(0, 12)}: a failing name main does not fail, or a stricter section it passes. The merge was rolled back to ${headAt.slice(0, 12)} (reset ${rollback.status === 0 ? 'ok' : 'FAILED'}) and nothing was pushed. The check log is ${judged.log}.`,
        75, 'checks_failed');
      }
      say(`#${id} checks passed in ${took}s on ${merged.slice(0, 12)}: ${outcome.why}`);
      recordProof(db, {digest: digest.retest, tree, by: owner.id, command: options.checks, log: `merged ${merged}; ${outcome.why}`});
    }
    if (options.noPush) {
      finish('abandoned', `no-push: merged ${merged.slice(0, 12)} locally, not pushed`);
      return {id, granted: true, merged, pushed: false};
    }
    heartbeat(db, id, lease);
    const push = git(canonical, ['push', 'origin', 'main']);
    if (push.status !== 0) {
      finish('refused', `push_failed: ${String(push.stderr || '').trim().split('\n').slice(-3).join(' | ')}`);
      throw new QueueError(`push_failed: ${String(push.stderr || '').trim().split('\n').slice(-3).join(' | ')}; the merge is local only (main is unchanged on origin)`, 75, 'push_failed');
    }
    const readback = gitOk(canonical, ['ls-remote', 'origin', 'refs/heads/main']).trim().split(/\s+/)[0];
    if (readback !== merged) {
      finish('refused', `readback_mismatch: pushed ${merged.slice(0, 12)} and origin/main is ${readback.slice(0, 12)}`);
      throw new QueueError(`readback_mismatch: pushed ${merged.slice(0, 12)} but origin/main reads ${readback.slice(0, 12)}`, 76, 'readback_mismatch');
    }
    say(`#${id} pushed main ${headAt.slice(0, 12)}..${merged.slice(0, 12)}; readback origin refs/heads/main = ${readback.slice(0, 12)}`);
    // The merged tree was just measured by a full run of the check command, and main is now exactly
    // that tree, so that measurement IS the known-failures baseline of the new main - recorded here so
    // the next landing on it pays no pristine run at all. Recorded after the readback, so nothing is
    // recorded for a commit that did not land.
    if (candidateRun) {
      const landedDigest = treeDigest(canonical, merged).retest;
      const record = baselineRecord({run: candidateRun, command: checkCommandKey(options.checks), commit: merged, digest: landedDigest, host: hostName(), source: 'candidate'});
      recordBaseline(db, {digest: landedDigest, command: options.checks, commit: merged, record, by: owner.id});
      say(`#${id} baseline recorded for the new main: ${record.names.length} known failure(s) at check inputs ${landedDigest.slice(0, 12)}; the next landing on it needs no pristine run`);
    }
    // A landing makes a commit installable, so it publishes the prebuilt binary for it. This runs
    // AFTER the push and the readback, so nothing here can make main's content depend on a build; a
    // failure is recorded, never rolled back into a refusal of a landing that already happened.
    heartbeat(db, id, lease);
    const release = publishNodeRelease(canonical, merged, dir);
    say(`#${id} release ${release.state} (${release.target}): ${release.detail}${release.tag ? ` [${release.tag}]` : ''} in ${release.seconds}s`);
    finish('landed', `${options.branch} landed at ${merged.slice(0, 12)} in ${now() - acquired.row.created_at}s (${rerun ? 'retested' : 'no retest'}; upstream ${delta.retest.why})`,
      {result: JSON.stringify({merged, upstream, rerun, delta: delta.counts, release})});
    return {id, granted: true, merged, pushed: true, rerun, release};
  } catch (error) {
    // An error that is not already a terminal state leaves the claim abandoned, never silently held.
    const row = db.prepare('SELECT state FROM queue WHERE id=?').get(id);
    if (row && row.state === 'granted') finish('abandoned', `error: ${error.code || 'failed'}: ${String(error.message).split('\n')[0]}`);
    throw error;
  }
}

// ---- release / reconcile ------------------------------------------------------------------------
function commandRelease(options) {
  const {dir, db} = open(options);
  const row = ownedRow(db, options);
  const state = options.result === 'abandoned' ? 'abandoned' : 'landed';
  const reason = options.evidence || `${state} by its holder (pid ${process.pid})`;
  db.prepare('UPDATE queue SET state=?, reason=?, ended_at=? WHERE id=?').run(state, reason, now(), row.id);
  logRow(db, row.id, state, reason);
  releaseLease(row.lease);
  const next = waitingRows(db)[0];
  say(`#${row.id} ${state}: ${reason}${next ? `; next is #${next.id} ${next.owner} (${next.branch}, waiting ${age(next.created_at)})` : '; nobody waiting'}`);
  return {id: row.id, state};
}

// The one way a person ends a row the queue will not decide: an expired holder whose process still
// runs, or a holder whose claim is contradicted by its lease. The evidence is required and logged;
// with --force the row is ended even though its pid is alive, and the holder's own token check turns
// that into a refusal to push rather than two landers.
function commandReconcile(options) {
  const {dir, db} = open(options);
  if (!options.id) throw new QueueError('reconcile needs --id <n>', 75, 'usage');
  if (!options.evidence || String(options.evidence).trim().length < 8) {
    throw new QueueError('reconcile needs --evidence describing what you checked (it is the record of why a claim ended)', 75, 'evidence_required');
  }
  const row = db.prepare('SELECT * FROM queue WHERE id=?').get(Number(options.id));
  if (!row) throw new QueueError(`no queue row #${options.id}`, 75, 'queue_row_missing');
  if (row.state !== 'granted') throw new QueueError(`#${row.id} is already ${row.state}: ${row.reason || ''}`, 75, 'not_granted');
  const sameBoot = row.boot === bootId() && row.host === hostName();
  const alive = sameBoot && process.kill && (() => { try { process.kill(row.pid, 0); return true; } catch (error) { return error.code === 'EPERM'; } })();
  if (alive && !options.force) {
    throw new QueueError(`live_owner: #${row.id} is claimed by pid ${row.pid} (${row.owner}) and that process is alive; a live owner is never reconciled without --force, and --force is an explicit decision that its landing must not push`, 75, 'live_owner');
  }
  const reason = `reconciled${alive ? ' (--force, holder pid alive)' : ''}: ${String(options.evidence).trim()}`;
  db.prepare('UPDATE queue SET state=?, reason=?, ended_at=? WHERE id=?').run('abandoned', reason, now(), row.id);
  logRow(db, row.id, 'reconciled', `${reason}; owner ${row.owner}, branch ${row.branch}, held ${age(row.started_at)}, lease ${row.lease.slice(0, 8)}`);
  const next = waitingRows(db)[0];
  say(`#${row.id} ended by reconcile: ${reason}${next ? `; next is #${next.id} ${next.owner} (${next.branch})` : '; nobody waiting'}`);
  return {id: row.id, state: 'abandoned', reason};
}

// ---- baseline -----------------------------------------------------------------------------------
//
// The recorded known-failures baseline, read or primed by a person. `land` keeps it up to date by
// itself (a measure on a pristine tree, then the measurement of every merged tree it lands); this
// command exists for the two cases the queue cannot cover: reading what the next landing will tolerate,
// and recording a measurement that was made outside the queue (a session that ran the checks on a
// pristine checkout itself). The record is keyed by the check command, this machine and main's retest
// digest, so a log recorded for a different tree is refused rather than trusted.
function commandBaseline(options) {
  const {repo, canonical, dir, db} = open(options);
  const command = options.command || 'bash scripts/fast.sh';
  const commit = resolveCommit(repo, options.commit || 'origin/main');
  if (!commit) throw new QueueError(`baseline: cannot resolve ${options.commit || 'origin/main'} in ${repo}`, 75, 'baseline_commit_unknown');
  const digest = treeDigest(canonical, commit).retest;
  if (options.record) {
    const log = path.resolve(options.record);
    if (!fs.existsSync(log)) throw new QueueError(`baseline --record: no such log ${log}`, 75, 'baseline_log_missing');
    const text = fs.readFileSync(log, 'utf8');
    const run = parseCheckLog(text, {exitCode: options.exitCode === undefined ? null : Number(options.exitCode)});
    if (!run.named && !run.ok) {
      throw new QueueError(`baseline --record: ${log} names no failing test and does not say the checks passed, so it cannot describe a tree. Pass --exit-code <n> for a log that ended in a bare exit code, or use scripts/fast.sh's output.`,
        75, 'baseline_log_unnamed');
    }
    const record = baselineRecord({run, command: checkCommandKey(command), commit, digest, host: hostName(), source: options.source || 'recorded'});
    recordBaseline(db, {digest, command, commit, record, by: resolveOwner(options).id});
    logRow(db, 0, 'baseline', `recorded by ${resolveOwner(options).id} from ${log} for ${commit.slice(0, 12)} (check inputs ${digest.slice(0, 12)}): ${record.names.length} known failure(s)`);
    const line = `recorded ${record.names.length} known failure(s) for ${commit.slice(0, 12)} with \`${checkCommandKey(command)}\` (check inputs ${digest.slice(0, 12)})`;
    return emit({recorded: record, digest, commit, command: checkCommandKey(command)}, options, line);
  }
  const record = baselineOf(db, {digest, command});
  if (options.json) return emit({commit, digest, command: checkCommandKey(command), baseline: record}, options);
  if (!record) { say(`no baseline recorded for ${commit.slice(0, 12)} with \`${checkCommandKey(command)}\` (check inputs ${digest.slice(0, 12)}): the next landing that needs one will measure a pristine tree once`); return null; }
  say(`${commit.slice(0, 12)} with \`${checkCommandKey(command)}\`: ${record.names.length} known failure(s) recorded by ${record.recorded_by} (${record.source}, check inputs ${digest.slice(0, 12)}, measured on ${String(record.commit || '').slice(0, 12)})`);
  for (const name of record.names) say(`  known: ${name}${(record.environment_names || []).includes(name) ? '  [environment]' : ''}`);
  return record;
}

// ---- history ------------------------------------------------------------------------------------
function commandHistory(options) {
  const {db} = open(options);
  const limit = Number(options.limit || 40);
  const rows = db.prepare(`SELECT l.at, l.queue_id, l.action, l.detail, q.owner, q.branch
                           FROM log l LEFT JOIN queue q ON q.id = l.queue_id
                           ORDER BY l.id DESC LIMIT ?`).all(limit);
  if (options.json) return emit(rows, options);
  for (const row of rows.reverse()) {
    say(`${new Date(row.at * 1000).toISOString()} #${row.queue_id} ${row.action}: ${row.detail}`);
  }
  return rows;
}

// ---- main ---------------------------------------------------------------------------------------
async function main() {
  const [command, ...argv] = process.argv.slice(2);
  const options = parseArgs(argv);
  let result;
  if (command === 'status') result = commandStatus(options);
  else if (command === 'acquire') result = await commandAcquire(options);
  else if (command === 'record') result = commandRecord(options);
  else if (command === 'land') result = await commandLand(options);
  else if (command === 'release') result = commandRelease(options);
  else if (command === 'reconcile') result = commandReconcile(options);
  else if (command === 'classify') result = commandClassify(options);
  else if (command === 'baseline') result = commandBaseline(options);
  else if (command === 'history') result = commandHistory(options);
  else throw new QueueError('usage: landing-queue.mjs status|acquire|record|land|release|reconcile|classify|baseline|history [options]', 75, 'usage');
  if (result && result.exit) process.exitCode = result.exit;
  return result;
}

main().catch(error => {
  const detail = error instanceof QueueError ? error.message : `${error.message}\n${error.stack || ''}`;
  console.error(`landing-queue: ${error.code || 'error'}: ${detail}`);
  process.exitCode = error.exit || 76;
});
