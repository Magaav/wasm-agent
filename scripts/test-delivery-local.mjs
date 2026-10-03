import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {terminal,skipped} from './lib/delivery-producer-proof.mjs';
import {evaluate} from './delivery-admission.mjs';
import {runFocused,plan,verifyFocused,verifyProducer} from './producer-admission.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-local-admission-')),repo=path.join(root,'repo');fs.mkdirSync(repo);
function git(cwd,...args){const r=spawnSync('git',['-c','user.name=fixture','-c','user.email=fixture@local',...args],{cwd,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try {
 for(const marker of ['  SKIP coverage','\tSkipped: coverage',' # skip coverage','2 tests skipped']){assert.ok(skipped(marker)>0);assert.equal(terminal('test-delivery-admission.mjs',marker+'\ndelivery admission ok (58 checks)'),false);}
 for(const bad of ['','delivery admission ok (1 checks)','delivery admission ok (58 checks)\ndelivery admission ok (58 checks)','FAIL\ndelivery admission ok (58 checks)'])assert.equal(terminal('test-delivery-admission.mjs',bad),false);
 git(repo,'init','-q','--initial-branch=main');fs.mkdirSync(path.join(repo,'scripts'));fs.mkdirSync(path.join(repo,'tests'));
 for(const f of ['gate-checks.mjs','gate-check.mjs'])fs.copyFileSync(path.resolve('scripts',f),path.join(repo,'scripts',f));
 fs.mkdirSync(path.join(repo,'scripts/lib'));fs.copyFileSync(path.resolve('scripts/lib/test-verdict.cjs'),path.join(repo,'scripts/lib/test-verdict.cjs'));
 fs.writeFileSync(path.join(repo,'lane-policy.json'),JSON.stringify({remote:{main_only:true}}));
 fs.writeFileSync(path.join(repo,'tests/local.js'),"console.log('ALL PASS');\n");git(repo,'add','.');git(repo,'commit','-qm','base');git(repo,'update-ref','refs/remotes/origin/main',git(repo,'rev-parse','HEAD'));
 const producer=path.join(root,'producer'),reviewer=path.join(root,'reviewer');
 git(repo,'worktree','add','-qb','change/wa-session-producer',producer);
 fs.appendFileSync(path.join(producer,'tests/local.js'),'// focused change\n');git(producer,'add','.');git(producer,'commit','-qm','delivery\n\nAgent: fixture session=producer');
 const tip=git(producer,'rev-parse','HEAD'),tree=git(producer,'rev-parse','HEAD^{tree}');
 git(repo,'worktree','add','-qb','change/wa-session-reviewer',reviewer);
 git(reviewer,'commit','--allow-empty','-qm','review exact delivery\n\nAgent: fixture session=reviewer');const anchor=git(reviewer,'rev-parse','HEAD');
 const dbFile=path.join(root,'memory.db'),db=new DatabaseSync(dbFile);db.exec('CREATE TABLE sessions(id TEXT,worktree TEXT,workspace_required INTEGER,workspace_state TEXT,workspace_branch TEXT)');
 for(const [id,dir] of [['producer',producer],['reviewer',reviewer]])db.prepare('INSERT INTO sessions VALUES(?,?,?,?,?)').run(id,dir,1,'allocated',`change/wa-session-${id}`);db.close();
 // Source-level applicability: the real delivery script diff must select its four suites.
 const actual=plan(path.resolve('.'));if(actual.files.some(f=>f==='scripts/delivery-admission.mjs'))assert.deepEqual(actual.checks,['delivery-subsystem']);
 const focused=await runFocused(producer);assert.equal(focused.admission_verified,true,JSON.stringify(focused));
 const record={delivery:'change/wa-session-producer',branch:'change/wa-session-producer',repository:producer,producer:'producer',tip,tree,producer_checks:JSON.parse(fs.readFileSync(focused.receipt)),review:{reviewer:'reviewer',commit:anchor,tip,tree,verdict:'passed',findings:[]}};
 const check=r=>evaluate({repo,record:r,sessionDb:dbFile});
 const store=path.join(root,'records');const {writeRecord}=await import('./lib/delivery-store.mjs');writeRecord(store,record);
 const lane=spawnSync(process.execPath,[path.resolve('scripts/merge-lane.mjs'),'--repo',repo,record.branch,'--delivery-store',store,'--delivery-session-db',dbFile,'--no-reuse-tree','--no-hooks','--gate-mode','none'],{encoding:'utf8'});
 assert.equal(lane.status,0,lane.stderr+lane.stdout);
 assert.equal(JSON.parse(lane.stdout).inputs[0].admission.decision,'admitted');
 // Real tiny tracked smoke execution proves full-receipt consumer contract, not application coverage.
 const crypto=await import('node:crypto');const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
 fs.writeFileSync(path.join(producer,'shared-runtime.txt'),'broad source');fs.writeFileSync(path.join(producer,'scripts/test.sh'),'echo "smoke ok"\n');
 fs.mkdirSync(path.join(producer,'skills/parallel-evolution/scripts'),{recursive:true});fs.writeFileSync(path.join(producer,'skills/parallel-evolution/scripts/finish.mjs'),'// private immutable driver\n');git(producer,'add','.');git(producer,'commit','-qm','broad\n\nAgent: fixture session=producer');
 const broadTip=git(producer,'rev-parse','HEAD'),broadTree=git(producer,'rev-parse','HEAD^{tree}');assert.equal(plan(producer).full_required,true);
 const gate=spawnSync('bash',['scripts/test.sh'],{cwd:producer,encoding:'utf8'});assert.equal(gate.status,0);const log=path.join(root,'full.log');fs.writeFileSync(log,gate.stdout);
 const full={schema:1,kind:'full',repo:producer,head:broadTip,tree:broadTree,passed:true,gate_exit:0,gate_runs:1,gate_ms:1,skipped:0,log,log_sha256:digest(fs.readFileSync(log)),runner:{path:path.join(producer,'skills/parallel-evolution/scripts/finish.mjs'),platform:process.platform,sha256:digest(fs.readFileSync(path.join(producer,'skills/parallel-evolution/scripts/finish.mjs')))},shell:process.platform==='win32'?path.join(process.env.ProgramFiles||'C:/Program Files','Git/bin/bash.exe'):'bash'};
 assert.equal(verifyFocused(producer,full).admission_verified,false);assert.equal(verifyProducer(producer,full).admission_verified,true);
 const broad={...record,tip:broadTip,tree:broadTree,producer_checks:full,review:{...record.review,tip:broadTip,tree:broadTree}};assert.equal(check(broad).decision,'admitted');
 for(const patch of [{repo:root},{repo:repo},{tree:tree},{runner:{...full.runner,path:path.join(producer,'scripts/unknown.mjs')}},{head:tip},{kind:'focused'},{skipped:1},{runner:{...full.runner,platform:'foreign'}},{runner:{...full.runner,sha256:'0'.repeat(64)}},{log_sha256:'0'.repeat(64)}])assert.equal(check({...broad,producer_checks:{...full,...patch}}).decision,'refused');
 // Causal production validation removal: private module copy, unchanged normal source.
 const originalProducer=fs.readFileSync(path.resolve('scripts/producer-admission.mjs'),'utf8'),splice="if(!proof.verified)throw Error(proof.reason);";assert.equal(originalProducer.split(splice).length,2);
 const mutantDir=path.join(root,'mutant');fs.cpSync(path.resolve('scripts'),mutantDir,{recursive:true});fs.writeFileSync(path.join(mutantDir,'producer-admission.mjs'),originalProducer.replace(splice,'// intentionally removed strict proof refusal'));
 const {pathToFileURL}=await import('node:url');const mutant=await import(pathToFileURL(path.join(mutantDir,'producer-admission.mjs')));
 const currentGuard="if(git(repo,'rev-parse','HEAD')!==selection.head||git(repo,'status','--porcelain'))throw Error('producer source moved or dirty');";assert.equal(originalProducer.split(currentGuard).length,2);
 fs.writeFileSync(path.join(mutantDir,'producer-admission.mjs'),originalProducer.replace(currentGuard,'// intentional removed current-source refusal'));
 const mutated=await import(pathToFileURL(path.join(mutantDir,'producer-admission.mjs')).href+'?causal');
 fs.appendFileSync(path.join(producer,'shared-runtime.txt'),'dirty forbidden source');assert.equal(mutated.verifyProducer(producer,full).admission_verified,true);assert.equal(verifyProducer(producer,full).admission_verified,false);git(producer,'checkout','--','shared-runtime.txt');
 assert.equal(fs.readFileSync(path.resolve('scripts/producer-admission.mjs'),'utf8'),originalProducer);
 const {writeRecord:save}=await import('./lib/delivery-store.mjs');const broadStore=path.join(root,'broad-records');delete broad.revision;save(broadStore,broad);
 const admission=spawnSync(process.execPath,[path.resolve('scripts/delivery-admission.mjs'),'admit',broad.branch,'--repo',repo,'--store',broadStore,'--session-db',dbFile,'--by','integrator'],{encoding:'utf8'});assert.equal(admission.status,0,admission.stderr);
 const merged=spawnSync(process.execPath,[path.resolve('scripts/merge-lane.mjs'),'--repo',repo,broad.branch,'--delivery-store',broadStore,'--delivery-session-db',dbFile,'--no-reuse-tree','--no-hooks','--gate-mode','none'],{encoding:'utf8'});assert.equal(merged.status,0,merged.stdout+merged.stderr);
 // Retain independently frozen tested source into the managed producer's rightful custody.
 const {retainFullProof}=await import('./lib/full-gate-proof.mjs');const frozen=path.join(root,'frozen');git(root,'clone','-q','--no-hardlinks',producer,frozen);git(frozen,'checkout','--detach','-q',broadTip);
 const frozenGate=spawnSync('bash',['scripts/test.sh'],{cwd:frozen,encoding:'utf8'});assert.equal(frozenGate.status,0);const frozenLog=path.join(root,'frozen.log');fs.writeFileSync(frozenLog,frozenGate.stdout);
 const frozenReceipt={...full,repo:frozen,log:frozenLog,log_sha256:digest(fs.readFileSync(frozenLog)),runner:{...full.runner,path:path.join(frozen,'skills/parallel-evolution/scripts/finish.mjs')}};
 const rawPath=path.join(root,'frozen-receipt.json');fs.writeFileSync(rawPath,JSON.stringify(frozenReceipt));const retained=retainFullProof(rawPath,producer,{candidateHead:broadTip});
 assert.equal(verifyProducer(producer,retained,broadTip).admission_verified,true);assert.equal(check({...broad,producer_checks:retained}).decision,'admitted');
 const {readRecord}=await import('./lib/delivery-store.mjs');const retainedRecord=readRecord(broadStore,broad.branch);retainedRecord.producer_checks=retained;save(broadStore,retainedRecord);
 const retainedCli=spawnSync(process.execPath,[path.resolve('scripts/delivery-admission.mjs'),'admit',broad.branch,'--repo',repo,'--store',broadStore,'--session-db',dbFile,'--by','integrator'],{encoding:'utf8'});assert.equal(retainedCli.status,0,retainedCli.stderr);
 const retainedMerge=spawnSync(process.execPath,[path.resolve('scripts/merge-lane.mjs'),'--repo',repo,broad.branch,'--delivery-store',broadStore,'--delivery-session-db',dbFile,'--no-reuse-tree','--no-hooks','--gate-mode','none'],{encoding:'utf8'});assert.equal(retainedMerge.status,0,retainedMerge.stdout+retainedMerge.stderr);
 for(const patch of [{owner_repo:null},{candidate_head:null},{source_receipt:null},{scope:null},{kind:'partial'},{candidate_head:tip},{owner_repo:frozen},{source_receipt:{...retained.source_receipt,sha256:'0'.repeat(64)}},{scope:{...retained.scope,sha256:'0'.repeat(64)}},{runner:full.runner}])assert.equal(check({...broad,producer_checks:{...retained,...patch}}).decision,'refused');
 // Preserve originals while corrupting an actual retained capsule and raw terminal log.
 const capsuleBytes=fs.readFileSync(retained.scope.path);fs.appendFileSync(retained.scope.path,'corrupt');assert.equal(check({...broad,producer_checks:retained}).decision,'refused');fs.writeFileSync(retained.scope.path,capsuleBytes);
 const rawLogBytes=fs.readFileSync(log);for(const text of ['not smoke\n','smoke ok (1 skipped)\n','smoke ok\nFAIL\n']){fs.writeFileSync(log,text);assert.equal(check({...broad,producer_checks:{...full,log_sha256:digest(fs.readFileSync(log))}}).decision,'refused');}fs.writeFileSync(log,rawLogBytes);
 assert.equal(check({...broad,producer_checks:retained}).decision,'admitted');
 git(producer,'commit','--allow-empty','-qm','same tree alias\n\nAgent: fixture session=producer');const alias=git(producer,'rev-parse','HEAD');assert.equal(verifyProducer(producer,{...retained,candidate_head:alias},alias).admission_verified,false);
 git(producer,'reset','--hard',tip);
 assert.equal(check(record).decision,'admitted');assert.equal(check(record).observed.source,'managed_local_unpublished');
 for(const change of [{review:null},{producer_checks:null},{tree:'0'.repeat(40)},{review:{...record.review,verdict:'refused'}},{review:{...record.review,reviewer:'producer'}},{review:{...record.review,tip:anchor}}])assert.equal(check({...record,...change}).decision,'refused');
 git(reviewer,'commit','--allow-empty','-qm','wrong provenance\n\nAgent: fixture session=foreign');assert.equal(check({...record,review:{...record.review,commit:git(reviewer,'rev-parse','HEAD')}}).decision,'refused');
 assert.equal(check(record).decision,'refused');
 console.log('local delivery admission ok (canonical consumer, exact tip/tree, real focused receipt, missing/refused/self review, moved anchor, provenance; 0 skipped)');
} finally {fs.rmSync(root,{recursive:true,force:true});}
