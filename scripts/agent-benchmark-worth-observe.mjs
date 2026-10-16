// Prospective only. Stream host-written receipts; never rewrite old certificates.
import fs from 'node:fs';import readline from 'node:readline';import assert from 'node:assert/strict';import crypto from 'node:crypto';
export async function inspectScreenVm(file,{arm,binding}){
 let seq=0,current=null,starts=0,outer=0,errors=0,bypasses=0,nested=0,normal=0;let fidelity=true,reason=null;const hash=crypto.createHash('sha256');let bytes=0;
 const stream=fs.createReadStream(file);stream.on('data',b=>{hash.update(b);bytes+=b.length;});
 try{for await(const line of readline.createInterface({input:stream,crlfDelay:Infinity})){if(!line)continue;assert(Buffer.byteLength(line)<=32*1024*1024,'receipt line bound');const r=JSON.parse(line);assert(r.seq===++seq&&r.arm===arm&&r.binding===binding,'sequence/scope');
  if(r.type==='bypass'){bypasses++;continue;}
  if(r.type==='outer'){assert(!current&&r.invocation===++outer,'outer identity');current={invocation:r.invocation,code:r.args.code,pending:[],vm:null,owner:null,admitted:false,nested:null,closed:false};continue;}
  const c=current;assert(c&&r.invocation===c.invocation,'invocation correlation');
  if(r.type==='host'){
   if(r.action==='start'){assert(!c.vm&&r.args.code===c.code&&r.result.backend==='node-quickjs-wasi-reference'&&r.result.node_required===true,'actual Node host/source');if(r.result.ok){assert(r.result.id&&/^[a-f0-9]{64}$/.test(r.args.owner));c.vm=r.result.id;c.owner=r.args.owner;starts++;}else{assert(r.result.effect!=='unknown','unknown start outcome');}}
   else{assert(r.args.id===c.vm&&r.args.owner===c.owner,'VM scope');if(r.action==='admit'){assert(r.result.ok,'failed admission');c.admitted=true;}else if(r.action==='deliver'){const q=c.pending.shift();assert(q&&q.id===r.args.call_id,'delivery identity');if(q.target==='tool'||q.name==='searchTools'){assert(c.nested&&c.nested.ended,'missing nested admission/result');if(q.target==='tool')assert(c.nested.name===q.name&&c.nested.arguments===q.args,'argument identity');assert.deepEqual(JSON.parse(r.args.payload),c.nested.result,'payload fidelity');assert(r.args.ok===(!c.nested.result?.error&&c.nested.result?.ok!==false),'result status fidelity');c.nested=null;}assert(r.result.ok,'unknown/failed delivery');}else if(r.action==='close'){assert(r.result.ok,'failed close');c.closed=true;}else assert.fail('unexpected host action');}
   for(const e of r.result.events??[])if(e.type==='call')c.pending.push(e);
  }else if(r.type==='nested_start'){assert(c.vm&&c.admitted&&!c.nested&&c.pending.length,'nested admission receipt missing');c.admitted=false;c.nested={name:r.name,arguments:r.arguments};nested++;}
  else if(r.type==='nested_end'){assert(c.nested&&r.name===c.nested.name&&r.ok,'nested outcome unknown');assert(r.result?.effect!=='unknown'&&r.result?.cleanup!=='unknown','unknown tool effect');c.nested.result=r.result;c.nested.ended=true;if(r.result?.error||r.result?.ok===false)errors++;}
  else if(r.type==='outer_end'){assert(!c.nested,'unfinished nested call');assert(!c.vm||c.closed,'VM not closed');assert(!c.pending.length||r.result?.unexecuted?.length===c.pending.length,'undelivered call unaccounted');if(r.result?.ok)normal++;else errors++;assert(r.result?.effect!=='unknown','unknown outer result');current=null;}
  else assert.fail('unknown receipt record');
 }assert(!current&&seq>0,'incomplete journal');}catch(e){fidelity=false;reason=e.message;stream.destroy();}
 return {actual_vm_use:starts>0,vm_starts:starts,outer_invocations:outer,outer_routing_enforced:bypasses===0,bypass_attempts:bypasses,known_program_or_tool_errors:errors,protocol_fidelity:fidelity,unknown_outcome:!fidelity,protocol_failure:reason,normal_vm_invocations:normal,nested_attempts:nested,sha256:hash.digest('hex'),bytes,records:seq};
}
