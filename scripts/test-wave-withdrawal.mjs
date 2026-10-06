import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';
import {create,advance,inspect,list,withdraw} from './wave-lifecycle.mjs';
import {apply as migrate} from './wave-migrate.mjs';
import {checkAdmission} from './wave-entry.mjs';
import {withdrawalSnapshot,validateWithdrawal} from './lib/wave-withdrawal.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-withdraw-'));let checks=0,passed=false;
const git=(repo,...args)=>{const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
function fixture(name){const dir=path.join(root,name),repo=path.join(dir,'repo'),store=path.join(dir,'store');fs.mkdirSync(repo,{recursive:true});git(repo,'init','-q','-b','main');git(repo,'config','user.name','fixture');git(repo,'config','user.email','fixture@invalid');fs.writeFileSync(repo+'/seed','fixture');git(repo,'add','.');git(repo,'commit','-qm','seed');const spec={argv:[process.execPath,'-e','throw Error("must not execute")'],post:{argv:[process.execPath,'-e','throw Error("must not execute")']}};const manifest={id:name,owner:'original',repo,executor_cwd:dir,bootstrap:true,activity:{kind:'none'},steps:['land','deploy','retire'].map(name=>({name,...spec})),verifiers:Object.fromEntries(['operations','claims','runtime','registries','deliveries','owners'].map(n=>[n,spec]))};create(store,manifest);migrate(store,name,'fixture');return{dir,repo,store,id:name};}
function input(fx){return{...withdraw(fx.store,fx.id),actor:'operator',evidence:'Inspect exact original journal: three pending steps, zero attempts, no operation IDs; withdraw this obsolete plan only.'};}
function db(fx){return new DatabaseSync(fx.store+'/waves.sqlite');}
const check=(v,label)=>{assert(v,label);checks++;};
try{
 const fx=fixture('never-started'),before=db(fx);const original=withdrawalSnapshot(before,before.prepare('SELECT * FROM waves').get());before.close();const ticket=input(fx);
 check(withdraw(fx.store,fx.id,ticket).state==='withdrawn','explicit plan withdrawn');
 check(withdraw(fx.store,fx.id,ticket).already_withdrawn===true,'known duplicate collects existing receipt');
 const after=db(fx),row=after.prepare('SELECT * FROM waves').get();const proof=validateWithdrawal(after,row);
 check(JSON.stringify(proof.original)===JSON.stringify(original),'original row/steps/events exact');
 check(proof.convergence_verified===false&&proof.effects_replayed===false,'not success or convergence certification');
 check(list(fx.store).unfinished.length===0,'withdrawn plan not unfinished');
 check(inspect(fx.store,fx.id).convergence==='not-run','inspection explicitly not-run');
 check(inspect(fx.store,fx.id).next_action.kind==='none','never schedules withdrawn effects');
 const registered=path.join(fx.repo,'.git','wa-waves');fs.mkdirSync(registered);fs.copyFileSync(fx.store+'/waves.sqlite',registered+'/waves.sqlite');
 fs.writeFileSync(registered+'/registration.json',JSON.stringify({schema:1,repo:fx.repo,owner:'fixture',config:fx.dir+'/config.json',source_root:fx.repo}));
 check(checkAdmission(fx.repo,{phase:'land'}).reason.startsWith('next_wave_requires_fresh_public_start'),'withdrawal does not mint new landing authority');
 check(checkAdmission(fx.repo,{phase:'observe'}).convergence==='not-run','entry observation names not-run');
 await assert.rejects(()=>advance(fx.store,fx.id),/wave_withdrawn_never_replay/);checks++;
 check(after.prepare('SELECT count(*) n FROM steps WHERE attempts>0').get().n===0,'advance did not admit an effect');
 after.prepare("UPDATE steps SET attempts=1 WHERE position=0").run();assert.throws(()=>list(fx.store),/steps_moved/);checks++;after.close();
 for(const [field,value] of [['attempts',1],['post_attempts',1],['operation_id','copied-op'],['result','{}'],['state','unknown']]){const f=fixture('bad-'+field),d=db(f);d.prepare('UPDATE steps SET '+field+'=? WHERE position=0').run(value);d.close();assert.throws(()=>withdraw(f.store,f.id,input(f)),/effect_history/);checks++;}
 const stale=fixture('stale'),staleTicket=input(stale);assert.throws(()=>withdraw(stale.store,stale.id,{...staleTicket,expected_snapshot_sha256:'wrong'}),/snapshot_moved/);checks++;
 const admitted=fixture('event'),d=db(admitted);d.prepare("INSERT INTO events(wave,at,type,body) VALUES(?,1,'operation_admitted','{}')").run(admitted.id);d.close();assert.throws(()=>withdraw(admitted.store,admitted.id,input(admitted)),/effect_history/);checks++;
 const noAuth=fixture('no-auth');assert.throws(()=>withdraw(noAuth.store,noAuth.id,{...input(noAuth),actor:''}),/actor_and_evidence/);checks++;
 const boot=fixture('owner'),b=db(boot);b.prepare("UPDATE waves SET boot='original-owner'").run();b.close();assert.throws(()=>withdraw(boot.store,boot.id,input(boot)),/only_never_admitted/);checks++;
 passed=true;console.log(`wave withdrawal ok (${checks} checks, 0 skipped; private Git/SQLite; no effects executed)`);
}finally{if(passed)fs.rmSync(root,{recursive:true,force:true});else console.error('evidence: '+root);}
