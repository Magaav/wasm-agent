// Self-contained private real-helper regression. Optional source root enables mutations.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {DatabaseSync} from 'node:sqlite';
const sourceRoot = path.resolve(process.argv[2] || '.');
const lib = await import(pathToFileURL(path.join(sourceRoot,'scripts/lib/wave-activity.mjs')));
const cli = await import(pathToFileURL(path.join(sourceRoot,'scripts/wave-activity.mjs')));
const root = fs.mkdtempSync(path.join(os.tmpdir(),'wa-owner-refusal-'));
const repo=path.join(root,'repo'),data=path.join(root,'data'),tree=path.join(root,'owned-tree'),beat=path.join(root,'heartbeat'),config=path.join(root,'config.json');
let checks=0; const check=(x,label)=>{assert.ok(x,label);checks++;};
const helpers=new Set();
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function stop(p){if(p.exitCode!==null||p.signalCode!==null)return;const done=new Promise(r=>p.once('exit',r));p.kill();await done;helpers.delete(p);}
function helper(args,cwd){const p=spawn(process.execPath,args,{cwd,stdio:'ignore'});helpers.add(p);return p;}
function git(...args){const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
function configProbe(probe){fs.writeFileSync(config,JSON.stringify({repo,data,source_root:sourceRoot,process_probe:probe}));}
function source(probe){return {kind:'node-runtime',repo,data,memory_db:path.join(data,'memory.db'),process_probe:probe};}
const receipt=()=>path.join(repo,'.git','wa-waves','activity-resolutions.json');
const bytes=()=>fs.existsSync(receipt())?fs.readFileSync(receipt(),'utf8'):null;
function refuse(){const before=bytes();assert.throws(()=>cli.resolve(config,'working-child','mere prose',{run:'held-run'}),/exact_owner_settlement_and_drain_unavailable/);checks++;check(bytes()===before,'refusal preserves receipt bytes');}
function state(probe,corroborated){const x=lib.activityInventory(source(probe));check(x.activity!=='off'&&x.agents.length===1&&x.resolved_claims.length===0,'owner retained, not OFF');check(x.agents[0].corroborated===corroborated,'scan accuracy');const o=cli.observe(config);check(o.activity_claims.length===1&&o.activity_claims[0].positive===true&&o.activity_claims[0].corroborated===corroborated&&o.activity_claims[0].resolvable===false,'observe positive/corroborated/resolvable accuracy');return x;}
try {
 fs.mkdirSync(repo);fs.mkdirSync(data);git('init','-q','-b','main');git('config','user.name','fixture');git('config','user.email','fixture@invalid');fs.writeFileSync(path.join(repo,'seed'),'private');git('add','.');git('commit','-qm','fixture');git('worktree','add','--detach',tree);
 const db=new DatabaseSync(path.join(data,'memory.db'));
 db.exec(`CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT,workspace_required INTEGER,workspace_state TEXT,workspace_branch TEXT,workspace_base_commit TEXT,workspace_source_path TEXT,workspace_start_state TEXT,parent_session_id TEXT,started_at REAL,ended_at REAL,updated_at REAL); CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT,run_id TEXT,boot TEXT,state TEXT,updated_at REAL); CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT,parent_session TEXT,state TEXT,run_id TEXT);`);
 db.prepare('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)').run('working-child',tree,1,'allocated','',git('rev-parse','HEAD'),repo,'{}',null,1,null,1);
 db.prepare('INSERT INTO steering_runs VALUES(?,?,?,?,?,?)').run('working-child','fixture','held-run','held-boot','active',1);db.close();
 const hidden=helper(['-e',`setInterval(()=>require('fs').writeFileSync(${JSON.stringify(beat)},String(Date.now())),30)`],tree);
 await sleep(1200);
 for(const [probe,expected] of [[true,false],[false,null]]){
  configProbe(probe);state(probe,expected);const b=fs.readFileSync(beat,'utf8');refuse();await sleep(120);check(fs.readFileSync(beat,'utf8')!==b,'heartbeat continues during refusal');
 }
 const identity=lib.claimIdentity(state(false,null).agents[0],lib.POSITIVE_CLAIM);
 fs.mkdirSync(path.dirname(receipt()),{recursive:true});fs.writeFileSync(receipt(),JSON.stringify({schema:1,kind:'wave-activity-resolutions',resolutions:[{...identity,evidence:'legacy prose',at:1,by:'fixture'}]}));
 check(lib.readResolutions(receipt()).ok,'legacy fixture is a valid readable receipt');
 const original=bytes();
 for(const [probe,expected] of [[true,false],[false,null]]){
  configProbe(probe);state(probe,expected);refuse();
  const fresh=spawnSync(process.execPath,[path.join(sourceRoot,'scripts/wave-activity.mjs'),'observe',config],{encoding:'utf8'});check(fresh.status===0,'restart/read succeeds');check(JSON.parse(fresh.stdout).activity!=='off','fresh process cannot replay prose');
 }
 const update=new DatabaseSync(path.join(data,'memory.db'));
 for(const [run,boot] of [['new-run','held-boot'],['held-run','new-boot']]){update.prepare('UPDATE steering_runs SET run_id=?,boot=?').run(run,boot);configProbe(false);state(false,null);refuse();}
 update.prepare('UPDATE steering_runs SET run_id=?,boot=?').run('held-run','held-boot');update.close();
 await stop(hidden);
 const visible=helper(['-e','setInterval(()=>{},1000)',tree],tree);await sleep(1200);configProbe(true);state(true,true);refuse();await stop(visible);
 // Terminal-looking prose and no visible process remain unsupported, not drain proof.
 configProbe(false);state(false,null);refuse();check(bytes()===original,'legacy receipt retained exactly');
 const missing={...source(false),memory_db:path.join(root,'missing.db')};check(lib.activityInventory(missing).activity==='unverifiable','unavailable store distinct from null visibility');
 fs.writeFileSync(config,JSON.stringify({repo,data:path.join(root,'absent'),process_probe:false}));assert.throws(()=>cli.observe(config),/activity_inventory_unavailable/);checks++;
 console.log(`owner refusal ok (${checks} checks; real false/null heartbeat, creation/replay/restart/identity/visible/observe/store; 0 skipped)`);
} finally {for(const p of helpers)await stop(p);fs.rmSync(root,{recursive:true,force:true});}
