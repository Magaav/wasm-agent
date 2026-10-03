// Real host HTTP, SQLite, restarts and signed two-node status; loopback mocks only.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http'),net=require('node:net');
const {spawn}=require('node:child_process'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]||fs.mkdtempSync(path.join(os.tmpdir(),'wa-serving-http-')));
fs.mkdirSync(out,{recursive:true});
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|SERVING_TEST_)/i.test(k)));
const children=[],requests=[];let mock;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,label){for(let i=0;i<200;i++){try{if(await fn())return;}catch{}await sleep(100);}throw Error('timeout '+label);}
function port(){return new Promise(r=>{const s=net.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>r(p));});});}
function launch(name,args,env){const log=fs.openSync(path.join(out,name+'.log'),'a');const child=spawn(binary,args,{cwd:out,env,stdio:['ignore',log,log],windowsHide:true});children.push(child);return child;}
async function script(name,lua,env,db){const file=path.join(out,name+'.lua');fs.writeFileSync(file,lua);const child=launch(name,['--db',db],{...env,WA_SCRIPT:file});await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code)=>code===0?resolve():reject(Error(name+' exit '+code+' '+fs.readFileSync(path.join(out,name+'.log'),'utf8'))));});console.log(name+' passed');}
async function identity(name,env,db){await script(name,`print(host.node_identity())`,env,db);return JSON.parse(fs.readFileSync(path.join(out,name+'.log'),'utf8').trim().split('\n').at(-1));}
const providerFixture=`
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv;local profile='account-a';local key='fixture-key'
host.getenv=function(k)
 if k=='WASM_AGENT_PROVIDER_ACCOUNT_PROFILE' then return profile end
 if k=='WASM_AGENT_LLM_API_KEY' then return key end
 return getenv(k)
end
local p=dofile('lua/core/provider.lua');local calls=0;local raw_http=host.http;local seam
host.http=function(...) calls=calls+1;local result=raw_http(...);print('RAW_HTTP '..result);if seam then seam() end;return result end
local function sql(s,v) return json.decode(host.sql_exec(s,json.encode(v or {}))) end
local checks=0;local function check(v,label) assert(v,label);checks=checks+1;print('ok '..label) end
local function call(text) return pcall(p.complete_with,'fixture',{{role='user',content=text}},nil,false,{}) end
local function recover() assert(p.recover_serving(p.serving_binding(),'private independently verified recovery',true).ok) end
if getenv('SERVING_TEST_MODE')=='restart' then
 check(p.serving('fixture').state=='blocked','real HTTP monthly block persisted across process restart')
 local before=calls;check(not call('correct') and calls==before,'persisted monthly block zero HTTP calls')
 profile='corrupt-account';before=calls
 check(p.serving('fixture').reason=='provider_eligibility_corrupt','corrupt account persisted fail closed')
 check(not call('correct') and calls==before,'corrupt restart zero HTTP calls')
 recover();check(call('correct') and p.serving('fixture').state=='observed_serving','corrupt recovery followed by genuine bound inference')
 profile='account-a'
else
 check(p.serving('fixture').state=='unknown','absent legacy state unknown')
 check(not call('monthly') and calls==1 and p.serving('fixture').state=='blocked','actual HTTP monthly429 establishes durable account block')
 local before=calls;key='rotated-key';check(not call('correct') and calls==before,'rotated key and healthy node do not probe quota')
 profile='account-b';check(p.serving('fixture').state=='unknown','other account route isolated')
 for _,text in ipairs({'other429','prose','transport'}) do call(text);check(p.serving('fixture').state=='unknown','real HTTP unsupported '..text..' not quota') end
 check(call('wrong') and p.serving('fixture').state=='unknown','HTTP200 wrong model not serving evidence')
 check(call('missing') and p.serving('fixture').state=='unknown','HTTP200 missing response model not serving evidence')
 check(call('correct') and p.serving('fixture').state=='observed_serving','actual correctly bound HTTP success certifies serving')
 recover();local binding=p.serving_binding()
 seam=function() sql("UPDATE provider_serving SET state='blocked',reason='provider_monthly_quota',model='fixture',generation=generation+1 WHERE binding=?",{binding}) end
 check(call('correct') and p.serving('fixture').state=='blocked','newer concurrent block wins real successful HTTP CAS')
 seam=nil;recover()
 seam=function() profile='account-c' end
 check(call('correct') and p.serving('fixture').state=='unknown','actual inflight account drift cannot recover foreign account')
 seam=nil;profile='account-b';check(p.serving('fixture').state=='unknown','actual inflight account drift retains original unknown')
 local old_env=host.getenv
 seam=function() host.getenv=function(k) if k=='WASM_AGENT_LLM_BASE_URL' then return getenv(k)..'/other-provider' end return old_env(k) end end
 check(call('correct') and p.serving('fixture').state=='unknown','changed provider endpoint cannot certify old request route')
 seam=nil;host.getenv=old_env
 profile='corrupt-account';check(call('correct'),'create private corrupted fixture')
 sql("UPDATE provider_serving SET state='corrupted' WHERE binding=?",{p.serving_binding()})
 before=calls;check(not call('correct') and calls==before,'corrupted durable row refuses all actual HTTP')
 profile='account-a'
end
-- Account-a remains monthly blocked for signed peer status checks.
print('real serving HTTP: '..checks..' checks, 0 skips, 0 paid calls; loopback HTTP='..calls)
`;
(async()=>{
 mock=http.createServer((req,res)=>{let text='';req.on('data',b=>text+=b);req.on('end',()=>{
  const request={method:req.method,url:req.url,authorization:req.headers.authorization,body:text};requests.push(request);fs.writeFileSync(path.join(out,'requests.json'),JSON.stringify(requests,null,2));
  assert.equal(req.method,'POST');assert.equal(req.url,'/chat/completions');assert.match(req.headers.authorization||'',/^Bearer (fixture-key|rotated-key)$/);
  const body=JSON.parse(text);assert.equal(body.model,'fixture');const kind=body.messages.at(-1).content;
  if(kind==='monthly'){res.writeHead(429);res.end(JSON.stringify({error:{type:'GoUsageLimitError',metadata:{limitName:'monthly'}}}));}
  else if(kind==='other429'){res.writeHead(429);res.end(JSON.stringify({error:{type:'OtherError',metadata:{limitName:'monthly'}}}));}
  else if(kind==='transport'){res.destroy();}
  else if(kind==='prose'){res.writeHead(500);res.end('GoUsageLimitError monthly');}
  else {res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({id:'owned-response',model:kind==='wrong'?'different-model':kind==='missing'?undefined:'fixture',choices:[{message:{content:'actual mock inference'},finish_reason:'stop'}]}));}
 });});
 await new Promise(r=>mock.listen(0,'127.0.0.1',r));const endpoint='http://127.0.0.1:'+mock.address().port;
 for(const embedded of [false,true]){
  const mode=embedded?'embedded':'source',home=path.join(out,mode);fs.mkdirSync(home,{recursive:true});
  const db=path.join(home,'private.db'),env={...clean,WASM_AGENT_HOME:home,WA_GRAPH_WATCH:'0',WASM_AGENT_LLM_BASE_URL:endpoint,WASM_AGENT_LLM_API_KEY:'fixture-key',WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_PROVIDER_ACCOUNT_PROFILE:'account-a'};
  if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
  await script(mode+'-first',providerFixture,{...env,SERVING_TEST_MODE:'first'},db);
  await script(mode+'-restart',providerFixture,{...env,SERVING_TEST_MODE:'restart'},db);
  const peer=await identity(mode+'-peer-id',env,db);
  const callerHome=path.join(out,mode+'-caller');fs.mkdirSync(callerHome,{recursive:true});const callerDb=path.join(callerHome,'private.db'),callerEnv={...env,WASM_AGENT_HOME:callerHome};
  const caller=await identity(mode+'-caller-id',callerEnv,callerDb);
  const registryPort=await port(),registryUrl='http://127.0.0.1:'+registryPort;
  const registry=launch(mode+'-registry',['rendezvous','--port',String(registryPort),'--db',path.join(out,mode+'-registry.db')],{...env,WASM_AGENT_NETWORK_ADMINS:[caller.node_id,peer.node_id].join(',')});
  await until(()=>fetch(registryUrl+'/health').then(r=>r.ok),'registry');
  const peerPort=await port(),callerPort=await port();
  const peerProcess=launch(mode+'-peer',['serve','--db',db,'--port',String(peerPort),'--client-port',String(await port()),'--ui',path.join(root,'ui')],{...env,WASM_AGENT_RENDEZVOUS:registryUrl,WASM_AGENT_RELAY:registryUrl,WASM_AGENT_ENDPOINT:'127.0.0.1:'+peerPort});
  const callerProcess=launch(mode+'-caller',['serve','--db',callerDb,'--port',String(callerPort),'--client-port',String(await port()),'--ui',path.join(root,'ui')],{...callerEnv,WASM_AGENT_RENDEZVOUS:registryUrl,WASM_AGENT_RELAY:registryUrl,WASM_AGENT_ENDPOINT:'127.0.0.1:'+callerPort});
  await until(()=>fetch('http://127.0.0.1:'+peerPort+'/health').then(r=>r.ok),'peer');await until(()=>fetch('http://127.0.0.1:'+callerPort+'/health').then(r=>r.ok),'caller');
  const signed=`
local json=dofile('lua/vendor/json.lua');local nodes=dofile('lua/core/nodes.lua');local o=dofile('lua/core/orchestrator.lua')
local destination='${peer.node_id}'
local checks=0;local function check(v,label) assert(v,label);checks=checks+1;print('ok '..label) end
for i=1,100 do if nodes.find(destination) then break end host.sleep(100) end
local raw=nodes.remote_call(destination,'status',{model='fixture',provider='opencode-go',serving_identity_only=true})
print('SIGNED_IDENTITY '..json.encode(raw));local identity=raw.serving_identity
check(identity and identity.node_id==destination and identity.model=='fixture' and identity.provider=='opencode-go','actual authenticated peer establishes requested identity')
local response=nodes.remote_call(destination,'status',{model='fixture',serving_identity=identity})
print('SIGNED_STATUS '..json.encode(response))
check(response.serving and response.serving.state=='blocked','signed status reads durable monthly account block')
check(o.serving_eligible(destination,'fixture','opencode-go')==false,'actual signed exact tuple skips blocked peer')
check(o.serving_eligible(destination,'fixture','foreign-provider')==true,'explicit unsupported provider override remains unknown')
identity.account_profile='foreign-account'
local changed=nodes.remote_call(destination,'status',{model='fixture',serving_identity=identity})
check(changed.serving.state=='unknown' and changed.serving.reason=='serving_identity_changed','foreign requested account cannot inherit default account block')
print('signed two-node serving: '..checks..' checks, 0 skips, 0 paid calls')
`;
  const before=requests.length;
  await script(mode+'-signed-status',signed,{...callerEnv,WASM_AGENT_RENDEZVOUS:registryUrl,WASM_AGENT_RELAY:registryUrl},callerDb);
  assert.equal(requests.length,before,'signed status must spend zero inference requests');
  for(const child of [callerProcess,peerProcess,registry]){const done=new Promise(r=>child.once('exit',r));child.kill();await done;}
 }
 console.log('Actual source + embedded HTTP inference boundaries, restarts and signed two-node serving passed; 0 skips, 0 paid calls; '+out);
})().catch(e=>{console.error(e.stack);process.exitCode=1;}).finally(async()=>{for(const child of children.reverse()){if(child.exitCode===null&&child.signalCode===null){const done=new Promise(r=>child.once('exit',r));child.kill();await done;}}if(mock)await new Promise(r=>mock.close(r));});
