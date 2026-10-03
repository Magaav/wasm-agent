// Run AFTER producer-admission run; never invoked inside the four proof suites.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import assert from 'node:assert/strict';import {spawnSync,spawn} from 'node:child_process';import {DatabaseSync} from 'node:sqlite';
import {evaluate} from './delivery-admission.mjs';import {verifyFocused} from './producer-admission.mjs';import {terminal} from './lib/delivery-producer-proof.mjs';import {writeRecord,readRecord} from './lib/delivery-store.mjs';
const source=path.resolve('.');
function git(repo,...args){const r=spawnSync('git',['-c','user.name=fixture','-c','user.email=fixture@local',...args],{cwd:repo,encoding:'utf8',maxBuffer:32*1024*1024});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
const receipt=JSON.parse(fs.readFileSync(path.resolve(source,git(source,'rev-parse','--git-path','wa-producer-check.json'))));assert.equal(verifyFocused(source,receipt).admission_verified,true);
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-script-consumer-')),repo=path.join(root,'repo'),producer=path.join(root,'producer'),reviewer=path.join(root,'reviewer'),dbFile=path.join(root,'memory.db'),store=path.join(root,'records');
try{
 git(root,'clone','-q','--no-hardlinks',source,repo);git(repo,'update-ref','refs/remotes/origin/main',receipt.base);
 const owner=process.env.WASM_AGENT_SESSION||'child:dispatch:1f044075-6b4b-4bce-b359-40c131d73533',branch=`change/wa-session-${owner.replace(/[^A-Za-z0-9_-]/g,'')}`;
 // Clone checks out original branch: detach before binding its exact immutable tip.
 git(repo,'checkout','--detach','-q',receipt.base);git(repo,'branch','-D',branch);git(repo,'worktree','add','-qb',branch,producer,receipt.head);
 git(repo,'worktree','add','-qb','change/wa-session-reviewer',reviewer,receipt.base);git(reviewer,'commit','--allow-empty','-qm','independent fixture review\n\nAgent: fixture session=reviewer');const anchor=git(reviewer,'rev-parse','HEAD');
 const db=new DatabaseSync(dbFile);db.exec('CREATE TABLE sessions(id TEXT,worktree TEXT,workspace_required INTEGER,workspace_state TEXT,workspace_branch TEXT)');for(const [id,dir,b]of [[owner,producer,branch],['reviewer',reviewer,'change/wa-session-reviewer']])db.prepare('INSERT INTO sessions VALUES(?,?,?,?,?)').run(id,dir,1,'allocated',b);db.close();
 const record={delivery:branch,branch,repository:producer,producer:owner,tip:receipt.head,tree:receipt.tree,producer_checks:receipt,review:{reviewer:'reviewer',commit:anchor,tip:receipt.head,tree:receipt.tree,verdict:'passed',findings:[]}};
 const check=r=>evaluate({repo,record:r,sessionDb:dbFile});assert.equal(check(record).decision,'admitted');writeRecord(store,record);
 const cli=spawnSync(process.execPath,[path.join(source,'scripts/delivery-admission.mjs'),'admit',branch,'--repo',repo,'--store',store,'--session-db',dbFile,'--by','integrator'],{encoding:'utf8'});assert.equal(cli.status,0,cli.stderr);
 const lane=spawnSync(process.execPath,[path.join(source,'scripts/merge-lane.mjs'),'--repo',repo,branch,'--delivery-store',store,'--delivery-session-db',dbFile,'--gate-mode','none','--no-hooks','--no-reuse-tree'],{encoding:'utf8',maxBuffer:32*1024*1024});assert.equal(lane.status,0,lane.stderr+lane.stdout);
 for(const patch of [{runner:{...receipt.runner,platform:'foreign'}},{runner:{...receipt.runner,sha256:'0'.repeat(64)}},{execution_after:{}},{head:'0'.repeat(40)},{base:'0'.repeat(40)},{results:receipt.results.slice(1)},{sources:{}},{results:receipt.results.map((r,i)=>i? r:{...r,log:path.join(root,'missing')})}])assert.equal(check({...record,producer_checks:{...receipt,...patch}}).decision,'refused');
 // Mutate real log artifacts with recomputed digests; run actual CLI, not parser alone.
 for(const suffix of ['  SKIP mandatory\n','\tSkipped: mandatory\n','1 tests skipped\n']){
  const result=receipt.results[1],log=path.join(root,'mutant.log');fs.writeFileSync(log,suffix+fs.readFileSync(result.log,'utf8'));
  const crypto=await import('node:crypto');const mutated={...receipt,results:receipt.results.map((r,i)=>i===1?{...r,log,log_sha256:crypto.createHash('sha256').update(fs.readFileSync(log)).digest('hex')}:r)};
  const proofFile=path.join(root,'mutant.json');fs.writeFileSync(proofFile,JSON.stringify(mutated));
  const refused=spawnSync(process.execPath,[path.join(source,'scripts/delivery-admission.mjs'),'check',branch,'--repo',repo,'--store',store,'--session-db',dbFile,'--producer-proof',proofFile],{encoding:'utf8'});assert.equal(refused.status,2,refused.stdout);
 }
 // Private source splice at the pre-write boundary, no production switch/callback.
 // A child blocks on a file barrier; parent mutates real private refs/DB/record/source.
 const instrument=path.join(root,'instrument');fs.mkdirSync(instrument);fs.cpSync(path.join(source,'scripts'),instrument,{recursive:true});
 const original=fs.readFileSync(path.join(source,'scripts/delivery-admission.mjs'),'utf8'),needle='      const fresh=evaluate(';
 assert.equal(original.split(needle).length,2);
 const barrier=`fs.writeFileSync(${JSON.stringify(path.join(root,'ready'))},'ready'); while(!fs.existsSync(${JSON.stringify(path.join(root,'release'))}))Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,10);`;
 async function race(kind,mutant=false){
  const file=path.join(instrument,'delivery-admission.mjs');let code=original.replace(needle,barrier+'\n'+needle);if(mutant)code=code.replace("if(fresh.decision==='refused')throw Error(fresh.refusal);",'// intentional missing refusal mutation');fs.writeFileSync(file,code);
  for(const f of ['ready','release'])fs.rmSync(path.join(root,f),{force:true});
  const before=readRecord(store,branch);before.admission=null;writeRecord(store,before);
  const child=spawn(process.execPath,[file,'admit',branch,'--repo',repo,'--store',store,'--session-db',dbFile,'--by','integrator'],{stdio:['ignore','pipe','pipe']});let output='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);const done=new Promise(resolve=>child.on('close',resolve));
  const deadline=Date.now()+30000;while(!fs.existsSync(path.join(root,'ready'))){if(Date.now()>deadline){child.kill();throw Error('race barrier timeout '+output);}await new Promise(r=>setTimeout(r,20));}
  const helper=path.join(producer,'scripts/lib/delivery-local.mjs'),bytes=fs.readFileSync(helper);
  if(kind==='ref')git(repo,'update-ref',`refs/heads/${branch}`,receipt.base,receipt.head);
  if(kind==='source')fs.appendFileSync(helper,'\n// source moved\n');
  if(kind==='binding'){const d=new DatabaseSync(dbFile);d.prepare('UPDATE sessions SET worktree=? WHERE id=?').run(reviewer,owner);d.close();}
  if(kind==='record'){const newer=readRecord(store,branch);newer.race_preserved='newer';writeRecord(store,newer);}
  fs.writeFileSync(path.join(root,'release'),'go');const exit=await done;const after=readRecord(store,branch);
  if(mutant){assert.equal(exit,0,output);assert.ok(after.admission,'mutation must expose stale acceptance');}else{assert.notEqual(exit,0,output);assert.equal(after.admission,null);if(kind==='record')assert.equal(after.race_preserved,'newer');}
  if(kind==='ref')git(repo,'update-ref',`refs/heads/${branch}`,receipt.head,receipt.base);
  fs.writeFileSync(helper,bytes);const d=new DatabaseSync(dbFile);d.prepare('UPDATE sessions SET worktree=? WHERE id=?').run(producer,owner);d.close();
 }
 for(const kind of ['ref','source','binding','record'])await race(kind);await race('binding',true);
 git(producer,'commit','--allow-empty','-qm',`moved\n\nAgent: fixture session=${owner}`);assert.equal(check(record).decision,'refused');git(producer,'checkout','--detach','-q',receipt.head);
 const binding=new DatabaseSync(dbFile);binding.prepare('UPDATE sessions SET worktree=? WHERE id=?').run(reviewer,owner);assert.equal(check(record).decision,'refused');binding.close();
 for(const [suite,count]of [['test-delivery-admission.mjs',58],['test-delivery-store.mjs',9],['test-merge-lane.mjs',107]]){const line=suite.includes('merge')?`merge-lane spine ok (${count} checks)`:suite.includes('store')?`delivery store ok (${count} checks, 0 skipped)`:`delivery admission ok (${count} checks)`;assert.equal(terminal(suite,line),true);for(const bad of ['',line+'\n'+line,line+'\n1 skipped',line.replace(String(count),'1'),line+'\nFAIL bad'])assert.equal(terminal(suite,bad),false);}
 console.log('delivery script consumer ok (generated real subsystem receipt; evaluator/admission CLI/merge consumer; identity/source/log/coverage/ref/binding negatives; private rehearsal; 0 skipped)');
}finally{fs.rmSync(root,{recursive:true,force:true});}
