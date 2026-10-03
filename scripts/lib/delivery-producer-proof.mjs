// Explicit delivery subsystem admission, not release verification.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
export const deliveryFiles=['scripts/delivery-record.mjs','scripts/delivery-admission.mjs','scripts/merge-lane.mjs','scripts/producer-admission.mjs','scripts/lib/delivery-local.mjs','scripts/lib/delivery-store.mjs','scripts/lib/delivery-producer-proof.mjs','scripts/test-delivery-refresh.mjs','scripts/test-delivery-admission.mjs','scripts/test-delivery-local.mjs','scripts/test-delivery-store.mjs','scripts/test-merge-lane.mjs','scripts/test-delivery-subsystem-consumer.mjs'];
const suites=['test-delivery-refresh.mjs','test-delivery-admission.mjs','test-delivery-store.mjs','test-merge-lane.mjs'];
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function git(repo,...args){const r=spawnSync('git',args,{cwd:repo,maxBuffer:32*1024*1024});if(r.status!==0)throw Error(String(r.stderr));return r.stdout;}
const text=(repo,...args)=>String(git(repo,...args)).trim();
// Cooperative local attestation, not a signature against an evidence-store writer.
function runner(){const executable=fs.realpathSync(process.execPath);return {executable,platform:process.platform,version:process.version,sha256:hash(fs.readFileSync(executable))};}
export function skipped(log){let count=0;for(const line of log.split(/\r?\n/)){const summary=line.match(/\b(\d+)\s+(?:tests?\s+)?skipped\b/i);if(summary)count+=Number(summary[1]);else if(/^\s*(?:[-#]\s*)?skip(?:ped)?(?:\s|:|$)/i.test(line))count++;}return count;}
function executionSources(repo,pinned){return Object.fromEntries(Object.keys(pinned).filter(f=>/\.(mjs|cjs|js|sh)$/.test(f)).map(f=>[f,hash(fs.readFileSync(path.join(repo,f)))]));}
function sources(repo,head){
 // Pin entire scripts and skills closures: dynamic imports and subprocess drivers included.
 const files=text(repo,'ls-tree','-r','--name-only',head,'scripts','skills').split('\n').filter(Boolean);
 return Object.fromEntries(files.map(f=>[f,hash(git(repo,'show',`${head}:${f}`))]));
}
export function verifyDeliveryProof(repo,receipt,selection){
 try{
  if(selection.full_required||selection.checks[0]!=='delivery-subsystem')throw Error('unsupported_delivery_scope');
  if(receipt.kind!=='delivery-subsystem'||receipt.schema!==1||receipt.head!==selection.head||receipt.tree!==selection.tree||receipt.base!==selection.base||receipt.passed!==true)throw Error('delivery_identity_mismatch');
  const expected=sources(repo,selection.head);
  if(JSON.stringify(receipt.sources)!==JSON.stringify(expected))throw Error('delivery_source_closure_mismatch');
  if(JSON.stringify(receipt.runner)!==JSON.stringify(runner()))throw Error('delivery_runner_identity_mismatch');
  const executing=Object.fromEntries(Object.entries(expected).filter(([f])=>/\.(mjs|cjs|js|sh)$/.test(f)));
  if(JSON.stringify(receipt.execution_before)!==JSON.stringify(executing)||JSON.stringify(receipt.execution_after)!==JSON.stringify(executing))throw Error('delivery_execution_source_mismatch');
  if(receipt.results?.length!==suites.length)throw Error('delivery_required_suites_missing');
  for(const suite of suites){const r=receipt.results.find(x=>x.suite===suite);const log=r&&fs.readFileSync(r.log);if(!r||r.exit!==0||r.skipped!==skipped(String(log))||skipped(String(log))!==0||hash(log)!==r.log_sha256||!terminal(suite,String(log)))throw Error(`delivery_suite_unverified:${suite}`);}
  return {admission_verified:true,gate_verified:false,requires_combined_gate:true,head:selection.head,tree:selection.tree,checks:selection.checks};
 }catch(error){return {admission_verified:false,gate_verified:false,error:error.message};}
}
export function terminal(suite,log){
 const patterns={'test-delivery-refresh.mjs':/^delivery refresh ok .*0 skipped/m,'test-delivery-admission.mjs':/^delivery admission ok \((\d+) checks\)/m,'test-delivery-store.mjs':/^delivery store ok \((\d+) checks, 0 skipped/m,'test-merge-lane.mjs':/^merge-lane spine ok \((\d+) checks\)/m};
 const matches=[...log.matchAll(new RegExp(patterns[suite].source,'gm'))],floor={'test-delivery-admission.mjs':58,'test-delivery-store.mjs':9,'test-merge-lane.mjs':107}[suite]||0;
 return matches.length===1&&(!floor||Number(matches[0][1])>=floor)&&!/^.*\bFAIL(?:ED)?\b/m.test(log)&&skipped(log)===0;
}
export function runDeliveryProof(repo,selection,output){
 const pinned=sources(repo,selection.head);
 for(const [f,digest] of Object.entries(pinned).filter(([f])=>/\.(mjs|cjs|js|sh)$/.test(f)))if(hash(fs.readFileSync(path.join(repo,f)))!==digest)throw Error(`uncommitted_source:${f}`);
 const execution_before=executionSources(repo,pinned),execution_runner=runner();
 const root=output||path.resolve(repo,text(repo,'rev-parse','--git-path','wa-delivery-producer-logs'));fs.mkdirSync(root,{recursive:true});
 const results=suites.map(suite=>{const r=spawnSync(process.execPath,[`scripts/${suite}`],{cwd:repo,encoding:'utf8',maxBuffer:32*1024*1024,timeout:180000});const bytes=Buffer.from((r.stdout||'')+(r.stderr||'')),log=path.join(root,suite+'.log');fs.writeFileSync(log,bytes);return {suite,exit:r.status,skipped:skipped(String(bytes)),log,log_sha256:hash(bytes),passed:r.status===0&&terminal(suite,String(bytes))};});
 if(text(repo,'rev-parse','HEAD')!==selection.head||text(repo,'status','--porcelain'))throw Error('delivery_source_moved');
 const execution_after=executionSources(repo,pinned);if(JSON.stringify(execution_before)!==JSON.stringify(execution_after)||JSON.stringify(execution_runner)!==JSON.stringify(runner()))throw Error('delivery_execution_changed');
 return {schema:1,kind:'delivery-subsystem',...selection,sources:pinned,runner:execution_runner,execution_before,execution_after,results,passed:results.every(r=>r.passed),gate_verified:false};
}
