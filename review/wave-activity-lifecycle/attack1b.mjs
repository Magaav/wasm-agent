// ATTACK 1b (corrected): the admission answer for the LIVE row's shape, before/after the change,
// IDLE and ACTIVE, pending / blocked / migrated-legacy. Store read = COPY of the live store.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {pathToFileURL} from 'node:url';

const [W, OLDW, LIVE_STORE_COPY, SCRATCH] = process.argv.slice(2);
const mod = (root, rel) => pathToFileURL(path.join(root, rel)).href;
const newEntry = await import(mod(W, 'scripts/wave-entry.mjs'));
const oldEntry = await import(mod(OLDW, 'scripts/wave-entry.mjs'));
const migrate = await import(mod(W, 'scripts/wave-migrate.mjs'));

const NODE_SCHEMA = `CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
  workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
  workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
  started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`;
const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };

function runtimeFixture(name, {live}) {
  const dir = path.join(SCRATCH, name), repo = path.join(dir, 'canonical'), data = path.join(dir, 'data');
  fs.mkdirSync(repo, {recursive: true}); fs.mkdirSync(data, {recursive: true});
  git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'f'); git(repo, 'config', 'user.email', 'f@invalid');
  fs.writeFileSync(path.join(repo, 'seed'), 'x\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'base');
  git(repo, 'remote', 'add', 'origin', 'https://example.invalid/x.git');
  const db = new DatabaseSync(path.join(data, 'memory.db')); db.exec(NODE_SCHEMA);
  if (live) {
    const tree = path.join(data, 'wa-worktree-live-child');
    git(repo, 'worktree', 'add', '--detach', tree);
    db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,parent_session_id,started_at,ended_at,updated_at) VALUES(?,?,1,'allocated',?,?,'parent',0,NULL,0)")
      .run('live-child', tree.replaceAll('\\', '/'), repo.replaceAll('\\', '/'), JSON.stringify({executor: {owner_boot: 'boot-live'}}));
    db.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES('live-child','fixture','run-live','boot-live','active',1)").run();
  }
  db.close();
  return {repo, data};
}

let n = 0;
function storeCase({rowState, fixture, migrated}) {
  const repo = path.join(SCRATCH, `case${++n}-${rowState}${migrated ? '-migrated' : ''}`);
  fs.rmSync(repo, {recursive: true, force: true}); fs.mkdirSync(repo);
  git(repo, 'init', '-q'); git(repo, 'remote', 'add', 'origin', 'https://example.invalid/x.git');
  const store = path.join(repo, '.git', 'wa-waves');
  fs.cpSync(LIVE_STORE_COPY, store, {recursive: true});
  const reg = path.join(store, 'registration.json');
  const registration = JSON.parse(fs.readFileSync(reg, 'utf8')); registration.repo = repo; fs.writeFileSync(reg, JSON.stringify(registration, null, 1));
  const db = new DatabaseSync(path.join(store, 'waves.sqlite'));
  const row = db.prepare('SELECT id,manifest FROM waves ORDER BY created_at DESC LIMIT 1').get();
  const manifest = JSON.parse(row.manifest);
  // DISCLOSED EDIT OF THE COPY ONLY: redirect the activity source at a private fixture (so the OFF
  // and ON branches can both be exercised). The live row's own columns are otherwise untouched.
  manifest.activity = {data: fixture.data, process_probe: false};
  if (fixture.repo !== manifest.repo) manifest.repo = fixture.repo;   // the activity source's repository
  db.prepare('UPDATE waves SET manifest=?,state=? WHERE id=?').run(JSON.stringify(manifest), rowState, row.id);
  db.close();
  if (migrated) migrate.apply(store, row.id, 'review-worker-8077a6cf');
  return {repo, id: row.id, store};
}

const idle = runtimeFixture('idle', {live: false});
const active = runtimeFixture('active', {live: true});
const PHASES = ['produce', 'allocate', 'land', 'admit'];
const CASES = [
  ['IDLE  + pending  (the live row exactly as it is now)', {rowState: 'pending', fixture: idle}],
  ['IDLE  + blocked', {rowState: 'blocked', fixture: idle}],
  ['IDLE  + migrated legacy row', {rowState: 'pending', fixture: idle, migrated: true}],
  ['ACTIVE+ blocked', {rowState: 'blocked', fixture: active}],
  ['ACTIVE+ migrated legacy row', {rowState: 'pending', fixture: active, migrated: true}],
];
for (const [label, opts] of CASES) {
  const c = storeCase(opts);
  const short = r => ({ok: r.ok, reason: r.reason, activity: r.activity, convergence: r.convergence, runtime_state: r.runtime_state});
  console.log(`\n===== ${label} =====`);
  for (const p of PHASES) {
    const before = short(oldEntry.checkAdmission(c.repo, {phase: p}));
    const after = short(newEntry.checkAdmission(c.repo, {phase: p}));
    const same = JSON.stringify({ok: before.ok, reason: before.reason}) === JSON.stringify({ok: after.ok, reason: after.reason});
    console.log(`  ${p.padEnd(9)} BEFORE(old code) ${JSON.stringify(before)}`);
    console.log(`  ${p.padEnd(9)} AFTER (new code) ${JSON.stringify(after)}   ${same ? 'SAME ok/reason' : '*** CHANGED ***'}`);
  }
}
console.log(`\nfixtures retained at ${SCRATCH}`);
