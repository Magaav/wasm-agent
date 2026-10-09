// Two isolated real Chromium pages, actual node/Lua/SQLite and owned mock provider.
// A proxy delays only the settings acknowledgement, after the node has applied it.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http');
const {spawn,spawnSync}=require('node:child_process');const {once}=require('node:events');const assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'..');let binary=path.resolve(process.argv[2]||'rust/target/release/wa.exe');
// The gate passes the extensionless `$BIN` on every platform; the native Windows binary
// is `wa.exe`, and this test hashes its bytes rather than only spawning it.
if(process.platform==='win32'&&!binary.toLowerCase().endsWith('.exe')&&fs.existsSync(binary+'.exe'))binary+='.exe';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-two-window-'));const report={schema:1,root,checks:[],requests:[],models:[]};
const embedded=process.argv.includes('--embedded');
const keep=process.argv.includes('--keep');
const interactiveOnly=process.argv.includes('--interactive-only');
report.skips=interactiveOnly?['native child journal host (outside interactive-only scope)']:[];
report.lua=embedded?'embedded candidate modules':'explicit source Lua root';
report.binary={path:binary,sha256:require('node:crypto').createHash('sha256').update(fs.readFileSync(binary)).digest('hex')};
const delay=ms=>new Promise(r=>setTimeout(r,ms));const children=[],sockets=new Set();let node,provider,proxy,chrome,ws;
let port,delayedWrite=false;const held=new Map();let sequence=0;const waiting=new Map();let browserClosed=false;
const pages=[];
function launchOwned(program,args,options) {
  if(process.platform!=='win32')return spawn(program,args,options);
  const name='job-'+children.length,receipt=path.join(root,name+'.receipt.json'),stop=path.join(root,name+'.stop'),spec=path.join(root,name+'.spec.json');
  fs.writeFileSync(spec,JSON.stringify({program,args,cwd:options.cwd||repo,receipt,stop}));
  const child=spawn('powershell',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(repo,'scripts','fixture-native-job.ps1'),'-Spec',spec],options);
  child.fixtureJob={receipt,stop};return child;
}
function jobProof(child){try{return child.fixtureJob?JSON.parse(fs.readFileSync(child.fixtureJob.receipt)):null;}catch{return null;}}
async function creation(child) {
  await once(child,'spawn');
  check(Number.isInteger(child.pid)&&child.pid>0,'owned wrapper process creation positively observed');
  if(child.fixtureJob)await until(()=>{const proof=jobProof(child);if(proof?.error)throw Error(proof.error);return proof?.creation_proven&&proof.assigned&&proof.in_job&&proof.kill_on_close;},'native creation assigned to owned Job');
}
function check(value,label){assert.ok(value,label);report.checks.push(label);}
async function listen(server){server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});server.listen(0,'127.0.0.1');await once(server,'listening');return server.address().port;}
async function until(fn,label,budget=12000){const deadline=Date.now()+budget;while(Date.now()<deadline){const v=await fn();if(v)return v;await delay(30);}throw new Error('deadline: '+label);}
async function freePort(){const s=http.createServer();const p=await listen(s);await new Promise(r=>s.close(r));return p;}
async function api(route,body){const begin=Date.now();const r=await fetch('http://127.0.0.1:'+port+'/'+route,{method:body===undefined?'GET':'POST',headers:{'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(3000)});const data=await r.json();report.requests.push({route,status:r.status,ms:Date.now()-begin});return {status:r.status,...data};}
function cdp(method,params={},sessionId){const id=++sequence;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{waiting.delete(id);reject(new Error('CDP deadline '+method));},15000);waiting.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});}
async function evaluate(page,expression){const r=await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},page);if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
async function page(url,thread){const ctx=await cdp('Target.createBrowserContext');const t=await cdp('Target.createTarget',{url:'about:blank',browserContextId:ctx.browserContextId});const a=await cdp('Target.attachToTarget',{targetId:t.targetId,flatten:true});const id=a.sessionId;pages.push({id,thread});await cdp('Page.enable',{},id);await cdp('Runtime.enable',{},id);await cdp('Page.addScriptToEvaluateOnNewDocument',{source:`try {localStorage.setItem('wa-chat-session',${JSON.stringify(thread)});} catch(e) {}`},id);await cdp('Page.navigate',{url},id);await until(()=>evaluate(id,"typeof send==='function' && synced && metaReady" ).catch(()=>false),'page ready '+thread);return id;}
function event(res,value){res.write('data: '+JSON.stringify(value)+'\n\n');}
function finish(res,text){event(res,{choices:[{delta:{content:text},finish_reason:'stop'}],usage:{prompt_tokens:12,completion_tokens:3,total_tokens:15}});res.end('data: [DONE]\n\n');}
(async()=>{
 try{
  provider=http.createServer((req,res)=>{let raw='';req.on('data',b=>raw+=b);req.on('end',()=>{
   if(req.method==='GET'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(req.url.endsWith('/models')?{data:[{id:'fixture-model'},{id:'fixture-next'}]}:{usage:{}}));return;}
   const body=JSON.parse(raw);const text=body.messages.filter(m=>m.role==='user').at(-1)?.content||'';
   const name=String(text).includes('RECOVERY-A')?'A':String(text).includes('RECOVERY-B')?'B':'NEXT';
   report.models.push({name,model:body.model,toolResults:body.messages.filter(m=>m.role==='tool').length});
   res.writeHead(200,{'content-type':'text/event-stream'});
   if(name==='A'&&!body.messages.some(m=>m.role==='tool')){
    const command="printf 'effect\\n' >> \""+path.join(root,'effects').replaceAll('\\','/')+"\"";
    event(res,{choices:[{delta:{tool_calls:[{index:0,id:'effect-once',type:'function',function:{name:'bash',arguments:JSON.stringify({command,timeout_seconds:5})}}]},finish_reason:'tool_calls'}]});res.end('data: [DONE]\n\n');
   }else if(name==='NEXT')finish(res,'NEXT-COMPLETE');
   else{event(res,{choices:[{delta:{content:'LIVE-'+name},finish_reason:null}]});held.set(name,res);}
  });});const modelPort=await listen(provider);
  const privateRepo=path.join(root,'repo');fs.mkdirSync(privateRepo);
  check(spawnSync('git',['init',privateRepo],{windowsHide:true}).status===0,'private recovery repository created');
  port=await freePort();const log=fs.openSync(path.join(root,'node.log'),'w');const env={...process.env};
  for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(k))delete env[k];
  Object.assign(env,{WASM_AGENT_HOME:root,...(embedded?{}:{WASM_AGENT_LUA_ROOT:repo}),WASM_AGENT_PROVIDER:'opencode-go',WASM_AGENT_LLM_MODEL:'fixture-model',WASM_AGENT_LLM_API_KEY:'fixture-only',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+modelPort,OPENAI_BASE_URL:'http://127.0.0.1:'+modelPort,OPENAI_API_KEY:'fixture-only',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0',WASM_AGENT_MODELS_DEV_URL:'off',WASM_AGENT_PROVIDER_RESPONSE_RETRIES:'0',WA_GRAPH_WATCH:'0'});
  node=launchOwned(binary,['--db',path.join(root,'memory.db'),'serve','--port',String(port),'--client-port',String(await freePort()),'--ui',path.join(repo,'ui')],{cwd:privateRepo,env,windowsHide:true,stdio:['ignore',log,log]});children.push(node);fs.closeSync(log);await creation(node);
  await until(async()=>{try{return(await api('health')).ok;}catch{return false;}},'node ready');
  // This private reverse proxy forwards a coherent upstream Host/Origin pair;
  // production's same-origin guard stays enabled and is not under test here.
  proxy=http.createServer((req,res)=>{const upstream=http.request({host:'127.0.0.1',port,path:req.url,method:req.method,headers:{...req.headers,host:'127.0.0.1:'+port,...(req.headers.origin?{origin:'http://127.0.0.1:'+port}:{})}},r=>{
   if(delayedWrite&&req.method==='POST'&&req.url==='/provider'){
    delayedWrite=false;let data='';r.on('data',b=>data+=b);r.on('end',()=>setTimeout(()=>{if(!res.destroyed){res.writeHead(r.statusCode,r.headers);res.end(data);}},350));
   }else{res.writeHead(r.statusCode,r.headers);r.pipe(res);}
  });upstream.on('error',e=>{if(!res.destroyed){res.writeHead(502);res.end(JSON.stringify({error:e.message}));}});req.pipe(upstream);});const browserPort=await listen(proxy);
  const chromePath=process.env.WA_TEST_CHROME||['C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(fs.existsSync);assert.ok(chromePath,'Chrome/Edge missing');
  const profile=path.join(root,'browser');chrome=launchOwned(chromePath,['--headless=new','--disable-gpu','--no-first-run','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{cwd:privateRepo,env,windowsHide:true,stdio:'ignore'});children.push(chrome);await creation(chrome);
  await until(()=>fs.existsSync(path.join(profile,'DevToolsActivePort')),'DevTools ready');const [debugPort,endpoint]=fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').trim().split(/\r?\n/);
  ws=new WebSocket('ws://127.0.0.1:'+debugPort+endpoint);await once(ws,'open');ws.addEventListener('message',e=>{const data=JSON.parse(e.data);const item=waiting.get(data.id);if(item){waiting.delete(data.id);clearTimeout(item.timer);data.error?item.reject(new Error(JSON.stringify(data.error))):item.resolve(data.result);}});
  // Known thread restoration correctly refuses an unknown id. Seed these two
  // private fixture sessions before opening windows, using the owned mock only.
  for(const thread of ['thread-A','thread-B']){
    const r=await fetch('http://127.0.0.1:'+port+'/chat',{method:'POST',headers:{'content-type':'application/json','accept':'text/event-stream'},body:JSON.stringify({thread,text:'SEED-PRIVATE-RECOVERY'}),signal:AbortSignal.timeout(10000)});
    check(r.ok,'private fixture session seeded');await r.text();
  }
  const url='http://127.0.0.1:'+browserPort+'/';const a=await page(url,'thread-A'),b=await page(url,'thread-B');
  if(!interactiveOnly) {
  // Native read-only child: no writable profile/allocation in the shared project.
  const receipt=await api('subagents',{action:'start',profile:'explore',prompt:'RECOVERY-B native child held',idempotency_key:'native-browser-child'});
  check(!!receipt.subagent_id,'native child admitted');
  const nativeChild=await until(async()=>{const r=await api('subagents',{action:'status',id:receipt.subagent_id});return r.session_id&&r;},'native child session');
  const nativePage=await page(url,nativeChild.session_id);
  await until(()=>held.has('B'),'native child held provider');
  await evaluate(nativePage,`window.nativePane=document.createElement('wa-agent-session');document.body.append(nativePane);nativePane.task=${JSON.stringify(nativeChild)};refreshAgentPane(nativePane).then(()=>true)`);
  await until(()=>evaluate(nativePage,"nativePane.transcript.textContent.includes('LIVE-B')"),'native authenticated session pane live tail');
  const nativeLedger=await api('subagents',{action:'session',id:receipt.subagent_id,limit:1,byte_limit:4096});
  check(nativeLedger.messages.length===1&&nativeLedger.messages[0].id,'native bounded session page identity');
  await cdp('Page.reload',{},nativePage);
  await until(()=>evaluate(nativePage,"transcriptReady && document.getElementById('messages').textContent.includes('LIVE-B')").catch(()=>false),'native child main host actual reload reconnect');
  check(await evaluate(nativePage,"document.getElementById('messages').textContent.split('LIVE-B').length===2"),'genuine native main reload tail exact once');
  finish(held.get('B'),'NATIVE-B-COMPLETE');
  await until(async()=>{const r=await api('subagents',{action:'status',id:receipt.subagent_id});return r.settled;},'native child terminal');
  held.delete('B');
  }
  await evaluate(a,"void send('RECOVERY-A'); 'started'");await until(()=>held.has('A'),'tool result and held A');
  const bRun=fetch('http://127.0.0.1:'+port+'/chat',{method:'POST',headers:{'content-type':'application/json','accept':'text/event-stream'},body:JSON.stringify({thread:'thread-B',text:'RECOVERY-B'})}).then(r=>r.text());await until(()=>held.has('B'),'held B');
  check((await api('health')).runs.length===2,'two actual long runs active');
  for(let i=0;i<3;i++){const s=await api('session?id=thread-A');check(s.status===200&&s.messages.some(m=>m.role==='tool'),'transcript responds while two runs active');}
  await evaluate(a,"input.value='PRESERVED-DRAFT'; input.dispatchEvent(new Event('input')); rememberPlace(); location.reload(); 'reloaded'");
  await until(()=>evaluate(a,"transcriptReady && document.getElementById('messages').textContent.includes('RECOVERY-A')").catch(()=>false),'reload durable transcript during run');
  await until(()=>evaluate(a,"document.getElementById('messages').textContent.includes('LIVE-A')").catch(()=>false),'checkpoint/live cursor reconciliation');
  check(await evaluate(a,"input.value==='PRESERVED-DRAFT'"),'draft survives real navigation');
  // An actual child host on the same page uses the production renderer and journal attachment.
  await evaluate(a,`window.recoveryPane=document.createElement('wa-agent-session');document.body.append(recoveryPane);recoveryPane.task={session_id:'thread-A',subagent_id:'fixture-read-host',state:'running',settled:false};window.originalPaneMessages=paneMessages;paneMessages=async()=>{const r=await apiFetch('session?id=thread-A',{headers:apiHeaders()});return {rows:(await r.json()).messages};};refreshAgentPane(recoveryPane).then(()=>true)`);
  await until(()=>evaluate(a,"recoveryPane.transcript.textContent.includes('LIVE-A')"),'child journal tail after actual main reload');
  const ledgerBefore=await api('session?id=thread-A');
  report.savedIdentity=ledgerBefore.messages.map(m=>({id:m.id,seq:m.seq,role:m.role,content:m.content}));
  check(await evaluate(a,"recoveryPane.transcript.textContent.split('LIVE-A').length===2"),'child tail exactly once');
  await evaluate(a,'refreshAgentPane(recoveryPane).then(()=>true)');
  check(await evaluate(a,"recoveryPane.transcript.textContent.split('LIVE-A').length===2"),'repeated child reconnect does not duplicate tail');
  check((await api('health')).runs.length===2,'recovery did not require run settlement');
  await evaluate(b,'apiTimeout=80; true');delayedWrite=true;
  await evaluate(b,"setProvider('gpt').then(()=>true)");
  check(await evaluate(b,"settings.provider==='gpt' && document.getElementById('settings-error').textContent.includes('in effect') && document.getElementById('settings-error').textContent.includes('aborted')"),'delayed write acknowledgement is reconciled from the actually applied node state');
  await evaluate(b,'apiTimeout=8000; true');
  await until(()=>evaluate(a,"settings.provider==='gpt'").catch(()=>false),'other window versioned settings refresh');
  const current=await api('models');const stale=await api('model',{value:'fixture-next',revision:current.settings_revision-1});check(stale.error==='settings_conflict','stale cross-window selection refuses');
  // A followed run owns this window's controls too. Wait for its settlement
  // before exercising the next-run setting; do not call a correct refusal a failure.
  held.get('A').end();
  await until(async()=>{const s=await api('session?id=thread-A');return s.state?.state==='failed';},'durable mid-run failure');
  await cdp('Page.reload',{},a);
  await until(()=>evaluate(a,"transcriptReady && document.getElementById('messages').textContent.includes('RECOVERY-A')").catch(()=>false),'failed transcript restores while B active');
  check((await api('health')).runs.some(r=>r.conversation==='thread-B'),'second long run remains active during error recovery');
  const recovered=await api('session?id=thread-A');check(recovered.messages.every((m,i,all)=>i===0||m.seq>all[i-1].seq),'durable message order intact');
  check(fs.readFileSync(path.join(root,'effects'),'utf8').trim().split(/\r?\n/).length===1,'reconnect/reload never replays tool effect');
  check(report.savedIdentity.every(m=>recovered.messages.some(r=>r.id===m.id&&r.seq===m.seq&&r.role===m.role&&r.content===m.content)),'real reload/drop preserves exact saved message identity and bytes');
  finish(held.get('B'),'B-COMPLETE');await bRun;
  await until(async()=>!(await api('health')).runs.length,'both runs settled');
  await evaluate(b,"watchTurn().then(()=>true)");
  await until(()=>evaluate(b,'!composerBusy()'),'B controls released');
  await evaluate(b,"setModel('fixture-next').then(()=>true)");
  check(await evaluate(b,"settings.model==='fixture-next'"),'next model setting confirmed before send');
  await evaluate(b,"send('NEXT-RUN').then(()=>true)");
  check(report.models.filter(m=>m.name!=='NEXT').every(m=>m.model==='fixture-model'),'in-flight runs retain immutable model snapshot');
  check(report.models.some(m=>m.name==='NEXT'&&m.model==='fixture-next'),'next run uses confirmed settings');
  report.passed=true;
 }catch(e){
  report.passed=false;report.error=e.stack;
  report.pages=await Promise.all(pages.map(async p=>{try{return {thread:p.thread,value:await evaluate(p.id,"({url:location.href,chatSession,conversationEpoch,synced,metaReady,transcriptReady,busy,followedSeq,liveRunId,liveEventSeq,liveCheckpointSeq,liveSyncFailed,text:document.body.innerText})")};}catch(error){return {thread:p.thread,error:String(error)};}}));
  try{report.health=await api('health');report.replay=await api('run-events',{thread:'thread-A',run_id:report.health.run_ids.find(r=>r.conversation==='thread-A'&&r.state==='running')?.run_id});}catch{}
  throw e;
 }
 finally{
  if(ws){try{await cdp('Browser.close');browserClosed=true;}catch{}ws.close();}
  for(const r of held.values())r.destroy();for(const s of sockets)s.destroy();
  for(const c of children)if(c.exitCode===null&&c.signalCode===null){const done=once(c,'exit');
    if(c.fixtureJob)fs.writeFileSync(c.fixtureJob.stop,'stop');else c.kill();
    await Promise.race([done,delay(12000)]);
    if(c.exitCode===null&&c.signalCode===null){c.kill();await Promise.race([done,delay(3000)]);}
  }
  for(const server of [proxy,provider])if(server){server.closeAllConnections();await new Promise(r=>server.close(r));}
  report.cleanup={ownedPids:children.map(c=>({pid:c.pid,exited:c.exitCode!==null||c.signalCode!==null,job:jobProof(c)})),browserClosed};
  const drained=report.cleanup.ownedPids.every(c=>c.exited&&(process.platform!=='win32'||(c.job?.creation_proven&&c.job.assigned&&c.job.in_job&&c.job.kill_on_close&&c.job.drained&&c.job.accounting?.active_processes===0)));
  if(!drained||!browserClosed){report.passed=false;report.cleanup.error='owned process shutdown or Job accounting unverified';process.exitCode=1;}
  // Successful fixture homes/browser caches must not grow with every gate.
  // Preserve the complete ledger/home/log evidence in shared Git metadata so
  // retiring this producer tree cannot erase it; failed/export-only runs stay
  // explicit --keep evidence for diagnosis, without being called cleaned.
  let evidence=root;
  const common=spawnSync('git',['rev-parse','--path-format=absolute','--git-common-dir'],{cwd:repo,encoding:'utf8',windowsHide:true});
  if(drained&&report.cleanup.ownedPids.every(c=>Number.isInteger(c.pid)&&c.pid>0)&&browserClosed&&!keep&&common.status===0){
    evidence=path.join(common.stdout.trim(),'wa-recovery-evidence',path.basename(root));
    fs.mkdirSync(path.dirname(evidence),{recursive:true});
    if(fs.existsSync(evidence))throw new Error('refusing to overwrite prior fixture evidence');
    fs.cpSync(root,evidence,{recursive:true,filter:source=>path.relative(root,source).split(path.sep)[0]!=='browser'});
    function verifyCopy(relative=''){
      for(const entry of fs.readdirSync(path.join(root,relative),{withFileTypes:true})){
        const name=path.join(relative,entry.name);if(name.split(path.sep)[0]==='browser')continue;
        if(entry.isDirectory())verifyCopy(name);
        else{const original=fs.readFileSync(path.join(root,name)),copied=fs.readFileSync(path.join(evidence,name));assert.ok(original.equals(copied),'fixture evidence copy differs: '+name);}
      }
    }
    verifyCopy();
    assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir())+path.sep)&&path.basename(root).startsWith('wa-two-window-'),'owned scratch cleanup stays in temporary root');
    fs.rmSync(root,{recursive:true,force:true});
    report.cleanup.fixture_home_removed=true;
  }else report.cleanup.fixture_home_removed=false;
  report.evidence=evidence;
  fs.writeFileSync(path.join(evidence,'report.json'),JSON.stringify(report,null,2)+'\n');console.log('evidence: '+path.join(evidence,'report.json'));
  if(report.passed)console.log('two-window recovery ok ('+report.checks.length+' checks, '+report.skips.length+' skipped; real browser/node, owned mock inference)');
 }
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
