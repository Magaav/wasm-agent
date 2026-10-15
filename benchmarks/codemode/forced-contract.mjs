import fs from 'node:fs';
import assert from 'node:assert/strict';
export const forcedScope='forced-codemode-parallel';
export const codemodeFunction={name:'codemode',description:'Execute JavaScript in an isolated VM to call approved task tools. Use await tools.<name>(args), text(value), return, searchTools and describeTool. Tool permissions, workspace, schema and effect checks apply to every nested call. No ambient filesystem, network, process or implicit model API. Effectful calls are serial; unawaited calls are not admitted.',parameters:{type:'object',properties:{code:{type:'string'},timeout_ms:{type:'integer',minimum:1,maximum:300000}},required:['code'],additionalProperties:false}};
export const codemodeSchema={type:'function',function:codemodeFunction};
export const routingAppendix='\n\nBenchmark routing condition (common to all contestants): all task tool work MUST use codemode JavaScript VM execution. Direct outer task tools, discovery and routed-tool calls are unavailable and refused. Use describeTool(name) for exact schemas and await tools.name(args) for operations; text(value) emits selected results. Files and shell use the isolated Linux workspace /tmp/work. Do not claim completion without doing the requested work. This routing appendix does not modify the original task instruction files.';
export const adaptedLabels={'pi':'Pi 1.2 + benchmark Node QuickJS-WASI adapter','wasm-current':'historical b384 wasm + benchmark Node QuickJS-WASI adapter','node-v1':'candidate wasm + Node V1','rust-v2':'candidate wasm + native Rust/Wasmtime V2'};
export const expectedBackend=arm=>arm==='rust-v2'?'rust-wasmtime-quickjs-wasi':'node-quickjs-wasi-reference';
// Input is private host-written evidence, never a string extracted from model/JS output.
export function verifyVmJournal(bytes,{arm,binding,session,complete=true}={}){
 const rows=bytes.toString().trim().split('\n').filter(Boolean).map(x=>JSON.parse(x));
 assert(rows.length&&complete,'missing/incomplete VM trace');let outer=0,nested=0,open=null,pending=null,starts=0,closes=0,vm=null,owner=null,queued=[],lastNested=null;const counts={};const sessions=new Set();
 const vmSources=new Map();
 for(const [i,r]of rows.entries()){
  assert(r.seq===i+1&&r.arm===arm&&r.binding===binding,'VM receipt sequence/arm binding');
  assert(r.type!=='bypass','outer task-tool bypass attempt');
  if(r.type==='outer'){assert(open===null&&r.invocation===++outer,'outer invocation ordering');open=r.invocation;vmSources.set(open,r.args.code);sessions.add(r.session);starts=0;closes=0;vm=null;owner=null;queued=[];lastNested=null;}
  else {assert(open!==null&&r.invocation===open,'VM invocation binding');
   if(r.type==='host'){
    if(r.action==='start'){assert(r.result.ok&&r.result.id&&r.result.backend===expectedBackend(arm),'actual VM host identity');assert(starts===0&&r.args.code===vmSources.get(open)&&/^[a-f0-9]{64}$/.test(r.args.owner),'VM source/owner');vm=r.result.id;owner=r.args.owner;starts++;}
    else assert(r.args.id===vm&&r.args.owner===owner,'host VM scope/identity');
    if(r.action==='deliver'){const call=queued.shift();assert(call&&call.id===r.args.call_id,'VM call/result ordering');if(call.target==='tool'){assert(lastNested&&lastNested.name===call.name&&lastNested.arguments===call.args,'nested result identity');assert.deepEqual(JSON.parse(r.args.payload),lastNested.result,'nested result not delivered faithfully');lastNested=null;}}
    for(const e of r.result.events??[])if(e.type==='call')queued.push(e);
    if(r.action==='close'){assert(r.result.ok,'VM close');closes++;}
   }else if(r.type==='nested_start'){assert(starts===1&&!pending&&queued.length&&((queued[0].target==='tool'&&queued[0].name===r.name&&queued[0].args===r.arguments)||(queued[0].target==='global'&&queued[0].name==='searchTools'&&r.name==='tool_search')),'nested call outside VM/overlap');pending=r.name;lastNested={name:r.name,arguments:r.arguments};}
   else if(r.type==='nested_end'){assert(pending===r.name&&r.ok,'nested outcome unknown');pending=null;lastNested.result=r.result;assert(!(r.result?.effect==='unknown'),'unknown nested effect');if(!r.result?.error&&r.result?.ok!==false){nested++;counts[r.name]=(counts[r.name]??0)+1;}}
   else if(r.type==='outer_end'){assert(starts===1&&closes===1&&!pending&&queued.length===0&&r.result?.ok,'incomplete/failed VM invocation');open=null;}
   else assert.fail('unknown VM receipt');
  }
 }
 assert(open===null&&sessions.size===1&&(!session||sessions.has(session)),'incomplete/session-mixed VM trace');
 assert(outer>0&&nested>0&&Object.keys(counts).some(x=>['read','read_many','write','edit','bash','ls','grep'].includes(x)),'zero/meaningless VM use');
 return {used:true,verified:true,arm,binding,session:[...sessions][0],backend:expectedBackend(arm),guest_sha256:'d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9',prelude_sha256:'57c8dc8c0e812117d82167fa751bc368f249d5aaee56d321066fc5280c785281',outer_vm_calls:outer,nested_task_calls:nested,nested:counts};
}
export function readVmJournal(file,options){return verifyVmJournal(fs.readFileSync(file),options);}
