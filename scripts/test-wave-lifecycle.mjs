// Disposable Git/SQLite fixtures and stand-in effect drivers, no live install.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawn,spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {create,advance,inspect,reconcile,resume,verify,gitBaseline} from './wave-lifecycle.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-test-'));
let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
function git(repo,args) { const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true}); assert.equal(r.status,0,r.stderr); return r.stdout.trim(); }
function fixture(name) {
  const dir=path.join(root,name),repo=path.join(dir,'canonical'),remote=path.join(dir,'remote.git'),executor=path.join(dir,'executor'),store=path.join(dir,'state');
  fs.mkdirSync(executor,{recursive:true});fs.mkdirSync(repo);
  git(repo,['init','-b','main']);git(repo,['config','user.name','wave-fixture']);git(repo,['config','user.email','wave@invalid']);
  fs.writeFileSync(path.join(repo,'seed'),'fixture\n');
  // A stand-in gate receipt is not enough now: the shared full-gate proof binds a real
  // tracked runner and input scope, so the fixture commits them and runs the real gate.
  fs.mkdirSync(path.join(repo,'scripts'),{recursive:true});fs.mkdirSync(path.join(repo,'skills','parallel-evolution','scripts'),{recursive:true});
  fs.writeFileSync(path.join(repo,'skills','parallel-evolution','scripts','finish.mjs'),'// wave lifecycle fixture gate driver\n');
  fs.writeFileSync(path.join(repo,'scripts','test.sh'),'#!/bin/sh\nprintf "smoke ok\\n"\n');
  git(repo,['add','.']);git(repo,['commit','-m','baseline and gate fixture']);
  git(dir,['init','--bare',remote]);git(repo,['remote','add','origin',remote]);git(repo,['push','-u','origin','main']);
  const gateHead=git(repo,['rev-parse','HEAD']),gateTree=git(repo,['rev-parse','HEAD^{tree}']);
  const driver=path.join(executor,'driver.cjs');
  fs.writeFileSync(driver,`const fs=require('fs'); const mode=process.argv[2];
    if(mode==='step') { fs.appendFileSync(process.argv[3],process.env.WA_WAVE_OPERATION_ID+'\\n'); console.log(JSON.stringify({ok:true,settled:true,cleanup:'self_exited',operation_id:process.env.WA_WAVE_OPERATION_ID})); }
    if(mode==='post') console.log(JSON.stringify({ok:true}));
    if(mode==='proof') console.log(JSON.stringify({ok:true,main:process.env.WA_WAVE_MAIN,wave_id:process.env.WA_WAVE_ID,complete:true,unresolved:[]}));
    if(mode==='zero') console.log(JSON.stringify({ok:true,released:0}));
    if(mode==='invalid') console.log(JSON.stringify({ok:false,reason:'deploy_unverified'}));
    if(mode==='sleep') { fs.writeFileSync(process.argv[3],String(process.pid)); setTimeout(()=>console.log(JSON.stringify({ok:true})),60000); }
    if(mode==='claim') console.log(JSON.stringify({ok:true,main:process.env.WA_WAVE_MAIN,wave_id:process.env.WA_WAVE_ID,complete:true,unresolved:['uncertain-client']}));`);
  const effects=path.join(executor,'effects');
  // A private node runtime store: the sessions/steering_runs/child_completions shape the real
  // `memory.db` has, with nothing in flight. The activity proof reads exactly this.
  const data=path.join(dir,'data');fs.mkdirSync(data,{recursive:true});
  const nodeStore=new DatabaseSync(path.join(data,'memory.db'));
  nodeStore.exec('CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT \'\',workspace_required INTEGER NOT NULL DEFAULT 0,workspace_state TEXT NOT NULL DEFAULT \'unbound\',workspace_branch TEXT NOT NULL DEFAULT \'\',workspace_base_commit TEXT NOT NULL DEFAULT \'\',workspace_source_path TEXT NOT NULL DEFAULT \'\',workspace_start_state TEXT NOT NULL DEFAULT \'{}\',parent_session_id TEXT,started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT \'\',run_id TEXT NOT NULL DEFAULT \'\',boot TEXT NOT NULL DEFAULT \'\',state TEXT NOT NULL,updated_at REAL NOT NULL);CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT \'\',parent_session TEXT NOT NULL DEFAULT \'\',state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT \'\')');
  nodeStore.close();
  // Stand-in receipt to exercise exact-tree/hash/skip checks. This fixture has
  // no application gate; it never claims production test coverage.
  const log=path.join(executor,'gate.log'),receipt=path.join(executor,'gate.json');
  fs.writeFileSync(log,'smoke ok\n');
  const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const shell=process.platform==='win32'?path.join(process.env.ProgramFiles||'C:/Program Files','Git','bin','bash.exe'):'bash';
  fs.writeFileSync(receipt,JSON.stringify({schema:1,passed:true,kind:'full',gate_ms:1,repo,head:gateHead,tree:gateTree,gate_exit:0,gate_runs:1,skipped:0,log,log_sha256:hash(log),shell,
    host:{hostname:os.hostname(),platform:process.platform,arch:os.arch()},
    runner:{path:path.join(repo,'skills','parallel-evolution','scripts','finish.mjs'),sha256:hash(path.join(repo,'skills','parallel-evolution','scripts','finish.mjs')),platform:process.platform},
    input_scope:{tree:gateTree,command:'bash scripts/test.sh',gate_sha256:hash(path.join(repo,'scripts','test.sh'))}}));
  const manifest={id:name,owner:'fixture-owner',repo,executor_cwd:executor,bootstrap:true,
    // THE ACTIVITY SOURCE. The wave's on/off is read from the node's own records, so a fixture
    // that wants a provable OFF declares a real (private, empty) node runtime store. Nothing
    // about this fixture is a waiver: `previous_wave_activity_unverifiable` still refuses when a
    // manifest names no source at all.
    activity:{data},
    gate_receipt:receipt,
    steps:['land','deploy','retire'].map(name=>({name,argv:[process.execPath,driver,'step',effects],post:{argv:[process.execPath,driver,'post']}})),
    verifiers:Object.fromEntries(['operations','claims','runtime','registries','deliveries','owners'].map(name=>[name,{argv:[process.execPath,driver,'proof']}]))};
  return {dir,repo,remote,executor,store,driver,effects,manifest};
}
let succeeded=false;
try {
  const malformed=fixture('malformed');
  for(const budget of ['not-a-number',0,-1,6,Infinity,Number.MAX_SAFE_INTEGER+1]) {
    const bad=JSON.parse(JSON.stringify(malformed.manifest));bad.steps[0].post.max_attempts=budget;
    assert.throws(()=>create(malformed.store,bad),/invalid_post_attempts/);checks++;
  }
  const badPost=JSON.parse(JSON.stringify(malformed.manifest));badPost.steps[0].post.argv=[];
  assert.throws(()=>create(malformed.store,badPost),/post_argv_required/);checks++;
  badPost.steps[0].post.argv=[process.execPath];badPost.steps[0].post.timeout_ms='unbounded';
  assert.throws(()=>create(malformed.store,badPost),/invalid_post_timeout/);checks++;
  const good=fixture('good');create(good.store,good.manifest);
  const result=await advance(good.store,'good');check(result.ok===true,'fresh complete Git and registry evidence settles wave');
  check(inspect(good.store,'good').state==='complete','completion is durable');
  check(fs.readFileSync(good.effects,'utf8').trim().split('\n').length===3,'completion directly continues exactly three drivers');
  const next={...good.manifest,id:'next',bootstrap:false};
  create(good.store,next);check(inspect(good.store,'next').state==='pending','clean verified baseline admits next wave');
  const zero=fixture('zero');zero.manifest.steps[2].argv=[process.execPath,zero.driver,'zero'];create(zero.store,zero.manifest);
  check((await advance(zero.store,'zero')).ok===false,'zero-released exit zero is not effect settlement or convergence');
  check(inspect(zero.store,'zero').steps[2].state==='unknown','ambiguous cleanup is durably unknown');
  const beside=create(zero.store,{...zero.manifest,id:'idle-next'});
  check(beside.ok===true,'a wave with zero live children cannot block starting the next wave');
  check(beside.previous?.id==='zero' && beside.previous.activity==='off','the idle previous wave is reported as off, from the node store and not from its row');
  check(beside.previous.convergence==='unverified' && beside.previous.runtime_state==='unverified','an unverified convergence is a named state, never a silent completion');
  check(inspect(zero.store,'zero').state==='blocked' && inspect(zero.store,'zero').runtime_state==='unverified','the unverified convergence stays durable and named');
  check(inspect(zero.store,'idle-next').state==='pending','the next wave is admitted beside the idle one');
  assert.throws(()=>resume(zero.store,'zero','count inspected'),/unknown_effect/);checks++;
  const uncertain=inspect(zero.store,'zero');
  assert.throws(()=>reconcile(zero.store,'zero',{operation_id:uncertain.steps[2].operation_id,evidence:'x'}),/exact_identity/);checks++;
  reconcile(zero.store,'zero',{operation_id:uncertain.steps[2].operation_id,expected_manifest_hash:uncertain.manifest_hash,evidence:'driver only emitted a count',drain_evidence:'stand-in driver exited with no descendants',effect_evidence:'fixture driver performed no retirement effect',outcome:'no_effect'});
  check(inspect(zero.store,'zero').steps[2].state==='pending','explicit no-effect reconciliation permits bounded replacement');
  const dirty=fixture('dirty');fs.writeFileSync(path.join(dirty.repo,'dirty'),'preserve');
  assert.throws(()=>verify(dirty.manifest),/canonical_dirty/);checks++;
  check(fs.readFileSync(path.join(dirty.repo,'dirty'),'utf8')==='preserve','dirty file retained');
  const unmerged=fixture('unmerged'),tree=path.join(unmerged.dir,'unmerged-tree');
  git(unmerged.repo,['worktree','add','--detach',tree]);fs.writeFileSync(path.join(tree,'value'),'valuable');git(tree,['add','value']);git(tree,['commit','-m','unmerged value']);
  assert.throws(()=>gitBaseline(unmerged.repo),/worktree_unmerged/);checks++;
  check(fs.existsSync(path.join(tree,'value')),'unmerged detached work preserved');
  const stale=fixture('stale');create(stale.store,stale.manifest);check((await advance(stale.store,'stale')).ok,'initial clean stale fixture');
  git(stale.repo,['branch','late-owner']);assert.throws(()=>create(stale.store,{...stale.manifest,id:'stale-next'}),/local_not_main_only/);checks++;
  const claim=fixture('claim');claim.manifest.verifiers.claims.argv=[process.execPath,claim.driver,'claim'];create(claim.store,claim.manifest);
  check((await advance(claim.store,'claim')).ok===false,'uncertain resource claim blocks wave completion');
  check(inspect(claim.store,'claim').reason.includes('claims_unresolved'),'blocked reason names claim projection');
  const deploy=fixture('deploy');deploy.manifest.verifiers.runtime.argv=[process.execPath,deploy.driver,'invalid'];create(deploy.store,deploy.manifest);
  check((await advance(deploy.store,'deploy')).ok===false,'deployment uncertainty blocks finished state');
  const gateFailure=fixture('gate-failure');
  const badGate=JSON.parse(fs.readFileSync(gateFailure.manifest.gate_receipt));badGate.passed=false;fs.writeFileSync(gateFailure.manifest.gate_receipt,JSON.stringify(badGate));
  create(gateFailure.store,gateFailure.manifest);check((await advance(gateFailure.store,'gate-failure')).ok===false,'failed combined full gate cannot become wave success');
  check(inspect(gateFailure.store,'gate-failure').reason.includes('combined_full_gate'),'durable blocked reason identifies missing full gate');
  const retry=fixture('retry'),repaired=path.join(retry.executor,'repaired'),observer=path.join(retry.executor,'observe.cjs');
  fs.writeFileSync(observer,`console.log(JSON.stringify({ok:require('fs').existsSync(process.argv[2])}));`);
  retry.manifest.steps[0].post={argv:[process.execPath,observer,repaired],max_attempts:2};create(retry.store,retry.manifest);
  check((await advance(retry.store,'retry')).ok===false,'postcondition exhaustion is terminal and bounded');
  check(inspect(retry.store,'retry').steps[0].post_attempts===2,'observation attempt budget is durable');
  check(fs.readFileSync(retry.effects,'utf8').trim().split('\n').length===1,'failed postconditions never repeat effects');
  fs.writeFileSync(repaired,'observed repaired state');resume(retry.store,'retry','fixture repair observed');
  check((await advance(retry.store,'retry')).ok===true,'explicit resolution continues observations and remaining stages');
  check(fs.readFileSync(retry.effects,'utf8').trim().split('\n').length===3,'effect command is not replayed by observation recovery');
  const moved=fixture('moved');
  const mover=path.join(moved.executor,'move.cjs');fs.writeFileSync(mover,`require('child_process').spawnSync('git',['-C',${JSON.stringify(moved.repo)},'push','origin','main:late-arrival']); console.log(JSON.stringify({ok:true,main:process.env.WA_WAVE_MAIN,wave_id:process.env.WA_WAVE_ID}));`);
  moved.manifest.verifiers.registries.argv=[process.execPath,mover];assert.throws(()=>verify(moved.manifest),/remote_not_main_only|baseline_moved/);checks++;
  const crash=fixture('crash'),pidFile=path.join(crash.executor,'child.pid');
  crash.manifest.steps[0].argv=[process.execPath,crash.driver,'sleep',pidFile];create(crash.store,crash.manifest);
  const runner=spawn(process.execPath,[path.resolve('scripts/wave-lifecycle.mjs'),'advance',crash.store,'crash'],{stdio:'ignore',windowsHide:true});
  const deadline=Date.now()+10000;while(!fs.existsSync(pidFile) && Date.now()<deadline) await new Promise(r=>setTimeout(r,20));
  assert.ok(fs.existsSync(pidFile),'driver admitted before crash');
  const closed=new Promise(resolve=>runner.on('exit',resolve));runner.kill();await closed;
  // Kill only the PID owned by this disposable test, never a live image name.
  try { process.kill(Number(fs.readFileSync(pidFile,'utf8'))); } catch {}
  const recovered=await advance(crash.store,'crash');check(recovered.ok===false,'restart refuses replay of interrupted effect');
  const interrupted=inspect(crash.store,'crash');check(interrupted.steps[0].state==='unknown','crash checkpoint preserves exact operation ID');
  check(interrupted.events.filter(e=>e.type==='operation_admitted').length===1,'crash does not admit a duplicate command');
  const receipt={operation_id:interrupted.steps[0].operation_id,settled:true,cleanup:'terminated',ok:true};
  reconcile(crash.store,'crash',{operation_id:receipt.operation_id,expected_manifest_hash:interrupted.manifest_hash,evidence:'fixture drained and inspected',drain_evidence:'owned child terminated',effect_evidence:'sleep command had no external effect',outcome:'settled',settlement:receipt});
  check((await advance(crash.store,'crash')).ok===true,'observed settlement continues remaining stages after restart');
  check(inspect(crash.store,'crash').events.filter(e=>e.type==='operation_admitted').length===3,'reconciled stage never reruns');
  succeeded=true;console.log(`wave lifecycle ok (${checks} checks; private Git/SQLite, crash recovery, no live refs/install)`);
} finally {
  if(succeeded) fs.rmSync(root,{recursive:true});else console.error(`wave fixtures retained: ${root}`);
}
