import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtempSync,writeFileSync,readFileSync,copyFileSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createWhatsAppAdapter,endpoint} from './mcp-whatsapp.mjs';
import {readBinding} from './whatsapp-mcp-client.mjs';

test('one total scoped page, stable global cursor, explicit operator-wide authority; old fanout causal control',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'wa-page-review-'));const token_file=join(dir,'token');writeFileSync(token_file,'a'.repeat(64));let calls=0;
 const messages=[{id:'new',conversation_id:'400@g.us',cursor:4},{id:'b',conversation_id:'300@s.whatsapp.net',cursor:3},{id:'a2',conversation_id:'200@s.whatsapp.net',cursor:2},{id:'a1',conversation_id:'200@s.whatsapp.net',cursor:1}];
 const server=http.createServer((req,res)=>{calls++;let body='';req.on('data',b=>body+=b);req.on('end',()=>{const r=JSON.parse(body);const scoped=messages.filter(m=>(r.account_wide||r.conversations?.includes(m.conversation_id)||r.conversation_id===m.conversation_id)&&(!r.before||m.cursor<r.before));
  // Old per-chat calls get two rows each, reproducing the old aggregate-over-limit defect.
  let page=scoped.slice(0,r.limit||2);if(r.conversation_id==='300@s.whatsapp.net')page=[{id:'old1',conversation_id:r.conversation_id,cursor:30},{id:'old2',conversation_id:r.conversation_id,cursor:29}];
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify({ok:true,account:r.account,generation:r.generation,messages:page,conversations:[...new Set(page.map(m=>m.conversation_id))].map(id=>({id})),posts:[],cursor_version:1,limit_scope:'total',scope_kind:r.account_wide?'account':'selected',next_before:scoped.length>page.length?page.at(-1).cursor:0,truncated:scoped.length>page.length,source_state:{connection:'catching_up',persistence_gap:true,last_journal_observed_at:123,coverage:'partial'}}));});});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const binding={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,allowed_conversations:['200@s.whatsapp.net','300@s.whatsapp.net'],connector_url:`http://127.0.0.1:${server.address().port}`,token_file};
 try{
  const call=createWhatsAppAdapter(binding);const first=await call('read_snapshot',{limit:2});assert.equal(calls,1);assert.equal(first.messages.length,2);assert.equal(first.source_state.persistence_gap,true);assert.equal(first.messages.some(m=>m.conversation_id==='400@g.us'),false);assert.equal(first.next_before,2);
  const second=await call('read_snapshot',{limit:2,before:first.next_before});assert.deepEqual(second.messages.map(m=>m.id),['a1']);assert.equal(calls,2);
  await assert.rejects(call('read_snapshot',{account_wide:true}),/unsupported_whatsapp_argument/);assert.throws(()=>endpoint({...binding,account_wide:true}),/binding_required/);
  const wide=createWhatsAppAdapter({...binding,allowed_conversations:[],account_wide:true,operator_account_read:true});const accountPage=await wide('read_snapshot',{limit:2});assert.equal(accountPage.messages[0].id,'new');assert.equal(accountPage.messages.length,2);assert.equal(calls,3);
  const profile_file=join(dir,'operator-read.json');writeFileSync(profile_file,JSON.stringify({resources:{...binding,allowed_conversations:[],account_wide:true,operator_account_read:true}}));
  const operatorBinding=readBinding({profile_file,account:binding.account,generation:binding.generation,connector_url:binding.connector_url,token_file});assert.equal(operatorBinding.account_wide,true);assert.equal(operatorBinding.operator_account_read,true);assert.equal((await createWhatsAppAdapter(operatorBinding)('read_snapshot',{limit:2})).messages[0].id,'new');
  writeFileSync(join(dir,'old.mjs'),execFileSync('git',['show','fdc79bfc8bd78ab5e04ab3e925bb92a7dd8fffa5:scripts/mcp-whatsapp.mjs']));copyFileSync(resolve('scripts/mcp-server-core.mjs'),join(dir,'mcp-server-core.mjs'));
  const old=await import(pathToFileURL(join(dir,'old.mjs')));const before=calls;const oldPage=await old.createWhatsAppAdapter(binding)('read_snapshot',{limit:2});assert.equal(calls-before,2);assert.equal(oldPage.messages.length,4,'old version should reproduce requested-limit violation');
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true});}
});
