// Read-only, source/artifact-bound sealed proof/result verification. No process,
// Docker, provider, credential, reservation or cleanup effects.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {fileURLToPath} from 'node:url';
import {runtimePins,sha} from './agent-benchmark-pilot-pins.mjs';import {verifyBundle,readSealedRecord} from './agent-benchmark-results.mjs';import {forcedScope,verifyVmJournal,codemodeFunction} from '../benchmarks/codemode/forced-contract.mjs';
const address=p=>p.replaceAll('\\','/').replace(/^records\//,'');
export function verifyForcedProof(config,out,{live=false,negative=false}={}){
 const root=path.join(out,'g'),r=JSON.parse(fs.readFileSync(path.join(out,'receipt.json'))),bundle=verifyBundle(root),owner=JSON.parse(fs.readFileSync(path.join(root,'owner.json')));
 assert(r.ok&&r.scope===(negative?forcedScope+'-negative':forcedScope)&&r.bundle.sha256===bundle.sha256,'scope/archive receipt');assert.deepEqual(r.pins,runtimePins(config),'current execution source/artifact drift');
 const read=name=>readSealedRecord(root,address(name));const manifest=JSON.parse(read('manifest.json'));assert.deepEqual(manifest.pins,r.pins);assert.deepEqual(manifest.results,r.results,'receipt not same as sealed results');
 assert(r.cleanup.ok&&r.removed.every(x=>x.settled&&x.absent)&&owner.docker_resources.every(x=>x.state==='removed'),'owned cleanup incomplete');assert(owner.processes.every(x=>x.state==='closed'&&x.process_tree==='settled'),'actor/process-tree unsettled');
 assert(r.results.length===4&&new Set(r.results.map(x=>x.arm)).size===4,'four arm results');
 const overlap=Math.min(...r.results.map(x=>x.solver_ended_at))-Math.max(...r.results.map(x=>x.solver_started_at));assert(overlap>0,'no actual four-actor overlap');
 const lastActor=Math.max(...r.results.map(x=>x.actor_settled_at)),lastWriter=Math.max(...r.results.map(x=>x.writer_drained_at));assert(r.results.every(x=>x.writer_drained_at>=lastActor&&x.capture_started_at>=lastWriter),'capture before all actor/writer settlements');if(live)assert(r.results.every(x=>x.grade_started_at>=Math.max(...r.results.map(x=>x.lifecycle_settled_at))),'grader competed with timed actors');
 const verdicts=[];
 for(const result of r.results){
  const bytes=read(result.vm_journal);let vm=null,error=null;try{vm=verifyVmJournal(bytes,{arm:result.arm,binding:result.binding,complete:result.normal_exit&&result.process_settled});}catch(e){error=e.message;}
  if(negative){assert(!vm&&error,'negative control cannot receive verified use');assert(result.vm_use.verified===false);}
  else if(!live){assert(vm&&result.finished,error??'qualification handoff incomplete');assert.deepEqual(vm,result.vm_use);assert(vm.outer_vm_calls===5&&vm.nested_task_calls===5&&vm.nested.read===2&&['read','write','edit','bash'].every(n=>vm.successful_nested[n]===1),'actual expected nested work');}
  const attempts=r.journal.attempts.filter(a=>a.arm===result.arm&&a.upstream_dispatched),usage=r.journal.complete&&attempts.length>0&&attempts.every(a=>a.usage!==null);
  verdicts.push({arm:result.arm,handoff:result.finished,vm_use:!!vm,usage,acceptance:result.grade?.pass??null,valid_treatment:!negative&&!!vm&&result.finished&&usage,error});
  for(const blob of result.changeset_evidence??[]){const entry=owner.records.find(e=>e.path===address(blob.path));assert(entry?.sha256===blob.sha256&&entry.bytes===blob.bytes&&entry.path.endsWith('/'+blob.sha256),'changeset content address/archive identity');}
 }
 const prepared=live?r.journal.attempts.filter(a=>a.prepared):null;
 const requests=live?null:JSON.parse(read('requests.json'));
 if(requests){assert(requests.length===(negative?20:24));for(const x of requests){const body=x.body;assert(body.input.filter(x=>x.type==='function_call_output').every(x=>Buffer.byteLength(x.output)<=51200),'50KiB model view');assert(body.tools.length===1&&body.tools[0].name==='codemode'&&body.tools[0].description===codemodeFunction.description);assert.deepEqual(body.tools[0].parameters,codemodeFunction.parameters);assert(r.journal.attempts.some(a=>a.arm===x.arm&&a.prepared?.sha256===sha(Buffer.from(JSON.stringify(body)))),'prepared request not bound to route capture');if(!negative)assert(body.input.filter(x=>x.type==='function_call').every(x=>x.name==='codemode'),'outer routed/direct bypass');}}
 else for(const a of prepared){const b=JSON.parse(read('route/'+a.prepared.name));assert(b.tools?.length===1&&b.tools[0].name==='codemode');assert.deepEqual(b.tools[0].parameters,codemodeFunction.parameters);}
 const unavailable=JSON.parse(read('rust-v2/node-unavailable.json'));assert(unavailable.error==='ENOENT','V2 Node-absent proof');const copiedRg=owner.records.find(x=>x.path==='rust-v2/h/t/rg.exe'||x.path==='rust-v2/h/t/rg');assert(copiedRg?.sha256===unavailable.rg_copy_sha256&&!owner.records.some(x=>x.path.startsWith('rust-v2/h/.wasm-agent/bin/')),'existing copied rg only; no runtime provisioning');const nativeConfig=JSON.parse(read('rust-v2/config.json'));assert(nativeConfig.forced&&!nativeConfig.reference_url&&!nativeConfig.reference_client,'V2 no Node reference bridge/fallback');
 const pi=r.results.find(x=>x.arm==='pi');const raw=read(pi.events_file);assert(raw.length===pi.event_evidence.bytes&&sha(raw)===pi.event_evidence.sha256&&raw.toString().split('\n').length-1===pi.event_evidence.count,'lossless Pi raw journal');
 const state=JSON.parse(read('pi/pi-result.json'));if(!negative&&!live){assert(raw.length>8388608&&state.messages.filter(x=>x.role==='toolResult').length===5&&JSON.stringify(state.messages.at(-1)).includes('qualification completed'),'later results/final after >8MiB raw stream');}
 return {ok:true,scope:r.scope,current_source_match:true,lossless_archives:true,cleaned:true,overlap_ms:overlap,verdicts,paid_solver_calls:live?null:0,real_provider_acceptance:live?null:false};
}
if(process.argv[1]===fileURLToPath(import.meta.url)){const [config,out,flag]=process.argv.slice(2);assert(!flag||['--live','--negative'].includes(flag));console.log(JSON.stringify(verifyForcedProof(JSON.parse(fs.readFileSync(config)),path.resolve(out),{live:flag==='--live',negative:flag==='--negative'})));}
