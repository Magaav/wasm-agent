#!/usr/bin/env node
// Production entrypoint: one registered durable wave store per shared repository.
// A fresh arbitrary directory cannot waive next-wave admission or a closing freeze.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {create,inspect,advance} from './wave-lifecycle.mjs';
import {waveActivity,activitySource,isolatedRepository} from './lib/wave-activity.mjs';
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const key=x=>{const p=path.resolve(x).replaceAll('\\','/');return process.platform==='win32'?p.toLowerCase():p;};
function git(repo,...args){const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});if(r.status!==0)throw Error('wave_git_identity_unavailable');return r.stdout.trim();}
export function location(repo){return path.join(fs.realpathSync(git(repo,'rev-parse','--path-format=absolute','--git-common-dir')),'wa-waves');}
export function isolated(repo) {
  return isolatedRepository(repo);
}
function registration(repo) {
  const store=location(repo),file=path.join(store,'registration.json');
  if(!fs.existsSync(file))throw Error('wave_registration_required');
  const row=JSON.parse(fs.readFileSync(file,'utf8'));
  if(row.schema!==1 || key(location(row.repo))!==key(store) || !row.owner || !row.config || !row.source_root)throw Error('wave_registration_unverifiable');
  return {...row,store};
}
export function checkAdmission(repo,{phase='produce'}={}) {
  try {
    if(!['produce','admit','land','allocate','observe'].includes(phase))throw Error('unknown_wave_admission_phase');
    const file=path.join(location(repo),'registration.json');
    if(!fs.existsSync(file) && !fs.existsSync(location(repo))) {
      if(isolated(repo))return {ok:true,wave_verified:false,mode:'isolated_local_fixture'};
      if(['produce','admit','land'].includes(phase))return {ok:true,wave_verified:false,mode:'unregistered_initial_migration_review',reason:'No wave authority established; public start/allocation/completion still require registration'};
    }
    const row=registration(repo),db=new DatabaseSync(path.join(row.store,'waves.sqlite'),{readOnly:true});
    let current;try{current=db.prepare('SELECT * FROM waves ORDER BY created_at DESC LIMIT 1').get();}finally{db.close();}
    if(!current)throw Error('registered_wave_not_started');
    // THE DERIVED ON/OFF, the same fact `create` uses: the wave is on while any child/agent for
    // this repository is in flight, and off when none is. It is read from the node's own
    // inventory, never from the durable row's bookkeeping.
    const verdict=waveActivity(activitySource(JSON.parse(current.manifest)),current);
    const named={activity:verdict.activity,convergence:verdict.convergence,runtime_state:verdict.runtime_state,reason:verdict.reason||current.reason||''};
    if(phase==='observe')return {ok:true,wave_verified:true,wave_id:current.id,store:row.store,phase,...named};
    if(current.state==='complete')throw Error('next_wave_requires_fresh_public_start');
    const freeze=path.join(row.store,'freeze.json');
    if(fs.existsSync(freeze) && phase!=='land')throw Error('wave_closing_frozen');
    if(verdict.activity==='on')return {ok:true,wave_verified:true,wave_id:current.id,store:row.store,phase,...named};
    // OFF. An idle wave must not fence the work that keeps the repository moving: producing and
    // allocating keep being admitted (that is how lanes work under an idle umbrella), while the
    // repository-level acts of landing and independent delivery admission stay refused while the
    // convergence is unverified - and the refusal names that state instead of hiding it.
    if(current.state==='blocked' && ['land','admit'].includes(phase))throw Error('wave_convergence_unverified:'+current.reason);
    return {ok:true,wave_verified:true,wave_id:current.id,store:row.store,phase,...named};
  }catch(e){return {ok:false,wave_verified:false,reason:e.message};}
}
export function register(repo,configFile,attestationFile) {
  const config=JSON.parse(fs.readFileSync(configFile,'utf8')),ticket=JSON.parse(fs.readFileSync(attestationFile,'utf8'));
  const canonical=fs.realpathSync(repo),store=location(canonical);
  if(key(config.repo)!==key(canonical) || git(canonical,'symbolic-ref','HEAD')!=='refs/heads/main')throw Error('wave_canonical_main_required');
  const inventory=git(canonical,'for-each-ref','--format=%(objectname) %(refname)','refs/heads/');
  if(ticket.schema!==1 || ticket.kind!=='wave-bootstrap-admission' || key(ticket.repo)!==key(canonical) || ticket.main!==git(canonical,'rev-parse','HEAD') || ticket.refs_sha256!==hash(inventory) || !ticket.issuer || !ticket.reviewer || ticket.issuer===ticket.reviewer)throw Error('independent_exact_bootstrap_admission_required');
  fs.mkdirSync(store,{recursive:true});
  const row={schema:1,repo:canonical,owner:ticket.issuer,config:path.resolve(configFile),source_root:config.source_root || canonical,attestation:path.resolve(attestationFile),attestation_sha256:hash(fs.readFileSync(attestationFile))};
  fs.writeFileSync(path.join(store,'registration.json'),JSON.stringify(row)+'\n',{flag:'wx'});
  return {ok:true,store,registration:row};
}
export function start(repo,manifestFile) {
  const row=registration(repo),manifest=JSON.parse(fs.readFileSync(manifestFile,'utf8'));
  if(key(manifest.repo)!==key(row.repo))throw Error('wave_manifest_repository_mismatch');
  const prior=fs.existsSync(path.join(row.store,'waves.sqlite'));
  if(manifest.bootstrap===true && prior)throw Error('bootstrap_cannot_be_repeated');
  if(manifest.bootstrap===true && hash(fs.readFileSync(row.attestation))!==row.attestation_sha256)throw Error('bootstrap_authority_moved');
  if(!isolated(repo)) {
    for(const name of ['operations','claims','runtime','registries','deliveries','owners']) {
      const expected=[process.execPath,path.join(row.source_root,'scripts/wave-proof.mjs'),name,row.config];
      if(JSON.stringify(manifest.verifiers?.[name]?.argv)!==JSON.stringify(expected))throw Error('production_wave_requires_concrete_verifier:'+name);
    }
  }
  const receipt=create(row.store,manifest);
  if(fs.existsSync(path.join(row.store,'freeze.json')))fs.unlinkSync(path.join(row.store,'freeze.json')); // previous verified wave's freeze only
  const config=JSON.parse(fs.readFileSync(row.config,'utf8'));
  if(config.monitor_mode==='external-cli-test' && isolated(repo))return {...receipt,monitor:'isolated_external_cli'};
  try {
    if(!config.sentinel_binary || !config.home || !config.install)throw Error('sanctioned_external_monitor_required');
    const invoke=(args)=>{
      const result=spawnSync(config.sentinel_binary,args,{env:{...process.env,WASM_AGENT_HOME:config.home,WA_INSTALL_DIR:config.install},encoding:'utf8',windowsHide:true,timeout:30000});
      if(result.status!==0)throw Error('monitor_registration_failed:'+result.stderr);return result.stdout;
    };
    const preflight=JSON.parse(invoke(['preflight']));if(preflight.watcher!=='running' || preflight.inventory_verified!==true || preflight.stop_file!==false || !preflight.capabilities?.health_free)throw Error('monitor_watcher_unverifiable');
    const definition=path.join(row.store,'monitor-definition.json');fs.writeFileSync(definition,JSON.stringify(watcherDefinition(repo))+'\n');
    invoke(['job','put',definition]);invoke(['job','enable','wave-convergence']);
    return {...receipt,monitor:'sanctioned_sentinel_schedule_registered'};
  }catch(e){
    const db=new DatabaseSync(path.join(row.store,'waves.sqlite'));try{db.prepare("UPDATE waves SET state='blocked',reason=? WHERE id=?").run(e.message,manifest.id);}finally{db.close();}
    throw e;
  }
}
export async function finish(repo,id) {const row=registration(repo);return advance(row.store,id);}
export function monitor(repo) {
  const row=registration(repo),db=new DatabaseSync(path.join(row.store,'waves.sqlite'));
  db.exec('PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS monitor(id TEXT PRIMARY KEY,attempts INTEGER NOT NULL DEFAULT 0,observations INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL,reason TEXT);');
  try {
    const latest=db.prepare('SELECT id FROM waves ORDER BY created_at DESC LIMIT 1').get();if(!latest)throw Error('wave_not_started');
    const status=inspect(row.store,latest.id);
    if(status.state==='complete' || status.state==='blocked')return {ok:status.state==='complete',state:status.state,disable_monitor:true,reason:status.reason};
    db.prepare("INSERT OR IGNORE INTO monitor(id,state) VALUES(?,'pending')").run(latest.id);
    const budget=db.prepare('SELECT attempts,observations FROM monitor WHERE id=?').get(latest.id);
    if(!Number.isSafeInteger(budget.observations) || budget.observations<0 || !Number.isSafeInteger(budget.attempts) || budget.attempts<0) {
      db.prepare("UPDATE waves SET state='blocked',reason='external_monitor_budget_unverifiable' WHERE id=?").run(latest.id);
      return {ok:false,state:'blocked',disable_monitor:true,reason:'external_monitor_budget_unverifiable'};
    }
    // A tick that FOUND the owner is not an observation of its absence. `observations` counts the ticks that
    // looked for the owner and found none - the only ticks the 120 budget is sized for - so a live owner must
    // not spend it. Incrementing before this check made every scheduled tick spend the budget: a wave whose
    // owner was alive and driving it reached `external_monitor_observation_budget_exhausted_owner_preserved`
    // on tick 121, which at the declared 30 s cadence (`watcherDefinition`) is about one hour of being
    // watched, and a blocked wave fences every future admission. Measured: 200 ticks with an owner lease
    // absent-but-unresolved leave the budget at 0, and an owner the lease proves dead still spends one
    // (`scripts/test-wave-monitor-budget.mjs`).
    if(status.owner_liveness!==false)return {ok:false,state:'owner_live_or_unverifiable',disable_monitor:false};
    db.prepare('UPDATE monitor SET observations=observations+1 WHERE id=?').run(latest.id);
    if(db.prepare('SELECT observations FROM monitor WHERE id=?').get(latest.id).observations>120) {
      db.prepare("UPDATE waves SET state='blocked',reason='external_monitor_observation_budget_exhausted_owner_preserved' WHERE id=?").run(latest.id);
      return {ok:false,state:'blocked',disable_monitor:true};
    }
    const attempts=db.prepare('SELECT attempts FROM monitor WHERE id=?').get(latest.id).attempts;
    if(!Number.isSafeInteger(attempts) || attempts<0 || attempts>=3) {
      db.prepare("UPDATE waves SET state='blocked',reason='external_monitor_restart_budget_exhausted' WHERE id=?").run(latest.id);
      return {ok:false,state:'blocked',disable_monitor:true,reason:'external_monitor_restart_budget_exhausted'};
    }
    db.prepare("UPDATE monitor SET attempts=attempts+1,state='admitted' WHERE id=?").run(latest.id);
    const result=spawnSync(process.execPath,[path.join(row.source_root,'scripts/wave-entry.mjs'),'finish',row.repo,latest.id],{cwd:JSON.parse(status.manifest).executor_cwd,encoding:'utf8',windowsHide:true,timeout:10800000,maxBuffer:32*1024*1024});
    const after=inspect(row.store,latest.id);
    db.prepare('UPDATE monitor SET state=?,reason=? WHERE id=?').run(after.state,result.error?.message || after.reason || null,latest.id);
    return {ok:after.state==='complete',state:after.state,disable_monitor:['complete','blocked'].includes(after.state),reason:after.reason,output:result.stdout,error:result.error?.message};
  }finally{db.close();}
}
export function watcherDefinition(repo) {
  const row=registration(repo);
  return {id:'wave-convergence',name:'Verified evolution wave continuation',trigger:{kind:'schedule',every_seconds:30},
    action:{kind:'run',script:path.join(JSON.parse(fs.readFileSync(row.config,'utf8')).install,'scripts/wave-monitor.sh'),timeout_seconds:10800},
    controls:{},description:'Bounded external owner recovery; complete or blocked disables scheduling; unknown effects never replay.'};
}
if(!process.execArgv.some(arg=>arg==='-e' || arg==='--eval') && process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const [verb,repo,a,b]=process.argv.slice(2);let result;
    if(verb==='check')result=checkAdmission(repo,{phase:a || 'produce'});
    else if(verb==='register')result=register(repo,a,b);
    else if(verb==='start')result=start(repo,a);
    else if(verb==='finish')result=await finish(repo,a);
    else if(verb==='monitor')result=monitor(repo);
    else if(verb==='watcher-definition')result=watcherDefinition(repo);
    else throw Error('usage: check|register|start|finish|monitor|watcher-definition REPO [ARGS]');
    console.log(JSON.stringify(result));if(result.ok===false)process.exitCode=1;
  }catch(e){console.log(JSON.stringify({ok:false,reason:e.message}));process.exitCode=1;}
}
