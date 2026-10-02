// ATTACK 6: what the one-row-per-repository unique index was giving up, and what a reader sees
// when duplicates/orphans exist. Plus the migration-record edge case (two waves, one store).
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {pathToFileURL} from 'node:url';

const [W, SCRATCH] = process.argv.slice(2);
const mod = rel => pathToFileURL(path.join(W, rel)).href;
const {create, inspect} = await import(mod('scripts/wave-lifecycle.mjs'));
const entry = await import(mod('scripts/wave-entry.mjs'));
const migrate = await import(mod('scripts/wave-migrate.mjs'));

const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
const NODE_SCHEMA = `CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
  workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
  workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
  started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`;

function fixture(name) {
  const dir = path.join(SCRATCH, name), repo = path.join(dir, 'canonical'), executor = path.join(dir, 'executor'), store = path.join(dir, 'state'), data = path.join(dir, 'data');
  fs.mkdirSync(repo, {recursive: true}); fs.mkdirSync(executor, {recursive: true}); fs.mkdirSync(data, {recursive: true});
  git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'f'); git(repo, 'config', 'user.email', 'f@invalid');
  fs.writeFileSync(path.join(repo, 'seed'), 'x\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'base');
  git(repo, 'remote', 'add', 'origin', 'https://example.invalid/x.git');
  const db = new DatabaseSync(path.join(data, 'memory.db')); db.exec(NODE_SCHEMA); db.close();
  const manifest = {id: name, owner: 'review-fixture', repo, executor_cwd: executor, bootstrap: true, activity: {data, process_probe: false},
    steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, '-e', '0'], post: {argv: [process.execPath, '-e', '0']}})),
    verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, '-e', '0']}]))};
  return {dir, repo, executor, store, data, manifest};
}
const raw = store => new DatabaseSync(path.join(store, 'waves.sqlite'), {readOnly: true});
const indexes = store => { const db = raw(store); const r = db.prepare("SELECT name,sql FROM sqlite_master WHERE type='index'").all(); db.close(); return r.map(x => x.name); };
const readers = (store, repo) => {
  const db = raw(store);
  const latest = db.prepare('SELECT id,state FROM waves ORDER BY created_at DESC LIMIT 1').get();
  const all = db.prepare('SELECT id,state,created_at FROM waves ORDER BY created_at DESC').all();
  db.close();
  return {readers_see: latest, rows_in_store: all};
};

// ---- A: two unfinished waves for one repository ------------------------------------------------
const a = fixture('a-two-waves');
create(a.store, a.manifest);
console.log('indexes after create():', JSON.stringify(indexes(a.store)));
create(a.store, {...a.manifest, id: 'a-two-waves-second', bootstrap: false});
console.log('indexes after a SECOND create():', JSON.stringify(indexes(a.store)));
const state = readers(a.store, a.repo);
console.log('A two unfinished rows for one repository:', JSON.stringify(state, null, 1));
const orphan = inspect(a.store, 'a-two-waves');
console.log('A the older row is still there and still unfinished:', JSON.stringify({id: orphan.id, state: orphan.state, steps: orphan.steps.map(s => `${s.name}:${s.state}`), next_action: orphan.next_action.kind}));
console.log('A does ANY reader mention it? checkAdmission sees only:', JSON.stringify((() => { const r = entry.checkAdmission(a.repo, {phase: 'observe'}); return {wave_id: r.wave_id, ok: r.ok, mode: r.mode, reason: r.reason}; })()));
const plan = migrate.plan(a.store, null);
console.log('A wave-migrate plan without an id also picks:', plan.wave_id);

// ---- B: the migration record is written with flag 'wx' -----------------------------------------
let secondApply;
try { const r = migrate.apply(a.store, 'a-two-waves', 'review-worker'); secondApply = `ok, record=${r.record}`; }
catch (e) { secondApply = `THREW ${e.code || ''} ${e.message}`; }
console.log('B second apply() in the same store:', secondApply);
const legacyRows = (() => { const db = raw(a.store); const r = db.prepare('SELECT id,legacy IS NOT NULL migrated FROM waves').all(); db.close(); return r; })();
console.log('B rows after that throw:', JSON.stringify(legacyRows));

// ---- C: what the reader does with a created_at tie ---------------------------------------------
const c = fixture('c-tie');
create(c.store, c.manifest);
const db = new DatabaseSync(path.join(c.store, 'waves.sqlite'));
const row = db.prepare('SELECT * FROM waves').get();
const tie = row.created_at;
db.prepare('INSERT INTO waves(id,repo,manifest,manifest_hash,state,owner,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)')
  .run('c-tie-second', row.repo, JSON.stringify({...c.manifest, id: 'c-tie-second'}), 'x', 'pending', 'someone', tie, tie);
db.close();
const picks = new Set();
for (let i = 0; i < 20; i++) { const db2 = raw(c.store); picks.add(db2.prepare('SELECT id FROM waves ORDER BY created_at DESC LIMIT 1').get().id); db2.close(); }
console.log('C two rows sharing created_at; the reader picked:', JSON.stringify([...picks]));
console.log('C checkAdmission names:', JSON.stringify((() => { const r = entry.checkAdmission(c.repo, {phase: 'observe'}); return {wave_id: r.wave_id, ok: r.ok, reason: r.reason}; })()));
console.log(`\nfixtures retained at ${SCRATCH}`);
