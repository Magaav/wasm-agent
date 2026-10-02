import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
import {verifyDelivered} from './lib/wave-delivery.mjs';import {positiveInFlightAgent,positiveResolvedBinding} from './lib/wave-owners.mjs';import {fullProof,findFullProof,retainFullProof} from './lib/full-gate-proof.mjs';import crypto from 'node:crypto';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-proof-real-'));let checks=0,passed=false;
const git=(...args)=>{const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
const check=(value,label)=>{assert.ok(value,label);checks++;};
try{
 git('init','-q','-b','main');git('config','user.name','fixture');git('config','user.email','fixture@invalid');fs.writeFileSync(path.join(root,'seed'),'base');git('add','.');git('commit','-qm','base');const base=git('rev-parse','HEAD');
 git('switch','-qc','change/fixture');fs.writeFileSync(path.join(root,'value'),'valuable');git('add','.');git('commit','-qm','tip');const tip=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}');
 const review=git('commit-tree',tree,'-p',tip,'-m','Independent review\n\nAgent: codex session=reviewer');git('update-ref','refs/remotes/origin/review',review);git('switch','-q','main');git('merge','-q','--no-ff','change/fixture','-m','landing');const main=git('rev-parse','HEAD');
 const record={delivery:'change/fixture',branch:'change/fixture',producer:'producer',tip,tree,review:{tip,tree,reviewer:'reviewer',commit:review,verdict:'passed',findings:[]},admission:{by:'admitter',tip,tree,state:'admitted'},landing:{sha:main}};
 check(verifyDelivered(root,record,main).ok,'real immutable review/admission/landing prove delivery');git('branch','-d','change/fixture');check(verifyDelivered(root,record,main).ok,'delivery proof survives retirement of branch');
 for(const bad of [{...record,review:{...record.review,tip:base}},{...record,review:{...record.review,tree:'f'.repeat(40)}},{...record,admission:{...record.admission,by:'producer'}},{...record,admission:{...record.admission,tip:base}}])check(!verifyDelivered(root,bad,main).ok,'stale or self-authorized delivery proof rejected');
 const unmerged=git('commit-tree',tree,'-p',tip,'-m','unlanded');check(!verifyDelivered(root,{...record,tip:unmerged,review:{...record.review,tip:unmerged},admission:{...record.admission,tip:unmerged}},main).ok,'unmerged tip cannot borrow landing.sha main');
 // OUR OWN OWNERSHIP IDENTITY. These are the node-runtime facts the wave proofs read instead of
 // a third-party card: a session's own turn, and a binding that is really reconciled.
 const agent={session:'s-1',worktree:'C:/data/wa-worktree-s-1',state:'allocated',in_flight:true,turn:{run_id:'r-1',boot:'b-1',state:'active',updated_at:1}};
 check(positiveInFlightAgent(agent),'a positively identified in-flight agent is what makes a wave ON');
 check(!positiveInFlightAgent({...agent,in_flight:false}),'a session that is not in flight is not activity');
 check(!positiveInFlightAgent({...agent,turn:{...agent.turn,state:'settled'}}),'a settled turn is not a running agent');
 check(!positiveInFlightAgent({...agent,turn:{...agent.turn,run_id:''}}),'an agent that cannot name its run is not a matching identity');
 check(!positiveInFlightAgent({...agent,turn:{...agent.turn,boot:''}}),'an agent that cannot name its boot is not a matching identity');
 check(!positiveInFlightAgent({...agent,turn:{...agent.turn,updated_at:undefined}}),'an agent with no turn stamp cannot authorize a freeze');
 check(!positiveInFlightAgent({...agent,worktree:''}),'an agent with no tree cannot authorize a freeze');
 check(!positiveInFlightAgent({...agent,session:''}),'an agent with no session identity cannot authorize a freeze');
 check(positiveResolvedBinding({state:'released',registered:false}),'a released binding with no tree left is settled');
 check(!positiveResolvedBinding({state:'released',registered:true}),'a released binding whose tree is still registered is not settled');
 check(positiveResolvedBinding({state:'parked',registered:true,detached:true,branch:'',recorded_branch:''}),'a parked detached exact tip is settled');
 check(!positiveResolvedBinding({state:'parked',registered:true,detached:false,branch:'change/x'}),'a parked binding still on a branch is not settled');
 check(!positiveResolvedBinding({state:'parked',registered:false,detached:true}),'a parked binding with no tree is not settled');
 check(!positiveResolvedBinding({state:'allocated',registered:true,detached:false}),'an allocated binding is not settled');
 check(!positiveResolvedBinding({state:'release_unknown',registered:true}),'an unresolved transition is never settled');
 // Real committed source + a real tracked gate runner, actually executed, then
 // retained so its execution identity survives retirement; never a fake removed clone.
 const gitIn=(repo,...args)=>{const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
 const initRepo=repo=>{fs.mkdirSync(repo,{recursive:true});gitIn(repo,'init','-q','--initial-branch','main');gitIn(repo,'config','user.name','proof');gitIn(repo,'config','user.email','proof@invalid');};
 const source=path.join(root,'actual-source'),owner=path.join(root,'owner');initRepo(source);initRepo(owner);
 fs.mkdirSync(path.join(source,'scripts'),{recursive:true});fs.mkdirSync(path.join(source,'skills/parallel-evolution/scripts'),{recursive:true});
 const runnerRel='skills/parallel-evolution/scripts/finish.mjs';
 fs.copyFileSync(new URL('../skills/parallel-evolution/scripts/finish.mjs',import.meta.url),path.join(source,runnerRel));
 fs.writeFileSync(path.join(source,'scripts/test.sh'),'#!/bin/sh\nprintf "fixture assertion passed\\nsmoke ok (2 skipped)\\n"\n');
 gitIn(source,'add','.');gitIn(source,'commit','-qm','real fixture source');
 const proofHead=gitIn(source,'rev-parse','HEAD'),proofTree=gitIn(source,'rev-parse','HEAD^{tree}');
 const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
 const shell=process.platform==='win32'?path.join(process.env.ProgramFiles||'C:/Program Files','Git','bin','bash.exe'):'bash';
 const executed=spawnSync(shell,['scripts/test.sh'],{cwd:source,windowsHide:true});assert.equal(executed.status,0,executed.stderr);
 const log=path.join(root,'gate.log');fs.writeFileSync(log,executed.stdout);
 const receipt={schema:1,kind:'full',repo:source,head:proofHead,tree:proofTree,gate_exit:0,gate_runs:1,gate_ms:1,passed:true,skipped:2,log,log_sha256:sha(executed.stdout),shell,
  runner:{path:path.join(source,runnerRel),sha256:sha(fs.readFileSync(path.join(source,runnerRel))),platform:process.platform},
  host:{hostname:os.hostname(),platform:process.platform,arch:os.arch()},
  input_scope:{tree:proofTree,command:'bash scripts/test.sh',gate_sha256:sha(fs.readFileSync(path.join(source,'scripts/test.sh')))}};
 check(fullProof(receipt,proofTree).verified,'real committed execution with tracked runner accepted');
 for(const bad of [{...receipt,kind:'producer-focused'},{...receipt,skipped:0},{...receipt,log_sha256:'0'.repeat(64)},{...receipt,tree:'f'.repeat(40)},{...receipt,repo:path.join(root,'removed-tested-clone')}])check(!fullProof(bad,proofTree).verified,'invalid full receipt rejected');
 const raw=path.join(root,'original.json');fs.writeFileSync(raw,JSON.stringify(receipt));
 const retained=retainFullProof(raw,owner,{candidateHead:proofHead});
 check(fullProof(retained,proofTree,{ownerRepo:owner}).verified,'retained proof verifies against durable owner storage');
 fs.writeFileSync(path.join(owner,'.git','wa-combined-gate.json'),JSON.stringify(retained));
 check(findFullProof(owner,proofTree).verified,'retained proof discovered through durable owner');
 fs.rmSync(source,{recursive:true,force:true});
 check(!fullProof(receipt,proofTree).verified,'unretained source retirement fails closed');
 const survived=fullProof(retained,proofTree,{ownerRepo:owner});check(survived.verified&&survived.tested_repo===source,'retained execution identity survives retirement');
 const retainedLog=JSON.parse(fs.readFileSync(retained.scope.path)).log;const logBytes=fs.readFileSync(retainedLog.path);fs.appendFileSync(retainedLog.path,'changed\n');
 check(!fullProof(retained,proofTree,{ownerRepo:owner}).verified,'corrupt retained terminal/log never reused');fs.writeFileSync(retainedLog.path,logBytes);
 passed=true;console.log(`wave proof adapters ok (${checks} checks; real Git review/landing objects, actual smoke schema, uncertainty negatives)`);
}finally{if(passed)fs.rmSync(root,{recursive:true});else console.error(`retained ${root}`);}
