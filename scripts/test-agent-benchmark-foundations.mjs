import {test} from 'node:test';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import {accounting,cacheContinuity,cleanupPlan,readiness,report,rubric} from './agent-benchmark-foundations.mjs';
test('unknown usage, summaries/retries and unpriced dollars remain unknown',()=>{
 const a=accounting([{kind:'attempt',usage:{input:100,cache_read:60,cache_write:10,output:5,reasoning:2}},{kind:'failed-summary'}]);
 assert.equal(a.input,null);assert.equal(a.actual_cost,null);assert.equal(a.complete_cost,false);assert.equal(a.attempts,2);assert.equal(a.tokens_wasted,null);
});
test('disjoint accounting preserves subsets and actual cost',()=>{
 const a=accounting([{usage:{input:100,cache_read:60,cache_write:10,output:5,reasoning:2,actual_cost:1}}]);
 assert.equal(a.uncached_input,30);assert.equal(a.output,5);assert.equal(a.actual_cost,1);
 assert.throws(()=>accounting([{usage:{input:1,cache_read:2,cache_write:0}}]));
 assert.throws(()=>accounting([{usage:{output:1,reasoning:2}}]));
});
test('cache prefix stability is not evidence of hits or coldness',()=>{
 const base={scope:'s',session:'one',model:'m',routing:'r',tools_hash:'t',instructions_hash:'i',prepared_prefix:'prefix'};
 const r=cacheContinuity([base,{...base,prepared_prefix:'prefix tail'}, {...base,session:'two'}, {...base,tools_hash:'changed'}]);
 assert.equal(r[1].continuity,true);assert.equal(r[1].cache_label,'unknown');assert.equal(r[1].cache_read,null);assert.equal(r[2].continuity,false);assert.ok(r[2].break_causes.includes('session'));assert.ok(r[3].break_causes.includes('tools_hash'));
});
test('stable long run, routing and instruction fences',()=>{
 const b={scope:'s',session:'a',model:'m',routing:'r',tools_hash:'t',instructions_hash:'i'};
 const seq=Array.from({length:100},(_,i)=>({...b,prepared_prefix:'a'.repeat(i+1)}));
 assert.equal(cacheContinuity(seq).filter(x=>x.continuity===true).length,99);
 for(const k of Object.keys(b)) assert.equal(cacheContinuity([seq[0],{...seq[1],[k]:'other'}])[1].continuity,false);
 assert.equal(cacheContinuity([{},{}])[1].continuity,null);
});
test('cleanup refuses corrupt, incomplete, shared, live, uncertain and escaping evidence',()=>{
 const b={sealed:true,integrity_verified:true,lossless:true,required_records_complete:true};
 const r={id:'x',kind:'checkout',generation:'g',owner_verified:true,drained:true,effects_known:true,shared:false,active:false,path_escape:false};
 assert.equal(cleanupPlan(b,[r],'g').length,1);
 for(const k of Object.keys(b))assert.throws(()=>cleanupPlan({...b,[k]:false},[r],'g'));
 for(const [k,v] of Object.entries({generation:'foreign',owner_verified:false,drained:false,effects_known:false,shared:true,active:true,path_escape:true,kind:'credential'}))assert.throws(()=>cleanupPlan(b,[{...r,[k]:v}],'g'));
});
test('candidate runner refuses before credentials or Docker',()=>{
 const r=spawnSync(process.execPath,['scripts/agent-benchmark.mjs','--check','fixtures/benchmarks/binding-discovery/v1/provenance.candidate.json'],{encoding:'utf8',env:{PATH:process.env.PATH}});
 assert.equal(r.status,1);assert.match(r.stderr,/benchmark readiness refused/);
});
test('readiness default refuses and scoring is not fabricated',()=>{
 assert.equal(readiness({}).ready,false);assert.equal(report({timed_out:true,oracle_pass:true}).finish,'oracle-pass-at-timeout');
 assert.equal(report({}).counters.retries,null);assert.equal(report({}).quality.scores,null);assert.equal(Object.values(rubric).reduce((a,b)=>a+b),100);
});
