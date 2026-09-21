// Real-process recovery proof, confined to fresh homes, ports, profiles and owned PIDs.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {spawn,spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-recovery-proof-'));
const wa=path.resolve(process.argv[2]||path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
const sentinel=path.resolve(process.argv[3]||path.join(repo,'rust/wa-sentinel/target/release',process.platform==='win32'?'wa-sentinel.exe':'wa-sentinel'));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));const children=[];let nodePort;let installed;let checks=0;
function check(value,label){assert.ok(value,label);checks++;}
async function until(f,label,ms=12000){let end=Date.now()+ms;while(Date.now()<end){if(await f())return;await sleep(50)}throw Error('timeout: '+label)}
function cli(env,...args){const r=spawnSync(sentinel,args,{env,encoding:'utf8',timeout:10000,windowsHide:true});assert.equal(r.status,0,r.stderr||r.error?.message);return r.stdout;}
async function main(){
 const listener=http.createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));nodePort=listener.address().port;await new Promise(r=>listener.close(r));
 const install=path.join(root,'install');fs.mkdirSync(install);installed=path.join(install,process.platform==='win32'?'wa.exe':'wa');fs.copyFileSync(wa,installed);fs.chmodSync(installed,0o755);
 const env={...process.env,WASM_AGENT_HOME:root,WASM_AGENT_NODE_KEY:path.join(root,'node.key'),WASM_AGENT_NODE_NAME:'recovery-proof',WA_INSTALL_DIR:install,WA_UI_DIR:path.join(repo,'ui'),WASM_AGENT_PORT:String(nodePort),WASM_AGENT_CLIENT_PORT:'0',WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_MANAGED:'0',WA_SENTINEL_SCRIPTS:root};delete env.WA_SCRIPT;delete env.WASM_AGENT_LUA_ROOT;
 // Crash containment is a Windows Job Object guarantee; POSIX groups do not claim it.
 if(process.platform==='win32'){
  const script=path.join(root,'crash.lua');const marker=path.join(root,'escaped-after-crash');
  const command='printf ready; sleep 1; printf escaped > "'+marker.replaceAll('\\','/')+'"';
  fs.writeFileSync(script,`local json=dofile('lua/vendor/json.lua')\nlocal r=json.decode(host.operation('start',json.encode({command=${JSON.stringify(command)},timeout_seconds=30})))\nfor i=1,200 do local s=json.decode(host.operation('status',json.encode({id=r.operation_id}))); if (s.output_bytes or 0)>0 then print('CHILD_READY'); io.stdout:flush(); break end; host.sleep(5) end\nhost.sleep(10000)\n`);
  const parent=spawn(wa,['--db',path.join(root,'crash.db')],{env:{...env,WA_SCRIPT:script},windowsHide:true,stdio:['ignore','pipe','pipe']});children.push(parent);let text='';parent.stdout.on('data',d=>text+=d);parent.stderr.on('data',d=>text+=d);
  await until(()=>text.includes('CHILD_READY'),'real operation running before crash');parent.kill();await new Promise(r=>parent.once('exit',r));await sleep(1300);check(!fs.existsSync(marker),'host death closes the Job Object and kills its descendants');
 }
 const mock=spawn(process.execPath,['-e',`require('http').createServer((q,s)=>{s.setHeader('content-type','application/json');s.end(JSON.stringify({ok:true,current:{label:'POST /chat',ms:999999}}))}).listen(${nodePort},'127.0.0.1')`],{env,stdio:'ignore',windowsHide:true});children.push(mock);
 const base=`http://127.0.0.1:${nodePort}`;await until(async()=>{try{return (await fetch(base+'/health')).ok}catch{return false}},'busy mock listener');
 const log=fs.openSync(path.join(root,'sentinel.log'),'a');const watcher=spawn(sentinel,['watch'],{env,stdio:['ignore',log,log],windowsHide:true});children.push(watcher);
 cli(env,'request','restart','--reason','fixture graceful restart');await sleep(500);
 const requests=path.join(root,'.wasm-agent/sentinel/requests');check(fs.readdirSync(requests).some(f=>f.endsWith('.json')),'graceful restart stays queued while busy');check(mock.exitCode===null,'graceful restart does not kill healthy busy work');
 const started=Date.now();cli(env,'request','recover','--reason','fixture non-cooperative recovery');
 await until(async()=>{try{return (await (await fetch(base+'/health')).json()).exec_timeout_seconds!==undefined}catch{return false}},'recovery replaced busy fixture');
 check(Date.now()-started<8000,'recovery acts without the 900-second idle wait');check(mock.exitCode!==null||mock.signalCode!==null,'only the owned busy listener was terminated');
 // Wait for the formerly deferred maintenance request to settle before cancelling a job.
 await until(()=>fs.readdirSync(requests).filter(f=>f.endsWith('.json')).length===0,'maintenance queue drained');await sleep(500);
 const procedure=path.join(root,'long.sh');fs.writeFileSync(procedure,'#!/bin/sh\nprintf active\nsleep 30\n');
 const definition=path.join(root,'long.json');fs.writeFileSync(definition,JSON.stringify({id:'long',name:'long',trigger:{kind:'event',topic:'fixture.long'},action:{kind:'run',script:procedure,timeout_seconds:40}}));
 cli(env,'job','put',definition);cli(env,'job','enable','long');const payload=path.join(root,'event.json');fs.writeFileSync(payload,'{}');cli(env,'job','emit','fixture.long','one',payload);
 await until(()=>JSON.parse(cli(env,'job','history')).some(d=>d.job_id==='long'&&d.state==='running'),'long deterministic action started');
 const disabled=Date.now();cli(env,'job','disable','long');
 await until(()=>JSON.parse(cli(env,'job','history')).some(d=>d.job_id==='long'&&d.state!=='running'&&d.state!=='queued'),'disable cancels admitted script');
 check(Date.now()-disabled<3000,'a long action does not hold the watcher or cancellation');
 console.log(`recovery ok (${checks} checks; only isolated fixture PIDs)\nevidence: ${root}`);
}
async function cleanup(){
 // Stop our watcher before resolving the replacement listener so it cannot restart it.
 for(const p of children.reverse()){if(p.exitCode===null&&p.signalCode===null){p.kill();await Promise.race([new Promise(r=>p.once('exit',r)),sleep(2000)]);}}
 if(nodePort&&installed){
  if(process.platform==='win32'){
   const script=`$p=Get-NetTCPConnection -State Listen -LocalPort ${nodePort} -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty OwningProcess; if($p){$x=Get-CimInstance Win32_Process -Filter "ProcessId=$p"; if($x.ExecutablePath -eq '${installed.replaceAll("'","''")}'){Stop-Process -Id $p -ErrorAction Stop}}`;
   spawnSync('powershell.exe',['-NoProfile','-Command',script],{timeout:10000,windowsHide:true});
  }else{
   const r=spawnSync('ss',['-ltnp'],{encoding:'utf8'});const line=r.stdout?.split('\n').find(l=>l.includes(':'+nodePort+' '));const pid=line?.match(/pid=(\d+)/)?.[1];if(pid){try{if(fs.realpathSync('/proc/'+pid+'/exe')===installed)process.kill(Number(pid))}catch{}}
  }
 }
}
(async()=>{try{await main()}catch(e){console.error(e.stack);console.error('evidence: '+root);process.exitCode=1}finally{await cleanup()}})();
