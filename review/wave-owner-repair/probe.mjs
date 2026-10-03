// Independent private-only falsification. No live stores are opened.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import assert from 'node:assert/strict';
const [tip,root]=process.argv.slice(2).map(x=>path.resolve(x));
fs.mkdirSync(root,{recursive:true});
const mod=rel=>import(pathToFileURL(path.join(tip,rel)).href);
const lib=await mod('scripts/lib/wave-activity.mjs'),cli=await mod('scripts/wave-activity.mjs');
const repo=path.join(root,'repo'),data=path.join(root,'data'),tree=path.join(root,'owned-tree');
fs.mkdirSync(repo,{recursive:true});fs.mkdirSync(data,{recursive:true});
function git(...args){const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
git('init','-q','-b','main');git('config','user.name','review');git('config','user.email','review@invalid');fs.writeFileSync(path.join(repo,'seed'),'private');git('add','.');git('commit','-qm','fixture');git('worktree','add','--detach',tree);
const db=new DatabaseSync(path.join(data,'memory.db'));
db.exec(`CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT,workspace_required INTEGER,workspace_state TEXT,workspace_branch TEXT,workspace_base_commit TEXT,workspace_source_path TEXT,workspace_start_state TEXT,parent_session_id TEXT,started_at REAL,ended_at REAL,updated_at REAL); CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT,run_id TEXT,boot TEXT,state TEXT,updated_at REAL); CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT,parent_session TEXT,state TEXT,run_id TEXT);`);
db.prepare('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)').run('working-child',tree,1,'allocated','',git('rev-parse','HEAD'),repo,'{}',null,1,null,1);
db.prepare('INSERT INTO steering_runs VALUES(?,?,?,?,?,?)').run('working-child','review','held-run','held-boot','active',1);db.close();
const configFile=path.join(root,'config.json');
function config(probe){fs.writeFileSync(configFile,JSON.stringify({repo,data,source_root:tip,process_probe:probe}));}
const source=probe=>({kind:'node-runtime',repo,data,memory_db:path.join(data,'memory.db'),process_probe:probe});
const resolutions=()=>path.join(repo,'.git','wa-waves','activity-resolutions.json');
function attempt(){try{return cli.resolve(configFile,'working-child','mere prose: no process names this tree',{run:'held-run'});}catch(e){return {refused:true,error:e.message};}}
function snapshot(probe){const x=lib.activityInventory(source(probe));return {activity:x.activity,agents:x.agents.length,resolved:x.resolved_claims.length,corroborated:x.bindings[0]?.corroborated};}
async function stop(p){const done=new Promise(r=>p.once('exit',r));p.kill();await done;}
// Visible holder provides the positive control.
const visible=spawn(process.execPath,['-e','setInterval(()=>{},1000)',tree],{stdio:'ignore'});
try{await new Promise(r=>setTimeout(r,1200));config(true);console.log('VISIBLE',JSON.stringify({before:snapshot(true),resolve:attempt()}));assert.equal(snapshot(true).corroborated,true);assert.equal(attempt().refused,true);}finally{await stop(visible);}
// Working holder intentionally has no tree path in command line; prove its work via private heartbeat.
const beat=path.join(root,'heartbeat');const hidden=spawn(process.execPath,['-e',`setInterval(()=>require('fs').writeFileSync(${JSON.stringify(beat)},String(Date.now())),30)`],{cwd:tree,stdio:'ignore'});
try{
 await new Promise(r=>setTimeout(r,1200));assert.ok(fs.existsSync(beat));const beforeBeat=fs.readFileSync(beat,'utf8');
 config(true);const before=snapshot(true),resolution=attempt(),after=snapshot(true);await new Promise(r=>setTimeout(r,120));const stillWorking=fs.readFileSync(beat,'utf8')!==beforeBeat;
 console.log('BLIND_WORKING',JSON.stringify({before,resolution,after,stillWorking,turnState:'active'}));assert.equal(before.corroborated,false);assert.equal(stillWorking,true);assert.equal(after.agents,1);assert.equal(after.activity,'on');assert.equal(resolution.refused,true);assert.match(resolution.error,/exact_owner_settlement_and_drain_unavailable/);assert.equal(fs.existsSync(resolutions()),false);
 fs.rmSync(resolutions(),{force:true});config(false);const unknownBefore=snapshot(false),unknownResolution=attempt(),unknownAfter=snapshot(false);
 console.log('UNKNOWN_VISIBILITY',JSON.stringify({before:unknownBefore,resolution:unknownResolution,after:unknownAfter}));assert.equal(unknownBefore.corroborated,null);assert.equal(unknownResolution.refused,true);assert.equal(unknownAfter.activity,'on');assert.equal(fs.existsSync(resolutions()),false);
 const identity=lib.claimIdentity({session:'working-child',worktree:tree.replaceAll('\\','/'),turn:{run_id:'held-run',boot:'held-boot'}},lib.POSITIVE_CLAIM);lib.writeResolution(resolutions(),{...identity,evidence:'preserved legacy prose',at:1,by:'review'});const receiptBytes=fs.readFileSync(resolutions(),'utf8');const rows=lib.readResolutions(resolutions()).resolutions;assert.equal(lib.readResolutions(resolutions()).ok,true);assert.equal(snapshot(false).activity,'on');assert.equal(attempt().refused,true);assert.equal(fs.readFileSync(resolutions(),'utf8'),receiptBytes);
 assert.equal(lib.findResolution(rows,identity,{corroborated:false}),null);assert.equal(lib.findResolution(rows,{...identity,run_id:'new-run'},{corroborated:false}),null);assert.equal(lib.findResolution(rows,{...identity,boot:'new-boot'},{corroborated:false}),null);
 console.log('IDENTITY',JSON.stringify({sameBlind:!!lib.findResolution(rows,identity,{corroborated:false}),visible:!!lib.findResolution(rows,identity,{corroborated:true}),newRun:!!lib.findResolution(rows,{...identity,run_id:'new-run'},{corroborated:false}),newBoot:!!lib.findResolution(rows,{...identity,boot:'new-boot'},{corroborated:false})}));
}finally{await stop(hidden);}
console.log('NARROW SAFETY PASS: false/null working owner retained, unsupported creation/replay refused; owned helpers drained.');
