// Synthetic account only. Real Windows connector -> HTTP -> MCP stdio -> CLI/Lua.
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {resolve,join} from 'node:path';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {requestMCP} from './mcp-client-core.mjs';
import {connectorRequest} from './mcp-whatsapp.mjs';
const [exe,out,wa]=process.argv.slice(2).map(v=>resolve(v));const python=process.env.WA_TEST_PYTHON;
if(!exe||!out||!python)throw Error('usage: connector fresh-evidence native-wa; WA_TEST_PYTHON required');
mkdirSync(out);const state=join(out,'state'),owners=join(out,'owners');let service;
let invocation=0;
const run=(file,args,env=process.env)=>{const r=spawnSync(file,args,{encoding:'utf8',env,timeout:30000,maxBuffer:8*1024*1024});const prefix=join(out,'call-'+(++invocation));writeFileSync(prefix+'.stdout',r.stdout||'');writeFileSync(prefix+'.stderr',r.stderr||'');writeFileSync(prefix+'.json',JSON.stringify({exit:r.status,signal:r.signal}));assert.equal(r.status,0,r.stderr+r.stdout);return r.stdout;};
const receipt={ok:false,platform:process.platform,scope:'synthetic OFF/unpaired; no real messages/weights',checks:[]};
try{
 run(exe,['init','--state',state,'--account','100@s.whatsapp.net','--all-chats','--language','pt']);
 run(python,['-c',`import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
for chat in ['200@s.whatsapp.net','300@g.us','400@lid']:
 c.execute('INSERT INTO chats(account,generation,chat,title,title_source,title_observed) VALUES(?,?,?,?,?,?)',('100@s.whatsapp.net',1,chat,'Ana','history_conversation',123))
for i,chat,body,transcript in [(1,'200@s.whatsapp.net','budget tomorrow',''),(2,'300@g.us','','orçamento amanhã'),(3,'400@lid','unrelated','')]:
 c.execute('INSERT INTO messages(account,generation,chat,id,sender,body,sent,observed,own,history,audio,unsupported) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',('100@s.whatsapp.net',1,chat,str(i),chat,body,100+i,200+i,i==2,0,i==2,''))
 if transcript:c.execute('INSERT INTO audio(account,generation,chat,id,state,transcript,language) VALUES(?,?,?,?,?,?,?)',('100@s.whatsapp.net',1,chat,str(i),'done',transcript,'pt'))
c.commit()`,join(state,'journal.db')]);
 const socket=net.createServer();await new Promise(r=>socket.listen(0,'127.0.0.1',r));const port=socket.address().port;await new Promise(r=>socket.close(r));
 service=spawn(exe,['serve','--state',state,'--owners',owners,'--listen',`127.0.0.1:${port}`],{stdio:['ignore','pipe','pipe']});let logs='';service.stdout.on('data',b=>logs+=b);service.stderr.on('data',b=>logs+=b);
 const b={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,account_wide:true,operator_account_read:true,allowed_conversations:[],connector_url:`http://127.0.0.1:${port}`,token_file:join(state,'api.token')};
 let status;for(let i=0;i<100;i++){try{status=await connectorRequest(b,'status');break;}catch{await new Promise(r=>setTimeout(r,30));}}assert.equal(status.connection,'needs_pairing');
 const profile=join(out,'profile.json');writeFileSync(profile,JSON.stringify({resources:b}));
 const cli=async args=>JSON.parse(run(process.execPath,[resolve('scripts/whatsapp-read.mjs'),'--profile-file',profile,...args]));
 const chats=await cli(['--list-chats','--query','Ana','--limit','2']);assert.equal(chats.rows_delivered,2);assert.equal(chats.truncated,true);assert.equal(chats.conversations[0].title,'Ana');
 const older=await cli(['--list-chats','--query','Ana','--before',String(chats.next_before)]);assert.equal(older.rows_delivered,1);
 const page=await cli(['--chat','300@g.us','--query','orçamento','--sent-since','102','--until','102']);assert.equal(page.messages.length,1);assert.equal(page.messages[0].transcript,'orçamento amanhã');assert.equal(page.messages[0].from_me,true);assert.deepEqual(page.chronological_inline_cursors,[2]);
 assert.equal((await cli(['--chat','200@s.whatsapp.net','--query','orçamento'])).rows_delivered,0);receipt.checks.push('real CLI/MCP names+duplicates+pages+selected outgoing transcript search+time+isolation');
 const throughProfile=await requestMCP({action:'call',server:{transport:'stdio',program:process.execPath,args:[resolve('scripts/mcp-whatsapp.mjs'),'--profile-file',profile],timeout_seconds:30},tool:'read_snapshot',arguments:{conversation_id:'300@g.us',query:'orçamento'}});
 assert.equal(throughProfile.result?.structuredContent?.messages?.[0]?.transcript,'orçamento amanhã');
 const readiness=spawnSync(process.execPath,[resolve('scripts/whatsapp-readiness.mjs'),'--profile-file',profile],{encoding:'utf8',timeout:30000});
 writeFileSync(join(out,'readiness.stdout'),readiness.stdout);writeFileSync(join(out,'readiness.stderr'),readiness.stderr);
 assert.equal(readiness.status,1);const unready=JSON.parse(readiness.stdout);assert.equal(unready.checks.pt,true);assert.equal(unready.checks.paired,false);assert.equal(unready.checks.requested_on,false);
 receipt.checks.push('private profile-file MCP and honest unpaired/PT readiness refusal');
 if(wa){
  const script=join(out,'native.lua');writeFileSync(script,`local w=dofile('lua/core/whatsapp.lua')\nlocal p={id='whatsapp-responder',allowed_tools={'whatsapp_read'},resources={backend='linked_device',account='100@s.whatsapp.net',generation=1,allowed_conversations={'300@g.us'},actions={'read'},connector_url=host.getenv('WA_TEST_CONNECTOR_URL'),token_file=host.getenv('WA_TEST_CONNECTOR_TOKEN_FILE')}}\nlocal ctx={role='master',profile=p,event={conversation_id='300@g.us',message_id='2'}}\nlocal r=w.dispatch({},'whatsapp_read',{query='orçamento',sent_since=102,['until']=102},ctx)\nassert(not r.error and r.count==1 and r.messages[1].transcript=='orçamento amanhã')\nlocal n=w.dispatch({},'whatsapp_read',{query='absent'},ctx);assert(not n.error and n.count==0)\nlocal f=w.dispatch({},'whatsapp_read',{conversation_id='200@s.whatsapp.net'},ctx);assert(f.error=='event_conversation_immutable')\nprint('source native navigation 3 checks passed')\n`);
  const env={...process.env};for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(k))delete env[k];Object.assign(env,{WASM_AGENT_HOME:join(out,'native-home'),WASM_AGENT_LUA_ROOT:process.cwd(),WA_SCRIPT:script,WA_MCP_SCRIPT_DIR:resolve('scripts'),WA_NODE:process.execPath,WA_TEST_CONNECTOR_URL:b.connector_url,WA_TEST_CONNECTOR_TOKEN_FILE:b.token_file});mkdirSync(env.WASM_AGENT_HOME);
  writeFileSync(join(out,'native.stdout'),run(wa,['--db',join(out,'native.db')],env));receipt.checks.push('source-root native Lua filter forwarding and event fence (not rebuilt embedded)');
 }
 assert.equal(logs,'');receipt.ok=true;
}finally{
 if(service&&service.exitCode===null)await new Promise(r=>{service.once('close',r);service.kill();});
 rmSync(state,{recursive:true,force:true});rmSync(owners,{recursive:true,force:true});rmSync(join(out,'profile.json'),{force:true});
 receipt.connector_sha256=createHash('sha256').update(readFileSync(exe)).digest('hex');writeFileSync(join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
}
