// Hermetic bridge fault matrix: fake Pi, localhost transport, no credentials/model calls.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..');
const scratch=process.argv[2];
assert(scratch&&path.isAbsolute(scratch),'absolute evidence scratch required');
const root=fs.mkdtempSync(path.join(scratch,'subscription-transport-'));
const put=(name,text)=>{const p=path.join(root,name);fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,text);return p;};
let checks=0;
const check=fn=>{fn();checks++;};
try {
  put('pi/package.json','{"type":"module"}');
  put('pi/dist/core/auth-storage.js',`export class AuthStorage {static create(){return {};}}`);
  put('pi/node_modules/@earendil-works/pi-ai/package.json','{"type":"module"}');
  put('pi/node_modules/@earendil-works/pi-ai/dist/providers/openai-codex.js','export const openaiCodexProvider=()=>({});');
  put('pi/node_modules/@earendil-works/pi-ai/dist/models.js',`
import http from 'node:http';
let attempts=0;
export function createModels(){return {setProvider(){},getModel(_p,id){return {id,api:'fixture'};},
stream(_m,context,options){
 const mode=context.messages[0].content[0].text;
 attempts++;
 return {
 async *[Symbol.asyncIterator](){
  if(mode==='unknown')throw Error('opaque terminated');
  if(mode==='cancel'){const e=Error('Request was aborted');e.name='AbortError';throw e;}
  if(mode==='deadline-abort'){const e=Error('local deadline');e.name='TimeoutError';e.cause=Error('socket');e.cause.code='ECONNRESET';throw e;}
  if(mode==='auth'||mode==='quota'){
   const r=await options.fetch('http://fixture.invalid',{method:'POST'});if(r.status===401||r.status===429)throw Error('HTTP refused');return;
  }
  if(mode==='fetch-reset'||mode==='redaction'||mode==='signal-abort'){
   const controller=new AbortController();if(mode==='signal-abort')controller.abort();
   try{await options.fetch('http://fixture.invalid',{method:'POST',signal:controller.signal});}catch{throw Error('terminated');}return;
  }
  if(mode==='partial-text')yield {type:'text_delta',contentIndex:0,delta:'partial'};
  if(mode==='partial-thought')yield {type:'thinking_delta',contentIndex:0,delta:'thinking'};
  if(mode==='partial-tool')yield {type:'toolcall_start',contentIndex:0,partial:{content:[{id:'partial',name:'never_execute'}]}};
  if(mode==='new-progress')yield {type:'future_progress',value:'not displayed'};
  const server=http.createServer((req,res)=>{req.resume();
   if(mode==='retry-success'&&attempts===2){res.writeHead(200,{'Content-Type':'text/event-stream','x-request-id':'req-local'});res.end('data: {}\\n\\n');return;}
   res.writeHead(200,{'Content-Type':'text/event-stream','Content-Length':1000,'x-request-id':'req-local'});
   res.write('data: {}\\n\\n');setTimeout(()=>res.socket.destroy(),15);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  try{const r=await options.fetch('http://127.0.0.1:'+server.address().port+'/fixture',{method:'POST'});
   try{for await(const chunk of r.body){};}catch{throw Error('terminated');}
  }finally{await new Promise(resolve=>server.close(resolve));}
  yield {type:'text_delta',contentIndex:0,delta:'success'};
 },
 async result(){return {stopReason:'stop',content:[{type:'text',text:'success'}],usage:{input:2,output:1,cacheRead:0,cacheWrite:0,totalTokens:3}};}
 };}};}
// Private fake wire makes handshake failure/auth reproducible before body streaming.
const nativeFetch=globalThis.fetch;
globalThis.fetch=async(url,opts)=>{
 if(url==='http://fixture.invalid'){
  const e=Error('terminated');e.cause=Error('Bearer fixture-sensitive-token https://secret.example/query?token=private');e.cause.code='ECONNRESET';
  if(process.env.FIXTURE_MODE==='auth')return new Response('denied',{status:401});
  if(process.env.FIXTURE_MODE==='quota')return new Response('limited',{status:429});
  throw e;
 }
 return nativeFetch(url,opts);
};
`);
  const text=fs.readFileSync(path.join(repo,'lua/core/openai_sub_bridge.lua'),'utf8');
  const bridge=put('bridge.mjs',text.split('return [==[')[1].split(']==]')[0]);
  const run=(mode,extra={})=>{
    const input=put('request-'+mode+'.json',JSON.stringify({home:root,auth_path:'dummy',model:'fixture',reasoning:'medium',
      messages:[{role:'user',content:mode}],tools:[],timeout_ms:5000,...extra}));
    const result=spawnSync(process.execPath,[bridge,input],{env:{...process.env,WASM_AGENT_PI_PACKAGE:path.join(root,'pi'),FIXTURE_MODE:mode},encoding:'utf8',timeout:10000});
    check(()=>assert(!result.error,result.error?.message));
    const events=(result.stdout||'').trim().split('\n').filter(Boolean).map(line=>JSON.parse(line));
    fs.writeFileSync(path.join(root,mode+'.stdout'),result.stdout||'');fs.writeFileSync(path.join(root,mode+'.stderr'),result.stderr||'');
    return {...result,events,attempts:events.filter(e=>e.type==='transport_attempt')};
  };
  const recovered=run('retry-success');
  check(()=>assert.equal(recovered.status,0,recovered.stderr+recovered.stdout));
  check(()=>assert.equal(recovered.attempts.length,2));
  check(()=>assert.equal(recovered.attempts[0].diagnostic.stage,'response_body'));
  check(()=>assert(recovered.attempts[0].diagnostic.causes.some(c=>['UND_ERR_SOCKET','UND_ERR_RES_CONTENT_LENGTH_MISMATCH'].includes(c.code))));
  check(()=>assert.equal(recovered.attempts[0].diagnostic.model_output_seen,false));
  check(()=>assert.equal(recovered.events.filter(e=>e.type==='transport_retry').length,1));
  check(()=>assert.equal(recovered.events.at(-1).result.content,'success'));
  const exhausted=run('repeat-failure');
  check(()=>assert.equal(exhausted.status,1));check(()=>assert.equal(exhausted.attempts.length,2));
  check(()=>assert.equal(exhausted.events.filter(e=>e.type==='transport_retry').length,1));
  check(()=>assert.match(exhausted.events.at(-1).error,/cause=UND_ERR_(SOCKET|RES_CONTENT_LENGTH_MISMATCH)/));
  const off=run('disabled',{transport_retries:0});
  check(()=>assert.equal(off.attempts.length,1));check(()=>assert.equal(off.events.filter(e=>e.type==='transport_retry').length,0));
  const expired=run('deadline',{timeout_ms:1});
  check(()=>assert.equal(expired.attempts.length,1));check(()=>assert.equal(expired.events.filter(e=>e.type==='transport_retry').length,0));
  for(const mode of ['partial-text','partial-thought','partial-tool','new-progress']){
    const r=run(mode);check(()=>assert.equal(r.status,1));check(()=>assert.equal(r.attempts.length,1));
    check(()=>assert.equal(r.attempts[0].diagnostic.model_output_seen,true));
    check(()=>assert.equal(r.events.filter(e=>e.type==='transport_retry').length,0));
    check(()=>assert.equal(r.events.filter(e=>e.type==='result').length,0));
  }
  for(const mode of ['unknown','auth','quota','cancel','deadline-abort','signal-abort']){
    const r=run(mode);check(()=>assert.equal(r.status,1));check(()=>assert.equal(r.attempts.length,1));
    check(()=>assert.equal(r.events.filter(e=>e.type==='transport_retry').length,0));
  }
  const reset=run('fetch-reset');check(()=>assert.equal(reset.attempts[0].diagnostic.stage,'response_headers'));
  check(()=>assert.equal(reset.attempts.length,2));
  const secret=run('redaction');check(()=>assert(!secret.stdout.includes('fixture-sensitive-token')));
  check(()=>assert(!secret.stdout.includes('secret.example')));
  if(process.argv[3]) {
    const lua=put('native-test.lua',`
local json=dofile('lua/vendor/json.lua')
local adapter=dofile('lua/core/openai_sub.lua')
local telemetry=dofile('lua/core/telemetry.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local sid=memory.start_session('','subscription-transport-fixture',{user_id='master',node_id=''})
local result=adapter.complete('fixture',{{role='user',content='retry-success'}},{},false,
  {session_id=sid,run_id='fixture'}, {selected='medium'})
assert(result.content=='success' and result.transport_failed_attempts==1,'retry recovers once with lost usage visible')
local attempts,retries=0,0
for _,e in ipairs(telemetry.events(sid,0,100).events) do
 if e.kind=='subscription_transport' and e.phase=='attempt' then attempts=attempts+1 end
 if e.kind=='subscription_transport' and e.phase=='retry' then retries=retries+1 end
end
assert(attempts==2 and retries==1,'both attempts and recovery durably recorded')
local real_stream,real_cancelled=host.stream,host.run_cancelled
local cancel=false
host.stream=function(raw)
 local e=json.decode(raw)
 if e.type=='status' and e.text:find('retrying once',1,true) then cancel=true end
end
host.run_cancelled=function() return json.encode({cancelled=cancel}) end
local cancelled_sid=memory.start_session('','cancel-during-retry',{user_id='master',node_id=''})
local success,why=pcall(adapter.complete,'fixture',{{role='user',content='repeat-failure'}},{},true,
 {session_id=cancelled_sid,run_id='cancelled'}, {selected='medium'})
host.stream,host.run_cancelled=real_stream,real_cancelled
assert(not success and tostring(why):find('run_cancelled',1,true),'cancellation interrupts retry backoff')
local cancel_attempts=0
for _,e in ipairs(telemetry.events(cancelled_sid,0,100).events) do
 if e.kind=='subscription_transport' and e.phase=='attempt' then cancel_attempts=cancel_attempts+1 end
end
assert(cancel_attempts==1,'no second inference after cancellation')
print('native transport recovery ok (4 checks)')
`);
    const home=path.join(root,'native');fs.mkdirSync(home);
    const env={...process.env};for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/.test(key))delete env[key];
    Object.assign(env,{WASM_AGENT_HOME:home,WASM_AGENT_PI_PACKAGE:path.join(root,'pi'),
      WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',WA_SCRIPT:lua});
    if(process.argv[4]!=='embedded')env.WASM_AGENT_LUA_ROOT=repo;
    const native=spawnSync(path.resolve(process.argv[3]),['--db',home+'/test.db'],{cwd:repo,env,encoding:'utf8',timeout:15000});
    fs.writeFileSync(root+'/native.stdout',native.stdout||'');fs.writeFileSync(root+'/native.stderr',native.stderr||'');
    check(()=>assert.equal(native.status,0,native.stdout+native.stderr));
    check(()=>assert.match(native.stdout,/native transport recovery ok/));
  }
  console.log(JSON.stringify({ok:true,checks,skipped:0,paid_calls:0,evidence:root}));
} catch(error){console.error('subscription transport fixture failed; evidence='+root);throw error;}
