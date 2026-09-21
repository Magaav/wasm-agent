// Integrated admission proof: two interactive SSE conversations while child inference
// occupies every background slot. Uses isolated state and a local mock provider only.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const {spawn, spawnSync} = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || process.env.WA_BIN || path.join(repo, 'rust/target/release/wa' + (process.platform === 'win32' ? '.exe' : '')));
const sentinel = path.resolve(process.argv[3] || path.join(repo,'rust/wa-sentinel/target/release/wa-sentinel'+(process.platform==='win32'?'.exe':'')));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-orchestration-e2e-'));
const config = path.join(root, '.wasm-agent');
fs.mkdirSync(path.join(config, 'subagent-profiles'), {recursive:true});
let checks = 0, child, watcher, provider, hostLog, watcherLog;
const held = new Map(), requests = [];
const check = (value, label) => { assert.ok(value, label); checks++; };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(fn, label, timeout=15000) {
  const deadline = Date.now()+timeout;
  while (Date.now()<deadline) { if (await fn()) return; await sleep(30); }
  throw Error('deadline: '+label);
}
async function listen(server) { await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);}); return server.address().port; }
async function freePort() {const s=http.createServer();const p=await listen(s);await new Promise(r=>s.close(r));return p;}
function answer(res, label) {
  if (res.destroyed || res.writableEnded) return;
  res.writeHead(200, {'content-type':'text/event-stream'});
  res.end('data: '+JSON.stringify({choices:[{delta:{content:label},finish_reason:'stop'}],usage:{prompt_tokens:20,completion_tokens:4,total_tokens:24}})+'\n\ndata: [DONE]\n\n');
}
(async()=>{
  try {
    provider=http.createServer((req,res)=>{
      let body='';req.on('data',c=>body+=c);req.on('end',()=>{
        let input;try{input=JSON.parse(body);}catch{res.writeHead(400);res.end();return;}
        requests.push(input);
        const user=(input.messages||[]).filter(m=>m.role==='user').map(m=>typeof m.content==='string'?m.content:JSON.stringify(m.content)).join('\n');
        const background=user.match(/BACKGROUND_[123]/)?.[0];
        if(background){held.set(background,res);return;}
        const interactive=user.includes('INTERACTIVE_A')?'ANSWER_A':user.includes('INTERACTIVE_B')?'ANSWER_B':'CHILD_DONE';
        // Delay long enough to overlap the interactive requests without depending on model speed.
        setTimeout(()=>answer(res,interactive),400);
      });
    });
    const modelPort=await listen(provider), port=await freePort();
    fs.writeFileSync(path.join(config,'AGENTS.md'),'OPERATOR_CONTEXT_MUST_NOT_REACH_CHILD_4189');
    fs.writeFileSync(path.join(config,'subagent-profiles/proof-lean.json'),JSON.stringify({
      schema_version:1,id:'proof-lean',instructions:'Answer the supplied bounded task. No tools are authorized.',
      allowed_tools:[],resources:{},limits:{timeout_seconds:40,max_output_bytes:4096,max_tokens:8000},
    }));
    const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WASM_AGENT_|WA_|OPENAI_|OPENCODE_)/.test(k)));
    const env={...clean,WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WASM_AGENT_LLM_BASE_URL:`http://127.0.0.1:${modelPort}`,
      WASM_AGENT_LLM_API_KEY:'fixture-only',WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_AGENTS_MD:path.join(config,'AGENTS.md'),
      WASM_AGENT_SUBAGENT_MAX_CONCURRENT:'2',WASM_AGENT_SUBAGENT_QUEUE_DEPTH:'4'};
    hostLog=fs.openSync(path.join(root,'node.log'),'a');
    child=spawn(wa,['--db',path.join(config,'memory.db'),'serve','--port',String(port),'--client-port','0','--ui',path.join(repo,'ui')],{env,stdio:['ignore',hostLog,hostLog],windowsHide:true});
    child.on('error',error=>console.error(error));
    const base=`http://127.0.0.1:${port}`;
    const api=async(body,headers={})=>{
      const r=await fetch(base+'/subagents',{method:'POST',headers:{'content-type':'application/json',...headers},body:JSON.stringify(body),signal:AbortSignal.timeout(12000)});
      const text=await r.text();let value;try{value=JSON.parse(text);}catch{throw Error(`subagents HTTP${r.status}: ${text}`);}
      return {status:r.status,...value};
    };
    await until(async()=>{try{return(await fetch(base+'/health',{signal:AbortSignal.timeout(500)})).ok;}catch{return false;}},'node ready');
    const receipts=[];
    for(let n=1;n<=2;n++){
      const r=await api({action:'start',profile:'proof-lean',prompt:`BACKGROUND_${n}`,idempotency_key:`proof-${n}`});
      check(r.status===200 && r.subagent_id && !r.error,'durable child admission '+JSON.stringify(r));receipts.push(r);
    }
    await until(()=>held.size===2,'two background inference requests started');
    check([...held.values()].every(r=>!r.writableEnded),'both background requests remain in flight');
    const duplicate=await api({action:'start',profile:'proof-lean',prompt:'BACKGROUND_1',idempotency_key:'proof-1'});
    check(duplicate.subagent_id===receipts[0].subagent_id,'same delivery returns the same child');
    // Submit the queued child through an actual portable Job + Delivery, not a simulated endpoint.
    const jobEnv={...env,WASM_AGENT_PORT:String(port),WASM_AGENT_MANAGED:'0',WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',
      WA_SENTINEL_SCRIPTS:root,WA_SENTINEL_JOB_CONCURRENCY:'2',WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY:'1'};
    const job=(...args)=>{
      const r=spawnSync(sentinel,['job',...args],{env:jobEnv,encoding:'utf8',timeout:10000,windowsHide:true});
      assert.equal(r.status,0,`job ${args.join(' ')}: ${r.error||r.stderr}`);return JSON.parse(r.stdout);
    };
    const jobFile=path.join(root,'background.json'), artifactFile=path.join(root,'background.artifact.json'), bindingsFile=path.join(root,'bindings.json');
    fs.writeFileSync(jobFile,JSON.stringify({id:'proof-background',name:'Bounded fixture',trigger:{kind:'event',topic:'proof.background'},action:{kind:'subagent',profile:'proof-lean',prompt:'BACKGROUND_3',timeout_seconds:60}}));
    job('put',jobFile);fs.writeFileSync(artifactFile,JSON.stringify(job('export','proof-background')));fs.writeFileSync(bindingsFile,'{}');
    check(job('import',artifactFile,'--bindings',bindingsFile,'--approve').job.enabled===false,'portable artifact imports disabled');
    job('enable','proof-background');
    const marker=path.join(root,'deterministic.completed'), script=path.join(root,'deterministic.sh');
    const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
    fs.writeFileSync(script,'#!/usr/bin/env bash\nprintf proof > '+quote(marker.replaceAll('\\','/'))+'\n');
    const deterministicFile=path.join(root,'deterministic.json');
    fs.writeFileSync(deterministicFile,JSON.stringify({id:'proof-deterministic',name:'Deterministic fixture',trigger:{kind:'event',topic:'proof.deterministic'},action:{kind:'run',script,timeout_seconds:10}}));
    job('put',deterministicFile);job('enable','proof-deterministic');
    watcherLog=fs.openSync(path.join(root,'sentinel.log'),'a');
    watcher=spawn(sentinel,['watch'],{env:jobEnv,stdio:['ignore',watcherLog,watcherLog],windowsHide:true});
    watcher.on('error',error=>console.error(error));
    const eventFile=path.join(root,'event.json');fs.writeFileSync(eventFile,'{"proof":true}');
    check(job('emit','proof.background','proof-event',eventFile).queued===1,'durable background delivery enqueued');
    let queued;
    await until(async()=>{const r=await api({action:'list'});queued=r.subagents?.find(s=>!receipts.some(existing=>existing.subagent_id===s.subagent_id));return !!queued;},'sentinel submits queued child');
    check(queued.subagent_id && !queued.error,'overflow delivery accepted into bounded child queue');receipts.push(queued);
    check(job('emit','proof.deterministic','proof-deterministic-event',eventFile).queued===1,'deterministic delivery enqueued');
    await until(()=>fs.existsSync(marker),'deterministic job progresses while inference saturated');checks++;
    const chats=await Promise.all(['A','B'].map(async name=>{
      const r=await fetch(base+'/chat',{method:'POST',headers:{'content-type':'application/json',accept:'text/event-stream'},body:JSON.stringify({thread:'proof-interactive-'+name,text:'INTERACTIVE_'+name}),signal:AbortSignal.timeout(8000)});
      return {name,status:r.status,text:await r.text()};
    }));
    for(const c of chats){
      check(c.status===200 && c.text.includes('ANSWER_'+c.name), 'interactive answer '+c.name+' before child completion');
      check(!c.text.includes('ANSWER_'+(c.name==='A'?'B':'A')) && !c.text.includes('CHILD_DONE'),'stream belongs only to '+c.name);
      check((c.text.match(/"type"\s*:\s*"done"/g)||[]).length===1,'exactly one terminal event '+c.name);
    }
    check(held.size===2 && !held.has('BACKGROUND_3'),'interactive traffic never released child capacity or executed queued child');
    for(const input of requests.filter(r=>JSON.stringify(r.messages).includes('BACKGROUND_'))){
      check(!JSON.stringify(input.messages).includes('OPERATOR_CONTEXT_MUST_NOT_REACH_CHILD_4189'),'lean child omits operator instruction file');
      check(!input.tools || input.tools.length===0,'zero-tool profile advertises no tools');
    }
    const listed=await api({action:'list'});
    check(!listed.error,'control plane lists children while all child slots are busy');
    const invalid=await api({action:'list'},{'x-wa-session':'unknown-credential'});
    check(invalid.status===401 || invalid.error==='invalid_session' || invalid.error==='unauthorized','unknown credential cannot inspect operator children');
    const cancel=await api({action:'cancel',subagent_id:receipts[0].subagent_id});
    check(!cancel.error,'cancel admitted without waiting behind inference');
    await until(async()=>{const r=await api({action:'status',subagent_id:receipts[0].subagent_id});return r.settled && r.state==='cancelled';},'native cancellation interrupts silent provider',10000);
    checks++;
    await until(()=>held.has('BACKGROUND_3'),'queued child starts after cancellation');
    checks++;
    answer(held.get('BACKGROUND_2'),'CHILD_DONE_2');answer(held.get('BACKGROUND_3'),'CHILD_DONE_3');
    for(const receipt of receipts.slice(1)){
      await until(async()=>{const r=await api({action:'result',subagent_id:receipt.subagent_id});return r.settled && r.state==='completed';},'durable child result'); checks++;
    }
    await until(()=>job('history').some(d=>d.job_id==='proof-background' && d.state==='completed'),'delivery settles after actual child completion');checks++;
    check(job('emit','proof.background','proof-event',eventFile).queued===0,'duplicate source event cannot submit a second child');
    check((await api({action:'list'})).subagents.length===3,'exactly three durable children after delivery dedupe');
    check(fs.existsSync(path.join(config,'subagents')),'child records use isolated node home, not ambient HOME');
    for(const name of ['A','B']){
      const data=await(await fetch(base+'/session?id=proof-interactive-'+name,{signal:AbortSignal.timeout(3000)})).json();
      const text=JSON.stringify(data.messages);
      check(text.includes('ANSWER_'+name) && !text.includes('ANSWER_'+(name==='A'?'B':'A')) && !text.includes('BACKGROUND_'),'durable transcript isolation '+name);
    }
    const evidence={schema:'wasm-agent.orchestration-proof/v1',checks,failed:0,skipped:0,model:'local-mock',live_whatsapp:false,child_ids:receipts.map(r=>r.subagent_id)};
    fs.writeFileSync(path.join(root,'verdict.json'),JSON.stringify(evidence,null,2));
    console.log(`orchestration integrated ok (${checks} checks, 0 skipped; mock inference, not a live WhatsApp proof)\nevidence: ${root}`);
  }catch(error){console.error(error.stack);console.error('evidence: '+root);process.exitCode=1;
  }finally{
    for(const response of held.values())response.destroy();
    for(const processHandle of [watcher,child])if(processHandle && processHandle.exitCode===null){processHandle.kill();await Promise.race([new Promise(r=>processHandle.once('exit',r)),sleep(5000)]);}
    if(hostLog!==undefined)fs.closeSync(hostLog);
    if(watcherLog!==undefined)fs.closeSync(watcherLog);
    provider?.closeAllConnections();provider?.close();
  }
})();
