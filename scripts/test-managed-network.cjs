// Disposable registry + two guests + two admins. Never touches the live service.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const net = require('node:net');
const {spawn, spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const binary = path.resolve(process.argv[2] || path.join(root, 'rust/target/release/wa.exe'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-managed-network-'));
const clean = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(WASM_AGENT_|WA_|OPENAI_API_KEY$|OPENCODE_GO_API_KEY$)/i.test(k)));
const children = [];
const externalPids = [];
let checks = 0;
const hash = s => crypto.createHash('sha256').update(s).digest('hex');
const now = () => Math.floor(Date.now()/1000);
const sleep = ms => new Promise(r => setTimeout(r, ms));
function check(value, label) { assert.ok(value, label); console.log('PASS ' + label); checks++; }
function cli(node, args, allowFailure=false) {
  const r = spawnSync(binary, args, {env:node.env, cwd:node.home, encoding:'utf8', timeout:60000, windowsHide:true});
  if (r.error || (!allowFailure && r.status !== 0)) throw new Error(`CLI ${args[0]}: ${r.error || r.stderr || r.stdout}`);
  return {value: args[0]==='node' && args[1]==='sign' ? r.stdout.trim() : JSON.parse(r.stdout.trim()), status:r.status};
}
function fixture(name) {
  const home = path.join(work, name); fs.mkdirSync(home);
  const node = {home, env:{...clean, WASM_AGENT_HOME:home}};
  Object.assign(node, cli(node, ['node']).value);
  node.name = name;
  return node;
}
function signature(node, message) { return cli(node, ['node','sign',message]).value; }
function headers(node, action, body) {
  const ts = now();
  return {'content-type':'application/json','x-wa-node':node.node_id,'x-wa-pub':node.public_key,
    'x-wa-ts':String(ts),'x-wa-sig':signature(node, `${action}|${node.node_id}|${ts}${body === undefined ? '' : '|'+hash(body)}`)};
}
async function request(url, method='GET', body, h={}) {
  const r = await fetch(url, {method,headers:h,body,signal:AbortSignal.timeout(60000)});
  const text = await r.text();
  let value; try { value=JSON.parse(text); } catch { value=text; }
  return {status:r.status,value};
}
async function freePair() {
  for (;;) {
    const a=net.createServer(), b=net.createServer();
    await new Promise(r=>a.listen(0,'127.0.0.1',r)); const port=a.address().port;
    const good=await new Promise(r=>{ b.once('error',()=>r(false)); b.listen(port+1,'127.0.0.1',()=>r(true)); });
    await new Promise(r=>a.close(r)); if (good) { await new Promise(r=>b.close(r)); return port; }
  }
}
function start(node, args, extra={}) {
  const log=fs.openSync(path.join(node.home, `process-${children.length}.log`),'a');
  const child=spawn(binary,args,{env:{...node.env,...extra},cwd:node.home,stdio:['ignore',log,log],windowsHide:true});
  fs.closeSync(log); children.push(child); return child;
}
async function until(fn, label) {
  for (let i=0;i<100;i++) { try { if(await fn()) return; } catch {} await sleep(100); }
  throw new Error('timeout: '+label);
}
async function register(service,node,role='master',override={}) {
  const ts=now();
  const payload={node_id:node.node_id,public_key:node.public_key,name:node.name,role,endpoints:[],ts,
    signature:signature(node,`${node.node_id}|${ts}`),...override};
  return request(service+'/register','POST',JSON.stringify(payload),{'content-type':'application/json'});
}
function callBody(target,capability,args={}) { return JSON.stringify({to_node_id:target.node_id,capability,args,nonce:crypto.randomUUID()}); }
async function direct(target,author,capability,args={},to=target) {
  const body=callBody(to,capability,args);
  return request(target.url+'/node/call','POST',body,headers(author,'call',body));
}
async function stop(child) {
  if(child.exitCode !== null || child.signalCode !== null) return;
  const done=new Promise(r=>child.once('exit',r)); child.kill(); await done;
}
(async()=>{
  const admin=fixture('operator'), otherAdmin=fixture('other-operator'), guest=fixture('customer-a'), guestB=fixture('customer-b');
  const registry=fixture('registry'), registryPort=await freePair();
  const service=`http://127.0.0.1:${registryPort}`;
  registry.args=['rendezvous','--port',String(registryPort)];
  registry.admins={WASM_AGENT_NETWORK_ADMINS:`${admin.node_id},${otherAdmin.node_id}`};
  registry.child=start(registry,registry.args,registry.admins);
  await until(async()=> (await request(service+'/health')).status===200, 'registry');
  check((await register(service,admin)).status===200 && (await register(service,otherAdmin)).status===200,'configured administrators register');
  const descriptor=(await request(service+'/service')).value;
  check(descriptor.protocol===1 && descriptor.enrollment_ready && descriptor.operators.length===2,'managed service advertises exact admin identities');
  check((await register(service,guest,'master')).status===200,'customer registration accepted');
  const mine=await request(service+'/lookup?node_id='+guest.node_id,'GET',undefined,headers(guest,'lookup'));
  check(mine.value.role==='guest','claiming master does not elevate a customer');
  check((await request(service+'/nodes','GET',undefined,headers(guest,'nodes'))).status===403,'guest cannot enumerate customer inventory');
  check((await request(service+'/nodes')).status===400,'anonymous inventory request refused');
  const ts=now();
  check((await register(service,guest,'master',{node_id:admin.node_id,signature:signature(guest,`${admin.node_id}|${ts}`),ts})).status===401,'another key cannot overwrite operator identity');
  for(const node of [guest,guestB]) {
    node.port=await freePair(); node.url=`http://127.0.0.1:${node.port}`;
    node.env={...node.env,WASM_AGENT_MANAGED:'1',WASM_AGENT_RENDEZVOUS:service,WASM_AGENT_RELAY:service};
    const config=path.join(node.home,'.wasm-agent');
    fs.writeFileSync(path.join(config,'node.name'),node.name);
    node.profile={schema:1,active:true,local_role:'guest',expires_at:now()+3600,service,operators:[{node_id:admin.node_id,public_key:admin.public_key}]};
    fs.writeFileSync(path.join(config,'enrollment.json'),JSON.stringify(node.profile));
    node.args=['serve','--port',String(node.port),'--client-port',String(node.port+1),'--ui',path.join(root,'ui')];
    node.child=start(node,node.args);
    await until(async()=> (await request(node.url+'/health')).status===200,node.name+' server');
    await until(async()=> (await request(service+'/lookup?node_id='+node.node_id,'GET',undefined,headers(node,'lookup'))).status===200,node.name+' registration');
  }
  check(cli(guest,['access']).value.registered,'model-free guest confirms its own registration');
  const resultFile=path.join(guest.home,'effect.txt');
  const written=await direct(guest,admin,'write',{path:resultFile,content:'approved operator effect'});
  check(!written.value.error && fs.readFileSync(resultFile,'utf8')==='approved operator effect','pinned operator makes a real native file effect without a guest model');
  check((await direct(guest,otherAdmin,'read',{path:resultFile})).value.error==='unknown_caller','unrelated registered administrator cannot read customer files');
  check((await direct(guest,guestB,'read',{path:resultFile})).value.error==='unknown_caller','customer cannot access another customer');
  check((await direct(guest,admin,'write',{path:resultFile,content:'wrong customer'},guestB)).value.error==='wrong_target','signed request cannot be redirected to another customer');
  check(fs.readFileSync(resultFile,'utf8')==='approved operator effect','wrong-target refusal made no file change');
  check((await direct(guest,admin,'chat',{text:'do not invoke a model'})).value.error==='capability_not_granted','managed guest refuses local-model delegation');
  check((await request(guest.url+'/health','GET',undefined,{Origin:'https://foreign.example'})).status===403,'foreign browser origin refused');
  const rebinding=await new Promise((resolve,reject)=>{
    const req=require('node:http').get(guest.url+'/health',{headers:{Host:'foreign.example'}},res=>{res.resume();resolve(res.statusCode);});
    req.on('error',reject);
  });
  check(rebinding===403,'foreign Host rebinding refused');
  let body=JSON.stringify({node_id:guest.node_id,role:'master',nonce:crypto.randomUUID()});
  check((await request(service+'/role','POST',body,headers(guest,'grant-role',body))).status===403,'guest cannot grant itself a network role');
  check((await direct(guest,admin,'set_role',{role:'master'})).value.error==='network_role_not_granted','local promotion requires a registry grant');
  const grantBody=body, signedGrant=headers(admin,'grant-role',body);
  const changedBody=JSON.stringify({node_id:guestB.node_id,role:'master'});
  check((await request(service+'/role','POST',changedBody,signedGrant)).status===401,'promotion signature covers target and role');
  check((await request(service+'/role','POST',body,signedGrant)).status===200,'administrator grants network master role');
  check((await request(service+'/role','POST',body,signedGrant)).status===409,'role grant replay refused durably');
  check((await direct(guest,admin,'set_role',{role:'master'})).value.ok===true && cli(guest,['access']).value.role==='master','authorized local promotion works without restart');
  check((await register(service,guest,'guest')).status===200 && (await request(service+'/lookup?node_id='+guest.node_id,'GET',undefined,headers(guest,'lookup'))).value.role==='master','heartbeat cannot override administrator-granted role');
  const rid=crypto.randomUUID();
  const forbiddenEnvelope=JSON.stringify({rid,to:guest.node_id,method:'POST',path:'/shell',body:'ignored',headers:{}});
  const relayAnswer=await request(service+'/relay/send','POST',forbiddenEnvelope,headers(admin,'relay-send'));
  check(relayAnswer.value.status===403 && relayAnswer.value.body.includes('relay_route_forbidden'),'relay cannot bypass signed API even after promotion');
  check((await request(service+'/relay/send','POST',forbiddenEnvelope,headers(otherAdmin,'relay-send'))).status===409,'other sender cannot collect a known relay result ID');
  const changedEnvelope=JSON.stringify({...JSON.parse(forbiddenEnvelope),to:guestB.node_id});
  check((await request(service+'/relay/send','POST',changedEnvelope,headers(admin,'relay-send'))).status===409,'request ID cannot be reused for another customer');
  const retry=await request(service+'/relay/send','POST',forbiddenEnvelope,headers(admin,'relay-send'));
  check(retry.value.replayed===true && retry.value.status===403,'original caller may retrieve the same cached result repeatedly');
  body=JSON.stringify({id:rid,node_id:guestB.node_id,status:200,body:'forged result'});
  check((await request(service+'/relay/respond','POST',body,headers(guestB,'relay-respond'))).status===403,'unrelated customer cannot forge a relay result');
  admin.env.WASM_AGENT_RENDEZVOUS=service; admin.env.WASM_AGENT_RELAY=service;
  const demote=cli(admin,['network','role',guest.node_id,'guest']);
  check(demote.value.ok && cli(guest,['access']).value.role==='guest','operator CLI demotes registry and local role through outbound relay');
  const promote=cli(admin,['network','role',guest.node_id,'master']);
  check(promote.value.ok && cli(guest,['access']).value.role==='master','operator CLI promotes through outbound relay without a model');
  const audit=cli(guest,['access','log']).value.events;
  check(audit.some(e=>e.caller===admin.node_id && e.capability==='write' && e.state==='completed'),'local audit attributes completed tool execution to the operator ID');
  const replayBody=callBody(guest,'status'), replayHeaders=headers(admin,'call',replayBody);
  check(!(await request(guest.url+'/node/call','POST',replayBody,replayHeaders)).value.error,'fresh target-bound request accepted');
  await stop(guest.child); guest.child=start(guest,guest.args);
  await until(async()=> (await request(guest.url+'/health')).status===200,'active restart');
  check((await request(guest.url+'/node/call','POST',replayBody,replayHeaders)).value.error==='replayed_request','request replay stays refused after recipient restart');
  await stop(registry.child); registry.child=start(registry,registry.args,registry.admins);
  await until(async()=> (await request(service+'/health')).status===200,'registry restart');
  check((await request(service+'/role','POST',grantBody,signedGrant)).status===409,'role grant replay stays refused after registry restart');
  if (process.argv[3]) {
    const archive=path.resolve(process.argv[3]);
    const descriptorPath=path.join(work,'release.json');
    const localRelease={schema:1,available:true,package_url:require('node:url').pathToFileURL(archive).href,
      sha256:hash(fs.readFileSync(archive)),service,operators:[{node_id:admin.node_id,public_key:admin.public_key}]};
    fs.writeFileSync(descriptorPath,JSON.stringify(localRelease));
    const installed=path.join(work,'paste-once package'), nodeHome=path.join(work,'paste-once home');
    const psArgs=['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(root,'scripts/bootstrap-windows.ps1'),
      '-ManifestPath',descriptorPath,'-Name','pasted-node','-InstallDir',installed,'-NodeHome',nodeHome,'-AcceptAccess','-NoRegisterCommand'];
    let boot;
    try { boot=spawnSync('powershell',psArgs,{env:clean,encoding:'utf8',timeout:180000,windowsHide:true}); }
    finally {
      const launchers=path.join(nodeHome,'.wasm-agent','launchers');
      if(fs.existsSync(launchers)) for(const dir of fs.readdirSync(launchers)) for(const file of fs.readdirSync(path.join(launchers,dir))) {
        if(file.endsWith('.pid')) externalPids.push(Number(fs.readFileSync(path.join(launchers,dir,file),'utf8')));
      }
    }
    if(boot.error || boot.status!==0) throw new Error('bootstrap: '+(boot.error || boot.stdout+'\n'+boot.stderr));
    check(boot.stdout.includes('CONNECTED as guest'),'paste-once bootstrap installs extracted package and verifies guest registration');
    const node={home:nodeHome,env:{...clean,WASM_AGENT_HOME:nodeHome}};
    Object.assign(node,cli(node,['node']).value);
    const profile=JSON.parse(fs.readFileSync(path.join(nodeHome,'.wasm-agent/enrollment.json'),'utf8'));
    node.url=`http://127.0.0.1:${profile.port}`;
    const file=path.join(nodeHome,'bootstrap-effect.txt');
    check(!(await direct(node,admin,'write',{path:file,content:'packaged bootstrap effect'})).value.error && fs.readFileSync(file,'utf8')==='packaged bootstrap effect','bootstrapped package accepts authorized tool effect with no model');
    check(fs.readFileSync(path.join(nodeHome,'.wasm-agent/node.name'),'utf8').trim()==='pasted-node','name prompt becomes the actual node name');
    check(!fs.readFileSync(path.join(nodeHome,'.wasm-agent/env'),'utf8').includes('API_KEY'),'fresh customer configuration contains no provider credentials');
    const packagedCommand=path.join(installed,'scripts/first-run.ps1');
    const disconnect=spawnSync('powershell',['-NoProfile','-ExecutionPolicy','Bypass','-File',packagedCommand,'disconnect'],{env:node.env,encoding:'utf8',timeout:30000,windowsHide:true});
    check(disconnect.status===0 && (await direct(node,admin,'read',{path:file})).value.error==='unknown_caller','packaged disconnect revokes live access without killing another process');
    const reconnect=spawnSync('powershell',['-NoProfile','-ExecutionPolicy','Bypass','-File',packagedCommand,'connect','-AcceptAccess'],{env:node.env,encoding:'utf8',timeout:60000,windowsHide:true});
    if(reconnect.status!==0) throw new Error('reconnect: '+reconnect.stdout+reconnect.stderr);
    check(!(await direct(node,admin,'read',{path:file})).value.error,'packaged connect renews explicit consent and reuses its own server');
    fs.writeFileSync(descriptorPath,JSON.stringify({...localRelease,sha256:'0'.repeat(64)}));
    const badInstall=path.join(work,'bad checksum install');
    const bad=spawnSync('powershell',[...psArgs.slice(0,psArgs.indexOf('-InstallDir')),'-InstallDir',badInstall,'-NodeHome',path.join(work,'bad checksum home'),'-AcceptAccess','-NoRegisterCommand'],{env:clean,encoding:'utf8',timeout:60000,windowsHide:true});
    check(bad.status!==0 && !fs.existsSync(badInstall),'bootstrap refuses checksum mismatch before running packaged code');
  }
  guest.profile.active=false;
  fs.writeFileSync(path.join(guest.home,'.wasm-agent/enrollment.json'),JSON.stringify(guest.profile));
  check((await direct(guest,admin,'write',{path:resultFile,content:'after revoke'})).value.error==='unknown_caller','local revocation blocks queued/future authority');
  await stop(guest.child); guest.child=start(guest,guest.args);
  await until(async()=> (await request(guest.url+'/health')).status===200,'restart');
  check((await direct(guest,admin,'read',{path:resultFile})).value.error==='unknown_caller','revocation survives restart');
  guest.profile.active=true; guest.profile.expires_at=now()-1;
  fs.writeFileSync(path.join(guest.home,'.wasm-agent/enrollment.json'),JSON.stringify(guest.profile));
  check(cli(guest,['access']).value.error==='access_expired' && (await direct(guest,admin,'read',{path:resultFile})).value.error==='unknown_caller','expired consent fails closed');
  check(fs.readFileSync(resultFile,'utf8')==='approved operator effect','denied operations caused no silent file changes');
  guest.profile.expires_at=now()+3600;
  fs.writeFileSync(path.join(guest.home,'.wasm-agent/enrollment.json'),JSON.stringify(guest.profile));
  await stop(registry.child); registry.child=start(registry,registry.args,{WASM_AGENT_NETWORK_ADMINS:otherAdmin.node_id});
  await until(async()=> (await request(service+'/health')).status===200,'administrator revocation');
  check((await direct(guest,admin,'read',{path:resultFile})).value.error==='unknown_caller','removing an administrator at the service revokes its pinned guest access');
  console.log(`managed network ok (${checks} checks, 0 skips; isolated service only)`);
})().catch(error=>{console.error(error.stack);process.exitCode=1;}).finally(async()=>{
  await Promise.all(children.map(stop));
  for(const pid of externalPids) { try { process.kill(pid); } catch {} }
  if(externalPids.length) await sleep(1000);
  if(process.exitCode) console.error('Fixture logs retained at '+work);
  else fs.rmSync(work,{recursive:true,force:true});
});
