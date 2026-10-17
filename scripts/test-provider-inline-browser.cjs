// Real Chromium + two real HTTP origins + private durable Python vault. Synthetic credentials only.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),http=require('node:http'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..'),out=process.argv[2]?path.resolve(process.argv[2]):fs.mkdtempSync(path.join(os.tmpdir(),'wa-inline-vault-'));
fs.mkdirSync(out,{recursive:true});console.log('Evidence: '+out);
const TOKEN='fixture-embed-admin-authorization-000000000000',KEY1='fixture-embed-secret-one-operator-only',KEY2='fixture-embed-secret-two-operator-only',SCOPE='a'.repeat(64);
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/i.test(k)));
const wait=ms=>new Promise(r=>setTimeout(r,ms));let checks=0;
function check(v,label){checks++;assert(v,label);}
function lines(stream){let buffer='',queue=[],waiters=[];stream.on('data',b=>{buffer+=b;while(buffer.includes('\n')){const p=buffer.indexOf('\n'),line=buffer.slice(0,p);buffer=buffer.slice(p+1);if(waiters.length)waiters.shift()(line);else queue.push(line);}});return()=>queue.length?Promise.resolve(queue.shift()):new Promise(r=>waiters.push(r));}
class CDP{
 constructor(ws){this.ws=ws;this.id=0;this.pending=new Map();this.contexts=new Map();this.console=[];this.security=[];ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id){const p=this.pending.get(m.id);if(p){this.pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}}else if(m.method==='Runtime.executionContextCreated'){const c=m.params.context;this.contexts.set(c.auxData?.frameId,{id:c.id,sessionId:m.sessionId});}else if(m.method==='Runtime.executionContextDestroyed'){for(const [frame,context]of this.contexts)if(context.id===m.params.executionContextId&&context.sessionId===m.sessionId)this.contexts.delete(frame);}else if(m.method==='Target.attachedToTarget'){this.send('Runtime.enable',{},m.params.sessionId).catch(()=>this.console.push('iframe runtime enable refused'));}else if(m.method==='Target.detachedFromTarget'){for(const [frame,context]of this.contexts)if(context.sessionId===m.params.sessionId)this.contexts.delete(frame);}else if(m.method==='Log.entryAdded'){this.security.push(m.params.entry.text);}else if(m.method==='Runtime.exceptionThrown'){this.console.push(m.params.exceptionDetails.exception?.description||m.params.exceptionDetails.text);}else if(m.method==='Runtime.consoleAPICalled'){this.console.push(JSON.stringify(m.params.args));}});}
 send(method,params={},sessionId){const id=++this.id;return new Promise((resolve,reject)=>{this.pending.set(id,{resolve,reject,timer:setTimeout(()=>{this.pending.delete(id);reject(Error('CDP deadline: '+method));},15000)});this.ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});}
 async eval(expression,context){const r=await this.send('Runtime.evaluate',{expression,contextId:context?.id,awaitPromise:true,returnByValue:true},context?.sessionId);if(r.exceptionDetails)throw Error('browser expression failed: '+r.exceptionDetails.text);return r.result.value;}
 async until(expression,contextId,label,ms=10000){const until=Date.now()+ms;while(Date.now()<until){try{if(await this.eval(expression,contextId))return;}catch(_){}await wait(30);}throw Error(label);}
 async press(key){await this.send('Input.dispatchKeyEvent',{type:'keyDown',key,code:key,windowsVirtualKeyCode:key==='Enter'?13:27,...(key==='Enter'?{text:'\r',unmodifiedText:'\r'}:{})});await this.send('Input.dispatchKeyEvent',{type:'keyUp',key,code:key,windowsVirtualKeyCode:key==='Enter'?13:27});}
 async shot(name){const r=await this.send('Page.captureScreenshot',{format:'png'});fs.writeFileSync(out+'/'+name+'.png',Buffer.from(r.data,'base64'));}
}
const sourceFiles=['ui/app.js','ui/components.js','ui/style.css','lua/core/provider_management.lua','vault/wa_vault.py','vault/page/embed-go.html','vault/page/embed-go.js','vault/page/embed-go.css','scripts/test-vault-embed.py','scripts/test-provider-inline-browser.cjs'];
const sources=()=>Object.fromEntries(sourceFiles.map(p=>[p,crypto.createHash('sha256').update(fs.readFileSync(root+'/'+p)).digest('hex')]));
async function main(){
 const sourceBefore=sources();fs.writeFileSync(out+'/source-start.json',JSON.stringify(sourceBefore,null,2));
 const stage=path.resolve(out,'stage');fs.cpSync(root+'/ui',stage,{recursive:true});
 fs.writeFileSync(stage+'/provider-network.js','window.__providerNetwork=window.fetch.bind(window);');
 fs.writeFileSync(stage+'/provider-route.js',"const fixtureFetch=window.fetch;window.fetch=(url,options)=>String(url).split('?')[0]==='provider-management'?window.__providerNetwork(url,options):fixtureFetch(url,options);");
 let html=fs.readFileSync(stage+'/index.html','utf8');html=html.replace('<script src="app.js"></script>','<script src="provider-network.js"></script><script src="test-fixtures.js"></script><script src="provider-route.js"></script><script src="app.js"></script>');fs.writeFileSync(stage+'/index.html',html);
 let info=null,routeMode='normal',parentCalls=[],chatCalls=0;
 const server=http.createServer(async(req,res)=>{
  let body='';for await(const chunk of req)body+=chunk;
  parentCalls.push({url:req.url,body,headers:JSON.stringify(req.headers)});
  if(req.url==='/log'&&![TOKEN,KEY1,KEY2].some(s=>body.includes(s)))fs.appendFileSync(out+'/parent-errors.jsonl',body+'\n');
  if(req.url==='/provider-management'){
   const status=await(await fetch(info.proxy+'/status')).json(),entry=status.providers['opencode-go'];
   const id=routeMode==='mismatch'?'22222222-2222-4222-8222-222222222222':status.vault_id;
   const origin=routeMode==='same-origin'?'http://'+req.headers.host:routeMode==='tls'?info.admin.replace('http:','https:'):info.admin;
   const data={selected:'openai-sub',embed_scope:SCOPE,providers:[{id:'openai-sub',label:'OpenAI subscription',source:'native',configured:true,enabled:true},{id:'opencode-go',label:'OpenCode Go',source:'vault',configured:entry.configured,enabled:entry.enabled,generation:entry.generation,operation:entry.operation,vault_id:id,vault_url:info.proxy,embed_url:origin+'/embed/go',operator_url:info.admin+'/#vault='+id}],quota:'Monthly workspace quota is not reset by changing a key.'};
   if(routeMode==='missing'){delete data.providers[1].embed_url;}
   if(routeMode==='wrong-source'){data.providers[1].source='legacy environment';}
   res.setHeader('Content-Type','application/json');res.end(JSON.stringify(data));return;
  }
  if(req.url==='/chat'){chatCalls++;res.writeHead(500).end();return;}
  const pathname=new URL(req.url,'http://localhost').pathname,file=path.resolve(stage,'.'+(pathname==='/'?'/index.html':pathname));
  if(!file.startsWith(stage+path.sep)){res.writeHead(403).end();return;}
  try{const data=fs.readFileSync(file);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':file.endsWith('.wasm')?'application/wasm':'text/html');res.end(data);}catch(_){res.writeHead(404).end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;
 const fixture=spawn('python',[root+'/scripts/test-vault-embed.py','--serve',origin],{cwd:root,env:clean,windowsHide:true,stdio:['pipe','pipe','pipe']});const fixtureClosed=new Promise(r=>fixture.once('close',r)),nextLine=lines(fixture.stdout);fixture.stderr.pipe(fs.createWriteStream(out+'/fixture.stderr'));
 const command=async action=>{fixture.stdin.write(JSON.stringify(action)+'\n');return JSON.parse(await Promise.race([nextLine(),wait(10000).then(()=>{throw Error('fixture command deadline: '+action.action);})]));};
 let chrome,cdp;
 try{
  info=JSON.parse(await nextLine());
  const chromePath=path.join(process.env.PROGRAMFILES||'C:/Program Files','Google/Chrome/Application/chrome.exe');
  chrome=spawn(chromePath,['--headless=new','--no-sandbox','--disable-gpu','--disable-background-networking','--disable-default-apps','--disable-component-update','--disable-sync','--no-first-run','--no-default-browser-check','--remote-debugging-port=0','--remote-allow-origins=http://localhost','--user-data-dir='+out+'/profile','--window-size=1280,900','about:blank'],{env:clean,windowsHide:true,stdio:['ignore','ignore','pipe']});
  chrome.stderr.pipe(fs.createWriteStream(out+'/browser.log'));
  let port;for(let i=0;i<200;i++){try{port=Number(fs.readFileSync(out+'/profile/DevToolsActivePort','utf8').split('\n')[0]);break;}catch(_){}await wait(30);}check(!!port,'disposable Chromium started');
  const targets=await(await fetch('http://127.0.0.1:'+port+'/json/list')).json(),target=targets.find(t=>t.type==='page');
  const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});cdp=new CDP(ws);await cdp.send('Runtime.enable');await cdp.send('Page.enable');await cdp.send('Log.enable');await cdp.send('Target.setAutoAttach',{autoAttach:true,waitForDebuggerOnStart:false,flatten:true});
  await cdp.send('Page.navigate',{url:origin});await cdp.until("typeof openProviderManagement==='function'&&transcriptReady",undefined,'staged UI startup');
  const baseNode=await cdp.eval('activeNode');
  await cdp.eval('openProviderManagement()');
  async function frame(){let tree;for(let i=0;i<150;i++){tree=await cdp.send('Page.getFrameTree');const f=tree.frameTree.childFrames?.find(f=>f.frame.url.includes('/embed/go'));if(f&&cdp.contexts.get(f.frame.id))return{...f.frame,context:cdp.contexts.get(f.frame.id)};await wait(30);}throw Error('inline frame/password inside provider section missing');}
  let child=await frame();
  await cdp.until("!document.getElementById('admin').disabled",child.context,'private enrollment ready');
  check(await cdp.eval("document.getElementById('key').type==='password'&&document.getElementById('admin').type==='password'",child.context),'vault-owned password inputs are masked');
  check(await cdp.eval("document.querySelector('wa-provider-manager section:last-child wa-vault-entry iframe')!==null&&document.querySelector('wa-vault-entry iframe').contentDocument===null"),'key box is inside provider panel and parent cannot inspect its cross-origin DOM');
  check(await cdp.eval("document.querySelector('wa-vault-entry iframe').sandbox.value==='allow-scripts allow-same-origin allow-forms'"),'sandbox permits private form events but not top navigation/popups; default form requests are CSP-blocked');
  const enroll=async(token=TOKEN)=>{await cdp.until("!document.getElementById('admin').disabled",child.context,'private enrollment field enabled');await cdp.eval(`document.getElementById('admin').value=${JSON.stringify(token)};document.getElementById('enroll').requestSubmit()`,child.context);};
  const enter=async key=>{await cdp.until("!document.getElementById('key').disabled",child.context,'private key field enabled for operator entry');await cdp.eval(`document.getElementById('key').value=${JSON.stringify(key)}`,child.context);};
  const click=async id=>cdp.eval(`document.getElementById(${JSON.stringify(id)}).click()`,child.context);
  await enroll('synthetic-invalid-enrollment');await cdp.until("document.getElementById('status').textContent.includes('refused')||document.getElementById('status').textContent.includes('unknown')",child.context,'denied authorization visible');
  check(await cdp.eval("document.getElementById('key').disabled&&document.getElementById('admin').value===''",child.context),'denied enrollment cannot save and clears secret input');
  await enroll();await cdp.until("!document.getElementById('key').disabled",child.context,'operator enrollment');
  await enter(KEY1);await click('cancel-entry');check(await cdp.eval("document.getElementById('key').value===''",child.context),'cancel clears without dispatch');check((await command({action:'stats'})).writes===0,'entry cancel writes nothing');
  await enter(KEY1);
  await cdp.eval("document.querySelector('wa-vault-entry').scrollIntoView({block:'center'})");await cdp.shot('password-box');
  check(await cdp.eval("!document.documentElement.outerHTML.includes("+JSON.stringify(KEY1)+")&&!JSON.stringify(localStorage).includes("+JSON.stringify(TOKEN)+")&&!JSON.stringify(sessionStorage).includes("+JSON.stringify(KEY1)+")"),'parent DOM/drafts/storage never receive secrets');
  await cdp.eval("document.getElementById('key').focus()",child.context);await cdp.press('Enter');
  await cdp.until("document.querySelector('wa-provider-manager').textContent.includes('Exact Go vault operation/generation verified')",undefined,'Enter submits only private form with exact parent route readback');
  let stats=await command({action:'stats'});check(stats.writes===1&&!stats.secrets_in_log_or_journal,'Save persists exactly once; no secret in logs/operation ledger');
  check(await cdp.eval("document.getElementById('key').value===''&&document.getElementById('admin').value===''&&!JSON.stringify(localStorage).includes("+JSON.stringify(KEY1)+")&&!JSON.stringify(sessionStorage).includes("+JSON.stringify(TOKEN)+")",child.context),'success clears inputs and does not persist/unmask credentials');
  await fetch(info.proxy+'/opencode-go/v1/chat/completions',{method:'POST',headers:{Authorization:'Bearer wa-vault-brokered'},body:'{"model":"fixture"}'});check((await command({action:'stats'})).upstream_key_one,'fake upstream receives stored key, never the node placeholder');
  await cdp.shot('committed');
  // Forged source/origin/channel cannot manufacture a saved result.
  const before=parentCalls.length;
  await cdp.eval("window.postMessage({type:'wa-vault-go',state:'committed',operation:crypto.randomUUID(),generation:crypto.randomUUID()},location.origin)");await wait(100);check(parentCalls.length===before,'forged parent/window source ignored');
  await cdp.eval("parent.postMessage({type:'wa-vault-go',state:'committed',channel:'wrong',scope:binding.scope,vault_id:binding.vault_id,operation:crypto.randomUUID(),generation:crypto.randomUUID()},binding.parent)",child.context);await wait(100);check(parentCalls.length===before,'stale/wrong channel event ignored');
  const spoof=await cdp.eval("({type:'wa-vault-go',state:'committed',channel:document.querySelector('wa-vault-entry')._channel,scope:document.querySelector('wa-vault-entry').config.scope,vault_id:document.querySelector('wa-vault-entry').config.vault,operation:crypto.randomUUID(),generation:crypto.randomUUID()})");
  await cdp.eval("(()=>{const f=document.createElement('iframe');f.id='forged-sibling';f.sandbox='allow-scripts allow-same-origin';f.src="+JSON.stringify(info.admin+'/identity')+";document.body.append(f);})()");
  let sibling;for(let i=0;i<100;i++){const t=await cdp.send('Page.getFrameTree');const f=t.frameTree.childFrames?.find(r=>r.frame.url.endsWith('/identity'));if(f&&cdp.contexts.get(f.frame.id)){sibling=cdp.contexts.get(f.frame.id);break;}await wait(30);}check(!!sibling,'same-origin foreign source fixture loaded');
  await cdp.eval('parent.postMessage('+JSON.stringify(spoof)+','+JSON.stringify(origin)+')',sibling);await wait(100);check(parentCalls.length===before,'same vault origin but different actual source window is refused');await cdp.eval("document.getElementById('forged-sibling').remove()");
  await cdp.eval("(()=>{const f=document.createElement('iframe');f.id='opaque-forgery';f.sandbox='allow-scripts';f.srcdoc="+JSON.stringify('<script>parent.postMessage('+JSON.stringify(spoof)+','+JSON.stringify(origin)+')</script>')+";document.body.append(f);})()");await wait(100);check(parentCalls.length===before,'opaque/foreign message origin cannot forge a committed result');await cdp.eval("document.getElementById('opaque-forgery').remove()");
  await cdp.eval("message('committed',{operation:crypto.randomUUID(),generation:crypto.randomUUID()})",child.context);
  await cdp.until("document.querySelector('wa-provider-manager').textContent.includes('not verified on the effective route')",undefined,'forged receipt rejected by fresh actual route readback');check((await command({action:'stats'})).writes===1,'forged saved receipt cannot write');
  await enter(KEY2);await cdp.eval('busy=true;applySettingsSovereignty()');await cdp.until("document.getElementById('key').value===''&&document.getElementById('save').disabled",child.context,'active run clears/disables entry');
  check((await command({action:'stats'})).writes===1,'active run causes no save');await cdp.eval('busy=false;applySettingsSovereignty()');
  // Drop a committed response: held UI reconciles exact operation without a second credential send.
  await command({action:'mode',mode:'drop-after'});await enter(KEY2);await click('save');await click('save');await cdp.until("(document.getElementById('status').textContent.startsWith('Save/auth outcome unknown')||document.getElementById('status').textContent.startsWith('Save/auth outcome held'))&&document.getElementById('save').disabled&&!document.getElementById('cancel-operation').disabled",child.context,'ambiguous write held');
  check((await command({action:'stats'})).writes===2,'unknown response had one durable commit');await click('reconcile');await cdp.until("document.getElementById('status').textContent.includes('Exact operation committed')",child.context,'exact reconciliation');check((await command({action:'stats'})).writes===2,'reconcile never resends key');
  await command({action:'restart'});const oldContext=child.context;cdp.contexts.delete(child.id);await cdp.eval('location.reload()',oldContext);child=await frame();await cdp.until("!document.getElementById('admin').disabled",child.context,'restart frame ready');await enroll();await cdp.until("document.getElementById('status').textContent.includes('Exact operation committed')",child.context,'restart retained write');check((await command({action:'stats'})).writes===2,'restart/read-only recovery does not replay');
  await fetch(info.proxy+'/opencode-go/v1/chat/completions',{method:'POST',headers:{Authorization:'Bearer wa-vault-brokered'},body:'{}'});check((await command({action:'stats'})).upstream_key_two,'restart retains correct new credential');
  // Unknown uncommitted send survives panel close/reopen, then explicit cancellation fences late sends.
  await command({action:'mode',mode:'drop-before'});await enter(KEY1);await click('save');await cdp.until("document.getElementById('status').textContent.startsWith('Save/auth outcome unknown')&&!document.getElementById('cancel-operation').disabled",child.context,'uncommitted send held');
  await cdp.eval('providerManagementPanel.close()');check(await cdp.eval("!document.querySelector('wa-vault-entry iframe')"),'close destroys private fields/token, not durable operation');
  await cdp.eval('openProviderManagement()');child=await frame();await cdp.until("!document.getElementById('admin').disabled",child.context,'reopen private frame');await enroll();await cdp.until("document.getElementById('status').textContent.includes('Pending/unknown')",child.context,'reopen finds durable pending fence');
  check(await cdp.eval("document.getElementById('key').value===''&&document.getElementById('save').disabled",child.context),'unknown old payload is not restored or blindly resaved');await click('cancel-operation');await cdp.until("!document.getElementById('save').disabled",child.context,'explicit pending cancellation');
  check((await command({action:'stats'})).writes===2,'close/reopen/cancel never writes another key');
  await enter(KEY1);await cdp.eval("rememberNode('synthetic-other-node')");check(await cdp.eval("!document.querySelector('wa-vault-entry iframe')"),'node switch destroys stale secret frame');
  await cdp.eval("rememberNode("+JSON.stringify(baseNode)+");providerManagementPanel.remove();providerManagementPanel=null;openProviderManagement()");child=await frame();await cdp.until("!document.getElementById('admin').disabled",child.context,'new node-scoped entry');
  await cdp.eval("me.role='guest';renderUser()");check(await cdp.eval("!document.querySelector('wa-vault-entry iframe')"),'guest/account authority change destroys entry');await cdp.eval("me.role='master';renderUser()");
  // Truthful setup and identity failures never fall back to a parent-owned input.
  const reopen=async mode=>{routeMode=mode;await cdp.eval("providerManagementPanel.close();providerManagementPanel.remove();providerManagementPanel=null;openProviderManagement()");};
  await reopen('missing');check(await cdp.eval("!document.querySelector('wa-vault-entry iframe')&&document.querySelector('wa-provider-manager').textContent.includes('setup required')"),'no vault route shows setup-required, not fake key storage');
  await reopen('same-origin');check(await cdp.eval("!document.querySelector('wa-vault-entry iframe')&&document.querySelector('wa-vault-entry').textContent.includes('different HTTPS')"),'same-origin parent-owned secret document is refused');
  await reopen('wrong-source');check(await cdp.eval("!document.querySelector('wa-vault-entry iframe')"),'wrong effective credential source cannot open key form');
  await reopen('mismatch');child=await frame();await cdp.until("document.getElementById('status').textContent.includes('mismatched')",child.context,'wrong vault identity refused');check(await cdp.eval("document.getElementById('admin').disabled&&document.getElementById('key').disabled",child.context),'wrong identity refuses enrollment and key entry');
  await reopen('tls');await cdp.until("document.querySelector('wa-vault-entry').textContent.includes('unavailable')",undefined,'TLS/handshake failure visible',12000);check((await command({action:'stats'})).writes===2,'TLS failure has no credential write or fallback');
  await command({action:'mode',mode:'redirect-frame'});await reopen('normal');await cdp.until("document.querySelector('wa-vault-entry').textContent.includes('unavailable')",undefined,'redirected full-admin frame refused',12000);check((await command({action:'stats'})).writes===2,'redirect/wrong frame source never receives another save');
  await reopen('normal');child=await frame();await cdp.until("!document.getElementById('admin').disabled",child.context,'final private form ready');
  await cdp.eval("document.querySelector('wa-vault-entry').scrollIntoView({block:'center'})");await cdp.shot('final-box');
  check(await cdp.eval("document.querySelector('wa-vault-entry iframe').getBoundingClientRect().width<=document.querySelector('wa-provider-manager').getBoundingClientRect().width"),'iframe fits provider balloon geometry');
  await cdp.send('Emulation.setDeviceMetricsOverride',{width:420,height:900,deviceScaleFactor:1,mobile:false});await cdp.eval("document.querySelector('wa-vault-entry').scrollIntoView({block:'center'})");await cdp.shot('narrow-box');
  check(await cdp.eval("document.documentElement.scrollWidth<=innerWidth+1&&getComputedStyle(document.body).animationName==='none'",child.context),'private password form wraps without overflow or idle animation');
  await cdp.send('Emulation.clearDeviceMetricsOverride');
  await cdp.eval("document.getElementById('admin').focus()",child.context);await cdp.press('Escape');await cdp.until("!providerManagementPanel.open",undefined,'frame Escape closes panel without chat submission');
  check(chatCalls===0,'no chat/inference request from entry or keyboard');
  check(await cdp.eval("(window.__calls||[]).length>0"),'parent fixture captures are active, not an empty oracle');
  check(await cdp.eval("!(window.__calls||[]).some(call=>call.method==='POST'&&/(^|\\/)chat(?:\\?|$)/.test(String(call.url)))"),'private Enter never submits even through the parent chat fixture');
  check(await cdp.eval("!["+[KEY1,KEY2,TOKEN].map(v=>JSON.stringify(v)).join(',')+"].some(secret=>JSON.stringify(window.__calls||[]).includes(secret)||JSON.stringify(localStorage).includes(secret)||JSON.stringify(sessionStorage).includes(secret)||input.value.includes(secret))"),'parent model/tool/session captures, drafts and storage contain no credential material');
  check(!parentCalls.some(r=>/^\/(provider|model|reasoning)$/.test(r.url)||(r.url==='/provider-management'&&r.body)), 'opening/saving never changes provider/model or initiates subscription login');
  check(!parentCalls.some(r=>[KEY1,KEY2,TOKEN].some(s=>(r.url+r.body+r.headers).includes(s))),'parent/node HTTP never receives key or enrollment token');
  check(!cdp.console.some(r=>[KEY1,KEY2,TOKEN].some(s=>r.includes(s))),'console captures contain no secret');
  stats=await command({action:'stats'});check(!stats.secrets_in_log_or_journal&&!stats.providers['openai-sub'].configured,'no log/journal leak or subscription credential side effect');
  const foreign=http.createServer((req,res)=>{const foreignOrigin='http://'+req.headers.host,src=info.admin+'/embed/go#'+new URLSearchParams({vault:info.vault_id,parent:foreignOrigin,scope:SCOPE,channel:crypto.randomUUID()});res.setHeader('Content-Type','text/html');res.end('<!doctype html><title>Unauthorized frame fixture</title><iframe src="'+src+'"></iframe>');});
  await new Promise(r=>foreign.listen(0,'127.0.0.1',r));const securityBefore=cdp.security.length;
  try{await cdp.send('Page.navigate',{url:'http://127.0.0.1:'+foreign.address().port});for(let i=0;i<100&&!cdp.security.slice(securityBefore).some(t=>t.includes('frame-ancestors'));i++)await wait(30);check(cdp.security.slice(securityBefore).some(t=>t.includes('frame-ancestors')),'real browser CSP refuses an unconfigured parent origin');await cdp.shot('foreign-parent-denied');check((await command({action:'stats'})).writes===2,'unauthorized parent cannot enroll or save');}finally{await cdp.send('Page.navigate',{url:'about:blank'});foreign.closeAllConnections();await new Promise(r=>foreign.close(r));}
  // Causal old external-link-only control: use the actual prior component source in a copied stage.
  const original=require('node:child_process').execFileSync('git',['show','bebef12a85ce6c46236c59be27be67a6fcc0fe35:ui/components.js'],{cwd:root,encoding:'utf8'});fs.writeFileSync(stage+'/components.js',original);
  await cdp.send('Page.navigate',{url:origin});await cdp.until("typeof openProviderManagement==='function'&&transcriptReady",undefined,'negative startup');await cdp.eval('openProviderManagement()');
  check(await cdp.eval("document.querySelector('wa-provider-manager')&&!document.querySelector('wa-vault-entry iframe')"),'causal external-link/no-box UI fails inline field requirement');await cdp.shot('old-ui-negative');
  check(JSON.stringify(sourceBefore)===JSON.stringify(sources()),'execution source unchanged during real browser/frame proof');
  fs.writeFileSync(out+'/receipt.json',JSON.stringify({ok:true,checks,skips:0,paid_calls:0,security_blocks:cdp.security,sources:sourceBefore,source_commit:require('node:child_process').execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),writes:stats.writes,negative:'actual baseline bebef12 external-link-only components in copied stage'},null,2));console.log(JSON.stringify({ok:true,checks,skips:0,evidence:out}));
 }catch(error){
  try{fs.writeFileSync(out+'/fixture-stats.json',JSON.stringify(await command({action:'stats'})));}catch(_){}
  if(cdp){try{const diagnostic=await cdp.eval("({title:document.title,ready:typeof transcriptReady==='undefined'?'undefined':transcriptReady,renderer:typeof rendererLoaded,body:document.body.textContent.slice(0,3000)})");fs.writeFileSync(out+'/parent-diagnostic.json',JSON.stringify(diagnostic));const frames=await cdp.send('Page.getFrameTree');for(const f of frames.frameTree.childFrames||[]){const ctx=cdp.contexts.get(f.frame.id);try{const d=await cdp.eval("({text:document.body.textContent,busy:typeof busy!=='undefined'&&busy,active:typeof active!=='undefined'&&active,verified:typeof verified!=='undefined'&&verified,tokenPresent:typeof token!=='undefined'&&!!token,adminTyped:!!document.getElementById('admin')?.value})",ctx);fs.writeFileSync(out+'/frame-diagnostic.json',JSON.stringify(d));}catch(_){}}fs.writeFileSync(out+'/console.json',JSON.stringify(cdp.console));await cdp.shot('failure');fs.writeFileSync(out+'/frames.json',JSON.stringify(frames));}catch(_){} }
  throw error;
 }finally{cdp?.ws.close();if(chrome){chrome.kill();}fixture.stdin.write('{"action":"stop"}\n');fixture.stdin.end();await Promise.race([fixtureClosed,wait(5000).then(()=>fixture.kill())]);server.closeAllConnections();await new Promise(r=>server.close(r));}
}
main().catch(error=>{fs.writeFileSync(out+'/failure.txt',String(error.stack||error));console.error(String(error.message||error));process.exitCode=1;});
