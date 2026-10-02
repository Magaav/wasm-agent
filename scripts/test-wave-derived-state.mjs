// THE DERIVED WAVE STATE, FALSIFYING THE OLD BEHAVIOUR.
//
//   (a) a wave with zero live children cannot block starting the next wave;
//   (b) a wave with a live child reports ON;
//   (d) a genuinely unverifiable convergence is reported as a NAMED state, never as complete;
//   plus: a wave never reports an active state with nothing running, and the legacy durable row is
//   handled by a documented, non-destructive, reversible migration.
//
// Everything here is a private Git repository and a private node runtime store (real `memory.db`
// with the real sessions/steering_runs shape), so every verdict is read from real records.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {create,advance,inspect} from './wave-lifecycle.mjs';
import {waveActivity,activityInventory} from './lib/wave-activity.mjs';
import {plan as migrationPlan,apply as migrationApply,revert as migrationRevert} from './wave-migrate.mjs';

const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-derived-'));
let checks=0,passed=false;
const check=(value,label)=>{assert.ok(value,label);checks++;};
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
  const dir=path.join(root,name),repo=path.join(dir,'canonical'),executor=path.join(dir,'executor'),store=path.join(dir,'state'),data=path.join(dir,'data');
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
  return {dir,repo,executor,store,data,driver,manifest};
}

// A LIVE CHILD for this repository: an open session whose binding names the repository, with a real
// registered managed worktree, and the node's own record of a running turn.
function liveChild(fx,id) {
  const tree=path.join(fx.data,`wa-worktree-${id}`);
  git(fx.repo,'worktree','add','--detach',tree);
  const db=new DatabaseSync(path.join(fx.data,'memory.db'));
  db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_source_path,workspace_start_state,parent_session_id,started_at,ended_at,updated_at) VALUES(?,?,1,'allocated',?,?,?,0,NULL,0)")
    .run(id,tree.replaceAll('\\','/'),fx.repo.replaceAll('\\','/'),JSON.stringify({executor:{owner_boot:`boot-${id}`}}),'parent');
  db.prepare("INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,'fixture',?,'boot-fixture','active',1)").run(id,`run-${id}`);
  db.close();
  return tree;
}
function endChild(fx,id) {
  const db=new DatabaseSync(path.join(fx.data,'memory.db'));
  db.prepare('UPDATE sessions SET ended_at=1 WHERE id=?').run(id);
  db.prepare("UPDATE steering_runs SET state='settled' WHERE session_id=?").run(id);
  db.close();
}
function source(fx) { return {kind:'node-runtime',repo:fx.repo,data:fx.data,memory_db:path.join(fx.data,'memory.db'),process_probe:false}; }
function rawRow(store,id) {
  const db=new DatabaseSync(path.join(store,'waves.sqlite'),{readOnly:true});
  try { return db.prepare('SELECT * FROM waves WHERE id=?').get(id); } finally { db.close(); }
}
function rawState(store,id,state) {
  const db=new DatabaseSync(path.join(store,'waves.sqlite'));
  try { db.prepare('UPDATE waves SET state=? WHERE id=?').run(state,id); } finally { db.close(); }
}

try {
  const fx=fixture('first');
  // A genuinely unverifiable convergence: the effect command exited zero but its cleanup outcome
  // is unknown, which is never treated as settlement.
  create(fx.store,fx.manifest);
  const blocked=await advance(fx.store,'first');
  check(blocked.ok===false && blocked.state==='blocked','an unknown effect outcome blocks the wave');

  // (d) NAMED, NOT COMPLETE.
  const first=inspect(fx.store,'first');
  check(first.state==='blocked','the unverified convergence stays a durable blocked row');
  check(first.convergence==='unverified','the convergence is named unverified');
  check(first.runtime_state==='unverified','the wave reports the named unverified state');
  check(first.runtime_state!=='complete' && first.activity!=='on','it is never reported as complete, and nothing is in flight');
  check(first.reason.includes('operation_outcome_unknown'),'the reason names the unverified effect');

  // (a) ZERO LIVE CHILDREN CANNOT BLOCK THE NEXT WAVE.
  check(activityInventory(source(fx)).on===false,'the private store proves nothing is in flight');
  const second=create(fx.store,{...fx.manifest,id:'second',bootstrap:false});
  check(second.ok===true,'a wave with zero live children cannot block starting the next wave');
  check(second.previous.id==='first' && second.previous.activity==='off','the idle previous wave is reported off, from the node store');
  check(second.previous.convergence==='unverified' && second.previous.runtime_state==='unverified','and its unverified convergence is named, never silently complete');
  check(inspect(fx.store,'second').state==='pending','the next wave is admitted');
  check(inspect(fx.store,'first').state==='blocked','the idle wave keeps its own named state');

  // (b) A LIVE CHILD REPORTS ON.
  const tree=liveChild(fx,'child-1');
  const inventory=activityInventory(source(fx));
  check(inventory.on===true,'a live child makes the repository active');
  check(inventory.agents.length===1 && inventory.agents[0].session==='child-1','the in-flight agent is the child, with its own identity');
  const active=waveActivity(source(fx),rawRow(fx.store,'second'));
  check(active.activity==='on' && active.runtime_state==='active','a wave with a live child reports ON');
  assert.throws(()=>create(fx.store,{...fx.manifest,id:'third',bootstrap:false}),/previous_wave_active/);checks++;
  check(inspect(fx.store,'second').runtime_state==='active','inspect agrees: the wave is on while the child works');
  check(fs.existsSync(tree),'the live child tree is real and left alone');

  // OFF AGAIN, AND THE NEXT WAVE STARTS.
  endChild(fx,'child-1');
  check(activityInventory(source(fx)).on===false,'an ended child is not activity');
  check(create(fx.store,{...fx.manifest,id:'third',bootstrap:false}).ok===true,'with every child off, the next wave starts');

  // A WAVE NEVER REPORTS AN ACTIVE STATE WITH NOTHING RUNNING.
  rawState(fx.store,'third','running');
  const stale=inspect(fx.store,'third');
  check(stale.state==='idle','a running row with nothing in flight is never reported active');
  check(stale.bookkeeping_state==='running','the durable bookkeeping value stays visible');
  check(stale.runtime_state==='idle' && stale.activity==='off','the derived verdict is what the wave reports');

  // THE MIGRATION: non-destructive, explicit, reversible.
  const before=rawRow(fx.store,'second');
  const plan=migrationPlan(fx.store,'second');
  check(plan.ok===true && plan.wave_id==='second' && plan.legacy_migrated===false,'the plan reads the legacy row without changing it');
  check(plan.derived.convergence==='open','an unmigrated pending row is an open convergence, not a completion');
  const applied=migrationApply(fx.store,'second','lane-d');
  check(applied.ok===true && applied.legacy_migrated===true,'the migration records the legacy row');
  check(applied.original_unchanged===true,'the migration moves no original column');
  check(fs.existsSync(path.join(fx.store,'migration.json')),'the migration leaves a durable, readable record');
  const afterApply=rawRow(fx.store,'second');
  for(const column of ['id','repo','manifest','manifest_hash','state','reason','owner','created_at','updated_at','receipt'])
    check(JSON.stringify(afterApply[column]??null)===JSON.stringify(before[column]??null),`migration left ${column} exactly as it was`);
  assert.throws(()=>migrationApply(fx.store,'second','lane-d'),/wave_already_migrated/);checks++;
  const migrated=inspect(fx.store,'second');
  check(migrated.convergence==='legacy-unverified' && migrated.runtime_state==='unverified','the legacy row is reported as a NAMED unverified state');
  check(migrated.legacy_migrated===true,'and it is visibly marked as migrated');
  check(create(fx.store,{...fx.manifest,id:'fourth',bootstrap:false}).ok===true,'admission keeps working while the legacy row exists');
  const reverted=migrationRevert(fx.store,'second');
  check(reverted.ok===true && reverted.legacy_migrated===false,'the migration reverts');
  check(!fs.existsSync(path.join(fx.store,'migration.json')),'the migration record is removed on revert');
  const afterRevert=rawRow(fx.store,'second');
  for(const column of ['id','repo','manifest','manifest_hash','state','reason','owner','created_at','updated_at','receipt'])
    check(JSON.stringify(afterRevert[column]??null)===JSON.stringify(before[column]??null),`revert restored ${column} exactly`);
  check(inspect(fx.store,'second').convergence==='open','after revert the row is an open convergence again');
  passed=true;
  console.log(`wave derived state ok (${checks} checks; real private Git and node store, on/off derived from children, named unverifiable convergence, reversible migration)`);
} finally {
  if(passed) fs.rmSync(root,{recursive:true,force:true}); else console.error(`wave derived-state fixtures retained: ${root}`);
}
