// Real isolated serve process + mock provider. No live account or paid inference.
const fs=require('fs'),os=require('os'),path=require('path'),http=require('http'),net=require('net'),assert=require('assert/strict');
const {spawn}=require('child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2] || (process.platform==='win32' ? 'rust/target/release/wa.exe' : 'rust/target/release/wa'));
const home=fs.mkdtempSync(path.join(os.tmpdir(),'wa-completion-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(k)));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,label){for(let i=0;i<200;i++){if(await fn())return;await sleep(100);}throw Error(label);}
async function port(){return new Promise(r=>{const s=net.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>r(p));});});}
let child,mock,wakes=0,delegated=false,runawayDelegated=false,runawayNotice='';
(async()=>{try{
 mock=http.createServer((req,res)=>{let body='';req.on('data',c=>body+=c);req.on('end',()=>{
  const b=JSON.parse(body),last=b.messages.filter(m=>m.role==='user').at(-1)?.content || '';
  let message={content:'finished',role:'assistant'},finish='stop';
  if(String(last).includes('[Child completion notice]')) {wakes++;if(String(last).includes('"error":"runaway_guard"')) runawayNotice=String(last);message.content='completion reviewed';}
  else if(b.messages.some(m=>m.role==='system' && String(m.content).includes('You are a subagent')) && String(JSON.stringify(b.messages)).includes('RUNAWAY-CHILD')) {finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'runaway-loop',type:'function',function:{name:'ls',arguments:'{"path":"."}'}}]};}
  else if(String(last)==='delegate runaway once' && !runawayDelegated) {runawayDelegated=true;finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'runaway-delegate',type:'function',function:{name:'subagent',arguments:JSON.stringify({action:'start',profile:'explore',prompt:'RUNAWAY-CHILD',idempotency_key:'runaway-completion-fixture',title:'runaway-child'})}}]};}
  else if(String(last)==='delegate once' && !delegated) {delegated=true;finish='tool_calls';message={role:'assistant',content:'',tool_calls:[{id:'delegate',type:'function',function:{name:'subagent',arguments:JSON.stringify({action:'start',profile:'explore',prompt:'child work',idempotency_key:'completion-fixture'})}}]};}
  const usage={prompt_tokens:100,completion_tokens:20,total_tokens:120};
  if(b.stream){res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: '+JSON.stringify({choices:[{delta:message,finish_reason:finish}],usage})+'\n\ndata: [DONE]\n\n');}
  else {res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({choices:[{message,finish_reason:finish}],usage}));}
 });});
 await new Promise(r=>mock.listen(0,'127.0.0.1',r));const p=await port(),cp=await port();
 const log=fs.openSync(path.join(home,'node.log'),'a');
 child=spawn(binary,['serve','--port',String(p),'--client-port',String(cp),'--ui',path.join(root,'ui')],{cwd:home,env:{...env,WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:root,WASM_AGENT_MANAGED:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+mock.address().port,WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_LLM_API_KEY:'fixture',WASM_AGENT_MAX_TOOL_ROUNDS:'3'},stdio:['ignore',log,log],windowsHide:true});
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
 const tasks=await get('/subagents',{action:'list'}),failed=tasks.subagents.find(t=>t.title==='runaway-child');
 assert(failed && failed.state==='failed' && failed.error==='runaway_guard','runaway child state: '+JSON.stringify(failed));
 console.log('completion wake ok (real scheduler, mock inference, deduplication, one failed-child notice, no recursive child)');
 }finally{if(child){child.kill();await new Promise(r=>child.once('exit',r));}if(mock){mock.closeAllConnections();await new Promise(r=>mock.close(r));}console.log('evidence: '+home);}})().catch(e=>{console.error(e);process.exitCode=1;});
