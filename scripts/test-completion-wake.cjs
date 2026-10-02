// Real isolated serve process + mock provider. No live account or paid inference.
const fs=require('fs'),os=require('os'),path=require('path'),http=require('http'),net=require('net'),assert=require('assert/strict');
const {spawn}=require('child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2] || (process.platform==='win32' ? 'rust/target/release/wa.exe' : 'rust/target/release/wa'));
const home=fs.mkdtempSync(path.join(os.tmpdir(),'wa-completion-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(k)));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,label){for(let i=0;i<200;i++){if(await fn())return;await sleep(100);}throw Error(label);}
async function port(){return new Promise(r=>{const s=net.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>r(p));});});}
let child,mock,wakes=0,delegated=false,runawayDelegated=false,runawayNotice='',supersededDelegated=false,afterSupersededDelegated=false;
(async()=>{try{
 mock=http.createServer((req,res)=>{let body='';req.on('data',c=>body+=c);req.on('end',()=>{
  const b=JSON.parse(body),last=b.messages.filter(m=>m.role==='user').at(-1)?.content || '';
  let message={content:'finished',role:'assistant'},finish='stop';
  if(String(last).includes('[Child completion notice]')) {wakes++;if(String(last).includes('"error":"runaway_guard"')) runawayNotice=String(last);message.content='completion reviewed';}
  else if(b.messages.some(m=>m.role==='system' && String(m.content).includes('You are a subagent')) && String(JSON.stringify(b.messages)).includes('RUNAWAY-CHILD')) {finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'runaway-loop',type:'function',function:{name:'ls',arguments:'{"path":"."}'}}]};}
  else if(String(last)==='delegate runaway once' && !runawayDelegated) {runawayDelegated=true;finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'runaway-delegate',type:'function',function:{name:'subagent',arguments:JSON.stringify({action:'start',profile:'explore',prompt:'RUNAWAY-CHILD',idempotency_key:'runaway-completion-fixture',title:'runaway-child'})}}]};}
  else if(String(last)==='delegate once' && !delegated) {delegated=true;finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'delegate',type:'function',function:{name:'subagent',arguments:JSON.stringify({action:'start',profile:'explore',prompt:'child work',idempotency_key:'completion-fixture'})}}]};}
  else if(String(last)==='delegate superseded once' && !supersededDelegated) {supersededDelegated=true;finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'delegate-superseded',type:'function',function:{name:'subagent',arguments:JSON.stringify({action:'start',profile:'explore',prompt:'child work under supersede',idempotency_key:'completion-superseded-fixture',title:'superseded-child'})}}]};}
  else if(String(last)==='delegate after supersede once' && !afterSupersededDelegated) {afterSupersededDelegated=true;finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'delegate-after',type:'function',function:{name:'subagent',arguments:JSON.stringify({action:'start',profile:'explore',prompt:'child work after supersede',idempotency_key:'completion-after-fixture',title:'after-supersede-child'})}}]};}
  const usage={prompt_tokens:100,completion_tokens:20,total_tokens:120};
  if(b.stream){res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: '+JSON.stringify({choices:[{delta:message,finish_reason:finish}],usage})+'\n\ndata: [DONE]\n\n');}
  else {res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({choices:[{message,finish_reason:finish}],usage}));}
 });});
 await new Promise(r=>mock.listen(0,'127.0.0.1',r));const p=await port(),cp=await port();
 const log=fs.openSync(path.join(home,'node.log'),'a');
 child=spawn(binary,['serve','--port',String(p),'--client-port',String(cp),'--ui',path.join(root,'ui')],{cwd:home,env:{...env,WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:root,WASM_AGENT_MANAGED:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+mock.address().port,WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_LLM_API_KEY:'fixture',WASM_AGENT_MAX_TOOL_ROUNDS:'4'},stdio:['ignore',log,log],windowsHide:true});
 const base='http://127.0.0.1:'+p;
 const get=async(route,body)=>{const r=await fetch(base+route,{...(body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(30000)});return r.json();};
 await until(async()=>{try{return (await get('/health')).ok!==false;}catch{return false;}},'startup');
 const answer=await get('/chat',{text:'delegate once',thread:'completion-parent'});assert(!answer.error,JSON.stringify(answer));
 await until(()=>wakes===1,'coordinator wake');await sleep(2500);assert.equal(wakes,1,'one notification, no recurring wake');
 const list=await get('/subagents',{action:'list'});assert.equal(list.subagents.length,1,'completion does not spawn another child');
 const result=await get('/subagents',{action:'result',id:list.subagents[0].subagent_id});assert.equal(result.state,'completed');
 const status=await get('/subagents',{action:'status',id:list.subagents[0].subagent_id});assert(!status.result,'status does not duplicate result');
 await get('/chat',{text:'delegate runaway once',thread:'completion-runaway-parent'});
 await until(()=>wakes===2,'failed-child completion wake');await sleep(2500);
 assert.equal(wakes,2,'failed child completion delivered once');
 assert(runawayNotice.includes('"state":"failed"') && runawayNotice.includes('"error":"runaway_guard"'),runawayNotice);
 // The packet travels with the wake: the coordinator starts from the measured evidence (usage, model,
 // and the artifact facts of the child's own checkout) instead of fetching it in its own turn. The
 // hermetic half of this - the facts themselves, from a real worktree - is scripts/test-completion-packet.lua.
 assert(runawayNotice.includes('Evaluation packet'),runawayNotice.slice(0,600));
 assert(runawayNotice.includes('"usage"') && runawayNotice.includes('"artifacts"') && runawayNotice.includes('"child"'),
   'the wake carries the settlement packet: '+runawayNotice.slice(0,600));
 const tasks=await get('/subagents',{action:'list'}),failed=tasks.subagents.find(t=>t.title==='runaway-child');
 assert(failed && failed.state==='failed' && failed.error==='runaway_guard','runaway child state: '+JSON.stringify(failed));
 // The hook's supersede path, which is what stops one settle from producing two wakes. The sentinel writes
 // `<config>/sentinel/completion-wake-superseded` from the enabled `onSubagentReturn` job (a definition that
 // declares "supersedes": "completion_wake"), and this outbox then does not send its own notice: the hook's
 // wake carries the same measured facts and the deploy instruction. Without the marker, unchanged - which
 // is what the four wakes above were counted under.
 const marker=path.join(home,'.wasm-agent','sentinel','completion-wake-superseded');
 fs.mkdirSync(path.dirname(marker),{recursive:true});
 fs.writeFileSync(marker,JSON.stringify({schema:1,by:['onSubagentReturn'],at:0}));
 await get('/chat',{text:'delegate superseded once',thread:'completion-superseded-parent'});
 await until(async()=>{const t=(await get('/subagents',{action:'list'})).subagents.find(x=>x.title==='superseded-child');return t&&t.state==='completed';},'superseded child settles');
 await sleep(2500);
 assert.equal(wakes,2,'a superseded settle sends no outbox wake');
 const supersededChild=(await get('/subagents',{action:'list'})).subagents.find(t=>t.title==='superseded-child');
 const supersededStatus=await get('/subagents',{action:'status',id:supersededChild.subagent_id});
 assert(supersededStatus.completion && supersededStatus.completion.state==='superseded',
   'the completion row records the supersession instead of a wake: '+JSON.stringify(supersededStatus.completion));
 fs.rmSync(marker,{force:true});
 await get('/chat',{text:'delegate after supersede once',thread:'completion-after-parent'});
 await until(()=>wakes===3,'the outbox wake resumes when the marker is gone');
 console.log('completion wake ok (real scheduler, mock inference, deduplication, one failed-child notice, no recursive child, the hook supersedes the notice while its marker is present)');
 }finally{if(child){child.kill();await new Promise(r=>child.once('exit',r));}if(mock){mock.closeAllConnections();await new Promise(r=>mock.close(r));}console.log('evidence: '+home);}})().catch(e=>{console.error(e);process.exitCode=1;});
