// Exercise cancellation through another interpreter while a real tool holds the run worker.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {spawn}=require('node:child_process');const repo=path.resolve(__dirname,'..');const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-operation-control-'));
const wa=path.resolve(process.argv[2]||path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));let child,provider,checks=0,calls=0;
function check(v,label){assert.ok(v,label);checks++}
async function until(f,label){const end=Date.now()+12000;while(Date.now()<end){const v=await f();if(v)return v;await sleep(25)}throw Error('timeout: '+label)}
(async()=>{try{
 provider=http.createServer((q,s)=>{let body='';q.on('data',d=>body+=d);q.on('end',()=>{
  const tool=calls++===0;const message=tool?{role:'assistant',content:null,tool_calls:[{index:0,id:'fixture-call',type:'function',function:{name:'bash',arguments:JSON.stringify({command:'printf ready; sleep 30'})}}]}:{role:'assistant',content:'ok'};
  const choice={message,finish_reason:tool?'tool_calls':'stop'};const usage={prompt_tokens:10,completion_tokens:2,total_tokens:12};
  if(JSON.parse(body).stream){s.writeHead(200,{'content-type':'text/event-stream'});s.end('data: '+JSON.stringify({id:'fixture',choices:[{delta:message,finish_reason:choice.finish_reason}],usage})+'\n\ndata: [DONE]\n\n')}
  else{s.setHeader('content-type','application/json');s.end(JSON.stringify({id:'fixture',choices:[choice],usage}))}
 })});await new Promise(r=>provider.listen(0,'127.0.0.1',r));const modelPort=provider.address().port;
 const reserve=http.createServer();await new Promise(r=>reserve.listen(0,'127.0.0.1',r));const port=reserve.address().port;await new Promise(r=>reserve.close(r));const base='http://127.0.0.1:'+port;
 const env={...process.env,WASM_AGENT_HOME:root,WASM_AGENT_NODE_KEY:path.join(root,'node.key'),WASM_AGENT_NODE_NAME:'operation-control',WASM_AGENT_MANAGED:'0',WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+modelPort,WASM_AGENT_LLM_API_KEY:'fixture-not-a-credential',WASM_AGENT_LLM_MODEL:'fixture'};delete env.WA_SCRIPT;delete env.WASM_AGENT_LUA_ROOT;
 const fd=fs.openSync(path.join(root,'host.log'),'a');child=spawn(wa,['--db',path.join(root,'memory.db'),'serve','--port',String(port),'--client-port','0','--ui',path.join(repo,'ui')],{env,stdio:['ignore',fd,fd],windowsHide:true});
 const get=async route=>(await fetch(base+route,{signal:AbortSignal.timeout(2000)})).json();
 const control=async args=>(await fetch(base+'/operation',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(2000)})).json();
 await until(async()=>{try{return await get('/health')}catch{return false}},'host ready');
 const chat=fetch(base+'/chat',{method:'POST',headers:{'content-type':'application/json',accept:'text/event-stream'},body:JSON.stringify({text:'fixture: exercise the tool',thread:'control-proof'})}).then(r=>r.text());chat.catch(()=>{});
 const health=await until(async()=>{const h=await get('/health');return h.operations?.some(o=>o.output_bytes>=5)&&h},'real tool produced output');const operation=health.operations.find(o=>o.output_bytes>=5);
 check(health.current!==null,'run worker is occupied');check(health.ok,'quiet long work is healthy');
 const listed=await get('/operations');check(JSON.stringify(listed).includes(operation.operation_id),'independent operation listing answers during the call');
 const output=await control({action:'read',id:operation.operation_id,stream:'stdout',offset:0,limit:32});check(output.content==='ready','partial output is observable before process exit');
 const jobs=await get('/jobs');check(Array.isArray(jobs.jobs),'Engine jobs still load during a call');
 const start=Date.now();await control({action:'cancel',id:operation.operation_id});
 const final=await until(async()=>{const s=await control({action:'status',id:operation.operation_id});return s.settled&&s},'operation settles after independent cancel');
 check(final.state==='cancelled'&&final.ok===false,'cancellation is terminal failure, never fake success');check(Date.now()-start<2000,'control does not wait for the blocked run worker');
 const result=await Promise.race([chat,new Promise((_,reject)=>setTimeout(()=>reject(Error('run did not recover')),12000).unref())]);fs.writeFileSync(path.join(root,'run.sse'),result);check(/"type"\s*:\s*"done"/.test(result)&&calls>=2,'run continues and settles after tool cancellation');
 console.log(`operation control ok (${checks} checks; real tool and local mock model, no paid inference)\nevidence: ${root}`);
 }catch(e){console.error(e.stack);console.error('evidence: '+root);process.exitCode=1}finally{if(child&&child.exitCode===null)child.kill();provider?.closeAllConnections();provider?.close()}})();
