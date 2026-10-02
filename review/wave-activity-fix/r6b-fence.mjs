// RE-VERIFY 6b: the fence found in Q6 - newest row `complete` beside an older unfinished row.
// How far does it reach, and is there a way out through the public API?
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {register, checkAdmission} from '../scripts/wave-entry.mjs';
import {pathToFileURL} from 'node:url';
const reviewed = await import(pathToFileURL(path.join(process.argv[2], 'scripts/wave-entry.mjs')).href);
import {create, list} from '../scripts/wave-lifecycle.mjs';

const source = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-rev6b-'));
const hash = x => crypto.createHash('sha256').update(x).digest('hex');
const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
const NODE_SCHEMA = `CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`;
const dir = path.join(root, 'f'), repo = path.join(dir, 'canonical'), executor = path.join(dir, 'executor'), data = path.join(dir, 'data');
fs.mkdirSync(executor, {recursive: true}); fs.mkdirSync(repo); fs.mkdirSync(data, {recursive: true});
git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'f'); git(repo, 'config', 'user.email', 'f@invalid');
fs.writeFileSync(path.join(repo, 'seed'), 'x\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'base');
const db0 = new DatabaseSync(path.join(data, 'memory.db')); db0.exec(NODE_SCHEMA); db0.close();
const driver = path.join(executor, 'driver.cjs'); fs.writeFileSync(driver, 'console.log(JSON.stringify({ok:true}));');
const manifest = id => ({id, owner: 'review-fixture', repo, executor_cwd: executor, bootstrap: true, activity: {data, process_probe: false},
  steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, driver], post: {argv: [process.execPath, driver]}})),
  verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, driver]}]))});
const configFile = path.join(executor, 'config.json');
fs.writeFileSync(configFile, JSON.stringify({repo, data, source_root: source, monitor_mode: 'external-cli-test'}));
const main = git(repo, 'rev-parse', 'HEAD');
const ticket = path.join(executor, 'bootstrap.json');
fs.writeFileSync(ticket, JSON.stringify({schema: 1, kind: 'wave-bootstrap-admission', repo, main, refs_sha256: hash(git(repo, 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads/')), issuer: 'fixture-coordinator', reviewer: 'fixture-independent'}));
register(repo, configFile, ticket);
const store = path.join(repo, '.git', 'wa-waves');
const setState = (id, state) => { const db = new DatabaseSync(path.join(store, 'waves.sqlite')); db.prepare('UPDATE waves SET state=? WHERE id=?').run(state, id); db.close(); };
const phases = () => Object.fromEntries(['produce', 'allocate', 'land', 'admit'].map(p => { const r = checkAdmission(repo, {phase: p}); return [p, r.ok ? 'ok' : r.reason]; }));

create(store, manifest('older'));
setState('older', 'blocked');
console.log('1. older blocked, no newer row:', JSON.stringify(phases()));
create(store, manifest('newer'));
console.log('2. newer pending beside it:', JSON.stringify(phases()), 'unfinished:', JSON.stringify(list(store).unfinished));
setState('newer', 'complete');
console.log('3. NEWEST COMPLETE, older blocked (fix):', JSON.stringify(phases()));
console.log('3b. the same state on the REVIEWED code 6a61338:', JSON.stringify(Object.fromEntries(['produce','allocate','land','admit'].map(p => { const r = reviewed.checkAdmission(repo, {phase: p}); return [p, r.ok ? 'ok' : r.reason]; }))));
console.log('   list().unfinished =', JSON.stringify(list(store).unfinished));
let created = 'ADMITTED';
try { const r = create(store, manifest('third')); created = `ADMITTED (previous=${r.previous?.id}/${r.previous?.state}, unfinished=${JSON.stringify(r.unfinished?.map(u => u.id))})`; }
catch (e) { created = `refused: ${e.message}`; }
console.log('4. create() in that state =>', created);
console.log('5. after that create():', JSON.stringify(phases()), 'unfinished:', JSON.stringify(list(store).unfinished));
console.log(`fixtures at ${root}`);
