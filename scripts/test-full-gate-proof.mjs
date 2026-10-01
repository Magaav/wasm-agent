import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fullProof,findFullProof,retainFullProof} from './lib/full-gate-proof.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-full-proof-'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
let checks=0;
const check=(value,message)=>{assert(value,message);checks++;};
const git=(repo,...args)=>{const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
const init=repo=>{fs.mkdirSync(repo);git(repo,'init','-q','--initial-branch','main');};
try{
 const source=path.join(root,'actual-source'),owner=path.join(root,'owner');init(source);init(owner);
 fs.mkdirSync(path.join(source,'scripts'));fs.mkdirSync(path.join(source,'skills/parallel-evolution/scripts'),{recursive:true});
 const runner=path.join(source,'skills/parallel-evolution/scripts/finish.mjs');
 fs.writeFileSync(runner,fs.readFileSync(new URL('../skills/parallel-evolution/scripts/finish.mjs',import.meta.url)));
 fs.writeFileSync(path.join(source,'scripts/test.sh'),'#!/bin/sh\nprintf "fixture assertion passed\\nsmoke ok (2 skipped)\\n"\n');
 git(source,'add','.');git(source,'-c','user.name=proof fixture','-c','user.email=proof@example.invalid','commit','-qm','real fixture source');
 const head=git(source,'rev-parse','HEAD'),tree=git(source,'rev-parse','HEAD^{tree}');
 const shell=process.platform==='win32'?path.join(process.env.ProgramFiles||'C:/Program Files','Git/bin/bash.exe'):'bash';
 const executed=spawnSync(shell,['scripts/test.sh'],{cwd:source,windowsHide:true});assert.equal(executed.status,0);
 const log=path.join(root,'gate.log');fs.writeFileSync(log,executed.stdout);
 const receipt={schema:1,kind:'full',repo:source,head,tree,gate_exit:0,gate_runs:1,gate_ms:1,passed:true,skipped:2,log,log_sha256:sha(executed.stdout),shell,
  runner:{path:runner,sha256:sha(fs.readFileSync(runner)),platform:process.platform},
  host:{hostname:os.hostname(),platform:process.platform,arch:os.arch()},
  input_scope:{tree,command:'bash scripts/test.sh',gate_sha256:sha(fs.readFileSync(path.join(source,'scripts/test.sh')))}};
 check(fullProof(receipt,tree).verified,'actual committed fixture execution accepted');
 for(const patch of [{repo:path.join(root,'never-existed')},{head:'f'.repeat(40)},{tree:'e'.repeat(40)},{gate_exit:7},{passed:false},{kind:'producer-focused'},{skipped:0},{gate_runs:0},{gate_ms:-1},{shell:'unknown shell'},
 {runner:{...receipt.runner,sha256:'0'.repeat(64)}},{runner:{...receipt.runner,platform:'wrong-platform'}},{host:{...receipt.host,hostname:'unknown-host'}},{input_scope:{...receipt.input_scope,gate_sha256:'0'.repeat(64)}}])check(!fullProof({...receipt,...patch},tree).verified,'reject '+JSON.stringify(patch));
 const rawPath=path.join(root,'original.json');fs.writeFileSync(rawPath,JSON.stringify(receipt));
 const retained=retainFullProof(rawPath,owner,{candidateHead:head});
 check(fullProof(retained,tree,{ownerRepo:owner}).verified,'pinned real source proof accepted');
 check(!fullProof({...retained,owner_repo:path.join(root,'nonexistent-storage')},tree).verified,'nonexistent storage identity rejected');
 check(fs.readFileSync(retained.source_receipt.path).equals(fs.readFileSync(rawPath)),'original receipt retained byte exactly');
 fs.writeFileSync(path.join(owner,'.git/wa-combined-gate.json'),JSON.stringify(retained));
 check(findFullProof(owner,tree).verified,'retained proof discoverable');
 for(const patch of [{repo:source},{head:'0'.repeat(40)},{runner:receipt.runner},{owner_repo:source},{source_receipt:{...retained.source_receipt,sha256:'0'.repeat(64)}},{scope:{...retained.scope,sha256:'0'.repeat(64)}}])check(!fullProof({...retained,...patch},tree,{ownerRepo:owner}).verified,'reject immutable override/corruption');
 check(!findFullProof(owner,'0'.repeat(40)).verified,'different candidate tree rejected');
 // Retire only the fixture-owned standalone repository, never an active linked worktree.
 fs.rmSync(source,{recursive:true,force:true});
 check(!fullProof(receipt,tree).verified,'unretained source deletion fails closed');
 const after=fullProof(retained,tree,{ownerRepo:owner});check(after.verified,'retained Git provenance survives actual source deletion');
 check(after.tested_repo===source&&after.head===head,'storage owner never replaces original tested identity');
 const scope=JSON.parse(fs.readFileSync(retained.scope.path));
 for(const ref of [scope.source.commit,scope.source.objects[tree],scope.runner,scope.log,retained.source_receipt]){
  const bytes=fs.readFileSync(ref.path);fs.writeFileSync(ref.path,Buffer.concat([bytes,Buffer.from('corruption')]));
  check(!fullProof(retained,tree,{ownerRepo:owner}).verified,'retired evidence corruption rejected');fs.writeFileSync(ref.path,bytes);
 }
 check(fullProof(retained,tree,{ownerRepo:owner}).verified,'restored fixture bytes verify');
 console.log(`full gate proof ok (${checks} checks, 0 skipped)`);
}finally{fs.rmSync(root,{recursive:true,force:true});}
