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
//   node scripts/landing-queue.mjs pin --commit <sha> [--pin-dir <dir>] [--owner <session id>]
//                                       [--wait-timeout <s>] [--repo <dir>]
//   node scripts/landing-queue.mjs record --tree <ref> [--command "<what ran>"] [--owner <id>]
//   node scripts/landing-queue.mjs land --branch <name> [--checks "<cmd>"] [--dry-run] [--no-push]
//                                       [--owner <session id>] [--lease-seconds <s>] [--repo <dir>]
//   node scripts/landing-queue.mjs preflight --branch <name> [--checks "<cmd>"] [--worktree <dir>]
//                                           [--lane gate|none] [--owner <session id>] [--repo <dir>]
//   node scripts/landing-queue.mjs release --id <n> [--result landed|abandoned] [--evidence <text>]
//   node scripts/landing-queue.mjs reconcile --id <n> --evidence <text> [--force]
//   node scripts/landing-queue.mjs classify --from <rev> --to <rev> [--repo <dir>] [--json]
//   node scripts/landing-queue.mjs baseline [--command "<cmd>"] [--commit <rev>] [--record <log>] [--exit-code <n>]
//                                          [--measure] [--source <label>] [--repo <dir>] [--json]
//   node scripts/landing-queue.mjs history [--limit <n>] [--json] [--repo <dir>]
//
// Exit codes: 0 the command's own success; 75 refused (named, terminal - a refusal is never retried
// by itself); 76 the queue or the repository could not answer.
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {
  QueueError, classifyDelta, treeDigest, candidateTree, canonicalDirt, describeDirt, git, gitOk,
  mainWorktree, openQueue, queueDir, logRow, resolveOwner, holderOf, reclaimPass, grantNext,
  queuePosition, waitingRows, heartbeat, resolveCommit, bootId, hostName, proofOf, recordProof,
  baselineOf, recordBaseline, checkCommandKey, recoverUnpushed, writeHolder, clearHolder,
} from './lib/landing-queue.mjs';
import {parseCheckLog, baselineRecord, judgeRun, describeRun} from './lib/landing-baseline.mjs';
import {deployGate} from './lib/deploy-gate.mjs';
import {holdLease, releaseLease} from './lib/sqlite-lease.mjs';

const now = () => Math.floor(Date.now() / 1000);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const say = line => console.log(`landing-queue: ${line}`);

function parseArgs(argv) {
  const options = {json: false};
  const flags = new Set(['--json', '--no-wait', '--dry-run', '--no-push', '--force', '--measure']);
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
// Every target the channel publishes, named together in ONE publisher run. The release tag is the
// commit (`node-<sha12>`) and it carries ONE manifest whose rows are the targets that build covered, and
// a re-publish replaces that manifest (`gh release upload --clobber`). Measured 2026-11-11: a second run
// per target would leave the second target's one-row manifest as the release's only manifest, and a node
// of the first target would then find no row for its triple and fall back to compiling - which is the
// cost this step exists to remove (work: x86_64, 2 cores, ~100 s incremental, 19 min bootstrap). So the
// publisher does both in one invocation; the queue reads its answer per target.
const RELEASE_TARGETS = ['aarch64-unknown-linux-gnu', 'x86_64-unknown-linux-gnu'];
const RELEASE_OK = new Set(['published', 'covered']);
const RELEASE_TIMEOUT_MS = 45 * 60 * 1000;

const lastLine = text => String(text || '').trim().split(/\r?\n/).filter(Boolean).slice(-1)[0] || '';

// Which target a failure line is about (`build_failed: wa for x86_64-unknown-linux-gnu.2.31`,
// `binary_missing: .../wa-x86_64-unknown-linux-gnu-abc123`), or '' when the line names none.
const releaseTargetOf = line => RELEASE_TARGETS.find(target => String(line).includes(target)) || '';

function publishNodeRelease(canonical, commit, dir) {
  const started = Date.now();
  const args = ['scripts/publish-node-binaries.sh', '--ensure', '--publish'];
  for (const target of RELEASE_TARGETS) args.push('--target', target);
  args.push('--commit', commit);
  const run = spawnSync('bash', args, {cwd: canonical, encoding: 'utf8', timeout: RELEASE_TIMEOUT_MS, env: process.env});
  const output = `${run.stdout || ''}${run.stderr || ''}`.trim();
  const seconds = Math.round((Date.now() - started) / 1000);
  const log = path.join(dir, `release-${commit.slice(0, 12)}.log`);
  try { fs.writeFileSync(log, `${output}\n`, 'utf8'); } catch { /* the row still carries the reason */ }
  const targets = Object.fromEntries(RELEASE_TARGETS.map(target =>
    [target, {state: 'unknown', detail: 'the publisher reported nothing for this target'}]));
  const timedOut = Boolean(run.error && run.error.code === 'ETIMEDOUT');
  if (timedOut || run.status !== 0) {
    // Name the target the run stopped at, and never call the other one covered: a run that died between
    // the two builds verified neither. Both states are read by `status` on the next landing.
    const tail = lastLine(output);
    const failed = releaseTargetOf(tail);
    const why = timedOut ? `the publisher did not finish within ${RELEASE_TIMEOUT_MS / 60000} min` : (tail || `the publisher exited ${run.status}`);
    for (const target of RELEASE_TARGETS) {
      targets[target] = !failed || target === failed
        ? {state: 'failed', detail: why}
        : {state: 'unverified', detail: `the publish run stopped at ${failed}: ${why}`};
    }
    return {state: 'failed', tag: '', targets, seconds, log, detail: why,
      failed: RELEASE_TARGETS.filter(target => !RELEASE_OK.has(targets[target].state))};
  }
  const covered = output.match(/covered: (\S+) covers the compiled inputs of \S+ for ([^(\n]+)/);
  const tag = (output.match(/publish-node-binaries ok: (\S+)/) || [])[1] || (covered ? covered[1] : '');
  const coveredFor = covered ? covered[2].split(/\s+/).filter(Boolean) : [];
  for (const target of RELEASE_TARGETS) {
    targets[target] = coveredFor.includes(target)
      ? {state: 'covered', tag, detail: `covered by ${covered[1]}`}
      : {state: 'published', tag, detail: `published ${tag}`};
  }
  const state = coveredFor.length === RELEASE_TARGETS.length ? 'covered' : 'published';
  return {state, tag, targets, seconds, log, failed: [],
    detail: lastLine(output) || (state === 'covered' ? `covered by ${tag}` : `published ${tag}`)};
}

// One line an operator reads: every target's own verdict, never an aggregate that hides one of them.
const describeRelease = release => `${release.state} (${
  RELEASE_TARGETS.map(target => `${target}=${(release.targets && release.targets[target] || {}).state || 'unknown'}`).join(', ')
}): ${release.detail}${release.tag ? ` [${release.tag}]` : ''}`;

// ---- the previous landing's release, and the row that says it is not covered ---------------------
//
// MEASURED 2026-11-11: the aarch64 publish for db0ec1f9 failed silently - the landing recorded it and
// nothing read it - and only the NEXT landing exposed it, after a commit with no installable binary had
// been on main for an hour. A landing is the moment a commit becomes installable, so an uncovered landed
// commit is a standing fact the next lander (and any person reading `status`) has to see BEFORE it acts.
//
// It is a named warning row, never a refusal: the merge is pushed and read back by the time the publisher
// runs, and an uncovered release is a fact about the release, not a reason to unland a commit or to stop
// the next landing. `status` therefore still exits 0; the row is what fails loudly.
function normalizeRelease(release) {
  if (!release || typeof release !== 'object') return null;
  if (release.targets && typeof release.targets === 'object') return release;
  // A row recorded before the queue published both targets: one target, one verdict. Normalized here so
  // an old row is read as what it says instead of being reported as "no release at all".
  if (!release.target) return {...release, targets: {}};
  return {...release,
    targets: {[release.target]: {state: release.state, tag: release.tag || '', detail: release.detail || ''}}};
}

function previousLanding(db) {
  // A `release`d acquire also ends as 'landed' and carries no result: only a row that actually merged
  // (its result names the commit) is a landing whose release verdict can be read.
  const row = db.prepare("SELECT id, owner, branch, ended_at, result FROM queue WHERE state='landed' AND result IS NOT NULL AND result != '' ORDER BY id DESC LIMIT 1").get();
  if (!row || !row.result) return null;
  let result;
  try { result = JSON.parse(row.result); } catch { return null; }
  return {id: row.id, owner: row.owner, branch: row.branch, landed_at: row.ended_at,
    commit: result.merged || '', release: normalizeRelease(result.release)};
}

// The verdict per target, then a WARNING row for every target that is not published or covered.
function releaseVerdict(landing) {
  if (!landing) return {lines: [], warnings: []};
  const sha = String(landing.commit || '').slice(0, 12) || 'unknown';
  const release = landing.release;
  const states = release
    ? RELEASE_TARGETS.map(target => `${target}=${(release.targets[target] || {}).state || 'unknown'}`).join(', ')
    : 'none recorded';
  const lines = [`release for ${sha} (landed by ${landing.branch} #${landing.id}, ${age(landing.landed_at)} ago): ${states}`];
  const warnings = [];
  if (!release) {
    warnings.push(`WARNING release_uncovered ${sha}: the landing recorded no release verdict at all`);
    return {lines, warnings};
  }
  for (const target of RELEASE_TARGETS) {
    const state = (release.targets[target] || {}).state || 'unknown';
    if (RELEASE_OK.has(state)) continue;
    const detail = (release.targets[target] || {}).detail || release.detail || '';
    warnings.push(`WARNING release_uncovered ${sha} ${target}: ${state}${detail ? ` - ${detail}` : ''}`
      + `${release.log ? ` (log ${release.log})` : ''}`);
  }
  return {lines, warnings};
}

// ---- status -------------------------------------------------------------------------------------
function commandStatus(options) {
  const {repo, canonical, dir, db} = open(options);
  const reclaimed = reclaimPass(db, dir);
  const holder = holderOf(db, dir);
  const waiting = waitingRows(db);
  const dirt = canonicalDirt(canonical);
  // What a dead lander left in the canonical checkout. Read without touching anything: the next
  // acquire finishes (or rolls back) it, and this line says which before anyone queues.
  const recovery = recoverUnpushed({canonical, db, apply: false, say: () => {}});
  // What a landing here would tolerate, before anyone queues: the recorded known-failures baseline of
  // the main that is checked out. A session should be able to read it without landing once (it is the
  // question every improvised judge on 2026-11-10 was really asking), and an empty answer is a fact
  // too: the next red candidate measures one baseline and pays for it once.
  const upstream = resolveCommit(repo, 'origin/main');
  const command = options.command || 'bash scripts/fast.sh';
  const previous = previousLanding(db);
  const verdict = releaseVerdict(previous);
  const baseline = upstream ? baselineOf(db, {digest: treeDigest(canonical, upstream).retest, command}) : null;
  const state = {
    canonical,
    queue_dir: dir,
    holder: holder && {
      id: holder.id, owner: holder.owner, owner_source: holder.owner_source, branch: holder.branch,
      kind: holder.kind || 'landing',
      started_at: holder.started_at, held_seconds: now() - holder.started_at,
      heartbeat_seconds_ago: now() - (holder.heartbeat_at || holder.started_at),
      expires_in: Math.max(0, (holder.expires_at || 0) - now()), lease_held: holder.lease_held,
      pid: holder.pid, reason: holder.reason || '',
    },
    waiting: waiting.map((row, index) => ({
      position: index + 1, id: row.id, owner: row.owner, branch: row.branch, waiting_seconds: now() - row.created_at,
    })),
    reclaimed,
    recovery: recovery.action === 'none' ? null : recovery,
    canonical_dirt: {dirty: dirt.dirty, count: dirt.count, files: dirt.files},
    verdict: holder ? 'busy' : 'free',
    baseline: baseline && {command: checkCommandKey(command), names: baseline.names || [],
      source: baseline.source || '', measured_on: baseline.commit || '', recorded_by: baseline.recorded_by || ''},
    // The commit before this one, read at the START of every look at the queue: a landing whose release is
    // not covered must not wait for the next landing to be visible.
    previous_release: previous && {id: previous.id, branch: previous.branch, commit: previous.commit,
      landed_at: previous.landed_at, release: previous.release},
    release_warnings: verdict.warnings,
  };
  if (options.json) return emit(state, options);
  const lines = [];
  lines.push(holder
    ? `holder #${holder.id} ${holder.owner} (${holder.owner_source}) on ${holder.branch}${holder.kind === 'deploy' ? ' [deploy: pinning a build commit]' : ''}, held ${age(holder.started_at)}${holder.lease_held ? '' : ' [LEASE NOT HELD - reclaimable]'}, expires in ${Math.max(0, (holder.expires_at || 0) - now())}s`
    : 'free: nobody holds the canonical checkout');
  if (waiting.length) {
    lines.push(`waiting ${waiting.length}: ` + waiting.map((row, i) => `#${i + 1} #${row.id} ${row.owner} (${row.branch}, ${age(row.created_at)})`).join(', '));
  }
  lines.push(dirt.dirty
    ? `canonical ${canonical}: DIRTY ${dirt.count} file(s) - ${describeDirt(dirt)}${holder ? ' (the holder is landing, so this may be its merge)' : ' - belongs to nobody holding the lease; a landing is refused until it is clean'}`
    : `canonical ${canonical}: clean`);
  lines.push(baseline
    ? `baseline for ${String(upstream).slice(0, 12)} with \`${checkCommandKey(command)}\`: ${(baseline.names || []).length} known failure(s) (${baseline.source || 'recorded'}, measured on ${String(baseline.commit || '').slice(0, 12)} by ${baseline.recorded_by || 'an earlier landing'}) - a landing is refused only for a failure this list does not have`
    : `baseline for ${String(upstream).slice(0, 12)} with \`${checkCommandKey(command)}\`: none recorded - the next red candidate measures one, once, and records it`);
  for (const line of [...verdict.lines, ...verdict.warnings]) lines.push(line);
  for (const entry of reclaimed) lines.push(`reclaimed #${entry.id} (${entry.owner}): ${entry.reason}`);
  if (recovery.action !== 'none') {
    lines.push(recovery.action === 'refused'
      ? `canonical recovery: REFUSED ${recovery.code}: ${recovery.reason}`
      : `canonical recovery: ${recovery.action} ${String(recovery.branch || '')} (HEAD ${String(recovery.head || '').slice(0, 12)} is ${recovery.ahead} commit(s) ahead of origin/main) - the next acquire records it`);
  }
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
  const log = options.log || say;
  // A claim that looks free may still be the residue of a lander that died between its merge and its
  // push: reclaim the dead row first, then finish (or undo) the effect it left in the tree before the
  // dirty check reads it. Both are logged; neither is inferred from a timeout.
  reclaimPass(db, dir);
  const recovery = recoverUnpushed({canonical, db, apply: true, say: log});
  if (recovery.action === 'refused') {
    throw new QueueError(`${recovery.code}: ${recovery.reason}.\n`
      + `  The canonical checkout ${canonical} is not a landing's to finish: a person must decide whether that`
      + ` commit is pushed, rebased or dropped. Nothing was merged and nothing was pushed.`, 75, recovery.code);
  }
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
  db.prepare(`INSERT INTO queue(owner,owner_source,owner_evidence,branch,worktree,canonical,kind,state,lease,pid,host,boot,base,created_at,lease_seconds)
              VALUES(?,?,?,?,?,?,?,'waiting',?,?,?,?,?,?,?)`)
    .run(owner.id, owner.source, JSON.stringify(owner.evidence), branch, path.resolve(options.repo || process.cwd()),
      canonical, options.kind === 'deploy' ? 'deploy' : 'landing', lease, process.pid, hostName(), bootId(), base, now(),
      Number(options.leaseSeconds || (options.kind === 'deploy' ? 300 : 1800)));
  const id = Number(db.prepare('SELECT last_insert_rowid() AS id').get().id);
  logRow(db, id, 'enqueued', `${owner.id} (${owner.source}) ${options.kind === 'deploy' ? 'deploy-pin ' : ''}branch ${branch} on ${canonical}, base ${base.slice(0, 12)}`);
  log(`#${id} enqueued for ${owner.id} (${owner.source}): branch ${branch}, base ${base.slice(0, 12)}`);

  if (options.noWait) {
    const position = queuePosition(db, id);
    const holder = holderOf(db, dir);
    db.prepare("UPDATE queue SET state='refused', reason=?, ended_at=? WHERE id=?").run('no-wait: refused without waiting', now(), id);
    logRow(db, id, 'refused', `no-wait; position ${position}, holder ${holder ? `#${holder.id} ${holder.owner}` : 'none'}`);
    emit({id, granted: false, position, holder: holder && {id: holder.id, owner: holder.owner, branch: holder.branch}}, options,
      `#${id} NOT granted (--no-wait): position ${position}, ${holder ? `holder #${holder.id} ${holder.owner} on ${holder.branch}` : 'no holder'}`);
    return {id, granted: false, position, exit: 75};
  }
  const granted = await waitForLease({db, dir, id, lease, options: {...options, log}});
  if (!granted.granted) return granted;
  return {id, lease, granted: true, row: db.prepare('SELECT * FROM queue WHERE id=?').get(id)};
}

async function waitForLease({db, dir, id, lease, options}) {
  const log = options.log || say;
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
      log(`#${id} waiting: position ${position} of ${waitingRows(db).length + 1}; holder ${holder ? `#${holder.id} ${holder.owner} on ${holder.branch} for ${age(holder.started_at)}` : 'none'}`);
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
  // Publish the holder for the tool-layer guard (lua/core/canonical_guard.lua). The row remains the authority.
  writeHolder(dir, row);
  const waited = now() - row.created_at;
  const behind = waitingRows(db).filter(other => other.id !== id).length;
  logRow(db, id, 'granted', `after waiting ${waited}s; ${behind} still waiting; expires in ${row.expires_at - now()}s`);
  log(`#${id} GRANTED to ${row.owner} on ${row.branch} after waiting ${waited}s (base ${row.base.slice(0, 12)}, lease ${lease.slice(0, 8)}, expires in ${row.expires_at - now()}s); ${behind} waiting`);
  return {id, lease, dir, granted: true, row, waited};
}

// ---- pin ---------------------------------------------------------------------------------------
//
// A deploy must not build from the canonical checkout while a landing may merge into it. Measured on
// wasm_the_first (2026-11-10, three deploys): landing #28 merged 3bea7b97 - which rewrites
// lua/core/server.lua - into the canonical tree while a deploy was reading it, and the deploy staged
// one commit and verified another (`stale embedded module: lua/core/server.lua`). Retrying the stage
// (commit 2231fc6f) treated the symptom; this is the coordination it was missing.
//
// `pin` takes the queue's lease - so it waits for a landing in progress, and a landing waits for it -
// and uses that moment to create a DETACHED worktree at the exact commit the deploy will build. The
// lease is then ended with evidence and every later step of the deploy reads the pinned tree, which no
// landing can move. The lease is short (one resolve, one worktree add); the build is not behind it.
const PIN_ROOT_DEFAULT = () => path.join(os.tmpdir(), 'wa-deploy-pins');

function ensurePinnedWorktree({canonical, commit, pinDir}) {
  const root = path.join(pinDir, commit);
  const usable = () => {
    if (!fs.existsSync(path.join(root, '.git'))) return false;
    const head = git(root, ['rev-parse', 'HEAD']).status === 0 ? gitOk(root, ['rev-parse', 'HEAD']).trim() : '';
    return head === commit;
  };
  if (usable()) return {root, reused: true};
  if (fs.existsSync(root)) {
    spawnSync('git', ['-C', canonical, 'worktree', 'remove', '--force', root], {encoding: 'utf8'});
    fs.rmSync(root, {recursive: true, force: true});
  }
  spawnSync('git', ['-C', canonical, 'worktree', 'prune'], {encoding: 'utf8'});
  fs.mkdirSync(pinDir, {recursive: true});
  const added = spawnSync('git', ['-C', canonical, 'worktree', 'add', '--detach', '--force', root, commit], {encoding: 'utf8'});
  if (added.status !== 0) {
    throw new QueueError(`pin_failed: cannot create a pinned worktree for ${commit.slice(0, 12)} at ${root}: ${String(added.stderr || added.stdout || '').trim().split('\n').slice(-2).join(' | ')}`,
      76, 'pin_failed');
  }
  const head = gitOk(root, ['rev-parse', 'HEAD']).trim();
  if (head !== commit) {
    throw new QueueError(`pin_mismatch: the pinned worktree ${root} is at ${head.slice(0, 12)}, not ${commit.slice(0, 12)}; refusing to build something that cannot say what it is`, 76, 'pin_mismatch');
  }
  return {root, reused: false};
}

async function commandPin(options) {
  if (!options.commit) throw new QueueError('pin needs --commit <sha> (the exact commit to build)', 75, 'usage');
  const {repo, canonical, dir, db} = open(options);
  const owner = resolveOwner({...options, allowDeploy: true});
  const commit = resolveCommit(repo, options.commit);
  if (!commit) throw new QueueError(`pin: cannot resolve ${options.commit} in ${repo}`, 75, 'pin_commit_unknown');
  const branchRef = gitOk(canonical, ['symbolic-ref', '--short', '-q', 'HEAD']).trim();
  if (branchRef !== 'main') {
    throw new QueueError(`pin_not_on_main: ${canonical} has HEAD on '${branchRef || 'detached'}'; a deploy pins a commit from the canonical main, never from another branch`, 75, 'pin_not_on_main');
  }
  const dirt = canonicalDirt(canonical);
  if (dirt.dirty) {
    throw new QueueError(`pin_dirty_canonical: ${canonical} has ${dirt.count} uncommitted change(s) and cannot say which commit is deployed: ${describeDirt(dirt)}. Commit them in their own worktree, or revert them; nothing was pinned`,
      75, 'pin_dirty_canonical');
  }
  const fetch = git(canonical, ['fetch', 'origin', '--prune']);
  if (fetch.status !== 0) say(`pin: warning: git fetch failed (${String(fetch.stderr || '').trim().split('\n').pop()}); pinning against the last known origin/main`);
  const upstream = resolveCommit(canonical, 'origin/main');
  const onMain = upstream && git(canonical, ['merge-base', '--is-ancestor', commit, upstream]).status === 0;
  if (!onMain) {
    throw new QueueError(`pin_not_on_main: ${commit.slice(0, 12)} is not contained in origin/main ${String(upstream || '').slice(0, 12)}; a deploy installs a commit that is on main`, 75, 'pin_not_on_main');
  }
  const pinDir = path.resolve(options.pinDir || PIN_ROOT_DEFAULT());
  const quiet = options.json ? () => {} : say;
  const acquired = await enqueueAndWait({...options, log: quiet, branch: options.branch || `deploy/${commit.slice(0, 12)}`, kind: 'deploy', allowDeploy: true});
  if (!acquired.granted) return acquired;
  const id = acquired.id;
  const finish = (state, reason, extra = {}) => {
    db.prepare('UPDATE queue SET state=?, reason=?, ended_at=?, result=? WHERE id=?').run(state, reason, now(), extra.result || '', id);
    logRow(db, id, state, reason);
    clearHolder(dir, id);
    releaseLease(acquired.lease);
    quiet(`#${id} ${state}: ${reason}`);
  };
  try {
    const pinned = ensurePinnedWorktree({canonical, commit, pinDir});
    const reason = `pinned ${commit.slice(0, 12)} at ${pinned.root} for a deploy to build from (canonical ${canonical} stays free; ${pinned.reused ? 'an existing pinned tree was reused' : 'a detached worktree was created'}); the lease is released and a landing may proceed`;
    db.prepare('UPDATE queue SET candidate_tree=?, verified_tree=? WHERE id=?').run(commit, commit, id);
    finish('pinned', reason, {result: JSON.stringify({commit, pin: pinned.root, reused: pinned.reused, owner: owner.id})});
    return emit({id, commit, pin: pinned.root, reused: pinned.reused, canonical}, options, reason);
  } catch (error) {
    finish('abandoned', `error: ${error.code || 'failed'}: ${String(error.message).split('\n')[0]}`);
    throw error;
  }
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
async function ensureBaseline({id, canonical, upstream, command, dir, db, say, by = 'queue'}) {
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
  recordBaseline(db, {digest, command, commit: upstream, record, by});
  logRow(db, 0, 'baseline', `measured on ${upstream.slice(0, 12)} in ${canonical} (check inputs ${digest.slice(0, 12)}) with '${checkCommandKey(command)}': ${record.names.length} known failure(s), exit ${captured.code}`);
  say(`#${id} baseline measured on ${upstream.slice(0, 12)}: ${record.names.length} known failure(s)${record.names.length ? ` (${record.names.slice(0, 4).join(', ')}${record.names.length > 4 ? ', ...' : ''})` : ''}; recorded for check inputs ${digest.slice(0, 12)}`);
  return record;
}

// ---- re-checking a "new" failure -----------------------------------------------------------------
//
// Measured here on 2026-11-10 (rows #27, #28 and #30): the set of checks this machine fails MOVES
// between runs - within eight minutes the same main failed graph/codemode/cli-view, then a disjoint
// completion-packet/context-usage set, then the first set again, and the same five rows run directly
// failed identically on main and on the merge. The installed component set and the load on a shared
// node change under a run, so "a name the baseline does not have" is not by itself the branch's fault,
// and refusing a correct branch is the failure this whole change exists to remove.
//
// The attribution used here is A-B-A, the classic answer to a flaky environment, and it measures the
// TREE and nothing else: the named Lua rows are run directly (the row recipe of scripts/fast.sh's
// lua_run: this binary, this tree as the Lua root, a scratch home, no node, no rendezvous) on main,
// then on the merged tree, then on main again. Running the rows directly rather than through the
// check command is deliberate: the baseline tree carries its own scripts/, and an older runner there
// would not honour a "just these rows" request - which is exactly how row #30 got a false answer.
//
//   * fails in EITHER main run -> unstable on this machine, never charged to the branch;
//   * passes both main runs and the merged run -> the branch's: the landing is refused;
//   * passes on the merged tree -> transient, reported and not charged.
//
// It runs only when a candidate would otherwise be refused, and only over the rows involved.
function luaRowsOf(run) {
  return [...new Set(run.failures.map(failure => failure.name)
    .filter(name => /^lua scripts\/[^ ]+\.lua$/.test(name))
    .map(name => name.slice(4)))].sort();
}

// One row, the way scripts/fast.sh runs it: WA_SCRIPT with this tree as WASM_AGENT_LUA_ROOT, its own
// scratch home and its own database, no rendezvous and no relay. Returns true when the row passed.
function runLuaRow({binary, cwd, row, timeoutMs = 180000}) {
  // A row the tree does not have cannot fail there. This is the whole difference between "main passes
  // it" and "main never had it", and it is what makes a row a branch ADDS measurable.
  if (!fs.existsSync(path.join(cwd, row))) return {row, ok: true, code: null, last: 'not in this tree'};
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-recheck-'));
  try {
    const result = spawnSync(binary, ['--db', path.join(home, 't.db')], {
      cwd, timeout: timeoutMs, encoding: 'utf8',
      env: {...process.env, WASM_AGENT_LUA_ROOT: cwd, WASM_AGENT_HOME: home,
        WASM_AGENT_RENDEZVOUS: '', WASM_AGENT_RELAY: '', WASM_AGENT_MANAGED: '0', WA_SCRIPT: row},
    });
    return {row, ok: result.status === 0, code: result.status, last: String(result.output || '').trim().split(/\r?\n/).filter(Boolean).slice(-1)[0] || ''};
  } finally {
    try { fs.rmSync(home, {recursive: true, force: true}); } catch { /* windows may hold a handle */ }
  }
}

function runLuaRows({binary, cwd, rows, log, label}) {
  const outcomes = new Map();
  const lines = [`# ${label}: ${rows.length} row(s) in ${cwd}`];
  for (const row of rows) {
    const outcome = runLuaRow({binary, cwd, row});
    outcomes.set(row, outcome.ok);
    lines.push(`${outcome.ok ? 'pass' : 'FAIL'} ${row} (exit ${outcome.code}) ${outcome.last.slice(0, 160)}`);
  }
  try { fs.writeFileSync(log, `${lines.join('\n')}\n`, 'utf8'); } catch { /* the row carries it */ }
  return outcomes;
}

function hostBinary(canonical) {
  const dirs = String(process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const onPath = dirs.flatMap(dir => [path.join(dir, process.platform === 'win32' ? 'wa.exe' : 'wa'), path.join(dir, 'wa')])
    .find(candidate => { try { return fs.statSync(candidate).isFile(); } catch { return false; } });
  if (onPath) return onPath;
  for (const candidate of [path.join(canonical, 'rust', 'target', 'release', 'wa.exe'),
    path.join(canonical, 'rust', 'target', 'release', 'wa'),
    path.join(os.homedir(), '.local', 'bin', 'wa')]) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return 'wa';
}

// main -> merged -> main, on the same rows, seconds apart.
async function recheckNewFailures({id, canonical, upstream, baseDigest, command, baseline, names, dir, db, say}) {
  const wanted = names.filter(name => /^lua scripts\/[^ ]+\.lua$/.test(name));
  const outsideLua = names.filter(name => !/^lua scripts\/[^ ]+\.lua$/.test(name));
  const result = {reproduced: [], unstable: [], transient: [], outside_lua: outsideLua};
  if (wanted.length === 0) return result;
  const rows = wanted.map(name => name.slice(4));
  const binary = hostBinary(canonical);
  say(`#${id} ${rows.length} new row(s); measuring them on main, merged, main (A-B-A) before calling them the branch's`);
  const detached = what => {
    const out = git(canonical, ['checkout', '--quiet', '--detach', what]);
    if (out.status !== 0) {
      throw new QueueError(`recheck_unavailable: cannot put ${canonical} at ${what.slice(0, 12)} to re-check ${rows.join(' ')}: ${String(out.stderr || '').trim().split('\n').slice(-2).join(' | ')}. Nothing was pushed.`,
        75, 'recheck_unavailable');
    }
  };
  const backToMain = () => {
    const out = git(canonical, ['checkout', '--quiet', 'main']);
    if (out.status !== 0) {
      throw new QueueError(`recheck_checkout_stuck: could not put ${canonical} back on main after the re-check: ${String(out.stderr || '').trim().split('\n').slice(-2).join(' | ')}. Nothing was pushed; the checkout is at ${upstream.slice(0, 12)}, detached, and a person must put it back on main.`,
        76, 'recheck_checkout_stuck');
    }
  };
  let onMainFirst, onMerged, onMainAgain;
  try {
    detached(upstream);
    onMainFirst = runLuaRows({binary, cwd: canonical, rows, log: path.join(dir, `recheck-a1-${upstream.slice(0, 12)}.log`), label: `main ${upstream.slice(0, 12)}`});
    backToMain();
    onMerged = runLuaRows({binary, cwd: canonical, rows, log: path.join(dir, `recheck-b-${Date.now()}.log`), label: 'merged tree'});
    detached(upstream);
    onMainAgain = runLuaRows({binary, cwd: canonical, rows, log: path.join(dir, `recheck-a2-${upstream.slice(0, 12)}.log`), label: `main ${upstream.slice(0, 12)} again`});
  } finally {
    backToMain();
  }
  result.unstable = rows.filter(row => !onMainFirst.get(row) || !onMainAgain.get(row))
    .map(row => `lua ${row}`);
  const suspects = rows.filter(row => onMainFirst.get(row) && onMainAgain.get(row));
  result.reproduced = suspects.filter(row => !onMerged.get(row)).map(row => `lua ${row}`);
  result.transient = suspects.filter(row => onMerged.get(row)).map(row => `lua ${row}`);
  if (result.unstable.length) {
    say(`#${id} fails on main too, so not this branch's: ${result.unstable.join(', ')} (unstable on this machine)`);
    // main was measured more recently than the baseline was: keep the fresher fact, so the next
    // landing on the same check inputs does not pay to discover it again.
    const merged = [...new Set([...(baseline.names || []), ...result.unstable])].sort();
    recordBaseline(db, {digest: baseDigest, command, commit: upstream, by: 'queue',
      record: {...baseline, names: merged, failed_checks: Math.max(Number(baseline.failed_checks) || 0, merged.length),
        environment_names: [...new Set([...(baseline.environment_names || []), ...result.unstable])].sort(),
        source: 'recheck', at: Math.floor(Date.now() / 1000)}});
  }
  if (result.transient.length) say(`#${id} passed on the merged tree when measured alone, so transient: ${result.transient.join(', ')}`);
  if (result.reproduced.length) say(`#${id} passes on main twice and fails on the merged tree: ${result.reproduced.join(', ')}`);
  return result;
}

// ---- land ---------------------------------------------------------------------------------------
async function commandLand(options) {
  if (!options.branch) throw new QueueError('land needs --branch <name>', 75, 'usage');
  const {repo, canonical, dir, db} = open(options);
  const owner = resolveOwner(options);
  // Before this lander touches anything: what did the LAST landing publish? Printed per target, with a
  // named warning row for each target it left uncovered - a lander that is about to make a commit
  // installable reads the standing fact first, and the row never blocks it.
  const previous = previousLanding(db);
  for (const line of [...releaseVerdict(previous).lines, ...releaseVerdict(previous).warnings]) say(line);
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
    clearHolder(dir, id);
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
      if (outcome.verdict === 'worse') {
        // "A name main does not fail" is not the branch's fault by itself on a machine whose failures
        // move between runs: re-check the new names on main's own tree, and charge only what
        // reproduces on the merged tree and passes on main.
        const recheck = await recheckNewFailures({id, canonical, upstream, baseDigest: treeDigest(canonical, upstream).retest,
          command: options.checks, baseline, names: outcome.new_failures || [], dir, db, say});
        const charged = [...(outcome.strict || []).filter(name => (outcome.new_failures || []).includes(name)),
          ...recheck.reproduced, ...recheck.outside_lua];
        if (charged.length === 0) {
          outcome = {...outcome, verdict: 'pass', charged: [],
            why: `only failures this machine also fails on main right now (${[...recheck.unstable, ...recheck.transient].join(', ')})`};
          db.prepare('UPDATE queue SET reason=? WHERE id=?').run(`recheck: ${recheck.unstable.length} unstable on main, ${recheck.transient.length} transient`, id);
          logRow(db, id, 'recheck', `${recheck.unstable.length} new name(s) fail on main too (unstable on this machine): ${recheck.unstable.join(', ') || 'none'}; ${recheck.transient.length} did not reproduce on the merged tree: ${recheck.transient.join(', ') || 'none'}`);
        } else {
          outcome = {...outcome, verdict: 'worse', new_failures: charged,
            why: `${charged.length} new failing check(s) pass on main twice and fail on the merged tree: ${charged.join(', ')}`};
          judged = {...judged, run: {...judged.run, failures: judged.run.failures.filter(failure => charged.includes(failure.name))}};
        }
      }
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
    // 4. The deploy gate: the preconditions a deploy of this tree would refuse, decided HERE, on the
    //    merged tree, before the push. A landing is the moment a commit becomes installable, and a
    //    commit no deploy can install is not a landing - it is a second landing, minutes later, on the
    //    node that discovered it (2026-11-11: a stale `rust/wa-sentinel/Cargo.lock`). See
    //    scripts/lib/deploy-gate.mjs for which deploy refusals each check covers, and for the two it
    //    honestly does not (a machine without cargo or a sha256 tool prints a named skip, never a pass).
    //
    //    It runs after the retest (a tree whose checks fail is refused before its deployability is
    //    asked about) and before `--no-push`, because "would this tree install" is worth knowing even
    //    for a local merge.
    let gate = null;
    if (merged === headAt) {
      say(`#${id} deploy gate skipped: main did not move (${merged.slice(0, 12)} is already origin/main)`);
    } else {
      gate = deployGate({root: canonical, commit: merged, dir, say: line => say(`#${id} ${line}`)});
      for (const check of gate.checks) {
        say(`#${id} deploy gate ${check.state === 'ok' ? 'ok' : check.state.toUpperCase()}: ${check.name} - ${check.detail}`);
      }
      if (!gate.ok) {
        const rollback = git(canonical, ['reset', '--hard', headAt]);
        finish('refused', `undeployable: ${gate.why}; rolled back to ${headAt.slice(0, 12)}`);
        throw new QueueError(`undeployable: a deploy of this tree cannot work, and a landing is what makes a commit installable.\n${gate.why}\n`
          + `  These are the deploy's own preconditions (scripts/lib/deploy-gate.mjs): ${gate.checks.map(check => `${check.name}=${check.state}`).join(', ')}.\n`
          + `  The merge was rolled back to ${headAt.slice(0, 12)} (reset ${rollback.status === 0 ? 'ok' : 'FAILED'}) and nothing was pushed. Fix it in ${options.branch} and land again.`,
        75, 'undeployable');
      }
      logRow(db, id, 'deploy-gate', gate.line);
    }
    if (options.noPush) {
      finish('abandoned', `no-push: merged ${merged.slice(0, 12)} locally, not pushed`);
      return {id, granted: true, merged, pushed: false, gate};
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
    say(`#${id} release ${describeRelease(release)} in ${release.seconds}s`);
    for (const warning of releaseVerdict({id, branch: options.branch, landed_at: now(), commit: merged, release}).warnings) say(warning);
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

// ---- preflight ----------------------------------------------------------------------------------
//
// THE PREFLIGHT LANE: run a branch's checks on its own tree, without the landing lease, and record what
// they proved for the landing that will reuse it.
//
// WHY IT EXISTS. `land` runs the checks on the MERGED tree inside the canonical checkout, under the
// one landing lease. That is correct and it is also why a session that wants to know whether its branch
// is good has had two bad options: wait for the lease (a queue of landings behind it) or run the suite
// by hand and have nobody be able to point at the result. Measured 2026-11-11: three sessions ran the
// fast path in their own worktrees while one landed, the lander's retest hit `cannot fork` and was
// refused `environment_blocked`, and two of the three results were thrown away because there was no
// record to attach them to.
//
// WHAT IT IS. The same check command, on the branch's OWN worktree, at the branch's OWN tip, admitted by
// the gate lane (scripts/gate-lane.mjs) so N preflights and a landing do not contend for the cores, and
// on success `recordProof` for the tree's retest digest - the same evidence table `record` writes, so
// `land --branch <name>` finds it and skips the retest it would otherwise have to run.
//
// WHAT IT IS NOT. It does not take the landing lease, touch the canonical checkout, merge anything or
// push anything: it cannot block a lander, and it cannot publish. `queue` rows are untouched (the one
// proof row IS the record). A red run records nothing and exits 1 - the check's own result, never a
// refusal.
const GATE_LANE = fileURLToPath(new URL('./gate-lane.mjs', import.meta.url));
const lastLines = (text, count = 2) => String(text || '').trim().split('\n').slice(-count).join(' | ').slice(0, 300);

// The worktree that holds this branch - the tree the preflight runs in. `git worktree list --porcelain`
// is the only answer to "where is this branch checked out": a branch that is not checked out anywhere
// can be checked by `--worktree <dir>` pointing at a clean tree already at that tip, and otherwise the
// refusal names the command that would make one.
function worktreeFor(repo, branch, expected) {
  const out = gitOk(repo, ['worktree', 'list', '--porcelain']);
  let current = null;
  const found = [];
  for (const line of out.split('\n')) {
    if (line.startsWith('worktree ')) current = {path: line.slice('worktree '.length).trim(), branch: '', head: ''};
    else if (current && line.startsWith('HEAD ')) current.head = line.slice(5).trim();
    else if (current && line.startsWith('branch ')) current.branch = line.slice('branch '.length).trim().replace(/^refs\/heads\//, '');
    else if (current && line.trim() === '') { found.push(current); current = null; }
  }
  if (current) found.push(current);
  return found.find(entry => entry.branch === branch && entry.head === expected)
    || found.find(entry => entry.head === expected)
    || null;
}

async function commandPreflight(options) {
  if (!options.branch) throw new QueueError('preflight needs --branch <name> (the branch whose tree is checked)', 75, 'usage');
  const {repo, canonical, dir, db} = open(options);
  // An owner is required for the proof (it is evidence: who ran what, on which tree), and it is the same
  // harness-session check every other command makes - but no lease is taken and no queue row is made.
  const owner = resolveOwner(options);
  const branch = options.branch.replace(/^refs\/heads\//, '').replace(/^origin\//, '');
  const tip = resolveCommit(canonical, options.branch) || resolveCommit(canonical, `origin/${branch}`);
  if (!tip) throw new QueueError(`preflight: cannot resolve ${options.branch} in ${canonical}`, 75, 'preflight_branch_unknown');
  const explicit = options.worktree ? path.resolve(options.worktree) : null;
  let worktree = explicit ? {path: explicit, head: gitOk(explicit, ['rev-parse', 'HEAD']).trim(), branch} : worktreeFor(canonical, branch, tip);
  if (!worktree) {
    throw new QueueError(`preflight_worktree_required: ${branch} (${tip.slice(0, 12)}) is not checked out in a worktree of ${canonical}, so there is no tree to run its checks on.\n`
      + `  Make one: bash ${path.join(canonical, 'scripts', 'new-worktree.sh')} ${branch.replace(/[^a-z0-9]+/gi, '-')} --canonical ${canonical}  (it creates the tree under the node's one root, docs/ONEROOT.md)\n`
      + `  Or by hand: git -C ${canonical} worktree add ${path.join(process.env.WASM_AGENT_HOME || process.env.HOME || '~', '.wasm-agent', 'worktrees', branch.replace(/[^a-z0-9]+/gi, '-'))} ${branch}\n`
      + `  Or name an existing clean tree at that tip: --worktree <dir>`, 75, 'preflight_worktree_required');
  }
  if (worktree.head !== tip) {
    throw new QueueError(`preflight_worktree_moved: ${worktree.path} is at ${String(worktree.head).slice(0, 12)} and ${branch} is at ${tip.slice(0, 12)}; a preflight records a proof for the tree it ran on, so it refuses a tree that is not the branch's tip (commit, or check out the tip first)`, 75, 'preflight_worktree_moved');
  }
  const command = options.checks || 'bash scripts/fast.sh';
  const log = path.resolve(options.log || path.join(dir, `preflight-${branch.replace(/[^a-z0-9]+/gi, '-')}-${tip.slice(0, 12)}.log`));
  fs.mkdirSync(path.dirname(log), {recursive: true});
  const quiet = options.json ? () => {} : say;
  quiet(`preflight ${branch} (${tip.slice(0, 12)}) in ${worktree.path}: ${command} - no landing lease, admitted by the gate lane`);
  const lane = options.lane === 'none' ? null : GATE_LANE;
  let status;
  let captured = '';
  const started = Date.now();
  if (lane && fs.existsSync(lane)) {
    const args = [lane, 'run', '--cwd', worktree.path, '--label', `preflight:${branch}`,
      '--log', log, '--wait-seconds', String(options.waitSeconds || 3600), '--', 'bash', '-c', command];
    const result = spawnSync(process.execPath, args, {encoding: 'utf8', windowsHide: true,
      env: {...process.env, WA_PREFLIGHT: '1'}});
    status = result.status === null ? -1 : result.status;
    captured = fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : '';
    if (status === 75 || status === 76) {
      throw new QueueError(`preflight_lane_blocked: the gate lane refused a slot for this preflight (exit ${status}): ${lastLines(String(result.stderr || '')) || 'no reason printed'}.\n`
        + `  The lane serializes CPU-heavy gates on this node so a landing's retest is not starved; the slot it is waiting behind is named by \`node scripts/gate-lane.mjs status\`.\n`
        + `  To run outside the lane on purpose: --lane none (and say so in the report).`, 75, 'preflight_lane_blocked');
    }
  } else {
    if (!lane && options.lane !== 'none') quiet('preflight: the gate lane is not beside this command, so the checks run unadmitted (what --lane none does)');
    const result = spawnSync('bash', ['-c', command], {cwd: worktree.path, encoding: 'utf8', windowsHide: true,
      env: {...process.env, WA_PREFLIGHT: '1'}});
    status = result.status === null ? -1 : result.status;
    captured = `${result.stdout || ''}${result.stderr || ''}`;
    fs.writeFileSync(log, captured);
  }
  const took = Math.round((Date.now() - started) / 1000);
  const run = parseCheckLog(captured, {exitCode: status});
  // The runner's own skip count, from its summary line: a skip is not a pass, and a proof recorded
  // over one says so rather than reading as a fully covered tree.
  const skipped = Number((/fast path (?:ok|FAILED) \([^)]*?,\s*(\d+)\s+skipped/.exec(captured) || [])[1] || 0);
  const digest = treeDigest(canonical, tip);
  if (status !== 0) {
    logRow(db, 0, 'preflight', `${owner.id} ran \`${command}\` on ${branch}@${tip.slice(0, 12)} and it FAILED (exit ${status}, ${took}s); nothing recorded. Log ${log}`);
    const detail = describeRun(run);
    quiet(`preflight ${branch} FAILED in ${took}s (exit ${status}); nothing was recorded, so the landing will run its own checks.${detail ? `\n${detail}` : ''}\n  log ${log}`);
    return {id: 0, branch, tree: tip, ok: false, exit_code: status, log, seconds: took, run};
  }
  recordProof(db, {digest: digest.retest, tree: tip, by: owner.id, command, log: `preflight ${log}; exit 0 in ${took}s`});
  logRow(db, 0, 'preflight', `${owner.id} proved ${branch}@${tip.slice(0, 12)} with \`${command}\` in ${took}s (retest digest ${digest.retest.slice(0, 12)}); a landing of ${branch} on this base needs no rerun. Log ${log}`);
  const line = `preflight ${branch} (${tip.slice(0, 12)}) passed in ${took}s and recorded a proof for retest digest ${digest.retest.slice(0, 12)}: \`land --branch ${branch}\` reuses it instead of running \`${command}\` again`;
  quiet(line);
  quiet(`  log ${log}${skipped ? `; the run SKIPPED ${skipped} check(s) - a skip is not a pass` : ''}`);
  return emit({id: 0, branch, tree: tip, ok: true, exit_code: 0, log, seconds: took, digest: digest.retest,
    command, skipped, recorded: true}, options);
}

// ---- release / reconcile ------------------------------------------------------------------------
function commandRelease(options) {
  const {dir, db} = open(options);
  const row = ownedRow(db, options);
  const state = ['abandoned', 'pinned'].includes(options.result) ? options.result : 'landed';
  const reason = options.evidence || `${state} by its holder (pid ${process.pid})`;
  db.prepare('UPDATE queue SET state=?, reason=?, ended_at=? WHERE id=?').run(state, reason, now(), row.id);
  logRow(db, row.id, state, reason);
  clearHolder(dir, row.id);
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
async function commandBaseline(options) {
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
  if (!record && options.measure) {
    // Measured on demand, by the same code a landing uses: one run of the check command on main's own
    // commit in the CANONICAL checkout, under the queue's own rule that nobody else is moving it. This
    // is the question every improvised judge asked on 11/10 - "what does main already fail here?" - and
    // until now this command could only read a record, so a session that needed the answer had to land
    // once (or improvise its own judge) to get it.
    const holder = holderOf(db, dir);
    if (holder) {
      throw new QueueError(`baseline --measure: #${holder.id} ${holder.owner} holds the queue on ${holder.branch}, so the canonical checkout is not ours to move. Nothing was measured; retry when it is free.`,
        75, 'baseline_busy');
    }
    const dirt = canonicalDirt(canonical);
    if (dirt.dirty) {
      throw new QueueError(`baseline --measure: ${canonical} is DIRTY (${dirt.count} file(s): ${describeDirt(dirt)}), and a baseline measured over somebody's uncommitted work is not main's. Nothing was measured.`,
        75, 'baseline_dirty_canonical');
    }
    // `--json` promises that stdout is the object and nothing else, so the measurement's own narration
    // is silenced there and carried in the record instead.
    const measured = await ensureBaseline({id: 0, canonical, upstream: commit, command, dir, db, by: resolveOwner(options).id,
      say: options.json ? () => {} : line => say(line.replace(/^#0 /, ''))});
    const line = `${commit.slice(0, 12)} with \`${checkCommandKey(command)}\`: ${(measured.names || []).length} known failure(s) MEASURED now`
      + `${(measured.names || []).length ? ` (${(measured.names || []).slice(0, 6).join(', ')}${measured.names.length > 6 ? ', ...' : ''})` : ''}`
      + ` (check inputs ${digest.slice(0, 12)}, source ${measured.source || 'canonical'})`;
    if (options.json) return emit({commit, digest, command: checkCommandKey(command), baseline: measured}, options, line);
    say(line);
    for (const name of measured.names || []) say(`  known: ${name}${(measured.environment_names || []).includes(name) ? '  [environment]' : ''}`);
    return measured;
  }
  if (options.json) return emit({commit, digest, command: checkCommandKey(command), baseline: record}, options);
  if (!record) { say(`no baseline recorded for ${commit.slice(0, 12)} with \`${checkCommandKey(command)}\` (check inputs ${digest.slice(0, 12)}): the next landing that needs one will measure a pristine tree once. Pass --measure to measure it now, in the canonical checkout`); return null; }
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
  else if (command === 'pin') result = await commandPin(options);
  else if (command === 'record') result = commandRecord(options);
  else if (command === 'land') result = await commandLand(options);
  else if (command === 'preflight') result = await commandPreflight(options);
  else if (command === 'release') result = commandRelease(options);
  else if (command === 'reconcile') result = commandReconcile(options);
  else if (command === 'classify') result = commandClassify(options);
  else if (command === 'baseline') result = commandBaseline(options);
  else if (command === 'history') result = commandHistory(options);
  else throw new QueueError('usage: landing-queue.mjs status|acquire|pin|record|land|preflight|release|reconcile|classify|baseline|history [options]', 75, 'usage');
  if (result && result.exit) process.exitCode = result.exit;
  // A preflight that ran the checks and found them red is the check's own result, not a refusal: exit 1
  // so a caller can tell it from `0 recorded` and from the named refusals (75) and lane errors (76).
  if (command === 'preflight' && result && result.ok === false) process.exitCode = 1;
  return result;
}

main().catch(error => {
  const detail = error instanceof QueueError ? error.message : `${error.message}\n${error.stack || ''}`;
  console.error(`landing-queue: ${error.code || 'error'}: ${detail}`);
  process.exitCode = error.exit || 76;
});
