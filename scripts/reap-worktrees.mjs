#!/usr/bin/env node
// Reap the session worktrees this factory forgot to collect - and prove every tree first.
//
// WHY THIS EXISTS. Allocation is transactional; collection is not. `lua/core/workspaces.lua`
// hands an isolated session a linked worktree at <state>/wa-worktree-<session> on the branch
// `change/wa-session-<session>`, and the only thing that ever removed one was the session's own
// `session_worktree release`. A session that ends without releasing leaves the tree, its
// registration in `.git/worktrees/<name>` and its local branch behind, and the next allocation
// does not reuse any of them - the counts only climb. Measured on 2026-09-29: 1376 worktree
// registrations, 1355 local branches, 1328 directories. Hand-tidying made it worse in a specific
// way: deleting a directory by hand leaves the registration, so `git worktree list` grows even
// when the disk does not.
//
// THE RECIPE, which is the whole of what this tool implements:
//   never touch  the primary/canonical checkout (the only tree on `main`), the node's own
//                worktree, any lane/role tree, and any live session's worktree - including the
//                tree this script is running in;
//   reap only    a managed session worktree whose branch tip is reachable from a PUSHED ref,
//                whose owning session is ended, that no process holds, whose
//                `git status --porcelain` is empty, and whose gitdir is not itself acting as a
//                primary (no `worktrees/` inside it);
//   order        `git worktree remove` first, `git branch -d` second.
//
// REFUSAL IS A RESULT. A tree this run cannot prove disposable is printed with the reason and the
// evidence and left alone - never skipped quietly. There is deliberately no fallback looser than
// the recipe: no `rm -rf`, no `git worktree remove --force`, no `git branch -D`, no "assume the
// session ended because the tree is old". Default is a report; `--apply` is the only way anything
// is removed, and even then each candidate is proved again at the moment of removal.
//
//   node scripts/reap-worktrees.mjs                  # report only, one line per tree
//   node scripts/reap-worktrees.mjs --apply          # reap the provably safe subset
//   node scripts/reap-worktrees.mjs --quiet          # summary only
//   node scripts/reap-worktrees.mjs --protect <session-id|path>   # add a protection
//   node scripts/reap-worktrees.mjs --offline        # do not ask origin; refuse everything
//   node scripts/reap-worktrees.mjs --require-holder-probe   # refuse when no process probe exists
//
// Exit code is 0 when the report/apply ran, 1 when a run could not prove the ground it stands on
// (no session store, no pushed refs) and therefore refused every candidate.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

// The recipe's exclusion list, by name: branches queued for an imminent landing (they are pushed
// today - that is why they are listed) plus the merge lane's own branch. Matched by prefix so the
// list stays exactly as the review wrote it.
const PROTECTED_SESSION_PREFIXES = [
  '317cca79', '7bacf15e', '7db14e40', '95e62f72', '08cb06ff',
  'e6bfc741', 'e843b90f', 'c1f9b78a', '33b4e818',
];
const MANAGED_DIR_RE = /^wa-worktree-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_BRANCH_RE = /^change\/wa-session-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;

function options(argv) {
  const stateFromEnv = process.env.WASM_AGENT_DB ? path.dirname(process.env.WASM_AGENT_DB) : null;
  const opts = {
    apply: false, quiet: false, offline: false, requireProbe: false,
    repo: null,
    stateDir: stateFromEnv || process.env.WASM_AGENT_STATE_DIR || path.join(os.homedir(), '.wasm-agent'),
    db: process.env.WASM_AGENT_DB || null,
    report: null, limit: Infinity, protect: [],
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--apply') opts.apply = true;
    else if (a === '--quiet') opts.quiet = true;
    else if (a === '--offline') opts.offline = true;
    else if (a === '--require-holder-probe') opts.requireProbe = true;
    else if (a === '--repo') opts.repo = argv[++i];
    else if (a === '--state-dir') opts.stateDir = argv[++i];
    else if (a === '--db') opts.db = argv[++i];
    else if (a === '--report') opts.report = argv[++i];
    else if (a === '--protect') opts.protect.push(argv[++i]);
    else if (a === '--limit') opts.limit = Number(argv[++i]);
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!opts.db) opts.db = path.join(opts.stateDir, 'memory.db');
  return opts;
}

function run(cmd, args, { cwd, timeout = 180000 } = {}) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', windowsHide: true, timeout, maxBuffer: 512 * 1024 * 1024 });
  return {
    ok: r.status === 0 && !r.error,
    code: r.status,
    out: r.stdout || '',
    err: r.stderr || '',
    why: r.error ? String(r.error.message) : (r.status === 0 ? '' : `exit ${r.status}`),
  };
}

// One path identity: separators, trailing slash, and (only for Windows paths, where the filesystem
// is case-insensitive) case. The session store and git disagree about `C:\x/y` vs `C:/x/y`.
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
  return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

function iso(seconds) {
  if (seconds === null || seconds === undefined) return '-';
  return new Date(Number(seconds) * 1000).toISOString().replace('T', ' ').slice(0, 16);
}

// Measured, not estimated: every file's size under the tree, plus the worktree's admin directory
// (`.git/worktrees/<name>`, which is what `git worktree remove` also deletes).
function dirBytes(root) {
  let bytes = 0, files = 0;
  const stack = [];
  try { if (!fs.statSync(root).isDirectory()) return { bytes: fs.statSync(root).size, files: 1 }; } catch { return { bytes: 0, files: 0 }; }
  stack.push(root);
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

// ── the session store: who owns a worktree, and whether that session ended ──────────────────────
// node:sqlite first (no external dependency), sqlite3(1) as the fallback. Neither available is not
// a reason to guess: it is a reason to refuse every candidate.
function readSessions(dbPath) {
  if (!fs.existsSync(dbPath)) return { error: `session store not found: ${dbPath}` };
  const boundQuery = 'SELECT id, worktree, ended_at, workspace_state, workspace_branch FROM sessions WHERE worktree IS NOT NULL AND worktree <> \'\'';
  const liveRunQuery = 'SELECT DISTINCT session_id FROM runs WHERE ended_at IS NULL';
  const totalQuery = 'SELECT count(*) FROM sessions';
  try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(dbPath, { readOnly: true });
    const bound = db.prepare(boundQuery).all();
    const liveRuns = new Set(db.prepare(liveRunQuery).all().map((r) => String(r.session_id)));
    const total = Number(db.prepare(totalQuery).get()['count(*)']);
    db.close();
    return { bound, liveRuns, total, source: 'node:sqlite' };
  } catch (e) {
    const rows = (query) => {
      const r = run('sqlite3', ['-readonly', '-separator', '\t', '-noheader', dbPath, query], { timeout: 120000 });
      if (!r.ok) throw new Error(`sqlite3 failed: ${r.why} ${r.err.trim()}`);
      return r.out.split('\n').filter((l) => l.length).map((l) => l.split('\t'));
    };
    try {
      const bound = rows(boundQuery).map(([id, worktree, ended, state, branch]) => ({
        id, worktree, ended_at: ended === '' ? null : Number(ended), workspace_state: state, workspace_branch: branch,
      }));
      const liveRuns = new Set(rows(liveRunQuery).map(([id]) => id));
      const total = Number(rows(totalQuery)[0][0]);
      return { bound, liveRuns, total, source: 'sqlite3' };
    } catch (e2) {
      return { error: `session store unreadable: ${e2.message}` };
    }
  }
}

// ── what origin actually has (read-only; never a fetch, so no local ref moves) ───────────────────
function pushedHeads(repo, offline) {
  if (offline) return { error: 'offline: origin was not asked, so no tip can be proved pushed' };
  const r = run('git', ['-C', repo, 'ls-remote', '--heads', 'origin'], { timeout: 120000 });
  if (!r.ok) return { error: `git ls-remote --heads origin failed: ${r.why} ${r.err.trim()}` };
  const heads = [];
  for (const line of r.out.split('\n')) {
    const m = /^([0-9a-f]{40})\trefs\/heads\/(.+)$/.exec(line.trim());
    if (m) heads.push({ sha: m[1], ref: m[2] });
  }
  if (!heads.length) return { error: 'origin advertises no heads' };
  const reachable = new Set();
  for (const h of heads) {
    const rev = run('git', ['-C', repo, 'rev-list', h.sha], { timeout: 180000 });
    if (!rev.ok) return { error: `cannot walk ${h.ref} (${h.sha.slice(0, 8)}): ${rev.why}` };
    for (const sha of rev.out.split('\n')) if (sha) reachable.add(sha);
  }
  return { heads, reachable };
}

// ── who holds a tree ────────────────────────────────────────────────────────────────────────────
// One enumeration, matched locally - a probe per candidate would be 1376 process spawns. Windows
// reports an image path and a command line, not a working directory, so a process whose cwd is
// inside a candidate but whose argv does not name it is not visible here; the removal step is the
// backstop (a held file makes `git worktree remove` fail loudly). POSIX reports neither, and says so.
function processProbe() {
  if (process.platform === 'win32') {
    const ps = run('powershell', ['-NoProfile', '-NonInteractive', '-Command',
      'Get-CimInstance Win32_Process | Select-Object ProcessId,Name,ExecutablePath,CommandLine | ConvertTo-Json -Compress'],
      { timeout: 120000 });
    if (!ps.ok) return { available: false, why: `Get-CimInstance failed: ${ps.why} ${ps.err.trim()}` };
    let rows = [];
    try {
      const parsed = JSON.parse(ps.out);
      rows = Array.isArray(parsed) ? parsed : [parsed];
    } catch (e) { return { available: false, why: `process list unparsable: ${e.message}` }; }
    const text = rows.map((r) => norm(`${r.CommandLine || ''} ${r.ExecutablePath || ''} ${r.Name || ''}`));
    return { available: true, detail: `${rows.length} processes inspected (command line + image path)`, text };
  }
  const ps = run('ps', ['-eo', 'pid,args'], { timeout: 60000 });
  if (!ps.ok) return { available: false, why: `ps failed: ${ps.why}` };
  return { available: true, holdable: false, detail: 'ps inspected (argv only; a working directory is not observable on this platform)', text: ps.out.split('\n').map(norm) };
}

function holderOf(probe, treePath) {
  if (!probe.available) return null;
  const needle = norm(treePath);
  for (const line of probe.text) if (line.includes(needle)) return line.trim().slice(0, 160);
  return null;
}

// ── one registration ────────────────────────────────────────────────────────────────────────────
function worktreeList(repo) {
  const r = run('git', ['-C', repo, 'worktree', 'list', '--porcelain'], { timeout: 120000 });
  if (!r.ok) throw new Error(`git worktree list failed: ${r.why} ${r.err.trim()}`);
  const entries = [];
  for (const block of r.out.split(/\r?\n\r?\n/)) {
    if (!block.trim()) continue;
    const e = { locked: false, prunable: false, detached: false, branch: '', head: '' };
    for (const line of block.split(/\r?\n/)) {
      const sp = line.indexOf(' ');
      const key = sp < 0 ? line : line.slice(0, sp);
      const val = sp < 0 ? '' : line.slice(sp + 1);
      if (key === 'worktree') e.path = val;
      else if (key === 'HEAD') e.head = val;
      else if (key === 'branch') e.branch = val.replace('refs/heads/', '');
      else if (key === 'detached') e.detached = true;
      else if (key === 'locked') e.locked = true;
      else if (key === 'prunable') e.prunable = true;
    }
    if (e.path) entries.push(e);
  }
  return entries;
}

function gitdirOf(treePath, primaryGitDir) {
  const dotGit = path.join(treePath, '.git');
  let st;
  try { st = fs.statSync(dotGit); } catch { return { error: '.git is missing or unreadable' }; }
  if (st.isDirectory()) return { error: '.git is a directory: this is a checkout of its own, not a linked worktree' };
  let content;
  try { content = fs.readFileSync(dotGit, 'utf8'); } catch (e) { return { error: `.git unreadable: ${e.message}` }; }
  const m = /^gitdir:\s*(.+)$/m.exec(content);
  if (!m) return { error: '.git does not name a gitdir' };
  let gitdir = m[1].trim();
  if (!path.isAbsolute(gitdir)) gitdir = path.resolve(treePath, gitdir);
  if (!norm(gitdir).startsWith(`${norm(primaryGitDir)}/worktrees/`)) {
    return { error: `gitdir is not under the primary's worktrees/: ${gitdir}` };
  }
  return { gitdir };
}

// The verdict for one registered worktree. Every branch of this function either proves the tree
// disposable ('would-reap') or names why it is not; there is no implicit fall-through.
function verify(entry, ctx) {
  const name = path.basename(entry.path);
  const t = { name, path: entry.path, branch: entry.branch, tip: entry.head, verdict: 'refused', reason: '', detail: '' };
  const protect = (reason, detail) => ({ ...t, verdict: 'protected', reason, detail });
  const refuse = (reason, detail) => ({ ...t, verdict: 'refused', reason, detail });

  // never touch: the primary checkout, the tree this script runs in, anything --protect names
  if (norm(entry.path) === norm(ctx.primary)) return protect('primary_worktree', 'the canonical checkout; the only tree on main');
  if (ctx.protectedPaths.has(norm(entry.path))) return protect('protected_path', 'named by --protect or by the invocation context');
  if (!norm(entry.path).startsWith(`${norm(ctx.stateDir)}/`)) return protect('outside_managed_area', `not under the managed area ${ctx.stateDir}`);
  if (!MANAGED_DIR_RE.test(name)) return protect('not_a_managed_session_worktree', 'directory name is not wa-worktree-<session-uuid>');
  if (entry.locked) return refuse('locked_worktree', 'git marks this registration locked (worktree list: locked)');

  // a tree that acts as a primary carries its own worktrees/ - removing it would take those with it
  const gd = gitdirOf(entry.path, ctx.primaryGitDir);
  if (gd.error) return refuse('gitdir_unproven', gd.error);
  const nested = path.join(gd.gitdir, 'worktrees');
  try {
    if (fs.existsSync(nested) && fs.readdirSync(nested).length) {
      return refuse('acts_as_primary', `${nested} is not empty: this tree has worktrees of its own`);
    }
  } catch (e) { return refuse('gitdir_unproven', `cannot read ${nested}: ${e.message}`); }

  // the owning session record - the only proof of ownership this tool accepts. An unreadable store
  // is not the same fact as a missing record, and it is not a reason to reap.
  const rows = ctx.byWorktree.get(norm(entry.path));
  if (ctx.storeError) return refuse('session_store_unreadable', ctx.storeError);
  if (!rows) return refuse('missing_session_record', 'no session row binds this worktree: ownership is unproven');
  if (rows.length > 1) return refuse('ambiguous_session_record', `${rows.length} sessions bind this path: ${rows.map((r) => r.id.slice(0, 8)).join(', ')}`);
  const session = rows[0];
  t.session = session.id;
  t.sessionEnded = session.ended_at;
  t.workspaceState = session.workspace_state;
  if (session.ended_at === null || session.ended_at === undefined) return protect('live_session', `session ${session.id.slice(0, 8)} has not ended`);
  if (ctx.protectedSessions.has(session.id)) return protect('protected_path', `session ${session.id.slice(0, 8)} named by --protect`);
  if (session.workspace_state !== 'allocated') return refuse(`workspace_state_${session.workspace_state || 'unset'}`, `session state is '${session.workspace_state}', not 'allocated'`);
  if (ctx.activeRuns.has(session.id)) return refuse('session_run_active', 'a run of this session has not ended');
  if (entry.detached || !entry.branch) return refuse('detached_head', 'the tree is not on a branch, so nothing can be proved about the tip');
  if (norm(session.workspace_branch) !== norm(entry.branch)) {
    return refuse('session_branch_mismatch', `session records '${session.workspace_branch}', tree is on '${entry.branch}'`);
  }

  const m = SESSION_BRANCH_RE.exec(entry.branch);
  if (!m) return protect('branch_not_a_managed_session_branch', `branch '${entry.branch}' is not change/wa-session-<uuid>`);
  if (norm(m[1]) !== norm(session.id)) return refuse('branch_session_mismatch', `branch names ${m[1].slice(0, 8)}, owning session is ${session.id.slice(0, 8)}`);
  if (ctx.protectedPrefixes.some((p) => norm(m[1]).startsWith(norm(p)))) {
    return protect('protected_branch_name', `change/wa-session-${m[1].slice(0, 8)}-* is on the do-not-reap list (imminent landing)`);
  }

  // no process holds it
  if (fs.existsSync(path.join(gd.gitdir, 'index.lock'))) return refuse('lock_present', `${gd.gitdir}/index.lock exists: a git command is running here`);
  if (fs.existsSync(path.join(gd.gitdir, 'HEAD.lock'))) return refuse('lock_present', `${gd.gitdir}/HEAD.lock exists: a git command is running here`);
  if (ctx.probe.available) {
    const held = holderOf(ctx.probe, entry.path);
    if (held) return refuse('held_by_process', `a process names this path: ${held}`);
  }

  // clean, by the same reading the review used (`--ignored` is reported, not required: reproducible
  // build output is not work, and refusing on it would refuse almost every tree)
  const status = run('git', ['-C', entry.path, 'status', '--porcelain', '--ignored', '--untracked-files=all'], { timeout: 120000 });
  if (!status.ok) return refuse('status_unreadable', `git status failed: ${status.why} ${status.err.trim().slice(0, 120)}`);
  const lines = status.out.split(/\r?\n/).filter((l) => l.length);
  const dirt = lines.filter((l) => !l.startsWith('!! '));
  const ignored = lines.length - dirt.length;
  t.ignored = ignored;
  if (dirt.length) return refuse('dirty_tree', `${dirt.length} uncommitted/untracked entry(ies): ${dirt.slice(0, 3).join(' | ').slice(0, 200)}`);

  // Without a holder probe, "no process holds it" is unobserved rather than proved. The default
  // proceeds and says so (a held file still makes `git worktree remove` fail loudly, and that step
  // is not the one that can lose work); --require-holder-probe makes the gap a refusal instead. The
  // gate sits after the checks that have something more specific to say, so a dirty tree is still
  // reported as dirty rather than as unprovable.
  if (ctx.requireProbe && !ctx.probe.available) return refuse('holder_probe_unavailable', ctx.probe.why);

  // the tip is already in something that was pushed: verified against origin's advertised heads
  if (!ctx.pushed.heads) return refuse('pushed_refs_unproven', ctx.pushed.error);
  if (!ctx.pushed.reachable.has(entry.head)) {
    const exact = ctx.pushed.heads.find((h) => h.sha === entry.head);
    return refuse('tip_not_reachable_from_pushed_ref', `tip ${entry.head.slice(0, 8)} is not an ancestor of any pushed head${exact ? ` (it is exactly origin/${exact.ref})` : ''}`);
  }
  t.pushedBy = ctx.pushed.heads.filter((h) => h.sha === entry.head).map((h) => `origin/${h.ref}`).join(',') || 'origin/main';
  return { ...t, verdict: 'would-reap', reason: 'disposable', detail: '' };
}

function measure(t, ctx) {
  const tree = dirBytes(t.path);
  let admin = { bytes: 0, files: 0 };
  const gd = gitdirOf(t.path, ctx.primaryGitDir);
  if (!gd.error) admin = dirBytes(gd.gitdir);
  t.bytes = tree.bytes + admin.bytes;
  t.treeBytes = tree.bytes;
  t.adminBytes = admin.bytes;
  t.files = tree.files;
  return t;
}

function counts(repo, stateDir) {
  const list = worktreeList(repo);
  const branches = run('git', ['-C', repo, 'for-each-ref', '--format=%(refname:short)', 'refs/heads'], { timeout: 120000 });
  const all = branches.ok ? branches.out.split('\n').filter(Boolean) : [];
  let dirs = [];
  try { dirs = fs.readdirSync(stateDir).filter((n) => MANAGED_DIR_RE.test(n)); } catch { dirs = []; }
  const registered = new Set(list.map((e) => norm(e.path)));
  return {
    registrations: list.length,
    branched: all.length,
    changeBranches: all.filter((b) => b.startsWith('change/')).length,
    dirs: dirs.length,
    unregisteredDirs: dirs.filter((d) => !registered.has(norm(path.join(stateDir, d)))).length,
  };
}

function main() {
  const opts = options(process.argv.slice(2));
  // --quiet keeps the summary and drops the one-line-per-tree evidence, which is what the report
  // file is for; it never drops a refusal's reason from the summary, which is a count.
  const say = (line = '') => { process.stdout.write(`${line}\n`); };
  const perTree = (line = '') => { if (!opts.quiet) process.stdout.write(`${line}\n`); };

  // the primary worktree: the first registration of the repo containing the cwd (or --repo)
  const start = (run('git', ['rev-parse', '--show-toplevel'], { cwd: opts.repo || process.cwd() }));
  if (!start.ok) throw new Error(`not inside a git worktree: ${start.why}`);
  const cwdTree = path.resolve(start.out.trim());
  const repo = path.resolve(opts.repo || (worktreeList(cwdTree)[0] || {}).path || cwdTree);
  const primaryGitDir = (() => {
    const r = run('git', ['-C', repo, 'rev-parse', '--absolute-git-dir']);
    if (!r.ok) throw new Error(`cannot resolve the primary git dir: ${r.why}`);
    return path.resolve(r.out.trim());
  })();
  const primaryBranch = run('git', ['-C', repo, 'symbolic-ref', '--short', 'HEAD']).out.trim();

  const protectedPaths = new Set([norm(repo), norm(cwdTree)]);
  const protectedSessions = new Set();
  for (const p of opts.protect) {
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(p)) protectedSessions.add(norm(p));
    else protectedPaths.add(norm(path.resolve(p)));
  }

  say(`worktree reap — ${opts.apply ? 'APPLY' : 'report only (nothing will be removed without --apply)'}`);
  say('');
  say(`repo:        ${repo}  (primary worktree, branch ${primaryBranch})`);
  say(`state dir:   ${path.resolve(opts.stateDir)}`);
  const before = counts(repo, opts.stateDir);

  const sessions = readSessions(path.resolve(opts.db));
  const byWorktree = new Map();
  const activeRuns = sessions.liveRuns || new Set();
  if (!sessions.error) {
    for (const row of sessions.bound) {
      const key = norm(row.worktree);
      if (!byWorktree.has(key)) byWorktree.set(key, []);
      byWorktree.get(key).push(row);
    }
  }
  const live = sessions.error ? 0 : sessions.bound.filter((r) => r.ended_at === null || r.ended_at === undefined).length;
  say(`session db:  ${path.resolve(opts.db)}  (${sessions.error ? `UNREADABLE: ${sessions.error}` : `${sessions.source}: ${sessions.total} sessions, ${sessions.bound.length} bind a worktree, ${live} still live`})`);

  const pushed = pushedHeads(repo, opts.offline);
  say(`pushed refs: ${pushed.error ? `UNPROVEN: ${pushed.error}` : `${pushed.heads.length} heads advertised by origin (ls-remote, read-only), ${pushed.heads.filter((h) => h.ref === 'main').length} of them main; ${pushed.reachable.size} commits reachable from them`}`);
  const probe = processProbe();
  say(`holder probe: ${probe.available ? probe.detail : `UNAVAILABLE: ${probe.why}`}`);
  say('');
  say(`registrations: ${before.registrations}   local branches: ${before.branched} (change/*: ${before.changeBranches})   managed dirs on disk: ${before.dirs}`);
  if (before.unregisteredDirs) say(`note: ${before.unregisteredDirs} managed dirs are on disk with no registration (not reaped here; ` +
    'that is `git worktree prune` / operator territory)');
  say('');

  const ctx = { primary: repo, primaryGitDir, stateDir: path.resolve(opts.stateDir), protectedPaths, protectedSessions, byWorktree, activeRuns, probe, pushed, requireProbe: opts.requireProbe, storeError: sessions.error || '', protectedPrefixes: PROTECTED_SESSION_PREFIXES };
  let findings = worktreeList(repo).map((e) => verify(e, ctx));
  const candidates = findings.filter((f) => f.verdict === 'would-reap');
  for (const c of candidates) measure(c, ctx);

  const list = (verdict, tag) => {
    const rows = findings.filter((f) => f.verdict === verdict);
    if (!rows.length) return;
    say(`${tag} (n=${rows.length}${verdict === 'would-reap' ? `, ${human(rows.reduce((a, r) => a + r.bytes, 0))} measured` : ''})`);
    for (const r of rows) {
      const bits = [
        `branch=${r.branch || '(detached)'}`,
        r.session ? `session=${r.session.slice(0, 8)}` : null,
        r.sessionEnded !== undefined && r.sessionEnded !== null ? `ended=${iso(r.sessionEnded)}` : null,
        `tip=${(r.tip || '').slice(0, 8)}`,
        r.bytes !== undefined ? `bytes=${r.bytes}` : null,
        r.files !== undefined ? `files=${r.files}` : null,
        r.ignored ? `ignored=${r.ignored}` : null,
      ].filter(Boolean).join('  ');
      perTree(`  ${r.verdict === 'would-reap' ? 'REAP  ' : r.verdict === 'protected' ? 'KEEP  ' : 'REFUSE'}  ${r.name}  ${r.reason}${r.detail ? `  — ${r.detail}` : ''}`);
      perTree(`          ${bits}`);
    }
    say('');
  };
  list('would-reap', 'WOULD REAP');
  list('refused', 'REFUSED (could not be proved disposable — left alone)');
  list('protected', 'PROTECTED (never touched by rule)');

  const hist = (verdict) => {
    const m = new Map();
    for (const f of findings.filter((x) => x.verdict === verdict)) m.set(f.reason, (m.get(f.reason) || 0) + 1);
    return [...m.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}=${v}`).join(' ') || '(none)';
  };
  const freed = candidates.reduce((a, r) => a + r.bytes, 0);
  say(`reasons refused:   ${hist('refused')}`);
  say(`reasons protected: ${hist('protected')}`);
  say(`disk that would be freed: ${human(freed)} — measured as the sum of each candidate's ${candidates.length} trees plus their admin dirs`);
  say('');

  const result = { when: new Date().toISOString(), opts: { repo, stateDir: path.resolve(opts.stateDir), db: path.resolve(opts.db), apply: opts.apply }, before, pushed: pushed.error ? { error: pushed.error } : { heads: pushed.heads.map((h) => h.ref) }, probe: { available: probe.available, detail: probe.detail || probe.why || '' }, findings };

  if (opts.apply) {
    // prove it again, at the moment of removal: the report above is minutes old by now
    const fresh = readSessions(path.resolve(opts.db));
    if (fresh.error) { say(`REFUSING ALL: the session store went unreadable between report and apply (${fresh.error})`); say(''); }
    else {
      const freshMap = new Map();
      for (const row of fresh.bound) { const k = norm(row.worktree); if (!freshMap.has(k)) freshMap.set(k, []); freshMap.get(k).push(row); }
      ctx.byWorktree = freshMap; ctx.activeRuns = fresh.liveRuns;
      const freshProbe = processProbe();
      if (freshProbe.available) ctx.probe = freshProbe;
      let done = 0, recheckRefused = 0;
      const applied = [];
      for (const c of candidates) {
        if (done >= opts.limit) { say(`stopping at --limit ${opts.limit}`); break; }
        const again = verify({ path: c.path, branch: c.branch, head: c.tip, locked: false, detached: false }, ctx);
        if (again.verdict !== 'would-reap') { recheckRefused += 1; say(`REFUSE (at reap time)  ${c.name}  ${again.reason}${again.detail ? `  — ${again.detail}` : ''}`); c.recheck = { reason: again.reason, detail: again.detail }; continue; }
        measure(again, ctx);
        // `git worktree remove` first, then `git branch -d`: deleting the directory by hand is what
        // left the registrations behind in the first place. No --force, and no fallback if it fails.
        const removed = run('git', ['-C', repo, 'worktree', 'remove', c.path], { timeout: 300000 });
        if (!removed.ok) { say(`FAILED   ${c.name}  git worktree remove: ${removed.why} ${removed.err.trim().split('\n')[0]}`); c.result = { removed: false, error: `${removed.why} ${removed.err.trim().split('\n')[0]}` }; continue; }
        const deleted = run('git', ['-C', repo, 'branch', '-d', c.branch], { timeout: 120000 });
        c.result = { removed: true, branchDeleted: deleted.ok, branchError: deleted.ok ? '' : `${deleted.why} ${deleted.err.trim().split('\n')[0]}` };
        if (!deleted.ok) say(`PARTIAL  ${c.name}  tree removed, branch kept — git branch -d: ${c.result.branchError}`);
        applied.push(c);
        done += 1;
        say(`REAPED   ${c.name}  branch=${c.branch}  freed=${human(again.bytes)} (measured)${c.result.branchDeleted ? '' : '  [branch kept]'}`);
      }
      const freedNow = applied.reduce((a, r) => a + (r.bytes || 0), 0);
      say('');
      say(`APPLIED: ${applied.length} trees reaped, ${freedNow} bytes freed, ${applied.filter((r) => !r.result.branchDeleted).length} branches kept, ${recheckRefused} refused at reap time`);
      result.applied = applied.map((r) => ({ name: r.name, path: r.path, branch: r.branch, tip: r.tip, session: r.session, bytes: r.bytes, result: r.result }));
      result.freedBytes = freedNow;
      result.recheckRefused = recheckRefused;
    }
  }

  const after = counts(repo, opts.stateDir);
  if (opts.apply) {
    say('');
    say(`registrations: ${before.registrations} -> ${after.registrations}`);
    say(`local branches: ${before.branched} -> ${after.branched}  (change/*: ${before.changeBranches} -> ${after.changeBranches})`);
    say(`managed dirs:   ${before.dirs} -> ${after.dirs}   unregistered dirs: ${before.unregisteredDirs} -> ${after.unregisteredDirs}`);
  }
  result.after = after;

  const reportPath = opts.report === null ? path.join(path.resolve(opts.stateDir), 'reap', `worktree-reap-${new Date().toISOString().replace(/[:.]/g, '-')}${opts.apply ? '-apply' : ''}.json`) : opts.report;
  try {
    fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    fs.writeFileSync(reportPath, `${JSON.stringify(result, null, 2)}\n`);
    say(`report: ${reportPath}`);
  } catch (e) { say(`report NOT written (${e.message})`); }

  if (!opts.quiet) return 0;
  return 0;
}

try {
  process.exitCode = main();
} catch (e) {
  process.stderr.write(`reap-worktrees: ${e.message}\n`);
  process.exitCode = 1;
}
