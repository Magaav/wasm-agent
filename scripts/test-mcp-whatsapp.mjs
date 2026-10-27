import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import http from 'node:http';
import {spawnSync} from 'node:child_process';
import {createWhatsAppAdapter,createNewestReader,endpoint} from './mcp-whatsapp.mjs';
import {bytePage} from './fixtures/whatsapp-byte-envelope.mjs';
import {plan,retire,hash,definition} from './whatsapp-retire.mjs';

test('linked-device MCP auth/scope, no redirects, no browser or model-send fallback',async()=>{
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
test('retirement check/apply is exact, preserves histories and refuses drift/unowned artifacts',async()=>{
 let jobs=[{id:'whatsapp-copilot',name:'fixture',revision:21,enabled:true,queued:0,trigger:{kind:'schedule',every_seconds:30},action:{kind:'run',script:'/fixture/whatsapp-source-ensure.sh'}}];
 const manifest={schema:1,owner:'wasm-agent-whatsapp',account:'100@s.whatsapp.net',jobs:[{id:jobs[0].id,revision:21,definition_sha256:hash(definition(jobs[0]))}],files:[],blockers:['task_process_identity_unverified']};let disabled=0;
 const driver={list:()=>structuredClone(jobs),disable:id=>{assert.equal(id,'whatsapp-copilot');disabled++;jobs[0].enabled=false;jobs[0].revision++;}};
 assert.equal((await retire(manifest,driver)).dry_run,true);assert.equal(disabled,0);
 assert.throws(()=>plan({...manifest,jobs:[{...manifest.jobs[0],revision:20}]},jobs),/mismatch/);
 assert.throws(()=>plan({...manifest,jobs:[{...manifest.jobs[0],id:'unrelated'}]},jobs),/unowned/);
 const result=await retire(manifest,driver,true);assert.equal(disabled,1);assert.equal(result.activation_authorized,false);assert.ok(result.preserved.includes('unknown sends'));assert.deepEqual(result.blockers,['task_process_identity_unverified']);
 await assert.rejects(retire(manifest,driver,true),/mismatch/);assert.equal(disabled,1);
});
test('retired CLI entrypoints cannot start Chrome, repair a trigger, or send even with old flags',()=>{
 for(const file of ['whatsapp-audio.mjs','whatsapp-store-send.mjs','whatsapp-trigger.mjs','whatsapp-adapter.mjs']){
  const result=spawnSync(process.execPath,[resolve('scripts',file),'--mcp-backend','--raw-store','--send'],{encoding:'utf8',timeout:5000});assert.equal(result.status,1,file);assert.match(result.stdout,/retired/);
 }
 const reader=spawnSync(process.execPath,[resolve('scripts/whatsapp-read.mjs'),'--raw-store'],{encoding:'utf8',timeout:5000});assert.equal(reader.status,1);assert.match(reader.stdout,/retired/);
 for(const file of ['whatsapp-source-ensure.sh','whatsapp-preflight.sh','whatsapp-transcribe.sh','whatsapp-ingest.sh','whatsapp-ingest-emit.sh','whatsapp-copilot-read.sh']){const source=readFileSync(resolve('scripts',file),'utf8');assert.match(source,/exit 1/);assert.doesNotMatch(source,/taskkill|schtasks|curl|9222|wa-sentinel|WA_SCRIPT/);}
});
test('private task XML dry run verifies ownership/hash and can never apply a fixture',t=>{
 if(process.platform!=='win32'){t.skip('Windows PowerShell fixture runtime unavailable');return;}
 const dir=mkdtempSync(join(tmpdir(),'wa-retire-task-'));try{
  const wrapper=join(dir,'whatsapp-chrome.cmd');writeFileSync(wrapper,'synthetic owned wrapper');
  const xml='<Task><Principals><Principal><UserId>S-1-5-21-fixture</UserId></Principal></Principals><Actions><Exec><Command>cmd.exe</Command><Arguments>fixture-wrapper</Arguments></Exec></Actions></Task>';
  const xmlPath=join(dir,'task.xml'),manifestPath=join(dir,'manifest.json');writeFileSync(xmlPath,xml);
  const manifest={schema:1,owner:'wasm-agent-whatsapp',task_name:'wasm-agent-whatsapp-chrome',xml_sha256:hash(xml),principal_sid:'S-1-5-21-fixture',command:'cmd.exe',arguments:'fixture-wrapper',wrapper_path:wrapper,wrapper_sha256:hash(readFileSync(wrapper))};writeFileSync(manifestPath,JSON.stringify(manifest));
  const run=extra=>spawnSync('powershell.exe',['-NoProfile','-File',resolve('scripts/whatsapp-retire-task.ps1'),'-Manifest',manifestPath,'-FixtureXml',xmlPath,...extra],{encoding:'utf8',timeout:10000});
  const result=run([]);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).activation_authorized,false);
  assert.notEqual(run(['-Apply']).status,0);
  writeFileSync(wrapper,'changed');assert.notEqual(run([]).status,0);
  assert.equal(readFileSync(xmlPath,'utf8'),xml);
 }finally{rmSync(dir,{recursive:true});}
});

test('default-off templates and scoped Lua guard retain generic MCP denial',()=>{
 const job=JSON.parse(readFileSync('jobs/whatsapp-copilot.json'));assert.equal(job.action.kind,'run');assert.match(job.name,/retired/);assert.doesNotMatch(JSON.stringify(job),/foreach|subagent|transcribe/);
 const profile=JSON.parse(readFileSync('jobs/profiles/whatsapp-responder.json'));assert.equal(profile.resources.language,'en');assert.equal(profile.resources.send_path,'linked_device');assert.equal(profile.resources.send_approved,false);assert.ok(!profile.allowed_tools.includes('whatsapp_send'));
 assert.match(readFileSync('lua/core/mcp.lua','utf8'),/whatsapp_send_requires_scoped_facade/);
 assert.match(readFileSync('lua/core/whatsapp.lua','utf8'),/general_send_refused_draft_visibility_unsupported/);
});
