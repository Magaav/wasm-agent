// Real Chromium frames/timers; disposable staged UI, never the installed page.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {spawn}=require('node:child_process'),{once}=require('node:events');
const repo=path.resolve(__dirname,'..'),out=process.argv[2];assert(out&&path.isAbsolute(out),'absolute evidence required');
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const files=['ui/app.js','ui/components.js','ui/style.css','scripts/test-final-answer-ui.js','scripts/test-final-answer-reading.cjs'];
const pins=()=>Object.fromEntries(files.map(f=>[f,hash(path.join(repo,f))]));
if(process.argv.includes('--post')){
 const r=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(r.ok&&r.skips===0&&r.real_frames);
 assert.deepEqual(r.sources,pins());for(const name of ['screenshot.png','dom.html'])assert.equal(hash(path.join(out,name)),r.artifacts[name]);
 console.log(JSON.stringify({ok:true,source_verified:true,evidence_verified:true,real_frames:true,skips:0}));process.exit(0);
}
assert(!fs.existsSync(out),'fresh evidence required');fs.mkdirSync(out);const stage=path.join(out,'stage'),profile=path.join(out,'profile');fs.cpSync(path.join(repo,'ui'),stage,{recursive:true});
let html=fs.readFileSync(path.join(stage,'index.html'),'utf8');assert(html.includes('<script src="app.js"></script>'));
html=html.replace('<script src="app.js"></script>','<script src="test-fixtures.js"></script><script src="app.js"></script>').replace('</body>','<script src="reading-probe.js"></script></body>');
fs.writeFileSync(path.join(stage,'index.html'),html);fs.writeFileSync(path.join(stage,'reading-probe.js'),'window.__realAnswerMotion=true;\n'+fs.readFileSync(path.join(repo,'scripts/test-final-answer-ui.js'),'utf8'));
let browser,ws,seq=0;const waiters=new Map(),sockets=new Set();const delay=ms=>new Promise(r=>setTimeout(r,ms));
function cdp(method,params={},sessionId){const id=++seq;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{waiters.delete(id);reject(Error(method+' timeout'));},10000);waiters.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});}
async function evaluate(session,expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},session);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
async function until(fn,label){const end=Date.now()+20000;while(Date.now()<end){if(await fn())return;await delay(30);}throw Error(label);}
const server=http.createServer((req,res)=>{const name=new URL(req.url,'http://fixture').pathname;const file=path.resolve(stage,'.'+(name==='/'?'/index.html':name));if(!file.startsWith(stage+path.sep))return res.writeHead(403).end();try{const type={'.js':'application/javascript','.css':'text/css','.wasm':'application/wasm','.html':'text/html'}[path.extname(file)]||'application/octet-stream';res.writeHead(200,{'content-type':type});res.end(fs.readFileSync(file));}catch{res.writeHead(404).end();}});
server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});
(async()=>{let receipt={ok:false,sources:pins(),skips:0,real_frames:true};try{
 server.listen(0,'127.0.0.1');await once(server,'listening');
 const chrome=process.env.WA_TEST_CHROME||process.env.WA_CHROME||(process.platform==='win32'?'C:/Program Files/Google/Chrome/Application/chrome.exe':'chromium');
 browser=spawn(chrome,['--headless=new','--disable-gpu','--no-first-run','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{windowsHide:true,stdio:'ignore'});await once(browser,'spawn');
 await until(()=>fs.existsSync(path.join(profile,'DevToolsActivePort')),'DevTools ready');const [port,endpoint]=fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').trim().split(/\r?\n/);
 ws=new WebSocket('ws://127.0.0.1:'+port+endpoint);await once(ws,'open');ws.addEventListener('message',event=>{const r=JSON.parse(event.data),w=waiters.get(r.id);if(w){clearTimeout(w.timer);waiters.delete(r.id);r.error?w.reject(Error(JSON.stringify(r.error))):w.resolve(r.result);}});
 const target=await cdp('Target.createTarget',{url:'about:blank'}),attached=await cdp('Target.attachToTarget',{targetId:target.targetId,flatten:true}),session=attached.sessionId;
 await cdp('Page.enable',{},session);await cdp('Runtime.enable',{},session);await cdp('Emulation.setDeviceMetricsOverride',{width:1280,height:900,deviceScaleFactor:1,mobile:false},session);
 await cdp('Page.bringToFront',{},session);await cdp('Page.navigate',{url:'http://127.0.0.1:'+server.address().port+'/'},session);
 await until(()=>evaluate(session,"!!document.querySelector('pre#wa-probe[data-status]')").catch(()=>false),'reading probe completion');
 const proof=await evaluate(session,"({status:document.getElementById('wa-probe').dataset.status,text:document.getElementById('wa-probe').textContent,title:document.title,html:document.documentElement.outerHTML})");
 fs.writeFileSync(path.join(out,'dom.html'),proof.html);receipt.probe_status=proof.status;receipt.probe_text=proof.text;
 const shot=await cdp('Page.captureScreenshot',{format:'png'},session);fs.writeFileSync(path.join(out,'screenshot.png'),Buffer.from(shot.data,'base64'));
 assert(proof.title==='wasm-agent'&&proof.status==='pass',proof.text);receipt.ok=true;receipt.artifacts=Object.fromEntries(['dom.html','screenshot.png'].map(name=>[name,hash(path.join(out,name))]));
}catch(error){receipt.error=String(error.stack||error);process.exitCode=1;}
finally{fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));
 if(ws?.readyState===1){await cdp('Browser.close').catch(()=>{});ws.close();}if(browser&&browser.exitCode===null){await Promise.race([once(browser,'close'),delay(2000)]);if(browser.exitCode===null)browser.kill();}
 for(const w of waiters.values()){clearTimeout(w.timer);w.reject(Error('browser closed'));}waiters.clear();for(const socket of sockets)socket.destroy();await new Promise(r=>server.close(r));
 console.log(JSON.stringify({ok:receipt.ok,real_frames:true,skips:0,out,error:receipt.error,probe:receipt.probe_text}));}
})().catch(error=>{console.error(error);process.exitCode=1;});
