// Real public registration, shared guard, native runtime session fence, Git CAS
// and Orca refresh. Application deployment evidence is deliberately absent:
// public completion MUST block instead of claiming this contract fixture live.
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {spawn,spawnSync} from 'node:child_process';
import {register,start,checkAdmission,location,monitor} from './wave-entry.mjs';
import {native,freeze,combinedSafety,runtimeRetirement,registry,dependencies} from './wave-adapter.mjs';
import {orcaJSON} from './lib/wave-owners.mjs';import {inspect} from './wave-lifecycle.mjs';import {retire} from './wave-retire.mjs';
import {checkWaveAdmission} from './lib/wave-guard.mjs';
const source=path.resolve('.'),binary=path.resolve(process.argv[2] || 'rust/target/debug/wa.exe');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-public-')),repo=path.join(root,'canonical'),remote=path.join(root,'origin.git'),home=path.join(root,'home'),data=path.join(home,'.wasm-agent'),executor=path.join(root,'executor');
fs.mkdirSync(repo);fs.mkdirSync(executor);fs.mkdirSync(home);let checks=0,passed=false;
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
function command(argv,cwd=repo,env={}){const r=spawnSync(argv[0],argv.slice(1),{cwd,env:{...process.env,...env},encoding:'utf8',windowsHide:true,timeout:30000});assert.equal(r.status,0,r.stderr || r.error?.message);return r.stdout.trim();}
const git=(...args)=>command(['git','-C',repo,...args]);const check=(v,label)=>{assert.ok(v,label);checks++;};
try {
 git('init','-q','-b','main');git('config','user.name','public-fixture');git('config','user.email','public@invalid');fs.writeFileSync(path.join(repo,'seed'),'preserved');git('add','.');git('commit','-qm','fixture');command(['git','init','--bare',remote],root);git('remote','add','origin',remote);git('push','-u','origin','main');
 // No extra agent/terminal is launched. This real card remains clean main-only
 // as a durable inspectable fixture; no stale missing directory is left in Orca.
 const added=JSON.parse(command(['orca','repo','add','--path',repo,'--json']));assert.equal(added.ok,true);
 const shown=JSON.parse(command(['orca','repo','show','--repo',`path:${repo}`,'--json']));
 const repoId=shown.result.repo?.id || shown.result.id || added.result.repo?.id;assert.ok(repoId,'actual Orca repository identity');
 const config={repo,source_root:source,wa_binary:binary,home,data,install:path.join(root,'install'),orca_repo_id:repoId,monitor_mode:'external-cli-test',owner_freeze:path.join(executor,'freeze.json'),retirement_plan:path.join(executor,'retire.json'),delivery_store:path.join(data,'sentinel/deliveries')};
 const configFile=path.join(executor,'config.json');fs.writeFileSync(configFile,JSON.stringify(config));
 command([process.execPath,path.join(source,'scripts/ship-wave.mjs'),source,repo],source);git('add','scripts');git('commit','-qm','fixture shipped public entry');git('push','origin','main');
 const main=git('rev-parse','HEAD'),ticket={schema:1,kind:'wave-bootstrap-admission',repo,main,refs_sha256:hash(git('for-each-ref','--format=%(objectname) %(refname)','refs/heads/')),issuer:'fixture-coordinator',reviewer:'fixture-independent'};
 const authority=path.join(executor,'bootstrap.json');fs.writeFileSync(authority,JSON.stringify(ticket));register(repo,configFile,authority);check(!checkAdmission(repo).ok,'registered production path cannot allocate before a wave starts');
 const post=path.join(executor,'observe.cjs');fs.writeFileSync(post,"console.log(JSON.stringify({ok:require('fs').existsSync(process.argv[2])}));");
 const marker=path.join(executor,'phase-effect');const manifest={id:'public',owner:'fixture-coordinator',repo,executor_cwd:executor,bootstrap:true,steps:['land','deploy','retire'].map(name=>({name,argv:[binary,'--db',path.join(root,'driver.db')],env:{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:source,WA_SCRIPT:path.join(source,'scripts/wave-executor.lua'),WA_WAVE_COMMAND:JSON.stringify({program:process.execPath,args:['-e',`require('fs').writeFileSync(${JSON.stringify(marker)},'native effect observed')`],cwd:executor,timeout_seconds:10})},post:{argv:[process.execPath,post,marker]}})),verifiers:Object.fromEntries(['operations','claims','runtime','registries','deliveries','owners'].map(kind=>[kind,{argv:[process.execPath,path.join(source,'scripts/wave-proof.mjs'),kind,configFile]}]))};
 const manifestFile=path.join(executor,'manifest.json');fs.writeFileSync(manifestFile,JSON.stringify(manifest));start(repo,manifestFile);check(checkAdmission(repo,{phase:'allocate'}).ok,'public shared registration admits an active wave');check(checkWaveAdmission(repo,{phase:'produce'}).wave_verified===true,'actual dynamic hot guard imports public entry without executing its CLI');
 const setup=path.join(executor,'setup.lua');fs.writeFileSync(setup,`local json=dofile('lua/vendor/json.lua')\nlocal m=dofile('lua/core/memory.lua');m.setup();assert(json.decode(host.resource('list','{}')).ok)\nlocal w=dofile('lua/core/workspaces.lua')\nlocal p=m.start_session('local','parent',{id='public-parent',user_id='fixture',node_id='fixture'})\nm.set_session_worktree(p,${JSON.stringify(repo.replaceAll('\\','/'))})\nlocal id=m.start_session('local','child',{id='public-child',user_id='fixture',node_id='fixture',parent_session_id=p,workspace_required=true})\nlocal v,e=w.ensure(m,id,p);assert(v,e);print(json.encode(v))\n`);
 const workspace=JSON.parse(command([binary,'--db',path.join(data,'memory.db')],source,{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:source,WA_SCRIPT:setup,WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0'}));
 const created=JSON.parse(command(['orca','worktree','create','--repo',`id:${repoId}`,'--name',`wave-park-${path.basename(root)}`,'--no-parent','--setup','skip','--json']));
 const orcaTree=created.result.worktree;assert.ok(orcaTree?.path);
 const fixtureTerminals=orcaJSON(config,['terminal','list','--worktree',`id:${orcaTree.id}`,'--json']);
 assert.equal(fixtureTerminals.truncated,false);
 for(const terminal of fixtureTerminals.terminals) {
   const live=orcaJSON(config,['terminal','show','--terminal',terminal.handle,'--json']).terminal;
   assert.ok(!live.agentIdentity,'fixture never closes an agent or unknown owner');
   // The fresh fallback shell belongs to this creation receipt; no command or
   // prompt was sent, and setup hooks were explicitly skipped.
   orcaJSON(config,['terminal','close','--terminal',terminal.handle,'--json']);
 }
 const ps=orcaJSON(config,['worktree','ps','--json']);const parkedCard=ps.worktrees.find(c=>c.worktreeId===orcaTree.id);assert.ok(parkedCard?.worktreeInstanceId);
 const parkedBranch=command(['git','-C',orcaTree.path,'symbolic-ref','HEAD']);
 check(fs.existsSync(workspace.worktree),'real managed session allocated through public guard');
 const state=JSON.parse(workspace.workspace_start_state || JSON.stringify(workspace.start_state));assert.ok(state.executor.owner_boot);
 const claimScript=path.join(executor,'claim.lua');fs.writeFileSync(claimScript,"local j=dofile('lua/vendor/json.lua');assert(j.decode(host.resource('claim',j.encode({principal='fixture',session='public-child',run='public-live',keys={'session:public-child'}}))).ok);print('CLAIM_READY');io.stdout:flush();host.sleep(30000)\n");
 const holder=spawn(binary,['--db',path.join(data,'memory.db')],{cwd:source,env:{...process.env,WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:source,WA_SCRIPT:claimScript},stdio:['ignore','pipe','pipe'],windowsHide:true});let claimOutput='';holder.stdout.on('data',b=>claimOutput+=b);
 const claimDeadline=Date.now()+10000;while(!claimOutput.includes('CLAIM_READY') && Date.now()<claimDeadline)await new Promise(r=>setTimeout(r,20));assert.ok(claimOutput.includes('CLAIM_READY'));
 check(!combinedSafety(config,workspace.worktree).ok,'real live session claim blocks retirement safety');
 const expectedClaim=native(config,{kind:'claims'}).claims.find(c=>c.key==='session:public-child');
 check(native(config,{kind:'claim_reconcile',expected_claim:expectedClaim,evidence:'fixture has not drained yet'}).ok===false,'native resource API refuses live boot lease');
 const exited=new Promise(r=>holder.once('exit',r));holder.kill();await exited;
 const cleared=native(config,{kind:'claim_reconcile',expected_claim:expectedClaim,evidence:'Owned helper was exact-handle killed and waited; its reviewed fixture script only claimed and slept; no target effect, originals preserved'});
 check(cleared.ok===true,'existing resource API reconciles only after actual owned drain and scoped effect inspection');
 const owner=`runtime:public-child:${state.executor.owner_boot}`;git('push','origin',workspace.branch);
 const adapter=(kind)=>[process.execPath,path.join(source,'scripts/wave-adapter.mjs'),kind,configFile];
 const plan={wave_id:'public',owner:'fixture-coordinator',repo,main,managed_roots:[data],local:[{ref:'refs/heads/'+workspace.branch,tip:main}],remote:[{ref:'refs/heads/'+workspace.branch,tip:main}],worktrees:[{path:workspace.worktree,tip:main,branch:'refs/heads/'+workspace.branch,mode:'remove',session_id:'public-child',user_id:'fixture',owner_id:owner,owner_argv:adapter('owner'),safety_argv:adapter('safety'),mutation_argv:adapter('runtime-retire'),reconcile_argv:adapter('reconcile'),registry_post_argv:adapter('registry-post')}],owners_argv:adapter('owners'),dependencies_argv:adapter('dependencies')};
 plan.managed_roots.push(path.dirname(orcaTree.path));plan.local.push({ref:parkedBranch,tip:main});
 plan.worktrees.push({path:orcaTree.path,tip:main,branch:parkedBranch,mode:'park',owner_id:`orca:${parkedCard.worktreeInstanceId}`,owner_argv:adapter('owner'),safety_argv:adapter('safety'),reconcile_argv:adapter('reconcile'),registry_post_argv:adapter('registry-post')});
 fs.writeFileSync(config.retirement_plan,JSON.stringify(plan));process.env.WA_WAVE_ID='public';process.env.WA_WAVE_MAIN=main;process.env.WA_WAVE_TARGET=workspace.worktree;process.env.WA_WAVE_TIP=main;
 check(combinedSafety(config,workspace.worktree).ok,'concrete native indexed operations plus real claims inventory is settled');check(dependencies(config).complete,'actual private Git transport has discoverable dependency scope');freeze(config,'fixture-coordinator','fixture-independent');check(!checkAdmission(repo,{phase:'allocate'}).ok,'freeze blocks new public allocation');check(checkAdmission(repo,{phase:'observe'}).ok && !checkAdmission(repo,{phase:'admit'}).ok,'read-only final observation never reopens frozen admission');
 check(retire(plan,path.join(executor,'retirement')).ok,'real session-fenced retirement and non-force Git CAS settle');check(!fs.existsSync(workspace.worktree),'real directory removal observed');check(registry(config,workspace.worktree).reconciled,'actual runtime and Orca refresh agree after removal');check(git('for-each-ref','--format=%(refname)','refs/heads/')==='refs/heads/main','shared local heads truly main-only');check(git('ls-remote','--heads','origin').split('\n').length===1,'remote heads truly main-only');
 check(registry(config,orcaTree.path).reconciled,'actual Orca card is refreshed to exact detached parked tip');
 delete process.env.WA_WAVE_TARGET;delete process.env.WA_WAVE_TIP;
 const resumed=monitor(repo);check(resumed.state==='blocked','public external continuation refuses missing complete application verification');check(inspect(location(repo),'public').state==='blocked','missing deployment/full-gate proof is durably blocked, never success');check(!checkAdmission(repo).ok,'next production entrypoint is fenced by blocked wave');
 passed=true;console.log(`wave public adapters ok (${checks} checks; real Orca/Git/native runtime closure, missing application verification correctly blocked)`);
}finally{delete process.env.WA_WAVE_ID;delete process.env.WA_WAVE_MAIN;delete process.env.WA_WAVE_TARGET;delete process.env.WA_WAVE_TIP;if(passed)fs.rmSync(root,{recursive:true,force:true});else console.error(`retained real public fixture: ${root}`);}
