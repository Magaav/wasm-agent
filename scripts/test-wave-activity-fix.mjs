// THE FIVE UNSAFE DIRECTIONS THE REVIEW NAMED, AND THE TWO MIGRATION DEFECTS.
//
//   1. land/admit are refused while the convergence is unverified - in BOTH corners (a blocked wave
//      with activity ON, and a migrated legacy-unverified row while idle);
//   2. a false OFF never admits the next wave (an unresolvable activity claim is unverifiable);
//   3. a false ON is NAMED and has an explicit resolution, so it can always clear;
//   4. wave-migrate's second apply is idempotent, and a leftover record is refused BEFORE the
//      transaction;
//   5. every unfinished row is read (create/checkAdmission/monitor/inspect/list), so an older
//      unfinished wave is never a silent orphan;
//   6. the index reversal is reported as transient, and that transience is measured here.
//
// Private Git, a private node store and the real public entry: every verdict is read from real
// records, and nothing touches a live store.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {register,start,checkAdmission,monitor} from './wave-entry.mjs';
import {create,advance,inspect,list} from './wave-lifecycle.mjs';
import {apply as migrationApply,revert as migrationRevert,plan as migrationPlan} from './wave-migrate.mjs';
import {activityInventory,sourceOfConfig} from './lib/wave-activity.mjs';
import {resolve as resolveActivity,observe as observeActivity} from './wave-activity.mjs';

const source=path.resolve('.');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-fix-'));
let checks=0,passed=false;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const git=(repo,...args)=>{const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
const NODE_SCHEMA=`
  CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
    workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
    workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
    started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
  CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',
    boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
  CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`;

function fixture(name) {
  const dir=path.join(root,name),repo=path.join(dir,'canonical'),executor=path.join(dir,'executor'),data=path.join(dir,'data');
  fs.mkdirSync(executor,{recursive:true});fs.mkdirSync(repo);fs.mkdirSync(data,{recursive:true});
  git(repo,'init','-q','-b','main');git(repo,'config','user.name','fixture');git(repo,'config','user.email','fixture@invalid');
  fs.writeFileSync(path.join(repo,'seed'),'fixture\n');git(repo,'add','.');git(repo,'commit','-qm','baseline');
  const db=new DatabaseSync(path.join(data,'memory.db'));db.exec(NODE_SCHEMA);db.close();
  const driver=path.join(executor,'driver.cjs'),effects=path.join(executor,'effects');
  fs.writeFileSync(driver,`const fs=require('fs');const mode=process.argv[2];
    if(mode==='step'){fs.appendFileSync(process.argv[3],process.env.WA_WAVE_OPERATION_ID+'\\n');console.log(JSON.stringify({ok:true,settled:true,cleanup:'self_exited',operation_id:process.env.WA_WAVE_OPERATION_ID}));}
    if(mode==='post')console.log(JSON.stringify({ok:true}));
    if(mode==='zero')console.log(JSON.stringify({ok:true,released:0}));`);
  const manifest={id:name,owner:'fixture-owner',repo,executor_cwd:executor,bootstrap:true,activity:{data},
    steps:[{name:'land',argv:[process.execPath,driver,'zero',effects],post:{argv:[process.execPath,driver,'post']}},
           {name:'deploy',argv:[process.execPath,driver,'step',effects],post:{argv:[process.execPath,driver,'post']}},
           {name:'retire',argv:[process.execPath,driver,'step',effects],post:{argv:[process.execPath,driver,'post']}}],
    verifiers:Object.fromEntries(['operations','claims','runtime','registries','deliveries','owners'].map(kind=>[kind,{argv:[process.execPath,driver,'post']}]))};
  const config={repo,data,source_root:source,monitor_mode:'external-cli-test'};
  const configFile=path.join(executor,'config.json');fs.writeFileSync(configFile,JSON.stringify(config));
  const manifestFile=path.join(executor,'manifest.json');fs.writeFileSync(manifestFile,JSON.stringify(manifest));
  const main=git(repo,'rev-parse','HEAD');
  const ticket=path.join(executor,'bootstrap.json');
  fs.writeFileSync(ticket,JSON.stringify({schema:1,kind:'wave-bootstrap-admission',repo,main,refs_sha256:hash(git(repo,'for-each-ref','--format=%(objectname) %(refname)','refs/heads/')),issuer:'fixture-coordinator',reviewer:'fixture-independent'}));
  register(repo,configFile,ticket);
  const store=path.join(repo,'.git','wa-waves');
  return {dir,repo,executor,data,store,config,configFile,manifestFile,manifest,driver,effects,main,
    startWave(id){const file=path.join(executor,`manifest-${id}.json`);fs.writeFileSync(file,JSON.stringify({...manifest,id,bootstrap:id===name}));return start(repo,file);}};
}
function sourceOf(fx) { return {kind:'node-runtime',repo:fx.repo,data:fx.data,memory_db:path.join(fx.data,'memory.db'),process_probe:false}; }
function nodeDB(fx) { return new DatabaseSync(path.join(fx.data,'memory.db')); }
function liveChild(fx,id,{turn=true}={}) {
  const tree=path.join(fx.data,`wa-worktree-${id}`);
  git(fx.repo,'worktree','add','--detach',tree);
  const db=nodeDB(fx);
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,parent_session_id,started_at,ended_at,updated_at) VALUES(?,?,1,'allocated',?,?,?,0,NULL,0)")
    .run(id,tree.replaceAll('\\','/'),fx.repo.replaceAll('\\','/'),JSON.stringify({executor:{owner_boot:`boot-${id}`}}),'parent');
  if(turn)db.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,'fixture',?,'boot-fixture','active',1)").run(id,`run-${id}`);
  db.close();
  return tree;
}
function endChild(fx,id) {
  const db=nodeDB(fx);
  db.prepare('UPDATE sessions SET ended_at=1 WHERE id=?').run(id);
  db.prepare("UPDATE steering_runs SET state='settled' WHERE session_id=?").run(id);
  db.close();
}
function indexPresent(fx) {
  const db=new DatabaseSync(path.join(fx.store,'waves.sqlite'),{readOnly:true});
  try { return db.prepare("SELECT count(*) c FROM sqlite_master WHERE type='index' AND name='active_repo'").get().c>0; } finally { db.close(); }
}

try {
  // ---------------------------------------------------------------- 1. land/admit while unverified
  const fx=fixture('lifecycle');
  fx.startWave('lifecycle');
  check((await advance(fx.store,'lifecycle')).state==='blocked','the fixture wave blocks on an unknown effect outcome');
  const offLand=checkAdmission(fx.repo,{phase:'land'});
  check(offLand.ok===false&&/wave_convergence_unverified/.test(offLand.reason),'landing is refused while the convergence is unverified and the wave is idle');
  check(checkAdmission(fx.repo,{phase:'produce'}).ok===true&&checkAdmission(fx.repo,{phase:'allocate'}).ok===true,'producing and allocating stay admitted for the idle lane');

  // (a) A BLOCKED WAVE WITH ACTIVITY ON MUST NOT ADMIT THEM EITHER.
  const tree=liveChild(fx,'child-live');
  check(fs.existsSync(tree),'the live child tree is real');
  const onObserve=checkAdmission(fx.repo,{phase:'observe'});
  check(onObserve.activity==='on'&&onObserve.runtime_state==='active','the same wave reports ON while the child works');
  const onLand=checkAdmission(fx.repo,{phase:'land'});
  check(onLand.ok===false&&/wave_convergence_unverified/.test(onLand.reason),'a live umbrella does not make an unverified convergence verified: landing is still refused');
  const onAdmit=checkAdmission(fx.repo,{phase:'admit'});
  check(onAdmit.ok===false&&/wave_convergence_unverified/.test(onAdmit.reason),'independent delivery admission is refused too, with activity ON');
  check(checkAdmission(fx.repo,{phase:'produce'}).ok===true&&checkAdmission(fx.repo,{phase:'allocate'}).ok===true,'producing and allocating stay admitted while the child works');
  assert.throws(()=>create(fx.store,{...fx.manifest,id:'blocked-next',bootstrap:false}),/previous_wave_active/);checks++;
  endChild(fx,'child-live');

  // (c) CONTROL: A SINGLE FRESH PENDING WAVE ADMITS ALL FOUR - the live-lane behaviour the reviewer
  // confirmed, on a store whose only unfinished row has an OPEN convergence.
  const fresh=fixture('fresh');
  fresh.startWave('fresh');
  const freshLive=liveChild(fresh,'child-fresh');
  check(checkAdmission(fresh.repo,{phase:'observe'}).activity==='on','the fresh wave reports ON while its lane works');
  check(checkAdmission(fresh.repo,{phase:'land'}).ok===true,'a fresh wave whose convergence is merely open admits landing for the producing lane');
  check(checkAdmission(fresh.repo,{phase:'admit'}).ok===true,'and independent delivery admission');
  check(checkAdmission(fresh.repo,{phase:'produce'}).ok===true&&checkAdmission(fresh.repo,{phase:'allocate'}).ok===true,'and producing and allocating');
  endChild(fresh,'child-fresh');
  check(fs.existsSync(freshLive),'the control lane tree is real');

  // (b) A MIGRATED legacy-unverified ROW, IDLE, as the only unfinished row: refused by name.
  const legacy=fixture('legacy');
  legacy.startWave('legacy');
  const applied=migrationApply(legacy.store,'legacy','lane-d');
  check(applied.ok===true&&applied.original_unchanged===true,'the migration applies without moving an original column');
  const legacyLand=checkAdmission(legacy.repo,{phase:'land'});
  check(legacyLand.ok===false&&/wave_convergence_unverified:legacy/.test(legacyLand.reason),'a migrated legacy-unverified row refuses landing while idle, naming that row');
  check(checkAdmission(legacy.repo,{phase:'admit'}).ok===false,'and independent delivery admission');
  check(checkAdmission(legacy.repo,{phase:'produce'}).ok===true&&checkAdmission(legacy.repo,{phase:'allocate'}).ok===true,'while producing and allocating keep being admitted');
  check(checkAdmission(legacy.repo,{phase:'observe'}).runtime_state==='unverified','and the row still reports its named unverified convergence');

  // An idle blocked wave still does not block starting the next one.
  check(fx.startWave('second').ok===true,'an idle blocked wave does not block the next one');

  // ------------------------------------------------------------------ 2. a false OFF admits nothing
  const off=fixture('falseoff');
  off.startWave('falseoff');
  // A live turn whose worktree is NOT registered: it must not read as OFF.
  const db=nodeDB(off);
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES('child-gone',?,1,'allocated',?,?,0,NULL,0)")
    .run(path.join(off.data,'wa-worktree-child-gone').replaceAll('\\','/'),off.repo.replaceAll('\\','/'),JSON.stringify({executor:{owner_boot:'boot-gone'}}));
  db.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES('child-gone','fixture','run-gone','boot-gone','active',1)").run();
  db.close();
  const gone=activityInventory(sourceOf(off));
  check(gone.activity==='unverifiable'&&gone.off===false,'a live turn without a registered tree is not an OFF answer');
  check(gone.claims.some(claim=>claim.claim==='activity_claim_without_a_registered_worktree'),'and the claim is named');
  assert.throws(()=>create(off.store,{...off.manifest,id:'off-next',bootstrap:false}),/previous_wave_activity_unverifiable:falseoff:unresolved_activity_claims:activity_claim_without_a_registered_worktree:child-gone/);checks++;
  const offAdmission=checkAdmission(off.repo,{phase:'produce'});
  check(offAdmission.ok===true&&offAdmission.activity==='unverifiable','lanes keep producing, and the unobservable answer is named, not called idle');
  check(offAdmission.unfinished[0].reason.includes('activity_claim_without_a_registered_worktree'),'the admission answer carries the named unresolved reason');
  // With the tree registered at the path the turn names, the SAME claim becomes positively ON.
  const registered=path.join(off.data,'wa-worktree-child-gone');
  git(off.repo,'worktree','add','--detach',registered);
  check(activityInventory(sourceOf(off)).activity==='on','with the tree registered and the turn running, the answer is positively ON');
  assert.throws(()=>create(off.store,{...off.manifest,id:'on-next',bootstrap:false}),/previous_wave_active/);checks++;
  check(fs.existsSync(registered),'the tree that turned the claim positive is real');

  // ------------------------------------------------------------ 3. a false ON is named and clears
  const stale=fixture('falseon');
  stale.startWave('falseon');
  // A stale child completion: parent open and allocated, a real tree, NO turn and no process.
  const staleTree=liveChild(stale,'child-stale',{turn:false});
  const db3=nodeDB(stale);
  db3.prepare("INSERT INTO child_completions(child_id,target_id,parent_session,state,run_id) VALUES('child-stale','target','child-stale','dispatching','run-stale')").run();
  db3.close();
  const claimed=activityInventory(sourceOf(stale));
  check(claimed.activity==='unverifiable'&&claimed.claims.some(claim=>claim.claim==='child_completion_claim_without_a_live_turn_or_process'),'a stale child completion is a NAMED unresolved claim, not a positive agent');
  assert.throws(()=>create(stale.store,{...stale.manifest,id:'stale-next',bootstrap:false}),/previous_wave_activity_unverifiable:falseon:.*child_completion_claim_without_a_live_turn_or_process:child-stale/);checks++;
  const observation=observeActivity(stale.configFile);
  check(observation.unresolved_activity_claims.length===1&&observation.unresolved_activity_claims[0].session==='child-stale','the observation names the claim and its exact identity');
  assert.throws(()=>resolveActivity(stale.configFile,'child-stale','',{child:'child-stale'}),/observed_resolution_evidence_required/);checks++;
  assert.throws(()=>resolveActivity(stale.configFile,'child-stale','observed',{}),/claim_identity_required/);checks++;
  assert.throws(()=>resolveActivity(stale.configFile,'child-stale','observed',{child:'a-different-child'}),/claim_identity_required/);checks++;
  const resolved=resolveActivity(stale.configFile,'child-stale','The parent turn is settled and no process names the tree; the completion was observed as abandoned',{child:'child-stale',actor:'lane-d'});
  check(resolved.ok===true&&resolved.activity_after==='off','the named resolution clears the claim and the activity is provably OFF again');
  check(fs.existsSync(path.join(stale.repo,'.git','wa-waves','activity-resolutions.json')),'the resolution is durable in the wave store');
  check(create(stale.store,{...stale.manifest,id:'stale-next',bootstrap:false}).ok===true,'with the claim resolved, the next wave is admitted');
  // A NEW claim (a different child) cannot borrow the old resolution.
  const db4=nodeDB(stale);
  db4.prepare("UPDATE child_completions SET child_id='child-new' WHERE parent_session='child-stale'").run();
  db4.close();
  check(activityInventory(sourceOf(stale)).activity==='unverifiable','a new child identity is a new claim, not a resolved one');
  check(fs.existsSync(staleTree),'the stale claim\'s tree was never touched');

  // ------------------------------------------- 4 and 6. the migration: idempotent, refused early, transient
  const migrate=fixture('migrate');
  migrate.startWave('migrate');
  const first=migrationApply(migrate.store,'migrate','lane-d');
  check(first.ok===true&&path.basename(first.record)==='migration-migrate.json','the record is one per wave');
  const repeat=migrationApply(migrate.store,'migrate','lane-d');
  check(repeat.ok===true&&repeat.already_migrated===true&&repeat.record===first.record,'a second apply is idempotent, not an error after it committed');
  // THE INDEX REVERSAL, MEASURED.
  const plan=migrationPlan(migrate.store,'migrate');
  check(plan.one_row_per_repository_index_transient.includes('drops active_repo again'),'the plan states that the index reversal is transient');
  const reverted=migrationRevert(migrate.store,'migrate');
  check(reverted.ok===true&&reverted.one_row_per_repository_index.transient===true,'revert reports the restored index as transient');
  check(reverted.one_row_per_repository_index.restored===true,'with a single unfinished row the index really is restored');
  check(indexPresent(migrate),'the index is present again after revert');
  migrate.startWave('after-revert');
  check(indexPresent(migrate)===false,'and the next read-write wave operation drops it again: the reversal is transient, exactly as reported');
  // A LEFTOVER RECORD IS REFUSED BEFORE THE TRANSACTION.
  const leftover=path.join(migrate.store,'migration-after-revert.json');
  fs.writeFileSync(leftover,JSON.stringify({schema:1,kind:'wave-legacy-migration',store:migrate.store,wave_id:'after-revert'}));
  const rowBefore=new DatabaseSync(path.join(migrate.store,'waves.sqlite'),{readOnly:true});
  const snapshot=JSON.parse(JSON.stringify(rowBefore.prepare('SELECT * FROM waves WHERE id=?').get('after-revert')));rowBefore.close();
  check(Boolean(snapshot)===true,'the unmigrated wave row exists before the refused apply');
  assert.throws(()=>migrationApply(migrate.store,'after-revert','lane-d'),/migration_record_without_migration/);checks++;
  const rowAfter=new DatabaseSync(path.join(migrate.store,'waves.sqlite'),{readOnly:true});
  const afterSnapshot=JSON.parse(JSON.stringify(rowAfter.prepare('SELECT * FROM waves WHERE id=?').get('after-revert')));rowAfter.close();
  check(JSON.stringify(snapshot)===JSON.stringify(afterSnapshot),'the refusal happened before the transaction: the row is byte-identical');
  fs.rmSync(leftover);

  // ------------------------------------------ 5. every unfinished row is read, none is an orphan
  const multi=fixture('multi');
  multi.startWave('multi');
  check((await advance(multi.store,'multi')).state==='blocked','the older wave is blocked and unfinished');
  const younger=multi.startWave('younger');
  check(younger.ok===true,'the younger wave is admitted beside it');
  const listed=list(multi.store);
  check(listed.waves.length===2&&listed.unfinished.length===2&&listed.unfinished.includes('multi')&&listed.unfinished.includes('younger'),'the store lists BOTH unfinished rows');
  const inspected=inspect(multi.store,'younger');
  check(inspected.unfinished.length===1&&inspected.unfinished[0].id==='multi','inspecting one row reports the other unfinished row');
  const monitored=monitor(multi.repo);
  check(monitored.wave_id==='multi','the monitor drives the OLDEST unfinished row, not the newest');
  check(monitored.state==='blocked'&&monitored.unfinished.includes('multi')&&monitored.unfinished.includes('younger'),'and it reports the whole unfinished set');
  const multiChild=liveChild(multi,'child-multi');
  assert.throws(()=>create(multi.store,{...multi.manifest,id:'multi-next',bootstrap:false}),/previous_wave_active:(multi|younger)/);checks++;
  check(checkAdmission(multi.repo,{phase:'land'}).ok===false,'landing is refused because an OLDER unfinished row is unverified');
  const reported=checkAdmission(multi.repo,{phase:'observe'});
  check(reported.unfinished.length===2&&reported.unfinished.some(entry=>entry.id==='multi'&&entry.activity==='on'),'the admission answer names the older active row');
  check(checkAdmission(multi.repo,{phase:'produce'}).ok===true,'producing stays admitted');
  check(fs.existsSync(multiChild),'the older wave\'s live child tree was left alone');
  // create() REPORTS every unfinished row it read, not only the newest.
  endChild(multi,'child-multi');
  const admitted=create(multi.store,{...multi.manifest,id:'multi-next',bootstrap:false});
  check(admitted.ok===true,'with the lane off, the next wave is admitted beside two unfinished rows');
  check(admitted.unfinished.length===2&&admitted.unfinished.some(entry=>entry.id==='multi')&&admitted.unfinished.some(entry=>entry.id==='younger'),'and it reports EVERY unfinished row, not only the newest');
  passed=true;
  console.log(`wave activity fix ok (${checks} checks; land/admit refused in both unverified corners, a false OFF never admits, a false ON is named and clears, the migration is idempotent and refuses early, every unfinished row is read, and the index reversal is transient)`);
} finally {
  if(passed) fs.rmSync(root,{recursive:true,force:true}); else console.error(`wave activity-fix fixtures retained: ${root}`);
}
