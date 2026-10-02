// RE-VERIFY 5+6+7: migration idempotency and early refusal; two unfinished waves; the transient index.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {register, checkAdmission, monitor} from '../scripts/wave-entry.mjs';
import {create, inspect, list} from '../scripts/wave-lifecycle.mjs';
import {apply as mApply, revert as mRevert, plan as mPlan} from '../scripts/wave-migrate.mjs';

const source = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-rev56-'));
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
const raw = (fx, id) => { const db = new DatabaseSync(path.join(fx.store, 'waves.sqlite'), {readOnly: true}); const r = db.prepare('SELECT * FROM waves WHERE id=?').get(id); const e = db.prepare('SELECT count(*) c FROM events').get().c; db.close(); return {row: r, events: e}; };
const setState = (fx, id, state) => { const db = new DatabaseSync(path.join(fx.store, 'waves.sqlite')); db.prepare('UPDATE waves SET state=? WHERE id=?').run(state, id); db.close(); };

try {
  console.log('--- Q5: migration idempotency, one record per wave, refusal BEFORE the transaction ---');
  const fx = fixture('q5');
  const first = mApply(fx.store, 'q5', 'review-worker');
  console.log(`  first apply: record=${path.basename(first.record)} dropped_index=${first.one_row_per_repository_index_dropped}`);
  check(path.basename(first.record) === 'migration-q5.json', 'the record is one per wave (migration-<id>.json)');
  const again = mApply(fx.store, 'q5', 'review-worker');
  check(again.ok === true && again.already_migrated === true && again.record === first.record, 'a second apply of the same wave is idempotent and names the same record');
  const other = create(fx.store, {...fx.manifest, id: 'q5-second', bootstrap: false});
  const second = mApply(fx.store, 'q5-second', 'review-worker');
  console.log(`  second wave record: ${path.basename(second.record)}`);
  check(path.basename(second.record) === 'migration-q5-second.json' && fs.existsSync(first.record), 'two waves in one store each keep their own record');
  // the LEGACY single-file name is still read for its own wave
  fs.rmSync(second.record);
  const legacyName = path.join(fx.store, 'migration.json');
  fs.copyFileSync(first.record, legacyName);
  fs.rmSync(first.record);   // only the LEGACY name remains, and it names this wave
  const viaLegacy = mApply(fx.store, 'q5', 'review-worker');
  console.log(`  with the legacy single-file record present, apply(q5) => already_migrated=${viaLegacy.already_migrated} record=${path.basename(viaLegacy.record)}`);
  check(viaLegacy.already_migrated === true && path.basename(viaLegacy.record) === 'migration.json', 'the old single-file record is still read for its own wave');
  check(viaLegacy.already_migrated === true, 'a migrated row plus a record is idempotent, never an error');
  // A RECORD WITHOUT ITS MIGRATION IS REFUSED BEFORE THE TRANSACTION: a wave that was never migrated.
  create(fx.store, {...fx.manifest, id: 'q5-third', bootstrap: false});
  const leftover = path.join(fx.store, 'migration-q5-third.json');
  fs.writeFileSync(leftover, JSON.stringify({schema: 1, kind: 'wave-legacy-migration', store: fx.store, wave_id: 'q5-third'}));
  const before = raw(fx, 'q5-third');
  let refused = 'ACCEPTED';
  try { mApply(fx.store, 'q5-third', 'review-worker'); } catch (e) { refused = e.message; }
  const after = raw(fx, 'q5-third');
  console.log();
  check(/migration_record_without_migration/.test(refused), 'a record without its migration is refused by name');
  check(JSON.stringify(before.row) === JSON.stringify(after.row) && before.events === after.events, 'NOTHING was written: the row and the event journal are byte-identical');
  fs.rmSync(leftover); fs.rmSync(legacyName);
  const plan = mPlan(fx.store, 'q5');
  check(plan.one_row_per_repository_index_transient.includes('drops active_repo again'), 'the plan states the index reversal is transient');

  console.log('--- Q7: the index reversal, measured ---');
  const mig = fixture('q7');
  mApply(mig.store, 'q7', 'review-worker');
  const rev = mRevert(mig.store, 'q7');
  const idx = () => { const db = new DatabaseSync(path.join(mig.store, 'waves.sqlite'), {readOnly: true}); const r = db.prepare("SELECT count(*) c FROM sqlite_master WHERE name='active_repo'").get().c; db.close(); return r > 0; };
  console.log(`  revert: restored=${rev.one_row_per_repository_index.restored} transient=${rev.one_row_per_repository_index.transient} present_now=${idx()}`);
  check(rev.one_row_per_repository_index.restored === true && rev.one_row_per_repository_index.transient === true && idx() === true, 'revert reports the restoration AND its transience, and the index really is present');
  create(mig.store, {...mig.manifest, id: 'q7-after', bootstrap: false});
  check(idx() === false, 'the next read-write wave operation drops it again: the reported transience is the measurement');

  console.log('--- Q6: two unfinished waves, and an attempt to make one a silent orphan ---');
  const m = fixture('q6');
  setState(m, 'q6', 'blocked');
  const younger = create(m.store, {...m.manifest, id: 'q6-younger', bootstrap: false});
  check(younger.ok === true, 'a second unfinished wave is admitted beside the first');
  check(younger.unfinished.length === 1 && younger.unfinished[0].id === 'q6', 'create() reports the older unfinished row it read');
  const listed = list(m.store);
  check(listed.waves.length === 2 && listed.unfinished.length === 2, 'list() shows BOTH unfinished rows');
  const insp = inspect(m.store, 'q6-younger');
  check(insp.unfinished.length === 1 && insp.unfinished[0].id === 'q6', 'inspect() reports the other unfinished row');
  const observed = checkAdmission(m.repo, {phase: 'observe'});
  check(observed.unfinished.length === 2, 'checkAdmission reports every unfinished row');
  const land = checkAdmission(m.repo, {phase: 'land'});
  console.log(`  land with an OLDER unverified row => ${land.reason?.slice(0, 80)}`);
  check(land.ok === false && /wave_convergence_unverified:q6:/.test(land.reason), 'landing is refused because of the OLDER unfinished row, by name');
  const monitored = monitor(m.repo);
  console.log(`  monitor => wave_id=${monitored.wave_id} unfinished=${JSON.stringify(monitored.unfinished)}`);
  check(monitored.wave_id === 'q6', 'the monitor drives the OLDEST unfinished row');
  check(monitored.unfinished.includes('q6') && monitored.unfinished.includes('q6-younger'), 'and it reports the whole unfinished set');
  // THE ORPHAN ATTEMPT: newest complete, older unfinished.
  setState(m, 'q6-younger', 'complete');
  const listedAfter = list(m.store);
  console.log(`  newest complete, older blocked: unfinished=${JSON.stringify(listedAfter.unfinished)}`);
  check(listedAfter.unfinished.includes('q6'), 'list() still shows the older unfinished row when the newest is complete');
  const inspAfter = inspect(m.store, 'q6-younger');
  check(inspAfter.unfinished.length === 1 && inspAfter.unfinished[0].id === 'q6', 'inspect() still reports it');
  const monAfter = monitor(m.repo);
  console.log(`  monitor with the newest complete => wave_id=${monAfter.wave_id} unfinished=${JSON.stringify(monAfter.unfinished)}`);
  check(monAfter.wave_id === 'q6', 'the monitor still drives the older unfinished row');
  for (const phase of ['produce', 'allocate', 'land', 'admit']) {
    const r = checkAdmission(m.repo, {phase});
    console.log(`  checkAdmission(${phase}) => ok=${r.ok} reason=${(r.reason || '').slice(0, 70)}`);
  }
  const prod = checkAdmission(m.repo, {phase: 'produce'});
  check(prod.ok === true, 'PRODUCING IS STILL ADMITTED while an older unfinished row exists beside a complete newest row');
  console.log(`\n${checks} checks passed`);
} catch (e) {
  console.error(`RE-VERIFY 5+6+7 FAILED (${checks} checks passed): ${e.message}\nfixtures retained at ${root}`);
  process.exitCode = 1;
}
