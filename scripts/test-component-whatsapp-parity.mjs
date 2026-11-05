// Parity: the mcp-whatsapp WASI component answers exactly like scripts/mcp-whatsapp.mjs against the
// same fake connector - results, refusals and read_newest. Runs the component through the real host
// (`wa`, host.component_mcp). Needs WA_BIN and mcp-whatsapp installed in WA_COMPONENTS_DIR; skips
// (and says so) otherwise.
//   WA_BIN=... WA_COMPONENTS_DIR=... node --test scripts/test-component-whatsapp-parity.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {createWhatsAppAdapter,createNewestReader} from './mcp-whatsapp.mjs';
import {bytePage} from './fixtures/whatsapp-byte-envelope.mjs';

const BIN=process.env.WA_BIN,DIR=process.env.WA_COMPONENTS_DIR;
const ready=BIN&&DIR&&existsSync(BIN)&&existsSync(join(DIR,'mcp-whatsapp.wasm'));
const ACCOUNT='100@s.whatsapp.net',CHAT='200@s.whatsapp.net',GROUP='300-1@g.us';

test('mcp-whatsapp component matches the Node adapter',{skip:ready?false:'WA_BIN / mcp-whatsapp component not installed'},async()=>{
 const now=Math.floor(Date.now()/1000);
 const messages=[{id:'m3',cursor:30,conversation_id:CHAT,sent_at:now-60,body:'novo'},{id:'m2',cursor:20,conversation_id:CHAT,sent_at:now-3600,body:'meio {} [] "q"'},{id:'m1',cursor:10,conversation_id:CHAT,sent_at:now-7200,body:'antigo'}];
 const server=http.createServer((req,res)=>{let body='';req.on('data',b=>body+=b);req.on('end',()=>{
  const data=JSON.parse(body);const method=req.url.slice(1);res.setHeader('Content-Type','application/json');
  if(req.headers.authorization!=='Bearer '+'a'.repeat(64)){res.statusCode=401;res.end('{"ok":false,"error":"auth"}');return;}
  const scope=data.account_wide?'account':'selected';
  if(method==='read_snapshot'){
   const rows=messages.filter(m=>(!data.before||m.cursor<data.before)&&(!data.sent_since||m.sent_at>=data.sent_since)&&(!data.conversations||data.conversations.includes(m.conversation_id))).slice(0,data.limit);
   res.write(''); // headers go out without Content-Length: the body is chunked, as Go sends large pages
   res.end(bytePage({ok:true,account:ACCOUNT,generation:1,messages:rows,cursor_version:1,limit_scope:'total',scope_kind:scope,source_state:{connection:'connected'},next_before:0,truncated:false}));return;
  }
  if(method==='list_chats'){res.end(bytePage({ok:true,account:ACCOUNT,generation:1,conversations:[{id:CHAT,cursor:5,title:'Casa'}].filter(c=>!data.query||c.title.toLowerCase().includes(String(data.query).toLowerCase())),cursor_version:1,limit_scope:'total',scope_kind:scope,source_state:{connection:'connected'},next_before:0,truncated:false}));return;}
  if(method==='lookup_self'){res.end(JSON.stringify({ok:true,account:ACCOUNT,generation:1,self:{id:ACCOUNT}}));return;}
  if(method==='inspect_chat'){res.end(JSON.stringify({ok:true,account:ACCOUNT,generation:1,chat:{id:data.conversation_id,scope:'selected'}}));return;}
  res.statusCode=404;res.end('{"ok":false,"error":"unknown"}');
 });});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;
 try{
  const dir=mkdtempSync(join(tmpdir(),'wa-parity-'));const token_file=join(dir,'token');writeFileSync(token_file,'a'.repeat(64),{mode:0o600});
  const config={allowed_conversations:[CHAT]};
  const binding={backend:'linked_device',account:ACCOUNT,generation:1,connector_url:`http://127.0.0.1:${port}/`,token_file,...config};
  const adapter=createWhatsAppAdapter(binding),newest=createNewestReader(adapter,{wide:false});
  const node=async(name,args)=>{try{return name==='read_newest'?await newest(args):await adapter(name,args);}catch(error){return {ok:false,error:String(error.message||error)};}};
  const lua=join(dir,'call.lua');writeFileSync(lua,"print(host.component_mcp(host.getenv('PARITY_REQUEST')))");
  const component=async(name,args)=>{
   const request={action:'call',component:'mcp-whatsapp',tool:name,arguments_json:JSON.stringify(args),timeout_seconds:20,
    config:{...config,account:ACCOUNT,generation:1,connector_url:`http://127.0.0.1:${port}/`},file_env:{WA_MCP_WHATSAPP_TOKEN:'PARITY_TOKEN_FILE'},net:[`127.0.0.1:${port}`]};
   // Async: the fake connector lives in this process, and a sync spawn would block it (deadlock).
   const run=await new Promise((done,reject)=>{const child=spawn(BIN,['--db',join(dir,'db.sqlite')],{env:{...process.env,WA_SCRIPT:lua,WASM_AGENT_LUA_ROOT:resolve('.'),PARITY_REQUEST:JSON.stringify(request),PARITY_TOKEN_FILE:token_file}});
    let stdout='',stderr='';child.stdout.on('data',d=>stdout+=d);child.stderr.on('data',d=>stderr+=d);const timer=setTimeout(()=>child.kill(),60000);
    child.on('error',reject);child.on('close',status=>{clearTimeout(timer);done({stdout,stderr,status});});});
   const line=run.stdout.trim().split('\n').at(-1);if(!line)throw Error('wa produced no answer: status '+run.status+' '+run.stderr.slice(-400));const answer=JSON.parse(line);
   assert.equal(answer.session_mode,'component',line);
   return answer.result_json?JSON.parse(answer.result_json).structuredContent:answer;
  };
  const cases=[
   ['read_snapshot',{conversation_id:CHAT,limit:2}],
   ['read_snapshot',{}],
   ['list_chats',{query:'casa'}],
   ['lookup_self',{}],
   ['inspect_chat',{conversation_id:CHAT}],
   ['inspect_chat',{conversation_id:GROUP}],            // not bound: refused by both
   ['read_snapshot',{conversation_id:CHAT,bogus:1}],    // unsupported argument
   ['send_message',{conversation_id:CHAT,body:'x',confirm:true}],
   ['download_audio',{conversation_id:CHAT,message_id:'m1'}],
   ['read_newest',{conversation_id:CHAT,n:2}],
  ];
  for(const [name,args] of cases){
   const expected=await node(name,args),actual=await component(name,args);
   if(name==='read_newest'){delete expected.searched_since;delete actual.searched_since;}
   assert.deepEqual(actual,expected,`${name} ${JSON.stringify(args)}`);
  }
 }finally{server.close();}
});
