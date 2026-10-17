import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createWhatsAppAdapter} from './mcp-whatsapp.mjs';
const exec=promisify(execFile);
function envelope(data){data.encoded_bytes=0;for(let i=0;i<5;i++){const text=JSON.stringify(data)+'\n';const n=Buffer.byteLength(text);if(data.encoded_bytes===n)return text;data.encoded_bytes=n;}throw Error('fixture bytes');}
test('explicit bounded name refresh follows selected binding, CLI narrowing and version refusal without replay',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'wa-refresh-'));const token_file=join(dir,'token');writeFileSync(token_file,'a'.repeat(64));let calls=0,last,old=false;
 const cid='200@s.whatsapp.net';
 const server=http.createServer((req,res)=>{let text='';req.on('data',b=>text+=b);req.on('end',()=>{calls++;last=JSON.parse(text);res.end(envelope({ok:true,account:last.account,generation:1,messages:[],conversations:[{id:cid,title:'Synthetic label',title_source:'sdk_contact_full_name',cursor:1}],posts:[],oversized_rows:[],page_version:2,names_version:1,byte_limit:4*1024*1024,order:[{cursor:1,kind:'inline',index:0}],rows_delivered:1,inline_complete:true,cursor_version:1,limit_scope:'total',scope_kind:last.account_wide?'account':'selected',next_before:0,truncated:false,source_state:{connection:'connected'},...(!old&&last.refresh_names?{name_refresh:{version:1,status:'page_refreshed_partial_coverage',checked:1,updated:1}}:{})}));});});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const b={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,connector_url:`http://127.0.0.1:${server.address().port}`,token_file,account_wide:true,operator_account_read:true,allowed_conversations:[]};
 try{
  const call=createWhatsAppAdapter(b);const page=await call('list_chats',{conversation_id:cid,refresh_names:true});assert.equal(page.name_refresh.version,1);assert.deepEqual(last.conversations,[cid]);assert.equal(last.account_wide,undefined);assert.equal(last.limit,32);
  const count=calls;for(const args of [{refresh_names:true,limit:33},{refresh_names:true,query:'label'},{refresh_names:'yes'},{account_wide:true}])await assert.rejects(call('list_chats',args));assert.equal(calls,count);
  const narrow=createWhatsAppAdapter({...b,account_wide:false,operator_account_read:false,allowed_conversations:[cid]});await assert.rejects(narrow('list_chats',{conversation_id:'300@g.us',refresh_names:true}),/not_bound/);assert.equal(calls,count);
  const profile=join(dir,'profile');writeFileSync(profile,JSON.stringify({resources:b}));const env={...process.env};for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(k))delete env[k];
  const run=await exec(process.execPath,[resolve('scripts/whatsapp-read.mjs'),'--profile-file',profile,'--list-chats','--chat',cid,'--refresh-names'],{env,timeout:10000});assert.equal(JSON.parse(run.stdout).name_refresh.version,1);assert.deepEqual(last.conversations,[cid]);
  old=true;const before=calls;await assert.rejects(call('list_chats',{refresh_names:true}),/requires_name_refresh_v1/);assert.equal(calls,before+1,'no compatibility fallback or retry');
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true});}
});
test('readiness surfaces aggregate name/hold warnings but does not globally gate eligible audio',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'wa-coverage-'));const token_file=join(dir,'token');writeFileSync(token_file,'a'.repeat(64));
 const server=http.createServer((req,res)=>{let text='';req.on('data',b=>text+=b);req.on('end',()=>{const r=JSON.parse(text);res.end(JSON.stringify(req.url==='/lookup_self'?{ok:true,account:r.account,generation:1}:{ok:true,config:{account:r.account,generation:1,all_chats:true,language:'pt',requested_on:true},connection:'connected',session_observation:{authentication:'authenticated_event_observed'},source_state:{persistence_gap:false},unknown_sends:0,audio:{blocked_source:5},coverage_status:{version:1,observed_chats:10,observed_titles:2,unobserved_titles:8,held_chats:3,historical_reason_only_holds:2}}));});});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try{
  const profile=join(dir,'profile');writeFileSync(profile,JSON.stringify({resources:{backend:'linked_device',account:'100@s.whatsapp.net',generation:1,connector_url:`http://127.0.0.1:${server.address().port}`,token_file,account_wide:true,operator_account_read:true,allowed_conversations:[]}}));
  const env={...process.env};for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(k))delete env[k];
  const run=await exec(process.execPath,[resolve('scripts/whatsapp-readiness.mjs'),'--profile-file',profile],{env,timeout:10000});const data=JSON.parse(run.stdout);assert.equal(data.ok,true);assert.equal(data.readiness_scope,'transport_and_policy_only_not_full_coverage');assert.deepEqual(data.warnings,['observed_names_partial','mutation_holds_present','historical_holds_need_item_proof']);assert.equal(data.coverage_status.held_chats,3);
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true});}
});
