#!/usr/bin/env node
// The landing queue's runner: ONE request at a time, restart-safe, from a journal that is the whole truth.
//
// The loop is three lines of policy and a lot of care about crashes:
//   1. take the next runnable request (priority first, then FIFO, never one waiting on review);
//   2. run the steps, writing a transition before each one;
//   3. write the verdict - landed with main's sha, or rejected with a cause and the rework to act on.
//
// RESTART SAFETY is the reason this is a journal and not a lock. An in-flight request is `merging`, `rows` or
// `pushing`; on start, each one is resolved by asking main (the only fact that cannot be stale): the sha is in
// origin/main -> `landed`, otherwise the request goes back to `queued` and runs again. Nothing is ever left
// half-applied, because the lander pushes LAST: a re-run before the push leaves no half state.
//
// NO SLEEP-SPIN. `waitForWork` blocks on the journal's own file (inotify via fs.watch, with a capped fallback
// poll) instead of `sleep 20`. A wait that wakes on the database write is the same loop with a smaller floor,
// and it cannot drift into polling the filesystem for hours.
//
// Usage: node scripts/q-runner.mjs [--repo <dir>] [--db <file>] [--missions <dir>] [--once] [--dry-run]
// Exit codes: 0 stopped cleanly (--once: nothing left to do); 1 a step failed in a way that is not a verdict.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {openJournal, nextRunnable, transition, verdict, lastState, isOpen} from './lib/queue/journal.mjs';
import {mainContains, landQuick, noopStep, CAPS} from './lib/queue/steps.mjs';
import {writeRework, escalate, renderRework} from './lib/queue/rework.mjs';
import {wakeSession} from './lib/queue/wake.mjs';

function defaultDb() {
  const home = process.env.WASM_AGENT_HOME || path.join(os.homedir(), '.wasm-agent');
  return path.join(home, 'lane', 'landing-queue.db');
}

// THE RESUME RULE, in one function so the row can call it without a runner: a request is only in flight if
// its last transition says so, and the only authority on "did it land" is main.
export async function resumeInFlight(db, {repo, log = () => {}} = {}) {
  const inFlight = db.prepare(`SELECT r.* FROM requests r
      WHERE NOT EXISTS (SELECT 1 FROM verdicts v WHERE v.req = r.id)
        AND (SELECT t.state FROM transitions t WHERE t.req = r.id ORDER BY t.id DESC LIMIT 1)
            IN ('merging', 'rows', 'pushing')`).all();
  const resolved = [];
  for (const row of inFlight) {
    const landed = await mainContains(repo, row.sha);
    if (landed) {
      verdict(db, row.id, {verdict: 'landed', cause: 'already_on_main', mainSha: row.sha.slice(0, 12)});
      resolved.push({id: row.id, outcome: 'landed'});
      log(`resume: #${row.id} ${row.branch} is on main - closed as landed`);
    } else {
      transition(db, row.id, 'queued', 'resumed', `restarted with no half state: ${row.sha.slice(0, 12)} is not on main`);
      resolved.push({id: row.id, outcome: 'queued'});
      log(`resume: #${row.id} ${row.branch} was in flight and is not on main - back in the queue`);
    }
  }
  return resolved;
}

/// DELIVERING A REJECTION, in one place (hunk 5). A rejected landing is rework: a file the mission owns, a
/// wake that reaches the session even if its turn has ended, and - at the third rejection for a mission - a
/// line in the orchestrator's ATTENTION. All three are best-effort and each says what it did, because a
/// runner that dies delivering a message has turned a rejected landing into a stuck queue.
export function deliverRejection(db, row, payload, opts = {}) {
  const missionsDir = opts.missionsDir;
  const out = {file: null, woke: false, escalated: null};
  if (!missionsDir) return out;
  const written = writeRework({missionsDir, mission: row.mission, id: row.id, payload, fsImpl: opts.fsImpl});
  out.file = written.written ? written.file : null;
  if (written.written) {
    const woke = wakeSession({missionsDir, mission: row.mission, file: written.file, id: row.id, spawn: opts.spawn, dryRun: Boolean(opts.dryRunWake)});
    out.woke = Boolean(woke.started);
    out.wake = woke;
  }
  const count = db.prepare(`SELECT COUNT(*) AS n FROM verdicts v JOIN requests r ON r.id = v.req
                             WHERE r.mission = ? AND v.verdict = 'rejected'`).get(row.mission || '').n;
  out.escalated = escalate({missionsDir, mission: row.mission, id: row.id, cause: payload.cause, count, fsImpl: opts.fsImpl});
  return out;
}

/// One request, end to end. `steps` is injected so a row can drive the state machine without pushing
/// anything: production passes the lander's steps, the rows pass a scripted sequence.
export async function runRequest(db, row, opts = {}) {
  const {repo, steps, log = () => {}} = opts;
  const branch = row.branch;
  transition(db, row.id, 'merging', 'runner took it');
  log(`#${row.id} ${branch}@${row.sha.slice(0, 12)}: merging`);

  const merge = await steps.merge({request: row, db});
  if (!merge.ok) {
    const payload = {cause: merge.cause || 'other', branch, sha: row.sha.slice(0, 12), detail: merge.detail ?? null, files: merge.files ?? [], rows: merge.rows ?? ''};
    verdict(db, row.id, {verdict: 'rejected', cause: payload.cause, payload});
    const delivered = deliverRejection(db, row, payload, opts);
    return {outcome: 'rejected', cause: payload.cause, delivered};
  }
  transition(db, row.id, 'rows', 'merged onto the tip', merge.detail ?? null);

  const rows = await steps.rows({request: row, db});
  if (!rows.ok) {
    const payload = {cause: rows.cause || 'own_rows_red', branch, sha: row.sha.slice(0, 12), detail: rows.detail ?? null, files: rows.files ?? [], rows: rows.rows ?? ''};
    verdict(db, row.id, {verdict: 'rejected', cause: payload.cause, payload});
    const delivered = deliverRejection(db, row, payload, opts);
    return {outcome: 'rejected', cause: payload.cause, delivered};
  }
  transition(db, row.id, 'pushing', 'own rows green', rows.detail ?? null);

  const push = await steps.push({request: row, db});
  if (!push.ok) {
    const payload = {cause: push.cause || 'stale_sha', branch, sha: row.sha.slice(0, 12), detail: push.detail ?? null, files: push.files ?? [], rows: push.rows ?? ''};
    verdict(db, row.id, {verdict: 'rejected', cause: payload.cause, payload});
    const delivered = deliverRejection(db, row, payload, opts);
    return {outcome: 'rejected', cause: payload.cause, delivered};
  }
  verdict(db, row.id, {verdict: 'landed', cause: null, mainSha: push.mainSha ?? null});
  return {outcome: 'landed', mainSha: push.mainSha ?? null};
}

/// Take one request if there is one. Returns null when the queue is empty or everything open is waiting on a
/// person, so the caller decides whether to block.
export async function runOnce(db, opts = {}) {
  const {repo, steps, log = () => {}} = opts;
  const row = nextRunnable(db);
  if (!row) return null;
  if (!isOpen(db, row.id)) return null;
  return {id: row.id, ...(await runRequest(db, row, {repo, steps, log, ...opts}))};
}

/// Block until something is queued - on the journal's own write, not on a clock. The fallback poll exists for
/// filesystems where watching a WAL file reports nothing, and it is the cap: it never becomes the loop.
export function waitForWork(db, {dbFile, timeoutMs = 3_600_000, pollMs = 250} = {}) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (why) => { if (done) return; done = true; try { watcher.close(); } catch { /* already closed */ } clearInterval(timer); resolve(why); };
    let watcher = {close: () => {}};
    if (dbFile) {
      try {
        watcher = fs.watch(dbFile, {persistent: false}, () => { if (nextRunnable(db)) finish('write'); });
      } catch { /* the poll below is the fallback */ }
    }
    const timer = setInterval(() => { if (nextRunnable(db)) finish('poll'); }, pollMs);
    setTimeout(() => finish('timeout'), timeoutMs);
  });
}

function parseArgs(argv) {
  const out = {flags: {}};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    if (key === 'once' || key === 'dry-run') { out.flags[key] = true; continue; }
    out.flags[key] = argv[i + 1]; i += 1;
  }
  return out;
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname);
if (invokedDirectly) {
  const {flags} = parseArgs(process.argv.slice(2));
  // NO ENVIRONMENT OVERRIDE (Fable 27/11): --repo or the fixed default, and nothing else. An env var that
  // can point the runner at another tree is a bypass of the one rule that keeps a landing out of the
  // canonical checkout, and it would be invisible in the unit file.
  const repo = flags.repo || path.join(os.homedir(), 'wasm-agent', 'q-clone');
  const missions = flags.missions || path.join(os.homedir(), 'Work', 'missions');
  const dbFile = flags.db || defaultDb();
  const log = (line) => process.stdout.write(`${new Date().toISOString().replace(/\.\d+Z$/, 'Z')} q: ${line}\n`);
  // NEVER THE CANONICAL CHECKOUT. The runner merges, regenerates and PUSHES; the canonical tree is what the
  // installed node serves and what deploy.sh installs from. A queue that landed in it would change the
  // running program as a side effect of somebody else's request. Its own clone or nothing.
  const canonical = path.join(os.homedir(), 'wasm-agent', 'checkout');
  if (path.resolve(repo) === path.resolve(canonical)) {
    process.stderr.write(`q-runner: refusing to run against the canonical checkout (${canonical}); give it its own clone with --repo\n`);
    process.exit(2);
  }
  const db = openJournal(dbFile);
  const step = landQuick({missionsDir: missions, repo, dryRun: Boolean(flags['dry-run'])});
  // The lander is one program: it merges, regenerates, runs the branch's own rows and pushes last. The queue's
  // three transitions still bracket it, because the phases it reports are what a reader wants to see, and the
  // caps belong to the rows above.
  const steps = {merge: step, rows: noopStep('rows'), push: noopStep('push')};
  const resume = async () => resumeInFlight(db, {repo, log});
  const loop = async () => {
    await resume();
    for (;;) {
      const done = await runOnce(db, {repo, steps, log});
      if (done) { log(`#${done.id} ${done.outcome}${done.cause ? ` (${done.cause})` : ''}`); if (flags.once) return; continue; }
      if (flags.once) return;
      await waitForWork(db, {dbFile});
    }
  };
  loop().then(() => { db.close(); process.exit(0); }).catch((error) => { log(`FAILED: ${error.message}`); db.close(); process.exit(1); });
}

export {CAPS};
