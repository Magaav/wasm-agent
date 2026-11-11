#!/usr/bin/env node
// The active reclaim pass's own evidence: scripts/reclaim-disk.mjs.
//
// WHY THIS FILE EXISTS. On 11/11 disk-full froze this node twice (00:47 and ~01:18) and killed it for
// ~1h44, and the same day on openclaw the numbers were 6.8 GB of `*-pre-update` backups, ~2.5 GB of
// `graph.db.malformed-*` quarantines and 1.8 GB of scratch for one ended session. The pass that removes
// them runs from a job, unattended, on a schedule. An unattended removal is only as good as the rule it
// removes by, so each rule is proved here against a fixture that contains, on purpose:
//
//   * more backups than the keep count, one of them named by a pending rollback (kept though it is old);
//   * three quarantine stamps, with the newest one's `-wal`/`-shm` siblings (kept whole) and the live
//     `graph.db` + its own journal next to them (never touched);
//   * scratch for a session that ended 48 h ago, one that ended an hour ago, a live one, one the store
//     has never heard of, and a directory whose name is not hex at all (only the first may go);
//   * a managed session worktree whose session ended: its `rust/target` is build output and goes, the
//     worktree, its branch and its own files are the session's work and stay;
//   * every file on the never-touch list, checked twice - by the predicate and by what survives a run.
//
// The last block proves the dry run is a dry run (nothing removed, the plan printed) and that `--apply`
// and `--dry-run` together are refused rather than decided by argument order.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { neverTouch, decodeScratchName, PRE_UPDATE_RE, QUARANTINE_RE, options } from './reclaim-disk.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(REPO, 'scripts', 'reclaim-disk.mjs');
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-reclaim-disk-'));
const STATE = path.join(WORK, 'state');
const TREE = path.join(WORK, 'repo');
const TEMP = path.join(WORK, 'temp');
const started = Date.now();
let passed = 0;

function check(name, condition, detail = '') {
  if (!condition) {
    console.error(`FAIL ${name}${detail ? `: ${detail}` : ''}`);
    process.exitCode = 1;
    throw new Error(`check failed: ${name}`);
  }
  passed += 1;
  console.log(`ok   ${name}`);
}

function write(file, bytes = 0) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${'x'.repeat(Math.max(0, bytes - 1))}\n`);
  return file;
}

function exists(...parts) { return fs.existsSync(path.join(...parts)); }
function gone(file) { return !fs.existsSync(file); }

function git(args, cwd = TREE) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function run(args, env = {}) {
  // Hermetic: the ambient `WASM_AGENT_DB` names the live node's store, and a pass that read it instead of
  // the fixture's would age the fixture by another store's verdict - which is exactly the bug this
  // environment stripping now makes impossible to reintroduce silently.
  const clean = { ...process.env, ...env };
  delete clean.WASM_AGENT_DB;
  delete clean.WASM_AGENT_STATE_DIR;
  const r = spawnSync(process.execPath, [CLI, '--db', DB, ...args], {
    cwd: TREE, encoding: 'utf8', env: clean,
  });
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

// ── the fixture ──────────────────────────────────────────────────────────────────────────────────
const NOW = Math.floor(Date.now() / 1000);
const HOUR = 3600;
fs.mkdirSync(STATE, { recursive: true });
fs.mkdirSync(TEMP, { recursive: true });
fs.mkdirSync(TREE, { recursive: true });
git(['init', '-q', '-b', 'main']);
git(['config', 'user.email', 'fixture@example.invalid']);
git(['config', 'user.name', 'fixture']);
write(path.join(TREE, 'README.md'), 32);
git(['add', '.']);
git(['commit', '-q', '-m', 'fixture']);

// The session store: the only proof of ownership this pass accepts.
const DB = path.join(STATE, 'memory.db');
{
  const db = new DatabaseSync(DB);
  db.exec(`CREATE TABLE sessions (id TEXT PRIMARY KEY, worktree TEXT, ended_at INTEGER, workspace_state TEXT, workspace_branch TEXT);
           CREATE TABLE runs (session_id TEXT, ended_at INTEGER);`);
  const insert = db.prepare('INSERT INTO sessions VALUES (?,?,?,?,?)');
  insert.run('aaaaaaaa-0000-4000-8000-000000000001', null, NOW - 48 * HOUR, 'unbound', '');     // scratch 48 h old
  insert.run('bbbbbbbb-0000-4000-8000-000000000002', null, NOW - HOUR, 'unbound', '');          // scratch 1 h old
  insert.run('cccccccc-0000-4000-8000-000000000003', null, null, 'unbound', '');                // live, no end
  insert.run('dddddddd-0000-4000-8000-000000000004', null, NOW - 5 * HOUR, 'unbound', '');      // ended, run open
  db.prepare('INSERT INTO runs VALUES (?,?)').run('dddddddd-0000-4000-8000-000000000004', null);
  db.close();
}

// 1. pre-update backups: six, the oldest of them pinned by a pending rollback.
const backups = [];
for (let i = 1; i <= 6; i += 1) {
  const stamp = `2026010${i}T01010${i}Z-00000000-0000-4000-8000-00000000000${i}-pre-update`;
  backups.push(stamp);
  write(path.join(STATE, 'backups', stamp, '1-memory.db'), 4096);
}
// A seventh, oldest, still named by a sentinel request that has not been completed.
const pinned = '20251231T235959Z-ffffffff-0000-4000-8000-ffffffffffff-pre-update';
write(path.join(STATE, 'backups', pinned, '1-memory.db'), 2048);
write(path.join(STATE, 'sentinel', 'requests', '001-rollback.json'), 64);
fs.writeFileSync(path.join(STATE, 'sentinel', 'requests', '001-rollback.json'),
  `${JSON.stringify({ action: 'deploy', restore_from: pinned })}\n`);
// A completed request naming another snapshot must NOT pin it: finished work is not a pending rollback.
write(path.join(STATE, 'sentinel', 'done', '002-done.json'), 64);
fs.writeFileSync(path.join(STATE, 'sentinel', 'done', '002-done.json'),
  `${JSON.stringify({ action: 'deploy', restore_from: backups[1] })}\n`);
// A snapshot with its own marker is a pending rollback whatever the store says.
const marked = '20251230T000000Z-eeeeeeee-0000-4000-8000-eeeeeeeeeeee-pre-update';
write(path.join(STATE, 'backups', marked, 'ROLLBACK-PENDING'), 8);

// 2. graph quarantines: three stamps, plus the live database and its own journal.
const stamps = ['20261110T221600Z', '20261111T030400Z', '20261111T050300Z'];
for (const stamp of stamps) {
  write(path.join(STATE, `graph.db.malformed-${stamp}`), 4096);
  write(path.join(STATE, `graph.db.malformed-${stamp}-wal`), 512);
  if (stamp !== stamps[0]) write(path.join(STATE, `graph.db.malformed-${stamp}-shm`), 128);
}
write(path.join(STATE, 'graph.db'), 8192);
write(path.join(STATE, 'graph.db-wal'), 4096);

// 3. session scratch: hex-named directories, one per shape above.
const hex = (text) => Buffer.from(text, 'utf8').toString('hex');
const scratch = {
  old: hex('aaaaaaaa-0000-4000-8000-000000000001'),
  fresh: hex('bbbbbbbb-0000-4000-8000-000000000002'),
  live: hex('cccccccc-0000-4000-8000-000000000003'),
  running: hex('dddddddd-0000-4000-8000-000000000004'),
  unknown: hex('99999999-0000-4000-8000-000000000009'),
};
for (const name of Object.values(scratch)) write(path.join(STATE, 'session-scratch', name, 'evidence.txt'), 1024);
write(path.join(STATE, 'session-scratch', 'ui-probe-not-a-session', 'evidence.txt'), 256);

// 4. a managed session worktree whose session ended: build output inside it, work beside it.
const WT_ID = 'aaaaaaaa-1111-4000-8000-00000000000a';
const WT_NAME = `wa-worktree-${WT_ID}`;
const WT = path.join(STATE, WT_NAME);
git(['worktree', 'add', '-q', '-b', `change/wa-session-${WT_ID}`, WT, 'main']);
write(path.join(WT, 'rust', 'target', 'release', 'wa.exe'), 8192);
write(path.join(WT, 'NOTES.md'), 64);
{
  const db = new DatabaseSync(DB);
  db.prepare('INSERT INTO sessions VALUES (?,?,?,?,?)')
    .run(WT_ID, WT, NOW - 2 * HOUR, 'allocated', `change/wa-session-${WT_ID}`);
  db.close();
}

// 5. the never-touch list, as files a wrong pattern could match.
const protectedFiles = {
  // The store itself is the fixture the sessions above were written into: naming it here is what proves
  // nothing moved it. (Writing over it - which this block did first - silently replaced the database with
  // a text file, and the pass then refused every category for a store it could not read.)
  'memory.db': DB,
  'memory.db-wal': write(path.join(STATE, 'memory.db-wal'), 16),
  'graph.db': path.join(STATE, 'graph.db'),
  'graph.db-wal': path.join(STATE, 'graph.db-wal'),
  'rendezvous.db': write(path.join(STATE, 'rendezvous.db'), 16),
  vault: write(path.join(STATE, 'vault', 'secrets.sqlite'), 16),
  'node.key': write(path.join(STATE, 'node.key'), 16),
  'binding.json': write(path.join(STATE, 'binding.json'), 16),
  'components/graph.wasm': write(path.join(STATE, 'components', 'graph.wasm'), 16),
  'sentinel/requests/001-rollback.json': path.join(STATE, 'sentinel', 'requests', '001-rollback.json'),
  'archive/old.db': write(path.join(STATE, 'archive', 'old.db'), 16),
  'serve.pid': write(path.join(STATE, 'serve.pid'), 8),
};

// ── 1. the never-touch predicate, asked directly ────────────────────────────────────────────────
const ctx = { stateDirAbs: STATE };
for (const [label, full] of Object.entries(protectedFiles)) {
  check(`never-touch: ${label} is refused with a reason`, typeof neverTouch(full, ctx) === 'string' && neverTouch(full, ctx).length > 0, String(neverTouch(full, ctx)));
}
check('never-touch: a pre-update backup is not protected (it is a category, not state)',
  neverTouch(path.join(STATE, 'backups', backups[0]), ctx) === null);
check('never-touch: a quarantine file is not protected',
  neverTouch(path.join(STATE, `graph.db.malformed-${stamps[0]}`), ctx) === null);
check('never-touch: the state directory itself is refused', neverTouch(STATE, ctx) !== null);
check('never-touch: a path outside the state directory is refused, and named as outside',
  /outside/.test(String(neverTouch(path.join(TREE, 'rust', 'target'), ctx))), String(neverTouch(path.join(TREE, 'rust', 'target'), ctx)));
check('never-touch: a path that leaves the state directory is refused',
  neverTouch(path.join(STATE, 'backups', '..', 'memory.db'), ctx) !== null);
// The predicate binds the build category too: it removes inside the state directory, so a future rule that
// pointed it at `components/` or `sentinel/` must be refused by the same list, not by its own copy of one.
check('never-touch: a build target under a protected directory would be refused',
  neverTouch(path.join(STATE, 'components', 'rust', 'target'), ctx) === 'installed components state');
check('never-touch: a managed worktree\'s own target is not protected (it is a category, not state)',
  neverTouch(path.join(STATE, 'wa-worktree-x', 'rust', 'target'), ctx) === null);

// ── 2. the name rules ───────────────────────────────────────────────────────────────────────────
check('a pre-update stamp matches the backup rule', PRE_UPDATE_RE.test(backups[0]));
check('a backup of another label is not a pre-update backup', !PRE_UPDATE_RE.test('20260101T010101Z-00000000-0000-4000-8000-000000000000-t1'));
const q = QUARANTINE_RE.exec(`graph.db.malformed-${stamps[2]}-wal`);
check('a quarantine journal parses to its stamp and suffix', q && q.groups.stamp === stamps[2] && q.groups.suffix === '-wal', JSON.stringify(q && q.groups));
check('the live database is not a quarantine', QUARANTINE_RE.exec('graph.db') === null);
check('a scratch name decodes back to its session', decodeScratchName(scratch.old) === 'aaaaaaaa-0000-4000-8000-000000000001');
check('a non-hex scratch name decodes to nothing (unknown owner)', decodeScratchName('ui-probe-not-a-session') === null);

// ── 3. options: the dry run flag, and the two switches that cannot both be true ─────────────────
check('--dry-run is accepted', options(['--dry-run']).dryRun === true && options(['--dry-run']).apply === false);
check('--apply is accepted', options(['--apply']).apply === true);
check('--apply with --dry-run is refused, not decided by order', (() => {
  try { options(['--apply', '--dry-run']); return false; } catch { return true; }
})());
check('--backup-keep defaults to 3', options([]).backupKeep === 3);
check('--scratch-age-hours defaults to 24', options([]).scratchAgeHours === 24);
check('the low-disk threshold defaults to 5 GB and 5%', options([]).lowDiskBytes === 5 * 1024 ** 3 && options([]).lowDiskPercent === 5);

// ── 4. the dry run: the plan, and nothing removed ───────────────────────────────────────────────
const REPORT1 = path.join(WORK, 'report-dry.json');
const dry = run(['--dry-run', '--repo', TREE, '--state-dir', STATE, '--temp-dir', TEMP, '--report', REPORT1]);
check('the dry run exits 0', dry.status === 0, dry.stderr);
check('the dry run says it is a dry run', /DRY RUN/.test(dry.stdout), dry.stdout.slice(0, 400));
check('the dry run names the pre-update plan with its bytes', /pre-update backups/.test(dry.stdout) && /would remove: 3 entries/.test(dry.stdout), dry.stdout);
check('the dry run removed nothing: every backup is still there', backups.every(name => exists(STATE, 'backups', name)));
check('the dry run removed nothing: every quarantine is still there',
  stamps.every(stamp => exists(STATE, `graph.db.malformed-${stamp}`)));
check('the dry run removed nothing: the old scratch is still there', exists(STATE, 'session-scratch', scratch.old));
check('the dry run removed nothing: the worktree target is still there', exists(WT, 'rust', 'target'));
const dryReport = JSON.parse(fs.readFileSync(REPORT1, 'utf8'));
check('the report says apply=false and freed nothing', dryReport.apply === false && dryReport.freedBytes === 0, JSON.stringify(dryReport.freedByCategory));
check('the dry run still reports the plan it would carry out', dryReport.wouldFreeBytes > 0 && dryReport.wouldFreeByCategory['pre-update-backups'] > 0, JSON.stringify(dryReport.wouldFreeByCategory));

// ── 5. the active run ───────────────────────────────────────────────────────────────────────────
const REPORT2 = path.join(WORK, 'report-apply.json');
const applied = run(['--apply', '--repo', TREE, '--state-dir', STATE, '--temp-dir', TEMP, '--report', REPORT2]);
check('the active run exits 0', applied.status === 0, applied.stderr);
const report = JSON.parse(fs.readFileSync(REPORT2, 'utf8'));

// 5a. pre-update backups: newest 3 stay, the rest go, the pinned ones stay.
const stillThere = backups.filter(name => exists(STATE, 'backups', name));
check('backups: exactly the newest 3 survive', stillThere.length === 3 && stillThere.every(name => backups.slice(-3).includes(name)), stillThere.join(','));
check('backups: the oldest is gone', gone(path.join(STATE, 'backups', backups[0])));
check('backups: the snapshot a pending request names survives though it is the oldest of all', exists(STATE, 'backups', pinned));
check('backups: the snapshot with its own rollback marker survives', exists(STATE, 'backups', marked));
check('backups: a snapshot named only by a COMPLETED request is not pinned, and goes', gone(path.join(STATE, 'backups', backups[1])));
check('backups: the report counts the bytes it freed', report.freedByCategory['pre-update-backups'] > 0, JSON.stringify(report.freedByCategory));
check('backups: the report names why each survivor survived', (report.backups.kept || []).some(row => /newest|rollback/.test(row.why)), JSON.stringify(report.backups.kept));

// 5b. graph quarantines: the newest stamp whole, older stamps gone, the live database untouched.
check('quarantine: the newest stamp keeps its base file', exists(STATE, `graph.db.malformed-${stamps[2]}`));
check('quarantine: the newest stamp keeps its -wal', exists(STATE, `graph.db.malformed-${stamps[2]}-wal`));
check('quarantine: the newest stamp keeps its -shm', exists(STATE, `graph.db.malformed-${stamps[2]}-shm`));
check('quarantine: the older stamp is gone with its journal', gone(path.join(STATE, `graph.db.malformed-${stamps[1]}`)) && gone(path.join(STATE, `graph.db.malformed-${stamps[1]}-wal`)));
check('quarantine: the oldest stamp is gone', gone(path.join(STATE, `graph.db.malformed-${stamps[0]}`)));
check('quarantine: the live graph.db is untouched', exists(STATE, 'graph.db') && fs.statSync(path.join(STATE, 'graph.db')).size === 8192);
check('quarantine: the live graph.db-wal is untouched', exists(STATE, 'graph.db-wal'));
check('quarantine: the report counts the bytes it freed', report.freedByCategory['graph-quarantine'] > 0, JSON.stringify(report.freedByCategory));

// 5c. session scratch: only the session that ended more than 24 h ago.
check('scratch: the 48 h-old session\'s scratch is gone', gone(path.join(STATE, 'session-scratch', scratch.old)));
check('scratch: an hour-old session\'s scratch is kept', exists(STATE, 'session-scratch', scratch.fresh));
check('scratch: a live session\'s scratch is kept', exists(STATE, 'session-scratch', scratch.live));
check('scratch: a session with an open run keeps its scratch', exists(STATE, 'session-scratch', scratch.running));
check('scratch: a session the store never heard of keeps its scratch', exists(STATE, 'session-scratch', scratch.unknown));
check('scratch: a name that is not a session id keeps its scratch', exists(STATE, 'session-scratch', 'ui-probe-not-a-session'));
check('scratch: the report counts the bytes it freed', report.freedByCategory['session-scratch'] > 0, JSON.stringify(report.freedByCategory));

// 5d. build output: the ended session's target goes, the worktree and its files stay.
check('build: the ended session\'s rust/target is gone', gone(path.join(WT, 'rust', 'target')));
check('build: the worktree itself stays', exists(WT));
check('build: the work beside the target stays (NOTES.md)', exists(WT, 'NOTES.md'));
check('build: the branch is still there', git(['-C', WT, 'rev-parse', '--abbrev-ref', 'HEAD']) === `change/wa-session-${WT_ID}`);
check('build: the report counts the bytes it freed', report.freedByCategory['build-targets'] > 0, JSON.stringify(report.freedByCategory));

// 5e. nothing on the never-touch list moved.
for (const [label, full] of Object.entries(protectedFiles)) {
  check(`never-touch after a real run: ${label} still exists`, fs.existsSync(full));
}
check('never-touch after a real run: the session store is still readable', (() => {
  const db = new DatabaseSync(DB, { readOnly: true });
  const n = db.prepare('SELECT COUNT(*) AS n FROM sessions').get().n;
  db.close();
  return n === 5;
})());

// 5f. the total is the sum of the categories, and it is not zero.
check('the report\'s total equals its categories', report.freedBytes === Object.values(report.freedByCategory).reduce((a, b) => a + b, 0), `${report.freedBytes} vs ${JSON.stringify(report.freedByCategory)}`);
check('the active run freed exactly what the dry run said it would free',
  JSON.stringify(report.freedByCategory) === JSON.stringify(dryReport.wouldFreeByCategory),
  `plan ${JSON.stringify(dryReport.wouldFreeByCategory)} -> freed ${JSON.stringify(report.freedByCategory)}`);
check('an active run names each category\'s bytes on stdout', /freed by category/.test(applied.stdout) && /pre-update-backups/.test(applied.stdout), applied.stdout.slice(-600));

// ── 6. a second active run has nothing left to do, and says so ──────────────────────────────────
const second = run(['--apply', '--repo', TREE, '--state-dir', STATE, '--temp-dir', TEMP, '--report', path.join(WORK, 'report-2.json')]);
const secondReport = JSON.parse(fs.readFileSync(path.join(WORK, 'report-2.json'), 'utf8'));
check('the second run exits 0', second.status === 0, second.stderr);
check('the second run frees nothing more from the aged categories',
  secondReport.freedByCategory['pre-update-backups'] === 0 && secondReport.freedByCategory['graph-quarantine'] === 0 && secondReport.freedByCategory['session-scratch'] === 0,
  JSON.stringify(secondReport.freedByCategory));
check('the second run keeps exactly the newest 3 backups', fs.readdirSync(path.join(STATE, 'backups')).length === 5, fs.readdirSync(path.join(STATE, 'backups')).join(','));

// ── 7. the deploy guard: build output is refused while a deploy is pending ──────────────────────
write(path.join(STATE, 'deploy-pending.json'), 32);
fs.writeFileSync(path.join(STATE, 'deploy-pending.json'), `${JSON.stringify({ state: 'deploy_pending', since: NOW, bound_seconds: 900 })}\n`);
write(path.join(WT, 'rust', 'target', 'release', 'wa.exe'), 4096);
const guarded = run(['--apply', '--repo', TREE, '--state-dir', STATE, '--temp-dir', TEMP, '--report', path.join(WORK, 'report-guard.json')]);
const guardReport = JSON.parse(fs.readFileSync(path.join(WORK, 'report-guard.json'), 'utf8'));
check('the guarded run exits 0', guarded.status === 0, guarded.stderr);
check('the guarded run names the deploy', guardReport.deployBlocked.length > 0 && /deploy-pending/.test(guardReport.deployBlocked.join(' ')), JSON.stringify(guardReport.deployBlocked));
check('the guarded run refuses the build category', guardReport.freedByCategory['build-targets'] === 0);
check('the guarded run left the target in place', exists(WT, 'rust', 'target', 'release', 'wa.exe'));
check('the refusal is visible on stdout', /REFUSED for this run/.test(guarded.stdout), guarded.stdout);
// An expired marker is not a deploy: `deploy_pause.lua` ignores one past its own bound, and so does this.
fs.writeFileSync(path.join(STATE, 'deploy-pending.json'), `${JSON.stringify({ state: 'deploy_pending', since: NOW - 4000, bound_seconds: 900 })}\n`);
const stale = run(['--apply', '--repo', TREE, '--state-dir', STATE, '--temp-dir', TEMP, '--report', path.join(WORK, 'report-stale.json')]);
const staleReport = JSON.parse(fs.readFileSync(path.join(WORK, 'report-stale.json'), 'utf8'));
check('an expired deploy marker no longer blocks, and the target is pruned', staleReport.deployBlocked.length === 0 && staleReport.freedByCategory['build-targets'] > 0, JSON.stringify(staleReport.deployBlocked));

// ── 8. the keep count is a knob, and the report is written where it was asked to be ─────────────
for (let i = 7; i <= 9; i += 1) write(path.join(STATE, 'backups', `2026020${i}T01010${i}Z-00000000-0000-4000-8000-00000000000${i}-pre-update`, '1-memory.db'), 1024);
const keepOne = run(['--apply', '--backup-keep', '1', '--repo', TREE, '--state-dir', STATE, '--temp-dir', TEMP, '--report', path.join(WORK, 'report-keep1.json')]);
const keepOneReport = JSON.parse(fs.readFileSync(path.join(WORK, 'report-keep1.json'), 'utf8'));
check('--backup-keep 1 is honoured', keepOne.status === 0 && keepOneReport.backups.keep === 1, keepOne.stderr);
const survivors = fs.readdirSync(path.join(STATE, 'backups')).sort();
check('--backup-keep 1 leaves the newest plus the two pinned snapshots',
  survivors.length === 3 && survivors.includes(pinned) && survivors.includes(marked) && survivors.includes('20260209T010109Z-00000000-0000-4000-8000-000000000009-pre-update'),
  survivors.join(','));
check('a state directory that does not exist is a named SKIP, not a crash', (() => {
  const missing = run(['--dry-run', '--repo', TREE, '--state-dir', path.join(WORK, 'nope'), '--temp-dir', TEMP, '--report', path.join(WORK, 'report-missing.json')]);
  const r = JSON.parse(fs.readFileSync(path.join(WORK, 'report-missing.json'), 'utf8'));
  // Exit 0: every category answered, and each answer is a refusal with a reason. A crash would be a
  // number nobody can act on, and a silent pass would be a category that never ran.
  return missing.status === 0
    && (missing.stdout.match(/SKIPPED/g) || []).length >= 2
    && typeof r.backups.error === 'string'
    && typeof r.scratch.error === 'string'
    && r.freedBytes === 0;
})(), 'a missing state directory must say which category could not run, and remove nothing');

console.log(`reclaim-disk: ${passed} checks passed in ${Math.round((Date.now() - started) / 1000)}s`);
try { fs.rmSync(WORK, { recursive: true, force: true }); } catch { /* windows may still hold a lock */ }
