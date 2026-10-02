// THE TWO RESIDUE CORNERS, MEASURED FIRST ON A COPY OF THE LIVE STORE AND THEN FIXED.
//
//   1. a stale `steering_runs` row reads positively ON, `observe` reports no claim, and `resolve`
//      refused it (`claim_is_not_unresolved:...:activity_is_positively_on`) - a fence with no way
//      out. The claim is now visible in `observe` and resolvable by the same named path, under the
//      same exact-identity binding, and a local process holding the tree can never be cleared.
//   2. a completed NEWEST wave beside an OLDER unfinished row refused ALL FOUR phases
//      (`next_wave_requires_fresh_public_start`, `produce`/`allocate` included). Producing and
//      allocating are no longer fenced by it; landing and independent admission still require a
//      fresh public start, and that refusal now names the older unfinished rows too.
//
// Private Git, a private node store and the real public entry; nothing here touches a live store.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {register, start, checkAdmission} from './wave-entry.mjs';
import {create, advance, list} from './wave-lifecycle.mjs';
import {activityInventory, POSITIVE_CLAIM} from './lib/wave-activity.mjs';
import {observe, resolve} from './wave-activity.mjs';

const source = path.resolve('.');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-wave-corners-'));
let checks = 0, passed = false;
const check = (value, label) => { assert.ok(value, label); checks++; };
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
  git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'fixture'); git(repo, 'config', 'user.email', 'fixture@invalid');
  fs.writeFileSync(path.join(repo, 'seed'), 'fixture\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'baseline');
  const db = new DatabaseSync(path.join(data, 'memory.db')); db.exec(NODE_SCHEMA); db.close();
  const driver = path.join(executor, 'driver.cjs'), effects = path.join(executor, 'effects');
  fs.writeFileSync(driver, `const fs=require('fs');const mode=process.argv[2];
    if(mode==='step'){fs.appendFileSync(process.argv[3],process.env.WA_WAVE_OPERATION_ID+'\\n');console.log(JSON.stringify({ok:true,settled:true,cleanup:'self_exited',operation_id:process.env.WA_WAVE_OPERATION_ID}));}
    if(mode==='post')console.log(JSON.stringify({ok:true}));
    if(mode==='zero')console.log(JSON.stringify({ok:true,released:0}));`);
  const manifest = {id: name, owner: 'fixture-owner', repo, executor_cwd: executor, bootstrap: true, activity: {data},
    steps: [{name: 'land', argv: [process.execPath, driver, 'zero', effects], post: {argv: [process.execPath, driver, 'post']}},
            {name: 'deploy', argv: [process.execPath, driver, 'step', effects], post: {argv: [process.execPath, driver, 'post']}},
            {name: 'retire', argv: [process.execPath, driver, 'step', effects], post: {argv: [process.execPath, driver, 'post']}}],
    verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(kind => [kind, {argv: [process.execPath, driver, 'post']}]))};
  const config = {repo, data, source_root: source, monitor_mode: 'external-cli-test'};
  const configFile = path.join(executor, 'config.json'); fs.writeFileSync(configFile, JSON.stringify(config));
  const manifestFile = path.join(executor, 'manifest.json'); fs.writeFileSync(manifestFile, JSON.stringify(manifest));
  const ticket = path.join(executor, 'bootstrap.json');
  fs.writeFileSync(ticket, JSON.stringify({schema: 1, kind: 'wave-bootstrap-admission', repo, main: git(repo, 'rev-parse', 'HEAD'), refs_sha256: hash(git(repo, 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads/')), issuer: 'fixture-coordinator', reviewer: 'fixture-independent'}));
  register(repo, configFile, ticket);
  return {dir, repo, executor, data, store: path.join(repo, '.git', 'wa-waves'), config, configFile, manifest, driver, effects,
    startWave(id) { const file = path.join(executor, `manifest-${id}.json`); fs.writeFileSync(file, JSON.stringify({...manifest, id, bootstrap: id === name})); return start(repo, file); }};
}
const nodeDB = fx => new DatabaseSync(path.join(fx.data, 'memory.db'));
const inventoryOf = fx => activityInventory({kind: 'node-runtime', repo: fx.repo, data: fx.data, memory_db: path.join(fx.data, 'memory.db')});

// A STALE TURN: an open session with an allocated binding and a real registered managed worktree,
// and a `steering_runs` row the node left behind in state `active`. Nothing is running in it.
function staleTurn(fx, id, {run = `run-${id}`, boot = `boot-${id}`} = {}) {
  const tree = path.join(fx.data, `wa-worktree-${id}`);
  if (!fs.existsSync(tree)) git(fx.repo, 'worktree', 'add', '--detach', tree);
  const db = nodeDB(fx);
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES(?,?,1,'allocated',?,?,0,NULL,0) ON CONFLICT(id) DO UPDATE SET worktree=excluded.worktree,workspace_state='allocated',ended_at=NULL")
    .run(id, tree.replaceAll('\\', '/'), fx.repo.replaceAll('\\', '/'), JSON.stringify({executor: {owner_boot: boot}}));
  db.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,'fixture',?,?,'active',1) ON CONFLICT(session_id) DO UPDATE SET run_id=excluded.run_id,boot=excluded.boot,state='active'")
    .run(id, run, boot);
  db.close();
  return tree;
}

try {
  // ------------------------------------------------------------------ corner 1
  const stale = fixture('stale');
  stale.startWave('stale');
  const tree = staleTurn(stale, 'child-stale-turn');
  const before = inventoryOf(stale);
  check(before.activity === 'on' && before.agents.length === 1, 'a stale turn with a registered tree reads positively ON (the measured fact)');
  check(before.agents[0].corroborated === false, 'and nothing is running in it: no local process names the tree');

  const seen = observe(stale.configFile);
  const listed = seen.activity_claims.find(claim => claim.session === 'child-stale-turn');
  check(Boolean(listed), 'observe LISTS the positively-ON claim instead of reporting none');
  check(listed.positive === true && listed.resolvable === true, 'and says it is positive and resolvable');
  check(listed.why === POSITIVE_CLAIM && listed.run_id === 'run-child-stale-turn' && listed.boot === 'boot-child-stale-turn', 'with the identity a resolution must name');
  check(/wave-activity\.mjs resolve .* child-stale-turn/.test(listed.resolution), 'and the exact command that resolves it');

  assert.throws(() => resolve(stale.configFile, 'child-stale-turn', 'observed', {actor: 'lane-d'}), /claim_identity_required:child-stale-turn/); checks++;
  const resolved = resolve(stale.configFile, 'child-stale-turn', 'The node process that started this turn is gone and nothing runs in the tree', {run: 'run-child-stale-turn', actor: 'lane-d'});
  check(resolved.ok === true && resolved.claim === POSITIVE_CLAIM && resolved.was_positive === true, 'a positive claim resolves by the same named path');
  check(resolved.activity_after === 'off', 'and the activity answer is provably OFF afterwards');
  const after = inventoryOf(stale);
  check(after.activity === 'off' && after.agents.length === 0 && after.resolved_claims.length === 1, 'the inventory agrees: no agents, one resolved claim');
  check(create(stale.store, {...stale.manifest, id: 'stale-next', bootstrap: false}).ok === true, 'so the fence create() raised has a way out: the next wave is admitted');
  assert.throws(() => resolve(stale.configFile, 'child-stale-turn', 'again', {run: 'run-child-stale-turn', actor: 'lane-d'}), /claim_already_resolved/); checks++;

  // NOT BORROWABLE: a NEW turn (a new run id) is a new claim.
  staleTurn(stale, 'child-stale-turn', {run: 'run-second', boot: 'boot-second'});
  const again = inventoryOf(stale);
  check(again.activity === 'on' && again.agents.length === 1, 'a NEW turn on the same session is a new claim: the old resolution does not apply');
  const second = resolve(stale.configFile, 'child-stale-turn', 'the second turn is dead too', {run: 'run-second', actor: 'lane-d'});
  check(second.ok === true && second.activity_after === 'off', 'and it resolves on its own identity');

  // A PROCESS HOLDING THE TREE CAN NEVER BE CLEARED.
  const holder = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)', tree], {stdio: 'ignore', windowsHide: true});
  await new Promise(done => setTimeout(done, 1500));
  const held = inventoryOf(stale);
  check(held.activity === 'on' && held.agents.length === 1, 'a process holding the tree is stronger evidence than the recorded resolution');
  check(held.agents[0].corroborated === true, 'and the probe corroborates it');
  assert.throws(() => resolve(stale.configFile, 'child-stale-turn', 'try to clear live work', {run: 'run-second', actor: 'lane-d'}), /claim_is_corroborated_by_a_local_process/); checks++;
  const exited = new Promise(done => holder.once('exit', done));
  holder.kill(); await exited;
  await new Promise(done => setTimeout(done, 500));
  check(inventoryOf(stale).activity === 'off', 'when the process goes, the recorded resolution applies again');

  // ------------------------------------------------------------------ corner 2
  const corner = fixture('corner');
  corner.startWave('corner');
  check((await advance(corner.store, 'corner')).state === 'blocked', 'the OLDER row is unfinished (a blocked convergence)');
  const younger = corner.startWave('younger');
  check(younger.ok === true, 'a younger wave is admitted beside it');
  // The fixture store is mine: this is the state the review measured (a completed newest row).
  const store = new DatabaseSync(path.join(corner.store, 'waves.sqlite'));
  store.prepare("UPDATE waves SET state='complete', reason=NULL WHERE id='younger'").run();
  store.close();
  check(list(corner.store).unfinished.length === 1, 'the store still holds one unfinished row (the older one)');

  const produce = checkAdmission(corner.repo, {phase: 'produce'});
  const allocate = checkAdmission(corner.repo, {phase: 'allocate'});
  check(produce.ok === true && allocate.ok === true, 'a completed newest wave no longer fences producing and allocating');
  check(produce.runtime_state === 'complete' && produce.unfinished.length === 1 && produce.unfinished[0].id === 'corner', 'and the answer still names the completed wave and the older unfinished row');
  const land = checkAdmission(corner.repo, {phase: 'land'});
  check(land.ok === false && /^next_wave_requires_fresh_public_start:younger:unfinished:corner$/.test(land.reason), 'landing still requires a fresh public start, and the refusal NAMES the older unfinished row');
  const admit = checkAdmission(corner.repo, {phase: 'admit'});
  check(admit.ok === false && /unfinished:corner/.test(admit.reason), 'and so does independent delivery admission');
  check(checkAdmission(corner.repo, {phase: 'observe'}).ok === true, 'read-only observation is never fenced by it');

  // The pure case (no unfinished row) keeps its old, narrower refusal.
  const pure = fixture('pure');
  pure.startWave('pure');
  const pureStore = new DatabaseSync(path.join(pure.store, 'waves.sqlite'));
  pureStore.prepare("UPDATE waves SET state='complete' WHERE id='pure'").run();
  pureStore.close();
  check(checkAdmission(pure.repo, {phase: 'produce'}).ok === true && checkAdmission(pure.repo, {phase: 'allocate'}).ok === true, 'with no unfinished row at all, producing and allocating are admitted too');
  const pureLand = checkAdmission(pure.repo, {phase: 'land'});
  check(pureLand.ok === false && /^next_wave_requires_fresh_public_start:pure$/.test(pureLand.reason), 'and landing is refused with just the completed wave named');

  // The closing freeze is NOT weakened by that: it still fences producing and allocating.
  fs.writeFileSync(path.join(pure.store, 'freeze.json'), JSON.stringify({wave_id: 'pure'}));
  const frozen = checkAdmission(pure.repo, {phase: 'produce'});
  check(frozen.ok === false && /wave_closing_frozen/.test(frozen.reason), 'a closing freeze still fences producing, named');
  check(checkAdmission(pure.repo, {phase: 'land'}).ok === false, 'and landing stays refused while frozen');

  passed = true;
  console.log(`wave activity corners ok (${checks} checks; the stale steering claim is visible and resolvable and a live process cannot be cleared, a completed newest wave no longer fences producing or allocating, and its refusal names the older unfinished row)`);
} finally {
  if (passed) fs.rmSync(root, {recursive: true, force: true}); else console.error(`wave corner fixtures retained: ${root}`);
}
