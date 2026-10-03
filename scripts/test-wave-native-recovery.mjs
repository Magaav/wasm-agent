// Actual production consumer functions, private fixture authority only. No live
// registration, source authority, historical closure or remote publication grant.
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';import {once} from 'node:events';import {DatabaseSync} from 'node:sqlite';
import {runFocused} from './producer-admission.mjs';import {digest,recoverySnapshot} from './lib/wave-recovery.mjs';import {landRecovery} from './wave-recovery-land.mjs';import {connectNativeRecovery} from './lib/wave-recovery-native.mjs';
const actual=path.resolve(import.meta.dirname,'..'),binary=path.resolve(process.argv[2]),root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-native-wave-'));
const suppliedBuildLog=path.resolve(process.argv[3]||path.join(os.tmpdir(),'wa-native-recovery-build.log'));
const buildLog=path.join(root,'actual-build.log');fs.copyFileSync(suppliedBuildLog,buildLog);
const buildCommand=process.argv.find(a=>a.startsWith('--build-command='))?.slice('--build-command='.length)||'cargo build --offline --manifest-path rust/Cargo.toml -p wa-host';let checks=0;const children=[];
const check=(value,label)=>{assert.ok(value,label);checks++;};
const git=(repo,...args)=>{const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true,maxBuffer:128*1024*1024});assert.equal(r.status,0,r.stderr||String(r.error));return r.stdout.trim();};
const write=(file,value)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,typeof value==='string'?value:JSON.stringify(value,null,2)+'\n');};
const commit=(repo,who)=>{git(repo,'add','.');git(repo,'commit','--allow-empty','-qm',`private fixture\n\nAgent: wasm-agent session=${who}`);return git(repo,'rev-parse','HEAD');};
const tool=name=>{if(name==='node')return fs.realpathSync(process.execPath);const r=spawnSync(process.platform==='win32'?'where.exe':'which',[name],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return fs.realpathSync(r.stdout.trim().split(/\r?\n/)[0]);};
const seed=path.join(root,'seed');fs.mkdirSync(seed);git(seed,'init','-q','-b','main');git(seed,'config','user.name','Fixture');git(seed,'config','user.email','fixture@invalid');git(seed,'config','core.autocrlf','false');
const names=git(actual,'ls-files','--cached','--others','--exclude-standard').split('\n').filter(Boolean);
for(const name of names){const from=path.join(actual,name);if(!fs.statSync(from).isFile())continue;fs.mkdirSync(path.dirname(path.join(seed,name)),{recursive:true});fs.copyFileSync(from,path.join(seed,name));}
write(path.join(seed,'tests/native-repair-fixture.js'),"console.log('ALL PASS');\n");commit(seed,'fixture-base');
const mutant=process.argv.includes('--mutant-owner');
if(mutant){const file=path.join(seed,'scripts/lib/wave-recovery.mjs'),before=fs.readFileSync(file,'utf8'),after=before.replace(/need\(source&&native\.receipt\?\.principal[^\n]+,'current_native_owner_binding'\);/,'/* causal mutant: remove native owner binding */');assert.notEqual(after,before,'exact production check found');write(file,after);commit(seed,'fixture-mutant-source');}
async function fixture(label,{foreign=false,used=false,dirty=false,snapshot=false,missing=false,external=false}={}){
 const home=path.join(root,label),repo=path.join(home,'canonical'),source=path.join(home,'producer'),reviewRoot=path.join(home,'reviewer'),meta=path.join(home,'operator');fs.mkdirSync(home);
 git(root,'clone','--quiet','--no-hardlinks',seed,repo);git(repo,'config','user.name','Fixture');git(repo,'config','user.email','fixture@invalid');git(repo,'config','core.autocrlf','false');
 const main=git(repo,'rev-parse','HEAD'),remote=path.join(home,'remote.git');git(home,'init','--bare','-q',remote);git(repo,'remote','set-url','origin',remote);git(repo,'push','-q','origin','main');git(repo,'update-ref','refs/remotes/origin/main',main);
 const producerBranch=external?'change/external-source-fixture':'change/wa-session-fixture-producer',reviewerBranch=external?'change/external-review-fixture':'change/wa-session-fixture-reviewer';
 git(repo,'worktree','add','-q','-b',producerBranch,source,main);
 fs.appendFileSync(path.join(source,'tests/native-repair-fixture.js'),'// narrow actual producer fixture\n');const tip=commit(source,'fixture-producer'),tree=git(repo,'rev-parse',tip+'^{tree}');
 // Git's ps1 checkout filter uses CRLF; the reviewed execution root deliberately
 // materializes exact immutable blob bytes without changing repository settings.
 const sourceNames=git(repo,'ls-tree','-r','--name-only',tip).split('\n').filter(Boolean).sort();
 const batch=spawnSync('git',['-C',repo,'cat-file','--batch'],{input:sourceNames.map(p=>`${tip}:${p}\n`).join(''),windowsHide:true,maxBuffer:128*1024*1024});assert.equal(batch.status,0,batch.stderr);let position=0;
 for(const name of sourceNames){const end=batch.stdout.indexOf(10,position),match=/^[a-f0-9]{40} blob (\d+)$/.exec(batch.stdout.subarray(position,end).toString());assert.ok(match);const length=Number(match[1]);fs.writeFileSync(path.join(source,name),batch.stdout.subarray(end+1,end+1+length));position=end+length+2;}
 git(source,'add','-u');assert.equal(git(source,'write-tree'),tree,'exact blob materialization preserves the source tree');
 const proof=await runFocused(source,{jobs:2});check(proof.admission_verified,'actual narrow producer source evidence');
 git(repo,'worktree','add','-q','-b',reviewerBranch,reviewRoot,tip);git(repo,'worktree','add','-q','-b','recovery/operator',meta,tip);
 fs.mkdirSync(path.join(home,'.wasm-agent'),{recursive:true});
 const sessions=path.join(home,'sessions.sqlite'),bindings=new DatabaseSync(sessions);
 bindings.exec('CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT,workspace_required INTEGER,workspace_state TEXT,workspace_branch TEXT)');
 if(!external)for(const [session,worktree] of [['fixture-producer',source],['fixture-reviewer',reviewRoot]])bindings.prepare('INSERT INTO sessions VALUES(?,?,?,?,?)').run(session,worktree,1,'allocated','change/wa-session-'+session);bindings.close();
 const common=git(repo,'rev-parse','--path-format=absolute','--git-common-dir'),store=path.join(common,'wa-waves');fs.mkdirSync(store);
 const historical=path.join(home,'historical-facts.json');write(historical,{kind:'private-historical-fact-only',actor:'old-label',reviewer:'declared-old-reviewer-is-not-current-approval'});
 const config=path.join(home,'config.json');write(config,{repo,data:path.join(home,'.wasm-agent'),source_root:source});
 write(path.join(store,'registration.json'),{schema:1,repo:fs.realpathSync(repo),owner:'old-owner-label',config,source_root:source,attestation:historical,attestation_sha256:digest(fs.readFileSync(historical))});
 const db=new DatabaseSync(path.join(store,'waves.sqlite'));db.exec('CREATE TABLE waves(id TEXT,repo TEXT,manifest TEXT,manifest_hash TEXT,state TEXT,reason TEXT,owner TEXT,boot TEXT,pid INTEGER,created_at INTEGER,updated_at INTEGER,receipt TEXT,legacy TEXT);CREATE TABLE steps(wave TEXT,position INTEGER);CREATE TABLE events(wave TEXT,sequence INTEGER)');
 db.prepare('INSERT INTO waves VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)').run('wave',repo,JSON.stringify({repo}),'manifest','pending',null,'old-owner-label',null,null,1,1,null,JSON.stringify({schema:1,kind:'derived-activity-migration',wave_id:'wave'}));db.close();
 const snap=recoverySnapshot(store,'wave'),files=git(repo,'ls-tree','-r','--name-only',tip).split('\n').filter(Boolean).sort().map(p=>({path:p,sha256:digest(fs.readFileSync(path.join(source,p)))}));
 const nativeInputs=files.filter(f=>f.path.startsWith('rust/')||f.path.startsWith('lua/'));
 for(const f of nativeInputs)assert.equal(digest(fs.readFileSync(path.join(actual,f.path))),f.sha256,'actual source-built native inputs match fixture');
 write(path.join(meta,'native-build.json'),{kind:'wave-native-build',authority:'private-fixture',source_tip:tip,source_tree:tree,binary_sha256:digest(fs.readFileSync(binary)),native_inputs:nativeInputs,exit:0,command:buildCommand,log:{path:buildLog,sha256:digest(fs.readFileSync(buildLog))},actual_builder_root:actual});
 const buildCommit=commit(meta,'fixture-builder');
 const runtime={native:{path:binary,sha256:digest(fs.readFileSync(binary)),build_commit:buildCommit,build_path:'native-build.json'},node:{path:tool('node'),sha256:digest(fs.readFileSync(tool('node')))},git:{path:tool('git'),sha256:digest(fs.readFileSync(tool('git')))},driver:'scripts/wave-recovery-driver.lua',consumer:'scripts/wave-recovery-bootstrap.mjs',effects:['canonical-local-main-cas']};
 if(process.platform==='win32')runtime.observer={path:tool('powershell.exe'),sha256:digest(fs.readFileSync(tool('powershell.exe')))};
 const mapping={schema:2,kind:'wave-current-issuer-binding',wave:'wave',owner_label:'old-owner-label',issuer_session:'fixture-operator',registration_sha256:snap.registration,
  effect:'canonical-local-main-cas',repo:fs.realpathSync(repo),ref:'refs/heads/main',origin_url:remote,native_principal:foreign?'foreign':'fixture-native-user',native_session:'fixture-native-session',resource_data:path.join(home,'.wasm-agent'),authority:'private-fixture',private_session_db:sessions,source_tip:tip,source_tree:tree,historical_facts:[{path:historical,sha256:digest(fs.readFileSync(historical))}]};
 write(path.join(meta,'current-issuer.json'),mapping);const mappingCommit=commit(meta,'fixture-operator');
 write(path.join(reviewRoot,'evidence.json'),JSON.parse(fs.readFileSync(proof.receipt)));
 // The prior artifact is explicitly a private fact; fresh native inventory is
 // mandatory and supplies all execution owner/exclusion authority at effect time.
 const artifact=path.join(home,'target-fact.json');write(artifact,{kind:'private-empty-runtime-before-admission',production:false});
 write(path.join(reviewRoot,'target.json'),{schema:1,kind:'recovery-target-inspection',main,action:'land',tip,target:fs.realpathSync(repo),reviewer:'fixture-reviewer',conflicts:'none',artifacts:[{path:artifact,sha256:digest(fs.readFileSync(artifact))}]});
 write(path.join(reviewRoot,'review.json'),{tip,tree,producer:'fixture-producer',reviewer:'fixture-reviewer',scope:'full-delivery',verdict:'passed',findings:[],authority:'private-fixture'});
 write(path.join(reviewRoot,'source-review.json'),{schema:2,kind:'wave-source-review',tip,tree,producer:'fixture-producer',reviewer:'fixture-reviewer',verdict:'passed',files,runtime,authority:'private-fixture'});
 write(path.join(reviewRoot,'current-issuer-review.json'),{schema:2,kind:'wave-current-issuer-binding-review',descriptor_commit:mappingCommit,descriptor_path:'current-issuer.json',descriptor_sha256:digest(git(repo,'show',mappingCommit+':current-issuer.json')),reviewer:'fixture-reviewer',verdict:'passed',authority:'private-fixture'});
 const reviewCommit=commit(reviewRoot,'fixture-reviewer'),entry={branch:producerBranch,tip,tree,action:'land',nonce:digest(label).slice(0,32),producer:'fixture-producer',reviewer:'fixture-reviewer',review_commit:reviewCommit,review_path:'review.json',target_path:'target.json',evidence_commit:reviewCommit,evidence_path:'evidence.json'};
 // External author custody is a separate CURRENT operator act. It makes no
 // synthetic sessions row and requires exact fresh Git/source/evidence facts.
 let issuerBinding={commit:mappingCommit,path:'current-issuer.json',review_commit:reviewCommit,review_path:'current-issuer-review.json'};
 if(external){
  const facts=path.join(home,'external-ownership-facts.json');write(facts,{kind:'private-current-ownership-observation',producer:{worktree:source,branch:producerBranch,tip},reviewer:{worktree:reviewRoot,branch:reviewerBranch,tip:reviewCommit}});
  mapping.external_custody={kind:'current-operator-external-custody',producer:{session:'fixture-producer',worktree:source,branch:producerBranch,tip,tree},reviewer:{session:'fixture-reviewer',worktree:reviewRoot,branch:reviewerBranch,tip:reviewCommit,tree:git(repo,'rev-parse',reviewCommit+'^{tree}')},evidence:[{path:facts,sha256:digest(fs.readFileSync(facts))}]};
  write(path.join(meta,'current-issuer.json'),mapping);const current=commit(meta,'fixture-operator');
  write(path.join(meta,'current-issuer-review.json'),{schema:2,kind:'wave-current-issuer-binding-review',descriptor_commit:current,descriptor_path:'current-issuer.json',descriptor_sha256:digest(git(repo,'show',current+':current-issuer.json')),reviewer:'fixture-mapping-reviewer',verdict:'passed',authority:'private-fixture'});
  const accepted=commit(meta,'fixture-mapping-reviewer');issuerBinding={commit:current,path:'current-issuer.json',review_commit:accepted,review_path:'current-issuer-review.json'};
 }
 const ticket={schema:2,kind:'wave-recovery-admission',repo:fs.realpathSync(repo),wave:'wave',owner:'old-owner-label',current_issuer_binding:missing?null:issuerBinding,snapshot:snap.snapshot,registration:snap.registration,manifest:snap.row.manifest_hash,legacy:digest(snap.row.legacy),expected_main:main,expires:Date.now()+3600000,entries:[entry]};
 write(path.join(meta,'recovery/ticket.json'),ticket);const ticketCommit=commit(meta,'fixture-operator'),raw=git(repo,'show',ticketCommit+':recovery/ticket.json');
 const receiptFile=path.join(home,'ticket-envelope.json');write(receiptFile,{commit:ticketCommit,path:'recovery/ticket.json',sha256:digest(raw)});
 write(path.join(home,'source.json'),{schema:2,kind:'wave-reviewed-source',root:source,tip,tree,files,runtime,authority:'private-fixture',review_commit:reviewCommit,review_path:'source-review.json'});
 write(path.join(home,'context.json'),{phase:'land',recovery:{receipt_file:receiptFile,delivery:entry.branch,tip,tree,review_commit:reviewCommit,reviewer:'fixture-reviewer',expected_main:main}});
 if(used){const consumed=new DatabaseSync(path.join(store,'recovery-consumption.sqlite'));consumed.exec('CREATE TABLE consumed(nonce TEXT PRIMARY KEY,binding TEXT,state TEXT)');consumed.prepare('INSERT INTO consumed VALUES(?,?,?)').run(entry.nonce,'retained original','uncertain');consumed.close();}
 if(dirty)write(path.join(repo,'concurrent.txt'),'preserve me\n');
 if(snapshot){const changed=new DatabaseSync(path.join(store,'waves.sqlite'));changed.prepare('UPDATE waves SET reason=?').run('changed snapshot');changed.close();}
 return {home,repo,source,reviewRoot,meta,main,tip,tree,store,entry,snap,remote,ticket,runtime};
}
function launch(f,pause=null){const env={...process.env};for(const key of Object.keys(env))if(/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key))delete env[key];
 Object.assign(env,{WASM_AGENT_HOME:f.home,WASM_AGENT_LUA_ROOT:f.source,WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',WA_SCRIPT:path.join(f.source,'scripts/test-wave-native-recovery.lua'),WA_RECOVERY_FIXTURE:f.home,WA_RECOVERY_REPO:f.repo,WA_RECOVERY_PAUSE_SEQUENCE:pause===null?'':String(pause)});
 const log=fs.openSync(path.join(f.home,'native.log'),'w'),p=spawn(binary,['--db',path.join(f.home,'native.db')],{cwd:f.source,env,stdio:['ignore',log,log],windowsHide:true});fs.closeSync(log);children.push(p);return p;}
async function result(f,p){if(p.exitCode===null)await once(p,'exit');assert.equal(p.exitCode,0,fs.readFileSync(path.join(f.home,'native.log'),'utf8'));return JSON.parse(fs.readFileSync(path.join(f.home,'native-result.json')));}
async function paused(f){for(let n=0;n<1000;n++){try{return JSON.parse(fs.readFileSync(path.join(f.home,'paused.json')));}catch{}if(fs.existsSync(path.join(f.home,'native-result.json')))throw Error('native exited before pause: '+fs.readFileSync(path.join(f.home,'native-result.json'),'utf8'));await new Promise(r=>setTimeout(r,20));}throw Error('native pause missing: '+f.home);}
try{
 if(mutant){const f=await fixture('causal-foreign',{foreign:true}),r=await result(f,launch(f));check(!r.ok,'REMOVED PRODUCTION OWNER CHECK MUST STILL REJECT: '+r.ok);throw Error('causal mutant unexpectedly rejected');}
 const positive=await fixture('positive');const p=launch(positive);const success=await result(positive,p);
 check(success.ok,'actual native source-only recovery positive: '+JSON.stringify(success));
 check(success.native_settled&&success.native_released&&success.native_child.parent_process_id===success.native_receipt.process_id,'actual native parent/child creation and settlement');
 check(success.source.schema===2&&success.source.authority==='private-fixture'&&success.custody.producer.source.kind==='private-fixture','source and custody truthfully private');
 check(success.canonical_readback.clean&&git(positive.repo,'rev-parse','main')===success.landing&&git(positive.repo,'status','--porcelain')==='','canonical CAS and actual worktree readback');
 check(success.wave_verified===false&&success.convergence==='legacy-unverified'&&success.original_refusal.startsWith('wave_convergence_unverified'),'unknown wave and original refusal preserved');
 check(git(positive.repo,'ls-remote','--heads','origin')===positive.main+'\trefs/heads/main'&&success.remote.published===false,'remote is observed, not relabeled as publication');
 write(path.join(root,'positive.json'),success);
 if(!process.argv.includes('--positive-only')){
  const external=await fixture('external-custody',{external:true}),externalResult=await result(external,launch(external));check(externalResult.ok,'current external custody can land exact reviewed author source');check(externalResult.custody.producer.kind==='external-author-tree','external custody is not relabeled native');const bindings=new DatabaseSync(path.join(external.home,'sessions.sqlite'),{readOnly:true});check(bindings.prepare('SELECT count(*) AS n FROM sessions').get().n===0,'external author acceptance never manufactures native bindings');bindings.close();
  for(const [name,options,reason] of [['foreign',{foreign:true},'native_owner_binding'],['missing',{missing:true},'current_issuer_binding'],['dirty',{dirty:true},'clean_canonical'],['snapshot',{snapshot:true},'snapshot_moved'],['nonce',{used:true},'already_consumed']]){
   const f=await fixture(name,options),child=launch(f),r=await result(f,child);check(!r.ok&&JSON.stringify(r).includes(reason),name+' refuses: '+JSON.stringify(r));check(git(f.repo,'rev-parse','main')===f.main,name+' leaves main unchanged');
   if(name==='dirty')check(fs.readFileSync(path.join(f.repo,'concurrent.txt'),'utf8')==='preserve me\n','dirty bytes preserved');
  }
  for(const name of ['replaced','uncertain','incomplete','scope']){
   const f=await fixture(name),child=launch(f,5),facts=await paused(f),db=new DatabaseSync(path.join(f.home,'.wasm-agent/resources/claims.sqlite'));
   if(name==='incomplete')db.exec('DROP TABLE claim_identity');
   else if(name==='uncertain')db.prepare('UPDATE claims SET uncertain=1 WHERE key=?').run(facts.receipt.key);
   else {const old=db.prepare('SELECT identity FROM claim_identity WHERE key=?').get(facts.receipt.key),identity=JSON.parse(old.identity);if(name==='scope')identity.scope.ref='refs/heads/foreign';else identity.process_id=1;db.prepare('UPDATE claim_identity SET identity=? WHERE key=?').run(JSON.stringify(identity),facts.receipt.key);}
   db.close();write(path.join(f.home,'continue'),'go');const r=await result(f,child);check(!r.ok,name+' native effect refused');check(git(f.repo,'rev-parse','main')===f.main,name+' preserved main');
   const consumed=new DatabaseSync(path.join(f.store,'recovery-consumption.sqlite'),{readOnly:true});check(consumed.prepare('SELECT state FROM consumed WHERE nonce=?').get(f.entry.nonce).state==='uncertain',name+' nonce remains uncertain');consumed.close();
  }
  for(const name of ['source','ref','remote','channel']){
   const f=await fixture(name);
   if(name==='source')fs.appendFileSync(path.join(f.source,'scripts/wave-recovery-driver.lua'),'\n-- changed execution bytes\n');
   if(name==='ref')git(f.repo,'update-ref','refs/heads/main',f.tip,f.main);
   if(name==='remote')git(f.repo,'remote','set-url','origin',path.join(f.home,'foreign.git'));
   if(name==='channel'){const held=path.join(f.home,'forged');write(held+'.parent.json',{schema:1,kind:'native-recovery-channel',nonce:'f'.repeat(64),receipt:success.native_receipt,runtime:{process_id:success.native_receipt.process_id}});assert.throws(()=>connectNativeRecovery(held,f.repo,JSON.parse(fs.readFileSync(path.join(f.home,'source.json')))),/parent_mismatch/);checks++;continue;}
   const r=await result(f,launch(f));check(!r.ok,name+' refuses');check(git(f.repo,'rev-parse','main')===(name==='ref'?f.tip:f.main),name+' does not move the selected ref');
  }
  assert.throws(()=>landRecovery(positive.repo,{},success.native_receipt),/control_required/);checks++;
  const held=await fixture('publication-held'),lease=new DatabaseSync(path.join(held.store,'recovery-target-lease.sqlite'));
  lease.exec('CREATE TABLE lease(id INTEGER PRIMARY KEY,identity TEXT);BEGIN IMMEDIATE');
  try{const r=await result(held,launch(held));check(!r.ok&&JSON.stringify(r).includes('target_lease_held'),'OS publication lease contention refuses');check(git(held.repo,'rev-parse','main')===held.main,'publication contention preserves main');}finally{lease.exec('ROLLBACK');lease.close();}
  const late=await fixture('concurrent-dirty'),lateChild=launch(late,5);await paused(late);write(path.join(late.repo,'tests/native-repair-fixture.js'),'concurrent dirty content\n');write(path.join(late.home,'continue'),'go');
  const lateResult=await result(late,lateChild);check(!lateResult.ok,'dirty state after reservation refuses');check(git(late.repo,'rev-parse','main')===late.main&&fs.readFileSync(path.join(late.repo,'tests/native-repair-fixture.js'),'utf8')==='concurrent dirty content\n','reserved concurrent dirty bytes and ref preserved');
  const crash=await fixture('crash'),crashed=launch(crash,5),crashFacts=await paused(crash),claims=new DatabaseSync(path.join(crash.home,'.wasm-agent/resources/claims.sqlite'),{readOnly:true});
  const original=claims.prepare('SELECT * FROM claims WHERE key=?').get(crashFacts.receipt.key);claims.close();
  const exited=once(crashed,'exit');crashed.kill('SIGKILL');await exited;
  check(git(crash.repo,'rev-parse','main')===crash.main,'parent crash before effect preserves exact main');
  const restarted=await result(crash,launch(crash));check(!restarted.ok,'fresh native process cannot adopt crashed target');
  const after=new DatabaseSync(path.join(crash.home,'.wasm-agent/resources/claims.sqlite'),{readOnly:true});assert.deepEqual(after.prepare('SELECT * FROM claims WHERE key=?').get(crashFacts.receipt.key),original);after.close();checks++;
  const marker=new DatabaseSync(path.join(crash.store,'recovery-consumption.sqlite'),{readOnly:true});check(marker.prepare('SELECT state FROM consumed WHERE nonce=?').get(crash.entry.nonce).state==='uncertain','crash and restart never replay uncertain nonce');marker.close();
 }
 const report={kind:'private-actual-native-recovery-consumer',checks,skipped:0,binary_sha256:digest(fs.readFileSync(binary)),source:actual,positive:positive.home,production_authority:false,remote_publication:false};write(path.join(root,'report.json'),report);
 console.log(`native wave recovery ok (${checks} checks, 0 skipped; source-root native parent, actual private canonical Git/store/effect)`);
}catch(error){console.error(error.stack);process.exitCode=1;}finally{for(const child of children)if(child.exitCode===null&&child.signalCode===null){const exit=once(child,'exit');child.kill();await exit;}console.log('evidence: '+root);}
