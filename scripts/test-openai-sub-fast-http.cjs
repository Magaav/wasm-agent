// Real private node HTTP/CAS, fake subscription usage/status only. No inference.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),net=require('node:net'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]);fs.mkdirSync(out);
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/i.test(k)));
async function listen(s){await new Promise(r=>s.listen(0,'127.0.0.1',r));return s.address().port;}
const hash=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
(async()=>{let checks=0,inference=0;const check=(v,l)=>{checks++;assert(v,l);};
 const vault=http.createServer((req,res)=>{res.setHeader('Content-Type','application/json');
  if(req.url==='/status')return res.end(JSON.stringify({providers:{'openai-sub':{configured:true,enabled:true,generation:'fixture-generation'}}}));
  if(req.url==='/openai-sub/wham/usage')return res.end('{}');
  inference++;res.writeHead(500).end('{}');
 });const vp=await listen(vault);
 try{for(const embedded of [false,true]){
  const reserve=net.createServer(),port=await listen(reserve);await new Promise(r=>reserve.close(r));
  const home=out+'/'+(embedded?'embedded':'source');fs.mkdirSync(home);
  const env={...clean,WASM_AGENT_HOME:home,WASM_AGENT_PROVIDER:'openai-sub',WASM_AGENT_OPENAI_SUB_VAULT_URL:'http://127.0.0.1:'+vp,WASM_AGENT_CLIENT_PORT:'0',WA_GRAPH_WATCH:'0'};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
  const child=spawn(binary,['--db',home+'/test.db','serve','--port',String(port),'--ui',root+'/ui'],{cwd:out,env,windowsHide:true,stdio:['ignore','pipe','pipe']});
  const logs=[];child.stdout.on('data',b=>logs.push(b));child.stderr.on('data',b=>logs.push(b));
  async function call(route,body,headers={}){const r=await fetch('http://127.0.0.1:'+port+route,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json',...headers},body:body===undefined?undefined:typeof body==='string'?body:JSON.stringify(body),signal:AbortSignal.timeout(5000)});return{status:r.status,value:await r.json()};}
  try{
   let ready=false;for(let i=0;i<100;i++){try{const r=await call('/models');if(r.value.model){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,50));}check(ready,'private node ready');
   let settings=(await call('/models')).value;
   settings=(await call('/model',{value:'gpt-6.1-sol',revision:settings.settings_revision})).value;
   check(settings.model==='gpt-6.1-sol','select exact model');
   check(settings.fast_mode.preference==='off','old default OFF');
   let r=await call('/fast-mode',{value:'on',revision:settings.settings_revision});check(r.value.fast_mode.preference==='on','ON through real settings endpoint');settings=r.value;
   const results=await Promise.all(['off','coding'].map(value=>call('/fast-mode',{value,revision:settings.settings_revision})));
   fs.writeFileSync(home+'/concurrent.json',JSON.stringify(results,null,2));
   check(results.filter(r=>['settings_conflict','read_capacity_busy'].includes(r.value.error)).length===1,'concurrent writers: one admission/CAS loser');
   check(results.filter(r=>r.value.fast_mode).length===1,'concurrent writers: one committed preference');
   const stale=await call('/fast-mode',{value:'on',revision:settings.settings_revision});
   check(stale.value.error==='settings_conflict','stale revision rejected after concurrent write');
   settings=(await call('/models')).value;check(settings.settings_revision>r.value.settings_revision,'revision advanced');
   r=await call('/fast-mode',{value:'on',revision:settings.settings_revision},{'X-WA-Node':'foreign'});check(r.value.error==='fast_mode_local_only','remote refused');
   r=await call('/fast-mode',{value:'on',revision:settings.settings_revision},{Origin:'http://stale.invalid'});check(r.status===403,'stale origin refused');
   const guest=(await call('/login','guest')).value.session;
   r=await call('/fast-mode',{value:'on',revision:settings.settings_revision},{'X-WA-Session':guest});check(r.value.error==='forbidden','guest denied');
   r=await call('/fast-mode','on');check(r.value.error==='settings_revision_required','revision mandatory');
   r=await call('/fast-mode',{value:'ultrafast',revision:settings.settings_revision});check(r.value.error==='invalid_fast_mode','Ultrafast excluded');
   r=await call('/fast-mode',{value:'off',revision:settings.settings_revision});check(r.value.fast_mode.preference==='off','OFF escape committed');
   fs.writeFileSync(home+'/settings.json',JSON.stringify(r.value,null,2));
  }finally{child.kill();await new Promise(r=>child.once('close',r));fs.writeFileSync(home+'/node.log',Buffer.concat(logs));}
 }}finally{await new Promise(r=>vault.close(r));}
 check(inference===0,'zero inference calls');const receipt={checks,skips:0,paid_calls:0,inference_calls:inference,binary_sha256:hash(binary)};
 fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
})().catch(e=>{console.error(e);process.exitCode=1;});
