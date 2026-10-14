import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {isolatedEnvironment} from './agent-benchmark-environment.mjs';
import {accounting,readiness,report,rubric,cleanupPlan,qualityNotes,anonymizedOutputId} from './agent-benchmark-foundations.mjs';
import {normalizeUsage,nativeTrace,piTrace,preparedRequests,digest,observationTimeline} from './agent-benchmark-telemetry.mjs';
const native={known:true,cache_known:true,cost_known:false,prompt:100,input:20,cacheRead:70,cacheWrite:10,output:5,reasoning:2};
const pi={input:20,cacheRead:70,cacheWrite:10,output:5,reasoning:2,cost:{total:0}};
test('preparation subprocess environment does not copy caller credentials or home configuration',()=>{
 const preserved=process.env.WASM_AGENT_PROVENANCE;process.env.WASM_AGENT_PROVENANCE='child';process.env.BENCHMARK_FAKE_SECRET='not-a-real-secret';try {const env=isolatedEnvironment('private-home',{WASM_AGENT_PROVENANCE:'orchestrator'});assert.equal(env.BENCHMARK_FAKE_SECRET,undefined);assert.equal(env.HOME,'private-home');assert.equal(env.USERPROFILE,'private-home');assert.equal(env.WASM_AGENT_PROVENANCE,'child');}finally{delete process.env.BENCHMARK_FAKE_SECRET;if(preserved===undefined)delete process.env.WASM_AGENT_PROVENANCE;else process.env.WASM_AGENT_PROVENANCE=preserved;}
});
test('Pi uncached input and native total prompt normalize identically without invented prices',()=>{
 const p=normalizeUsage(pi,'pi'),n=normalizeUsage(native,'native');
 for(const k of ['prompt_total','uncached_input','cache_read','cache_write','output','reasoning','actual_cost'])assert.equal(p[k],n[k]);
 assert.equal(p.reported_priced_cost,0);assert.equal(p.actual_cost,null);
 assert.equal(normalizeUsage({...native,cost_known:true,cost:.01},'native').reported_priced_cost,.01);
 assert.equal(normalizeUsage({...native,cost_known:true,cost:.01},'native').actual_cost,null);
 assert.equal(normalizeUsage({...native,actualBilling:{priced:true,cost:.01,currency:'USD',receipt_sha256:'a'.repeat(64)}},'native').actual_cost,.01);
 for(const n of [-1,.5,Number.MAX_SAFE_INTEGER+1,NaN])assert.throws(()=>normalizeUsage({...pi,input:n},'pi'));
 assert.throws(()=>normalizeUsage({...native,prompt:1},'native'));
 assert.throws(()=>normalizeUsage({...pi,totalTokens:1},'pi'));
 assert.throws(()=>normalizeUsage({...pi,input:Number.MAX_SAFE_INTEGER,cacheRead:1},'pi'));
 assert.throws(()=>normalizeUsage({...pi,reasoning:10},'pi'));
 assert.equal(normalizeUsage({input:20,output:2},'pi').prompt_total,null);
});
test('all attempts, failed summaries and unknown retries invalidate complete cost',()=>{
 const a=accounting([{usage:normalizeUsage(native,'native')},{kind:'failed-summary',usage:normalizeUsage(null,'native')}]);
 assert.equal(a.prompt_total,null);assert.equal(a.actual_cost,null);assert.equal(a.complete_cost,false);assert.equal(a.attempts,2);assert.equal(a.tokens_wasted,null);
 assert.throws(()=>accounting([{usage:{input:20}}]),/ambiguous/);assert.throws(()=>accounting([{usage:{output:.5}}]));
});
const request={scope:'operator',session:'one',kind:'model_call',routing:{endpoint:'https://provider.invalid/responses',session:'one'},body:{model:'fixture-model',messages:[{role:'system',content:'Do not send or deploy.'},{role:'user',content:'Fix binding discovery.'}],tools:[{type:'function',function:{name:'read',parameters:{type:'object',properties:{path:{type:'string'}}}}}],max_tokens:4096},usage:native,ttft_ms:8};
test('actually prepared JSON message append survives closing-bracket causal control',()=>{
 const next={...request,body:{...request.body,max_tokens:2048,messages:[...request.body.messages,{role:'assistant',tool_calls:[{id:'c',type:'function',function:{name:'read',arguments:'{"path":"tools.lua"}'}}]},{role:'tool',tool_call_id:'c',content:'source bytes'}]}};
 assert.equal(JSON.stringify(next.body).startsWith(JSON.stringify(request.body)),false);
 const r=preparedRequests([request,next]);assert.equal(r[1].relation,'append_only');assert.equal(r[1].cache_relevant_changed,false);assert.equal(r[1].settings_changed,true);assert.equal(r[1].cache_label,'observed-cache-read');assert.equal(r[1].ttft_ms,8);assert(!JSON.stringify(r).includes('Fix binding'));
});
test('prepared long run plus schema/model/routing/instruction and cross-session fences',()=>{
 const seq=Array.from({length:100},(_,i)=>({...request,body:{...request.body,messages:[...request.body.messages,...Array.from({length:i},(_,n)=>({role:'user',content:'observation '+n}))]}}));
 assert.equal(preparedRequests(seq).filter(x=>x.relation==='append_only').length,99);
 for(const field of ['model','tools','instructions']) {const x={...request,body:{...request.body,[field]:field==='tools'?[]:'changed'}};assert.equal(preparedRequests([request,x])[1].cache_relevant_changed,true);}
 assert.equal(preparedRequests([request,{...request,routing:{endpoint:'other'}}])[1].cache_relevant_changed,true);
 assert.equal(preparedRequests([request,{...request,body:{...request.body,prompt_cache_key:'new-route'}}])[1].cache_relevant_changed,true);
 assert.equal(preparedRequests([request,{...request,session:'other'}])[1].relation,'unmeasured');
 assert.equal(preparedRequests([request,{...request,routing:null}])[1].reason,'missing-scope-or-routing');
 assert.equal(preparedRequests([request,{...request,scope:null}])[1].reason,'missing-scope-or-routing');
 assert.throws(()=>preparedRequests([{...request,headers:{Authorization:'secret'}}]),/credential/);
 assert.throws(()=>preparedRequests([request],{secrets:['Fix binding']}),/secret/);
 assert.throws(()=>preparedRequests([{...request,routing:{endpoint:'https://user:password@host/'}}]),/credential/);
 assert.throws(()=>preparedRequests([{...request,routing:{endpoint:'host',auth_token:'private'}}]),/credential/);
 const evicted=Array.from({length:17},(_,i)=>({...request,session:'session-'+i}));assert.equal(preparedRequests([...evicted,evicted[0]]).at(-1).relation,'unmeasured');
 assert.equal(preparedRequests([{...request,body:{...request.body,messages:Array(8193).fill({role:'user',content:'budget'})}}])[0].reason,'message_budget');
 assert.equal(preparedRequests([{...request,usage:undefined}])[0].cache_read,null);
});
let seq=0;const event=(span,kind,phase,payload)=>({id:'e'+(++seq),seq,session_id:'s',run_id:'r',span_id:span,kind,phase,payload});
test('native adapter validates spans, failures, summaries, lost attempts and metadata-only output',()=>{
 const a=event('1','model_call','start',{system_hash:'a'.repeat(64),schema_hash:'b'.repeat(64),model:'fixture',provider:'local'}),b=event('1','model_call','end',{ok:true,ms:10,ttft_ms:2,normalized:native,transport_failed_attempts:1});
 const s=event('2','summary','start',{}),e=event('2','summary','end',{ok:false,normalized:{known:false}});
 const r=nativeTrace({events:[a,b,s,e,a]});assert.equal(r.accounting.attempts,3);assert.equal(r.accounting.prompt_total,null);assert.equal(r.accounting.complete_cost,false);assert.equal(r.summary_attempts,1);assert.equal(r.nested_code_mode_calls,null);
 assert.throws(()=>nativeTrace({events:[a,{...a,payload:{other:true}}]}),/duplicate/);
 assert.throws(()=>nativeTrace({events:[b,{...a,seq:b.seq+1}]}),/boundaries/);
 assert.throws(()=>nativeTrace({events:[a],has_more:true}),/incomplete/);
 assert.equal(nativeTrace([a]).accounting.prompt_total,null);
});
test('realistic Pi JSONL shapes preserve abort/compaction/unpriced/lost evidence',()=>{
 const rows=[{id:'a',type:'message',message:{role:'assistant',usage:pi,content:[{type:'toolCall',id:'c',name:'read',arguments:{path:'private-prompt-path'}}],stopReason:'toolUse'}},{id:'t',type:'message',message:{role:'toolResult',toolCallId:'c',isError:true,content:[{type:'text',text:'private-result'}]}},{id:'b',type:'message',message:{role:'assistant',stopReason:'aborted',content:[]}},{id:'s',type:'compaction',summary:'private-summary'}];
 const r=piTrace(rows.map(JSON.stringify).join('\n'));assert.equal(r.tool_calls,1);assert.equal(r.compactions,1);assert.equal(r.accounting.attempts,3);assert.equal(r.accounting.actual_cost,null);assert.equal(r.complete_worker_cost,false);assert(!JSON.stringify(r).includes('private-'));
 assert.throws(()=>piTrace([...rows,{...rows[0],message:{role:'assistant',content:[]}}]),/duplicate/);
 assert.throws(()=>piTrace([...rows,{id:'orphan',type:'message',message:{role:'toolResult',toolCallId:'missing'}}]),/unmatched/);
 const zero=piTrace([{id:'zero',type:'message',message:{role:'assistant',stopReason:'error',usage:{input:0,cacheRead:0,cacheWrite:0,output:0,totalTokens:0,cost:{total:0}},content:[]}}]);assert.equal(zero.accounting.prompt_total,null);assert.equal(zero.accounting.output,null);assert.equal(zero.accounting.attempt_evidence[0].usage_evidence,'unproven-SDK-zero-default');
 assert.equal(piTrace(rows.slice(0,1)).unfinished_tool_calls,1);
});
test('candidate runner refuses before credentials or Docker',()=>{
 const r=spawnSync(process.execPath,['scripts/agent-benchmark.mjs','--check','fixtures/benchmarks/binding-discovery/v1/provenance.candidate.json'],{encoding:'utf8',env:{PATH:process.env.PATH}});
 assert.equal(r.status,1);assert.match(r.stderr,/benchmark readiness refused/);
});
test('actual observed timelines and evidence-backed subjective grading remain separate',()=>{
 const r=observationTimeline([{id:'setup',phase:'setup',clock:'monotonic',start_ms:1,end_ms:3,evidence_sha256:'a'.repeat(64)}]);assert.equal(r.phase_times_ms.setup,2);assert.equal(r.phase_times_ms.build,null);assert.equal(r.timeline[0].cpu_ms,null);
 assert.throws(()=>observationTimeline([{id:'x',phase:'setup',clock:'monotonic',start_ms:4,end_ms:1,evidence_sha256:'a'.repeat(64)}]));
 assert.equal(qualityNotes('blind-id').score,null);assert.throws(()=>qualityNotes('id',{}));
 assert.notEqual(anonymizedOutputId('final answer','a'.repeat(32)),anonymizedOutputId('final answer','b'.repeat(32)));
 assert.throws(()=>accounting([{avoidable_work:[{decision:'wasted'}]}]),/evidence/);
});
test('readiness/scoring stays unknown and obsolete cleanup flags refuse',()=>{
 assert.equal(readiness({}).ready,false);assert.equal(report({timed_out:true,oracle_pass:true}).finish,'oracle-pass-at-timeout');
 assert.equal(report({}).counters.retries,null);assert.equal(report({}).quality.scores,null);assert.equal(Object.values(rubric).reduce((a,b)=>a+b),100);assert.throws(()=>cleanupPlan({sealed:true}));
});
