#!/usr/bin/env node
// External acceptance: this file stays outside solver workspaces.
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const root=path.resolve(process.argv[2]||'');
let checks=0,seq=0;
const check=fn=>{fn();checks++;};
const event=(span,kind,phase,payload)=>({id:'e'+(++seq),seq,session_id:'s',run_id:'r',span_id:span,kind,phase,payload});
try {
  if(!process.argv[2]) throw Error('candidate root required');
  const {audit}=require(path.join(root,'scripts/lib/token-audit.cjs'));
  for(const payload of [[], '[]', {}, '{}']) {
    const rows=[event('run','run','start',payload),event('run','run','end',{ms:7})];
    const original=JSON.stringify(rows);
    check(()=>assert.equal(audit(rows).timing.run_ms.p50,7));
    check(()=>assert.equal(JSON.stringify(rows),original));
  }
  for(const payload of [[], '[]']) {
    const r=audit([event('missing','model_call','start',payload),event('missing','model_call','end',payload)]);
    check(()=>assert.equal(r.usage.missing_usage,1));
    check(()=>assert.equal(r.usage.recorded_calls_cost_usd,null));
  }
  for(const payload of [[{}], '[{}]', null, 'null', true, 'true', 2, '2', 'bad-json'])
    check(()=>assert.throws(()=>audit([event('invalid','run','start',payload)]),/invalid_event_payload/));
  const empty=event('duplicate','run','start',[]),end=event('duplicate','run','end',{ms:2});
  check(()=>assert.equal(audit([empty,{...empty,payload:'[]'},end]).duplicate_events,1));
  check(()=>assert.throws(()=>audit([empty,{...empty,payload:{changed:1}},end]),/conflicting_duplicate_event/));
  const started=event('reverse','run','start',[]),finished=event('reverse','run','end',{ms:1});
  check(()=>assert.throws(()=>audit([{...started,seq:finished.seq+1},finished]),/inconsistent_span_boundaries/));
  const sample=[event('cli','run','start','[]'),event('cli','run','end',{ms:11})];
  const input=path.join(root,'oracle-input.json');
  if(fs.existsSync(input)) throw Error('oracle input path already exists');
  const text=JSON.stringify({events:sample});
  fs.writeFileSync(input,text,{flag:'wx'});
  try {
    const run=spawnSync(process.execPath,[path.join(root,'scripts/audit-tokens.cjs'),input],{cwd:root,encoding:'utf8',timeout:10000});
    check(()=>assert.equal(run.status,0,run.stderr));
    check(()=>assert.equal(JSON.parse(run.stdout).timing.run_ms.p50,11));
    check(()=>assert.equal(fs.readFileSync(input,'utf8'),text));
  } finally {fs.unlinkSync(input);}
  const regressions=spawnSync(process.execPath,[path.join(root,'scripts/test-token-audit.cjs')],{cwd:root,encoding:'utf8',timeout:10000});
  check(()=>assert.equal(regressions.status,0,regressions.stderr));
  console.log(JSON.stringify({ok:true,pass:true,checks,skipped:0,oracle:'telemetry-empty-payload',scope:'behavior and existing regressions, not patch resemblance'}));
} catch(error) {
  console.log(JSON.stringify({ok:false,pass:false,checks,skipped:0,error:error.message}));process.exitCode=1;
}
