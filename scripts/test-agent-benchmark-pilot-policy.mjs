// Pure admission validation; synthetic references here NEVER authorize/run trials.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import crypto from 'node:crypto';import {checkPilotManifest,runApprovedPilot,runApprovedPiPilot,proposedLimits} from './agent-benchmark-pilot.mjs';
if(process.argv[2]==='--capture'){
 const {openPiEvidence,verifyPiEvidence,durablePiResult}=await import('../benchmarks/codemode/pi-evidence.mjs');
 const {createGeneration,containedProcess}=await import('./agent-benchmark-results.mjs');
 const [binary,out]=process.argv.slice(3);assert(path.isAbsolute(binary)&&path.isAbsolute(out)&&!fs.existsSync(out));fs.mkdirSync(out);let checks=0;
 const events=path.join(out,'events.jsonl'),writer=openPiEvidence(events);const expected=[];
 for(let i=0;i<160;i++){const event={type:'message_update',message:{content:'x'.repeat(i*1024)}};expected.push(JSON.stringify({event})+'\n');writer.append(event);}
 writer.append({type:'tool_result',result:'later-tool-preserved'});expected.push(JSON.stringify({event:{type:'tool_result',result:'later-tool-preserved'}})+'\n');writer.append({type:'reply',text:'final-handoff-preserved'});expected.push(JSON.stringify({event:{type:'reply',text:'final-handoff-preserved'}})+'\n');
 const proof=writer.close(),bytes=Buffer.from(expected.join(''));assert(bytes.length>8388608);checks++;assert.deepEqual(fs.readFileSync(events),bytes);checks++;assert.equal(proof.sha256,crypto.createHash('sha256').update(bytes).digest('hex'));checks++;verifyPiEvidence(events,proof);checks++;assert.throws(()=>writer.append({}),/closed/);checks++;assert.throws(()=>openPiEvidence(events),/EEXIST/);checks++;
 // Inject real filesystem partial writes plus failed write/fsync/close. Retain
 // each partial file; no fake successful evidence receipt and no retry/replay.
 for(const failure of ['writeSync','fsyncSync','closeSync']){
  let calls=0;const io={...fs,[failure](...args){calls++;if(failure==='closeSync')fs.closeSync(...args);throw Error('injected '+failure);}};
  const journal=openPiEvidence(path.join(out,failure+'.jsonl'),io);
  if(failure==='closeSync'){journal.append({failure});assert.throws(()=>journal.close(),/injected/);}else{assert.throws(()=>journal.append({failure}),/injected/);assert.throws(()=>journal.close(),/injected/);}
  assert(calls>=1);checks+=2;
 }
 const short=openPiEvidence(path.join(out,'short.jsonl'),{...fs,writeSync:(fd,b,o,n)=>fs.writeSync(fd,b,o,Math.min(n,3))});short.append({exact:'multibyte-π'});verifyPiEvidence(path.join(out,'short.jsonl'),short.close());checks++;
 durablePiResult(path.join(out,'failed-result.json'),{ok:false,messages:[{stopReason:'aborted',usage:null}],event_evidence:null,error:'synthetic write failure; no replay'});assert.throws(()=>verifyPiEvidence(events,null),/incomplete/);checks++;
 const root=path.join(out,'overflow');createGeneration(root,'old-console-overflow-negative-control');const script=path.join(out,'old-console.cjs');fs.writeFileSync(script,'process.stdout.write('+JSON.stringify(bytes.toString())+');');
 const receipt=await containedProcess(root,binary,process.execPath,[script],{cwd:path.resolve('.'),luaRoot:path.resolve('.'),timeout_seconds:30});assert.equal(receipt.error,'output_limit_exceeded');assert.equal(receipt.output_complete,false);assert.equal(fs.statSync(receipt.stdout_path).size,8388608);assert(receipt.settled);checks+=4;
 fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify({ok:true,checks,skipped:0,proof,overflow:{error:receipt.error,bytes:fs.statSync(receipt.stdout_path).size,output_complete:receipt.output_complete,settled:receipt.settled},paid_solver_calls:0}));console.log(JSON.stringify({ok:true,checks,skipped:0,paid_solver_calls:0}));
}else{
const [manifest,out]=process.argv.slice(2);assert(manifest&&path.isAbsolute(manifest)&&out&&path.isAbsolute(out)&&!fs.existsSync(out));fs.mkdirSync(out);const bytes=fs.readFileSync(manifest),sha=crypto.createHash('sha256').update(bytes).digest('hex');let checks=0,calls=0;const original=globalThis.fetch;globalThis.fetch=async()=>{calls++;throw Error('test forbids all network');};
try{assert.throws(()=>checkPilotManifest(manifest,'wrong',null),/human-approved/);checks++;assert.throws(()=>checkPilotManifest(manifest,sha,null),/human approval reference/);checks++;await assert.rejects(runApprovedPilot(manifest,path.join(out,'must-not-exist'),'wrong',null),/human-approved/);checks++;assert(!fs.existsSync(path.join(out,'must-not-exist')));checks++;assert(!fs.existsSync(path.join(path.dirname(manifest),'launch-intent.json')));checks++;
 const copy=path.join(out,'manifest-copy.json');fs.writeFileSync(copy,bytes);assert.throws(()=>checkPilotManifest(copy,sha,null),/copies/);checks++;assert.equal(proposedLimits.attemptsPerArm,1);assert.equal(proposedLimits.maxRequests,120);assert.equal(proposedLimits.maxPromptTotal,20000000);assert.equal(proposedLimits.maxOutputTotal,120000);assert.equal(proposedLimits.maxMilliseconds,2700000);checks+=5;assert.equal(calls,0);checks++;
 const m=JSON.parse(bytes);if(process.argv[4]==='--pi-only'){
  const approval={session_id:'SYNTHETIC-NEGATIVE-CONTROLS-NOT-A-GRANT',message_id:'SYNTHETIC-NO-LIVE-LAUNCH',manifest_sha256:sha};
  assert.deepEqual(checkPilotManifest(manifest,sha,approval,'pi-only').arms,['pi']);checks++;
  assert.throws(()=>checkPilotManifest(manifest,sha,approval),/scope\/limits/);checks++;
  const root=path.join(out,'synthetic-plan');fs.mkdirSync(root);const file=path.join(root,'manifest.json');
  async function negative(change,pattern,run=false){const x=structuredClone(m);x.reservation_root=root;change(x);const b=JSON.stringify(x),s=crypto.createHash('sha256').update(b).digest('hex'),a={...approval,manifest_sha256:s};fs.writeFileSync(file,b);if(run)await assert.rejects(runApprovedPiPilot(file,path.join(out,'never-launch'),s,a),pattern);else assert.throws(()=>checkPilotManifest(file,s,a,'pi-only'),pattern);checks++;assert(!fs.existsSync(path.join(out,'never-launch')));}
  for(const key of ['maxRequests','maxPromptTotal','maxOutputTotal','maxMilliseconds','maxRequestMilliseconds','automaticTrialRetries'])await negative(x=>x.limits[key]++,/scope\/limits/);
  await negative(x=>x.arms.push('wasm-current'),/scope\/limits/);await negative(x=>x.order.push('rust-v2'),/scope\/limits/);await negative(x=>x.reasoning='medium',/scope\/limits/);await negative(x=>x.model='other',/scope\/limits/);await negative(x=>{x.id='binding-discovery-four-arm-pilot';x.arms=x.order=['pi','wasm-current','node-v1','rust-v2'];},/scope\/limits/);
  await negative(x=>x.pins.sources['benchmarks/codemode/pilot-pi.mjs']='0'.repeat(64),/source drift/);
  fs.writeFileSync(path.join(root,'launch-intent.json'),JSON.stringify({state:'synthetic consumed/unknown; no replay'}));await negative(()=>{},/existing\/unknown launch intent/,true);
  assert.equal(calls,0);checks++;assert(!fs.existsSync(path.join(path.dirname(manifest),'launch-intent.json')));checks++;
 }
 fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify({ok:true,checks,skipped:0,network_calls:0,live_calls_authorized:false,manifest_sha256:sha}));console.log(JSON.stringify({ok:true,checks,skipped:0,network_calls:0,live_calls_authorized:false}));
}finally{globalThis.fetch=original;}
}
