// ATTACK 2: make the derived ON/OFF lie.
//
// The predicate is  in_flight = open && state not resolved/unresolved && (a live turn row || a live child row),
// then a real registered worktree must also exist, or the turn is dropped as stale.
// Five adversarial shapes, each a real private Git repo + a real private node store:
//   B. a running turn with NO worktree at all          (does it report OFF while a turn runs?)
//   C. a CRASHED finisher row left `running`           (does the row ever make the wave active?)
//   D. a child with a real registered tree but NO session row
//   E. a STALE child_completions row, nothing else running (false ON that never clears?)
//   F. a live turn whose tree registration was lost     (OFF while an agent is working?)
// and the probe: the same inventory with the process probe on and off.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {create, inspect} from '../scripts/wave-lifecycle.mjs';
import {waveActivity, activityInventory} from '../scripts/lib/wave-activity.mjs';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-review-lie-'));
const NODE_SCHEMA = `
  CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
    workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
    workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
    started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
  CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',
    boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
  CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`;
const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };

function fixture(name) {
  const dir = path.join(root, name), repo = path.join(dir, 'canonical'), executor = path.join(dir, 'executor'), store = path.join(dir, 'state'), data = path.join(dir, 'data');
  fs.mkdirSync(repo, {recursive: true}); fs.mkdirSync(executor, {recursive: true}); fs.mkdirSync(data, {recursive: true});
  git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'f'); git(repo, 'config', 'user.email', 'f@invalid');
  fs.writeFileSync(path.join(repo, 'seed'), 'x\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'base');
  git(repo, 'remote', 'add', 'origin', 'https://example.invalid/x.git');   // NOT an isolated fixture
  const db = new DatabaseSync(path.join(data, 'memory.db')); db.exec(NODE_SCHEMA); db.close();
  const manifest = {
    id: name, owner: 'review-fixture', repo, executor_cwd: executor, bootstrap: true,
    activity: {data, process_probe: false},
    steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, '-e', '0'], post: {argv: [process.execPath, '-e', '0']}})),
    verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, '-e', '0']}])),
  };
  return {dir, repo, executor, store, data, manifest};
}
const source = fx => ({kind: 'node-runtime', repo: fx.repo, data: fx.data, memory_db: path.join(fx.data, 'memory.db'), process_probe: false});
const store_ = fx => new DatabaseSync(path.join(fx.data, 'memory.db'));
function session(fx, {id, worktree = '', state = 'allocated', turn = null, child = null, ended = null}) {
  const db = store_(fx);
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,parent_session_id,started_at,ended_at,updated_at) VALUES(?,?,1,?,?,?,?,0,?,0)")
    .run(id, worktree.replaceAll('\\', '/'), state, fx.repo.replaceAll('\\', '/'), JSON.stringify({executor: {owner_boot: `boot-${id}`}}), 'parent', ended);
  if (turn) db.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,'fixture',?,'boot-x',?,1)").run(id, `run-${id}`, turn);
  if (child) db.prepare("INSERT INTO child_completions(child_id,target_id,parent_session,state,run_id) VALUES(?,?,?,?,?)").run(`child-of-${id}`, '', id, child, `run-${id}`);
  db.close();
}
const setChildState = (fx, id, state) => { const db = store_(fx); db.prepare('UPDATE child_completions SET state=? WHERE parent_session=?').run(state, id); db.close(); };
const rawState = (fx, id, state) => { const db = new DatabaseSync(path.join(fx.store, 'waves.sqlite')); db.prepare('UPDATE waves SET state=? WHERE id=?').run(state, id); db.close(); };

const report = [];
try {
  // ---- B: a running turn with NO worktree at all -------------------------------------------------
  const b = fixture('b-no-worktree');
  create(b.store, b.manifest);
  session(b, {id: 'turn-no-tree', worktree: '', state: 'unbound', turn: 'active'});
  const invB = activityInventory(source(b));
  const vB = waveActivity(source(b), {id: 'b-no-worktree', state: 'pending'});
  report.push(['B running turn, no worktree', {on: invB.on, agents: invB.agents.length, unresolved: invB.unresolved.map(u => u.reason)}]);
  let bCreated = 'THREW';
  try { create(b.store, {...b.manifest, id: 'b-next', bootstrap: false}); bCreated = 'ADMITTED the next wave'; } catch (e) { bCreated = `refused: ${e.message}`; }
  report.push(['B create() with a live turn but no tree', bCreated]);

  // ---- C: a crashed finisher's row left `running` ------------------------------------------------
  const c = fixture('c-crashed-row');
  create(c.store, c.manifest);
  rawState(c, 'c-crashed-row', 'running');
  const cInspect = inspect(c.store, 'c-crashed-row');
  const cVerdict = waveActivity(source(c), {id: 'c-crashed-row', state: 'running'});
  report.push(['C row left running, nothing in flight', {inspect_state: cInspect.state, bookkeeping_state: cInspect.bookkeeping_state, activity: cVerdict.activity, runtime_state: cVerdict.runtime_state}]);
  let cCreated = 'THREW';
  try { create(c.store, {...c.manifest, id: 'c-next', bootstrap: false}); cCreated = 'ADMITTED the next wave'; } catch (e) { cCreated = `refused: ${e.message}`; }
  report.push(['C create() over a running row', cCreated]);

  // ---- D: a child with a real registered tree but NO session row ---------------------------------
  const d = fixture('d-child-no-row');
  create(d.store, d.manifest);
  const dTree = path.join(d.data, 'wa-worktree-ghost-child');
  git(d.repo, 'worktree', 'add', '--detach', dTree);
  const invD = activityInventory(source(d));
  report.push(['D registered managed tree, no session row', {on: invD.on, agents: invD.agents.length, unresolved: invD.unresolved.map(u => u.reason)}]);
  let dCreated = 'THREW';
  try { create(d.store, {...d.manifest, id: 'd-next', bootstrap: false}); dCreated = 'ADMITTED the next wave'; } catch (e) { dCreated = `refused: ${e.message}`; }
  report.push(['D create() with an unowned registered tree', dCreated]);

  // ---- E: a STALE child_completions row, parent idle, nothing else running ------------------------
  const e = fixture('e-stale-child-row');
  create(e.store, e.manifest);
  const eTree = path.join(e.data, 'wa-worktree-parent-open');
  git(e.repo, 'worktree', 'add', '--detach', eTree);
  session(e, {id: 'parent-open', worktree: eTree, state: 'allocated', turn: null, child: 'running'});
  const invE1 = activityInventory(source(e));
  const invE1probe = activityInventory({...source(e), process_probe: true});
  report.push(['E stale child row, parent allocated with a real tree, no turn', {on: invE1.on, agents: invE1.agents.length, child: invE1.agents[0]?.child, turn: invE1.agents[0]?.turn, with_probe: invE1probe.on, corroborated: invE1probe.agents[0]?.corroborated}]);
  let eCreated = 'THREW';
  try { create(e.store, {...e.manifest, id: 'e-next', bootstrap: false}); eCreated = 'ADMITTED the next wave'; } catch (err) { eCreated = `refused: ${err.message}`; }
  report.push(['E create() with a stale child row', eCreated]);
  setChildState(e, 'parent-open', 'settled');
  report.push(['E after the child row settles', {on: activityInventory(source(e)).on}]);

  // ---- F: a live turn whose worktree registration was lost ---------------------------------------
  const f = fixture('f-lost-registration');
  create(f.store, f.manifest);
  const fTree = path.join(f.data, 'wa-worktree-lost');
  fs.mkdirSync(fTree, {recursive: true});           // exists on disk, never registered with Git
  session(f, {id: 'lost-reg', worktree: fTree, state: 'allocated', turn: 'active'});
  const invF = activityInventory(source(f));
  report.push(['F live turn, tree exists but is not registered', {on: invF.on, agents: invF.agents.length, unresolved: invF.unresolved.map(u => u.reason)}]);
  let fCreated = 'THREW';
  try { create(f.store, {...f.manifest, id: 'f-next', bootstrap: false}); fCreated = 'ADMITTED the next wave'; } catch (err) { fCreated = `refused: ${err.message}`; }
  report.push(['F create() with a lost registration', fCreated]);

  // ---- G: a binding mid-transition (`releasing`) while a turn is running --------------------------
  const g = fixture('g-mid-release');
  create(g.store, g.manifest);
  const gTree = path.join(g.data, 'wa-worktree-releasing');
  git(g.repo, 'worktree', 'add', '--detach', gTree);
  session(g, {id: 'mid-release', worktree: gTree, state: 'releasing', turn: 'active'});
  const invG = activityInventory(source(g));
  report.push(['G turn running while the binding is mid-release', {on: invG.on, agents: invG.agents.length, unresolved: invG.unresolved.map(u => u.reason)}]);
  let gCreated = 'THREW';
  try { create(g.store, {...g.manifest, id: 'g-next', bootstrap: false}); gCreated = 'ADMITTED the next wave'; } catch (err) { gCreated = `refused: ${err.message}`; }
  report.push(['G create() with a live turn mid-release', gCreated]);

  for (const [label, value] of report) console.log(`${label}\n   -> ${JSON.stringify(value)}`);
  console.log(`\nfixture retained at ${root}`);
} catch (e) {
  console.error('ATTACK 2 ERROR:', e.message, '\nfixtures at', root);
  process.exitCode = 1;
}
