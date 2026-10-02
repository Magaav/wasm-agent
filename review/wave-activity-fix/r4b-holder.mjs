// RE-VERIFY 4b: (a) a PROCESS that appears must make a child-only claim positive again;
// (b) the symmetric staleness the fix does NOT name: a stale `steering_runs` row (state active)
//     with a registered tree and nothing running - is it ON, and can it be resolved?
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {register} from '../scripts/wave-entry.mjs';
import {create} from '../scripts/wave-lifecycle.mjs';
import {activityInventory} from '../scripts/lib/wave-activity.mjs';
import {observe as observeActivity, resolve as resolveActivity} from '../scripts/wave-activity.mjs';

const source = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-rev4b-'));
let checks = 0;
const check = (v, label) => { assert.ok(v, label); checks++; console.log(`  PASS ${label}`); };
const hash = x => crypto.createHash('sha256').update(x).digest('hex');
const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
const NODE_SCHEMA = `
  CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
    workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
    workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
    started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
  CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',
    boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
  CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`;
function fixture(name) {
  const dir = path.join(root, name), repo = path.join(dir, 'canonical'), executor = path.join(dir, 'executor'), data = path.join(dir, 'data');
  fs.mkdirSync(executor, {recursive: true}); fs.mkdirSync(repo); fs.mkdirSync(data, {recursive: true});
  git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'f'); git(repo, 'config', 'user.email', 'f@invalid');
  fs.writeFileSync(path.join(repo, 'seed'), 'x\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'base');
  const db = new DatabaseSync(path.join(data, 'memory.db')); db.exec(NODE_SCHEMA); db.close();
  const driver = path.join(executor, 'driver.cjs'); fs.writeFileSync(driver, 'console.log(JSON.stringify({ok:true}));');
  const manifest = {id: name, owner: 'review-fixture', repo, executor_cwd: executor, bootstrap: true, activity: {data},
    steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, driver], post: {argv: [process.execPath, driver]}})),
    verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, driver]}]))};
  const configFile = path.join(executor, 'config.json');
  fs.writeFileSync(configFile, JSON.stringify({repo, data, source_root: source, monitor_mode: 'external-cli-test', process_probe: true}));
  const main = git(repo, 'rev-parse', 'HEAD');
  const ticket = path.join(executor, 'bootstrap.json');
  fs.writeFileSync(ticket, JSON.stringify({schema: 1, kind: 'wave-bootstrap-admission', repo, main, refs_sha256: hash(git(repo, 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads/')), issuer: 'fixture-coordinator', reviewer: 'fixture-independent'}));
  register(repo, configFile, ticket);
  const store = path.join(repo, '.git', 'wa-waves');
  create(store, manifest);
  return {dir, repo, executor, data, store, configFile, manifest};
}
const src = (fx, probe) => ({kind: 'node-runtime', repo: fx.repo, data: fx.data, memory_db: path.join(fx.data, 'memory.db'), process_probe: probe});
const db_ = fx => new DatabaseSync(path.join(fx.data, 'memory.db'));
const createNext = (fx, id) => { try { create(fx.store, {...fx.manifest, id, bootstrap: false}); return 'ADMITTED'; } catch (e) { return e.message; } };

let holder;
try {
  console.log('--- (a) a PROCESS that appears makes a child-only claim positive again ---');
  const a = fixture('holder');
  const tree = path.join(a.data, 'wa-worktree-held');
  git(a.repo, 'worktree', 'add', '--detach', tree);
  const db = db_(a);
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,parent_session_id,started_at,ended_at,updated_at) VALUES('held',?,1,'allocated',?,?,'parent',0,NULL,0)")
    .run(tree.replaceAll('\\', '/'), a.repo.replaceAll('\\', '/'), JSON.stringify({executor: {owner_boot: 'boot-held'}}));
  db.prepare("INSERT INTO child_completions(child_id,target_id,parent_session,state,run_id) VALUES('child-held','','held','dispatching','run-held')").run();
  db.close();
  check(activityInventory(src(a, false)).activity === 'unverifiable', 'with no process and no turn the child claim is unverifiable');
  // A REAL long-lived process whose command line names the tree.
  holder = spawn(process.execPath, ['-e', 'setTimeout(()=>{},45000)', tree.replaceAll('\\', '/')], {stdio: 'ignore', windowsHide: true});
  await new Promise(resolve => setTimeout(resolve, 1500));
  const probed = activityInventory(src(a, true));
  console.log(`  with the holder process running: activity=${probed.activity} agents=${probed.agents.length} corroborated=${probed.agents[0]?.corroborated}`);
  check(probed.activity === 'on' && probed.agents[0]?.corroborated === true, 'the appearing process makes the claim POSITIVE again (activity on, corroborated true)');
  check(createNext(a, 'held-next').startsWith('previous_wave_active'), 'and create() refuses it as an active wave');

  console.log('--- (b) the SYMMETRIC staleness: a stale steering_runs row with a registered tree ---');
  const b = fixture('stale-turn');
  const bTree = path.join(b.data, 'wa-worktree-stale-turn');
  git(b.repo, 'worktree', 'add', '--detach', bTree);
  const db2 = db_(b);
  db2.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,parent_session_id,started_at,ended_at,updated_at) VALUES('stale-turn',?,1,'allocated',?,?,'parent',0,NULL,0)")
    .run(bTree.replaceAll('\\', '/'), b.repo.replaceAll('\\', '/'), JSON.stringify({executor: {owner_boot: 'boot-stale'}}));
  db2.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES('stale-turn','fixture','run-stale','boot-stale','active',1)").run();
  db2.close();
  const stale = activityInventory(src(b, true));   // real probe: NO process names this tree
  console.log(`  stale turn row, no process, no child: activity=${stale.activity} agents=${stale.agents.length} claims=${stale.claims.length} corroborated=${stale.agents[0]?.corroborated}`);
  const refused = createNext(b, 'stale-next');
  console.log(`  create() => ${refused.slice(0, 120)}`);
  const obs = observeActivity(b.configFile);
  console.log(`  observe: unresolved_activity_claims=${obs.unresolved_activity_claims.length} agents=${obs.agents.length} activity=${obs.activity}`);
  let resolution = 'accepted';
  try { const r = resolveActivity(b.configFile, 'stale-turn', 'observed: nothing is running for this tree', {run: 'run-stale', actor: 'review-worker'}); resolution = `accepted: activity_after=${r.activity_after}`; }
  catch (e) { resolution = `REFUSED: ${e.message}`; }
  console.log(`  resolve() => ${resolution}`);
  check(stale.activity === 'on', 'a stale turn row with a registered tree reads ON');
  check(obs.unresolved_activity_claims.length === 0, 'observe reports NO unresolved claim for it (it is counted as a positive agent)');
  check(/REFUSED/.test(resolution), 'and the named way out REFUSES to resolve it');
  console.log(`\n${checks} checks passed`);
} catch (e) {
  console.error(`RE-VERIFY 4b FAILED (${checks} checks passed): ${e.message}\nfixtures retained at ${root}`);
  process.exitCode = 1;
} finally {
  try { holder?.kill(); } catch { /* already gone */ }
}
