// Two DIFFERENT waves migrated in one store: does the second apply()'s durable record survive?
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {pathToFileURL} from 'node:url';

const [W, SCRATCH] = process.argv.slice(2);
const migrate = await import(pathToFileURL(path.join(W, 'scripts/wave-migrate.mjs')).href);
const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
const NODE_SCHEMA = `CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
  workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
  workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
  started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`;

const dir = path.join(SCRATCH, 'two-waves'), repo = path.join(dir, 'canonical'), executor = path.join(dir, 'executor'), store = path.join(dir, 'state'), data = path.join(dir, 'data');
fs.rmSync(dir, {recursive: true, force: true});
fs.mkdirSync(repo, {recursive: true}); fs.mkdirSync(executor, {recursive: true}); fs.mkdirSync(data, {recursive: true});
git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'f'); git(repo, 'config', 'user.email', 'f@invalid');
fs.writeFileSync(path.join(repo, 'seed'), 'x\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'base');
const db0 = new DatabaseSync(path.join(data, 'memory.db')); db0.exec(NODE_SCHEMA); db0.close();
fs.mkdirSync(store, {recursive: true});
const manifest = id => ({id, owner: 'review-fixture', repo, executor_cwd: executor, bootstrap: true, activity: {data, process_probe: false},
  steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, '-e', '0'], post: {argv: [process.execPath, '-e', '0']}})),
  verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, '-e', '0']}]))});
const db = new DatabaseSync(path.join(store, 'waves.sqlite'));
db.exec(`CREATE TABLE IF NOT EXISTS waves(id TEXT PRIMARY KEY,repo TEXT NOT NULL,manifest TEXT NOT NULL,manifest_hash TEXT NOT NULL,state TEXT NOT NULL,reason TEXT,owner TEXT NOT NULL,boot TEXT,pid INTEGER,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,receipt TEXT);
CREATE TABLE IF NOT EXISTS steps(wave TEXT NOT NULL,position INTEGER NOT NULL,name TEXT NOT NULL,state TEXT NOT NULL,operation_id TEXT,attempts INTEGER NOT NULL DEFAULT 0,post_attempts INTEGER NOT NULL DEFAULT 0,next_at INTEGER NOT NULL DEFAULT 0,result TEXT,PRIMARY KEY(wave,position));
CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY,wave TEXT NOT NULL,at INTEGER NOT NULL,type TEXT NOT NULL,body TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS waves_repo ON waves(repo,created_at);`);
for (const [i, id] of ['first', 'second'].entries())
  db.prepare('INSERT INTO waves(id,repo,manifest,manifest_hash,state,owner,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)').run(id, repo, JSON.stringify(manifest(id)), `h-${id}`, 'pending', 'review-fixture', 1000 + i, 1000 + i);
db.close();

const first = migrate.apply(store, 'first', 'review-worker');
console.log('first apply  =>', JSON.stringify({ok: first.ok, record: path.basename(first.record)}));
console.log('migration.json exists:', fs.existsSync(path.join(store, 'migration.json')), 'names:', JSON.parse(fs.readFileSync(path.join(store, 'migration.json'), 'utf8')).wave_id);
let second;
try { second = `ok ${JSON.stringify(migrate.apply(store, 'second', 'review-worker'))}`; }
catch (e) { second = `THREW ${e.code || ''}: ${e.message}`; }
console.log('second apply =>', second);
const check = new DatabaseSync(path.join(store, 'waves.sqlite'), {readOnly: true});
console.log('rows now:', JSON.stringify(check.prepare('SELECT id,state,legacy IS NOT NULL migrated FROM waves').all()));
check.close();
console.log('migration.json still names:', JSON.parse(fs.readFileSync(path.join(store, 'migration.json'), 'utf8')).wave_id);
const rev = migrate.revert(store, 'second');
console.log('revert(second) after that =>', JSON.stringify({ok: rev.ok, legacy_migrated: rev.legacy_migrated}));
console.log('migration.json after reverting the SECOND wave:', fs.existsSync(path.join(store, 'migration.json')) ? JSON.parse(fs.readFileSync(path.join(store, 'migration.json'), 'utf8')).wave_id : 'removed');
console.log(`fixture retained at ${dir}`);
