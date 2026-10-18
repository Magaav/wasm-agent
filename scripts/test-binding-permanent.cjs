// Focused no-expiry (permanent) binding proof. One private registry, two administrators, a node that
// explicitly asks for a permanent consent and a node that keeps the ordinary 24-hour one, all real
// native processes. No live service, no model call, no credential, no deploy.
//
// What this proves, and what it deliberately does not:
//  - the registry bounds the ordinary request exactly as before and refuses every unauthorized or
//    malformed no-expiry attempt by name, storing nothing;
//  - a permanent request is granted only by the administrator's own signed affirmation, survives a
//    registry restart, and is fenced by registry revoke/demote and by local /unbind;
//  - a 24-hour grant is never silently upgraded, and status says "no expiry" in words, not as a
//    timestamp.
// It does not authenticate first-contact keys, does not run the live fabric, and does not claim that
// an already-running effect can be cancelled.
const fs=require('fs'),os=require('os'),path=require('path'),crypto=require('crypto'),net=require('net'),assert=require('assert/strict');
const {spawn,spawnSync}=require('child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/release/wa.exe');
const work=fs.mkdtempSync(path.join(os.tmpdir(),'wa-permanent-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_API_KEY$|OPENCODE_GO_API_KEY$)/i.test(k)));
const children=[];let checks=0;const sleep=ms=>new Promise(r=>setTimeout(r,ms));const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
const ok=(v,label)=>{assert(v,label);checks++;console.log('PASS '+label);};
const STANDARD=86400,PERMANENT=50*365*24*3600,CEILING=100*365*24*3600;
const seconds=()=>Math.floor(Date.now()/1000);
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
// The CLI prints progress lines and then one JSON line per command; the last such line is the result.
function resultLine(out){return JSON.parse(out.trim().split(/\r?\n/).filter(l=>l.trim().startsWith('{')).pop());}
(async()=>{try{
 const admin=node('admin'),other=node('other-admin'),phone=node('phone'),peer=node('peer'),stranger=node('unrelated'),registry=node('registry');
 const p=await port(),service='http://127.0.0.1:'+p;
 registry.env.WASM_AGENT_NETWORK_ADMINS=admin.node_id+','+other.node_id;
 let registryChild=start(registry,['rendezvous','--port',String(p)]);
 await until(async()=>{try{return(await request(service+'/health')).status===200}catch{return false}},'registry startup');
 for(const n of [admin,other,stranger]){const ts=Math.floor(Date.now()/1000);const b=JSON.stringify({node_id:n.node_id,public_key:n.public_key,name:n.name,role:'master',endpoints:[],ts,signature:sign(n,'v2|'+n.node_id+'|'+ts+'|'+n.name+'|[]')});assert.equal((await request(service+'/register','POST',b,{'content-type':'application/json'})).status,200);n.env.WASM_AGENT_RENDEZVOUS=service;n.env.WASM_AGENT_RELAY=service;}
 for(const n of [phone,peer]){n.env.WASM_AGENT_RENDEZVOUS=service;n.env.WASM_AGENT_RELAY=service;}

 ok((await request(service+'/service')).value.binding_lifetimes.join('/')==='standard/permanent','service advertises both lifetimes, default first');
 const admins=[{node_id:admin.node_id,public_key:admin.public_key},{node_id:other.node_id,public_key:other.public_key}];
 const body=over=>{const now=seconds();return {schema:1,id:crypto.randomBytes(16).toString('hex'),node_id:phone.node_id,public_key:phone.public_key,code:crypto.randomBytes(6).toString('hex'),name:'phone',service,operators:admins,scope:'user-account-tools',expires_at:now+STANDARD,pairing_expires_at:now+600,...over};};
 const submit=async(value,headerNode=phone)=>{const raw=JSON.stringify(value);return request(service+'/bindings/request','POST',raw,headers(headerNode,'bind-request',raw));};
 const pending=async()=>(await request(service+'/bindings/pending','GET',undefined,headers(admin,'bind-pending'))).value;
 const lookup=id=>request(service+'/lookup?node_id='+id,'GET',undefined,headers(admin,'lookup'));

 // ---- the ordinary request keeps its bounds, and the no-expiry intent is a validated branch ------
 let r=await submit(body({expires_at:seconds()+STANDARD+300}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','an over-long ordinary consent is refused by name');
 r=await submit(body({pairing_expires_at:seconds()+900}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','an over-long pairing window is refused by name');
 r=await submit(body({expires_at:seconds()-1}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','an already-expired ordinary consent is refused');
 r=await submit(body({lifetime:'permanent',expires_at:seconds()+STANDARD}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','permanent inside the ordinary window refuses: it may exceed 86400 and must');
 r=await submit(body({lifetime:'permanent',expires_at:seconds()+CEILING+3600}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','permanent beyond the hundred-year ceiling refuses: the stored value stays finite');
 r=await submit(body({lifetime:'permanent',expires_at:seconds()+PERMANENT,pairing_expires_at:seconds()+900}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','a permanent request still gets only a ten-minute pairing window');
 r=await submit(body({lifetime:'forever',expires_at:seconds()+PERMANENT}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','an unknown lifetime value refuses');
 r=await submit(body({lifetime:null,expires_at:seconds()+PERMANENT}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','a null lifetime refuses instead of reading as absent');
 r=await submit(body({mode:'permanent',expires_at:seconds()+PERMANENT}));
 ok(r.status===400&&r.value.error==='binding_request_invalid','an unknown twelfth field refuses: the shape is fixed');

 // ---- stale or tampered lifetime fields are refused (signature/body binding unchanged) -----------
 const permanent=body({lifetime:'permanent',expires_at:seconds()+PERMANENT});
 const permanentRaw=JSON.stringify(permanent);
 let probe=await request(service+'/bindings/request','POST',permanentRaw,headers(phone,'bind-request',JSON.stringify({...permanent,expires_at:seconds()+PERMANENT+1})));
 ok(probe.status===401&&probe.value.error==='binding_signature_invalid','a lifetime/expiry edit under an old signature refuses');
 const standard=body({}),standardRaw=JSON.stringify(standard);
 probe=await request(service+'/bindings/request','POST',JSON.stringify({...standard,lifetime:'permanent',expires_at:seconds()+PERMANENT}),headers(phone,'bind-request',standardRaw));
 ok(probe.status===401&&probe.value.error==='binding_signature_invalid','a lifetime added under a standard request signature refuses');
 const empty=await pending();
 ok(empty.bindings.length===0&&empty.truncated===false,'every refused request stored nothing');

 // ---- the operator asks for the no-expiry intent explicitly --------------------------------------
 r=cli(phone,['bind','permanent'],service+'\nBIND\n');
 ok(r.status===1&&r.stdout.includes('binding_permanent_consent_required')&&!state(phone),'the ordinary BIND word cannot carry the no-expiry intent');
 r=cli(phone,['bind','permanent'],service+'\nPERMANENT\n');
 ok(r.status===0&&state(phone)?.request.lifetime==='permanent','the explicit PERMANENT word submits the intent');
 const s=state(phone),b=s.request;
 ok(s.revision===1,'the pending request is generation one');
 ok(Object.keys(b).length===12,'the permanent request carries exactly the twelfth lifetime field');
 ok(b.expires_at>seconds()+STANDARD&&b.expires_at<=seconds()+PERMANENT+60,'the permanent request asks for a long but finite consent window');
 ok(b.scope==='user-account-tools','the permanent intent does not widen the capability');
 ok(r.stdout.includes('PERMANENT: this consent has NO EXPIRY'),'the CLI states the no-expiry intent before consent');
 ok(r.stdout.includes('RISK: a lost or stolen device, or a compromised relay, keeps access'),'the CLI states the risk of a permanent grant before consent');
 ok(r.stdout.includes('Consent: no expiry (permanent binding)'),'the permanent consent line says no expiry, not a timestamp');
 ok(r.stdout.includes('lifetimes: standard,permanent'),'the CLI shows that this service understands permanent lifetimes');

 // ---- asking is not authorization: the administrator must affirm the exact intent ---------------
 const accept={id:b.id,node_id:b.node_id,public_key:b.public_key,code:b.code,digest:s.digest,revision:1};
 const acceptWith=over=>{const v={...accept,...over};return {raw:JSON.stringify(v),v};};
 const post=(raw,node,action)=>request(service+'/bindings/accept','POST',raw,headers(node,action,raw));
 r=cli(admin,['accept',b.code],'ACCEPT\n');
 ok(r.status===1&&r.stdout.includes('binding_accept_permanent_confirmation_required'),'the ordinary ACCEPT word cannot grant a no-expiry request');
 r=cli(admin,['accept',b.code],'cancel\n');
 ok(r.status===1&&r.stdout.includes('PERMANENT: this request asks for NO EXPIRY')&&r.stdout.includes('ACCEPT-PERMANENT'),'the acceptance preview names the permanent intent and its own word');
 ok(r.stdout.includes('consent: no expiry (permanent binding'),'the acceptance preview consent line says no expiry');
 let a=acceptWith({authorize_lifetime:'permanent'});
 let x=await post(a.raw,stranger,'bind-accept');
 ok(x.status===403&&x.value.error==='administrator_required','a non-administrator cannot authorize a permanent grant');
 x=await post(JSON.stringify(accept),admin,'bind-accept');
 ok(x.status===403&&x.value.error==='binding_lifetime_authorization_required','a permanent request without the affirmation refuses by name');
 a=acceptWith({authorize_lifetime:'yes'});x=await post(a.raw,admin,'bind-accept');
 ok(x.status===403&&x.value.error==='binding_lifetime_authorization_required','an affirmation that is not the exact intent refuses');
 // The affirmation is inside the signed body, not appended to it.
 a=acceptWith({authorize_lifetime:'permanent'});
 x=await request(service+'/bindings/accept','POST',a.raw,headers(admin,'bind-accept',JSON.stringify(accept)));
 ok(x.status===401&&x.value.error==='bad_signature','the affirmation is signed, not appended to the body');
 a=acceptWith({authorize_lifetime:'permanent',digest:'0'.repeat(64)});x=await post(a.raw,admin,'bind-accept');
 ok(x.status===409&&x.value.error==='binding_generation_changed','the affirmation cannot be moved to another generation');
 const still=(await pending()).bindings;
 ok(still.length===1&&still[0].state==='pending'&&still[0].request.lifetime==='permanent','every refused acceptance left the request pending and granted nothing');

 // ---- the authorized acceptance, and what it survives ------------------------------------------
 r=cli(admin,['accept',b.code],'ACCEPT-PERMANENT\n');
 ok(r.status===0,'the administrator affirmation is accepted');
 const bindStatus=()=>request(service+'/bindings/request?id='+b.id,'GET',undefined,headers(admin,'bind-status'));
 let v=(await bindStatus()).value;
 ok(v.binding.state==='accepted'&&v.binding.request.lifetime==='permanent','the accepted binding keeps the permanent intent');
 ok(v.binding.request.expires_at>seconds()+STANDARD,'the accepted consent window is long, not twenty-four hours');
 ok((await lookup(phone.node_id)).value.binding.state==='accepted','a fresh lookup shows the permanent grant');

 // ---- an ordinary node on the same registry: 24 hours, and it stays 24 hours --------------------
 r=cli(peer,['bind',service],'BIND\n');
 ok(r.status===0,'the ordinary BIND word still submits the ordinary request');
 const ps0=state(peer),pb=ps0.request;
 ok(Object.keys(pb).length===11&&!('lifetime' in pb),'the ordinary request keeps the deployed eleven-field shape');
 ok(pb.expires_at<=seconds()+STANDARD+60,'the ordinary request still asks for twenty-four hours');
 r=cli(admin,['accept',pb.code],'cancel\n');
 ok(r.status===1&&r.stdout.includes('(24-hour standard consent)')&&!r.stdout.includes('no expiry'),'the ordinary acceptance preview says 24-hour, not no-expiry');
 const peerRow=(await pending()).bindings.find(x=>x.request.node_id===peer.node_id);
 const peerAccept={id:pb.id,node_id:pb.node_id,public_key:pb.public_key,code:pb.code,digest:peerRow.digest,revision:peerRow.revision};
 let pa={...peerAccept,authorize_lifetime:'permanent'};
 x=await post(JSON.stringify(pa),admin,'bind-accept');
 ok(x.status===409&&x.value.error==='binding_lifetime_not_requested','a twenty-four-hour request cannot be accepted as permanent');
 r=cli(admin,['accept',pb.code],'ACCEPT-PERMANENT\n');
 ok(r.status===1&&r.stdout.includes('binding_accept_confirmation_required'),'the permanent word on an ordinary request is refused');
 r=cli(admin,['accept',pb.code],'ACCEPT\n');
 ok(r.status===0,'the ordinary ACCEPT still approves the ordinary request');

 // ---- status wording, both cases ----------------------------------------------------------------
 const phoneStatus=resultLine(cli(phone,['bind','status']).stdout);
 ok(phoneStatus.lifetime==='permanent'&&phoneStatus.consent==='no expiry (permanent binding; revoke to end it)','wa bind status reports a permanent grant as no expiry');
 ok(!/\d{6,}/.test(phoneStatus.consent),'the permanent consent wording is not a very large timestamp');
 const peerStatus=resultLine(cli(peer,['bind','status']).stdout);
 ok(peerStatus.lifetime==='standard'&&peerStatus.consent==='expires '+peerStatus.expires_at+' (24-hour standard consent)','wa bind status reports the ordinary grant with its exact expiry');
 ok(!peerStatus.consent.includes('no expiry'),'the ordinary grant is never described as permanent');

 // ---- the permanent grant survives a registry restart and a fresh lookup -----------------------
 await stop(registryChild);
 registryChild=start(registry,['rendezvous','--port',String(p)]);
 await until(async()=>{try{return(await request(service+'/health')).status===200}catch{return false}},'registry restart');
 v=(await lookup(phone.node_id)).value;
 ok(v.binding.state==='accepted'&&v.binding.request.lifetime==='permanent','the permanent grant survives the registry restart as a fresh lookup');

 // ---- delivery through a permanent grant, and the demote fence ----------------------------------
 const phoneRun=start(phone,['bind','run']),peerRun=start(peer,['bind','run']);
 await until(async()=>!!(await lookup(phone.node_id)).value.relay_attached,'permanent node attaches');
 await until(async()=>!!(await lookup(peer.node_id)).value.relay_attached,'ordinary node attaches');
 const call=async(author,capability,args={},to)=>{const body=JSON.stringify({to_node_id:to,capability,args,request_id:crypto.randomUUID()});const envelope=JSON.stringify({rid:crypto.randomUUID(),to,method:'POST',path:'/node/call',headers:headers(author,'call',body),body});return request(service+'/relay/send','POST',envelope,headers(author,'relay-send'));};
 const phoneTarget=path.join(phone.home,'permanent-effect.txt'),peerTarget=path.join(peer.home,'peer-effect.txt');
 let effect=await call(admin,'write',{path:phoneTarget,content:'permanent'},phone.node_id);
 ok(effect.status===200&&fs.readFileSync(phoneTarget,'utf8')==='permanent','a permanent grant delivers a signed effect');
 effect=await call(admin,'write',{path:peerTarget,content:'ordinary'},peer.node_id);
 ok(effect.status===200&&fs.readFileSync(peerTarget,'utf8')==='ordinary','the ordinary grant still delivers on the same registry');
 r=cli(admin,['promote',phone.node_id],'PROMOTE\n');
 ok(r.status===0&&state(phone).network_role==='master','the permanent node can still be promoted (and approval does not do it)');
 // A master's send is accepted by the registry while it holds the role. The receiving node still
 // refuses a caller that is not one of its own pinned operators - binding.present() routes that
 // decision to the caller rule, which is why only an operator's call may execute here - so the
 // effect body says so and the file is untouched: what is measured below is the registry fence.
 effect=await call(phone,'write',{path:peerTarget,content:'phone-wrote'},peer.node_id);
 ok(effect.status===200&&fs.readFileSync(peerTarget,'utf8')==='ordinary','a permanent-bound master may initiate while promoted ['+effect.status+' '+JSON.stringify(effect.value)+']');
 r=cli(admin,['demote',phone.node_id],'DEMOTE\n');
 ok(r.status===0,'the permanent node can be demoted');
 effect=await call(phone,'write',{path:peerTarget,content:'after-demote'},peer.node_id);
 ok(effect.status===403&&effect.value.error==='forbidden_role'&&fs.readFileSync(peerTarget,'utf8')==='ordinary','demote fences a permanent grant for future calls ['+effect.status+' '+JSON.stringify(effect.value)+']');

 // ---- registry revoke fences the permanent grant -------------------------------------------------
 r=cli(admin,['revoke',phone.node_id],'REVOKE\n');
 ok(r.status===0,'the exact administrator revoke of a permanent binding succeeds');
 effect=await call(admin,'write',{path:phoneTarget,content:'after-revoke'},phone.node_id);
 ok(effect.status===403&&fs.readFileSync(phoneTarget,'utf8')==='permanent','registry revoke fences the permanent grant for future calls');
 await stop(phoneRun);await stop(peerRun);

 // ---- no silent upgrade: renewing without the word stays ordinary -------------------------------
 r=cli(peer,['bind','renew'],'BIND\n');
 ok(r.status===0,'renewal without the permanent word submits an ordinary request');
 const renewed=state(peer),rb=renewed.request;
 ok(Object.keys(rb).length===11&&!('lifetime' in rb)&&rb.expires_at<=seconds()+STANDARD+60,'renewal does not silently upgrade an existing twenty-four-hour grant');
 const renewedRow=(await pending()).bindings.find(x=>x.request.node_id===peer.node_id);
 pa={...peerAccept,id:rb.id,code:rb.code,digest:renewedRow.digest,revision:renewedRow.revision,authorize_lifetime:'permanent'};
 x=await post(JSON.stringify(pa),admin,'bind-accept');
 ok(x.status===409&&x.value.error==='binding_lifetime_not_requested','the renewed ordinary request cannot be accepted as permanent');
 r=cli(admin,['accept',rb.code],'ACCEPT\n');
 ok(r.status===0,'the renewed ordinary request is accepted as ordinary');
 const renewedStatus=resultLine(cli(peer,['bind','status']).stdout);
 ok(renewedStatus.lifetime==='standard'&&!/no expiry/.test(renewedStatus.consent),'the renewed grant is still reported as twenty-four hours');

 // ---- local /unbind fences the permanent grant, and needs no registry ---------------------------
 // The re-bind an operator would type in the window or the REPL: the ordinary word is refused, and
 // the explicit one resubmits the no-expiry intent without touching the ordinary path.
 const chat=start(phone,['chat'],true);let phrase='';chat.stdout.on('data',d=>phrase+=d);chat.stderr.resume();
 chat.stdin.write('/session\n/bind permanent renew\nBIND\n/bind permanent renew\nPERMANENT\n/exit\n');
 await until(()=>chat.exitCode!==null,'permanent re-bind REPL exit');
 ok(phrase.includes('binding_permanent_consent_required'),'the REPL will not re-bind a permanent intent on the ordinary word');
 ok(phrase.includes('PERMANENT: this consent has NO EXPIRY'),'the REPL states the no-expiry intent at re-bind');
 const rebound=state(phone);
 ok(rebound.request.lifetime==='permanent'&&Object.keys(rebound.request).length===12,'the REPL re-bind submits the explicit no-expiry request');
 const againRow=(await pending()).bindings.find(x=>x.request.node_id===phone.node_id);
 const again=state(phone);
 const againAccept=JSON.stringify({id:again.request.id,node_id:again.request.node_id,public_key:again.request.public_key,code:again.request.code,digest:againRow.digest,revision:againRow.revision,authorize_lifetime:'permanent'});
 x=await post(againAccept,admin,'bind-accept');
 ok(x.status===200&&x.value.binding.state==='accepted','the permanent re-bind is accepted with the affirmation');
 ok(resultLine(cli(phone,['bind','status']).stdout).lifetime==='permanent','the re-bound node reports the permanent lifetime');
 await stop(registryChild);
 r=cli(phone,['unbind']);
 ok(r.status===1&&resultLine(r.stdout).local_revoked===true&&resultLine(r.stdout).error==='binding_registry_revoke_unconfirmed','local unbind revokes first and reports the unreachable registry separately');
 const localFence=path.join(phone.home,'local-fence.lua');
 fs.writeFileSync(localFence,"local b=dofile('lua/core/binding.lua');assert(not b.profile());assert(not b.authorize('"+admin.node_id+"','"+admin.public_key+"'));print('local revoke fences the permanent grant')");
 const fenceRun=spawnSync(binary,['status'],{cwd:phone.home,env:{...phone.env,WA_SCRIPT:localFence},encoding:'utf8',timeout:20000});
 ok(fenceRun.status===0&&fenceRun.stdout.includes('local revoke fences the permanent grant'),'local revoke refuses the pinned operator with the registry down');
 registryChild=start(registry,['rendezvous','--port',String(p)]);
 await until(async()=>{try{return(await request(service+'/health')).status===200}catch{return false}},'registry restart after local revoke');
 v=(await lookup(phone.node_id)).value;
 ok(v.binding.state==='accepted','the registry still holds the accepted permanent grant, so the refusal above is local');
 const afterUnbind=resultLine(cli(phone,['bind','status']).stdout);
 ok(afterUnbind.active===false&&afterUnbind.lifetime==='permanent','the permanently bound node reports itself inactive after local revoke');
 const fenceAgain=spawnSync(binary,['status'],{cwd:phone.home,env:{...phone.env,WA_SCRIPT:localFence},encoding:'utf8',timeout:20000});
 ok(fenceAgain.status===0&&fenceAgain.stdout.includes('local revoke fences the permanent grant'),'the local boundary holds even once the registry is reachable again');
 // The same intent in one command from the native CLI, with no REPL and no prompt: the whole
 // remainder after `bind` has to reach the controller or `permanent renew` cannot be expressed.
 r=cli(phone,['bind','permanent','renew'],'PERMANENT\n');
 const oneShot=state(phone);
 ok(r.status===0&&oneShot.request.lifetime==='permanent'&&Object.keys(oneShot.request).length===12&&!r.stdout.includes('Fabric HTTPS URL'),'the one-shot CLI can re-bind with the same no-expiry intent, in one command and with no service prompt');
 const oneRow=(await pending()).bindings.find(x=>x.request.node_id===phone.node_id);
 const oneAccept=JSON.stringify({id:oneShot.request.id,node_id:oneShot.request.node_id,public_key:oneShot.request.public_key,code:oneShot.request.code,digest:oneRow.digest,revision:oneRow.revision,authorize_lifetime:'permanent'});
 x=await post(oneAccept,admin,'bind-accept');
 ok(x.status===200&&x.value.binding.state==='accepted','the one-shot permanent re-bind is accepted with the affirmation');
 ok(resultLine(cli(phone,['bind','status']).stdout).lifetime==='permanent','the one-shot re-bound node reports the permanent lifetime');
 // A state file naming a lifetime the signed request does not is corrupt, not a longer grant.
 const tampered=state(phone);tampered.request.lifetime='perpetual';tampered.raw_request=JSON.stringify(tampered.request);tampered.digest=hash(tampered.raw_request);
 fs.writeFileSync(path.join(phone.home,'.wasm-agent/binding.json'),JSON.stringify(tampered));
 const corruptProbe=path.join(phone.home,'corrupt-lifetime.lua');
 fs.writeFileSync(corruptProbe,"local b=dofile('lua/core/binding.lua');assert(b.saved()==nil);print('a state lifetime the request does not carry is refused')");
 const corruptRun=spawnSync(binary,['status'],{cwd:phone.home,env:{...phone.env,WA_SCRIPT:corruptProbe},encoding:'utf8',timeout:20000});
 ok(corruptRun.status===0&&corruptRun.stdout.includes('a state lifetime the request does not carry is refused'),'a tampered local lifetime field is refused, not re-read');

 fs.writeFileSync(path.join(work,'result.json'),JSON.stringify({ok:true,checks,skipped:0,paid_calls:0,source_root:root}));console.log('binding permanent ok ('+checks+' checks, 0 skipped)');
 }finally{for(const c of children.reverse())await stop(c);console.log('evidence: '+work)}})().catch(e=>{console.error(e);process.exitCode=1});
