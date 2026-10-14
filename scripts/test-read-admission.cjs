// Real private node, two read/control slots, no inference or installed UI access.
// node scripts/test-read-admission.cjs <candidate-wa> <fresh-evidence> [baseline-wa]
// node scripts/test-read-admission.cjs --post <candidate-wa> <evidence> [baseline-wa]
'use strict';
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),crypto=require('node:crypto');
const {spawn}=require('node:child_process'),{once}=require('node:events'),assert=require('node:assert/strict');
const post=process.argv[2]==='--post',args=process.argv.slice(post?3:2),repo=path.resolve(__dirname,'..');
assert(args[0]&&args[1],'candidate and fresh evidence required');
const binary=path.resolve(args[0]),out=path.resolve(args[1]),baseline=args[2]&&path.resolve(args[2]);
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const sources=()=>Object.fromEntries(['rust/wa-host/src/serve.rs','scripts/test-read-admission.cjs'].map(p=>[p,hash(path.join(repo,p))]));
if(post){const r=JSON.parse(fs.readFileSync(out+'/receipt.json'));assert(r.ok&&r.skipped===0);assert.deepEqual(r.sources,sources());assert.equal(r.binary_sha256,hash(binary));if(baseline)assert.equal(r.baseline_sha256,hash(baseline));for(const [p,h] of Object.entries(r.logs))assert.equal(hash(out+'/'+p),h);console.log(JSON.stringify({ok:true,checks:r.checks,skipped:0,evidence_verified:true}));process.exit(0);}
assert(!fs.existsSync(out),'fresh evidence required');fs.mkdirSync(out,{recursive:true});
const report={ok:false,checks:[],skipped:0,sources:sources(),binary_sha256:hash(binary),...(baseline?{baseline_sha256:hash(baseline)}:{})};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function check(ok,label){assert(ok,label);report.checks.push(label);}
async function until(fn,label){const end=Date.now()+5000;do{if(await fn())return;await sleep(5);}while(Date.now()<end);throw Error('deadline: '+label);}
async function port(){const s=http.createServer();s.listen(0,'127.0.0.1');await once(s,'listening');const p=s.address().port;await new Promise(r=>s.close(r));assert(![8799,8800].includes(p));return p;}
async function run(program,name,old){
 const root=path.join(out,name);fs.mkdirSync(root);fs.mkdirSync(root+'/lua/core',{recursive:true});fs.mkdirSync(root+'/lua/vendor');fs.copyFileSync(repo+'/lua/vendor/json.lua',root+'/lua/vendor/json.lua');
 fs.writeFileSync(root+'/lua/core/subagents.lua','-- private fixture\n');
 fs.writeFileSync(root+'/lua/core/server.lua',`local json=dofile('lua/vendor/json.lua')
local root=assert(host.getenv('WASM_AGENT_HOME'))
local function reply(id)
 assert(type(id)=='string' and id:match('^[a-z0-9%-]+$'))
 assert(host.write_file(root..'/'..id..'.entered','entered'))
 if id:match('^hold%-') then
  local start=host.monotonic_ms()
  while not host.read_file(root..'/'..id..'.release') do
   if host.monotonic_ms()-start>15000 then error('fixture barrier deadline') end
   host.sleep(5)
  end
 end
 return json.encode({fixture=true,id=id})
end
function wa_me(session) return reply(session) end
function wa_model(node,session) return reply(session) end
function wa_subagents(body,session) return reply(json.decode(body).id) end
function wa_sync_tick() return '{}' end
function wa_orchestrator_tick() return '{}' end
`);
 fs.mkdirSync(root+'/ui');fs.writeFileSync(root+'/ui/index.html','<!doctype html><title>private read admission</title>');
 const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!(/^(WA_|WASM_AGENT_|OPENAI_|ANTHROPIC_|OPENCODE_|CODEX_|PI_)/i.test(k))));
 Object.assign(env,{HOME:root,USERPROFILE:root,APPDATA:root,LOCALAPPDATA:root,WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:root,WA_GRAPH_WATCH:'0',WA_GRAPH_DB:root+'/graph.db',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_WORKERS:'3',WASM_AGENT_WORKERS_MAX:'4',WASM_AGENT_CONTROL_WORKERS:'2',WASM_AGENT_READ_QUEUE_DEPTH:'2',WASM_AGENT_WORKERS_IDLE_SECONDS:'60',WASM_AGENT_WORKER_STALL_EXIT_SECONDS:'0'});
 const p=await port(),clientPort=await port(),log=fs.openSync(root+'/node.log','w');
 const child=spawn(program,['--db',root+'/memory.db','serve','--port',String(p),'--client-port',String(clientPort),'--ui',root+'/ui'],{cwd:root,env,windowsHide:true,stdio:['ignore',log,log]});fs.closeSync(log);
 const sockets=new Set(),requests=[];let fatal;
 child.on('error',e=>fatal=e);
 function request(route,id){const start=Date.now(),r={route,id,done:false};requests.push(r);
  r.promise=new Promise((resolve,reject)=>{const body=route==='/subagents'?JSON.stringify({action:'events',id}):'';const req=http.request({host:'127.0.0.1',port:p,path:route,method:body?'POST':'GET',agent:false,headers:{connection:'close','content-length':Buffer.byteLength(body),'content-type':'application/json','x-wa-session':id||''}},res=>{let text='';res.setEncoding('utf8');res.on('data',s=>text+=s);res.on('end',()=>{clearTimeout(timer);Object.assign(r,{done:true,status:res.statusCode,value:JSON.parse(text),ms:Date.now()-start});resolve(r);});});const timer=setTimeout(()=>req.destroy(Error('request deadline')),5000);req.on('socket',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});req.on('error',e=>{clearTimeout(timer);reject(e);});req.end(body);});
  // Preserve a failure without an unhandled rejection while barriers are held.
  r.promise.catch(()=>{});return r;
 }
 const entered=id=>fs.existsSync(root+'/'+id+'.entered'),release=id=>fs.writeFileSync(root+'/'+id+'.release','release');
 const healthy=r=>{assert.equal(r.status,200,JSON.stringify(r));assert(!r.value.error);return r.value;};
 try{
  await once(child,'spawn');await until(async()=>{if(fatal)throw fatal;try{return(await request('/health').promise).status===200;}catch{return false;}},'private listener');
  healthy(await request('/me','seed').promise);
  const a=request('/subagents','hold-a');await until(()=>entered('hold-a'),'first read/control holder');
  const b=request('/models','hold-b');await until(()=>entered('hold-b'),'second read/control holder');
  const before=healthy(await request('/health').promise);
  check(before.node_threads.filter(t=>t.role==='reads'&&t.label).length===2,name+': exactly two occupied independent read slots');
  if(!old)check(before.read_admission.timeout_ms===250&&before.read_admission.queue_depth===2,'default admission budget and configured queue bound are reported');
  const burst=request('/subagents','follow-burst');await sleep(25);
  const h=await request('/health').promise;healthy(h);check(h.ms<150,name+': health remains prompt during contention');
  if(!old){check(!burst.done,'short collision waits instead of refusing immediately');check(h.value.read_admission.waiting===1,'health exposes bounded admission wait');}
  release('hold-b');healthy(await b.promise);const result=await burst.promise;
  if(old){check(result.status===503&&result.value.error==='read_capacity_busy','baseline reproduces follow read refusal on a short collision');return;}
  healthy(result);check(result.value.id==='follow-burst'&&entered('follow-burst'),'follow read succeeds after short collision without extra capacity');check(!a.done,'unrelated long control remains occupied');
  const c=request('/models','hold-c');await until(()=>entered('hold-c'),'sustained second holder');
  const expire=await request('/subagents','expired-follow').promise;
  check(expire.status===503&&expire.value.error==='read_capacity_busy'&&expire.ms>=200&&expire.ms<750,'sustained overload refuses within bounded admission deadline');
  check(!entered('expired-follow'),'expired read never enters Lua');
  const overflow=Array.from({length:8},(_,i)=>request('/subagents','overflow-'+i));await sleep(25);
  const under=await request('/health').promise;healthy(under);check(under.ms<150&&under.value.read_admission.waiting<=3,'queue is bounded and never parks the listener');
  await Promise.all(overflow.map(r=>r.promise));check(overflow.every(r=>r.status===503&&r.value.error==='read_capacity_busy'&&r.ms<750),'queue overflow and expiry are explicit, bounded refusals');
  check(overflow.every(r=>!entered(r.id)),'queued expired requests have no late Lua execution');
  release('hold-c');healthy(await c.promise);
  // Another window occupies one slot: every completion-to-next-request edge must remain usable.
  for(let i=0;i<128;i++)healthy(await request('/subagents','sequential-'+i).promise);
  check(!a.done,'128 sequential follow reads succeed with the other slot still occupied');
  release('hold-a');healthy(await a.promise);
  await until(async()=>healthy(await request('/health').promise).read_admission.waiting===0,'admission queue drained');
  check(healthy(await request('/health').promise).node_threads.filter(t=>t.role==='reads').length===2,'read capacity did not grow');
 }finally{
  for(const id of ['hold-a','hold-b','hold-c'])release(id);
  for(const socket of sockets)socket.destroy();
  let timer;const exited=once(child,'exit');child.kill();await Promise.race([exited,new Promise(resolve=>timer=setTimeout(resolve,5000))]);clearTimeout(timer);check(child.exitCode!==null||child.signalCode!==null,name+': owned process exit observed');
  fs.writeFileSync(root+'/requests.json',JSON.stringify(requests.map(({promise,...r})=>r),null,2));
 }
}
(async()=>{try{if(baseline)await run(baseline,'baseline',true);await run(binary,'candidate',false);report.ok=true;}catch(e){report.error=e.stack;}finally{report.logs={};for(const name of baseline?['baseline','candidate']:['candidate'])for(const file of ['node.log','requests.json']){const p=name+'/'+file;if(fs.existsSync(out+'/'+p))report.logs[p]=hash(out+'/'+p);}fs.writeFileSync(out+'/receipt.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));process.exitCode=report.ok?0:1;}})();
