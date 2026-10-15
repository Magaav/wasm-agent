// Actual owned HTTP admission/steering race; private server and deterministic provider only.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),net=require('node:net'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {spawn}=require('node:child_process'),{once}=require('node:events'),{DatabaseSync}=require('node:sqlite'),{pathToFileURL}=require('node:url');
const repo=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),embedded=process.argv.includes('--embedded');
assert(!fs.existsSync(out),'fresh evidence required');fs.mkdirSync(out,{recursive:true});const home=out+'/h';fs.mkdirSync(home);
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');let checks=0,calls=0,provider,child,port,releaseFirst,firstSeenResolve;
const firstSeen=new Promise(resolve=>firstSeenResolve=resolve),sockets=new Set(),pending=[];
const check=(ok,label)=>{assert(ok,label);checks++;};const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function freePort(){const s=net.createServer();s.listen(0,'127.0.0.1');await once(s,'listening');const p=s.address().port;await new Promise(r=>s.close(r));return p;}
async function api(route,body,headers={}){const r=await fetch('http://127.0.0.1:'+port+'/'+route,{method:body===undefined?'GET':'POST',headers:{'content-type':'application/json',...headers},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(3000)});return {status:r.status,payload:await r.json()};}
function chat(thread,text,extra={},headers={}){const value=fetch('http://127.0.0.1:'+port+'/chat',{method:'POST',headers:{'content-type':'application/json',accept:'text/event-stream',...headers},body:JSON.stringify({thread,text,...extra}),signal:AbortSignal.timeout(20000)}).then(async r=>({status:r.status,text:await r.text()}));value.catch(()=>{});pending.push(value);return value;}
(async()=>{try{
 const {isolatedEnvironment}=await import(pathToFileURL(repo+'/scripts/agent-benchmark-environment.mjs').href);
 provider=http.createServer((req,res)=>{let raw='';req.on('data',b=>raw+=b);req.on('end',()=>{calls++;const body=JSON.parse(raw),text=body.messages.filter(m=>m.role==='user').at(-1)?.content||'';
  const finish=answer=>{res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: '+JSON.stringify({choices:[{delta:{content:answer},finish_reason:'stop'}],usage:{prompt_tokens:20,completion_tokens:5,total_tokens:25}})+'\n\ndata: [DONE]\n\n');};
  if(calls===1){res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: '+JSON.stringify({choices:[{delta:{content:'BACKGROUND-PARTIAL'},finish_reason:null}]})+'\n\n');releaseFirst=()=>res.end('data: '+JSON.stringify({choices:[{delta:{},finish_reason:'stop'}],usage:{prompt_tokens:20,completion_tokens:5,total_tokens:25}})+'\n\ndata: [DONE]\n\n');firstSeenResolve();}
  else finish(String(text).includes('HUMAN CORRECTION')?'CORRECTION-APPLIED':'IDLE-NEXT-ANSWER');
 });});provider.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});provider.listen(0,'127.0.0.1');await once(provider,'listening');
 port=await freePort();const clientPort=await freePort(),dbfile=home+'/memory.db',log=fs.openSync(out+'/server.log','w');
 child=spawn(binary,['--db',dbfile,'serve','--port',String(port),'--client-port',String(clientPort),'--ui',repo+'/ui'],{cwd:repo,env:isolatedEnvironment(home,{WASM_AGENT_LUA_ROOT:embedded?'':repo,WASM_AGENT_PROVIDER:'opencode-go',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+provider.address().port,WASM_AGENT_LLM_API_KEY:'private-fake-only',WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0',WASM_AGENT_COMPLETION_WAKE:'0',WA_GRAPH_WATCH:'0'}),stdio:['ignore',log,log],windowsHide:true});fs.closeSync(log);
 let ready=false;for(let i=0;i<160;i++){try{if((await api('health')).status===200){ready=true;break;}}catch{}await sleep(25);}check(ready,'private server ready');
 const thread='private-human-background-race';
 const background=chat(thread,'[Child completion notice] private deterministic background fixture',{}, {'X-WA-Run-Class':'background'});
 await Promise.race([firstSeen,sleep(5000).then(()=>{throw Error('background model barrier not reached')})]);
 const before=(await api('runs',{action:'status',thread})).payload;check(before.ok&&before.runs.length===1&&before.runs[0].state==='running','background owns one active native run');const first=before.runs[0];
 const refused=await chat(thread,'HUMAN CORRECTION',{if_idle:true});let refusal;try{refusal=JSON.parse(refused.text)}catch{}
 check(refused.status===409&&refusal?.error==='session_busy','stale UI submission gets typed busy refusal, not an SSE queue');
 check(refusal.not_started===true&&refusal.effect==='none'&&refusal.thread===thread,'busy refusal explicitly proves no request admission/effect');
 const during=(await api('runs',{action:'status',thread})).payload;
 check(during.runs.length===1&&during.runs[0].run_key===first.run_key,'busy refusal creates no journal run/backlog');
 check(during.runs[0].state==='running'&&!during.runs[0].cancel_requested&&calls===1,'original background model is neither cancelled nor duplicated');
 const legacy=chat(thread,'LEGACY QUEUED REQUEST MUST NOT EXECUTE');
 let queued;
 for(let i=0;i<40&&!queued;i++){const status=(await api('runs',{action:'status',thread})).payload;queued=status.runs.find(r=>r.state==='queued');if(!queued)await sleep(25);}
 check(queued&&calls===1,'legacy API queue policy remains explicit without a second model call');
 const cancelled=await api('runs',{action:'cancel',thread,run_id:queued.run_key});
 check(cancelled.status===200&&cancelled.payload.cancel_requested&&cancelled.payload.state==='queued','queued cancellation is acknowledged without claiming settlement');
 const afterCancel=(await api('runs',{action:'status',thread})).payload;
 check(afterCancel.runs.find(r=>r.run_key===first.run_key).state==='running'&&!afterCancel.runs.find(r=>r.run_key===first.run_key).cancel_requested,'queued cancellation never targets active coordinator');
 check(afterCancel.runs.find(r=>r.run_key===queued.run_key).cancel_requested,'only intended queued request gets cancel flag');
 const steering={action:'steer_session',session_id:thread,text:'HUMAN CORRECTION',idempotency_key:'same-correction'};
 const accepted=await api('subagents',steering);check(accepted.status===200&&accepted.payload.id&&accepted.payload.state==='queued','existing independent control lane accepts correction');
 const repeated=await api('subagents',steering);check(repeated.payload.id===accepted.payload.id&&repeated.payload.deduplicated,'same correction key produces one durable inbox effect');
 const unauthorized=await api('chat',{thread,text:'must not enter',if_idle:true},{'X-WA-Session':'invalid-private-credential'});
 check(unauthorized.status===401,'invalid identity refused before no-queue admission');
 releaseFirst();const completed=await background;check(completed.status===200&&completed.text.includes('CORRECTION-APPLIED')&&completed.text.includes('"type":"done"'),'same running coordinator consumes correction and completes');
 check(calls===2,'correction causes a new decision in the same run, not another queued chat run');
 await legacy;
 const drained=(await api('runs',{action:'status',thread})).payload;
 check(drained.runs.length===2&&drained.runs.find(r=>r.run_key===first.run_key).state==='completed','active coordinator settles with only the explicitly admitted legacy request beside it');
 check(drained.runs.find(r=>r.run_key===queued.run_key).state==='cancelled'&&calls===2,'cancelled queued request drains without ever executing inference');
 const db=new DatabaseSync(dbfile,{readOnly:true});
 try{const rows=db.prepare('SELECT * FROM steering_inbox WHERE session_id=?').all(thread);check(rows.length===1&&rows[0].state==='read'&&rows[0].message_seq,'actual SQLite steering was consumed once');const m=db.prepare("SELECT COUNT(*) AS n FROM messages WHERE session_id=? AND role='user' AND content='HUMAN CORRECTION'").get(thread);check(m.n===1,'original correction text retained once in the transcript');}finally{db.close();}
 const next=await chat(thread,'idle next',{if_idle:true});check(next.status===200&&next.text.includes('IDLE-NEXT-ANSWER'),'idle new UI request remains admissible');
 const final=(await api('runs',{action:'status',thread})).payload;check(final.runs.length===3&&final.runs.filter(r=>r.state==='completed').length===2&&final.runs.filter(r=>r.state==='cancelled').length===1,'only intentional runs and the explicitly cancelled legacy request remain');
 const receipt={ok:true,checks,skipped:0,embedded,real_provider_calls:0,mock_provider_calls:calls,first_run_key:first.run_key,refusal,binary:{path:binary,sha256:sha(fs.readFileSync(binary))},sources:['rust/wa-host/src/serve.rs','rust/wa-host/src/serve/scheduler.rs','lua/core/agent.lua','lua/core/orchestration_mode.lua','scripts/test-chat-handoff.cjs'].map(p=>({path:p,sha256:sha(fs.readFileSync(repo+'/'+p))}))};fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify({ok:true,checks,skipped:0,embedded,real_provider_calls:0,evidence:out}));
}finally{if(releaseFirst)releaseFirst=()=>{};if(child&&child.exitCode===null&&child.signalCode===null){const done=once(child,'exit');child.kill();await done;}await Promise.allSettled(pending);for(const s of sockets)s.destroy();if(provider)await new Promise(r=>provider.close(r));}})().catch(error=>{console.error(error);process.exitCode=1;});
