// Real Chromium event-loop checks; scratch fixtures only, no live browser/node or inference.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {spawn}=require('node:child_process'),{once}=require('node:events'),crypto=require('node:crypto');
const repo=path.resolve(__dirname,'..'),out=path.resolve(process.argv[2]||fs.mkdtempSync(path.join(os.tmpdir(),'wa-light-ui-')));
const pins=()=>Object.fromEntries(['ui/app.js','ui/components.js','ui/style.css','scripts/test-lightweight-browser.cjs'].map(p=>[p,crypto.createHash('sha256').update(fs.readFileSync(path.join(repo,p))).digest('hex')]));
if(process.argv.includes('--post')){
 const r=JSON.parse(fs.readFileSync(out+'/receipt.json'));assert(r.ok&&r.skips===0&&r.checks.length===13);assert.deepEqual(r.sources,pins());assert.equal(r.screenshot_sha256,crypto.createHash('sha256').update(fs.readFileSync(out+'/screenshot.png')).digest('hex'));console.log(JSON.stringify({ok:true,checks:r.checks.length,skips:0,source_verified:true,evidence_verified:true}));process.exit(0);
}
assert(!fs.existsSync(out+'/receipt.json'),'evidence generation already exists');
fs.mkdirSync(out,{recursive:true});const profile=path.join(out,'profile');
const checks=[],waiters=new Map(),sockets=new Set();let browser,ws,seq=0;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
function check(v,m){assert(v,m);checks.push(m);}
async function until(fn,m){const until=Date.now()+8000;while(Date.now()<until){if(await fn())return;await delay(30);}throw Error(m);}
function cdp(method,params={},sessionId){const id=++seq;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{waiters.delete(id);reject(Error(method+' timeout'));},10000);waiters.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});}
async function evaluate(id,expression){const r=await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},id);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
const server=http.createServer((req,res)=>{const url=new URL(req.url,'http://local'),name=url.pathname==='/'?'index.html':url.pathname.slice(1);if(name.includes('..')||name.includes('\\'))return res.writeHead(400).end();
 try{let b=fs.readFileSync(path.join(repo,'ui',name));if(name==='index.html')b=Buffer.from(b.toString().replace('<script src="app.js"></script>','<script src="test-fixtures.js"></script><script src="app.js"></script>'));res.writeHead(200,{'content-type':name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':name.endsWith('.wasm')?'application/wasm':'text/html'});res.end(b);}catch{res.writeHead(404).end();}});
server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});
(async()=>{try{
 server.listen(0,'127.0.0.1');await once(server,'listening');
 const chrome=process.env.WA_TEST_CHROME||'C:/Program Files/Google/Chrome/Application/chrome.exe';
 browser=spawn(chrome,['--headless=new','--disable-gpu','--no-first-run','--remote-debugging-port=0','--user-data-dir='+profile,'about:blank'],{windowsHide:true,stdio:'ignore'});await once(browser,'spawn');
 await until(()=>fs.existsSync(profile+'/DevToolsActivePort'),'DevTools ready');const [port,endpoint]=fs.readFileSync(profile+'/DevToolsActivePort','utf8').trim().split(/\r?\n/);
 ws=new WebSocket('ws://127.0.0.1:'+port+endpoint);await once(ws,'open');ws.addEventListener('message',e=>{const r=JSON.parse(e.data),w=waiters.get(r.id);if(w){waiters.delete(r.id);clearTimeout(w.timer);r.error?w.reject(Error(JSON.stringify(r.error))):w.resolve(r.result);}});
 async function page(){const t=await cdp('Target.createTarget',{url:'about:blank'}),a=await cdp('Target.attachToTarget',{targetId:t.targetId,flatten:true});await cdp('Page.enable',{},a.sessionId);await cdp('Runtime.enable',{},a.sessionId);await cdp('Page.navigate',{url:'http://127.0.0.1:'+server.address().port+'/'},a.sessionId);await until(()=>evaluate(a.sessionId,'typeof metaReady!=="undefined" && metaReady && transcriptReady').catch(()=>false),'page ready');return a.sessionId;}
 const a=await page(),b=await page();
 check(await evaluate(a,"getComputedStyle(document.querySelector('.panel')).backdropFilter==='none' && getComputedStyle(document.querySelector('.orb-core')).animationName==='none'"),'real page has static idle compositing');
 await evaluate(b,"__fixtures.models.model='cross-window-light'; metadataRefreshedAt=Date.now(); true");
 await evaluate(a,'notifyMetadataChange(); true');
 await until(()=>evaluate(b,"settings.model==='cross-window-light'"),'BroadcastChannel changes');check(true,'cross-window invalidation immediately refreshes authoritative settings');
 // Headless background targets suppress ResizeObserver frames; bring the actual tested target forward.
 await cdp('Page.bringToFront',{},a);
 const retained=await evaluate(a,`(()=>{follow=false;transcript.replaceChildren();for(let i=0;i<120;i++){const m=document.createElement('wa-message');m.setAttribute('role',i%2?'assistant':'user');m.body.textContent='Evidence-'+i+' '+('retained original text '.repeat(25));transcript.append(m);}transcript.scrollTop=0;return transcript.children.length;})()`);
 check(retained===120,'all original DOM retained for long transcript');
 await delay(200);
 const measured=await evaluate(a,"({count:transcript.children.length,contained:transcript.querySelectorAll('.render-contained').length,owner:transcript.className,height:transcript.children[0]?.getBoundingClientRect().height,observer:!!messageRenderObserver,first:transcript.children[0]?.outerHTML.slice(0,350)})");fs.writeFileSync(out+'/containment.json',JSON.stringify(measured));
 check(measured.count===120&&measured.contained>=100,'measurement-based containment: '+JSON.stringify(measured));
 check(await evaluate(a,"getComputedStyle(transcript.lastElementChild).contentVisibility==='visible'"),'live/newest bubble always synchronous');
 const search=await evaluate(a,"({found:window.find('Evidence-75',false,false,true),visible:uiVisible(),body:document.body.className,text:transcript.textContent.includes('Evidence-75'),selection:getSelection().toString(),height:transcript.clientHeight,scroll:transcript.scrollTop})");fs.writeFileSync(out+'/search.json',JSON.stringify(search));
 check(search.found,'find-in-page reaches off-screen original evidence: '+JSON.stringify(search));
 const selected=await evaluate(a,"(()=>{const r=document.createRange();r.selectNodeContents(transcript.children[75].body);const s=getSelection();s.removeAllRanges();s.addRange(r);return s.toString().startsWith('Evidence-75');})()");check(selected,'selection/copy keeps off-screen original text');
 await evaluate(a,"getSelection().removeAllRanges();transcript.children[60].scrollIntoView();follow=false;true");await delay(100);
 const position=await evaluate(a,"({scroll:transcript.scrollTop,anchor:transcript.children[60].getBoundingClientRect().top})");
 await evaluate(a,"(()=>{const m=document.createElement('wa-message');m.body.textContent='New evidence';transcript.append(m);return true;})()");await delay(100);
 const after=await evaluate(a,"({scroll:transcript.scrollTop,anchor:transcript.children[60].getBoundingClientRect().top})");fs.writeFileSync(out+'/scroll.json',JSON.stringify({position,after}));
 check(Math.abs(after.anchor-position.anchor)<=2,'new output preserves visible reading anchor in long history: '+JSON.stringify({position,after}));
 const clock=await evaluate(a,"(()=>{const s=document.createElement('wa-step');document.body.append(s);s.setStep('same','running',1000);const o=new MutationObserver(()=>{});o.observe(s,{subtree:true,attributes:true,childList:true});for(let i=0;i<50;i++)s.setStep('same','running',1200);const n=o.takeRecords().length;o.disconnect();s.remove();return n;})()");check(clock===0,'fifty unchanged clock updates cause zero DOM writes');
 const idle=await evaluate(a,"(async()=>{busy=false;observedRun=null;metaReady=true;metadataRetryAt=0;metadataRefreshedAt=Date.now();const now=Date.now,base=now();const n=__calls.filter(x=>x.url.startsWith('models?')).length;Date.now=()=>base+6000;await ensureMeta();Date.now=now;return __calls.filter(x=>x.url.startsWith('models?')).length-n;})()");check(idle===0,'visible idle skips unnecessary five-second metadata read');
 const hidden=await evaluate(a,"(async()=>{const d=Object.getOwnPropertyDescriptor(document,'hidden');Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));metadataRefreshedAt=Date.now();const now=Date.now,base=now();Date.now=()=>base+31000;const n=__calls.filter(x=>x.url.startsWith('models?')).length;await ensureMeta();const rested=document.body.classList.contains('ui-resting');Date.now=now;if(d)Object.defineProperty(document,'hidden',d);else delete document.hidden;document.dispatchEvent(new Event('visibilitychange'));return {reads:__calls.filter(x=>x.url.startsWith('models?')).length-n,rested};})()");check(hidden.reads===0&&hidden.rested,'hidden surface rests optional work without deleting data');
 await delay(100);check(await evaluate(a,"!document.body.classList.contains('ui-resting') && transcript.textContent.includes('Evidence-75')"),'visibility return preserves originals and resumes promptly');
 await cdp('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]},a);
 check(await evaluate(a,"(()=>{const s=document.createElement('span');s.className='spinner';document.body.append(s);const n=getComputedStyle(s).animationName;s.remove();return n==='none';})()"),'reduced-motion disables ongoing animation');
 const shot=await cdp('Page.captureScreenshot',{format:'png'},a);fs.writeFileSync(out+'/screenshot.png',Buffer.from(shot.data,'base64'));
 fs.writeFileSync(out+'/receipt.json',JSON.stringify({ok:true,checks,skips:0,paid_inference:false,sources:pins(),screenshot_sha256:crypto.createHash('sha256').update(Buffer.from(shot.data,'base64')).digest('hex')},null,2));console.log(JSON.stringify({ok:true,checks:checks.length,skips:0,out}));
 }catch(e){fs.writeFileSync(out+'/failure.txt',e.stack||String(e));
 if(ws?.readyState===1){const targets=await cdp('Target.getTargets').catch(()=>null);fs.writeFileSync(out+'/targets.json',JSON.stringify(targets));}
 throw e;}
 finally{if(ws?.readyState===1){await cdp('Browser.close').catch(()=>{});ws.close();}if(browser&&browser.exitCode===null){await Promise.race([once(browser,'close'),delay(2000)]);if(browser.exitCode===null)browser.kill();}for(const w of waiters.values()){clearTimeout(w.timer);w.reject(Error('browser closed'));}waiters.clear();for(const s of sockets)s.destroy();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
