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
// AGE IS NOT EVIDENCE OF DISUSE (the repair). An entry past `--min-age-hours` is a *candidate*, not a
// decision: a family a live process holds or works in is never removed, and neither is one whose
// liveness cannot be established - both are left and named, in report mode too. The evidence is the
// OS's own exclusive-access test on the family directory plus a live-process command-line scan that
// names the pid; the measured cases are above `inUseEvidence` below. `fs.rmSync` removing a family a
// live process holds a file inside is exactly what the reviewed pass did, so a removal that succeeds
// is not evidence that the family was stale - which is why the decision is taken before it.
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
import { pathToFileURL } from 'node:url';
import { procUse as procEvidence, procUseNote } from './lib/proc-use.mjs';

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
    apply: false, dryRun: false, quiet: false, minAgeHours: 6, limit: Infinity,
    backupKeep: 3, scratchAgeHours: 24, explicitStateDir: false,
    lowDiskBytes: Number(process.env.WA_RECLAIM_LOW_DISK_BYTES || '') || 5 * 1024 ** 3,
    lowDiskPercent: Number(process.env.WA_RECLAIM_LOW_DISK_PERCENT || '') || 5,
    repo: null, tempDir: os.tmpdir(), stateDir: null, db: null, report: null, protect: [],
  };
  opts.stateDir = stateFromEnv || process.env.WASM_AGENT_STATE_DIR || null;
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--apply') opts.apply = true;
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--backup-keep') opts.backupKeep = Number(argv[++i]);
    else if (a === '--scratch-age-hours') opts.scratchAgeHours = Number(argv[++i]);
    else if (a === '--low-disk-bytes') opts.lowDiskBytes = Number(argv[++i]);
    else if (a === '--low-disk-percent') opts.lowDiskPercent = Number(argv[++i]);
    else if (a === '--quiet') opts.quiet = true;
    else if (a === '--min-age-hours') opts.minAgeHours = Number(argv[++i]);
    else if (a === '--limit') opts.limit = Number(argv[++i]);
    else if (a === '--repo') opts.repo = argv[++i];
    else if (a === '--temp-dir') opts.tempDir = argv[++i];
    else if (a === '--state-dir') { opts.stateDir = argv[++i]; opts.explicitStateDir = true; }
    else if (a === '--db') opts.db = argv[++i];
    else if (a === '--report') opts.report = argv[++i];
    else if (a === '--protect') opts.protect.push(argv[++i]);
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!Number.isFinite(opts.minAgeHours) || opts.minAgeHours < 0) throw new Error('--min-age-hours needs a number');
  for (const [key, flag] of [['backupKeep', '--backup-keep'], ['scratchAgeHours', '--scratch-age-hours'], ['lowDiskBytes', '--low-disk-bytes'], ['lowDiskPercent', '--low-disk-percent']]) {
    if (!Number.isFinite(opts[key]) || opts[key] < 0) throw new Error(`${flag} needs a number`);
  }
  if (!Number.isInteger(opts.backupKeep)) throw new Error('--backup-keep needs a whole number');
  // Two spellings of one decision would be decided by argument order, which nobody reading the job
  // would guess. `--dry-run` is the operator's switch, `--apply` is the job's; both together is an
  // error, not the last one winning.
  if (opts.apply && opts.dryRun) throw new Error('--apply and --dry-run are exclusive: one run either removes or shows the plan');
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
  const fields = line.split(/\s+/).filter(Boolean);
  // `df -Pk` prints `Filesystem 1024-blocks Used Available Capacity Mounted on`, and the Filesystem
  // field may itself contain spaces - this machine's root mount is `C:/Program Files/Git` - so the
  // fields are located from the capacity column (the only field that is a percentage) and counted
  // from it, exactly as `scripts/check-disk-floor.sh` does. The same free space must yield the same
  // verdict in both places.
  const caps = fields.map((f, i) => (/^[0-9]+%$/.test(f) ? i : -1)).filter(i => i >= 0);
  if (caps.length !== 1 || caps[0] < 4) return { error: `df said: ${line}` };
  const cap = caps[0];
  const totalKb = Number(fields[cap - 3]), availKb = Number(fields[cap - 1]);
  if (!Number.isFinite(totalKb) || !Number.isFinite(availKb)) return { error: `df said: ${line}` };
  return { totalBytes: totalKb * 1024, availableBytes: availKb * 1024, mount: fields.slice(cap + 1).join(' ') || target };
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

// ── liveness: who is still using a temp family, decided from evidence ────────────────────────────
// The reviewed pass expired an entry because the *directory* was old, and removed a family a live
// process held a file inside: a long-running process that appends to a file inside its family keeps
// the FILE's mtime fresh, not the directory's, so the directory ages while its owner is alive. So an
// entry past `--min-age-hours` is only a candidate, and removal needs a second, negative result:
//
//   1. the OS's own exclusive-access test on the family directory. A rename - even to the same name -
//      needs DELETE access on the directory and on what it holds, so it is refused while any process
//      holds the directory or a file inside it, and succeeds once nothing does. Measured on this node
//      (MSYS/MINGW64, 2026-09-30): an idle directory renames OK; a directory with a file held open by
//      a live process refuses EPERM; a directory that is a live process's working directory refuses
//      EBUSY; the same directory renames OK once the holder is killed.
//   2. a live process whose command line names the family, which is what lets a refusal name the pid
//      that holds it rather than only an error code.
//
// On a POSIX host a rename is metadata-only and would succeed with a file still held, so there the
// evidence is /proc: a live process's cwd or open file inside the family. Where no evidence source
// can answer - no probe, an entry that is not a directory, a /proc entry that cannot be inspected -
// the entry is LEFT and named `liveness unproven`. Refusing to delete is a result, and the list of
// what was not touched is this pass's product.

// The probe: a same-name rename of the directory. It leaves the family exactly where it was, and its
// refusal is the OS naming a holder.
function renameProbe(dir) {
  try { fs.renameSync(dir, dir); return null; }
  catch (e) { return e.code || String(e.message || e); }
}

function matchKey(p) { return String(p || '').replace(/\\/g, '/').replace(/\/+/g, '/').toLowerCase(); }

// One process scan per run, and only when there is a candidate to decide. This is the *pid* evidence;
// the rename probe above decides on its own, so a scan that cannot run costs a name, not the rule.
function liveProcesses() {
  if (process.platform !== 'win32') return { error: 'the process scan is the Windows evidence source; on POSIX /proc is' };
  const script = 'Get-CimInstance Win32_Process | ForEach-Object { [string]$_.ProcessId + " " + [string]$_.CommandLine }';
  // -EncodedCommand: the script is handed over as base64 UTF-16LE, so no shell or `-Command` quoting
  // can mangle it (this node's process names contain spaces and quotes).
  const r = run('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { timeout: 120000 });
  if (!r.ok) return { error: `the process scan failed: ${r.why} ${r.err.trim().slice(0, 120)}` };
  const rows = [];
  for (const line of r.out.split(/\r?\n/)) {
    const m = /^\s*(\d+)\s+(.*)$/.exec(line);
    if (m) rows.push({ pid: Number(m[1]), cmd: m[2] });
  }
  if (!rows.length) return { error: 'the process scan returned no rows' };
  return { source: 'powershell Get-CimInstance Win32_Process', rows };
}

function pidNaming(dir, procs) {
  if (!procs || !procs.rows) return null;
  const key = matchKey(dir);
  const hit = procs.rows.find(row => matchKey(row.cmd).includes(key));
  return hit ? { pid: hit.pid, cmd: hit.cmd.trim().slice(0, 160) } : null;
}

// The POSIX evidence source is scripts/lib/proc-use.mjs: a live process's cwd or any open file inside the
// family, with its rule for processes /proc will not show (another user's are skipped and counted; one of
// this user's makes the answer unproven). Exercised on Linux since 30/10 (openclaw, v0.1.0-alpha.12).
// The decision for one aged candidate. `null` means removal is allowed; anything else is the record's
// reason for staying, with the evidence that decided it.
function inUseEvidence(full, isDir, procs, scan) {
  const named = pidNaming(full, procs);
  if (named) return { kind: 'in_use', pid: named.pid, source: 'process command line', why: `in use: a live process names this family - pid ${named.pid} (${named.cmd})` };
  if (!isDir) return { kind: 'liveness_unproven', pid: null, source: null, why: 'liveness unproven: the entry is not a directory, so the directory probe cannot answer for the open handles inside it' };
  const code = renameProbe(full);
  if (code) return { kind: 'in_use', pid: null, source: 'rename probe', why: `in use: the OS refused an exclusive rename of the family (${code}) - a process holds the directory or a file inside it` };
  if (process.platform === 'win32') return null;
  return posixEvidence(full, scan);
}

// /proc's answer for one family, folded into the run's scan summary (the report names how many other-user
// processes were skipped, so the rule is visible, not silent).
function posixEvidence(full, scan) {
  const use = procEvidence(full);
  if (scan) {
    scan.decided += 1;
    scan.processes = Math.max(scan.processes, use.scanned);
    scan.skippedOtherUser = Math.max(scan.skippedOtherUser, use.skippedOtherUser);
    scan.unreadableOwn = Math.max(scan.unreadableOwn, use.unreadableOwn);
    scan.skippedPrivileged = Math.max(scan.skippedPrivileged, use.skippedPrivileged);
  }
  if (use.error) return { kind: 'liveness_unproven', pid: null, source: '/proc', why: `liveness unproven: ${use.error}` };
  if (use.holder) return { kind: 'in_use', pid: use.holder.pid, source: '/proc', why: `in use: ${use.holder.why}` };
  if (use.unreadableOwn) return { kind: 'liveness_unproven', pid: null, source: '/proc', why: `liveness unproven: ${procUseNote(use)} - one of them could be working in it` };
  return null;
}

function tempPass(opts) {
  let entries = [];
  try { entries = fs.readdirSync(opts.tempDir); } catch (e) { return { error: `cannot read ${opts.tempDir}: ${e.message}`, families: new Map() }; }
  const families = mintedFamilies(opts.repo, entries);
  const protectedFamilies = PROTECTED_TEMP_FAMILIES.map(entry => ({ ...entry, hits: 0, bytes: 0 }));
  const cutoff = Date.now() - opts.minAgeHours * 3600 * 1000;
  const expired = [], kept = [], candidates = [];
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
    const record = { name, family, mintedBy: families.get(family), ageHours: Number((ageMs / 3600000).toFixed(1)), bytes: 0, isDir: st.isDirectory() };
    if (st.mtimeMs > cutoff) { record.why = `fresh: younger than --min-age-hours ${opts.minAgeHours}`; kept.push(record); continue; }
    candidates.push({ full, record });
  }

  // The age test has passed: these are candidates, and whether each may go is decided from evidence
  // about who is still using it. This runs in report mode too, so a report cannot call a live family
  // "would expire" and then be believed.
  const procs = candidates.length ? liveProcesses() : null;
  const scan = process.platform === 'win32' ? null : { source: '/proc (cwd and open files)', processes: 0, skippedOtherUser: 0, skippedPrivileged: 0, unreadableOwn: 0, decided: 0 };
  for (const { full, record } of candidates) {
    record.bytes = dirBytes(full).bytes;
    const use = inUseEvidence(full, record.isDir, procs, scan);
    if (use) { record.why = use.why; record.kind = use.kind; record.pid = use.pid ?? null; record.source = use.source || null; kept.push(record); continue; }
    if (opts.apply && expired.length < opts.limit) {
      // The proof is re-read at the moment of removal: a family that came into use between the
      // decision and this line is refused here, not deleted and apologised for afterwards.
      const again = renameProbe(full);
      if (again) { record.removed = false; record.kind = 'in_use'; record.why = `in use: it came into use between the decision and the removal (the OS refused an exclusive rename: ${again})`; kept.push(record); continue; }
      const late = process.platform === 'win32' ? null : posixEvidence(full, null);
      if (late) { record.removed = false; record.kind = late.kind; record.pid = late.pid; record.source = late.source; record.why = `${late.why} (re-read at the moment of removal)`; kept.push(record); continue; }
      try {
        // A refusal is a result: a file another process holds is reported, not forced.
        fs.rmSync(full, { recursive: true, force: false, maxRetries: 1 });
        record.removed = true;
      } catch (e) { record.removed = false; record.why = `held or unremovable: ${e.message}`; kept.push(record); continue; }
    } else if (!opts.apply) record.removed = false;
    expired.push(record);
  }
  return { families, candidates: families.candidates.size, expired, kept, unknown, protectedFamilies, cutoff, procs, scan, decided: candidates.length };
}

// ── the session store: whose tree is it, and has that session ended ──────────────────────────────
function readSessions(dbPath) {
  if (!fs.existsSync(dbPath)) return { error: `session store not found: ${dbPath}` };
  const boundQuery = "SELECT id, worktree, ended_at, workspace_state, workspace_branch FROM sessions WHERE worktree IS NOT NULL AND worktree <> ''";
  const liveRunQuery = 'SELECT DISTINCT session_id FROM runs WHERE ended_at IS NULL';
  // Every session, not only the bound ones: session-scratch belongs to a session, and most sessions
  // never bind a worktree. The ended timestamp is the proof the scratch pass needs.
  const allQuery = 'SELECT id, ended_at FROM sessions';
  try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(dbPath, { readOnly: true });
    const bound = db.prepare(boundQuery).all();
    const liveRuns = new Set(db.prepare(liveRunQuery).all().map(r => String(r.session_id)));
    const all = db.prepare(allQuery).all().map(row => ({ id: String(row.id), ended_at: row.ended_at === null || row.ended_at === undefined ? null : Number(row.ended_at) }));
    db.close();
    return { bound, liveRuns, all, source: 'node:sqlite' };
  } catch (e) {
    const rows = (query) => {
      const r = run('sqlite3', ['-readonly', '-separator', '\t', '-noheader', dbPath, query], { timeout: 120000 });
      if (!r.ok) throw new Error(`sqlite3 failed: ${r.why} ${r.err.trim()}`);
      return r.out.split('\n').filter(l => l.length).map(l => l.split('\t'));
    };
    try {
      const bound = rows(boundQuery).map(([id, worktree, ended, state, branch]) => ({ id, worktree, ended_at: ended === '' ? null : Number(ended), workspace_state: state, workspace_branch: branch }));
      const all = rows(allQuery).map(([id, ended]) => ({ id, ended_at: ended === '' ? null : Number(ended) }));
      return { bound, liveRuns: new Set(rows(liveRunQuery).map(([id]) => id)), all, source: 'sqlite3' };
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

function prunePass(opts, ctx, blocked = []) {
  const entries = worktreeList(ctx.repo);
  const findings = entries.map(entry => targetCandidate(entry, ctx));
  // A deploy that is building is the one thing this pass must never remove under: demote every build
  // candidate before anything is measured or removed, and name why on each row.
  if (blocked.length) {
    for (const finding of findings) {
      if (finding.verdict !== 'would-prune') continue;
      finding.verdict = 'kept';
      finding.reason = 'deploy_in_progress';
      finding.detail = blocked.join('; ');
    }
  }
  for (const f of findings) if (f.verdict === 'would-prune') f.bytes = dirBytes(f.target).bytes;
  const candidates = findings.filter(f => f.verdict === 'would-prune');
  if (blocked.length) return { findings, candidates, applied: [], refusedAtApply: 0, blocked };
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
      // The never-touch list is asked by EVERY removal under the state directory, not only by the three
      // categories that were added with it. A build target lives in the state directory too, so a future
      // edit that pointed a category at `components/` or `sentinel/` would be refused here instead of
      // discovered later. (The bounded-temp pass is deliberately outside this: it removes only inside the
      // OS temp directory, only names a tracked script mints, and carries its own liveness evidence.)
      const guard = neverTouch(candidate.target, ctx);
      if (guard) {
        candidate.result = { removed: false, error: `refused: ${guard}` };
        refusedAtApply += 1;
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

// ── the never-touch list, and the one function allowed to remove ────────────────────────────────
// A category decides what *could* go; this decides whether anything *may*. It is checked inside
// `removeSafely` - the only removal in this file - so a category whose pattern is wrong shows up as
// "nothing removed", never as a store that is gone. The list lives here once because a list repeated
// per category is a list that disagrees with itself on the fifth edit.
const NEVER_TOUCH = [
  { re: /^memory\.db($|[-.])/, why: 'the memory store: sessions, runs, the run journal' },
  { re: /^rendezvous\.db($|[-.])/, why: 'the rendezvous store' },
  { re: /^graph\.db$/, why: 'the live graph database (its indexer owns it)' },
  { re: /^graph\.db-(wal|shm|journal)$/, why: "the live graph database's SQLite siblings" },
  { re: /^graph\.db\.d$/, why: 'the live graph database directory' },
  { re: /^vault($|\.)/, why: 'the vault' },
  { re: /^node\.key/, why: "the node's identity key" },
  { re: /^binding(\.|$)/, why: 'the peer binding and its leases' },
  { re: /^serve\.pid$/, why: "the running node's pid" },
  { re: /^deploy-result\.json$/, why: 'the deploy receipt' },
  { re: /^installed\.txt$/, why: 'the install record' },
  { re: /^protocol-effect\.json/, why: 'the sentinel effect ledger' },
  { re: /^queue($|\.)/, why: "the node's durable queue" },
  { re: /^undelivered/, why: 'the delivery outbox' },
];
const NEVER_TOUCH_TOP = new Map([
  ['components', 'installed components state'],
  ['sentinel', 'sentinel state: requests, claimed, done, failed, stop, effect ledger'],
  ['archive', 'the archive (clean-disk rule 4)'],
  ['bound', 'binding state'],
  ['bin', 'the installed binaries'],
  ['changes', 'the changeset store'],
  ['captures', 'retained model-request captures'],
  ['vault', 'the vault'],
  ['vaults', 'the vault'],
]);

function relativeInside(root, full) {
  const a = norm(path.resolve(root));
  const b = norm(path.resolve(full));
  if (b === a) return '';
  return b.startsWith(`${a}/`) ? b.slice(a.length + 1) : null;
}

// The reason this path may not be removed, or null when it may. Every removal asks this first.
function neverTouch(full, ctx) {
  const rel = relativeInside(ctx.stateDirAbs, full);
  if (rel === null) return `outside ${ctx.stateDirAbs}: this pass removes nothing outside the state directory`;
  const parts = rel === '' ? [] : rel.split('/');
  if (!parts.length) return 'the state directory itself';
  if (parts.some(part => part === '..' || part === '.')) return 'a path that leaves the state directory';
  const top = NEVER_TOUCH_TOP.get(parts[0]);
  if (top) return top;
  const leaf = parts[parts.length - 1];
  for (const rule of NEVER_TOUCH) if (rule.re.test(leaf)) return rule.why;
  return null;
}

// The single removal path. It re-reads the never-touch predicate at the moment of removal (the list
// is cheap and the decision is the expensive thing), measures before it removes, and reports a refusal
// as a refusal. `expect` narrows what may go: a name test the category is sure about, so a path that
// was swapped between the decision and the deletion is refused rather than followed.
function removeSafely(full, ctx, expect) {
  const refused = neverTouch(full, ctx);
  if (refused) return { removed: false, bytes: 0, why: `refused: ${refused}` };
  if (expect && !expect.test(path.basename(full))) return { removed: false, bytes: 0, why: `refused: '${path.basename(full)}' is not the shape this category removes` };
  const measured = dirBytes(full).bytes;
  if (!ctx.apply) return { removed: false, bytes: measured, why: 'dry run: nothing is removed' };
  try {
    fs.rmSync(full, { recursive: true, force: false, maxRetries: 1 });
    return { removed: true, bytes: measured, why: '' };
  } catch (e) {
    // Held, or refused by the OS: a result, named. Never retried with a bigger hammer.
    return { removed: false, bytes: measured, why: `held or unremovable: ${e.message}` };
  }
}

// ── category 1: pre-update backups, keep the newest N plus any pending rollback needs ───────────
// `lua/core/backup.lua` names a snapshot `<config>/backups/<stamp>-<uuid>-pre-update`, where the stamp
// is `YYYYMMDDTHHMMSSZ` and therefore sorts into age. `lua/core/backup.lua` takes the snapshot and leaves
// retention to this pass (`M.prune` now answers `retention_is_the_reclaim_pass`), and 48 of them reached
// 6.8 GB on openclaw before anything bounded them.
// The rule that makes a number safe is the one this pass can prove *from the disk*: the newest N are
// the recovery sources an update can still want, and a snapshot a pending rollback names is not aged
// out at all. Everything else is a copy of stores that still exist.
const PRE_UPDATE_RE = /^\d{8}T\d{6}Z-.+-pre-update$/;

// The rollback evidence, read rather than assumed. A pending rollback is: a marker file in the
// snapshot itself, or a sentinel request that has not been completed and names the snapshot. `done/`
// and `failed/` are finished work, so they do not pin anything; a `requests/`, `claimed/` or
// `deferred/` entry names work that is still owed.
const ROLLBACK_MARKERS = ['ROLLBACK-PENDING', '.rollback-pending', 'rollback-pending.json'];
function pendingRollbackEvidence(stateDir) {
  const dirs = ['sentinel/requests', 'sentinel/claimed', 'sentinel/deferred'];
  const evidence = [];
  let error = '';
  let scanned = 0;
  for (const rel of dirs) {
    const dir = path.join(stateDir, rel);
    let names;
    try { names = fs.readdirSync(dir); } catch (e) {
      if (e.code !== 'ENOENT') error = `${rel}: ${e.message}`;
      continue;
    }
    for (const name of names.slice(0, 500)) {
      const full = path.join(dir, name);
      let text;
      try {
        const st = fs.statSync(full);
        if (!st.isFile() || st.size > 256 * 1024) continue;
        text = fs.readFileSync(full, 'utf8');
      } catch { continue; }
      scanned += 1;
      evidence.push({ source: `${rel}/${name}`, text });
    }
  }
  return { evidence, error, scanned };
}

function rollbackPins(backupName, backupPath, rollback) {
  try {
    if (ROLLBACK_MARKERS.some(marker => fs.existsSync(path.join(backupPath, marker)))) {
      return `a rollback marker inside the snapshot (${ROLLBACK_MARKERS.join('/')})`;
    }
  } catch { /* an unreadable snapshot is kept by the caller's own error path */ }
  const hit = rollback.evidence.find(entry => entry.text.includes(backupName));
  return hit ? `pending sentinel request ${hit.source} names it` : null;
}

function backupPass(opts, ctx) {
  const dir = path.join(ctx.stateDirAbs, 'backups');
  let names;
  try { names = fs.readdirSync(dir); } catch (e) {
    return { dir, error: e.code === 'ENOENT' ? 'no backups directory on this node' : `cannot read ${dir}: ${e.message}`, removed: [], kept: [] };
  }
  const rollback = pendingRollbackEvidence(ctx.stateDirAbs);
  // An unreadable rollback evidence source is not permission to age a recovery source out.
  const all = names.filter(name => PRE_UPDATE_RE.test(name)).sort().reverse();
  const removed = [], kept = [];
  for (let i = 0; i < all.length; i += 1) {
    const name = all[i];
    const full = path.join(dir, name);
    const record = { category: 'pre-update-backups', name, path: full, bytes: 0, removed: false, why: '' };
    if (i < opts.backupKeep) { record.why = `one of the newest ${opts.backupKeep} (kept)`; kept.push(record); continue; }
    const pin = rollbackPins(name, full, rollback);
    if (pin) { record.why = `kept: ${pin}`; kept.push(record); continue; }
    if (rollback.error) { record.why = `kept: rollback evidence unreadable (${rollback.error}), so no snapshot is aged out on a guess`; kept.push(record); continue; }
    const outcome = removeSafely(full, ctx, PRE_UPDATE_RE);
    record.bytes = outcome.bytes; record.removed = outcome.removed; record.why = outcome.why || `beyond the newest ${opts.backupKeep}, not named by a pending rollback`;
    if (outcome.removed || outcome.why.startsWith('dry run')) removed.push(record); else kept.push(record);
  }
  return { dir, error: '', removed, kept, rollback: { scanned: rollback.scanned, error: rollback.error }, keep: opts.backupKeep, total: all.length };
}

// ── category 2: graph quarantines, keep the newest one with its SQLite siblings ────────────────────
// `quarantine_database` in rust/wa-capabilities/src/graph.rs renames a malformed database aside as
// `<file>.malformed-<stamp>` plus `-wal`, `-shm`, `-journal`. On openclaw the indexer did that ~20 times
// between 10/11 22:16 and 11/11 05:03 (~2.5 GB): each rebuild went malformed again, so each rebuild
// left another copy. One superseded quarantine is worth keeping as evidence; nineteen are the loop's
// footprint. The newest stamp is kept whole - a base file without its `-wal` is not a database.
const QUARANTINE_RE = /^(?<db>[A-Za-z0-9_.-]+\.db)\.malformed-(?<stamp>\d{8}T\d{6}Z)(?<suffix>-(?:wal|shm|journal))?$/;

function graphQuarantinePass(opts, ctx) {
  // The state directory itself, and one level down: a node that keeps its graph in `graph.db.d/`
  // quarantines next to the live file, and one that keeps it at the top quarantines there.
  const roots = [ctx.stateDirAbs];
  try {
    for (const name of fs.readdirSync(ctx.stateDirAbs)) {
      if (!/^graph\.db\.d$/.test(name) && !/^[A-Za-z0-9_.-]+\.db\.d$/.test(name)) continue;
      roots.push(path.join(ctx.stateDirAbs, name));
    }
  } catch { /* the top level was validated by the caller */ }
  const groups = new Map();
  const removed = [], kept = [];
  let candidates = 0;
  for (const root of roots) {
    let names;
    try { names = fs.readdirSync(root); } catch { continue; }
    for (const name of names) {
      const m = QUARANTINE_RE.exec(name);
      if (!m) continue;
      candidates += 1;
      const key = `${norm(root)}|${m.groups.db}|${m.groups.stamp}`;
      if (!groups.has(key)) groups.set(key, { dir: root, db: m.groups.db, stamp: m.groups.stamp, files: [] });
      groups.get(key).files.push(name);
    }
  }
  const newest = new Map();
  for (const [key, group] of groups) {
    const current = newest.get(`${norm(group.dir)}|${group.db}`);
    if (!current || group.stamp > current.stamp) newest.set(`${norm(group.dir)}|${group.db}`, group);
  }
  let keepCount = 0;
  for (const group of [...groups.values()].sort((a, b) => (a.stamp < b.stamp ? 1 : a.stamp > b.stamp ? -1 : 0))) {
    const isNewest = newest.get(`${norm(group.dir)}|${group.db}`) === group;
    if (isNewest) { keepCount += 1; }
    for (const name of group.files) {
      const full = path.join(group.dir, name);
      const record = { category: 'graph-quarantine', name: path.join(path.basename(group.dir), name), path: full, stamp: group.stamp, bytes: 0, removed: false, why: '' };
      if (isNewest) {
        // The whole newest group stays: a `.db.malformed-<stamp>` without its `-wal` is not a database
        // that anyone can open, so keeping the base file and deleting the journal keeps nothing.
        record.bytes = dirBytes(full).bytes;
        record.why = 'the newest quarantine, kept whole with its SQLite siblings';
        kept.push(record); continue;
      }
      const outcome = removeSafely(full, ctx, QUARANTINE_RE);
      record.bytes = outcome.bytes; record.removed = outcome.removed; record.why = outcome.why || `superseded by a newer quarantine (${group.stamp} < newest)`;
      if (outcome.removed || outcome.why.startsWith('dry run')) removed.push(record); else kept.push(record);
    }
  }
  return { removed, kept, candidates, groups: groups.size, keptGroups: keepCount };
}

// ── category 3: session scratch of sessions that ended more than a day ago ───────────────────────
// `lua/core/workspaces.lua` stages a session's evidence under
// `<data>/session-scratch/<hex-encoded session id>`, and hex is injective so the directory can be
// decoded back to the session it belonged to. The proof that it may go is the *session store's*:
// that session ended, no run of it is open, and it ended more than `--scratch-age-hours` ago. A
// directory that does not decode, or decodes to a session the store has never heard of, is left and
// named - an unknown owner is not an absent owner.
function scratchPass(opts, ctx) {
  const dir = path.join(ctx.stateDirAbs, 'session-scratch');
  let names;
  try { names = fs.readdirSync(dir); } catch (e) {
    return { dir, error: e.code === 'ENOENT' ? 'no session-scratch directory on this node' : `cannot read ${dir}: ${e.message}`, removed: [], kept: [] };
  }
  if (ctx.storeError) return { dir, error: `the session store is unreadable (${ctx.storeError}), so no scratch is aged out`, removed: [], kept: [] };
  const cutoff = Date.now() / 1000 - opts.scratchAgeHours * 3600;
  const removed = [], kept = [];
  for (const name of names) {
    const full = path.join(dir, name);
    const record = { category: 'session-scratch', name, path: full, bytes: 0, removed: false, why: '' };
    const decoded = decodeScratchName(name);
    if (!decoded) { record.bytes = dirBytes(full).bytes; record.why = 'kept: the name does not decode to a session id, so its owner is unknown'; kept.push(record); continue; }
    record.session = decoded;
    if (ctx.protectedSessions.has(norm(decoded))) { record.bytes = dirBytes(full).bytes; record.why = 'kept: named by --protect'; kept.push(record); continue; }
    const rows = ctx.allSessions.get(norm(decoded));
    if (!rows) { record.bytes = dirBytes(full).bytes; record.why = 'kept: no session record for this id, so its owner cannot be proved ended'; kept.push(record); continue; }
    const ended = rows.ended_at;
    if (ended === null || ended === undefined) { record.bytes = dirBytes(full).bytes; record.why = 'kept: the session has not ended'; kept.push(record); continue; }
    if (ctx.activeRuns.has(rows.id)) { record.bytes = dirBytes(full).bytes; record.why = 'kept: a run of this session has not ended'; kept.push(record); continue; }
    const ageHours = (Date.now() / 1000 - Number(ended)) / 3600;
    record.ageHours = Number(ageHours.toFixed(1));
    if (Number(ended) > cutoff) { record.bytes = dirBytes(full).bytes; record.why = `kept: ended ${record.ageHours} h ago, younger than --scratch-age-hours ${opts.scratchAgeHours}`; kept.push(record); continue; }
    const outcome = removeSafely(full, ctx, /^[0-9a-f]+$/);
    record.bytes = outcome.bytes; record.removed = outcome.removed; record.why = outcome.why || `ended ${record.ageHours} h ago, past --scratch-age-hours ${opts.scratchAgeHours}`;
    if (outcome.removed || outcome.why.startsWith('dry run')) removed.push(record); else kept.push(record);
  }
  return { dir, error: '', removed, kept, cutoff };
}

function decodeScratchName(name) {
  if (!/^([0-9a-f]{2})+$/.test(name)) return null;
  const text = Buffer.from(name, 'hex').toString('utf8');
  if (!text || !text.startsWith(text.trim()) || text.includes('\u0000')) return null;
  const again = [...Buffer.from(text, 'utf8')].map(b => b.toString(16).padStart(2, '0')).join('');
  return again === name ? text : null;
}

// ── the deploy guard: no build output is touched while a deploy builds ───────────────────────────
// The shared deploy target is the one cargo target a deploy writes while the node still runs, and a
// removal under a live deploy is how a half-written target becomes a wrong error later (clean-disk
// rule 8). Two evidence sources, both the node's own:
//
//   * a live process whose command line names a deploy or a build (`deploy.sh`, `upgrade.sh`,
//     `cargo build/test/clippy/clean`) - the writer itself;
//   * `deploy-pending.json`, the marker `lua/core/deploy_pause.lua` writes before it waits. It carries
//     its own `bound_seconds`, so a marker left behind by a crash stops counting once its bound has
//     passed - the same rule that module applies to honouring it.
//
// `sentinel/deploy-protocol/` is deliberately NOT evidence: it is a permanent directory of finished
// deploy records on every deploy-capable node, so its existence would refuse the build categories
// forever. Presence of a thing that is always present is not a fact about now.
function deployInProgress(ctx) {
  const reasons = [];
  if (process.platform === 'win32') {
    const procs = liveProcesses();
    if (procs && procs.rows) {
      const hit = procs.rows.find(row => /deploy\.(sh|ps1)|upgrade\.(sh|ps1)|cargo\s+(build|test|clippy|clean)/i.test(row.cmd));
      if (hit) reasons.push(`a live process is building or deploying - pid ${hit.pid} (${hit.cmd.trim().slice(0, 140)})`);
    }
  } else {
    const use = procEvidence(ctx.stateDirAbs);
    if (use.error) reasons.push(`the /proc scan could not answer (${use.error}), so a deploy cannot be ruled out`);
  }
  const marker = path.join(ctx.stateDirAbs, 'deploy-pending.json');
  try {
    const st = fs.statSync(marker);
    const text = fs.readFileSync(marker, 'utf8');
    let parsed = {};
    try { parsed = JSON.parse(text); } catch { parsed = {}; }
    const since = Number(parsed.since) || Math.floor(st.mtimeMs / 1000);
    const bound = Number(parsed.bound_seconds) || 900;
    const age = Math.floor(Date.now() / 1000) - since;
    if (parsed.state === undefined || parsed.state === 'deploy_pending') {
      if (age <= bound) reasons.push(`a deploy is pending (deploy-pending.json, ${age}s of its ${bound}s bound used)`);
    }
  } catch { /* no marker: the common case, and not a refusal */ }
  for (const lock of ['.deploy.lock', 'sentinel/stop', 'deploy.paused']) {
    const full = path.join(ctx.stateDirAbs, lock);
    try { if (fs.existsSync(full)) reasons.push(`the deploy lock ${lock} is held`); } catch { /* unreadable is not a lock */ }
  }
  return reasons;
}

function printCategory(say, opts, n, title, result, extra = []) {
  say(`${n}. ${title}`);
  if (result.error) {
    say(`   SKIPPED: ${result.error}`);
    for (const row of result.kept || []) say(`     KEEP   ${String(row.name).slice(0, 90)}  — ${row.why}${row.bytes ? `  ${human(row.bytes)}` : ''}`);
    return { removed: 0, bytes: 0, wouldBytes: 0 };
  }
  for (const line of extra) say(`   ${line}`);
  const wouldBytes = result.removed.reduce((a, r) => a + r.bytes, 0);
  const freedBytes = result.removed.reduce((a, r) => a + (r.removed ? r.bytes : 0), 0);
  say(`   ${opts.apply ? 'removed' : 'would remove'}: ${result.removed.length} entries, ${human(wouldBytes)}`);
  for (const row of result.removed) say(`     ${opts.apply && row.removed ? 'REMOVED' : 'PLAN'}  ${String(row.name).slice(0, 100)}  ${human(row.bytes)}  — ${row.why}`);
  const kept = result.kept || [];
  say(`   kept: ${kept.length} entries (each with the rule that kept it)`);
  for (const row of kept.slice(0, 30)) say(`     KEEP   ${String(row.name).slice(0, 100)}  — ${row.why}${row.bytes ? `  ${human(row.bytes)}` : ''}`);
  if (kept.length > 30) say(`     ... and ${kept.length - 30} more kept entries`);
  return { removed: result.removed.length, bytes: freedBytes, wouldBytes };
}

function main() {
  const opts = options(process.argv.slice(2));
  const say = (line = '') => process.stdout.write(`${line}\n`);
  const start = run('git', ['rev-parse', '--show-toplevel'], { cwd: opts.repo || process.cwd() });
  if (!start.ok) throw new Error(`not inside a git worktree: ${start.why}`);
  const cwdTree = path.resolve(start.out.trim());
  if (!opts.repo) opts.repo = path.resolve((worktreeList(cwdTree)[0] || {}).path || cwdTree);
  if (!opts.stateDir) opts.stateDir = path.resolve(path.join(os.homedir(), '.wasm-agent'));
  // The store belongs to the state directory it was measured in. `WASM_AGENT_DB` is the running node's
  // own store and is honoured only when this run was not pointed at a different state directory: a
  // `--state-dir X` that aged X's scratch by Y's session store would delete a live session's evidence
  // on another store's verdict. That exact leak happened in this pass's own test fixture, which
  // inherited the ambient variable and found no record for any session - so the rule is here now.
  if (!opts.db) opts.db = (!opts.explicitStateDir && process.env.WASM_AGENT_DB) || path.join(opts.stateDir, 'memory.db');

  const protectedPaths = new Set([norm(opts.repo), norm(cwdTree)]);
  const protectedSessions = new Set();
  for (const p of opts.protect) {
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(p)) protectedSessions.add(norm(p));
    else protectedPaths.add(norm(path.resolve(p)));
  }

  say(`disk reclaim — ${opts.apply ? 'APPLY (removing the safe categories)' : 'DRY RUN (nothing is removed; --apply is the job\'s switch)'}`);
  say('');
  say(`repo:      ${opts.repo}`);
  say(`state dir: ${opts.stateDir}`);
  say(`temp dir:  ${opts.tempDir}   (entries older than ${opts.minAgeHours} h are expired; nothing else is)`);
  const before = freeSpace(opts.repo);
  say(`free before: ${before.error ? `UNMEASURABLE: ${before.error}` : `${human(before.availableBytes)} of ${human(before.totalBytes)} on ${before.mount}`}`);
  // The same number the job's own low-disk trigger reads, printed here so a dry run says whether the
  // scheduled pass would already have been woken by the threshold rather than by its clock.
  if (!before.error) {
    const usedPercent = 100 - (before.availableBytes / before.totalBytes) * 100;
    const lowBytes = before.availableBytes < opts.lowDiskBytes;
    const lowPercent = Number.isFinite(usedPercent) && (before.availableBytes / before.totalBytes) * 100 < opts.lowDiskPercent;
    say(`low-disk threshold: ${human(opts.lowDiskBytes)} free or ${opts.lowDiskPercent}% free (configurable: --low-disk-bytes, --low-disk-percent, WA_RECLAIM_LOW_DISK_BYTES)`);
    say(`  ${lowBytes || lowPercent ? 'BELOW the threshold - the disk trigger would run this pass now' : 'above the threshold - only the schedule would'}`);
  }
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
    const evidence = temps.kept.filter(r => r.kind);
    const rest = temps.kept.filter(r => !r.kind);
    if (temps.scan) say(`   live-process scan (the pid evidence): ${temps.scan.decided ? `${temps.scan.source}, ${temps.scan.processes} processes${procUseNote(temps.scan) ? ` (${procUseNote(temps.scan)})` : ''}` : 'no aged candidate to decide'}`);
    else say(`   live-process scan (the pid evidence): ${temps.procs && temps.procs.rows ? `${temps.procs.source}, ${temps.procs.rows.length} processes` : (temps.decided ? `unavailable - ${(temps.procs && temps.procs.error) || 'unknown reason'}` : 'no aged candidate to decide')}`);
    say(`   LEFT, in use or liveness unproven (evidence, not age): ${evidence.length} entries`);
    for (const record of evidence.slice(0, 20)) say(`     LEFT   ${record.name}  — ${record.why}${record.bytes ? `  ${human(record.bytes)}` : ''}`);
    if (evidence.length > 20) say(`     ... and ${evidence.length - 20} more in use or unproven`);
    say(`   kept: ${temps.kept.length} entries (fresh, in use, or never expired by rule) — named below`);
    for (const record of rest.slice(0, 10)) say(`     KEEP   ${record.name}  — ${record.why}`);
    if (rest.length > 10) say(`     ... and ${rest.length - 10} more fresh entries of the same families`);
    for (const guard of temps.protectedFamilies) {
      if (guard.hits) say(`   KEEP   ${guard.prefix}*  n=${guard.hits}  — another lane's retention rule: ${guard.why}`);
    }
    say(`   not matched to a known family (left alone): ${temps.unknown} entries`);
  }
  say('');

  // 2. rust/target in worktrees whose session ended
  const ctx = {
    repo: opts.repo, stateDir: path.resolve(opts.stateDir), stateDirAbs: path.resolve(opts.stateDir), db: path.resolve(opts.db),
    apply: opts.apply, protectedPaths, protectedSessions, byWorktree: new Map(), activeRuns: new Set(), allSessions: new Map(), storeError: '',
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
    for (const row of sessions.all || []) ctx.allSessions.set(norm(row.id), row);
  }

  say(`2. build targets that no running cargo or deploy uses`);
  say(`   session db: ${ctx.db}${sessions.error ? `  UNREADABLE: ${sessions.error} (every candidate is refused)` : `  ${sessions.source}: ${sessions.bound.length} sessions bind a worktree, ${(sessions.all || []).length} sessions in total`}`);
  const blocked = deployInProgress(ctx);
  if (blocked.length) say(`   REFUSED for this run: a build or deploy is in progress — ${blocked.join('; ')}`);
  const prune = prunePass(opts, ctx, blocked);
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

  // 3-5. the safe categories: pre-update backups, graph quarantines, ended sessions' scratch
  const backups = backupPass(opts, ctx);
  const b3 = printCategory(say, opts, 3, `pre-update backups under ${backups.dir} (keep the newest ${opts.backupKeep} plus any a pending rollback names)`, backups, [
    `rollback evidence: ${backups.rollback ? `${backups.rollback.scanned} pending sentinel request(s) read${backups.rollback.error ? `; UNREADABLE: ${backups.rollback.error}` : ''}` : 'not read'}`,
    `snapshots found: ${backups.total ?? 0}`,
  ]);
  say('');
  const quarantine = graphQuarantinePass(opts, ctx);
  const b4 = printCategory(say, opts, 4, 'graph quarantines (keep the newest stamp whole, with its -wal/-shm/-journal)', quarantine, [
    `quarantine files found: ${quarantine.candidates} in ${quarantine.groups} stamp group(s); newest group kept per database: ${quarantine.keptGroups}`,
  ]);
  say('');
  const scratch = scratchPass(opts, ctx);
  const b5 = printCategory(say, opts, 5, `session scratch of sessions that ended more than ${opts.scratchAgeHours} h ago`, scratch, [
    `cutoff: ${iso(scratch.cutoff)} (a session that ended before it)`,
  ]);
  say('');

  const after = freeSpace(opts.repo);
  say(`free after:  ${after.error ? `UNMEASURABLE: ${after.error}` : `${human(after.availableBytes)} of ${human(after.totalBytes)} on ${after.mount}`}`);
  if (!before.error && !after.error) say(`freed by this pass: ${human(Math.max(0, after.availableBytes - before.availableBytes))} (free space moved from other writers too)`);
  const freedByCategory = {
    'bounded-temp': temps.error ? 0 : temps.expired.reduce((a, r) => a + (r.removed ? r.bytes : 0), 0),
    'build-targets': prune.applied.reduce((a, f) => a + (f.bytes || 0), 0),
    'pre-update-backups': b3.bytes,
    'graph-quarantine': b4.bytes,
    'session-scratch': b5.bytes,
  };
  // The plan is not the result: a dry run that reported its plan as `freed` would make the one number an
  // operator checks after an active run indistinguishable from the number before it.
  const wouldFreeByCategory = {
    'bounded-temp': temps.error ? 0 : temps.expired.reduce((a, r) => a + r.bytes, 0),
    'build-targets': prune.candidates.reduce((a, f) => a + (f.bytes || 0), 0),
    'pre-update-backups': b3.wouldBytes,
    'graph-quarantine': b4.wouldBytes,
    'session-scratch': b5.wouldBytes,
  };
  if (opts.apply) {
    say('');
    say('freed by category (bytes actually removed):');
    for (const [name, bytes] of Object.entries(freedByCategory)) say(`  ${name.padEnd(20)} ${human(bytes)}  (${bytes} B)`);
  } else {
    say('');
    say('would free by category (nothing removed in a dry run):');
    for (const [name, bytes] of Object.entries(wouldFreeByCategory)) say(`  ${name.padEnd(20)} ${human(bytes)}  (${bytes} B)`);
  }


  const result = {
    when: new Date().toISOString(),
    apply: opts.apply,
    minAgeHours: opts.minAgeHours,
    free: { before: before.error ? { error: before.error } : { availableBytes: before.availableBytes, totalBytes: before.totalBytes, mount: before.mount }, after: after.error ? { error: after.error } : { availableBytes: after.availableBytes, totalBytes: after.totalBytes, mount: after.mount } },
    temp: temps.error ? { error: temps.error } : {
      expired: temps.expired.map(r => ({ name: r.name, family: r.family, ageHours: r.ageHours, bytes: r.bytes, removed: r.removed === true })),
      kept: temps.kept.map(r => ({ name: r.name, family: r.family || null, why: r.why })),
      leftInUse: temps.kept.filter(r => r.kind === 'in_use').map(r => ({ name: r.name, family: r.family || null, pid: r.pid ?? null, source: r.source || null, bytes: r.bytes, why: r.why })),
      livenessUnproven: temps.kept.filter(r => r.kind === 'liveness_unproven').map(r => ({ name: r.name, family: r.family || null, why: r.why })),
      liveProcessScan: temps.scan ? { source: temps.scan.source, processes: temps.scan.processes, skippedOtherUser: temps.scan.skippedOtherUser, skippedPrivileged: temps.scan.skippedPrivileged, unreadableOwn: temps.scan.unreadableOwn, candidatesDecided: temps.scan.decided }
        : temps.procs && temps.procs.rows ? { source: temps.procs.source, processes: temps.procs.rows.length } : { error: (temps.procs && temps.procs.error) || null, candidatesDecided: temps.decided },
      protected: temps.protectedFamilies.filter(g => g.hits).map(g => ({ prefix: g.prefix, n: g.hits, why: g.why })),
      unknown: temps.unknown,
    },
    targets: prune.findings.map(f => ({ name: f.name, path: f.path, verdict: f.verdict, reason: f.reason, detail: f.detail, session: f.session || null, ended: f.sessionEnded ?? null, bytes: f.bytes, result: f.result || null })),
    backups: backups.error ? { error: backups.error } : {
      dir: backups.dir, keep: backups.keep, total: backups.total, rollback: backups.rollback,
      removed: backups.removed.map(r => ({ name: r.name, bytes: r.bytes, removed: r.removed === true })),
      kept: backups.kept.map(r => ({ name: r.name, bytes: r.bytes, why: r.why })),
    },
    quarantine: {
      files: quarantine.candidates, groups: quarantine.groups, keptGroups: quarantine.keptGroups,
      removed: quarantine.removed.map(r => ({ name: r.name, stamp: r.stamp, bytes: r.bytes, removed: r.removed === true })),
      kept: quarantine.kept.map(r => ({ name: r.name, stamp: r.stamp, bytes: r.bytes, why: r.why })),
    },
    scratch: scratch.error ? { error: scratch.error } : {
      dir: scratch.dir, cutoff: scratch.cutoff,
      removed: scratch.removed.map(r => ({ name: r.name, session: r.session, ageHours: r.ageHours, bytes: r.bytes, removed: r.removed === true })),
      kept: scratch.kept.map(r => ({ name: r.name, session: r.session || null, ageHours: r.ageHours ?? null, bytes: r.bytes, why: r.why })),
    },
    deployBlocked: blocked,
    freedByCategory,
    wouldFreeByCategory,
    freedBytes: freedByCategory['bounded-temp'] + freedByCategory['build-targets'] + freedByCategory['pre-update-backups'] + freedByCategory['graph-quarantine'] + freedByCategory['session-scratch'],
    wouldFreeBytes: wouldFreeByCategory['bounded-temp'] + wouldFreeByCategory['build-targets'] + wouldFreeByCategory['pre-update-backups'] + wouldFreeByCategory['graph-quarantine'] + wouldFreeByCategory['session-scratch'],
  };
  const reportPath = opts.report === null ? path.join(opts.stateDir, 'disk', `reclaim-${new Date().toISOString().replace(/[:.]/g, '-')}${opts.apply ? '-apply' : ''}.json`) : opts.report;
  try {
    fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    fs.writeFileSync(reportPath, `${JSON.stringify(result, null, 2)}\n`);
    say(`report: ${reportPath}`);
  } catch (e) { say(`report NOT written (${e.message})`); }

  return ctx.storeError ? 1 : 0;
}

// The library half: the predicates a test can ask without starting a pass. `neverTouch` is exported
// because the never-touch list is the thing that must be provable, and a test that can only observe its
// effect on a fixture cannot tell "the list refused it" from "no category wanted it".
export { neverTouch, decodeScratchName, pendingRollbackEvidence, rollbackPins, deployInProgress, removeSafely, options, PRE_UPDATE_RE, QUARANTINE_RE };

// Only when this file is the program. An import gets the predicates and no pass, so a test never
// removes anything by loading the module.
const asProgram = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (asProgram) {
  try {
    process.exitCode = main();
  } catch (e) {
    process.stderr.write(`reclaim-disk: ${e.stack || e.message}\n`);
    process.exitCode = 1;
  }
}
