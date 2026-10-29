import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {createWhatsAppAdapter,createNewestReader,endpoint} from './mcp-whatsapp.mjs';
import {bytePage} from './fixtures/whatsapp-byte-envelope.mjs';

test('linked-device MCP auth/scope, no redirects, no model-send fallback',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'wa-linked-fixture-'));const token='a'.repeat(64);const token_file=join(dir,'token');writeFileSync(token_file,token,{mode:0o600});let calls=0;
 const server=http.createServer((req,res)=>{calls++;assert.equal(req.headers.authorization,'Bearer '+token);let body='';req.on('data',b=>body+=b);req.on('end',()=>{const data=JSON.parse(body);assert.equal(data.account,'100@s.whatsapp.net');assert.equal(data.generation,1);assert.deepEqual(data.conversations,['200@s.whatsapp.net']);const conversation_id=data.conversations[0];res.setHeader('Content-Type','application/json');res.end(bytePage({ok:true,account:'100@s.whatsapp.net',generation:1,messages:[{id:'fixture',conversation_id}],conversations:[{id:conversation_id}],cursor_version:1,limit_scope:'total',scope_kind:'selected',source_state:{connection:'connected',persistence_gap:false},next_before:0}));});});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const binding={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,allowed_conversations:['200@s.whatsapp.net'],connector_url:`http://127.0.0.1:${server.address().port}`,token_file};
 try{
  const call=createWhatsAppAdapter(binding);const data=await call('read_snapshot',{});assert.equal(data.messages[0].id,'fixture');assert.equal(calls,1);
  await assert.rejects(call('inspect_chat',{conversation_id:'foreign'}),/not_bound/);
  assert.equal((await call('send_message',{conversation_id:'200@s.whatsapp.net',body:'never sent',confirm:true})).pre_dispatch,true);assert.equal(calls,1);
  assert.equal((await call('download_audio',{conversation_id:'200@s.whatsapp.net',message_id:'fixture'})).ok,false);assert.equal(calls,1);
  for(const url of ['http://example.com/','https://user:secret@example.com/','https://example.com/?token=bad'])assert.throws(()=>endpoint({...binding,connector_url:url}));
  assert.throws(()=>endpoint({...binding,backend:'browser'}));assert.throws(()=>endpoint({...binding,generation:0}));
  assert.equal(readFileSync(token_file,'utf8'),token);
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true});}
});
test('read_newest closes the truncated-page and multi-identity misses',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'wa-newest-fixture-'));const token='b'.repeat(64);const token_file=join(dir,'token');writeFileSync(token_file,token,{mode:0o600});
 const conv='200@s.whatsapp.net';let mode='migrated';const NOW=Math.floor(Date.now()/1000);
 const server=http.createServer((req,res)=>{let body='';req.on('data',b=>body+=b);req.on('end',()=>{const data=JSON.parse(body);res.setHeader('Content-Type','application/json');
  const base={ok:true,account:'100@s.whatsapp.net',generation:1,cursor_version:1,limit_scope:'total',scope_kind:'selected',source_state:{connection:'connected'}};
  if(mode==='migrated'){res.end(bytePage({...base,messages:[{id:'older',conversation_id:conv,sent_at:NOW-5000,cursor:66208},{id:'newer',conversation_id:conv,sent_at:NOW-4000,cursor:66201}],conversations:[{id:conv}],truncated:true,next_before:66201}));return;}
  if(data.before){res.end(bytePage({...base,messages:[{id:'third',conversation_id:conv,sent_at:NOW-3000,cursor:3}],conversations:[{id:conv}],next_before:0}));return;}
  res.end(bytePage({...base,messages:[{id:'top',conversation_id:conv,sent_at:NOW-2000,cursor:5},{id:'second',conversation_id:conv,sent_at:NOW-1000,cursor:4}],conversations:[{id:conv}],truncated:true,next_before:4}));
 });});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const binding={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,allowed_conversations:[conv],connector_url:`http://127.0.0.1:${server.address().port}`,token_file};
 try{
  const call=createWhatsAppAdapter(binding);
  // A cursor-descending page that runs forward in time cannot be the newest page.
  await assert.rejects(call('read_snapshot',{}),/connector_page_not_newest/);
  assert.equal((await call('read_snapshot',{sent_since:1})).messages.length,2);
  mode='paged';
  const newest=createNewestReader(call);
  const answer=await newest({conversation_id:conv,n:3});
  assert.deepEqual(answer.messages.map(m=>m.sent_at),[NOW-1000,NOW-2000,NOW-3000]);
  assert.equal(answer.pages_read,2);assert.equal(answer.complete,true);assert.ok(answer.searched_since>0);assert.equal(answer.window_days,30);
  await assert.rejects(newest({}),/newest_needs_conversation_or_query/);
  await assert.rejects(newest({conversation_id:conv,n:51}),/invalid_newest_count/);
  await assert.rejects(newest({conversation_id:conv,scan_days:0}),/invalid_newest_window/);
  await assert.rejects(newest({conversation_id:'foreign',n:2}),/not_bound/);
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true});}
});
test('read_newest cannot be fooled by a renamed or dual-identity thread',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'wa-newest-wide-'));const token='c'.repeat(64);const token_file=join(dir,'token');writeFileSync(token_file,token,{mode:0o600});
 const named='200@s.whatsapp.net',hidden='300@lid';const NOW=Math.floor(Date.now()/1000);
 const server=http.createServer((req,res)=>{let body='';req.on('data',b=>body+=b);req.on('end',()=>{const data=JSON.parse(body);res.setHeader('Content-Type','application/json');
  const base={ok:true,account:'100@s.whatsapp.net',generation:1,cursor_version:1,limit_scope:'total',source_state:{connection:'connected'}};
  if(req.url==='/list_chats'){const chat={id:named,conversation_id:named,title:'Laura <3',cursor:1};res.end(bytePage({...base,scope_kind:'account',messages:[chat],conversations:[chat],next_before:0}));return;}
  if(data.conversations){res.end(bytePage({...base,scope_kind:'selected',messages:[],conversations:[],next_before:0}));return;}
  res.end(bytePage({...base,scope_kind:'account',messages:[{id:'hidden-hit',conversation_id:hidden,sent_at:NOW-60,cursor:9}],conversations:[],next_before:0}));
 });});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const binding={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,account_wide:true,operator_account_read:true,allowed_conversations:[named],connector_url:`http://127.0.0.1:${server.address().port}`,token_file};
 try{
  const call=createWhatsAppAdapter(binding);const newest=createNewestReader(call,{wide:true});
  const answer=await newest({query:'Laura',n:5,scan_days:1});
  assert.equal(answer.messages.length,1);assert.equal(answer.messages[0].conversation_id,hidden);assert.equal(answer.account_wide_scan,true);
  const hiddenThread=answer.threads.find(t=>t.id===hidden);assert.ok(hiddenThread&&hiddenThread.matched===false&&hiddenThread.rows===1);
  const namedThread=answer.threads.find(t=>t.id===named);assert.ok(namedThread&&namedThread.matched===true&&namedThread.rows===0);
  assert.equal(answer.rows_seen,1);assert.equal(answer.complete,true);
  const scoped=await newest({conversation_id:named,n:5,scan_days:1});
  assert.equal(scoped.rows_seen,0,'an explicit conversation must not pull other threads in');assert.equal(scoped.account_wide_scan,true);
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true});}
});
test('the WhatsApp MCP server is never registered with a send tool',()=>{
 assert.match(readFileSync('lua/core/mcp.lua','utf8'),/whatsapp_send_uses_operator_route/);
});
