// Real node HTTP, fake vault status only: no live provider/model/account call.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),http=require('node:http'),assert=require('node:assert/strict'),{spawn}=require('node:child_process'),net=require('node:net');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe'),out=fs.mkdtempSync(path.join(os.tmpdir(),'wa-provider-http-'));
const clean=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/i.test(key)));
async function listen(server){await new Promise(r=>server.listen(0,'127.0.0.1',r));return server.address().port;}
async function main(){console.log('Evidence: '+out);let checks=0,upstreamCalls=0;const check=(v,label)=>{checks++;assert(v,label);};
 const vault=http.createServer((req,res)=>{if(req.url!='/status'){upstreamCalls++;res.writeHead(500).end();return;}res.setHeader('Content-Type','application/json');res.end(JSON.stringify({vault_id:'11111111-1111-4111-8111-111111111111',providers:{'opencode-go':{configured:true,enabled:true,generation:'synthetic-generation',operation:'33333333-3333-4333-8333-333333333333'},'openai-sub':{configured:false,enabled:true,generation:'absent'}}}));});
 const vp=await listen(vault);
 try{for(const embedded of [false,true]){
  const reserve=net.createServer();const port=await listen(reserve);await new Promise(r=>reserve.close(r));
  const home=out+'/'+(embedded?'embedded':'source');fs.mkdirSync(home,{recursive:true});
  const env={...clean,WASM_AGENT_HOME:home,WASM_AGENT_OPENCODE_GO_VAULT_URL:'http://127.0.0.1:'+vp,WASM_AGENT_OPENAI_SUB_VAULT_URL:'native',WASM_AGENT_VAULT_OPERATOR_URL:'http://127.0.0.1:8801',WASM_AGENT_CLIENT_PORT:'0',WA_GRAPH_WATCH:'0'};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
  const child=spawn(binary,['--db',home+'/fixture.db','serve','--port',String(port),'--ui',root+'/ui'],{cwd:out,env,windowsHide:true,stdio:['ignore','pipe','pipe']});
  const logs=[];child.stdout.on('data',b=>logs.push(b));child.stderr.on('data',b=>logs.push(b));
  const call=async(route,body,headers={})=>{const r=await fetch('http://127.0.0.1:'+port+route,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json',...headers},body:body===undefined?undefined:typeof body==='string'?body:JSON.stringify(body),signal:AbortSignal.timeout(5000)});return{status:r.status,value:await r.json()};};
  try{
   let ready=false;for(let i=0;i<100;i++){try{await call('/health');ready=true;break;}catch(_){await new Promise(r=>setTimeout(r,50));}}check(ready,'fixture node ready');
   let state;for(let i=0;i<100;i++){state=await call('/provider-management');if(state.status!==503)break;await new Promise(r=>setTimeout(r,50));}
   check(state.status===200&&state.value.providers?.length===2,'real deterministic management route: '+JSON.stringify(state));
   check(state.value.providers[0].source==='native'&&state.value.providers[1].source==='vault','Go source preserves native subscription');
   check(state.value.providers[1].generation==='synthetic-generation','effective route readback includes opaque generation');
   check(state.value.providers[1].operation==='33333333-3333-4333-8333-333333333333'&&state.value.providers[1].embed_url==='http://127.0.0.1:8801/embed/go'&&/^[a-f0-9]{64}$/.test(state.value.embed_scope),'native metadata advertises only bound public frame/receipt scope');
   const foreign=await call('/provider-management',undefined,{'X-WA-Node':'foreign-node'});check(foreign.value.error==='provider_management_local_only','no secret/control relay across node scope');
   const stale=await call('/provider-management',{action:'begin',operation:'synthetic-operation-123'},{Origin:'http://stale.invalid'});check(stale.status===403,'stale origin denied before auth action');
   const rejected=await call('/provider-management',{key:'synthetic-no-node-key'});check(rejected.value.error==='invalid_provider_management_field'&&!JSON.stringify(rejected).includes('synthetic-no-node-key'),'credential-shaped requests refused without echo');
   const childTarget=await call('/provider-management',{action:'begin',operation:'synthetic-operation-123',child_id:'child'});check(childTarget.value.error==='invalid_provider_management_field','child targeting not admitted');
   const login=await call('/login','guest');check(!!login.value.session,'guest fixture session issued');
   const guest=await call('/provider-management',undefined,{'X-WA-Session':login.value.session});check(guest.value.error==='forbidden','guest denied management state');
   const guestWrite=await call('/provider-management',{action:'begin',operation:'synthetic-operation-123'},{'X-WA-Session':login.value.session});check(guestWrite.value.error==='forbidden','guest denied re-login');
  }finally{child.kill();await new Promise(r=>child.once('close',r));fs.writeFileSync(home+'/node.log',Buffer.concat(logs));}
 }}finally{await new Promise(r=>vault.close(r));}
 check(upstreamCalls===0,'all management operations made zero inference/upstream calls');console.log(JSON.stringify({checks,skips:0,paid_calls:0,evidence:out}));}
main().catch(error=>{console.error(error);process.exitCode=1;});
