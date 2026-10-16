// Actual unpaired Go/SQLite + actual MCP stdio/HTTP. Synthetic data only, OFF throughout.
import assert from 'node:assert/strict';
import {spawn,spawnSync,execFileSync} from 'node:child_process';
import {mkdirSync,readFileSync,writeFileSync,copyFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import net from 'node:net';
import http from 'node:http';
import {createHash} from 'node:crypto';
import {createWhatsAppAdapter,connectorRequest} from './mcp-whatsapp.mjs';
import {requestMCP} from './mcp-client-core.mjs';
const [candidate,oldBinary,output,waBinary]=process.argv.slice(2).map(v=>resolve(v));if(!output)throw Error('usage: <new-exe> <old-clean-exe> <fresh-output>');
mkdirSync(output);const sha=b=>createHash('sha256').update(b).digest('hex');assert.equal(sha(readFileSync(oldBinary)),'71289cf07189159be5ee29233214adca489019151672c8d9d41dcf395f5e3c59');
const python=process.env.WA_TEST_PYTHON;if(!python)throw Error('absolute WA_TEST_PYTHON required');
const seed=(mode,state)=>{const run=spawnSync(python,[resolve('scripts/fixtures/whatsapp-byte-seed.py'),mode,join(state,'journal.db')],{encoding:'utf8',timeout:20000});assert.equal(run.status,0,run.stderr);};
let active=[];const results={ok:false,scope:'OFF unpaired synthetic only; no real WhatsApp account/QR/messages',candidate_sha256:sha(readFileSync(candidate)),old_sha256:sha(readFileSync(oldBinary)),pages:[]};
async function start(binary,name){
 const state=join(output,name,'state'),owners=join(output,name,'owners');mkdirSync(join(output,name));
 const init=spawnSync(binary,['init','--state',state,'--account','100@s.whatsapp.net','--all-chats'],{encoding:'utf8',timeout:10000});assert.equal(init.status,0,init.stderr);seed('base',state);
 const reservation=net.createServer();await new Promise(r=>reservation.listen(0,'127.0.0.1',r));const port=reservation.address().port;await new Promise(r=>reservation.close(r));
 const process=spawn(binary,['serve','--state',state,'--owners',owners,'--listen',`127.0.0.1:${port}`],{stdio:['ignore','pipe','pipe']});active.push(process);let logs='';process.stdout.on('data',b=>logs+=b);process.stderr.on('data',b=>logs+=b);
 const binding={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,account_wide:true,operator_account_read:true,allowed_conversations:[],connector_url:`http://127.0.0.1:${port}`,token_file:join(state,'api.token')};
 let status;for(let i=0;i<100;i++){if(process.exitCode!==null)throw Error('private service exited '+logs);try{status=await connectorRequest(binding,'status');break;}catch{await new Promise(r=>setTimeout(r,30));}}
 assert.equal(status?.connection,'needs_pairing');assert.equal(status.config.requested_on,false);
 return {binding,state,process,getLogs:()=>logs};
}
async function rawSize(binding){const body=JSON.stringify({account:binding.account,generation:1,account_wide:true,limit:700});const token=readFileSync(binding.token_file,'utf8');return await new Promise((resolve,reject)=>{const req=http.request(new URL('/read_snapshot',binding.connector_url),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},res=>{let bytes=0;res.on('data',b=>bytes+=b.length);res.on('end',()=>resolve({status:res.statusCode,bytes}));res.on('error',reject)});req.on('error',reject);req.end(body);});}
async function mcp(binding,tool,args){const result=await requestMCP({action:'call',server:{transport:'stdio',program:process.execPath,args:[resolve('scripts/mcp-whatsapp.mjs'),'--binding-json',JSON.stringify(binding)],timeout_seconds:30},tool,arguments:args});assert.equal(result.ok,true,JSON.stringify({error:result.error,outcome:result.outcome}));return result.result.structuredContent;}
async function fieldAll(call,descriptor,field,firstViaStdio){
 const info=descriptor.fields[field];let offset=0,hash=createHash('sha256'),chunks=0;
 for(;;){const args={resource:descriptor.resource,row:descriptor.row,field,version:info.field_version,offset,length:16384};const data=chunks===0&&firstViaStdio?await mcp(firstViaStdio,'read_field',args):await call('read_field',args);assert.equal(data.ok,true,JSON.stringify(data));const bytes=Buffer.from(data.data_base64,'base64');assert.equal(bytes.length,data.chunk_bytes);assert.ok(bytes.length<=16384);assert.equal(data.next_offset,offset+bytes.length);hash.update(bytes);chunks++;if(data.complete){assert.equal(data.next_offset,info.byte_length);break;}assert.ok(data.next_offset>offset);offset=data.next_offset;assert.ok(chunks<10000);}
 return {sha256:hash.digest('hex'),chunks};
}
try{
 const old=await start(oldBinary,'old');const measured=await rawSize(old.binding);assert.equal(measured.status,200);assert.ok(measured.bytes>24*1024*1024);results.old_http_bytes=measured.bytes;
 const oldModule=join(output,'old-adapter.mjs');writeFileSync(oldModule,execFileSync('git',['show','9be5376e9212b8bbe2a57781da92c5efd2f82fb8:scripts/mcp-whatsapp.mjs']));copyFileSync(resolve('scripts/mcp-server-core.mjs'),join(output,'mcp-server-core.mjs'));const original=await import(pathToFileURL(oldModule));await assert.rejects(original.connectorRequest(old.binding,'read_snapshot',{account_wide:true,limit:700}),/connector_response_too_large/);results.old_mcp_error='connector_response_too_large';
 const current=await start(candidate,'new');const call=createWhatsAppAdapter(current.binding);let before=0;const ids=new Set();let inserted=false;
 for(let i=0;i<20;i++){const data=await mcp(current.binding,'read_snapshot',{limit:700,before});assert.equal(data.ok,true);assert.equal(data.page_version,2);assert.ok(data.encoded_bytes<=4*1024*1024);assert.equal(data.oversized_rows.length,0);results.pages.push({rows:data.rows_delivered,bytes:data.encoded_bytes,byte_truncated:data.byte_truncated,next_before:data.next_before});
  for(const m of data.messages){assert.ok(!ids.has(m.id));assert.ok(m.id.startsWith('b-'),'new inserts must not enter the older keyset window');ids.add(m.id);const index=Number(m.id.slice(2));assert.equal(m.body,String(index).padStart(10,'0')+':'+'x'.repeat(39989));}
  if(!inserted){seed('late',current.state);inserted=true;}
  if(!data.truncated)break;assert.ok(data.rows_delivered>0);const last=data.order.at(-1).cursor;assert.equal(data.next_before,last);if(before)assert.ok(last<before);before=last;
 }
 assert.equal(ids.size,700);assert.ok(results.pages[0].byte_truncated);results.exact_rows_once=ids.size;
 seed('extra',current.state);const page=await call('read_snapshot',{limit:10});assert.equal(page.ok,true);const descriptor=page.oversized_rows.find(r=>r.fields.transcript.byte_length>0);assert.ok(descriptor);assert.equal(page.inline_complete,false);const escaped=page.messages.find(m=>m.id==='escaped');assert.equal(escaped.body,'<>"\\\x00é🗣'.repeat(2000));
 const body=await fieldAll(call,descriptor,'body',current.binding);assert.equal(body.sha256,sha(Buffer.from('Hé🗣<>"\\'.repeat(500000))));const transcript=await fieldAll(call,descriptor,'transcript');assert.equal(transcript.sha256,sha(Buffer.from('transcrição 🗣<>"\\'.repeat(30000))));results.large_body=body;results.large_transcript=transcript;
 for(const resource of ['list_chats','posting_status']){const p=await call(resource,{limit:10});assert.equal(p.ok,true);assert.ok(p.encoded_bytes<=4*1024*1024);assert.equal(p.oversized_rows.length,1);const d=p.oversized_rows[0];const field=resource==='list_chats'?'posting_hold_reason':'ack';const exact=await fieldAll(call,d,field);const expected=(resource==='list_chats'?'hold<>"\\字':'ack<>"\\字').repeat(20000);assert.equal(exact.sha256,sha(Buffer.from(expected)));}
 const narrow=createWhatsAppAdapter({...current.binding,account_wide:false,operator_account_read:false,allowed_conversations:['300@s.whatsapp.net']});const ref={resource:'read_snapshot',row:descriptor.row,field:'body',version:descriptor.fields.body.field_version,offset:0};assert.equal((await narrow('read_field',ref)).ok,false);
 assert.equal((await connectorRequest({...current.binding,generation:2},'read_field',{...ref,account_wide:true})).ok,false);assert.equal((await connectorRequest({...current.binding,account:'foreign@s.whatsapp.net'},'read_snapshot',{account_wide:true,limit:1})).ok,false);
 await assert.rejects(call('read_snapshot',{account_wide:true}),/unsupported_whatsapp_argument/);assert.equal((await call('read_field',{...ref,field:'raw'})).error,'field_not_readable');seed('mutate',current.state);assert.equal((await call('read_field',ref)).error,'field_version_changed_restart');
 assert.equal(old.getLogs(),'');assert.equal(current.getLogs(),'');
 if(waBinary){results.native=[];for(const mode of ['source','embedded']){const home=join(output,'native-'+mode);mkdirSync(home);const env={...process.env};for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(key))delete env[key];Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:resolve('scripts/test-whatsapp-byte-native.lua'),WA_NODE:process.execPath,WA_MCP_SCRIPT_DIR:resolve('scripts'),WA_TEST_CONNECTOR_URL:current.binding.connector_url,WA_TEST_CONNECTOR_TOKEN_FILE:current.binding.token_file,WA_TEST_EXPECTED_BODY_BASE64:Buffer.from('changed after descriptor').toString('base64')});if(mode==='source')env.WASM_AGENT_LUA_ROOT=resolve('.');const run=spawnSync(waBinary,['--db',join(home,'fixture.db')],{cwd:home,env,encoding:'utf8',timeout:60000,maxBuffer:1024*1024});writeFileSync(join(home,'stdout.log'),run.stdout??'');writeFileSync(join(home,'stderr.log'),run.stderr??'');assert.equal(run.status,0,run.stderr);assert.match(run.stdout,/whatsapp byte native ok/);results.native.push({mode,exit:run.status});}}
 seed('badmeta',current.state);const oversizedMeta={...current.binding,account:'x'.repeat(300)+'@s.whatsapp.net'};const refusal=await connectorRequest(oversizedMeta,'read_snapshot',{account_wide:true,limit:1});assert.equal(refusal.error,'page_no_progress');const boundedRefusal=await rawSize(oversizedMeta);assert.equal(boundedRefusal.status,503);assert.ok(boundedRefusal.bytes<1024);results.no_progress_refusal=refusal.error;results.ok=true;
}finally{
 for(const child of active){if(child.exitCode===null&&child.signalCode===null)await new Promise(r=>{child.once('close',r);child.kill();});}
 // Synthetic fixture state retained privately for diagnosis; never copied to a release.
 writeFileSync(join(output,'receipt.json'),JSON.stringify(results,null,2));console.log(JSON.stringify(results));
}
