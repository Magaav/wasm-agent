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
  if(mode.startsWith('midstream-')){
   const first=attempts===1;
   if(first){
    const thinking={type:'thinking',thinking:''},text={type:'text',text:''};
    const tool={type:'toolCall',id:'unfinished-call',name:'write',arguments:{},partialJson:''};
    const partial={content:[thinking]};
    yield {type:'thinking_start',contentIndex:0,partial};thinking.thinking='interrupted thinking';
    yield {type:'thinking_delta',contentIndex:0,delta:thinking.thinking,partial};
    thinking.thinkingSignature='opaque known signature';
    if(mode==='midstream-thinking-end')thinking.thinking='complete end-only thinking';
    yield {type:'thinking_end',contentIndex:0,content:thinking.thinking,partial};
    partial.content.push(text);yield {type:'text_start',contentIndex:1,partial};text.text='interrupted progress';
    yield {type:'text_delta',contentIndex:1,delta:text.text,partial};
    if(mode==='midstream-commentary'){text.textSignature=JSON.stringify({phase:'commentary'});yield {type:'text_end',contentIndex:1,content:text.text,partial};}
    if(mode==='midstream-final'){text.textSignature=JSON.stringify({phase:'final_answer'});yield {type:'text_end',contentIndex:1,content:text.text,partial};}
    partial.content.push(tool);yield {type:'toolcall_start',contentIndex:2,partial};
    tool.partialJson='{\"path\":';yield {type:'toolcall_delta',contentIndex:2,delta:tool.partialJson,partial};
    if(mode==='midstream-completed-tool'){delete tool.partialJson;tool.arguments={path:'must-not-execute'};yield {type:'toolcall_end',contentIndex:2,toolCall:tool,partial};}
    if(mode==='midstream-unknown'){yield {type:'future_progress',value:'unknown'};}
    if(mode==='midstream-unknown-field'){yield {type:'text_delta',contentIndex:1,delta:'extra',partial,future:true};}
    if(mode==='midstream-unknown-error'){yield {type:'error',reason:'error',error:{content:[{type:'serverEffect'}]}};}
    if(mode==='midstream-unknown-block'){partial.content.push({type:'serverEffect',id:'unknown'});yield {type:'text_delta',contentIndex:1,delta:'extra',partial};}
    if(mode==='midstream-malformed'){yield {type:'toolcall_delta',contentIndex:99,delta:'malformed',partial};}
    if(mode==='midstream-cancel'){const e=Error('cancel');e.name='AbortError';throw e;}
    if(mode==='midstream-auth'||mode==='midstream-quota'){const r=await options.fetch('http://fixture.invalid',{method:'POST'});throw Error('HTTP '+r.status);}
    if(mode==='midstream-result')delete tool.partialJson;
   }
   if(!first){
    const tool={type:'toolCall',id:'completed-call',name:'write',arguments:{path:'fixture-effect',content:'once'}};
    const partial={content:[tool]};
    yield {type:'toolcall_start',contentIndex:0,partial};
    yield {type:'toolcall_end',contentIndex:0,toolCall:tool,partial};
    return;
   }
  }
  if(mode==='unknown')throw Error('opaque terminated');
  if(mode==='cancel'){const e=Error('Request was aborted');e.name='AbortError';throw e;}
  if(mode==='deadline-abort'){const e=Error('local deadline');e.name='TimeoutError';e.cause=Error('socket');e.cause.code='ECONNRESET';throw e;}
  if(mode==='auth'||mode==='quota'){
   const r=await options.fetch('http://fixture.invalid',{method:'POST'});if(r.status===401||r.status===429)throw Error('HTTP refused');return;
  }
  if(mode==='fetch-reset'||mode==='redaction'||mode==='signal-abort'||mode==='recovery-hang'){
   const controller=new AbortController();if(mode==='signal-abort')controller.abort();
   try{await options.fetch('http://fixture.invalid',{method:'POST',signal:mode==='recovery-hang'?options.signal:controller.signal});}catch{throw Error('terminated');}return;
  }
  if(mode==='partial-text')yield {type:'text_delta',contentIndex:0,delta:'partial'};
  if(mode==='partial-thought')yield {type:'thinking_delta',contentIndex:0,delta:'thinking'};
  if(mode==='partial-tool')yield {type:'toolcall_start',contentIndex:0,partial:{content:[{id:'partial',name:'never_execute'}]}};
  if(mode==='new-progress')yield {type:'future_progress',value:'not displayed'};
  if(mode==='empty-thinking-start')yield {type:'thinking_start',contentIndex:0,partial:{content:[{type:'thinking',thinking:''}]}};
  if(mode==='empty-text-start')yield {type:'text_start',contentIndex:0,partial:{content:[{type:'text',text:''}]}};
  if(mode==='result-empty-thinking')yield {type:'thinking_start',contentIndex:0,partial:{content:[{type:'thinking',thinking:''}]}};
  if(mode==='result-empty-text')yield {type:'text_start',contentIndex:0,partial:{content:[{type:'text',text:''}]}};
  if(mode==='malformed-start')yield {type:'thinking_start',contentIndex:0};
  if(mode==='nonempty-start')yield {type:'thinking_start',contentIndex:0,partial:{content:[{type:'thinking',thinking:'already generated'}]}};
  if(mode==='signature-start')yield {type:'thinking_start',contentIndex:0,partial:{content:[{type:'thinking',thinking:'',thinkingSignature:'opaque'}]}};
  if(mode==='prior-nonempty-start')yield {type:'text_start',contentIndex:1,partial:{content:[{type:'thinking',thinking:'prior output'},{type:'text',text:''}]}};
  if(mode==='start-then-text'){yield {type:'text_start',contentIndex:0,partial:{content:[{type:'text',text:''}]}};yield {type:'text_delta',contentIndex:0,delta:'partial'};}
  if(mode==='wrong-index-start')yield {type:'text_start',contentIndex:2,partial:{content:[{type:'text',text:''}]}};
  if(mode==='unknown-block-start')yield {type:'text_start',contentIndex:0,partial:{content:[{type:'text',text:'',futureProperty:true}]}};
  if(mode==='sparse-start'){const content=[];content[1]={type:'text',text:''};yield {type:'text_start',contentIndex:1,partial:{content}};}
  if(mode==='unknown-event-field-start')yield {type:'text_start',contentIndex:0,futurePayload:'unknown',partial:{content:[{type:'text',text:''}]}};
  if(mode==='wrong-type-start')yield {type:'text_start',contentIndex:0,partial:{content:[{type:'thinking',thinking:''}]}};
  const server=http.createServer((req,res)=>{req.resume();
   if(((['retry-success','healthy-slow','empty-thinking-start','empty-text-start','result-empty-thinking','result-empty-text'].includes(mode))&&attempts===2)||(mode==='cycle-success'&&attempts===12)){res.writeHead(200,{'Content-Type':'text/event-stream','x-request-id':'req-local'});
    res.flushHeaders();if(mode==='healthy-slow')setTimeout(()=>res.end('data: {}\\n\\n'),150);else res.end('data: {}\\n\\n');return;}
   res.writeHead(200,{'Content-Type':'text/event-stream','Content-Length':1000,'x-request-id':'req-local'});
   res.write('data: {}\\n\\n');setTimeout(()=>res.socket.destroy(),15);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  try{const r=await options.fetch('http://127.0.0.1:'+server.address().port+'/fixture',{method:'POST'});
   try{for await(const chunk of r.body){};}catch{if(mode.startsWith('result-empty-')||mode==='midstream-result')return;throw Error('terminated');}
  }finally{await new Promise(resolve=>server.close(resolve));}
  yield {type:'text_delta',contentIndex:0,delta:'success'};
 },
 async result(){if(mode.startsWith('midstream-')){
  if(attempts===1)return {stopReason:'error',errorMessage:'terminated',content:[{type:'toolCall',id:'unfinished-call',name:'write',arguments:{}}]};
  return {stopReason:'toolUse',content:[{type:'toolCall',id:'completed-call',name:'write',arguments:{path:'fixture-effect',content:'once'}}],usage:{input:2,output:1,cacheRead:0,cacheWrite:0,totalTokens:3}};
 }if(mode.startsWith('result-empty-')&&attempts===1)return {stopReason:'error',errorMessage:'terminated',content:[mode==='result-empty-text'?{type:'text',text:''}:{type:'thinking',thinking:''}]};return {stopReason:'stop',content:[{type:'text',text:'success'}],usage:{input:2,output:1,cacheRead:0,cacheWrite:0,totalTokens:3}};}
 };}};}
// Private fake wire makes handshake failure/auth reproducible before body streaming.
const nativeFetch=globalThis.fetch;
globalThis.fetch=async(url,opts)=>{
 if(url==='http://fixture.invalid'){
  const e=Error('terminated');e.cause=Error('Bearer fixture-sensitive-token https://secret.example/query?token=private');e.cause.code='ECONNRESET';
  if(['auth','midstream-auth'].includes(process.env.FIXTURE_MODE))return new Response('denied',{status:401});
  if(['quota','midstream-quota'].includes(process.env.FIXTURE_MODE))return new Response('limited',{status:429});
  if(process.env.FIXTURE_MODE==='recovery-hang'&&attempts>1){
    await new Promise((resolve,reject)=>{const abort=()=>{const a=Error('recovery timeout');a.name='AbortError';reject(a);};
      if(opts.signal.aborted)abort();else opts.signal.addEventListener('abort',abort,{once:true});});
  }
  throw e;
 }
 return nativeFetch(url,opts);
};
`);
  const text=fs.readFileSync(path.join(repo,'lua/core/openai_sub_bridge.lua'),'utf8');
  const bridge=put('bridge.mjs',text.split('return [==[')[1].split(']==]')[0]);
  const run=(mode,extra={})=>{
    const input=put('request-'+mode+'.json',JSON.stringify({home:root,auth_path:'dummy',model:'fixture',reasoning:'medium',
      messages:[{role:'user',content:mode}],tools:[],timeout_ms:5000,transport_retries:1,recovery_window_ms:1000,...extra}));
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
  const healthy=run('healthy-slow',{transport_retries:10,recovery_window_ms:1000});
  check(()=>assert.equal(healthy.status,0,healthy.stdout));
  check(()=>assert.equal(healthy.attempts.length,2));
  check(()=>assert(healthy.events.some(e=>e.type==='retry'&&e.state==='connected')));
  const exhausted=run('repeat-failure');
  check(()=>assert.equal(exhausted.status,1));check(()=>assert.equal(exhausted.attempts.length,2));
  check(()=>assert.equal(exhausted.events.filter(e=>e.type==='transport_retry').length,1));
  check(()=>assert.match(exhausted.events.at(-1).error,/UND_ERR_(SOCKET|RES_CONTENT_LENGTH_MISMATCH)/));
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
  // Both thrown body errors and Pi-normalized empty-content failures recover.
  for(const mode of ['empty-thinking-start','empty-text-start','result-empty-thinking','result-empty-text']){
    const r=run(mode);check(()=>assert.equal(r.status,0,r.stdout));check(()=>assert.equal(r.attempts.length,2));
    check(()=>assert.equal(r.attempts[0].diagnostic.model_output_seen,false));
    check(()=>assert.equal(r.attempts[0].diagnostic.retry_scheduled,true));
    check(()=>assert.equal(r.events.filter(e=>e.type==='transport_retry').length,1));
    check(()=>assert.equal(r.events.filter(e=>e.type==='result').length,1));
    check(()=>assert.equal(r.events.at(-1).result.content,'success'));
    check(()=>assert.equal(r.attempts[0].diagnostic.empty_item_starts[mode.includes('thinking')?'thinking':'text'],1));
    check(()=>assert.equal(r.events.filter(e=>['reasoning','decision'].includes(e.type)).length,0));
  }
  for(const mode of ['malformed-start','nonempty-start','signature-start','prior-nonempty-start','start-then-text','wrong-index-start','unknown-block-start','sparse-start','unknown-event-field-start','wrong-type-start']){
    const r=run(mode);check(()=>assert.equal(r.status,1));check(()=>assert.equal(r.attempts.length,1));
    check(()=>assert.equal(r.attempts[0].diagnostic.model_output_seen,true));
    check(()=>assert.equal(r.events.filter(e=>e.type==='transport_retry').length,0));
    check(()=>assert(r.attempts[0].diagnostic.output_progress_class));
  }
  for(const mode of ['unknown','auth','quota','cancel','deadline-abort','signal-abort']){
    const r=run(mode);check(()=>assert.equal(r.status,1));check(()=>assert.equal(r.attempts.length,1));
    check(()=>assert.equal(r.events.filter(e=>e.type==='transport_retry').length,0));
  }
  // Explicit Lua-owned uncommitted boundary: previews are not dispatched effects.
  for(const mode of ['midstream-tool','midstream-completed-tool','midstream-commentary','midstream-final','midstream-result','midstream-thinking-end']){
    const r=run(mode,{midstream_recovery:true});
    check(()=>assert.equal(r.status,0,r.stdout));check(()=>assert.equal(r.attempts.length,2));
    check(()=>assert.equal(r.attempts[0].diagnostic.model_output_seen,true));
    check(()=>assert.equal(r.attempts[0].diagnostic.uncommitted_retry_safe,true));
    const interrupted=r.events.filter(e=>e.type==='retry'&&e.state==='interrupted');
    check(()=>assert.equal(interrupted.length,1));
    check(()=>assert.equal(interrupted[0].discarded_attempt.tools_executed,0));
    check(()=>assert.equal(interrupted[0].discarded_attempt.reasoning,mode==='midstream-thinking-end'?'complete end-only thinking':'interrupted thinking'));
    check(()=>assert.equal(interrupted[0].discarded_attempt.texts[0].text,'interrupted progress'));
    check(()=>assert.equal(r.events.filter(e=>e.type==='result').length,1));
    check(()=>assert.deepEqual(r.events.at(-1).result.tool_calls.map(c=>c.id),['completed-call']));
    check(()=>assert(r.events.filter(e=>e.type==='transport_retry').every(e=>e.note.includes('no tools replayed'))));
    const bodyIds=r.events.filter(e=>e.type==='pending_delta').map(e=>e.pending_id);
    check(()=>assert.equal(new Set(bodyIds).size,bodyIds.length,'attempt text IDs never reused'));
  }
  for(const mode of ['midstream-unknown','midstream-unknown-field','midstream-unknown-error','midstream-unknown-block','midstream-malformed','midstream-cancel','midstream-auth','midstream-quota','midstream-disabled']){
    const r=run(mode,{midstream_recovery:true,...(mode==='midstream-disabled'?{transport_retries:0}:{})});
    check(()=>assert.equal(r.status,1));check(()=>assert.equal(r.attempts.length,1));
    check(()=>assert.equal(r.events.filter(e=>e.type==='transport_retry'||e.type==='result').length,0));
  }
  for(const mode of ['midstream-tool','midstream-commentary']){
    const r=run(mode,{midstream_recovery:false});
    check(()=>assert.equal(r.status,1));check(()=>assert.equal(r.attempts.length,1));
    check(()=>assert.equal(r.events.filter(e=>e.type==='result'||e.type==='transport_retry').length,0));
  }
  const ten=run('repeat-failure',{transport_retries:10,recovery_window_ms:1000});
  check(()=>assert.equal(ten.attempts.length,11));
  check(()=>assert.equal(ten.events.filter(e=>e.type==='transport_retry').length,10));
  check(()=>assert.deepEqual(ten.events.filter(e=>e.type==='retry'&&e.state==='attempting').map(e=>e.index),[1,2,3,4,5,6,7,8,9,10]));
  check(()=>assert.equal(ten.events.filter(e=>e.type==='retry').at(-1).state,'exhausted'));
  const cycled=run('cycle-success',{transport_retries:10,recovery_window_ms:1000,reconnect_cooldown_ms:50});
  check(()=>assert.equal(cycled.status,0,cycled.stdout));
  check(()=>assert.equal(cycled.attempts.length,12));
  check(()=>assert(cycled.events.some(e=>e.type==='retry'&&e.state==='reconnecting'&&e.cycle===1)));
  check(()=>assert(cycled.events.some(e=>e.type==='retry'&&e.state==='attempting'&&e.cycle===2&&e.index===1)));
  check(()=>assert.equal(cycled.events.filter(e=>e.type==='retry').at(-1).state,'recovered'));
  const hung=run('recovery-hang',{transport_retries:10,recovery_window_ms:1000});
  check(()=>assert(hung.attempts.length>=9&&hung.attempts.length<=11,'hanging reconnect attempts bounded in cycle'));
  check(()=>assert(hung.attempts.slice(1).some(e=>e.diagnostic.recovery_timeout===true)));
  check(()=>assert(hung.events.some(e=>e.type==='retry'&&e.state==='exhausted')));
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
local real_getenv=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES' then return '1' end return real_getenv(k) end
local result=adapter.complete('fixture',{{role='user',content='retry-success'}},{},false,
  {session_id=sid,run_id='fixture'}, {selected='medium'})
assert(result.content=='success' and result.transport_failed_attempts==1,'retry recovers once with lost usage visible')
local attempts,retries=0,0
for _,e in ipairs(telemetry.events(sid,0,100).events) do
 if e.kind=='subscription_transport' and e.phase=='attempt' then attempts=attempts+1 end
 if e.kind=='subscription_transport' and e.phase=='retry' then retries=retries+1 end
end
assert(attempts==2 and retries==1,'both attempts and recovery durably recorded')
local stored_retry=0
for _,row in ipairs(memory.session_messages(sid,{all=true})) do if row.role=='retry' then stored_retry=stored_retry+1 end end
assert(stored_retry>=3,'retry topic events survive transcript reload')
for _,mode in ipairs({'result-empty-thinking','empty-text-start'}) do
 local empty_sid=memory.start_session('','empty-start-recovery',{user_id='master',node_id=''})
 local repaired=adapter.complete('fixture',{{role='user',content=mode}},{},false,
   {session_id=empty_sid,run_id='empty-start'}, {selected='medium'})
 assert(repaired.content=='success' and repaired.transport_failed_attempts==1,'empty starts recover in actual Lua/operation path')
 local first
 for _,e in ipairs(telemetry.events(empty_sid,0,100).events) do
  if e.kind=='subscription_transport' and e.phase=='attempt' then first=first or e.payload end
 end
 assert(first and first.model_output_seen==false and first.retry_scheduled==true,'durable empty-start safe replay evidence')
end
local real_stream,real_cancelled=host.stream,host.run_cancelled
local cancel=false
host.stream=function(raw)
 local e=json.decode(raw)
 if e.type=='retry' and e.state=='reconnecting' then cancel=true end
end
host.run_cancelled=function() return json.encode({cancelled=cancel}) end
local cancelled_sid=memory.start_session('','cancel-during-retry',{user_id='master',node_id=''})
local success,why=pcall(adapter.complete,'fixture',{{role='user',content='repeat-failure'}},{},true,
 {session_id=cancelled_sid,run_id='cancelled'}, {selected='medium'})
host.stream,host.run_cancelled=real_stream,real_cancelled
assert(not success and tostring(why):find('run_cancelled',1,true),'cancellation interrupts three-minute cooldown')
local cancel_attempts=0
for _,e in ipairs(telemetry.events(cancelled_sid,0,100).events) do
 if e.kind=='subscription_transport' and e.phase=='attempt' then cancel_attempts=cancel_attempts+1 end
end
assert(cancel_attempts==2,'no new cycle inference after cooldown cancellation')
print('native transport recovery ok (8 checks)')
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
    const loop=spawnSync(path.resolve(process.argv[3]),['--db',home+'/loop.db'],{cwd:repo,
      env:{...env,WA_SCRIPT:path.join(repo,'scripts/test-subscription-midstream-loop.lua')},encoding:'utf8',timeout:20000});
    fs.writeFileSync(root+'/loop.stdout',loop.stdout||'');fs.writeFileSync(root+'/loop.stderr',loop.stderr||'');
    check(()=>assert.equal(loop.status,0,loop.stdout+loop.stderr));
    check(()=>assert.match(loop.stdout,/subscription midstream production loop ok/));
  }
  console.log(JSON.stringify({ok:true,checks,skipped:0,paid_calls:0,evidence:root}));
} catch(error){console.error('subscription transport fixture failed; evidence='+root);throw error;}
