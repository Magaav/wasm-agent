import test from 'node:test';import assert from 'node:assert/strict';
import {verifyVmJournal,forcedScope} from '../benchmarks/codemode/forced-contract.mjs';import {runParallelWave} from './agent-benchmark-parallel.mjs';import {preparePilot,parallelLimits,proposedLimits} from './agent-benchmark-pilot.mjs';
const binding='a'.repeat(64),arm='rust-v2';
function trace(){const owner='b'.repeat(64),id='vm-1',args='{"path":"probe.txt"}',value={content:'real task result',typed:null};return [
 {type:'outer',invocation:1,session:'private-session',args:{code:'text(await tools.read({path:"probe.txt"}));'}},
 {type:'host',invocation:1,action:'start',args:{owner,code:'text(await tools.read({path:"probe.txt"}));'},result:{ok:true,id,backend:'rust-wasmtime-quickjs-wasi',events:[{type:'call',id:1,target:'tool',name:'read',args}]}},
 {type:'host',invocation:1,action:'admit',args:{id,owner},result:{ok:true}},
 {type:'nested_start',invocation:1,name:'read',arguments:args},
 {type:'nested_end',invocation:1,name:'read',ok:true,result:value},
 {type:'host',invocation:1,action:'deliver',args:{id,owner,call_id:1,ok:true,payload:JSON.stringify(value)},result:{ok:true,events:[{type:'done',ok:true}]}},
 {type:'host',invocation:1,action:'close',args:{id,owner},result:{ok:true}},
 {type:'outer_end',invocation:1,result:{ok:true}}
 ].map((r,i)=>({...r,seq:i+1,arm,binding}));}
const check=rows=>verifyVmJournal(Buffer.from(rows.map(x=>JSON.stringify(x)).join('\n')+'\n'),{arm,binding});
test('real host protocol and meaningful nested result are required',()=>{const r=check(trace());assert.equal(r.used,true);assert.equal(r.outer_vm_calls,1);assert.equal(r.nested.read,1);});
for(const [name,mutate]of [
 ['forged backend',r=>r[1].result.backend='model-claims-rust'],
 ['cross-arm trace',r=>r[4].arm='pi'],
 ['cross-session trace',r=>{r.push({...r[0],seq:9,invocation:2,session:'foreign'});}],
 ['changed source',r=>r[1].args.code='text("claim")'],
 ['forged nested result',r=>r[4].result.content='forged'],
 ['wrong VM owner',r=>r[5].args.owner='c'.repeat(64)],
 ['wrong call identity',r=>r[5].args.call_id=2],
 ['unknown effect',r=>r[4].result.effect='unknown'],
 ['incomplete trace',r=>r.pop()],
 ['outer bypass',r=>{r[0].type='bypass';}],
 ['missing actual VM execution',r=>r[1].result.ok=false]
])test(name+' refuses verified use',()=>{const r=trace();mutate(r);assert.throws(()=>check(r));});
test('zero use is not a valid treatment',()=>assert.throws(()=>check([])));
const arms=['pi','wasm-current','node-v1','rust-v2'].map(arm=>({arm}));
test('parallel wave starts all actors, waits all settlements and drains before return',async()=>{let active=0,max=0,drained=0;const r=await runParallelWave(arms,async(a,barrier)=>{await barrier(a.arm);const started=Date.now();active++;max=Math.max(max,active);await new Promise(r=>setTimeout(r,20));active--;await barrier.settled(a.arm);drained++;return {solver_released_at:started,solver_ended_at:Date.now()};});assert.equal(max,4);assert.equal(drained,4);assert(r.overlap_ms>0);});
test('failure never fail-fast leaves another actor uncollected',async()=>{let drained=0,halted=0;await assert.rejects(runParallelWave(arms,async(a,barrier)=>{try{await barrier(a.arm);if(a.arm==='pi')throw Error('unknown effect');await new Promise(r=>setTimeout(r,30));await barrier.settled(a.arm);return {};}finally{drained++;}},{halt:()=>halted++}),e=>e.failures.length===1);assert.equal(drained,4);assert.equal(halted,1);});
test('staging failure releases waiters without actor effects',async()=>{let effects=0,drained=0;await assert.rejects(runParallelWave(arms,async(a,b)=>{try{if(a.arm==='pi')throw Error('stage refused');await b(a.arm);effects++;}finally{drained++;}}));assert.equal(effects,0);assert.equal(drained,4);});
test('old entries retain serial limits; new scope is explicit, same per-arm envelope',()=>{assert.match(proposedLimits.controller,/serial/);assert.match(parallelLimits.controller,/concurrent/);for(const k of ['maxRequests','maxPromptTotal','maxOutputTotal','maxMilliseconds','maxRequestMilliseconds','automaticTrialRetries'])assert.equal(parallelLimits[k],proposedLimits[k]);assert.throws(()=>preparePilot({},'',forcedScope+'-copy'),/fixed pilot scope/);});
