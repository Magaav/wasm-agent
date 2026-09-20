// Hermetic end-to-end jobs proof: real sentinel, isolated Chrome, fake local chat (no model).
// node scripts/test-jobs.cjs [sentinel-executable] [wa-executable]
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {spawn,spawnSync}=require('node:child_process');
const WebSocket=globalThis.WebSocket||require('undici').WebSocket; // Node 18 fixture compatibility; no download.
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-jobs-proof-'));
const repo=path.resolve(__dirname,'..');
const sentinel=path.resolve(process.argv[2]||path.join(repo,'rust/wa-sentinel/target/release',process.platform==='win32'?'wa-sentinel.exe':'wa-sentinel'));
const wa=path.resolve(process.argv[3]||path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const children=[];let receiver;let websocket;let checked=0;let requests=[];let simulateLostReply=false;
function check(value,label){assert.ok(value,label);checked++;}
async function until(f,label,ms=15000){const end=Date.now()+ms;while(Date.now()<end){const v=await f();if(v)return v;await sleep(100);}throw Error('Timed out: '+label);}
function child(exe,args,env){const log=fs.openSync(path.join(root,`child-${children.length}.log`),'a');const p=spawn(exe,args,{env,stdio:['ignore',log,log],windowsHide:true});children.push(p);return p;}
function cli(env,...args){const r=spawnSync(sentinel,['job',...args],{env,encoding:'utf8',timeout:10000,windowsHide:true});assert.equal(r.status,0,r.stderr||r.error?.message);return JSON.parse(r.stdout);}
function put(env,id,trigger,action){const file=path.join(root,id+'.json');fs.writeFileSync(file,JSON.stringify({id,name:id,trigger,action}));return cli(env,'put',file);}
function emit(env,topic,id,data){const file=path.join(root,'event.json');fs.writeFileSync(file,JSON.stringify(data));return cli(env,'emit',topic,id,file);}
async function main(){
 let server=http.createServer(async(req,res)=>{
  if(req.url==='/health'){res.setHeader('content-type','application/json');res.end(JSON.stringify({ok:true,current:null}));return;}
  if(req.url==='/chat'){let body='';for await(const c of req)body+=c;requests.push(JSON.parse(body));res.writeHead(200,{'Content-Type':'text/event-stream'});res.end(simulateLostReply?'data: {"type":"delta","text":"partial"}\n\n':'data: {"type":"reply","text":"fixture"}\n\ndata: {"type":"done"}\n\n');return;}
  res.writeHead(404);res.end();
 });receiver=server;await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;
 const env={...process.env,WASM_AGENT_HOME:root,WASM_AGENT_PORT:String(port),WA_SENTINEL_WAKE_BUDGET:'6',WA_SENTINEL_SCRIPTS:root,WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_MANAGED:'0'};delete env.WA_SCRIPT;delete env.WASM_AGENT_LUA_ROOT;
 const action={kind:'wake',session:'fixture-conversation',skill:'review-fixture',prompt:'Draft only, never send.'};
 check(put(env,'inbox',{kind:'event',topic:'fixture.message'},action).enabled===false,'definitions default off');
 check(emit(env,'fixture.message','disabled',{text:'no wake'}).queued===0,'disabled job ignores events');
 cli(env,'enable','inbox');check(emit(env,'fixture.message','m1',{text:'UNTRUSTED FIXTURE'}).queued===1,'enabled event enqueued');check(emit(env,'fixture.message','m1',{text:'duplicate'}).queued===0,'stable source id deduplicated');
 const watcher=child(sentinel,['watch'],env);
 await until(()=>requests.length===1,'queued wake delivered');
 check(requests[0].thread==='fixture-conversation','wake uses conversation body, not authentication header');
 check(requests[0].text.includes('review-fixture')&&requests[0].text.includes('UNTRUSTED EVENT DATA'),'skill and untrusted event boundary reach agent');
 await until(()=>cli(env,'history').some(d=>d.job_id==='inbox'&&d.state==='completed'),'wake settled only on done');
 simulateLostReply=true;emit(env,'fixture.message','m2',{text:'ambiguous'});await until(()=>requests.length===2,'second wake');await sleep(2500);
 check(requests.length===2,'ambiguous submission is not retried');check(cli(env,'history').find(d=>d.job_id==='inbox').state!=='completed','EOF without done is not success');simulateLostReply=false;
 cli(env,'disable','inbox');check(emit(env,'fixture.message','m3',{}).queued===0,'disable prevents new wakes');
 const script=path.join(root,'procedure.sh');fs.writeFileSync(script,'#!/bin/sh\nprintf "deterministic-proof\\n"\n');
 put(env,'script',{kind:'event',topic:'fixture.script'},{kind:'run',script,timeout_seconds:3});cli(env,'enable','script');emit(env,'fixture.script','s1',{text:'$(not executed as shell)'});
 await until(()=>cli(env,'history').some(d=>d.job_id==='script'&&d.state==='completed'),'deterministic delivery');check(requests.length===2,'script action makes no model call');
 // Filesystem observation runs independently of the control/action loop.
 const incoming=path.join(root,'incoming');fs.mkdirSync(incoming);
 put(env,'files',{kind:'file',path:incoming,pattern:'.incoming'},{kind:'run',script,timeout_seconds:3});cli(env,'enable','files');
 await until(()=>cli(env,'list').find(j=>j.id==='files').source_status==='watching directory','file baseline');
 fs.writeFileSync(path.join(incoming,'fixture.incoming'),'untrusted event text');
 await until(()=>cli(env,'history').some(d=>d.job_id==='files'&&d.state==='completed'),'file event caused deterministic execution');
 check(requests.length===2,'file event makes no model call');cli(env,'disable','files');
 // A real isolated browser page, not the operator's profile or messaging account.
 const chrome=process.env.CHROME_BIN||(process.platform==='win32'?'C:/Program Files/Google/Chrome/Application/chrome.exe':'/usr/bin/chromium');
 check(fs.existsSync(chrome),'real Chrome available (missing is failure, not an inferred skip)');
 const profile=path.join(root,'chrome');fs.mkdirSync(profile);
 child(chrome,['--headless=new','--no-first-run','--no-default-browser-check','--no-sandbox','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],env);
 const active=path.join(profile,'DevToolsActivePort');await until(()=>fs.existsSync(active),'Chrome debug endpoint');const chromePort=fs.readFileSync(active,'utf8').split('\n')[0];
 const pages=await (await fetch(`http://127.0.0.1:${chromePort}/json/list`)).json();const page=pages.find(p=>p.type==='page'&&p.url==='about:blank');check(!!page,'fixture owns an explicit blank page');
 websocket=new WebSocket(page.webSocketDebuggerUrl);await new Promise((r,j)=>{websocket.addEventListener('open',r,{once:true});websocket.addEventListener('error',j,{once:true});});
 let counter=0;const pending=new Map();websocket.addEventListener('message',e=>{const v=JSON.parse(e.data);if(pending.has(v.id)){pending.get(v.id)(v);pending.delete(v.id);}});
 const call=(method,params)=>new Promise(resolve=>{const id=++counter;pending.set(id,resolve);websocket.send(JSON.stringify({id,method,params}));});
 put(env,'browser',{kind:'cdp',websocket_url:page.webSocketDebuggerUrl,binding:'wa_fixture'},{kind:'run',script,timeout_seconds:3});cli(env,'enable','browser');
 await until(async()=>{const v=await call('Runtime.evaluate',{expression:'typeof window.wa_fixture',returnByValue:true});return v.result?.result?.value==='function';},'sentinel CDP binding');
 await call('Runtime.evaluate',{expression:'wa_fixture(JSON.stringify({id:"browser-message-1",data:{text:"hello from real Chrome"}}))'});
 await until(()=>cli(env,'history').some(d=>d.job_id==='browser'&&d.state==='completed'),'real CDP event caused deterministic execution');
 await call('Runtime.evaluate',{expression:'wa_fixture(JSON.stringify({id:"browser-message-1",data:{text:"duplicate"}}))'});await sleep(2500);
 check(cli(env,'history').filter(d=>d.job_id==='browser').length===1,'CDP event deduplication');
 cli(env,'disable','browser');await call('Runtime.evaluate',{expression:'wa_fixture(JSON.stringify({id:"browser-message-2",data:{text:"disabled"}}))'});await sleep(500);
 check(cli(env,'history').filter(d=>d.job_id==='browser').length===1,'disabled CDP job cannot enqueue');
 // Exercise engine API against the actual node, not only the UI's fetch fixture.
 const listener=http.createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const nodePort=listener.address().port;await new Promise(r=>listener.close(r));
 const nodeEnv={...env,WASM_AGENT_PORT:String(nodePort),WASM_AGENT_NODE_KEY:path.join(root,'node.key'),WASM_AGENT_NODE_NAME:'job-proof'};
 child(wa,['--db',path.join(root,'node.db'),'serve','--port',String(nodePort),'--client-port','0','--ui',path.join(repo,'ui')],nodeEnv);
 const base=`http://127.0.0.1:${nodePort}`;
 await until(async()=>{try{return (await fetch(base+'/health')).ok}catch{return false}},'scratch node');
 const list=await (await fetch(base+'/jobs')).json();check(list.jobs.some(j=>j.id==='inbox'&&!j.enabled),'engine reads the same durable job state');
 let response=await fetch(base+'/jobs',{method:'POST',headers:{'content-type':'application/json',origin:'https://untrusted.invalid'},body:JSON.stringify({id:'inbox',action:'enable'})});check(response.status===403,'foreign page cannot enable automation');
 response=await fetch(base+'/jobs',{method:'POST',headers:{'content-type':'application/json',origin:base},body:JSON.stringify({id:'inbox',action:'enable'})});check((await response.json()).enabled===true,'same-origin engine toggle persists');
 check(cli(env,'list').find(j=>j.id==='inbox').enabled===true,'sentinel sees engine toggle');
 console.log(`jobs e2e ok (${checked} checks; real Chrome, real sentinel/node, no paid inference)\nevidence: ${root}`);
}
(async()=>{try{await main()}catch(e){console.error(e.stack);console.error('evidence: '+root);process.exitCode=1}finally{
 if(websocket){try{websocket.send(JSON.stringify({id:99999,method:'Browser.close'}))}catch{}websocket.close();}
 // Only processes started by this fixture; never image-name kills.
 for(const p of children.reverse()){if(p.exitCode===null){p.kill();await Promise.race([new Promise(r=>p.once('exit',r)),sleep(3000)]);}}
 if(receiver)await new Promise(r=>receiver.close(r));
}})();
