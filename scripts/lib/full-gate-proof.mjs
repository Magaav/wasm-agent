// Full source execution proof. Original bytes and Git objects survive tree retirement.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const runners=new Set(['skills/parallel-evolution/scripts/finish.mjs','scripts/merge-lane.mjs']);
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
function requireFact(value,message){if(!value)throw Error(message);}
function git(repo,...args){const r=spawnSync('git',args,{cwd:repo,windowsHide:true,maxBuffer:32*1024*1024});if(r.status!==0)throw Error(r.stderr?.toString()||r.error?.message||'Git identity unavailable');return r.stdout;}
const gitText=(repo,...args)=>git(repo,...args).toString().trim();
function identity(repo){requireFact(fs.existsSync(repo),'original tested repository is unavailable');return {repo:path.resolve(repo),common:fs.realpathSync(gitText(repo,'rev-parse','--path-format=absolute','--git-common-dir')),format:gitText(repo,'rev-parse','--show-object-format')};}
function objectHash(type,bytes,format){return crypto.createHash(format).update(Buffer.from(`${type} ${bytes.length}\0`)).update(bytes).digest('hex');}
function checkedObject(ref,type,oid,format){const bytes=readRef(ref);requireFact(objectHash(type,bytes,format)===oid,'retained Git object identity mismatch');return bytes;}
function entries(bytes,format){const rows=[];let i=0;const size=format==='sha256'?32:20;while(i<bytes.length){const space=bytes.indexOf(32,i),zero=bytes.indexOf(0,space);requireFact(space>=i&&zero>space&&zero+1+size<=bytes.length,'invalid retained tree');rows.push({mode:bytes.subarray(i,space).toString(),name:bytes.subarray(space+1,zero).toString(),oid:bytes.subarray(zero+1,zero+1+size).toString('hex')});i=zero+1+size;}return rows;}
function readRef(ref){requireFact(ref&&/^[a-f0-9]{64}$/.test(ref.sha256||''),'artifact hash missing');const bytes=fs.readFileSync(ref.path);requireFact(digest(bytes)===ref.sha256,'retained artifact hash mismatch');return bytes;}
function scopeBlob(snapshot,relative){let oid=snapshot.tree;const parts=relative.split('/');for(let i=0;i<parts.length;i++){const bytes=checkedObject(snapshot.objects[oid],'tree',oid,snapshot.format);const row=entries(bytes,snapshot.format).find(r=>r.name===parts[i]);requireFact(row,'scope path missing from retained source tree');oid=row.oid;if(i===parts.length-1){requireFact(/^100(644|755)$/.test(row.mode),'scope file is not a tracked regular blob');return checkedObject(snapshot.objects[oid],'blob',oid,snapshot.format);}}throw Error('empty scope path');}
function verifySnapshot(snapshot,head,tree){requireFact(snapshot.head===head&&snapshot.tree===tree,'original source head/tree annotation changed');const commit=checkedObject(snapshot.commit,'commit',head,snapshot.format);requireFact(commit.toString().split('\n')[0]===`tree ${tree}`,'tested commit does not identify recorded tree');checkedObject(snapshot.objects[tree],'tree',tree,snapshot.format);}
function platform(receipt){requireFact(receipt.runner&&receipt.runner.platform===process.platform,'unknown or mismatched execution platform');const expected=process.platform==='win32'?path.join(process.env.ProgramFiles||'C:/Program Files','Git','bin','bash.exe'):'bash';const normalize=s=>path.resolve(s).toLowerCase();requireFact(process.platform==='win32'?normalize(receipt.shell||'')===normalize(expected):receipt.shell==='bash'||receipt.shell==='/bin/bash'||receipt.shell==='/usr/bin/bash','unknown native gate shell');if(receipt.host){requireFact(receipt.host.platform===process.platform&&receipt.host.arch===os.arch()&&receipt.host.hostname===os.hostname(),'execution host attestation differs from known local host');}}
function terminal(receipt,bytes,tree){requireFact((!receipt.kind||receipt.kind==='full')&&receipt.schema===1&&receipt.passed===true&&receipt.tree===tree&&receipt.gate_exit===0&&receipt.gate_runs===1&&Number.isFinite(receipt.gate_ms)&&receipt.gate_ms>=0,'invalid full receipt');const match=/(?:^|\n)smoke ok(?: \((\d+) skipped\))?\r?\n?$/.exec(bytes.toString());requireFact(digest(bytes)===receipt.log_sha256&&match&&Number(match[1]||0)===receipt.skipped,'invalid full log or skips');return match[0].trim();}
function driver(receipt){const repo=receipt.runner?.source_repo||receipt.repo,head=receipt.runner?.source_head||receipt.head;const relative=path.relative(repo,receipt.runner?.path||'').replaceAll('\\','/');requireFact(runners.has(relative),'runner is not a known repository gate driver');return {repo,head,relative};}
function live(receipt,tree){platform(receipt);const source=identity(receipt.repo);requireFact(gitText(receipt.repo,'rev-parse',`${receipt.head}^{tree}`)===tree,'tested head/tree not in original shared Git source');const d=driver(receipt),runnerIdentity=identity(d.repo),bytes=git(d.repo,'show',`${d.head}:${d.relative}`);requireFact(digest(bytes)===receipt.runner.sha256,'runner bytes do not match recorded source/hash');const gate=git(receipt.repo,'show',`${receipt.head}:scripts/test.sh`);requireFact(gate.length>0,'full gate input scope unavailable');if(receipt.input_scope){requireFact(receipt.input_scope.tree===tree&&receipt.input_scope.command==='bash scripts/test.sh'&&receipt.input_scope.gate_sha256===digest(gate),'input scope annotation mismatch');}const log=fs.readFileSync(receipt.log);return {source,driver:d,runnerIdentity,runnerBytes:bytes,gateBytes:gate,log,verdict:terminal(receipt,log,tree)};}
function result(receipt,verdict,log){return {verified:true,tree:receipt.tree,head:receipt.head,tested_repo:receipt.repo,owner_repo:receipt.owner_repo||receipt.repo,runner:receipt.runner,shell:receipt.shell,host:receipt.host||null,execution_host_recorded:Boolean(receipt.host),input_scope:receipt.input_scope||{tree:receipt.tree,command:'bash scripts/test.sh',legacy_scope_derived_from_exact_source:true},log,log_sha256:receipt.log_sha256,skipped:receipt.skipped,gate_ms:receipt.gate_ms,verdict_line:verdict};}
export function fullProof(receipt,tree,{ownerRepo=null}={}){
 try{
  if(receipt.schema!==2){const proof=live(receipt,tree);return result(receipt,proof.verdict,receipt.log);}
  requireFact(receipt.kind==='retained-full','unknown retained receipt schema');
  const allowed=new Set(['schema','kind','source_receipt','scope','owner_repo','candidate_head','at']);requireFact(Object.keys(receipt).every(k=>allowed.has(k)),'derived receipt must not override original execution identity');
  const originalBytes=readRef(receipt.source_receipt),original=JSON.parse(originalBytes),scope=JSON.parse(readRef(receipt.scope));
  requireFact(scope.schema===1&&scope.original_receipt_sha256===digest(originalBytes),'immutable source receipt link mismatch');platform(original);
  requireFact(scope.capture_host.platform===process.platform&&scope.capture_host.arch===os.arch()&&scope.capture_host.hostname===os.hostname(),'retention host/platform mismatch');
  requireFact(scope.source.repo===path.resolve(original.repo),'retained original tested repository changed');verifySnapshot(scope.source,original.head,tree);
  const d=driver(original);requireFact(scope.driver.repo===path.resolve(d.repo)&&scope.driver.head===d.head&&scope.runner_relative===d.relative,'original runner provenance changed');verifySnapshot(scope.driver,d.head,scope.driver.tree);
  const runner=scopeBlob(scope.driver,d.relative);requireFact(digest(runner)===original.runner.sha256&&digest(readRef(scope.runner))===original.runner.sha256,'retained runner/hash mismatch');
  const gate=scopeBlob(scope.source,'scripts/test.sh');requireFact(digest(gate)===scope.input_scope.gate_sha256&&scope.input_scope.tree===tree&&scope.input_scope.command==='bash scripts/test.sh','retained gate input scope mismatch');
  if(original.input_scope)requireFact(JSON.stringify(original.input_scope)===JSON.stringify(scope.original_input_scope),'original input attestation changed');
  requireFact(scope.owner.repo===path.resolve(receipt.owner_repo),'storage owner annotation changed');
  const current=identity(ownerRepo||receipt.owner_repo);requireFact(current.common===scope.owner.common&&current.format===scope.owner.format,'retained proof belongs to a different shared Git repository');
  const log=readRef(scope.log),verdict=terminal(original,log,tree);return {...result(original,verdict,scope.log.path),owner_repo:receipt.owner_repo,retained:true,original_receipt:receipt.source_receipt,retained_scope:receipt.scope,retention_host:scope.capture_host};
 }catch(error){return {verified:false,reason:error.message};}
}
export function retainFullProof(receiptPath,ownerRepo,{candidateHead=null}={}){
 const raw=fs.readFileSync(receiptPath),receipt=JSON.parse(raw),owner=identity(ownerRepo);
 const root=path.join(owner.common,'wa-full-proof-evidence','objects');fs.mkdirSync(root,{recursive:true});
 const put=bytes=>{const sha256=digest(bytes),file=path.join(root,sha256);try{fs.writeFileSync(file,bytes,{flag:'wx'});}catch(error){if(error.code!=='EEXIST')throw error;requireFact(digest(fs.readFileSync(file))===sha256,'existing immutable object corrupt');}return {path:file,sha256};};
 if(receipt.schema===2){
  const original=JSON.parse(readRef(receipt.source_receipt));
  const proof=fullProof(receipt,original.tree);requireFact(proof.verified,proof.reason);
  const scope=JSON.parse(readRef(receipt.scope));
  requireFact(owner.common===scope.owner.common&&owner.format===scope.owner.format,'cannot derive proof into another shared Git repository');
  const copy=ref=>put(readRef(ref));
  for(const snapshot of [scope.source,scope.driver]){snapshot.commit=copy(snapshot.commit);for(const oid of Object.keys(snapshot.objects))snapshot.objects[oid]=copy(snapshot.objects[oid]);}
  scope.owner=owner;scope.runner=copy(scope.runner);scope.log=copy(scope.log);
  return {schema:2,kind:'retained-full',source_receipt:copy(receipt.source_receipt),scope:put(Buffer.from(JSON.stringify(scope))),owner_repo:path.resolve(ownerRepo),candidate_head:candidateHead||receipt.candidate_head,at:new Date().toISOString()};
 }
 const verified=live(receipt,receipt.tree);
 const snapshot=(repo,head,paths)=>{const id=identity(repo),tree=gitText(repo,'rev-parse',`${head}^{tree}`),objects={};const add=(oid,type)=>{if(!objects[oid])objects[oid]=put(git(repo,'cat-file',type,oid));return git(repo,'cat-file',type,oid);};add(tree,'tree');for(const relative of paths){let oid=tree;const parts=relative.split('/');for(let i=0;i<parts.length;i++){const row=entries(add(oid,'tree'),id.format).find(r=>r.name===parts[i]);requireFact(row,'scope path absent');oid=row.oid;add(oid,i===parts.length-1?'blob':'tree');}}return {...id,head,tree,commit:put(git(repo,'cat-file','commit',head)),objects};};
 const scope={schema:1,original_receipt_sha256:digest(raw),owner,source:snapshot(receipt.repo,receipt.head,['scripts/test.sh']),driver:snapshot(verified.driver.repo,verified.driver.head,[verified.driver.relative]),runner_relative:verified.driver.relative,runner:put(verified.runnerBytes),log:put(verified.log),input_scope:{tree:receipt.tree,command:'bash scripts/test.sh',gate_sha256:digest(verified.gateBytes)},original_input_scope:receipt.input_scope||null,capture_host:{hostname:os.hostname(),platform:process.platform,arch:os.arch()},legacy_execution_host_recorded:Boolean(receipt.host)};
 return {schema:2,kind:'retained-full',source_receipt:put(raw),scope:put(Buffer.from(JSON.stringify(scope))),owner_repo:path.resolve(ownerRepo),candidate_head:candidateHead||receipt.head,at:new Date().toISOString()};
}
export function findFullProof(repo,tree){
 const listed=spawnSync('git',['worktree','list','--porcelain'],{cwd:repo,encoding:'utf8',windowsHide:true});const roots=new Set([repo,...(listed.stdout||'').split('\n').filter(l=>l.startsWith('worktree ')).map(l=>l.slice(9))]);
 for(const root of roots)for(const name of ['wa-finish-gate.json','wa-combined-gate.json']){try{const file=path.resolve(root,gitText(root,'rev-parse','--git-path',name)),receipt=JSON.parse(fs.readFileSync(file));const storageOwner=name==='wa-combined-gate.json'?receipt.owner_repo:receipt.repo;if(!storageOwner||path.resolve(storageOwner)!==path.resolve(root))continue;const proof=fullProof(receipt,tree,{ownerRepo:root});if(proof.verified)return {...proof,receipt:file};}catch{}}
 return {verified:false,reason:'no complete identity-bound identical-tree smoke evidence'};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){try{const [repo,tree]=process.argv.slice(2);const proof=findFullProof(path.resolve(repo||'.'),tree);console.log(JSON.stringify(proof));if(!proof.verified)process.exitCode=2;}catch(error){console.error(error.message);process.exitCode=2;}}
