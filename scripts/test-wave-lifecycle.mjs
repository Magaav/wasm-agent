// Disposable Git/SQLite fixtures and stand-in effect drivers, no live install.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawn,spawnSync} from 'node:child_process';
import {create,advance,inspect,reconcile,resume,verify,gitBaseline} from './wave-lifecycle.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-test-'));
let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
function git(repo,args) { const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true}); assert.equal(r.status,0,r.stderr); return r.stdout.trim(); }
function fixture(name) {
  const dir=path.join(root,name),repo=path.join(dir,'canonical'),remote=path.join(dir,'remote.git'),executor=path.join(dir,'executor'),store=path.join(dir,'state');
  fs.mkdirSync(executor,{recursive:true});fs.mkdirSync(repo);
  git(repo,['init','-b','main']);git(repo,['config','user.name','wave-fixture']);git(repo,['config','user.email','wave@invalid']);
  fs.writeFileSync(path.join(repo,'seed'),'fixture\n');git(repo,['add','seed']);git(repo,['commit','-m','baseline']);
  git(dir,['init','--bare',remote]);git(repo,['remote','add','origin',remote]);git(repo,['push','-u','origin','main']);
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
  // Stand-in receipt to exercise exact-tree/hash/skip checks. This fixture has
  // no application gate; it never claims production test coverage.
  const log=path.join(executor,'gate.log'),receipt=path.join(executor,'gate.json');
  fs.writeFileSync(log,'[smoke] ALL PASS (0 skipped)\n');
  const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  fs.writeFileSync(receipt,JSON.stringify({passed:true,gate_exit:0,gate_runs:1,tree:git(repo,['rev-parse','HEAD^{tree}']),skipped:0,log,log_sha256:hash(log),runner:{path:driver,sha256:hash(driver)}}));
  const manifest={id:name,owner:'fixture-owner',repo,executor_cwd:executor,bootstrap:true,
    gate_receipt:receipt,
    steps:['land','deploy','retire'].map(name=>({name,argv:[process.execPath,driver,'step',effects],post:{argv:[process.execPath,driver,'post']}})),
    verifiers:Object.fromEntries(['operations','claims','runtime','registries','deliveries','owners'].map(name=>[name,{argv:[process.execPath,driver,'proof']}]))};
  return {dir,repo,remote,executor,store,driver,effects,manifest};
}
let succeeded=false;
try {
  const good=fixture('good');create(good.store,good.manifest);
  const result=await advance(good.store,'good');check(result.ok===true,'fresh complete Git and registry evidence settles wave');
  check(inspect(good.store,'good').state==='complete','completion is durable');
  check(fs.readFileSync(good.effects,'utf8').trim().split('\n').length===3,'completion directly continues exactly three drivers');
  const next={...good.manifest,id:'next',bootstrap:false};
  create(good.store,next);check(inspect(good.store,'next').state==='pending','clean verified baseline admits next wave');
  const zero=fixture('zero');zero.manifest.steps[2].argv=[process.execPath,zero.driver,'zero'];create(zero.store,zero.manifest);
  check((await advance(zero.store,'zero')).ok===false,'zero-released exit zero is not effect settlement or convergence');
  check(inspect(zero.store,'zero').steps[2].state==='unknown','ambiguous cleanup is durably unknown');
  assert.throws(()=>create(zero.store,{...zero.manifest,id:'forbidden-next'}),/previous_wave_blocked/);checks++;
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
