#!/usr/bin/env node
// Read-only complete inventory of each requested legacy original. A match is
// typed as evidence or a lead; absent ledger/provenance never becomes no-effect.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {DatabaseSync} from 'node:sqlite';
const [data,seed,output]=process.argv.slice(2);const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const prior=JSON.parse(fs.readFileSync(seed,'utf8')),originals=prior.originals || prior.operations.unsafe_manual_settlements;
const ids=new Set(originals.map(x=>x.id)),matches=new Map([...ids].map(id=>[id,[]])),leads=new Map([...ids].map(id=>[id,[]]));
const db=new DatabaseSync(path.join(data,'memory.db'),{readOnly:true});
try {
 const tools=db.prepare("SELECT id,session_id,seq,tool_call_id,tool_name,content FROM messages WHERE role='tool'").all();
 for(const row of tools) {
  let value;try{value=JSON.parse(row.content);}catch{continue;}
  let artifact;
  if(value.full_result?.sha256){const file=path.join(data,'tool-results',value.full_result.sha256+'.txt');if(fs.existsSync(file)){const bytes=fs.readFileSync(file);if(hash(bytes)===value.full_result.sha256){try{value=JSON.parse(bytes);artifact={path:file,sha256:hash(bytes)};}catch{}}}}
  if(!ids.has(value.operation_id))continue;
  const calls=db.prepare("SELECT id,tool_calls FROM messages WHERE session_id=? AND seq<? AND tool_calls!='[]' ORDER BY seq DESC LIMIT 8").all(row.session_id,row.seq).flatMap(r=>{try{return JSON.parse(r.tool_calls);}catch{return [];}}).filter(c=>c.id===row.tool_call_id);
  matches.get(value.operation_id).push({kind:'exact_tool_result_operation_id',message_id:row.id,session:row.session_id,call_id:row.tool_call_id,calls,result:value,artifact});
 }
 for(const file of fs.readdirSync(path.join(data,'tool-results'))) {
  const full=path.join(data,'tool-results',file);if(!fs.statSync(full).isFile())continue;const bytes=fs.readFileSync(full),text=bytes.toString();
  for(const id of new Set(text.match(/op-[A-Za-z0-9-]+/g)||[]))if(ids.has(id))leads.get(id).push({kind:'artifact_mention_not_execution_binding',path:full,sha256:hash(bytes)});
 }
 const model=db.prepare("SELECT seq,session_id,run_id,payload FROM harness_events WHERE kind='model_call'").all();const byPid=new Map();
 for(const row of model){let p;try{p=JSON.parse(row.payload);}catch{continue;}const identity=p.runtime?.native;if(identity?.process_id){const entries=byPid.get(identity.process_id)||[];entries.push({event:row.seq,session:row.session_id,run:row.run_id,identity,source_hash:p.runtime.source_hash,sources:p.runtime.sources});byPid.set(identity.process_id,entries);}}
 const rows=originals.map(old=>{
  const id=old.id,directory=path.join(data,'operations',id),originalPaths=fs.readdirSync(directory).filter(name=>name.startsWith('state.json.before-reconcile-')).map(name=>{const file=path.join(directory,name),bytes=fs.readFileSync(file);return {path:file,sha256:hash(bytes),state:JSON.parse(bytes)};});
  const bytes=fs.readFileSync(path.join(directory,'state.json')),pid=Number(id.split('-')[2]);
  return {id,pid_legacy_only:pid,current:{sha256:hash(bytes),state:JSON.parse(bytes)},originals:originalPaths,exact_ledger:matches.get(id),artifact_leads:leads.get(id),source_leads:byPid.get(pid)||[],stable_identity_verified:false,
    blocker:'independent original creation/boot/containment and positive drain provenance still required; PID/source/artifact mention is not sufficient'};
 });
 fs.writeFileSync(output,JSON.stringify({schema:1,read_only:true,rows,summary:{requested:ids.size,exact_ledger:rows.filter(r=>r.exact_ledger.length).length,artifact_leads:rows.filter(r=>r.artifact_leads.length).length,source_leads:rows.filter(r=>r.source_leads.length).length,stable_identity_verified:0}},null,2)+'\n',{flag:'wx'});
 console.log(JSON.stringify({ok:true,report:output,records:rows.length,original_outcomes:'unknown preserved'}));
}finally{db.close();}
