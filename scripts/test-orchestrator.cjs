// Two actual isolated nodes, signed fabric calls, mock inference; no live account.
const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const http=require('node:http'), net=require('node:net');
const {spawn,spawnSync}=require('node:child_process');
const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
const binary=path.resolve(process.argv[2] || (process.platform==='win32' ? 'rust/target/release/wa.exe' : 'rust/target/release/wa'));
const work=fs.mkdtempSync(path.join(os.tmpdir(),'wa-orchestrator-'));
const clean=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WASM_AGENT_|WA_|OPENAI_API_KEY$|OPENCODE_GO_API_KEY$)/i.test(key)));
const children=[], seen=[], pending=[];
let checks=0, mock;
function check(value,label) { assert.ok(value,label);checks++;console.log('ok   '+label); }
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(fn,label) { for(let i=0;i<300;i++) { const value=await fn();if(value)return value;await sleep(100); } throw Error('timeout: '+label); }
function port() { return new Promise(resolve=>{const s=net.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));});}); }
function launch(name,args,env) {
  const log=fs.openSync(path.join(work,name+'.log'),'a');
  const child=spawn(binary,args,{cwd:work,env,stdio:['ignore',log,log],windowsHide:true});children.push(child);return child;
}
function fixture(name) {
  const home=path.join(work,name);fs.mkdirSync(home,{recursive:true});
  const env={...clean,WASM_AGENT_HOME:home,WA_GRAPH_WATCH:'0',WASM_AGENT_LUA_ROOT:root};
  const result=spawnSync(binary,['node'],{cwd:work,env,encoding:'utf8',windowsHide:true});
  assert.equal(result.status,0,result.stderr);
  return {name,env,home,...JSON.parse(result.stdout)};
}
async function get(url,body) {
  const response=await fetch(url,{...(body ? {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)} : {}),signal:AbortSignal.timeout(70000)});
  const text=await response.text();try{return JSON.parse(text);}catch{return {raw:text,status:response.status};}
}
async function startNode(node,registry,model) {
  const p=await port(),client=await port();node.url='http://127.0.0.1:'+p;
  node.child=launch(node.name,['serve','--port',String(p),'--client-port',String(client),'--ui',path.join(root,'ui')],{
    ...node.env,WASM_AGENT_RENDEZVOUS:registry,WASM_AGENT_RELAY:registry,
    WASM_AGENT_ENDPOINT:'127.0.0.1:'+p,WASM_AGENT_LLM_BASE_URL:model,
    WASM_AGENT_LLM_API_KEY:'fixture',WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_SUBAGENT_MAX_CONCURRENT:'2',
  });
  await until(async()=>{try{return await get(node.url+'/health');}catch{return false;}},node.name+' startup');
}
async function stop(child) { if(child.exitCode!==null || child.signalCode!==null)return;const done=new Promise(r=>child.once('exit',r));child.kill();await done; }

(async()=>{
  // Force cancellation between the queue snapshot and reservation: no worker may start.
  const raceScript=path.join(work,'cancel-race.lua');
  fs.writeFileSync(raceScript,`
local real_dofile=dofile
local json=real_dofile("lua/vendor/json.lua")
dofile=function(p)
  if p=="lua/core/nodes.lua" then return {is_master=function() return true end} end
  if p=="lua/core/users.lua" then return {find=function() return {role="master"} end,is_master=function() return true end} end
  if p=="lua/core/provider.lua" then return {} end
  return real_dofile(p)
end
host.sql_query=function(sql)
  if sql:find("SELECT policy",1,true) then return json.encode({{policy=json.encode({enabled=true,nodes={{node="local",max_tasks=1}}})}}) end
  return json.encode({{id="cancel-race",owner="fixture",state="queued",destination="",args="{}",context="{}"}})
end
local reservations=0
host.sql_exec=function(sql)
  assert(sql:find("state='placing'",1,true),sql)
  reservations=reservations+1
  return json.encode({ok=true,changes=0}) -- cancellation already won
end
real_dofile("lua/core/orchestrator.lua").tick({control=function() error("cancelled task executed") end})
assert(reservations==1)
print("cancel race ok")
`);
  const race=spawnSync(binary,['--db',path.join(work,'cancel-race.db')],{cwd:work,env:{...clean,WASM_AGENT_HOME:path.join(work,'race-home'),WASM_AGENT_LUA_ROOT:root,WA_SCRIPT:raceScript},encoding:'utf8',timeout:30000,windowsHide:true});
  check(race.status===0 && race.stdout.includes('cancel race ok'),'cancellation wins before admission: '+(race.stderr||''));
  mock=http.createServer((req,res)=>{
    let body='';req.on('data',chunk=>body+=chunk);req.on('end',()=>{
      const request=JSON.parse(body);seen.push(request);
      const last=request.messages.filter(m=>m.role==='user').at(-1)?.content || '';
      const answer=()=>{if(!res.headersSent)res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: '+JSON.stringify({choices:[{delta:{content:'verified '+last},finish_reason:'stop'}],usage:{prompt_tokens:10,completion_tokens:4,total_tokens:14}})+'\n\ndata: [DONE]\n\n');};
      if(last.includes('HOLD')) {
        res.writeHead(200,{'content-type':'text/event-stream'});
        res.write('data: '+JSON.stringify({choices:[{delta:{content:'working '},finish_reason:null}]})+'\n\n');
        pending.push(answer);
      } else answer();
    });
  });
  await new Promise(resolve=>mock.listen(0,'127.0.0.1',resolve));
  const model='http://127.0.0.1:'+mock.address().port;
  const coordinator=fixture('coordinator'),cloud=fixture('cloud'),registry=fixture('registry');
  const registryUrl='http://127.0.0.1:'+await port();
  launch('registry',['rendezvous','--port',registryUrl.split(':').at(-1),'--db',path.join(registry.home,'registry.db')],{
    ...registry.env,WASM_AGENT_NETWORK_ADMINS:[coordinator.node_id,cloud.node_id].join(',')});
  await until(async()=>{try{return await get(registryUrl+'/health');}catch{return false;}},'registry startup');
  await startNode(cloud,registryUrl,model);await startNode(coordinator,registryUrl,model);
  const call=body=>get(coordinator.url+'/subagents',body);
  await until(async()=>{const f=await call({action:'fleet'});return f.nodes?.some(n=>n.node_id===cloud.node_id);},'peer discovery');
  const policy={enabled:true,nodes:[{node:cloud.node_id,max_tasks:1},{node:'local',max_tasks:1}]};
  check((await call({action:'placement',policy})).policy.nodes[0].node===cloud.node_id,'ordered placement persists');
  check((await call({action:'placement',policy:{enabled:true,nodes:[{node:'local',max_tasks:-1}]}})).error==='invalid_node_limit','invalid capacity is refused');
  const first=await call({action:'start',prompt:'HOLD first',idempotency_key:'first'});
  const duplicate=await call({action:'start',prompt:'HOLD first',idempotency_key:'first'});
  check(first.subagent_id===duplicate.subagent_id,'queued submission is idempotent');
  const status=id=>call({action:'status',id});
  const a=await until(async()=>{const a=await status(first.subagent_id);return a.session_id && a;},'first placement');
  check(a.execution_node===cloud.node_id,'first task fills preferred cloud node');
  const preview=await until(async()=>{const value=await status(first.subagent_id);return value.preview?.text && value;},'live child preview');
  check(preview.preview.text.includes('working'),'in-flight child text is visible before settlement');
  const second=await call({action:'start',prompt:'HOLD second',idempotency_key:'second'});
  const b=await until(async()=>{const b=await status(second.subagent_id);return b.session_id && b;},'overflow placement');
  check(b.execution_node==='local' && b.session_id!==a.session_id,'overflow uses next node with a separate session');
  const third=await call({action:'start',prompt:'third',idempotency_key:'third'});
  await sleep(2500);
  check((await status(third.subagent_id)).state==='queued','all-full work remains durably queued');
  const steering=await call({action:'steer',id:first.subagent_id,text:'remote corrected requirement',idempotency_key:'remote-steer'});
  assert.equal(steering.state,'queued','signed peer path accepts live steering');
  const turn=await call({action:'message',id:first.subagent_id,text:'follow up',idempotency_key:'follow'});
  check(turn.session_id===a.session_id && turn.after_id,'direct conversation keeps session and serializes its next run');
  const repeated=await call({action:'message',id:first.subagent_id,text:'follow up',idempotency_key:'follow'});
  check(repeated.remote_subagent_id===turn.remote_subagent_id,'repeated direct message does not create a second run');
  const bypass=await get(coordinator.url+'/chat',{text:'bypass',thread:b.session_id});
  check(JSON.stringify(bypass).includes('use_subagent_message'),'ordinary chat cannot broaden child authority');
  check((await call({action:'cancel',id:third.subagent_id})).state==='cancelled','queued work cancels without execution');
  await until(()=>pending.length===2,'both inference requests');
  pending.splice(0).forEach(release=>release());
  const done=await until(async()=>{const value=await status(first.subagent_id);return value.settled && value;},'continued session settlement');
  check(done.state==='completed','remote follow-up settles');
  const transcript=await call({action:'session',id:first.subagent_id});
  check(transcript.messages.filter(m=>m.role==='user').length===3 && transcript.messages.some(m=>m.content==='remote corrected requirement'),'original prompts and steering survive in one child transcript');
  assert(seen.some(r=>r.messages.at(-1)?.content==='remote corrected requirement'),'remote steering reaches next model call');
  const childRequests=seen.filter(r=>r.messages[0].content.includes('subagent'));
  check(childRequests.every(r=>r.messages[0].content.includes('# Subagent') && !r.messages[0].content.includes('# Orchestrator')),'children receive only their execution-role instructions');
  check(childRequests.every(r=>!r.tools.some(t=>t.function.name==='bash')),'continuation preserves the read-only profile');
  await stop(coordinator.child);
  await startNode(coordinator,registryUrl,model);
  check((await call({action:'fleet'})).policy.nodes[0].node===cloud.node_id,'node hierarchy survives coordinator restart');
  check((await status(first.subagent_id)).session_id===a.session_id,'remote session identity survives coordinator restart');
  await call({action:'placement',policy:{enabled:true,nodes:[{node:cloud.node_id,max_tasks:0},{node:'local',max_tasks:0}]}});
  const excluded=await call({action:'start',prompt:'excluded nodes',idempotency_key:'excluded'});
  await sleep(2500);
  check((await status(excluded.subagent_id)).state==='queued','zero limits exclude every device from execution');
  check((await call({action:'cancel',id:excluded.subagent_id})).state==='cancelled','excluded-node work can be cancelled without a worker');
  console.log(`node orchestration ok (${checks} checks, 0 skipped)`);
  console.log(`evidence: ${work}`);
})().catch(error=>{console.error(error.stack);console.error('FAIL; evidence '+work);process.exitCode=1;}).finally(async()=>{
  pending.splice(0).forEach(release=>release());for(const child of children.reverse())await stop(child);
  if(mock)await new Promise(resolve=>mock.close(resolve));
});
