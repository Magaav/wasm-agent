// REVIEWER: section 3 - corner 2 (a COMPLETE newest row beside an OLDER unfinished row) on a COPY of
// the LIVE store: the older unfinished row IS the live row (copied, repointed), the newest row is
// created on the copy and set `complete`. Nothing here touches the live store.
//
// Usage: node c2-phases.mjs <tipTree> <oldTree> <scratchRoot>
import {pathToFileURL} from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';

const [TIP, OLD, ROOT] = process.argv.slice(2);
const mod = (root, rel) => pathToFileURL(path.join(root, rel)).href;
const tipEntry = await import(mod(TIP, 'scripts/wave-entry.mjs'));
const oldEntry = await import(mod(OLD, 'scripts/wave-entry.mjs'));
const tipLife = await import(mod(TIP, 'scripts/wave-lifecycle.mjs'));

const LIVE_REPO = 'C:/Users/Victor/orca/projects/wasm-agent';
const LIVE_DATA = 'C:/Users/Victor/.wasm-agent';
const LIVE_STORE = path.join(LIVE_REPO, '.git', 'wa-waves');
const STALE = '33b4e818-0278-47a1-823a-b756517ec787';

const C = path.join(ROOT, 'c');
fs.rmSync(C, {recursive: true, force: true});
const repo = path.join(C, 'repo'), data = path.join(C, 'data'), executor = path.join(C, 'executor');
fs.mkdirSync(data, {recursive: true}); fs.mkdirSync(repo, {recursive: true}); fs.mkdirSync(executor, {recursive: true});
const git = (cwd, ...args) => { const r = spawnSync('git', ['-C', cwd, ...args], {encoding: 'utf8', windowsHide: true}); if (r.status !== 0) throw Error(`git ${args.join(' ')}: ${r.stderr}`); return r.stdout.trim(); };
git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'reviewer'); git(repo, 'config', 'user.email', 'reviewer@invalid');
fs.writeFileSync(path.join(repo, 'seed'), 'reviewer fixture\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'review baseline');
const store = path.join(repo, '.git', 'wa-waves');
fs.mkdirSync(store, {recursive: true});
for (const name of ['waves.sqlite', 'registration.json', 'migration.json']) fs.copyFileSync(path.join(LIVE_STORE, name), path.join(store, name));
const configFile = path.join(C, 'config.json');
fs.writeFileSync(configFile, JSON.stringify({repo, data, source_root: TIP, monitor_mode: 'external-cli-test', process_probe: true}, null, 1));
const registration = JSON.parse(fs.readFileSync(path.join(store, 'registration.json'), 'utf8'));
registration.repo = repo; registration.config = configFile; registration.source_root = TIP;
fs.writeFileSync(path.join(store, 'registration.json'), JSON.stringify(registration));
const writeRepo = repo.replaceAll('\\', '/').toLowerCase();
const waveDb = new DatabaseSync(path.join(store, 'waves.sqlite'));
const liveRow = waveDb.prepare('SELECT * FROM waves').get();
const liveManifest = JSON.parse(liveRow.manifest); liveManifest.repo = repo; liveManifest.activity = {data};
waveDb.prepare('UPDATE waves SET repo=?, manifest=? WHERE id=?').run(writeRepo, JSON.stringify(liveManifest), liveRow.id);
waveDb.close();

// the copy of the LIVE node store: the live stale row, repointed (a registered tree, so it is a
// POSITIVE claim - the state where "agents are working" is the honest reading of the copied row).
const live = new DatabaseSync(path.join(LIVE_DATA, 'memory.db'), {readOnly: true});
const sessions = live.prepare('SELECT * FROM sessions WHERE id=?').all(STALE);
const turns = live.prepare('SELECT * FROM steering_runs WHERE session_id=?').all(STALE);
const ddl = live.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' AND name IN ('sessions','steering_runs','child_completions')").all();
live.close();
const db = new DatabaseSync(path.join(data, 'memory.db'));
for (const t of ddl) db.exec(t.sql);
const tree = path.join(data, `wa-worktree-${STALE}`).replaceAll('\\', '/');
git(repo, 'worktree', 'add', '--detach', tree);
for (const s of sessions) db.prepare('INSERT INTO sessions(id,parent_session_id,worktree,workspace_required,workspace_state,workspace_branch,workspace_base_commit,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)').run(s.id, s.parent_session_id, tree, s.workspace_required, s.workspace_state, s.workspace_branch, s.workspace_base_commit, repo, s.workspace_start_state, s.started_at, s.ended_at, s.updated_at);
for (const t of turns) db.prepare('INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,?,?,?,?,?)').run(t.session_id, t.owner, t.run_id, t.boot, t.state, t.updated_at);
db.close();
const setTurn = state => { const d = new DatabaseSync(path.join(data, 'memory.db')); d.prepare('UPDATE steering_runs SET state=? WHERE session_id=?').run(state, STALE); d.close(); };
const treeOf = id => path.join(data, `wa-worktree-${id}`).replaceAll('\\', '/');

const driver = path.join(executor, 'driver.cjs');
fs.writeFileSync(driver, 'console.log(JSON.stringify({ok:true}));');
let dbCounter = 0;
const manifest = id => ({id, owner: 'review-fixture', repo, executor_cwd: executor, bootstrap: false, activity: {data, process_probe: true},
  steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, driver], post: {argv: [process.execPath, driver]}})),
  verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, driver]}]))});
const setState = (id, state) => { const d = new DatabaseSync(path.join(store, 'waves.sqlite')); d.prepare('UPDATE waves SET state=?, reason=NULL WHERE id=?').run(state, id); d.close(); };
const phases = entry => Object.fromEntries(['produce', 'allocate', 'land', 'admit', 'observe'].map(p => { const r = entry.checkAdmission(repo, {phase: p}); return [p, r.ok ? `ok(${r.runtime_state}${r.note ? '; note' : ''})` : r.reason]; }));
const say = (label, value) => console.log(`${label} ${typeof value === 'string' ? value : JSON.stringify(value)}`);
const rowsNow = () => { const d = new DatabaseSync(path.join(store, 'waves.sqlite'), {readOnly: true}); const r = d.prepare('SELECT id,state,created_at FROM waves ORDER BY created_at DESC').all(); d.close(); return r; };

console.log('=== fixture: a copy of the LIVE store; the OLDER unfinished row IS the live row ===');
say('copied live row', {id: liveRow.id, state: liveRow.state, created_at: liveRow.created_at, legacy: liveRow.legacy !== null});
setTurn('settled');   // the copy's older row is idle while the newest row is created on the copy
tipLife.create(store, manifest('review-newest'));
say('rows after creating the newest row on the copy', rowsNow());
say('1. older unfinished (live row) + newest PENDING - tip', phases(tipEntry));
say('1b. the same store on the PRE-DELTA code', phases(oldEntry));
setState('review-newest', 'complete');
say('2. NEWEST COMPLETE + older unfinished - tip', phases(tipEntry));
say('2b. NEWEST COMPLETE + older unfinished - PRE-DELTA code', phases(oldEntry));

// the closing freeze: does it still fence producing/allocating with a complete newest row?
fs.writeFileSync(path.join(store, 'freeze.json'), JSON.stringify({wave_id: 'review-newest'}));
say('3. NEWEST COMPLETE + freeze.json - tip', phases(tipEntry));
fs.rmSync(path.join(store, 'freeze.json'));

// a LIVE older row: the copied live turn is active again and a process names its tree.
setTurn('active');
say('4. NEWEST COMPLETE + the older row positively ON (the copied live turn, active) - tip', phases(tipEntry));
say('4b. the same state - PRE-DELTA code', phases(oldEntry));
setState('review-newest', 'pending');
say('4b2. the SAME positively-ON older row with the newest row merely PENDING - tip (the baseline policy: is the admission new?)', phases(tipEntry));
setState('review-newest', 'complete');
say('4c. and what the WAVE START (create()) does in that state - tip', (() => { try { return {ok: tipLife.create(store, manifest('review-third')).ok}; } catch (e) { return {ok: false, reason: e.message}; } })());
setTurn('settled');
say('5. the same store with the older row idle (turn settled) - tip', phases(tipEntry));

// multiple older unfinished rows: the refusal must name them all.
const d = new DatabaseSync(path.join(store, 'waves.sqlite'));
d.prepare("INSERT INTO waves(id,repo,manifest,manifest_hash,state,owner,created_at,updated_at) SELECT 'review-older-A',repo,manifest,manifest_hash,'pending',owner,created_at-1,updated_at FROM waves WHERE id='review-newest'").run();
d.prepare("INSERT INTO waves(id,repo,manifest,manifest_hash,state,owner,created_at,updated_at) SELECT 'review-older-B',repo,manifest,manifest_hash,'blocked',owner,created_at-2,updated_at FROM waves WHERE id='review-newest'").run();
d.close();
say('6. rows now', rowsNow());
say('6a. land with two older unfinished rows beside the complete newest - tip', phases(tipEntry).land);
say('6b. admit', phases(tipEntry).admit);
say('the complete branch, verbatim', (() => { const s = fs.readFileSync(path.join(TIP, 'scripts', 'wave-entry.mjs'), 'utf8'); const i = s.indexOf('if(current.state===', s.indexOf('wave_closing_frozen')); return s.slice(i, i + 430); })());
console.log(`fixture retained at ${repo}`);
