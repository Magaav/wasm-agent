#!/usr/bin/env node
// The deterministic reclaim pass: what this node can free, what it refuses to free, and why.
//
// WHY. On 2026-09-30 the disk reached 1.9 GB of 477 GB and a gate died 10.6 seconds into its build with
// `There is not enough space on the disk. (os error 112)`. Nothing reported the trend and nothing was
// allowed to reclaim anything, so the only repair was a person deleting directories by hand - which is
// also how a registration gets orphaned and a live tree gets removed. This is the pass that can be run by
// a job instead, on a stated rule, with every refusal named.
//
// WHAT IT DOES, IN ORDER.
//   1. Reports free space (before, and again after).
//   2. Expires the *bounded* temp families: entries in the OS temp directory whose name matches a family
//      some tracked script under `scripts/` actually mints, older than `--min-age-hours` (6 by default).
//      A family another lane bounds is left alone and named here: `wa-gate-home-*` (the gate's retained
//      home, kept for diagnostics by `scripts/test.sh`) and the merge lane's clones are *their* retention
//      rule, not this pass's.
//   3. Prunes `rust/target` inside a managed session worktree whose owning session has ended.
//
// WHAT IT NEVER TOUCHES (the refusal is the product). The canonical checkout (the only tree on `main`),
// the node's own worktree, every lane/role tree, any live session's worktree, the tree this pass runs in,
// any tree whose owning session cannot be proved ended, any tree a process holds, and anything a
// `.cargo-lock` says cargo is writing. A tree it cannot prove is printed with the proof it was missing -
// never skipped quietly, and never `rm -rf`-ed on a guess.
//
// It removes *derived build output* and temp scratch, never work: no commit, no branch, no tree, no
// registration. `--apply` is the only way anything is removed, and the proofs are re-read at the moment
// of removal; the default run is a report.
//
//   node scripts/reclaim-disk.mjs                  # report only (nothing is removed)
//   node scripts/reclaim-disk.mjs --apply          # expire and prune the provable subset
//   node scripts/reclaim-disk.mjs --min-age-hours 24
//   node scripts/reclaim-disk.mjs --protect <session-id|path>
//   node scripts/reclaim-disk.mjs --temp-dir DIR --state-dir DIR --repo DIR
//
// Exit code 0 when the pass ran (including when everything was refused: a refusal is a result, and the
// job's history should mean something), 1 when it could not prove the ground it stands on (no session
// store, not inside a git worktree) and therefore refused every candidate.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
// A managed session worktree's name is derived from the session id by `lua/core/workspaces.lua`: the id
// with every character that is not `[%w-]` removed (`clean_id`, line 273), then `wa-worktree-<clean_id>`
// for the directory (line 275) and `change/wa-session-<clean_id>` for the branch (line 274). A *child
// dispatch* session's id carries a role prefix (`child:dispatch:<uuid>`), so its clean_id is not a bare
// uuid and a name test written around a bare uuid - the shape `scripts/reap-worktrees.mjs` uses for its
// own recipe - does not match the trees this node actually allocates. The proof here is therefore the
// store's own row plus those two derived names, which is stricter than a pattern and matches every shape.
const MANAGED_DIR_RE = /^wa-worktree-[A-Za-z0-9-]+$/;
function cleanId(sessionId) { return String(sessionId).replace(/[^\w-]/g, ''); }

// Families whose retention belongs to another lane. Named here so this pass cannot become a second,
// disagreeing owner of someone else's rule.
const PROTECTED_TEMP_FAMILIES = [
  { prefix: 'wa-gate-home', why: "the gate's retained home: scripts/test.sh keeps it for diagnostics, and the lane that bounds gate homes owns that rule" },
  { prefix: 'wa-merge-lane', why: 'a merge-lane clone: scripts/merge-lane.mjs owns its retention' },
  { prefix: 'wa-lane-', why: 'a merge/gate lane scratch tree: its lane owns its retention' },
];

// Temp families this pass will never expire even though a script mints them, because their lifetime is a
// process's rather than a run's and the caller is still alive. Kept small on purpose.
const NEVER_EXPIRE = [
  { prefix: 'wa-sentinel-', why: 'the sentinel watches this path while it runs' },
];

function options(argv) {
  const stateFromEnv = process.env.WASM_AGENT_DB ? path.dirname(process.env.WASM_AGENT_DB) : null;
  const opts = {
    apply: false, quiet: false, minAgeHours: 6, limit: Infinity,
    repo: null, tempDir: os.tmpdir(), stateDir: null, db: null, report: null, protect: [],
  };
  opts.stateDir = stateFromEnv || process.env.WASM_AGENT_STATE_DIR || null;
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--apply') opts.apply = true;
    else if (a === '--quiet') opts.quiet = true;
    else if (a === '--min-age-hours') opts.minAgeHours = Number(argv[++i]);
    else if (a === '--limit') opts.limit = Number(argv[++i]);
    else if (a === '--repo') opts.repo = argv[++i];
    else if (a === '--temp-dir') opts.tempDir = argv[++i];
    else if (a === '--state-dir') opts.stateDir = argv[++i];
    else if (a === '--db') opts.db = argv[++i];
    else if (a === '--report') opts.report = argv[++i];
    else if (a === '--protect') opts.protect.push(argv[++i]);
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!Number.isFinite(opts.minAgeHours) || opts.minAgeHours < 0) throw new Error('--min-age-hours needs a number');
  return opts;
}

function run(cmd, args, { cwd, timeout = 180000 } = {}) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', windowsHide: true, timeout, maxBuffer: 256 * 1024 * 1024 });
  return { ok: r.status === 0 && !r.error, code: r.status, out: r.stdout || '', err: r.stderr || '', why: r.error ? String(r.error.message) : (r.status === 0 ? '' : `exit ${r.status}`) };
}

function norm(p) {
  let s = String(p || '').replace(/\\/g, '/').replace(/\/+$/, '');
  if (/^[A-Za-z]:\//.test(s)) s = s[0].toLowerCase() + s.slice(1).toLowerCase();
  return s;
}

function human(bytes) {
  if (!Number.isFinite(bytes)) return '?';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = bytes, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return `${v.toFixed(v < 10 && i > 0 ? 2 : 0)} ${units[i]}`;
}

function iso(seconds) {
  if (seconds === null || seconds === undefined) return '-';
  return new Date(Number(seconds) * 1000).toISOString().replace('T', ' ').slice(0, 16);
}

// Measured, not estimated: every file's size under a path (one walk, no shell).
function dirBytes(root) {
  let bytes = 0, files = 0;
  let st;
  try { st = fs.lstatSync(root); } catch { return { bytes: 0, files: 0 }; }
  if (!st.isDirectory()) return { bytes: st.size, files: 1 };
  if (st.isSymbolicLink()) return { bytes: 0, files: 0 };
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let handle;
    try { handle = fs.opendirSync(dir); } catch { continue; }
    try {
      let ent;
      while ((ent = handle.readSync())) {
        const full = `${dir}/${ent.name}`;
        if (ent.isDirectory()) { stack.push(full); continue; }
        try { bytes += fs.lstatSync(full).size; files += 1; } catch { /* vanished mid-walk: not ours to report */ }
      }
    } finally { try { handle.closeSync(); } catch { /* already closed */ } }
  }
  return { bytes, files };
}

function freeSpace(target) {
  const r = run('df', ['-Pk', target], { timeout: 60000 });
  if (!r.ok) return { error: `df -Pk ${target} failed: ${r.why} ${r.err.trim()}` };
  const line = r.out.trim().split('\n').pop() || '';
  const fields = line.split(/\s+/);
  // Filesystem 1024-blocks Used Available Capacity Mounted on - the mount may contain spaces.
  const totalKb = Number(fields[1]), availKb = Number(fields[3]);
  if (!Number.isFinite(totalKb) || !Number.isFinite(availKb)) return { error: `df said: ${line}` };
  return { totalBytes: totalKb * 1024, availableBytes: availKb * 1024, mount: fields.slice(5).join(' ') || target };
}

// ── the families this repository actually mints ──────────────────────────────────────────────────
// Read out of the tracked scripts rather than carried as a second list: the check in
// `scripts/check-temp-retention.mjs` fails a *new* unbounded family, and this pass expires the families
// already in the tree, so both read the same evidence and neither can drift into a private list. A name
// read out of a script is kept only if the temp directory really holds entries under it, so the list is
// what is on disk rather than what a regex would like to be true (`unknown` below is the honest
// remainder: entries no tracked script claims, which this pass leaves alone).
function mintedFamilies(repo, entries) {
  const listed = run('git', ['-C', repo, 'ls-files', '-z', 'scripts'], { timeout: 120000 });
  if (!listed.ok) throw new Error(`cannot list the tracked scripts of ${repo}: ${listed.why} ${listed.err.trim()}`);
  const files = listed.out.split('\0').filter(f => /\.(sh|bash|mjs|cjs|js|lua|ps1)$/.test(f));
  const candidates = new Map();
  // Two readings of the same line, because the commonest shell shape nests quotes: for
  // `GATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/wa-gate-home-XXXXXX")"` a paired-quote scan
  // *consumes* the inner opening quote as the outer literal's closing one and never sees the family at
  // all. So the name is also read directly, as whatever follows a temp root.
  const AFTER_TEMP_ROOT = /(?:\$TMPDIR|\$\{TMPDIR[^}]*\}|os\.tmpdir\(\)|\/tmp\/|%TEMP%|\$env:TEMP|Temp[\\/])[^A-Za-z\n]{0,8}([A-Za-z][A-Za-z0-9._-]{4,})/g;
  const prefixOf = (raw) => raw.replace(/^.*[\\/]/, '').trim()
    .replace(/\$\{[^}]*\}[\s\S]*$/, '').replace(/X{3,}[\s\S]*$/, '')
    .replace(/[^A-Za-z0-9._-]+$/, '').replace(/[-._]+$/, '');
  const offer = (raw, rel) => {
    const prefix = prefixOf(raw);
    if (prefix.length < 5 || /^(tmp|temp|temporary|sqlite|node|exit|joined)$/i.test(prefix)) return;
    if (!candidates.has(prefix)) candidates.set(prefix, rel);
  };
  for (const rel of files) {
    let text;
    try { text = fs.readFileSync(path.join(repo, rel), 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      // Either the line reaches a temp root, or a literal on it carries the nonce (`wa-x-XXXXXX`).
      if (!/os\.tmpdir\(\)|\$TMPDIR|\$\{TMPDIR|%TEMP%|\$env:TEMP|\/tmp\/|Temp[\\/]|X{3,}/.test(line)) continue;
      for (const m of line.matchAll(AFTER_TEMP_ROOT)) offer(m[1], rel);
      for (const m of line.matchAll(/["'`]([^"'`\n]{3,120})["'`]/g)) offer(m[1], rel);
    }
  }
  const families = new Map();
  for (const [prefix, rel] of candidates) {
    if (entries.some(name => name.startsWith(prefix))) families.set(prefix, rel);
  }
  families.candidates = candidates;
  return families;
}

function tempPass(opts) {
  let entries = [];
  try { entries = fs.readdirSync(opts.tempDir); } catch (e) { return { error: `cannot read ${opts.tempDir}: ${e.message}`, families: new Map() }; }
  const families = mintedFamilies(opts.repo, entries);
  const protectedFamilies = PROTECTED_TEMP_FAMILIES.map(entry => ({ ...entry, hits: 0, bytes: 0 }));
  const cutoff = Date.now() - opts.minAgeHours * 3600 * 1000;
  const expired = [], kept = [];
  let unknown = 0;
  for (const name of entries) {
    const full = path.join(opts.tempDir, name);
    let st;
    try { st = fs.lstatSync(full); } catch { continue; }
    const never = NEVER_EXPIRE.find(entry => name.startsWith(entry.prefix));
    if (never) { kept.push({ name, why: `never expired by rule: ${never.why}` }); continue; }
    const guard = protectedFamilies.find(entry => name.startsWith(entry.prefix));
    if (guard) { guard.hits += 1; continue; }
    const family = [...families.keys()].find(prefix => name.startsWith(prefix));
    if (!family) { unknown += 1; continue; }
    const ageMs = Date.now() - st.mtimeMs;
    const record = { name, family, mintedBy: families.get(family), ageHours: Number((ageMs / 3600000).toFixed(1)), bytes: 0 };
    if (st.mtimeMs > cutoff) { record.why = `fresh: younger than --min-age-hours ${opts.minAgeHours}`; kept.push(record); continue; }
    record.bytes = dirBytes(full).bytes;
    if (opts.apply && expired.length < opts.limit) {
      try {
        // A refusal is a result: a file another process holds is reported, not forced.
        fs.rmSync(full, { recursive: true, force: false, maxRetries: 1 });
        record.removed = true;
      } catch (e) { record.removed = false; record.why = `held or unremovable: ${e.message}`; kept.push(record); continue; }
    } else if (!opts.apply) record.removed = false;
    expired.push(record);
  }
  return { families, candidates: families.candidates.size, expired, kept, unknown, protectedFamilies, cutoff };
}

// ── the session store: whose tree is it, and has that session ended ──────────────────────────────
function readSessions(dbPath) {
  if (!fs.existsSync(dbPath)) return { error: `session store not found: ${dbPath}` };
  const boundQuery = "SELECT id, worktree, ended_at, workspace_state, workspace_branch FROM sessions WHERE worktree IS NOT NULL AND worktree <> ''";
  const liveRunQuery = 'SELECT DISTINCT session_id FROM runs WHERE ended_at IS NULL';
  try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(dbPath, { readOnly: true });
    const bound = db.prepare(boundQuery).all();
    const liveRuns = new Set(db.prepare(liveRunQuery).all().map(r => String(r.session_id)));
    db.close();
    return { bound, liveRuns, source: 'node:sqlite' };
  } catch (e) {
    const rows = (query) => {
      const r = run('sqlite3', ['-readonly', '-separator', '\t', '-noheader', dbPath, query], { timeout: 120000 });
      if (!r.ok) throw new Error(`sqlite3 failed: ${r.why} ${r.err.trim()}`);
      return r.out.split('\n').filter(l => l.length).map(l => l.split('\t'));
    };
    try {
      const bound = rows(boundQuery).map(([id, worktree, ended, state, branch]) => ({ id, worktree, ended_at: ended === '' ? null : Number(ended), workspace_state: state, workspace_branch: branch }));
      return { bound, liveRuns: new Set(rows(liveRunQuery).map(([id]) => id)), source: 'sqlite3' };
    } catch (e2) { return { error: `session store unreadable: ${e2.message}` }; }
  }
}

function worktreeList(repo) {
  const r = run('git', ['-C', repo, 'worktree', 'list', '--porcelain'], { timeout: 120000 });
  if (!r.ok) throw new Error(`git worktree list failed: ${r.why} ${r.err.trim()}`);
  const entries = [];
  for (const block of r.out.split(/\r?\n\r?\n/)) {
    if (!block.trim()) continue;
    const e = { locked: false, branch: '', head: '' };
    for (const line of block.split(/\r?\n/)) {
      const sp = line.indexOf(' ');
      const key = sp < 0 ? line : line.slice(0, sp);
      const val = sp < 0 ? '' : line.slice(sp + 1);
      if (key === 'worktree') e.path = val;
      else if (key === 'branch') e.branch = val.replace('refs/heads/', '');
      else if (key === 'HEAD') e.head = val;
      else if (key === 'locked') e.locked = true;
    }
    if (e.path) entries.push(e);
  }
  return entries;
}

// What a process is holding is not visible for every process on Windows and not at all on POSIX, so the
// proof that a target is not being written is the writer's own lock file plus the failure that `rmSync`
// reports if a file is held. Both are named in the output; neither is guessed.
function targetCandidate(entry, ctx) {
  const name = path.basename(entry.path);
  const t = { name, path: entry.path, branch: entry.branch, verdict: 'refused', reason: '', detail: '', bytes: 0 };
  const keep = (reason, detail) => ({ ...t, verdict: 'kept', reason, detail });
  const refuse = (reason, detail) => ({ ...t, verdict: 'refused', reason, detail });

  if (norm(entry.path) === norm(ctx.repo)) return keep('canonical_worktree', 'the only tree on main; never pruned here');
  if (ctx.protectedPaths.has(norm(entry.path))) return keep('protected_path', 'named by --protect or by this run');
  if (!norm(entry.path).startsWith(`${norm(ctx.stateDir)}/`)) return keep('outside_managed_area', `not under ${ctx.stateDir}: a lane or the node's own tree, which this pass does not own`);
  if (!MANAGED_DIR_RE.test(name)) return keep('not_a_managed_session_worktree', 'directory name is not wa-worktree-<session-uuid>');
  if (entry.locked) return refuse('locked_worktree', 'git marks this registration locked');
  const target = path.join(entry.path, 'rust', 'target');
  let st;
  try { st = fs.lstatSync(target); } catch { return keep('no_target', 'no rust/target in this tree: nothing to prune'); }
  if (!st.isDirectory() || st.isSymbolicLink()) return refuse('target_not_a_directory', `${target} is not a plain directory`);
  t.target = target;

  // the owning session - the only proof of ownership this pass accepts
  const rows = ctx.byWorktree.get(norm(entry.path));
  if (ctx.storeError) return refuse('session_store_unreadable', ctx.storeError);
  if (!rows) return refuse('missing_session_record', 'no session row binds this worktree: ownership is unproven');
  if (rows.length > 1) return refuse('ambiguous_session_record', `${rows.length} sessions bind this path`);
  const session = rows[0];
  t.session = session.id;
  t.sessionEnded = session.ended_at;
  if (session.ended_at === null || session.ended_at === undefined) return keep('live_session', `session ${session.id.slice(0, 8)} has not ended`);
  if (ctx.protectedSessions.has(norm(session.id))) return keep('protected_session', `session ${session.id.slice(0, 8)} named by --protect`);
  if (session.workspace_state !== 'allocated') return refuse(`workspace_state_${session.workspace_state || 'unset'}`, `session state is '${session.workspace_state}', not 'allocated'`);
  if (ctx.activeRuns.has(session.id)) return refuse('session_run_active', 'a run of this session has not ended');
  if (!entry.branch) return refuse('detached_head', 'the tree is not on a branch, so its tip cannot be proved');
  const clean = cleanId(session.id);
  if (!entry.branch.startsWith('change/wa-session-')) return keep('branch_not_a_managed_session_branch', `branch '${entry.branch}' is not change/wa-session-*`);
  if (name !== `wa-worktree-${clean}`) return refuse('worktree_name_mismatch', `directory is '${name}', the session's own name is 'wa-worktree-${clean}'`);
  if (entry.branch !== `change/wa-session-${clean}`) return refuse('branch_session_mismatch', `branch is '${entry.branch}', the session's own branch is 'change/wa-session-${clean}'`);
  if (norm(session.workspace_branch) !== norm(entry.branch)) return refuse('session_branch_mismatch', `session records '${session.workspace_branch}', tree is on '${entry.branch}'`);

  // cargo's own lock: a target being written is not a target to delete
  for (const lock of ['.cargo-lock', 'CACHEDIR.TAG.tmp']) {
    if (fs.existsSync(path.join(target, lock))) return refuse('target_locked', `${target}/${lock} exists: cargo may be writing this target`);
  }
  return { ...t, verdict: 'would-prune', reason: 'disposable', detail: '' };
}

function prunePass(opts, ctx) {
  const entries = worktreeList(ctx.repo);
  const findings = entries.map(entry => targetCandidate(entry, ctx));
  for (const f of findings) if (f.verdict === 'would-prune') f.bytes = dirBytes(f.target).bytes;
  const candidates = findings.filter(f => f.verdict === 'would-prune');
  if (opts.apply && !ctx.storeError) {
    const fresh = readSessions(ctx.db);
    if (fresh.error) { ctx.storeError = fresh.error; return { findings, candidates, applied: [], refusedAtApply: 0 }; }
    const byWorktree = new Map();
    for (const row of fresh.bound) {
      const key = norm(row.worktree);
      if (!byWorktree.has(key)) byWorktree.set(key, []);
      byWorktree.get(key).push(row);
    }
    ctx.byWorktree = byWorktree;
    ctx.activeRuns = fresh.liveRuns;
    const applied = [];
    let refusedAtApply = 0;
    for (const candidate of candidates) {
      if (applied.length >= opts.limit) break;
      const again = targetCandidate({ path: candidate.path, branch: candidate.branch, head: candidate.head, locked: false }, ctx);
      if (again.verdict !== 'would-prune') {
        refusedAtApply += 1;
        candidate.recheck = { reason: again.reason, detail: again.detail };
        continue;
      }
      const before = dirBytes(candidate.target).bytes;
      try {
        fs.rmSync(candidate.target, { recursive: true, force: false, maxRetries: 1 });
        candidate.bytes = before;
        candidate.result = { removed: true };
        applied.push(candidate);
      } catch (e) {
        // Never a fallback: a target that cannot be removed is reported with the error it gave.
        candidate.result = { removed: false, error: e.message };
        refusedAtApply += 1;
      }
    }
    return { findings, candidates, applied, refusedAtApply };
  }
  return { findings, candidates, applied: [], refusedAtApply: 0 };
}

function main() {
  const opts = options(process.argv.slice(2));
  const say = (line = '') => process.stdout.write(`${line}\n`);
  const start = run('git', ['rev-parse', '--show-toplevel'], { cwd: opts.repo || process.cwd() });
  if (!start.ok) throw new Error(`not inside a git worktree: ${start.why}`);
  const cwdTree = path.resolve(start.out.trim());
  if (!opts.repo) opts.repo = path.resolve((worktreeList(cwdTree)[0] || {}).path || cwdTree);
  if (!opts.stateDir) opts.stateDir = path.resolve(path.join(os.homedir(), '.wasm-agent'));
  if (!opts.db) opts.db = process.env.WASM_AGENT_DB || path.join(opts.stateDir, 'memory.db');

  const protectedPaths = new Set([norm(opts.repo), norm(cwdTree)]);
  const protectedSessions = new Set();
  for (const p of opts.protect) {
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(p)) protectedSessions.add(norm(p));
    else protectedPaths.add(norm(path.resolve(p)));
  }

  say(`disk reclaim — ${opts.apply ? 'APPLY' : 'report only (nothing is removed without --apply)'}`);
  say('');
  say(`repo:      ${opts.repo}`);
  say(`state dir: ${opts.stateDir}`);
  say(`temp dir:  ${opts.tempDir}   (entries older than ${opts.minAgeHours} h are expired; nothing else is)`);
  const before = freeSpace(opts.repo);
  say(`free before: ${before.error ? `UNMEASURABLE: ${before.error}` : `${human(before.availableBytes)} of ${human(before.totalBytes)} on ${before.mount}`}`);
  say('');

  // 1. temp families
  const temps = tempPass(opts);
  say(`1. bounded temp families ${temps.error ? `— SKIPPED: ${temps.error}` : `(${temps.families.size} families named by this repository's scripts and present in ${opts.tempDir}, of ${temps.candidates} names read)`}`);
  if (!temps.error) {
    const byFamily = new Map();
    for (const record of temps.expired) {
      const group = byFamily.get(record.family) || { family: record.family, n: 0, bytes: 0, oldest: Infinity, mintedBy: record.mintedBy, removed: 0 };
      group.n += 1; group.bytes += record.bytes; group.removed += record.removed ? 1 : 0;
      if (group.oldest > record.ageHours) group.oldest = record.ageHours;
      byFamily.set(record.family, group);
    }
    say(`   ${opts.apply ? 'expired' : 'would expire'}: ${temps.expired.length} entries, ${human(temps.expired.reduce((a, r) => a + r.bytes, 0))} — ${opts.apply ? 'removed' : 'measured'} (families, oldest first):`);
    for (const group of [...byFamily.values()].sort((a, b) => b.bytes - a.bytes).slice(0, 20)) {
      say(`     ${group.family}*  n=${group.n}  ${human(group.bytes)}  oldest=${group.oldest.toFixed(0)}h  minted by ${group.mintedBy}${opts.apply ? `  removed=${group.removed}` : ''}`);
    }
    say(`   kept: ${temps.kept.length} entries (fresh, or never expired by rule) — named below`);
    for (const record of temps.kept.slice(0, 10)) say(`     KEEP   ${record.name}  — ${record.why}`);
    if (temps.kept.length > 10) say(`     ... and ${temps.kept.length - 10} more fresh entries of the same families`);
    for (const guard of temps.protectedFamilies) {
      if (guard.hits) say(`   KEEP   ${guard.prefix}*  n=${guard.hits}  — another lane's retention rule: ${guard.why}`);
    }
    say(`   not matched to a known family (left alone): ${temps.unknown} entries`);
  }
  say('');

  // 2. rust/target in worktrees whose session ended
  const ctx = {
    repo: opts.repo, stateDir: path.resolve(opts.stateDir), db: path.resolve(opts.db),
    protectedPaths, protectedSessions, byWorktree: new Map(), activeRuns: new Set(), storeError: '',
  };
  const sessions = readSessions(ctx.db);
  if (sessions.error) ctx.storeError = sessions.error;
  else {
    for (const row of sessions.bound) {
      const key = norm(row.worktree);
      if (!ctx.byWorktree.has(key)) ctx.byWorktree.set(key, []);
      ctx.byWorktree.get(key).push(row);
    }
    ctx.activeRuns = sessions.liveRuns;
  }
  say(`2. rust/target in ended sessions' worktrees`);
  say(`   session db: ${ctx.db}${sessions.error ? `  UNREADABLE: ${sessions.error} (every candidate is refused)` : `  ${sessions.source}: ${sessions.bound.length} sessions bind a worktree`}`);
  const prune = prunePass(opts, ctx);
  const buckets = { 'would-prune': 'PRUNE', kept: 'KEEP', refused: 'REFUSE' };
  for (const verdict of ['would-prune', 'kept', 'refused']) {
    const rows = prune.findings.filter(f => f.verdict === verdict);
    if (!rows.length) continue;
    const total = rows.reduce((a, f) => a + (f.bytes || 0), 0);
    say(`   ${buckets[verdict]} (n=${rows.length}${verdict === 'would-prune' ? `, ${human(total)} measured` : ''})`);
    for (const row of rows) {
      say(`     ${buckets[verdict]} ${row.name.slice(0, 60)}  ${row.reason}${row.detail ? ` — ${row.detail}` : ''}${row.bytes ? `  ${human(row.bytes)}` : ''}${row.recheck ? `  (refused again at ${row.recheck.reason})` : ''}${row.result && row.result.removed === false ? `  FAILED to remove: ${row.result.error}` : ''}`);
    }
  }
  const hist = (verdict) => {
    const m = new Map();
    for (const f of prune.findings.filter(x => x.verdict === verdict)) m.set(f.reason, (m.get(f.reason) || 0) + 1);
    return [...m.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}=${v}`).join(' ') || '(none)';
  };
  say(`   reasons kept:     ${hist('kept')}`);
  say(`   reasons refused:  ${hist('refused')}`);
  say(`   ${opts.apply ? 'pruned' : 'disk that would be freed'}: ${human(prune.candidates.reduce((a, f) => a + (f.bytes || 0), 0))} across ${prune.candidates.length} target(s); ${opts.apply ? `${prune.applied.length} removed, ${prune.refusedAtApply} refused at removal time` : 'nothing removed (--apply is the only way)'}`);
  say('');

  const after = freeSpace(opts.repo);
  say(`free after:  ${after.error ? `UNMEASURABLE: ${after.error}` : `${human(after.availableBytes)} of ${human(after.totalBytes)} on ${after.mount}`}`);
  if (!before.error && !after.error) say(`freed by this pass: ${human(Math.max(0, after.availableBytes - before.availableBytes))} (free space moved from other writers too)`);

  const result = {
    when: new Date().toISOString(),
    apply: opts.apply,
    minAgeHours: opts.minAgeHours,
    free: { before: before.error ? { error: before.error } : { availableBytes: before.availableBytes, totalBytes: before.totalBytes, mount: before.mount }, after: after.error ? { error: after.error } : { availableBytes: after.availableBytes, totalBytes: after.totalBytes, mount: after.mount } },
    temp: temps.error ? { error: temps.error } : {
      expired: temps.expired.map(r => ({ name: r.name, family: r.family, ageHours: r.ageHours, bytes: r.bytes, removed: r.removed === true })),
      kept: temps.kept.map(r => ({ name: r.name, family: r.family || null, why: r.why })),
      protected: temps.protectedFamilies.filter(g => g.hits).map(g => ({ prefix: g.prefix, n: g.hits, why: g.why })),
      unknown: temps.unknown,
    },
    targets: prune.findings.map(f => ({ name: f.name, path: f.path, verdict: f.verdict, reason: f.reason, detail: f.detail, session: f.session || null, ended: f.sessionEnded ?? null, bytes: f.bytes, result: f.result || null })),
    freedBytes: prune.applied.reduce((a, f) => a + (f.bytes || 0), 0) + temps.expired.reduce((a, r) => a + (r.removed ? r.bytes : 0), 0),
  };
  const reportPath = opts.report === null ? path.join(opts.stateDir, 'disk', `reclaim-${new Date().toISOString().replace(/[:.]/g, '-')}${opts.apply ? '-apply' : ''}.json`) : opts.report;
  try {
    fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    fs.writeFileSync(reportPath, `${JSON.stringify(result, null, 2)}\n`);
    say(`report: ${reportPath}`);
  } catch (e) { say(`report NOT written (${e.message})`); }

  return ctx.storeError ? 1 : 0;
}

try {
  process.exitCode = main();
} catch (e) {
  process.stderr.write(`reclaim-disk: ${e.stack || e.message}\n`);
  process.exitCode = 1;
}
