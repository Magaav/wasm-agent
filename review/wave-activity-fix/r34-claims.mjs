// RE-VERIFY 3+4: every shape where a claim of current work fails to be positive must read
// `unverifiable` (never OFF) and `create()` must refuse it BY NAME; and a false ON must be a named
// claim with a named way out that cannot be borrowed by a later claim.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {register, checkAdmission} from '../scripts/wave-entry.mjs';
import {create} from '../scripts/wave-lifecycle.mjs';
import {activityInventory} from '../scripts/lib/wave-activity.mjs';
import {observe as observeActivity, resolve as resolveActivity} from '../scripts/wave-activity.mjs';

const source = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-rev3-'));
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; console.log(`  PASS ${label}`); };
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
  const driver = path.join(executor, 'driver.cjs');
  fs.writeFileSync(driver, `console.log(JSON.stringify({ok:true}));`);
  const manifest = {id: name, owner: 'review-fixture', repo, executor_cwd: executor, bootstrap: true, activity: {data, process_probe: false},
    steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, driver], post: {argv: [process.execPath, driver]}})),
    verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, driver]}]))};
  const configFile = path.join(executor, 'config.json');
  fs.writeFileSync(configFile, JSON.stringify({repo, data, source_root: source, monitor_mode: 'external-cli-test'}));
  const main = git(repo, 'rev-parse', 'HEAD');
  const ticket = path.join(executor, 'bootstrap.json');
  fs.writeFileSync(ticket, JSON.stringify({schema: 1, kind: 'wave-bootstrap-admission', repo, main, refs_sha256: hash(git(repo, 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads/')), issuer: 'fixture-coordinator', reviewer: 'fixture-independent'}));
  register(repo, configFile, ticket);
  const store = path.join(repo, '.git', 'wa-waves');
  create(store, manifest);
  return {dir, repo, executor, data, store, configFile, manifest};
}
const src = fx => ({kind: 'node-runtime', repo: fx.repo, data: fx.data, memory_db: path.join(fx.data, 'memory.db'), process_probe: false});
const db_ = fx => new DatabaseSync(path.join(fx.data, 'memory.db'));
function session(fx, {id, worktree = '', state = 'allocated', turn = null, child = null}) {
  const db = db_(fx);
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,parent_session_id,started_at,ended_at,updated_at) VALUES(?,?,1,?,?,?,'parent',0,NULL,0)")
    .run(id, worktree.replaceAll('\\', '/'), state, fx.repo.replaceAll('\\', '/'), JSON.stringify({executor: {owner_boot: `boot-${id}`}}));
  if (turn) db.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,'fixture',?,'boot-x',?,1)").run(id, `run-${id}`, turn);
  if (child) db.prepare("INSERT INTO child_completions(child_id,target_id,parent_session,state,run_id) VALUES(?,?,?,?,?)").run(child, '', id, child, `run-${id}`);
  db.close();
}
const createNext = (fx, id) => { try { create(fx.store, {...fx.manifest, id, bootstrap: false}); return 'ADMITTED'; } catch (e) { return e.message; } };

try {
  console.log('--- Q3: every non-positive claim shape is UNVERIFIABLE, never OFF, and create() refuses by name ---');
  const shapes = [
    ['worktree missing on disk and in Git', {id: 'missing-tree', worktree: '', state: 'allocated', turn: 'active'}],
    ['tree exists but is NOT registered with Git', {id: 'unregistered-tree', worktree: path.join('DATA', 'wa-worktree-unregistered'), state: 'allocated', turn: 'active'}],
    ['binding mid-release', {id: 'mid-release', worktree: path.join('DATA', 'wa-worktree-mid'), state: 'releasing', turn: 'active'}],
    ['claim on a RESOLVED binding', {id: 'resolved-binding', worktree: path.join('DATA', 'wa-worktree-res'), state: 'parked', turn: 'active'}],
  ];
  for (const [label, shape] of shapes) {
    const fx = fixture(`q3-${shape.id}`);
    if (label.includes('NOT registered')) { fs.mkdirSync(path.join(fx.data, 'wa-worktree-unregistered'), {recursive: true}); }
    if (label.includes('mid-release')) { git(fx.repo, 'worktree', 'add', '--detach', path.join(fx.data, 'wa-worktree-mid')); }
    if (label.includes('RESOLVED')) { git(fx.repo, 'worktree', 'add', '--detach', path.join(fx.data, 'wa-worktree-res')); }
    session(fx, {...shape, worktree: shape.worktree.replace('DATA', fx.data.replaceAll('\\', '/'))});
    const inv = activityInventory(src(fx));
    const claim = inv.claims.map(c => c.claim).join('|');
    console.log(`  shape "${label}": activity=${inv.activity} on=${inv.on} off=${inv.off} claim=${claim}`);
    check(inv.activity === 'unverifiable' && inv.off === false, `${label}: the answer is unverifiable, never OFF`);
    const refused = createNext(fx, 'next');
    console.log(`     create() => ${refused.slice(0, 130)}`);
    check(/previous_wave_activity_unverifiable:/.test(refused), `${label}: create() refuses by that name instead of admitting the next wave`);
    check(checkAdmission(fx.repo, {phase: 'produce'}).ok === true, `${label}: lanes keep producing`);
    check(checkAdmission(fx.repo, {phase: 'produce'}).activity === 'unverifiable', `${label}: the admission answer names it, not idle`);
  }

  console.log('--- Q4: the false ON is a named claim with a named way out that cannot be borrowed ---');
  const fx = fixture('q4');
  const tree = path.join(fx.data, 'wa-worktree-stale');
  git(fx.repo, 'worktree', 'add', '--detach', tree);
  session(fx, {id: 'stale', worktree: tree, state: 'allocated', turn: null, child: 'child-stale'});
  db_(fx).prepare("UPDATE child_completions SET state='dispatching' WHERE parent_session='stale'").run();
  const before = activityInventory(src(fx));
  console.log(`  stale completion: activity=${before.activity} claim=${before.claims.map(c => c.claim).join('|')} corroborated=${before.bindings[0].corroborated}`);
  check(before.activity === 'unverifiable' && before.claims.some(c => c.claim === 'child_completion_claim_without_a_live_turn_or_process'), 'a stale completion is a NAMED claim, not a positive agent and not OFF');
  const refused = createNext(fx, 'q4-next');
  check(/previous_wave_activity_unverifiable:.*child_completion_claim_without_a_live_turn_or_process/.test(refused), 'create() refuses it by name');
  const obs = observeActivity(fx.configFile);
  check(obs.unresolved_activity_claims.length === 1, 'observe names exactly one unresolved claim');
  check(obs.unresolved_activity_claims[0].session === 'stale' && obs.unresolved_activity_claims[0].child_id === 'child-stale', 'observe names the claim identity');
  // an old resolution cannot be borrowed: change the child identity FIRST, then resolve, then change it back
  const db = db_(fx); db.prepare("UPDATE child_completions SET child_id='child-other' WHERE parent_session='stale'").run(); db.close();
  check(activityInventory(src(fx)).claims.some(c => c.claim === 'child_completion_claim_without_a_live_turn_or_process'), 'a new child identity is still an unresolved claim');
  db_(fx).prepare("UPDATE child_completions SET child_id='child-stale' WHERE parent_session='stale'").run();
  const resolved = resolveActivity(fx.configFile, 'stale', 'observed: the parent turn is settled and no process names the tree', {child: 'child-stale', actor: 'review-worker'});
  console.log(`  resolve => activity_after=${resolved.activity_after} file=${path.basename(resolved.file)}`);
  check(resolved.ok === true && resolved.activity_after === 'off', 'the named resolution clears the claim and the answer becomes provably OFF');
  check(createNext(fx, 'q4-next') === 'ADMITTED', 'the next wave is admitted once the claim is resolved');
  // A LATER claim cannot borrow the resolution.
  db_(fx).prepare("UPDATE child_completions SET child_id='child-later' WHERE parent_session='stale'").run();
  check(activityInventory(src(fx)).activity === 'unverifiable', 'a LATER claim (different child) cannot borrow the old resolution');
  check(createNext(fx, 'q4-later').startsWith('previous_wave_activity_unverifiable'), 'and create() refuses it again');
  // A PROCESS THAT APPEARS MAKES THE CLAIM POSITIVE AGAIN.
  db_(fx).prepare("UPDATE child_completions SET child_id='child-stale' WHERE parent_session='stale'").run();
  const held = activityInventory({...src(fx), process_probe: true});
  console.log(`  with the real probe (no process names the tree): activity=${held.activity}`);
  const fake = {...src(fx), process_probe: false};
  const inventory = activityInventory(fake);
  // the same claim, now with a live turn: positive without any process
  db_(fx).prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES('stale','fixture','run-live','boot-x','active',1)").run();
  const positive = activityInventory(src(fx));
  check(positive.activity === 'on' && positive.agents.length === 1, 'a live turn for the same binding makes the claim positively ON again');
  check(createNext(fx, 'q4-on').startsWith('previous_wave_active'), 'and create() refuses it as an active wave');
  console.log(`\n${checks} checks passed`);
  fs.rmSync(root, {recursive: true, force: true});
} catch (e) {
  console.error(`RE-VERIFY 3+4 FAILED (${checks} checks passed): ${e.message}\nfixtures retained at ${root}`);
  process.exitCode = 1;
}
