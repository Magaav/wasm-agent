// The landing queue: one lander at a time on the canonical checkout, FIFO, with the lease, the
// dirty-tree refusal and the upstream-delta classification that decides what must be retested.
//
// WHY. Measured on wasm_the_first, 2026-11-10 (session 883ffeda): six landings interleaved on main
// in one session, so every move of `origin/main` cost a rebase plus a full fast path for the branch
// and for a pristine base - 6-10 minutes a round, ~20 minutes lost in that one session. Two of those
// six moves were docs-only (`skills/clean-disk` and its report script) and still forced a full
// retest of Rust/Lua branches. In the same window another session (e0fc6da6) edited the canonical
// checkout directly for ~25 minutes; the deploy then refused the dirty tree and blocked the
// landing's deploy for ~7 minutes. Both failures are queue failures: the tree had no owner, and the
// retest decision was made by the shape of a rebase rather than by what actually changed.
//
// WHAT THIS PROGRAM DECIDES. Three things, each recorded:
//   1. who may touch the canonical checkout, in which order, and from what evidence a dead holder is
//      reclaimed (`acquire`/`release`/`reconcile`);
//   2. whether the canonical checkout is dirty and belongs to nobody holding the lease (refused, by
//      name, before anyone waits);
//   3. whether an upstream move can change the result of the branch's checks (`classify`), by
//      comparing digests of the *tree's test-relevant inputs* rather than the diff.
//
// WHAT IT DOES NOT DO. It never merges, rebases, pushes or runs a check by itself: `land` is the
// documented landing (skills/git-orchestrator/SKILL.md, "3. Push under the sole lock") wrapped in
// the lease, and the merge lane, the gate lane and the release gate keep their own jobs. It never
// uses a pid as a lock: the lease is an OS-held SQLite lock (scripts/lib/sqlite-lease.mjs), so a
// killed lander frees the tree the moment it dies and the reclaim is a logged decision, which is the
// failure this repository already paid for once (lesson `les-dcbabb9d2835`: a `.deploy.lock` with a
// dead pid blocked every deploy for 1h44 because nothing reclaimed it).
//
// STATE. One directory per repository, `<git-common-dir>/wa-landing-queue` (all worktrees share it,
// and it is outside the working tree so it can never dirty main), holding `queue.sqlite`, the
// `leases/` locks and nothing that needs a process to be alive. A node replacement restarts the
// queue from the same rows; there is no watcher, scheduler or recurring wake anywhere in this file.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {holdLease, releaseLease, leaseHeld, pidAlive} from './sqlite-lease.mjs';

export class QueueError extends Error {
  constructor(message, exit = 76, code = '') {
    super(message);
    this.exit = exit;
    this.code = code;
  }
}

const now = () => Math.floor(Date.now() / 1000);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// ---- what a test run can read -------------------------------------------------------------------
//
// The retest decision below is "does any input of the checks change", so it needs the complement as
// data: the paths that are documentation and nothing else. Two facts make that list smaller than
// "everything under docs/ and skills/", and both are measured rather than assumed (2026-11-10):
//
//   * `scripts/sync-prompt-docs.lua` WRITES docs/ENVELOPE.md, docs/LAYERED-PROMPT.md and
//     docs/PROGRESSIVE-ENVELOPE.md from the Lua source and `--check` compares them - a move of one of
//     those three can flip that check;
//   * `scripts/check-instructions.mjs` (also in the fast path) reads AGENTS.md,
//     AGENTS.orchestrator.md, docs/CONCURRENCY.md, docs/EVOLUTION.md, docs/FABRIC.md,
//     docs/ORCHESTRATION.md, docs/SKILLS.md, docs/ORCHESTRATION-MODE.md and the three skill files
//     it names - a move of one of those can flip the instruction checks.
//
// So docs-only is not the same as harmless, and this list is the difference. It is guarded by
// scripts/test-landing-queue.mjs, which parses those two scripts and fails when either starts
// reading a file that is not listed here: adding a checked document without adding it here is a
// test failure, not a silently weaker skip.
export const CHECK_INPUTS = new Set([
  'AGENTS.md', 'AGENTS.orchestrator.md', 'AGENTS.subagents.md',
  'docs/ENVELOPE.md', 'docs/LAYERED-PROMPT.md', 'docs/PROGRESSIVE-ENVELOPE.md',
  'docs/CONCURRENCY.md', 'docs/EVOLUTION.md', 'docs/FABRIC.md', 'docs/ORCHESTRATION.md',
  'docs/SKILLS.md', 'docs/ORCHESTRATION-MODE.md', 'docs/FACTORY.md', 'docs/MEMORY.md',
  'skills/git-orchestrator/SKILL.md', 'skills/parallel-evolution/SKILL.md',
  'skills/see-your-output/SKILL.md',
]);

// Documentation and nothing else: no check in scripts/fast.sh or scripts/test.sh reads it.
export function testRelevant(file) {
  if (CHECK_INPUTS.has(file)) return true;
  if (/^docs\//.test(file)) return false;
  if (/^skills\//.test(file)) return false;
  if (/\.md$/.test(file)) return false;
  if (/^(review|reviews|review-evidence|vault|licenses)\//.test(file)) return false;
  if (/^LICENSE$/.test(file)) return false;
  return true;
}

// The compiled-inputs rule, verbatim from scripts/lib/node-binaries.sh (wa_compiled_input), which is
// the one definition the node-binary publisher and the deploy share. Kept as a second
// implementation ON PURPOSE and pinned by a parity test (scripts/test-landing-queue.mjs compares
// this function with the shell one over real paths), because the shell function is the authority and
// a silent divergence here would change which landings publish a binary.
export function compiledInput(file) {
  if (/^(lua|docs|tests|ui|modules|skills|jobs|benchmarks|review|reviews|review-evidence|fixtures|vault|scripts)\//.test(file)) {
    return /^scripts\/(codemode|build-|provision-codemode)/.test(file);
  }
  if (file.includes('/')) return true;
  if (/\.md$/.test(file)) return false;
  return true;
}

// One list of path classes, so `status`, the log line and the JSON all say the same thing.
export function pathClass(file) {
  if (compiledInput(file)) return 'compiled';
  if (/^lua\//.test(file)) return 'lua';
  if (/^rust\//.test(file)) return 'rust';
  if (/^ui\//.test(file)) return 'ui';
  if (/^scripts\//.test(file)) return 'scripts';
  if (/^tests\//.test(file)) return 'tests';
  if (/^skills\//.test(file)) return 'skills';
  if (/^docs\//.test(file) || /\.md$/.test(file)) return 'docs';
  return 'other';
}

// The digest's own identity, hashed as the first line: a change to the classifier above MUST
// invalidate every digest already recorded in the queue rather than silently re-match (the same rule
// as WA_COMPILED_INPUTS_SCHEMA in scripts/lib/node-binaries.sh).
export const INPUTS_SCHEMA = 'wasm-agent-retest-inputs/1';

// ---- git ---------------------------------------------------------------------------------------
export function git(repo, args, options = {}) {
  const result = spawnSync('git', ['-C', repo, ...args], {
    encoding: options.encoding === undefined ? 'utf8' : options.encoding,
    maxBuffer: 64 * 1024 * 1024,
    input: options.input,
  });
  if (result.error) throw new QueueError(`git ${args.join(' ')}: ${result.error.message}`, 76, 'git_spawn');
  return result;
}
export function gitOk(repo, args, options) {
  const result = git(repo, args, options);
  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || '').trim().split('\n').slice(-3).join(' | ');
    throw new QueueError(`git ${args.join(' ')} failed in ${repo}: ${detail || `exit ${result.status}`}`, 76, 'git_failed');
  }
  return String(result.stdout || '');
}

// The main worktree of this repository - the canonical checkout every lander merges into. Reported
// by git, never inferred from the path the caller happens to be in.
export function mainWorktree(repo) {
  const out = gitOk(repo, ['worktree', 'list', '--porcelain']);
  for (const block of out.split(/\n\n+/)) {
    const line = block.split('\n').find(l => l.startsWith('worktree '));
    if (!line) continue;
    return line.slice('worktree '.length);
  }
  throw new QueueError(`no worktree recorded for ${repo}`, 76, 'no_worktree');
}
export function gitCommonDir(repo) {
  return path.resolve(repo, gitOk(repo, ['rev-parse', '--git-common-dir']).trim());
}
export function resolveCommit(repo, ref) {
  const result = git(repo, ['rev-parse', '--verify', '-q', `${ref}^{commit}`]);
  return result.status === 0 ? String(result.stdout).trim() : '';
}

// The candidate tree of `branch` merged onto `base`, computed without a working tree and without a
// checkout: `git merge-tree --write-tree` answers "which tree would the landing push". An empty
// string means the merge conflicts, which is a named blocked input, never a retest question.
export function candidateTree(repo, base, branch) {
  const result = git(repo, ['merge-tree', '--write-tree', base, branch]);
  if (result.status === 0) return String(result.stdout).split('\n')[0].trim();
  if (result.status === 1) {
    return {conflict: true, detail: String(result.stdout || result.stderr || '').split('\n').slice(0, 6).join(' | ')};
  }
  throw new QueueError(`git merge-tree ${base} ${branch} failed: ${String(result.stderr || '').trim()}`, 76, 'merge_tree_failed');
}

// ---- the digest ---------------------------------------------------------------------------------
//
// A digest over a TREE, not over a diff, and over the paths a test run can read - the same idea as
// scripts/lib/node-binaries.sh's wa_compiled_inputs_digest, generalized from "is compiled" to "can
// change a test result". Two trees with the same digest are indistinguishable to every check in the
// fast path, whatever order their commits arrived in, so a receipt for one still covers the other.
//
// Sorted and path-first, for the same reason as the publisher: git's listing order is not a fact
// about the tree.
export function treeDigest(repo, treeish) {
  const tree = gitOk(repo, ['rev-parse', '--verify', '-q', `${treeish}^{tree}`]).trim();
  const listing = new TextDecoder().decode(git(repo, ['ls-tree', '-r', '-z', '--full-tree', tree], {encoding: 'buffer'}).stdout);
  const retest = [];
  const compiled = [];
  for (const entry of listing.split('\0')) {
    if (!entry) continue;
    const tab = entry.indexOf('\t');
    if (tab < 0) continue;
    const meta = entry.slice(0, tab).split(' ');
    const file = entry.slice(tab + 1);
    if (meta[1] === 'commit') continue; // a submodule pin is not a file's bytes
    const sha = meta[2];
    if (testRelevant(file)) retest.push(`${file} ${sha}`);
    if (compiledInput(file)) compiled.push(`${file} ${sha}`);
  }
  const hash = lines => crypto.createHash('sha256').update(`${INPUTS_SCHEMA}\n${lines.join('\n')}\n`).digest('hex');
  return {
    tree,
    retest: hash(retest.sort()),
    compiled: hash(compiled.sort()),
    retest_inputs: retest.length,
    files: listing.split('\0').filter(Boolean).length,
  };
}

// ---- the upstream delta -------------------------------------------------------------------------
//
// What moved between two commits, classified. `retest.required` is the answer the queue acts on: it
// is true exactly when at least one moved path can change the result of a check, which is why a
// docs-only move of main skips the branch's suite and a Lua or Rust move does not.
export function classifyDelta(repo, from, to) {
  const fromSha = resolveCommit(repo, from);
  const toSha = resolveCommit(repo, to);
  if (!fromSha) throw new QueueError(`classify: ${from} is not a commit in ${repo}`, 75, 'delta_base_unknown');
  if (!toSha) throw new QueueError(`classify: ${to} is not a commit in ${repo}`, 75, 'delta_head_unknown');
  const raw = gitOk(repo, ['diff', '--name-status', '-z', '--no-renames', fromSha, toSha]);
  const fields = raw.split('\0').filter(Boolean);
  const moved = [];
  for (let i = 0; i + 1 < fields.length; i += 2) moved.push({status: fields[i], path: fields[i + 1]});
  const counts = {};
  for (const entry of moved) {
    const cls = pathClass(entry.path);
    counts[cls] = (counts[cls] || 0) + 1;
  }
  const relevant = moved.filter(entry => testRelevant(entry.path));
  const before = treeDigest(repo, fromSha);
  const after = treeDigest(repo, toSha);
  const compiledMoved = before.compiled !== after.compiled;
  // The instruction every logging line and every refusal repeats.
  const why = moved.length === 0
    ? 'no paths moved'
    : relevant.length === 0
      ? `docs-only: ${moved.length} path(s) moved, none of them read by a check`
      : `${relevant.length} of ${moved.length} moved path(s) can change a check result (${[...new Set(relevant.map(e => pathClass(e.path)))].join(', ')})`;
  return {
    from: fromSha,
    to: toSha,
    commits: Number(gitOk(repo, ['rev-list', '--count', `${fromSha}..${toSha}`]).trim() || 0),
    paths: moved.map(entry => ({...entry, class: pathClass(entry.path), test_relevant: testRelevant(entry.path)})),
    counts,
    test_relevant_paths: relevant.map(entry => entry.path),
    compiled_moved: compiledMoved,
    digest: {before: before.retest, after: after.retest, before_compiled: before.compiled, after_compiled: after.compiled},
    retest: {
      required: relevant.length > 0,
      // Named separately for the two things a lander must re-run: the branch's suite on the merged
      // candidate, and the pristine baseline (main before the branch went in).
      branch_suite: relevant.length > 0,
      baseline: before.retest !== after.retest,
      why,
    },
  };
}

// ---- the repository's queue directory -----------------------------------------------------------
export function queueDir(repo, override) {
  const dir = override || process.env.WA_LANDING_QUEUE_DIR || path.join(gitCommonDir(repo), 'wa-landing-queue');
  return path.resolve(dir);
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS queue(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner TEXT NOT NULL, owner_source TEXT NOT NULL, owner_evidence TEXT NOT NULL,
  branch TEXT NOT NULL, worktree TEXT NOT NULL, canonical TEXT NOT NULL,
  state TEXT NOT NULL, reason TEXT,
  lease TEXT NOT NULL, pid INTEGER NOT NULL, host TEXT NOT NULL, boot TEXT NOT NULL,
  base TEXT NOT NULL,
  created_at INTEGER NOT NULL, started_at INTEGER, heartbeat_at INTEGER, expires_at INTEGER,
  lease_seconds INTEGER NOT NULL DEFAULT 1800,
  ended_at INTEGER,
  verified_tree TEXT, verified_digest TEXT, verified_at INTEGER, verified_by TEXT,
  baseline_commit TEXT, baseline_digest TEXT,
  candidate_tree TEXT, rerun INTEGER, delta TEXT, result TEXT
);
CREATE TABLE IF NOT EXISTS proofs(
  digest TEXT PRIMARY KEY, tree TEXT NOT NULL, verified_at INTEGER NOT NULL,
  verified_by TEXT NOT NULL, command TEXT NOT NULL, log TEXT);
-- The known-failures baseline (scripts/lib/landing-baseline.mjs), one row per (check command, machine,
-- retest digest of the tree it measured). Keyed by the digest and not by the commit because that is
-- what makes it reusable: two main commits whose check inputs are identical are indistinguishable to
-- every check, so a landing on the second must not pay for a pristine run that the first already paid
-- for. The commit is kept for the record - it says which main the names were observed on.
CREATE TABLE IF NOT EXISTS baselines(
  digest TEXT NOT NULL, chk TEXT NOT NULL, host TEXT NOT NULL,
  commit_ TEXT NOT NULL, record TEXT NOT NULL, recorded_at INTEGER NOT NULL, recorded_by TEXT NOT NULL,
  PRIMARY KEY(digest, chk, host));
CREATE TABLE IF NOT EXISTS log(
  id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, queue_id INTEGER NOT NULL,
  action TEXT NOT NULL, detail TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS queue_state ON queue(state,id);
CREATE INDEX IF NOT EXISTS log_queue ON log(queue_id,id);
`;

export function openQueue(dir) {
  fs.mkdirSync(path.join(dir, 'leases'), {recursive: true});
  const db = new DatabaseSync(path.join(dir, 'queue.sqlite'));
  // Several landers, a status call and the holder all write this file from separate processes: one
  // transaction at a time is the whole load, and a busy timeout is what keeps them off each other.
  db.exec('PRAGMA busy_timeout=10000; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
  db.exec(SCHEMA);
  return db;
}

export function logRow(db, id, action, detail) {
  db.prepare('INSERT INTO log(at,queue_id,action,detail) VALUES(?,?,?,?)').run(now(), id, action, detail);
}

// A boot identity, so a pid recorded before a node replacement is never read as a live owner after
// one: on Windows a pid is reused, and "pid 4242 is alive" proves nothing about who 4242 was.
let bootCache = '';
export function bootId() {
  if (bootCache) return bootCache;
  const read = file => { try { return fs.readFileSync(file, 'utf8').trim(); } catch { return ''; } };
  bootCache = read('/proc/sys/kernel/random/boot_id');
  if (!bootCache && process.platform === 'win32') {
    const result = spawnSync('powershell.exe', ['-NoProfile', '-Command',
      '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")'], {encoding: 'utf8'});
    bootCache = result.status === 0 ? String(result.stdout || '').trim() : '';
  }
  if (!bootCache) bootCache = `unknown-boot:${os.hostname()}`;
  return bootCache;
}
export const hostName = () => os.hostname();

// ---- owner identity -----------------------------------------------------------------------------
//
// The owner is a harness session id, and this is where the repository has been burned once already:
// lesson `les-cf782de101c6` - an agent passed `wa-sentinel request deploy --session <hex>`, taking
// that hex from the name of a session-scratch directory that belonged to an OLD session, so the
// deploy's outcome was delivered to an unrelated session and the asker never learned it. The rule
// that came out of it is this function's contract: never derive your own id from a directory, a file
// name or an env guess; take it from the harness and prove it.
//
// Two provenances are accepted, strongest first:
//  1. `harness-env`: WASM_AGENT_SESSION_ID (or WA_SESSION_ID) in the environment - the marker the
//     harness itself sets for a child process (scripts/mcp-client-core.mjs preserves it, code-mode
//     connectors see it).
//  2. `ledger-live-session`: a uuid the caller names with `--owner`, checked against this node's own
//     ledger (WASM_AGENT_DB): the session must exist, must not be ended, and must have been active
//     within `ownerMaxAge` seconds. A worktree name, a scratch directory or `$(basename $PWD)` is not
//     a uuid and is refused by name, before anything is queued.
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REFUSED_OWNER = [
  'The queue will not guess who you are: a wrong owner attributes the lease (and any reclaim of it)',
  'to the wrong session. Get the id from the harness, exactly as it reports it -',
  '`tool_call(session_worktree, {action:"status"})` prints `session_id`, and a sentinel wake line',
  '(`wake-start <id> ...`) carries it too - then pass it as `--owner <id>` (or set',
  'WASM_AGENT_SESSION_ID, which code-mode children already inherit).',
].join(' ');
// The row that names the process serving this session, or null. Read defensively: a ledger written
// by a binary older than this one has no `session_presence` table, and an unreadable ledger must not
// turn into a queue refusal about liveness that is really about schema.
function presenceOf(db, owner) {
  try {
    const table = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='session_presence'").get();
    if (!table) return null;
    return db.prepare('SELECT session_id,pid,boot,role,started_at,heartbeat_at FROM session_presence WHERE session_id=?').get(owner) || null;
  } catch { return null; }
}

export function resolveOwner({owner, ledger, ownerMaxAge = 900, env = process.env} = {}) {  const marker = env.WASM_AGENT_SESSION_ID || env.WA_SESSION_ID;
  if (marker) {
    if (owner && owner !== marker) {
      throw new QueueError(`owner_mismatch: --owner ${owner} is not this process's harness session ${marker} (WASM_AGENT_SESSION_ID)`, 75, 'owner_mismatch');
    }
    return {id: marker, source: 'harness-env', evidence: {variable: env.WASM_AGENT_SESSION_ID ? 'WASM_AGENT_SESSION_ID' : 'WA_SESSION_ID'}};
  }
  if (!owner) throw new QueueError(`owner_required: no harness session id in the environment. ${REFUSED_OWNER}`, 75, 'owner_required');
  if (!SESSION_ID.test(owner)) {
    throw new QueueError(`owner_not_a_session_id: '${owner}' is not a harness session id (expected a uuid). ${REFUSED_OWNER}`, 75, 'owner_not_a_session_id');
  }
  const ledgerPath = ledger || env.WA_LANDING_QUEUE_LEDGER || env.WASM_AGENT_DB
    || path.join(env.WASM_AGENT_HOME || env.USERPROFILE || env.HOME || os.homedir(), '.wasm-agent', 'memory.db');
  if (!fs.existsSync(ledgerPath)) {
    throw new QueueError(`owner_unverifiable: session ${owner} cannot be checked: no ledger at ${ledgerPath} (set WASM_AGENT_DB or WA_LANDING_QUEUE_LEDGER). ${REFUSED_OWNER}`, 75, 'owner_unverifiable');
  }
  let db;
  try { db = new DatabaseSync(ledgerPath, {readOnly: true}); } catch (error) {
    throw new QueueError(`owner_unverifiable: cannot read ${ledgerPath}: ${error.message}`, 75, 'owner_unverifiable');
  }
  try {
    const session = db.prepare('SELECT id,ended_at,updated_at,started_at FROM sessions WHERE id=?').get(owner);
    if (!session) {
      throw new QueueError(`owner_unknown_to_harness: no session ${owner} in ${ledgerPath}; that id is not a session on this node`, 75, 'owner_unknown_to_harness');
    }
    // Liveness is a running process, never a row's `ended_at` (measured 10/11: the queue refused a
    // live session because its ledger row was closed when the node restarted; a duplicate wake
    // closed another row while its turn was running; a piped `wa chat` closed its caller's own row
    // on the way out). The process that serves a session writes `session_presence` and keeps its
    // heartbeat fresh (lua/core/memory.lua), so that is the question asked first - and `ended_at`
    // is only evidence of an ending once no live process is left.
    const presence = presenceOf(db, owner);
    const heartbeat_age = presence ? Math.max(0, now() - Math.floor(Number(presence.heartbeat_at || 0))) : null;
    if (presence && heartbeat_age <= ownerMaxAge && pidAlive(Number(presence.pid))) {
      return {id: owner, source: 'live-process', evidence: {ledger: ledgerPath, pid: Number(presence.pid),
        boot: presence.boot || '', heartbeat_seconds_ago: heartbeat_age, role: presence.role || ''}};
    }
    if (session.ended_at !== null && session.ended_at !== undefined) {
      const why = presence
        ? `its last heartbeat was ${heartbeat_age}s ago from pid ${presence.pid}, which is not alive`
        : 'no session_presence row names a running process';
      throw new QueueError(`owner_ended: session ${owner} ended at ${new Date(Number(session.ended_at) * 1000).toISOString()} and ${why}; a lease is held by a live session`, 75, 'owner_ended');
    }
    const age = Math.max(0, now() - Math.floor(Number(session.updated_at || session.started_at || 0)));
    if (age > ownerMaxAge) {
      throw new QueueError(`owner_stale: session ${owner} has not been active for ${age}s (limit ${ownerMaxAge}s${presence ? `; its presence heartbeat is ${heartbeat_age}s old` : '; it has no session_presence row'}); confirm the id is your own`, 75, 'owner_stale');
    }
    return {id: owner, source: 'ledger-live-session', evidence: {ledger: ledgerPath, active_seconds_ago: age, session_started_at: session.started_at}};
  } finally { try { db.close(); } catch {} }
}

// ---- the canonical checkout ---------------------------------------------------------------------
//
// Requirement, measured on 2026-11-10 (session e0fc6da6): a session that holds no lease must not
// leave edits in the canonical checkout, because the next landing (and the deploy after it) is
// refused by that dirt for as long as it sits there. The queue therefore treats a dirty canonical
// tree as an owned resource: while a lease is held the dirt may be the holder's, and without one it
// belongs to nobody. It names the files either way.
export function canonicalDirt(canonical) {
  const result = git(canonical, ['status', '--porcelain=v1', '--untracked-files=normal']);
  if (result.status !== 0) {
    throw new QueueError(`cannot read the state of ${canonical}: ${String(result.stderr || '').trim()}`, 76, 'canonical_unreadable');
  }
  const lines = String(result.stdout || '').split('\n').filter(line => line.trim() !== '');
  return {
    dirty: lines.length > 0,
    files: lines.map(line => line.replace(/^..\s?/, '')).slice(0, 40),
    count: lines.length,
  };
}
export function describeDirt(dirt, limit = 12) {
  const shown = dirt.files.slice(0, limit).join(', ');
  return dirt.count > limit ? `${shown}, +${dirt.count - limit} more` : shown;
}

// ---- the queue ----------------------------------------------------------------------------------
export const STATES = ['waiting', 'granted', 'landed', 'abandoned', 'refused', 'reclaimed'];

export function holderOf(db, dir) {
  const row = db.prepare("SELECT * FROM queue WHERE state='granted' ORDER BY id LIMIT 1").get();
  if (!row) return null;
  return {...row, lease_held: leaseHeld(dir, row.lease)};
}

// The reclaim decision, and the one place a dead holder stops blocking the queue. It is automatic
// because the evidence is a fact the kernel owns (the lease is not held), not because a pid looks
// old; and it is never silent: every reclaim writes a `reclaimed` row to the log and a reason on the
// row itself, naming the pid, whether that pid is still alive, the boot it was recorded on, and how
// long it held.
//
// A holder that is ALIVE but whose lease is gone, or a holder whose lease is expired but whose
// process still runs, is NOT reclaimed here: two landers on one tree is the storm this exists to
// remove, so that case is reported and left to `reconcile --evidence` (or `--force-reclaim`, an
// explicit named decision that the holder's own token check turns into a refusal to push).
export function reclaimPass(db, dir) {
  const reclaimed = [];
  const rows = db.prepare("SELECT * FROM queue WHERE state='granted' ORDER BY id").all();
  for (const row of rows) {
    if (leaseHeld(dir, row.lease)) continue;
    const sameBoot = Boolean(row.boot) && row.boot === bootId() && row.host === hostName();
    const alive = sameBoot && pidAlive(row.pid);
    if (alive && now() - (row.started_at || row.created_at) < 60) continue; // a grant taking its lock
    if (alive) {
      // Alive, holding no lease: a contradiction the queue refuses to resolve by itself.
      db.prepare('UPDATE queue SET reason=? WHERE id=?')
        .run(`orphaned: pid ${row.pid} is alive on this boot but holds no lease ${row.lease}; the tree is not freed automatically`, row.id);
      continue;
    }
    const elapsed = now() - (row.started_at || row.created_at);
    const why = sameBoot
      ? `holder pid ${row.pid} is gone, lease ${row.lease} not held`
      : `holder pid ${row.pid} is not observable on this boot (recorded ${row.host}/${row.boot}, now ${hostName()}/${bootId()}), lease ${row.lease} not held`;
    const reason = `reclaimed after ${elapsed}s: ${why}`;
    db.prepare("UPDATE queue SET state='reclaimed', reason=?, ended_at=? WHERE id=? AND state='granted'").run(reason, now(), row.id);
    logRow(db, row.id, 'reclaimed', `${reason}; owner ${row.owner}, branch ${row.branch}, base ${row.base}`);
    reclaimed.push({id: row.id, owner: row.owner, reason});
  }
  return reclaimed;
}

// A recorded proof, keyed by the digest of the tree that was checked rather than by the landing that
// checked it. That is the whole point of the digest: the same test run covers every landing whose
// candidate tree has the same test-relevant inputs, however many times main moved in between - the
// cost session 883ffeda paid six times on 2026-11-10.
export function proofOf(db, digest) {
  return db.prepare('SELECT * FROM proofs WHERE digest=?').get(digest) || null;
}
export function recordProof(db, {digest, tree, by, command, log}) {
  db.prepare(`INSERT INTO proofs(digest,tree,verified_at,verified_by,command,log) VALUES(?,?,?,?,?,?)
              ON CONFLICT(digest) DO UPDATE SET tree=excluded.tree, verified_at=excluded.verified_at,
              verified_by=excluded.verified_by, command=excluded.command, log=excluded.log`)
    .run(digest, tree, now(), by, command || '', log || '');
}

// ---- the known-failures baseline ----------------------------------------------------------------
//
// `scripts/lib/landing-baseline.mjs` judges a run against one of these. The key is the triple
// (check command, machine, retest digest): the command because a different suite fails differently,
// the machine because the twelve red Lua checks on wasm_the_first are the installed node's component
// set being behind the tree, not a property of the commit, and the digest because two trees with the
// same check inputs cannot fail differently. A baseline from another machine is never reused: it
// would either tolerate a failure this machine does not have or refuse one it cannot help.
export const checkCommandKey = command => String(command || '').trim().replace(/\s+/g, ' ');

export function baselineOf(db, {digest, command, host = hostName()}) {
  const row = db.prepare('SELECT * FROM baselines WHERE digest=? AND chk=? AND host=?').get(digest, checkCommandKey(command), host);
  if (!row) return null;
  try { return {...JSON.parse(row.record), recorded_by: row.recorded_by, commit: row.commit_}; } catch { return null; }
}

export function recordBaseline(db, {digest, command, host = hostName(), commit, record, by}) {
  db.prepare(`INSERT INTO baselines(digest,chk,host,commit_,record,recorded_at,recorded_by) VALUES(?,?,?,?,?,?,?)
              ON CONFLICT(digest,chk,host) DO UPDATE SET commit_=excluded.commit_, record=excluded.record,
              recorded_at=excluded.recorded_at, recorded_by=excluded.recorded_by`)
    .run(digest, checkCommandKey(command), host, commit || '', JSON.stringify(record), now(), by || '');
}

export function queuePosition(db, id) {
  const waiting = db.prepare("SELECT id FROM queue WHERE state='waiting' ORDER BY id").all().map(r => r.id);
  const index = waiting.indexOf(id);
  return index < 0 ? 0 : index + 1;
}

export function waitingRows(db) {
  return db.prepare("SELECT id,owner,branch,created_at FROM queue WHERE state='waiting' ORDER BY id").all();
}

// Try to hand the lease to the lowest waiting row. Runs inside ONE immediate transaction, so two
// waiters can never both observe "no holder" and both claim the tree.
export function grantNext(db, dir, {nowS = now()} = {}) {
  db.exec('BEGIN IMMEDIATE');
  try {
    reclaimPass(db, dir);
    const holder = db.prepare("SELECT * FROM queue WHERE state='granted' ORDER BY id LIMIT 1").get();
    if (holder) { db.exec('COMMIT'); return null; }
    const next = db.prepare("SELECT * FROM queue WHERE state='waiting' ORDER BY id LIMIT 1").get();
    if (!next) { db.exec('COMMIT'); return null; }
    const started = nowS;
    const expires = started + (Number(next.lease_seconds) || 1800);
    db.prepare('UPDATE queue SET state=?, started_at=?, heartbeat_at=?, expires_at=? WHERE id=? AND state=?')
      .run('granted', started, started, expires, next.id, 'waiting');
    db.exec('COMMIT');
    return {...next, state: 'granted', started_at: started};
  } catch (error) { try { db.exec('ROLLBACK'); } catch {} throw error; }
}

// The holder's own liveness marker, and the check that keeps a revoked holder from pushing: every
// effect in `land` re-reads its row first, so a `reconcile`/`--force-reclaim` by a person turns into
// a refusal to touch main rather than two landers racing.
export function heartbeat(db, id, lease) {
  const row = db.prepare('SELECT * FROM queue WHERE id=?').get(id);
  if (!row) throw new QueueError(`no queue row ${id}`, 75, 'queue_row_missing');
  if (row.state !== 'granted' || row.lease !== lease) {
    throw new QueueError(`lease_lost: row #${id} is ${row.state} and its lease is ${row.lease === lease ? 'yours' : 'not yours'}; refusing to continue touching ${row.canonical}`, 75, 'lease_lost');
  }
  db.prepare('UPDATE queue SET heartbeat_at=?, expires_at=? WHERE id=?').run(now(), now() + (Number(row.lease_seconds) || 1800), id);
  return row;
}
