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
 for(const patch of [{head:tip},{kind:'focused'},{skipped:1},{runner:{...full.runner,platform:'foreign'}},{runner:{...full.runner,sha256:'0'.repeat(64)}},{log_sha256:'0'.repeat(64)}])assert.equal(check({...broad,producer_checks:{...full,...patch}}).decision,'refused');
 const {writeRecord:save}=await import('./lib/delivery-store.mjs');const broadStore=path.join(root,'broad-records');delete broad.revision;save(broadStore,broad);
 const admission=spawnSync(process.execPath,[path.resolve('scripts/delivery-admission.mjs'),'admit',broad.branch,'--repo',repo,'--store',broadStore,'--session-db',dbFile,'--by','integrator'],{encoding:'utf8'});assert.equal(admission.status,0,admission.stderr);
 const merged=spawnSync(process.execPath,[path.resolve('scripts/merge-lane.mjs'),'--repo',repo,broad.branch,'--delivery-store',broadStore,'--delivery-session-db',dbFile,'--no-reuse-tree','--no-hooks','--gate-mode','none'],{encoding:'utf8'});assert.equal(merged.status,0,merged.stdout+merged.stderr);
 git(producer,'reset','--hard',tip);
 assert.equal(check(record).decision,'admitted');assert.equal(check(record).observed.source,'managed_local_unpublished');
 for(const change of [{review:null},{producer_checks:null},{tree:'0'.repeat(40)},{review:{...record.review,verdict:'refused'}},{review:{...record.review,reviewer:'producer'}},{review:{...record.review,tip:anchor}}])assert.equal(check({...record,...change}).decision,'refused');
 git(reviewer,'commit','--allow-empty','-qm','wrong provenance\n\nAgent: fixture session=foreign');assert.equal(check({...record,review:{...record.review,commit:git(reviewer,'rev-parse','HEAD')}}).decision,'refused');
 assert.equal(check(record).decision,'refused');
 console.log('local delivery admission ok (canonical consumer, exact tip/tree, real focused receipt, missing/refused/self review, moved anchor, provenance; 0 skipped)');
} finally {fs.rmSync(root,{recursive:true,force:true});}
