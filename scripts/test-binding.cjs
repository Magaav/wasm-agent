// Native private registry + live CLI + two admins + unrelated peer. No live fabric/model credentials.
const fs=require('fs'),os=require('os'),path=require('path'),crypto=require('crypto'),net=require('net'),assert=require('assert/strict');
const {spawn,spawnSync}=require('child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/release/wa.exe');
const work=fs.mkdtempSync(path.join(os.tmpdir(),'wa-binding-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_API_KEY$|OPENCODE_GO_API_KEY$)/i.test(k)));
const children=[];let checks=0;const sleep=ms=>new Promise(r=>setTimeout(r,ms));const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
const ok=(v,label)=>{assert(v,label);checks++;console.log('PASS '+label);};
function cli(n,args,input){const r=spawnSync(binary,args,{cwd:n.home,env:n.env,input,encoding:'utf8',timeout:70000,windowsHide:true});fs.appendFileSync(path.join(n.home,'cli.jsonl'),JSON.stringify({args,status:r.status,stdout:r.stdout,stderr:r.stderr})+'\n');return r;}
function node(name){const home=path.join(work,name);fs.mkdirSync(home);const n={home,env:{...env,WASM_AGENT_HOME:home,WA_GRAPH_WATCH:'0'}};const r=cli(n,['node']);assert.equal(r.status,0,r.stderr);Object.assign(n,JSON.parse(r.stdout));n.name=name;return n;}
const sign=(n,text)=>{const r=cli(n,['node','sign',text]);assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
function headers(n,action,body){const ts=Math.floor(Date.now()/1000);return {'content-type':'application/json','x-wa-node':n.node_id,'x-wa-pub':n.public_key,'x-wa-ts':String(ts),'x-wa-sig':sign(n,action+'|'+n.node_id+'|'+ts+(body===undefined?'':'|'+hash(body)))};}
async function request(url,method='GET',body,h={}){const r=await fetch(url,{method,body,headers:h,signal:AbortSignal.timeout(70000)});const text=await r.text();let value;try{value=JSON.parse(text)}catch{value=text}return {status:r.status,value};}
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
function start(n,args,piped=false){const log=fs.openSync(path.join(n.home,'runtime-'+children.length+'.log'),'a');const c=spawn(binary,args,{cwd:n.home,env:n.env,stdio:piped?['pipe','pipe','pipe']:['ignore',log,log],windowsHide:true});fs.closeSync(log);children.push(c);return c;}
async function until(f,label){for(let i=0;i<150;i++){if(await f())return;await sleep(100)}throw Error('timeout '+label);}
async function stop(c){if(c.exitCode!==null||c.signalCode!==null)return;let timer;const done=new Promise((r,j)=>{timer=setTimeout(()=>j(Error('child exit unknown '+c.pid)),10000);c.once('exit',r)});c.kill();try{await done}finally{clearTimeout(timer)}}
function state(n){const f=path.join(n.home,'.wasm-agent/binding.json');return fs.existsSync(f)?JSON.parse(fs.readFileSync(f)):null;}
(async()=>{try{
 const admin=node('admin'),other=node('other-admin'),app=node('arch-cli'),stranger=node('unrelated'),registry=node('registry');
 const p=await port(),service='http://127.0.0.1:'+p;
 registry.env.WASM_AGENT_NETWORK_ADMINS=admin.node_id+','+other.node_id;
 start(registry,['rendezvous','--port',String(p)]);
 await until(async()=>{try{return(await request(service+'/health')).status===200}catch{return false}},'registry startup');
 for(const n of [admin,other,stranger]){const ts=Math.floor(Date.now()/1000);const b=JSON.stringify({node_id:n.node_id,public_key:n.public_key,name:n.name,role:'master',endpoints:[],ts,signature:sign(n,n.node_id+'|'+ts)});assert.equal((await request(service+'/register','POST',b,{'content-type':'application/json'})).status,200);n.env.WASM_AGENT_RENDEZVOUS=service;n.env.WASM_AGENT_RELAY=service;}
 ok((await request(service+'/service')).value.binding_protocol===1,'binding service discovery version');
 const beforeKey=fs.readFileSync(path.join(app.home,'.wasm-agent/node.key'));
 app.env.WASM_AGENT_NODE_NAME='arch-cli';
 fs.writeFileSync(path.join(app.home,'.wasm-agent/env'),'WASM_AGENT_LLM_API_KEY=fixture-preserved\n');const beforeEnv=fs.readFileSync(path.join(app.home,'.wasm-agent/env'));
 let r=cli(app,['bind',service],'cancel\n');ok(r.status===1&&!state(app),'cancel stores no consent/binding');
 const serverOwner=node('server-owner'),serverPort=await port(),serverClient=await port();
 const serverChild=start(serverOwner,['serve','--port',String(serverPort),'--client-port',String(serverClient),'--ui',path.join(root,'ui')]);
 await until(async()=>{try{return(await request('http://127.0.0.1:'+serverPort+'/health')).status===200}catch{return false}},'existing server');
 const conflict=cli(serverOwner,['bind',service],'BIND\n');ok(conflict.status===1&&!state(serverOwner)&&conflict.stdout.includes('existing_server_owned'),'existing server refuses CLI attachment before consent persistence');await stop(serverChild);
 r=cli(app,['bind','http://example.org'],'BIND\n');ok(r.status===1&&r.stdout.includes('requires_https')&&!state(app),'nonloopback HTTP refuses before effects');
 const invalidPort=await port();r=cli(app,['bind','http://127.0.0.1:'+invalidPort],'BIND\n');ok(r.status===1&&!state(app),'missing service refuses without consent');
 const chat=start(app,['chat'],true);let output='',stderr='';chat.stdout.on('data',b=>output+=b);chat.stderr.on('data',b=>stderr+=b);
 chat.stdin.write('/session\n/bind '+service+'\nBIND\n');
 await until(()=>state(app)?.phase==='pending','CLI submitted pairing');const s=state(app),b=s.request;
 ok(output.includes('NOT a workspace sandbox'),'human authority warning');
 ok(fs.readFileSync(path.join(app.home,'.wasm-agent/node.key')).equals(beforeKey)&&fs.readFileSync(path.join(app.home,'.wasm-agent/env')).equals(beforeEnv),'key/provider settings preserved');
 ok(b.node_id===app.node_id&&!s.active,'pending binding has no execution authority');
 r=cli(admin,['nodes','pending']);ok(r.status===0&&JSON.parse(r.stdout).bindings.length===1,'actual native pending command');
 const pending=(await request(service+'/bindings/pending','GET',undefined,headers(admin,'bind-pending'))).value;
 ok(pending.bindings.length===1&&pending.bindings[0].digest===s.digest,'administrator pending inventory exact request');
 ok((await request(service+'/bindings/pending','GET',undefined,headers(stranger,'bind-pending'))).status===403,'ordinary guest cannot enumerate pairing');
 const original=s.raw_request;
 ok((await request(service+'/bindings/request','POST',original,headers(app,'bind-request',original))).status===200,'exact duplicate request collects same receipt');
 const wrongPins=JSON.stringify({...b,id:crypto.randomBytes(16).toString('hex'),code:crypto.randomBytes(6).toString('hex'),operators:[{node_id:admin.node_id,public_key:'0'.repeat(64)}]});
 ok((await request(service+'/bindings/request','POST',wrongPins,headers(app,'bind-request',wrongPins))).status===409,'wrong or missing operator pins refuse');
 const expiredPair=JSON.stringify({...b,id:crypto.randomBytes(16).toString('hex'),code:crypto.randomBytes(6).toString('hex'),pairing_expires_at:1});
 ok((await request(service+'/bindings/request','POST',expiredPair,headers(app,'bind-request',expiredPair))).status===400,'expired pairing cannot mint a request');
 const changed=JSON.stringify({...b,name:'changed'});
 ok((await request(service+'/bindings/request','POST',changed,headers(app,'bind-request',changed))).status===409,'request ID cannot change payload');
 ok((await request(service+'/bindings/request','POST',changed,headers(app,'bind-request',original))).status===401,'request signature binds entire payload');
 const accept={id:b.id,node_id:b.node_id,public_key:b.public_key,code:b.code,digest:s.digest,revision:1};let raw=JSON.stringify(accept);
 ok((await request(service+'/bindings/accept','POST',raw,headers(stranger,'bind-accept',raw))).status===403,'nonadministrator cannot accept');
 const bad=JSON.stringify({...accept,digest:'0'.repeat(64)});
 ok((await request(service+'/bindings/accept','POST',bad,headers(admin,'bind-accept',bad))).status===409,'wrong digest cannot accept');
 r=cli(admin,['accept',b.code],'cancel\n');ok(r.status===1,'administrator cancellation leaves pending');
 r=cli(admin,['promote',app.node_id],'PROMOTE\n');ok(r.status===1,'pending node cannot promote');
 r=cli(admin,['accept',b.code],'ACCEPT\n');ok(r.status===0,'actual native administrator acceptance command');
 await until(()=>state(app)?.active,'app observes approval');
 const lookup=()=>request(service+'/lookup?node_id='+app.node_id,'GET',undefined,headers(admin,'lookup'));
 await until(async()=>!!(await lookup()).value.relay_attached,'actual outbound relay attach');
 ok((await lookup()).value.role==='guest','acceptance does not promote');
 r=cli(app,['bind',service],'BIND\n');ok(r.status===1&&r.stdout.includes('existing_request'),'duplicate binding requires inspection not new submission');
 ok((await request(service+'/bindings/accept','POST',raw,headers(other,'bind-accept',raw))).status===409,'stale second acceptance refuses');
 r=cli(app,['bind','run']);ok(r.status===1&&r.stdout.includes('already_owned'),'second process attachment fails OS lease');
 async function call(author,capability,args={},to=app.node_id){const body=JSON.stringify({to_node_id:to,capability,args,request_id:crypto.randomUUID()});const envelope=JSON.stringify({rid:crypto.randomUUID(),to:app.node_id,method:'POST',path:'/node/call',headers:headers(author,'call',body),body});return request(service+'/relay/send','POST',envelope,headers(author,'relay-send'));}
 const target=path.join(app.home,'approved-effect.txt');let effect=await call(admin,'write',{path:target,content:'approved'});
 ok(effect.status===200&&fs.readFileSync(target,'utf8')==='approved','signed approved native effect via outbound CLI');
 effect=await call(admin,'write',{path:target,content:'redirected'},other.node_id);ok(JSON.parse(effect.value.body).error==='wrong_target'&&fs.readFileSync(target,'utf8')==='approved','wrong target cannot affect files');
 const staleGrant=JSON.stringify({node_id:app.node_id,public_key:app.public_key,role:'master',binding_id:b.id,binding_digest:s.digest,binding_revision:1});
 ok((await request(service+'/role','POST',staleGrant,headers(admin,'grant-role',staleGrant))).status===409,'role grant refuses stale binding generation');
 r=cli(admin,['promote',app.node_id],'PROMOTE\n');ok(r.status===0,'native promotion registry plus target acknowledged');
 ok(state(app).network_role==='master'&&(await lookup()).value.role==='master','network promotion verified without local role mutation');
 raw=JSON.stringify({...accept,revision:2});ok((await request(service+'/bindings/accept','POST',raw,headers(app,'bind-accept',raw))).status===403,'promoted master still cannot accept devices');
 chat.stdin.write('/session\n/bind status\n');await sleep(500);
 const ledgerProbe=path.join(app.home,'ledger-probe.lua');fs.writeFileSync(ledgerProbe,"local j=dofile('lua/vendor/json.lua');print(host.sql_query('SELECT count(*) n FROM sessions','[]'));print(host.sql_query('SELECT count(*) n FROM messages','[]'))");
 const ledgerRun=spawnSync(binary,['status'],{cwd:app.home,env:{...app.env,WA_SCRIPT:ledgerProbe},encoding:'utf8',timeout:15000});assert.equal(ledgerRun.status,0,ledgerRun.stderr);
 const counts=ledgerRun.stdout.trim().split(/\r?\n/).map(s=>JSON.parse(s)[0].n);
 ok(counts[0]===1,'binding keeps the same CLI session');ok(counts[1]===0,'binding controls never enter model transcript');
 ok(!output.includes('no model')&&!stderr.includes('model request'),'slash commands make zero model calls');
 r=cli(admin,['demote',app.node_id],'DEMOTE\n');ok(r.status===0&&state(app).network_role==='guest','native demotion preserves local CLI');
 if(process.platform!=='win32')ok((fs.statSync(path.join(app.home,'.wasm-agent/binding.json')).mode&0o777)===0o600,'Unix binding state private from creation');
 // A saved local expiry fences an already queued relay request without a timer-based settle.
 const stateFile=path.join(app.home,'.wasm-agent/binding.json'),savedState=fs.readFileSync(stateFile);
 const expired=state(app);expired.expires_at=expired.request.expires_at=1;expired.raw_request=JSON.stringify(expired.request);expired.digest=hash(expired.raw_request);fs.writeFileSync(stateFile,JSON.stringify(expired));
 r=cli(app,['access']);const expiredView=JSON.parse(r.stdout);ok(expiredView.active===false,'expired local consent is not reported active');
 const probe=path.join(app.home,'expiry-probe.lua');fs.writeFileSync(probe,"local b=dofile('lua/core/binding.lua');assert(not b.profile());assert(not b.authorize('"+admin.node_id+"','"+admin.public_key+"'));print('expired grant refused')");
 const probeRun=spawnSync(binary,['status'],{cwd:app.home,env:{...app.env,WA_SCRIPT:probe},encoding:'utf8',timeout:15000});ok(probeRun.status===0&&probeRun.stdout.includes('expired grant refused'),'expired native Lua authorization refuses pinned operator');fs.writeFileSync(stateFile,savedState);
 const corrupt=Buffer.from('{');fs.writeFileSync(stateFile,corrupt);r=cli(app,['bind',service],'BIND\n');ok(r.status===1&&fs.readFileSync(stateFile).equals(corrupt),'corrupt state refuses without overwrite');fs.writeFileSync(stateFile,savedState);
 r=cli(admin,['revoke',app.node_id],'REVOKE\n');ok(r.status===0,'exact administrator binding revoke');
 effect=await call(admin,'write',{path:target,content:'after-revoke'});ok(effect.status===403&&fs.readFileSync(target,'utf8')==='approved','revoked relay cannot execute');
 chat.stdin.write('/unbind\n/exit\n');await until(()=>chat.exitCode!==null,'CLI clean exit');ok(state(app).consent===false,'local unbind retained identity but disabled access');
 ok(fs.readFileSync(path.join(app.home,'.wasm-agent/node.key')).equals(beforeKey),'key unchanged through unbind');
 const restarted=start(app,['chat','--continue'],true);let resumed='';restarted.stdout.on('data',x=>resumed+=x);restarted.stderr.resume();restarted.stdin.write('/bind status\n/exit\n');await until(()=>restarted.exitCode!==null,'revoked CLI restart');ok(resumed.includes('"active":false')&&state(app).consent===false,'restart does not reactivate revoked consent');
 fs.writeFileSync(path.join(work,'result.json'),JSON.stringify({ok:true,checks,skipped:0,paid_calls:0,source_root:root}));console.log('binding ok ('+checks+' checks, 0 skipped)');
 }finally{for(const c of children.reverse())await stop(c);console.log('evidence: '+work)}})().catch(e=>{console.error(e);process.exitCode=1});
