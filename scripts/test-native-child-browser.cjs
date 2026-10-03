// Two isolated real Chromium pages, actual node/Lua/SQLite and owned mock provider.
// A proxy delays only the settings acknowledgement, after the node has applied it.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http');
const {spawn,spawnSync}=require('node:child_process');const {once}=require('node:events');const assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'..');let binary=path.resolve(process.argv[2]||'rust/target/release/wa.exe');
// The gate passes the extensionless `$BIN` on every platform; the native Windows binary
// is `wa.exe`, and this test hashes its bytes rather than only spawning it.
if(process.platform==='win32'&&!binary.toLowerCase().endsWith('.exe')&&fs.existsSync(binary+'.exe'))binary+='.exe';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-native-browser-'));const report={schema:1,root,checks:[],requests:[],models:[]};
const embedded=process.argv.includes('--embedded');
const uiArg=process.argv.indexOf('--ui-root'),uiRoot=uiArg<0?path.join(repo,'ui'):path.resolve(process.argv[uiArg+1]);
const keep=process.argv.includes('--keep');
report.lua=embedded?'embedded candidate modules':'explicit source Lua root';
report.binary={path:binary,sha256:require('node:crypto').createHash('sha256').update(fs.readFileSync(binary)).digest('hex')};
const delay=ms=>new Promise(r=>setTimeout(r,ms));const children=[],sockets=new Set();let node,provider,proxy,chrome,ws;
let port,ownerToken='',delayedWrite=false;const held=new Map();let sequence=0;const waiting=new Map();let browserClosed=false;
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
async function api(route,body,token=ownerToken){const begin=Date.now();const r=await fetch('http://127.0.0.1:'+port+'/'+route,{method:body===undefined?'GET':'POST',headers:{'content-type':'application/json',...(token?{'X-WA-Session':token}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(3000)});const data=await r.json();report.requests.push({route,status:r.status,ms:Date.now()-begin});return {status:r.status,...data};}
function cdp(method,params={},sessionId){const id=++sequence;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{waiting.delete(id);reject(new Error('CDP deadline '+method));},15000);waiting.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});}
async function evaluate(page,expression){const r=await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},page);if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
async function page(url,thread){const ctx=await cdp('Target.createBrowserContext');const t=await cdp('Target.createTarget',{url:'about:blank',browserContextId:ctx.browserContextId});const a=await cdp('Target.attachToTarget',{targetId:t.targetId,flatten:true});const id=a.sessionId;pages.push({id,thread});await cdp('Page.enable',{},id);await cdp('Runtime.enable',{},id);await cdp('Page.addScriptToEvaluateOnNewDocument',{source:`try {localStorage.setItem('wa-chat-session',${JSON.stringify(thread)});localStorage.setItem('wa-session',${JSON.stringify(ownerToken)});} catch(e) {}`},id);await cdp('Page.navigate',{url},id);await until(()=>evaluate(id,"typeof send==='function' && synced && metaReady" ).catch(()=>false),'page ready '+thread);return id;}
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
   if(name==='B'&&!body.messages.some(m=>m.role==='tool')){
    event(res,{choices:[{delta:{reasoning_content:'NATIVE-REASONING 原始'},finish_reason:null}]});
    event(res,{choices:[{delta:{phase:'commentary',content:'NATIVE-COMMENTARY'},finish_reason:null}]});
    event(res,{choices:[{delta:{tool_calls:[{index:0,id:'native-read',type:'function',function:{name:'read',arguments:JSON.stringify({path:path.join(root,'repo','native-read.txt')})}}]},finish_reason:'tool_calls'}]});res.end('data: [DONE]\n\n');
   }else if(name==='A'&&!body.messages.some(m=>m.role==='tool')){
    const command="printf 'effect\\n' >> \""+path.join(root,'effects').replaceAll('\\','/')+"\"";
    event(res,{choices:[{delta:{tool_calls:[{index:0,id:'effect-once',type:'function',function:{name:'bash',arguments:JSON.stringify({command,timeout_seconds:5})}}]},finish_reason:'tool_calls'}]});res.end('data: [DONE]\n\n');
   }else if(name==='NEXT')finish(res,'NEXT-COMPLETE');
   else{event(res,{choices:[{delta:{reasoning_content:'LIVE-REASONING START '},finish_reason:null}]});
    event(res,{choices:[{delta:{phase:'final_answer',content:'LIVE-'+name},finish_reason:null}]});
    for(let i=0;i<300;i++)event(res,{choices:[{delta:{content:' raw-'+i+' 原始 '},finish_reason:null}]});
    held.set(name,res);}
  });});const modelPort=await listen(provider);
  const privateRepo=path.join(root,'repo');fs.mkdirSync(privateRepo);check(spawnSync('git',['init',privateRepo],{windowsHide:true}).status===0,'private repository created');fs.writeFileSync(path.join(privateRepo,'native-read.txt'),'ORIGINAL-NATIVE-TOOL');
  port=await freePort();const log=fs.openSync(path.join(root,'node.log'),'w');const env={...process.env};
  for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(k))delete env[k];
  Object.assign(env,{WASM_AGENT_HOME:root,...(embedded?{}:{WASM_AGENT_LUA_ROOT:repo}),WASM_AGENT_PROVIDER:'opencode-go',WASM_AGENT_LLM_MODEL:'fixture-model',WASM_AGENT_LLM_API_KEY:'fixture-only',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+modelPort,OPENAI_BASE_URL:'http://127.0.0.1:'+modelPort,OPENAI_API_KEY:'fixture-only',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0',WASM_AGENT_MODELS_DEV_URL:'off',WASM_AGENT_PROVIDER_RESPONSE_RETRIES:'0',WA_GRAPH_WATCH:'0'});
  node=launchOwned(binary,['--db',path.join(root,'memory.db'),'serve','--port',String(port),'--client-port',String(await freePort()),'--ui',uiRoot],{cwd:privateRepo,env,windowsHide:true,stdio:['ignore',log,log]});children.push(node);fs.closeSync(log);
  await creation(node);
  await until(async()=>{try{return(await api('health')).ok;}catch{return false;}},'node ready');
  const ownerLogin=await(await fetch('http://127.0.0.1:'+port+'/login',{method:'POST',body:'master'})).json();
  check(!!ownerLogin.session,'explicit authenticated native owner credential');ownerToken=ownerLogin.session;
  // This private reverse proxy forwards a coherent upstream Host/Origin pair;
  // production's same-origin guard stays enabled and is not under test here.
  proxy=http.createServer((req,res)=>{const upstream=http.request({host:'127.0.0.1',port,path:req.url,method:req.method,headers:{...req.headers,host:'127.0.0.1:'+port,...(req.headers.origin?{origin:'http://127.0.0.1:'+port}:{})}},r=>{
   if(delayedWrite&&req.method==='POST'&&req.url==='/provider'){
    delayedWrite=false;let data='';r.on('data',b=>data+=b);r.on('end',()=>setTimeout(()=>{if(!res.destroyed){res.writeHead(r.statusCode,r.headers);res.end(data);}},350));
   }else{res.writeHead(r.statusCode,r.headers);r.pipe(res);}
  });upstream.on('error',e=>{if(!res.destroyed){res.writeHead(502);res.end(JSON.stringify({error:e.message}));}});req.pipe(upstream);});const browserPort=await listen(proxy);
  const chromePath=process.env.WA_TEST_CHROME||['C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(fs.existsSync);assert.ok(chromePath,'Chrome/Edge missing');
  const profile=path.join(root,'browser');chrome=launchOwned(chromePath,['--headless=new','--disable-gpu','--no-first-run','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{cwd:privateRepo,env,windowsHide:true,stdio:'ignore'});children.push(chrome);
  await creation(chrome);
  await until(()=>fs.existsSync(path.join(profile,'DevToolsActivePort')),'DevTools ready');const [debugPort,endpoint]=fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').trim().split(/\r?\n/);
  ws=new WebSocket('ws://127.0.0.1:'+debugPort+endpoint);await once(ws,'open');ws.addEventListener('message',e=>{const data=JSON.parse(e.data);const item=waiting.get(data.id);if(item){waiting.delete(data.id);clearTimeout(item.timer);data.error?item.reject(new Error(JSON.stringify(data.error))):item.resolve(data.result);}});
  const url='http://127.0.0.1:'+browserPort+'/';const a=await page(url,'thread-A');
  // Native read-only child: no writable profile/allocation in the shared project.
  const receipt=await api('subagents',{action:'start',profile:'explore',prompt:'RECOVERY-B native child held',idempotency_key:'native-browser-child'});
  check(!!receipt.subagent_id,'native child admitted');
  let nativeChild=await until(async()=>{const r=await api('subagents',{action:'status',id:receipt.subagent_id});return r.session_id&&r;},'native child session');
  const nativePage=await page(url,nativeChild.session_id);
  await until(()=>held.has('B'),'native child held provider');
  await until(async()=>{const r=await api('subagents',{action:'status',id:receipt.subagent_id});return r.preview?.text?.includes('raw-299');},'native original chunks committed before assertions');
  nativeChild=await api('subagents',{action:'status',id:receipt.subagent_id});
  const binding={action:'events',id:receipt.subagent_id,attempt_id:nativeChild.attempt_id,session_id:nativeChild.session_id,node_id:nativeChild.node_id,event_node_id:nativeChild.event_node_id,event_epoch:nativeChild.event_epoch};
  check(typeof nativeChild.event_node_id==='string'&&nativeChild.event_node_id.length>0,'native journal bound to actual node identity');
  const live=await until(async()=>{const r=await api('subagents',binding);return r.latest_seq>300&&r;},'native journal has all original chunks');
  check(live.transport==='native'&&live.durable&&live.has_more&&live.events.length===256,'genuine native journal first indexed page');
  check(live.checkpoint_message_seq>1&&live.checkpoint_seq>0,'native tool exchange advances durable checkpoint');
  const tail=await api('subagents',{...binding,after:live.next_seq});
  check(tail.next_seq>live.next_seq&&!tail.has_more,'native event cursor advances to complete tail');
  const raw=[...live.events,...tail.events];
  check(raw.every((r,i)=>!i||r.seq===raw[i-1].seq+1),'native raw event ids ordered without gaps');
  check(raw.filter(r=>r.event.type==='delta').map(r=>r.event.text).join('')==='LIVE-B'+Array.from({length:300},(_,i)=>' raw-'+i+' 原始 ').join(''),'native raw content exact and once across pages');
  report.raw=raw;
  const archive=await api('subagents',{...binding,archive:true});
  check(archive.events.some(r=>r.event.type==='reasoning')&&archive.events.some(r=>r.event.type==='commentary_delta')&&archive.events.some(r=>r.event.type==='tool')&&archive.events.some(r=>r.event.type==='tool_result'),'actual provider reasoning commentary tool and answer channels retained');
  for(const field of ['attempt_id','session_id','node_id','event_node_id','event_epoch'])check((await api('subagents',{...binding,[field]:'foreign-'+field})).error==='native_event_identity_mismatch:'+field,'native refuses foreign '+field);
  const login=await(await fetch('http://127.0.0.1:'+port+'/login',{method:'POST',body:'guest'})).json();
  check(!!login.session,'isolated foreign owner credential exists');
  check((await api('subagents',binding,login.session)).error==='forbidden_subagent','native refuses foreign owner before evidence');
  check((await api('subagents',{...binding,after:9007199254740990})).error==='native_event_cursor_out_of_range','native refuses future cursor');
  await evaluate(nativePage,`window.nativePane=document.createElement('wa-agent-session');document.body.append(nativePane);nativePane.task=${JSON.stringify(nativeChild)};refreshAgentPane(nativePane).then(()=>true)`);
  await until(()=>evaluate(nativePage,"nativePane.transcript.textContent.includes('LIVE-B')"),'native authenticated session pane live tail');
  check(await evaluate(nativePage,"nativePane.transcript.textContent.split('LIVE-B').length===2 && nativePane.transcript.textContent.includes('raw-299')"),'native pane consumes all journal pages exactly once');
  check(await evaluate(nativePage,"nativePane.hasAttribute('journal-attached')&&getComputedStyle(nativePane.preview).display==='none'"),'genuine native journal attachment supersedes bounded preview');
  await evaluate(nativePage,'refreshAgentPane(nativePane).then(()=>true)');
  check(await evaluate(nativePage,"nativePane.transcript.textContent.split('LIVE-B').length===2"),'native repeated attachment exact once');
  const tiles=[nativeChild];
  for(let i=0;i<5;i++) {
    const item=await api('subagents',{action:'start',profile:'explore',prompt:'NATIVE-OTHER-'+i,idempotency_key:'native-tile-'+i});
    check(!!item.subagent_id,'native layout child admitted '+i);
    tiles.push(await until(async()=>{const r=await api('subagents',{action:'status',id:item.subagent_id});return r.settled&&r;},'native layout child settled '+i));
  }
  await cdp('Emulation.setDeviceMetricsOverride',{width:1200,height:800,deviceScaleFactor:1,mobile:false},nativePage);
  await evaluate(nativePage,`window.nativeShowroom=document.createElement('wa-orchestrator');nativeShowroom.style.cssText='position:fixed;inset:0;width:100vw;height:100vh;z-index:9999;background:var(--panel)';document.body.append(nativeShowroom);window.nativeTiles=${JSON.stringify(tiles)};nativeShowroom.data=nativeTiles;nativeTiles.forEach(task=>nativeShowroom.pin(task));true`);
  await evaluate(nativePage,'(async()=>{for(const p of nativeShowroom.panes.values())await refreshAgentPane(p);return true;})()');
  const layout=await evaluate(nativePage,`(()=>{const c=nativeShowroom.canvas.getBoundingClientRect();return [...nativeShowroom.panes.values()].map(p=>{const r=p.getBoundingClientRect(),h=p.querySelector('.agent-pane-head').getBoundingClientRect(),a=p.querySelector('[data-part="attach"]').getBoundingClientRect(),s=p.querySelector('button[data-action="steer"]').getBoundingClientRect();return {top:r.top,bottom:r.bottom,left:r.left,right:r.right,header:h.height,contained:r.top>=c.top&&r.bottom<=c.bottom&&r.left>=c.left&&r.right<=c.right,actions:a.height===s.height};});})()`);
  check(layout.length===6&&layout.every(p=>p.contained),'six genuine native panes contained in viewport grid');
  check(layout.every(p=>p.header<=44&&p.actions),'six native headers capped at44 and shared actions match attachments');report.layout=layout;
  check(await evaluate(nativePage,`[...nativeShowroom.panes.values()].every(p=>{const box=p.getBoundingClientRect(), controls=[...p.querySelectorAll('.composer-footer button,.composer-model')].filter(e=>!e.hidden&&e.getBoundingClientRect().width>0).map(e=>e.getBoundingClientRect());return controls.every((r,i)=>r.left>=box.left&&r.right<=box.right&&controls.slice(i+1).every(s=>r.right<=s.left||s.right<=r.left||r.bottom<=s.top||s.bottom<=r.top));})`),'six native shared footer controls contained without overlap');
  const screenshot=await cdp('Page.captureScreenshot',{format:'png'},nativePage);fs.writeFileSync(path.join(root,'six-panes.png'),Buffer.from(screenshot.data,'base64'));
  const saved=await evaluate(nativePage,`(()=>{window.anchorPane=[...nativeShowroom.panes.values()][0];anchorPane.input.value='NATIVE-DRAFT';const trace=anchorPane.transcript.querySelector('wa-trace');if(!trace)throw Error('native tool topic missing');trace.open=false;const answer=anchorPane.transcript.querySelector('.seg[data-live-channel="delta"]');if(!answer)throw Error('raw native segment identity missing');anchorPane.transcript.scrollTop+=answer.getBoundingClientRect().top-anchorPane.transcript.getBoundingClientRect().top+50;window.anchorBefore=transcriptPlace(anchorPane.transcript);return anchorBefore;})()`);
  event(held.get('B'),{choices:[{delta:{reasoning_content:'GROWING-REASONING '+('r '.repeat(1500))},finish_reason:null}]});
  event(held.get('B'),{choices:[{delta:{content:'GROWING-ASSISTANT'},finish_reason:null}]});
  await until(async()=>{const r=await api('subagents',{action:'status',id:receipt.subagent_id});return r.preview?.text?.includes('GROWING-ASSISTANT');},'native assistant grows');
  await evaluate(nativePage,'refreshAgentPane(anchorPane).then(()=>true)');
  const anchored=await evaluate(nativePage,`({place:transcriptPlace(anchorPane.transcript),draft:anchorPane.input.value,fold:anchorPane.transcript.querySelector('wa-trace')?.open})`);
  report.scroll={saved,anchored};
  check(anchored.draft==='NATIVE-DRAFT'&&anchored.fold===false,'growing native assistant preserves folds and draft');
  check(anchored.place.key===saved.key&&Math.abs(anchored.place.offset-saved.offset)<=1,'growing native assistant retains stable raw-id scroll anchor');
  const inner=await evaluate(nativePage,`(()=>{const bodies=anchorPane.transcript.querySelectorAll('.reasoning-body');const body=bodies[bodies.length-1];body.scrollTop=45;return body.scrollTop;})()`);
  check(inner>0,'native reasoning has a real inner scroll viewport');
  event(held.get('B'),{choices:[{delta:{content:'INNER-SCROLL-APPEND'},finish_reason:null}]});
  await until(async()=>{const r=await api('subagents',{action:'status',id:receipt.subagent_id});return r.preview?.text?.includes('INNER-SCROLL-APPEND');},'native next segment change committed');
  await evaluate(nativePage,'refreshAgentPane(anchorPane).then(()=>true)');
  check(await evaluate(nativePage,`(()=>{const bodies=anchorPane.transcript.querySelectorAll('.reasoning-body');return bodies[bodies.length-1].scrollTop===${inner};})()`),'native growing segments retain inner reasoning scroll position');
  check(await evaluate(nativePage,`(async()=>{const before=anchorPane.transcript.textContent,previous=anchorPane.task;const pending=refreshAgentPane(anchorPane);anchorPane.task={...previous,subagent_id:'other-attempt'};await pending;const preserved=anchorPane.transcript.textContent===before;anchorPane.task=previous;return preserved;})()`),'late native pane response cannot cross attempt identity');
  check(await evaluate(nativePage,`(async()=>{const before=anchorPane.transcript.textContent,previous=anchorPane.task;const pending=refreshAgentPane(anchorPane);anchorPane.task={...previous,attempt_id:'old-native-attempt'};await pending;const preserved=anchorPane.transcript.textContent===before;anchorPane.task=previous;return preserved;})()`),'late native attempt response cannot cross stable logical control address');
  await evaluate(nativePage,'nativeShowroom.remove();nativePane.remove();true');
  check(await evaluate(nativePage,`(async()=>{const before=messages.textContent;const pending=syncNativeSession(chatSession,conversationEpoch,activeNode);conversationEpoch++;await pending;return messages.textContent===before;})()`),'late native main response cannot cross conversation epoch');
  check(await evaluate(nativePage,`(async()=>{const before=messages.textContent,previous=session;const pending=syncNativeSession(chatSession,conversationEpoch,activeNode);session='foreign-credential';await pending;session=previous;return messages.textContent===before;})()`),'late native main response cannot cross owner credential');
  check(await evaluate(nativePage,`(async()=>{const before=messages.textContent,previous=activeNode;const pending=syncNativeSession(chatSession,conversationEpoch,activeNode);activeNode='foreign-node';await pending;activeNode=previous;return messages.textContent===before;})()`),'late native main response cannot cross active node');
  const nativeLedger=await api('subagents',{action:'session',id:receipt.subagent_id,limit:1,byte_limit:4096});
  check(nativeLedger.messages.length===1&&nativeLedger.messages[0].id,'native bounded session page identity');
  await cdp('Page.reload',{},nativePage);
  await until(()=>evaluate(nativePage,"transcriptReady && document.getElementById('messages').textContent.includes('LIVE-B')").catch(()=>false),'native child main host actual reload reconnect');
  check(await evaluate(nativePage,"messages.textContent.split('LIVE-B').length===2 && messages.textContent.includes('raw-299') && liveEventSeq>300"),'native main reload preserves all page cursors and exact once content');
  await cdp('Network.enable',{},nativePage);
  await cdp('Network.emulateNetworkConditions',{offline:true,latency:0,downloadThroughput:-1,uploadThroughput:-1},nativePage);
  event(held.get('B'),{choices:[{delta:{content:'DROP-RAW'},finish_reason:null}]});
  await delay(1100);
  await cdp('Network.emulateNetworkConditions',{offline:false,latency:0,downloadThroughput:-1,uploadThroughput:-1},nativePage);
  await until(()=>evaluate(nativePage,"messages.textContent.includes('DROP-RAW')"),'native actual network drop reconnect');
  check(await evaluate(nativePage,"messages.textContent.split('DROP-RAW').length===2"),'native reconnect exact once new event');
  const original='NATIVE-B-COMPLETE'+('原'.repeat(16000));
  finish(held.get('B'),original);
  await until(async()=>{const r=await api('subagents',{action:'status',id:receipt.subagent_id});return r.settled;},'native child terminal');
  held.delete('B');
  check((await api('health')).subagents.active===0,'all native child threads settled before scratch retirement');
  await until(()=>evaluate(nativePage,"messages.textContent.includes('NATIVE-B-COMPLETE')"),'native terminal ledger fallback');
  const complete=await api('subagents',{action:'session',id:receipt.subagent_id,limit:200,byte_limit:4096});
  const reference=complete.messages.find(r=>r.omitted&&r.role==='assistant');
  check(!!reference?.evidence&&reference.id,'native oversized original has exact evidence identity');
  let offset=1,version=null,encoded='',originalBytes;
  for(;;){const chunk=await api('subagents',{action:'session',id:receipt.subagent_id,message_id:reference.id,byte_offset:offset,byte_limit:4096,...(version?{message_version:version}:{})});
    check(chunk.message_id===reference.id&&(!version||chunk.message_version===version)&&chunk.next_offset>offset,'native exact original version and byte cursor advances');
    version=chunk.message_version;encoded+=chunk.content;originalBytes=chunk.bytes;offset=chunk.next_offset;if(chunk.eof)break;}
  const exact=JSON.parse(encoded);
  check(Buffer.byteLength(encoded)===originalBytes&&offset===originalBytes+1&&exact.content==='LIVE-B'+Array.from({length:300},(_,i)=>' raw-'+i+' 原始 ').join('')+'GROWING-ASSISTANT'+'INNER-SCROLL-APPEND'+'DROP-RAW'+original,'native oversized original exact raw bytes without clipping');
  check((await api('subagents',{action:'session',id:receipt.subagent_id,message_id:reference.id,byte_offset:1,message_version:'old-version',byte_limit:4096})).error==='message_changed','native old message version refuses');
  check((await api('subagents',binding)).state==='completed','native terminal event archive remains owner readable');
  const modelsBeforeRestart=report.models.length;
  const nodeExit=once(node,'exit');fs.writeFileSync(node.fixtureJob.stop,'stop');await nodeExit;
  check(jobProof(node)?.drained&&jobProof(node)?.accounting.active_processes===0,'private node killed and waited with zero Job processes');
  const restartLog=fs.openSync(path.join(root,'node.log'),'a');
  node=launchOwned(binary,['--db',path.join(root,'memory.db'),'serve','--port',String(port),'--client-port',String(await freePort()),'--ui',uiRoot],{cwd:privateRepo,env,windowsHide:true,stdio:['ignore',restartLog,restartLog]});children.push(node);fs.closeSync(restartLog);
  await creation(node);await until(async()=>{try{return(await api('health')).ok;}catch{return false;}},'private native node restarted');
  const recovered=await api('subagents',{...binding,archive:true});
  check(recovered.state==='completed'&&recovered.event_epoch===binding.event_epoch&&JSON.stringify(recovered.events)===JSON.stringify(archive.events),'native archive raw ids and content survive actual node restart');
  await delay(1100);check(report.models.length===modelsBeforeRestart,'native restart never replays unknown effects or inference');
  await cdp('Page.reload',{},nativePage);
  await until(()=>evaluate(nativePage,"transcriptReady&&messages.textContent.includes('NATIVE-B-COMPLETE')").catch(()=>false),'native terminal original ledger after real node restart');
  // A real continuation is another native attempt in the same durable session.
  const next=await api('subagents',{action:'message',id:receipt.subagent_id,text:'RECOVERY-B journal failure',idempotency_key:'native-browser-next'});
  check(next.subagent_id!==receipt.subagent_id&&next.session_id===nativeChild.session_id,'native continuation has opaque new attempt in same session');
  await until(()=>held.has('B'),'native continued attempt real provider');
  const nextTask=await api('subagents',{action:'status',id:next.subagent_id});
  await until(async()=>{const r=await api('subagents',{action:'status',id:next.subagent_id});return r.preview?.text?.includes('raw-299');},'continued attempt has committed chunks');
  check((await api('subagents',{...binding,id:next.subagent_id})).error==='native_event_identity_mismatch:attempt_id','old attempt cannot attach new native attempt');
  // Journal loss is made explicit; preserve bytes under a new evidence name, never discard them.
  const journal=path.join(root,'.wasm-agent','subagents',next.subagent_id,'events.sqlite');
  await until(()=>{try{fs.renameSync(journal,journal+'.preserved');return true;}catch(e){if(e.code==='EBUSY')return false;throw e;}},'preserve journal for real storage loss fixture');
  event(held.get('B'),{choices:[{delta:{content:'AFTER-JOURNAL-LOSS'},finish_reason:null}]});
  event(held.get('B'),{choices:[{delta:{content:'CANCEL-WAKE'},finish_reason:null}]});
  const broken=await until(async()=>{const r=await api('subagents',{action:'status',id:next.subagent_id});return r.settled&&r;},'native journal loss settles visibly');
  check(broken.state==='failed'&&broken.event_error?.startsWith('native_event_journal_write_failed:'),'native write failure cannot become successful settlement');
  check((await api('subagents',{action:'events',id:next.subagent_id})).error?.startsWith('native_event_journal_write_failed:'),'native partial retained evidence reports write loss');
  check(JSON.parse(fs.readFileSync(path.join(root,'.wasm-agent','subagents',next.subagent_id,'record.json'))).event_error===broken.event_error,'native write failure retained durably');
  held.delete('B');
  check((await api('health')).subagents.active===0,'all native attempts accounted settled before scratch cleanup');
  const missing=tiles[1],missingJournal=path.join(root,'.wasm-agent','subagents',missing.subagent_id,'events.sqlite');
  fs.renameSync(missingJournal,missingJournal+'.preserved');
  check((await api('subagents',{action:'events',id:missing.subagent_id})).error?.startsWith('native_event_evidence_unavailable:'),'missing old event evidence is named unavailable');
  check((await api('subagents',{action:'session',id:missing.subagent_id,message_id:reference.id,byte_offset:1,byte_limit:4096})).error==='unknown_message','native exact message cannot cross session');
  await evaluate(nativePage,`window.unavailablePane=document.createElement('wa-agent-session');document.body.append(unavailablePane);unavailablePane.task=${JSON.stringify(missing)};refreshAgentPane(unavailablePane).then(()=>true)`);
  check(await evaluate(nativePage,"unavailablePane.transcript.textContent.includes('NEXT-COMPLETE')&&unavailablePane.notice.textContent.includes('native_event_evidence_unavailable')"),'native unavailable journal visibly falls back to original terminal ledger');
  report.passed=true;
  check(report.checks.length>=63,'original native assertion floor retained');
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
    assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir())+path.sep)&&path.basename(root).startsWith('wa-native-browser-'),'owned scratch cleanup stays in temporary root');
    fs.rmSync(root,{recursive:true,force:true});
    report.cleanup.fixture_home_removed=true;
  }else report.cleanup.fixture_home_removed=false;
  report.evidence=evidence;
  fs.writeFileSync(path.join(evidence,'report.json'),JSON.stringify(report,null,2)+'\n');console.log('evidence: '+path.join(evidence,'report.json'));
  if(report.passed){console.log('native child browser ok ('+report.checks.length+' checks, 0 skipped; real browser/node, owned mock inference)');console.log('ALL PASS');}
 }
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
