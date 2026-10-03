// Actual private installer, native watcher and source-root Lua. Only inference is a labelled local mock.
const fs=require('fs'),path=require('path'),os=require('os'),http=require('http'),net=require('net'),assert=require('assert/strict');
const {spawn,spawnSync}=require('child_process');
const repo=path.resolve(__dirname,'..');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const args=process.argv.slice(2);
assert.notEqual(process.env.WASM_AGENT_IN_TURN,'1','outside WA execution required; never remove a production marker');
assert.equal(process.platform,'win32','this fixture requires the enclosing native Windows Job');
let packetFile=args[args.indexOf('--packet')+1];
if(!args.includes('--packet')){
 const head=spawnSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).stdout.trim();
 const packet=path.join(os.tmpdir(),'wa-private-install-'+Date.now()+'-'+process.pid);
 const r=spawnSync('python',[path.join(repo,'scripts/prepare-sentinel-private-install.py'),'--repo',repo,'--head',head,'--packet',packet],{encoding:'utf8',windowsHide:true});
 assert.equal(r.status,0,r.stderr);packetFile=path.join(packet,'packet.json');
}
const packet=JSON.parse(fs.readFileSync(packetFile));
const base=path.dirname(path.resolve(packetFile));
for(const field of ['source','private_remote','home','install'])assert(path.resolve(packet[field]).startsWith(base+path.sep),'isolated '+field);
const source=packet.source,home=packet.home,install=packet.install,box=path.join(home,'.wasm-agent/sentinel');
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>['PATH','SYSTEMROOT','WINDIR','COMSPEC','TEMP','TMP','PATHEXT','SYSTEMDRIVE','CARGO_HOME','RUSTUP_HOME','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','USERPROFILE','APPDATA','LOCALAPPDATA'].includes(k.toUpperCase())));
let privateEnv={...env,...packet.environment,WASM_AGENT_LUA_ROOT:source,WASM_AGENT_CLIENT_PORT:packet.environment.WA_CLIENT_PORT,WA_SENTINEL_WAKE_BUDGET:'100',TMPDIR:base.replaceAll('\\','/')};
const binary=path.join(source,'rust/target/release/wa.exe'),sentinel=path.join(source,'rust/wa-sentinel/target/release/wa-sentinel.exe');
let mock,node,watch,releaseBusy,notices=[],sequence=0;
const url='http://127.0.0.1:'+privateEnv.WA_PORT;
function save(name,value){fs.writeFileSync(path.join(base,name),JSON.stringify(value,null,2));}
async function until(fn,label,ms=180000){const started=Date.now();while(Date.now()-started<ms){if(await fn())return;await sleep(100);}throw Error(label);}
async function run(program,argv,name){const out=fs.openSync(path.join(base,name+'.stdout'),'wx'),err=fs.openSync(path.join(base,name+'.stderr'),'wx');const child=spawn(program,argv,{cwd:source,env:privateEnv,windowsHide:true,stdio:['ignore',out,err]});const receipt=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({pid:child.pid,code,signal}));});fs.closeSync(out);fs.closeSync(err);save(name+'.receipt.json',receipt);assert.equal(receipt.code,0,name+' failed; inspect retained stdout/stderr');return receipt;}
async function api(route,body){const r=await fetch(url+route,{...(body?{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(120000)});assert(r.ok,route+' HTTP '+r.status);return r.json();}
function cli(...argv){const r=spawnSync(path.join(install,'wa-sentinel.exe'),argv,{cwd:source,env:privateEnv,encoding:'utf8',windowsHide:true,timeout:30000});save('cli-'+(++sequence)+'.json',{argv,pid:r.pid,status:r.status,stdout:r.stdout,stderr:r.stderr});assert.equal(r.status,0,r.stderr);return r.stdout;}
async function gone(pid){await until(()=>{try{process.kill(pid,0);return false;}catch{return true;}},'owned pid did not exit '+pid,15000);}
(async()=>{try{
 // Source is a full clone with an actual private remote main, never fake upstream on a live checkout.
 const proof=await import(path.join(source,'scripts/sentinel-install-proof.mjs'));
 assert.equal(proof.sourceIdentity(source,packet.head).tree,packet.tree);
 await run('cargo',['build','--release','--offline','--manifest-path','rust/Cargo.toml','-p','wa-host'],'source-host-build');
 await run('cargo',['build','--release','--offline','--manifest-path','rust/wa-sentinel/Cargo.toml'],'source-sentinel-build');
 fs.copyFileSync(binary,path.join(install,'wa.exe'));fs.copyFileSync(sentinel,path.join(install,'wa-sentinel.exe'));
 fs.writeFileSync(path.join(install,'runtime-worktree.txt'),source+'\n');
 mock=http.createServer((req,res)=>{let raw='';req.on('data',c=>raw+=c);req.on('end',()=>{const b=JSON.parse(raw),last=String(b.messages.filter(m=>m.role==='user').at(-1)?.content||'');const answer=()=>{if(res.writableEnded)return;if(last.includes('[onSentinelReturn]')){notices.push(last);save('mock-inference-notices.json',notices);}const message={role:'assistant',content:'private Lua parent consumed'},usage={prompt_tokens:1,completion_tokens:1,total_tokens:2};if(b.stream){res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: '+JSON.stringify({choices:[{delta:message,finish_reason:'stop'}],usage})+'\n\ndata: [DONE]\n\n');}else{res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({choices:[{message,finish_reason:'stop'}],usage}));}};if(last==='hold private parent')releaseBusy=answer;else answer();});});
 await new Promise(r=>mock.listen(0,'127.0.0.1',r));
 Object.assign(privateEnv,{WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:'+mock.address().port,WASM_AGENT_LLM_MODEL:'labelled-local-mock',WASM_AGENT_LLM_API_KEY:'fixture-not-a-credential'});
 save('environment.json',{...privateEnv,PATH:'retained system toolchain path',paid_calls:0,mocked_services:['local inference only']});
 const out=fs.openSync(path.join(base,'bootstrap-node.stdout'),'wx'),err=fs.openSync(path.join(base,'bootstrap-node.stderr'),'wx');
 node=spawn(path.join(install,'wa.exe'),['serve','--port',privateEnv.WA_PORT,'--client-port',privateEnv.WA_CLIENT_PORT,'--ui',path.join(source,'ui')],{cwd:source,env:privateEnv,windowsHide:true,stdio:['ignore',out,err]});
 fs.writeFileSync(path.join(install,'serve.pid'),String(node.pid));
 await until(async()=>{try{return(await api('/health')).ok===true;}catch{return false;}},'private initial node');
 await api('/chat',{text:'seed actual private parent',thread:'private-install-parent'});
 const session=(await api('/session?id=private-install-parent')).session;assert.equal(session.id,'private-install-parent');assert(session.user_id);
 const def=JSON.parse(fs.readFileSync(path.join(source,'jobs/on-sentinel-return.json'),'utf8').replaceAll('PREPARED_BY_INSTALL',install.replaceAll('\\','/')));
 const jobfile=path.join(base,'actual-hook.json');save('actual-hook.json',def);cli('job','put',jobfile);cli('job','enable','onSentinelReturn');
 const watchLog=fs.openSync(path.join(base,'bootstrap-watcher.stdout'),'wx');watch=spawn(path.join(install,'wa-sentinel.exe'),['watch'],{cwd:source,env:privateEnv,windowsHide:true,stdio:['ignore',watchLog,watchLog]});
 await until(()=>fs.existsSync(path.join(box,'sentinel.pid')),'private watcher ready');
 const originalWatcher=proof.processIdentity(watch.pid),originalNode=proof.processIdentity(node.pid);save('native-before.json',{originalWatcher,originalNode});
 const busy=api('/chat',{text:'hold private parent',thread:session.id});await until(()=>!!releaseBusy,'actual Lua busy parent');
 const began=Date.now();cli('request','deploy','--expected-sha',packet.head,'--owner',session.user_id,'--session',session.id,'--reason','actual private exact-source installation');
 const requests=fs.readdirSync(path.join(box,'requests')).filter(n=>n.endsWith('.json'));assert.equal(requests.length,1);
 const request=JSON.parse(fs.readFileSync(path.join(box,'requests',requests[0]))),dir=path.join(box,'deploy-protocol',request.id);
 await until(()=>fs.existsSync(path.join(dir,'ack.json')),'five-second durable watcher acknowledgement',5000);
 const ackMs=Date.now()-began;assert(ackMs<5000);assert.equal(notices.length,0,'busy parent cannot consume');assert(!fs.existsSync(path.join(dir,'effect.json')),'busy parent no effect');
 releaseBusy();releaseBusy=null;await busy;
 await until(()=>fs.existsSync(path.join(dir,'result.json')),'actual installer terminal result',600000);
 const result=JSON.parse(fs.readFileSync(path.join(dir,'result.json')));assert.equal(result.ok,true,JSON.stringify(result));assert.equal(result.request_id,request.id);
 const actual=proof.verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir);
 assert.equal(actual.failed,0);assert.equal(actual.skipped,0);
 await until(()=>notices.some(n=>n.includes('phase "verified"')),'actual Lua verified terminal return',180000);
 const terminal=notices.filter(n=>n.includes('phase "verified"'));assert.equal(terminal.length,1);
 assert(!fs.readdirSync(path.join(box,'requests')).some(n=>{try{return JSON.parse(fs.readFileSync(path.join(box,'requests',n))).verb==='wake';}catch{return false;}}),'no legacy wake plus hook');
 const listener=proof.processIdentity(Number(fs.readFileSync(path.join(install,'serve.pid')))),watcher=proof.processIdentity(Number(fs.readFileSync(path.join(box,'sentinel.pid'))));
 assert.notEqual(listener.created,originalNode.created);assert.notEqual(watcher.created,originalWatcher.created);save('native-after.json',{listener,watcher,health:await api('/health')});
 const transcript=await api('/session?id='+session.id);save('actual-parent-transcript.json',transcript);assert(JSON.stringify(transcript.messages).includes('I am updated'));
 // Actual verifier negatives preserve each failing raw receipt; every altered file is restored exactly.
 const installedFile=path.join(install,'installed.txt'),installedBytes=fs.readFileSync(installedFile),resultFile=path.join(dir,'result.json'),resultBytes=fs.readFileSync(resultFile);
 let negativeCount=0;
 for(const [name,mutate,restore] of [
  ['request',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,request_id:'wrong-request'})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['future',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,at:new Date(Date.now()+600000).toISOString()})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['stale',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,at:new Date(1000).toISOString()})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['missing',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,at:undefined})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['partial',()=>fs.writeFileSync(installedFile,installedBytes.toString().replace('record_role=final','record_role=interim')),()=>fs.writeFileSync(installedFile,installedBytes)],
  ['source',()=>fs.writeFileSync(installedFile,installedBytes.toString().replace('resolved_commit='+packet.head,'resolved_commit='+'b'.repeat(40))),()=>fs.writeFileSync(installedFile,installedBytes)],
 ]) {try{mutate();assert.throws(()=>proof.verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir),undefined,name);negativeCount++;}finally{restore();}}
 const uiFile=path.join(install,'ui/index.html'),uiBytes=fs.readFileSync(uiFile);try{fs.appendFileSync(uiFile,'\nprivate hash negative');assert.throws(()=>proof.verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir),/ui_mismatch/);negativeCount++;}finally{fs.writeFileSync(uiFile,uiBytes);}
 const binding=JSON.parse(fs.readFileSync(path.join(dir,'binding.json')));
 assert.throws(()=>proof.verifyActual(source,install,request,{...binding,owner:'wrong-owner'},dir),/binding_mismatch/);negativeCount++;
 const artifactBytes=fs.readFileSync(binary);try{fs.appendFileSync(binary,'private source artifact hash negative');assert.throws(()=>proof.verifyActual(source,install,request,binding,dir),/built_artifact_mismatch/);negativeCount++;}finally{fs.writeFileSync(binary,artifactBytes);}
 // Remove only the causal request comparison in a private copy; the actual bad outcome now passes.
 const originalHelper=fs.readFileSync(path.join(source,'scripts/sentinel-install-proof.mjs'),'utf8');
 const mutantFile=path.join(base,'causal-check-removed.mjs');
 assert(originalHelper.includes('result?.request_id!==intent.id||'));
 fs.writeFileSync(mutantFile,originalHelper.replace('result?.request_id!==intent.id||',''));
 const mutant=await import(mutantFile);
 try{fs.writeFileSync(resultFile,JSON.stringify({...result,request_id:'wrong-request'}));assert.equal(mutant.verifyActual(source,install,request,binding,dir).ok,true,'removed causal check must admit the actual wrong request');negativeCount++;save('causal-removal.json',{red:true,actual_wrong_request:'wrong-request',original_refused:true,mutant_admitted:true});}finally{fs.writeFileSync(resultFile,resultBytes);}
 const clean=proof.verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir);assert.equal(clean.ok,true);
 save('result.json',{ok:true,request_id:request.id,head:packet.head,tree:packet.tree,ack_ms:ackMs,checks:8+negativeCount,skipped:0,paid_calls:0,actual_installer:true,actual_verifier:true,private_source:source,notices:terminal.length});
 console.log(`sentinel private install ok (${8+negativeCount} checks, 0 skipped)`);
 }finally{
  if(releaseBusy)releaseBusy();
  if(fs.existsSync(path.join(box,'sentinel.pid'))){const pid=Number(fs.readFileSync(path.join(box,'sentinel.pid')));fs.writeFileSync(path.join(box,'stop'),'owned private fixture cleanup');await gone(pid);}
  if(fs.existsSync(path.join(install,'serve.pid'))){const pid=Number(fs.readFileSync(path.join(install,'serve.pid')));const {processIdentity}=await import(path.join(source,'scripts/sentinel-install-proof.mjs'));try{const identity=processIdentity(pid);assert.equal(fs.realpathSync(identity.image).toLowerCase(),fs.realpathSync(path.join(install,'wa.exe')).toLowerCase());process.kill(pid);await gone(pid);}catch(e){if(e.code!=='ESRCH'&&!String(e).includes('Cannot find a process'))throw e;}}
  if(node&&node.exitCode===null){node.kill();await gone(node.pid);}if(watch&&watch.exitCode===null){watch.kill();await gone(watch.pid);}
  if(mock){mock.closeAllConnections();await new Promise(r=>mock.close(r));}
  console.log('immutable private evidence: '+base);
 }
})().catch(error=>{save('failure.json',{error:error.stack});console.error(error);process.exitCode=1;});
