// Actual private installer, native watcher and source-root Lua. Only inference is a labelled local mock.
const fs=require('fs'),path=require('path'),os=require('os'),http=require('http'),net=require('net'),assert=require('assert/strict');
const {spawn,spawnSync}=require('child_process');
const {pathToFileURL}=require('url');
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
function cli(...argv){const r=spawnSync(path.join(install,'wa-sentinel.exe'),argv,{cwd:source,env:privateEnv,encoding:'utf8',windowsHide:true,timeout:argv[0]==='protocol'&&argv[1]==='reconcile'?120000:30000});save('cli-'+(++sequence)+'.json',{argv,pid:r.pid,status:r.status,stdout:r.stdout,stderr:r.stderr});assert.equal(r.status,0,r.stderr);return r.stdout;}
async function gone(pid){await until(()=>{try{process.kill(pid,0);return false;}catch{return true;}},'owned pid did not exit '+pid,15000);}
(async()=>{try{
 // Source is a full clone with an actual private remote main, never fake upstream on a live checkout.
 const proof=await import(pathToFileURL(path.join(source,'scripts/sentinel-install-proof.mjs')).href);
 const verifyActual=(...a)=>proof.verifyActual(...a,privateEnv);
 assert.equal(proof.sourceIdentity(source,packet.head).tree,packet.tree);
 if(args.includes('--build-cache')) {
  const cache=fs.realpathSync(args[args.indexOf('--build-cache')+1]);
  assert(cache.startsWith(fs.realpathSync(os.tmpdir())+path.sep)&&path.basename(cache)==='source','explicit prior private source cache only');
  const prior=path.dirname(cache);
  for(const name of ['source-host-build','source-sentinel-build'])assert.equal(JSON.parse(fs.readFileSync(path.join(prior,name+'.receipt.json'))).code,0,'prior actual source build required');
  for(const relative of ['rust/target','rust/wa-sentinel/target'])fs.cpSync(path.join(cache,relative),path.join(source,relative),{recursive:true,preserveTimestamps:true,errorOnExist:true,force:false});
  save('build-cache.json',{source:cache,read_only:true,cargo_builds_still_required:true,installation_proof_reused:false});
 }
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
 await until(()=>fs.existsSync(path.join(dir,'effect.json')),'actual effect admission');
 const busyDuringUpdate=api('/chat',{text:'hold private parent',thread:session.id});await until(()=>!!releaseBusy,'actual parent busy during installation');
 const noticesBefore=notices.length;
 // Wait for the actual durable clock, not an assumed 12s scheduling window.
 // Cold native owner reads/filesystem work may delay observation on Windows.
 await until(()=>{try{const c=JSON.parse(fs.readFileSync(path.join(dir,'check.json')));return c.due_at!==undefined&&c.at>=c.due_at;}catch{return false;}},'actual durable updating check',60000);
 assert.equal(notices.length,noticesBefore,'updating return coalesced while real parent busy');
 const check=JSON.parse(fs.readFileSync(path.join(dir,'check.json')));
 assert(check.at>=check.due_at&&check.due_at>=request.queued_at+10,'actual ten-second check observed while busy');
 save('actual-updating-busy-check.json',check);
 releaseBusy();releaseBusy=null;await busyDuringUpdate;
 await until(()=>fs.existsSync(path.join(dir,'result.json')),'actual installer terminal result',600000);
 const result=JSON.parse(fs.readFileSync(path.join(dir,'result.json')));assert.equal(result.ok,true,JSON.stringify(result));assert.equal(result.request_id,request.id);
 const actual=verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir);
 assert.equal(actual.failed,0);assert.equal(actual.skipped,0);
 await until(()=>notices.some(n=>n.includes('phase "verified"')),'actual Lua verified terminal return',180000);
 const terminal=notices.filter(n=>n.includes('phase "verified"'));assert.equal(terminal.length,1);
 assert(!fs.readdirSync(path.join(box,'requests')).some(n=>{try{return JSON.parse(fs.readFileSync(path.join(box,'requests',n))).verb==='wake';}catch{return false;}}),'no legacy wake plus hook');
 const listener=proof.processIdentity(Number(fs.readFileSync(path.join(install,'serve.pid')))),watcher=proof.processIdentity(Number(fs.readFileSync(path.join(box,'sentinel.pid'))));
 assert.notEqual(listener.created,originalNode.created);assert.notEqual(watcher.created,originalWatcher.created);save('native-after.json',{listener,watcher,health:await api('/health')});
 const transcript=await api('/session?id='+session.id);save('actual-parent-transcript.json',transcript);assert(JSON.stringify(transcript.messages).includes('I am updated'));
 let admissionNegatives=0,negativeCount=0;
 const reconciliationOnly=args.includes('--reconciliation-only');
 if(!reconciliationOnly) {
 for(const [name,owner,sha,problem] of [['owner','wrong-owner',packet.head,'parent_owner_mismatch'],['source',session.user_id,'b'.repeat(40),'canonical source']]) {
  const prior=new Set(fs.readdirSync(path.join(box,'deploy-protocol')));
  cli('request','deploy','--expected-sha',sha,'--owner',owner,'--session',session.id,'--reason','private admission negative '+name);
  let negative;
  await until(()=>{negative=fs.readdirSync(path.join(box,'deploy-protocol')).find(id=>!prior.has(id));return !!negative;},'negative request identity');
  const evidence=path.join(box,'deploy-protocol',negative);
  await until(()=>fs.existsSync(path.join(evidence,'ack.json')),'negative acknowledgement',5000);
  await until(()=>fs.existsSync(path.join(box,'failed',negative+'.json')),'named admission failure');
  const failure=JSON.parse(fs.readFileSync(path.join(box,'failed',negative+'.json')));
  assert(failure.detail.includes(problem),failure.detail);assert(!fs.existsSync(path.join(evidence,'effect.json')),'negative did not reserve an effect');
  save('admission-negative-'+name+'.json',{id:negative,failure,actual_effect_reserved:false});admissionNegatives++;
 }
 // Actual verifier negatives preserve each failing raw receipt; every altered file is restored exactly.
 const installedFile=path.join(install,'installed.txt'),installedBytes=fs.readFileSync(installedFile),resultFile=path.join(dir,'result.json'),resultBytes=fs.readFileSync(resultFile);
 for(const [name,mutate,restore] of [
  ['request',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,request_id:'wrong-request'})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['future',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,at:new Date(Date.now()+600000).toISOString()})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['stale',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,at:new Date(1000).toISOString()})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['missing',()=>fs.writeFileSync(resultFile,JSON.stringify({...result,at:undefined})),()=>fs.writeFileSync(resultFile,resultBytes)],
  ['partial',()=>fs.writeFileSync(installedFile,installedBytes.toString().replace('record_role=final','record_role=interim')),()=>fs.writeFileSync(installedFile,installedBytes)],
  ['source',()=>fs.writeFileSync(installedFile,installedBytes.toString().replace('resolved_commit='+packet.head,'resolved_commit='+'b'.repeat(40))),()=>fs.writeFileSync(installedFile,installedBytes)],
 ]) {try{mutate();assert.throws(()=>verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir),undefined,name);negativeCount++;}finally{restore();}}
 const uiFile=path.join(install,'ui/index.html'),uiBytes=fs.readFileSync(uiFile);try{fs.appendFileSync(uiFile,'\nprivate hash negative');assert.throws(()=>verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir),/ui_mismatch/);negativeCount++;}finally{fs.writeFileSync(uiFile,uiBytes);}
 const binding=JSON.parse(fs.readFileSync(path.join(dir,'binding.json')));
 assert.throws(()=>verifyActual(source,install,request,{...binding,owner:'wrong-owner'},dir),/binding_mismatch/);negativeCount++;
 const artifactBytes=fs.readFileSync(binary);try{fs.appendFileSync(binary,'private source artifact hash negative');assert.throws(()=>verifyActual(source,install,request,binding,dir),/built_artifact_mismatch/);negativeCount++;}finally{fs.writeFileSync(binary,artifactBytes);}
 // Remove only the causal request comparison in a private copy; the actual bad outcome now passes.
 const originalHelper=fs.readFileSync(path.join(source,'scripts/sentinel-install-proof.mjs'),'utf8');
 const mutantFile=path.join(base,'causal-check-removed.mjs');
 assert(originalHelper.includes('result?.request_id!==intent.id||'));
 fs.writeFileSync(mutantFile,originalHelper.replace('result?.request_id!==intent.id||',''));
 const mutant=await import(pathToFileURL(mutantFile).href);
 try{fs.writeFileSync(resultFile,JSON.stringify({...result,request_id:'wrong-request'}));assert.equal(mutant.verifyActual(source,install,request,binding,dir,privateEnv).ok,true,'removed causal check must admit the actual wrong request');negativeCount++;save('causal-removal.json',{red:true,actual_wrong_request:'wrong-request',original_refused:true,mutant_admitted:true});}finally{fs.writeFileSync(resultFile,resultBytes);}
 }
 const installedFile=path.join(install,'installed.txt'),resultFile=path.join(dir,'result.json'),resultBytes=fs.readFileSync(resultFile);
 const clean=verifyActual(source,install,request,JSON.parse(fs.readFileSync(path.join(dir,'binding.json'))),dir);assert.equal(clean.ok,true);
 // Recovery after a consumed terminal failure uses the real native verifier, not
 // cursor deletion or a second installation. Original immutable return survives.
 cli('job','disable','onSentinelReturn');
 await until(async()=>{const h=await api('/health');return h.current===null&&h.runs.length===0;},'parent drained for reconciliation');
 const activeFile=path.join(box,'protocol-effect.json'),effectBytes=fs.readFileSync(path.join(dir,'effect.json')),effect=JSON.parse(effectBytes);
 fs.writeFileSync(activeFile,JSON.stringify(effect));
 const cursorFile=path.join(dir,'observation.json'),originalCursor=fs.readFileSync(cursorFile);
 const failureFile=path.join(dir,'returns','private-reconciled-failure.json'),failureBytes=Buffer.from(JSON.stringify({id:request.id,phase:'failed',detail:'private already-recovered finalization',at:Math.floor(Date.now()/1000)}));
 fs.writeFileSync(failureFile,failureBytes);fs.writeFileSync(cursorFile,JSON.stringify({slot:99,next_at:Number.MAX_SAFE_INTEGER,last_event:'private-reconciled-failure'}));
 const terminalCursor=fs.readFileSync(cursorFile),beforeRecovery=proof.snapshot(source,install,undefined,privateEnv);
 const negativeCli=(label,env=privateEnv)=>{const r=spawnSync(path.join(install,'wa-sentinel.exe'),['protocol','reconcile',request.id,'--reason','private explicit verification-only recovery'],{cwd:source,env,encoding:'utf8',windowsHide:true,timeout:120000});save('reconcile-negative-'+label+'.json',{status:r.status,stdout:r.stdout,stderr:r.stderr});assert.notEqual(r.status,0,label);assert.deepEqual(fs.readFileSync(activeFile),Buffer.from(JSON.stringify(effect)),'negative cannot settle reservation');};
 negativeCli('in-turn',{...privateEnv,WASM_AGENT_IN_TURN:'1'});
 try{fs.writeFileSync(resultFile,JSON.stringify({...result,request_id:'wrong-reconciliation-request'}));negativeCli('wrong-result');}finally{fs.writeFileSync(resultFile,resultBytes);}
 const settled=JSON.parse(cli('protocol','reconcile',request.id,'--reason','private recovered finalization observed end to end'));
 assert(settled.ok&&settled.reservation==='verified'&&settled.effect_replayed===false&&settled.original_returns_preserved);
 assert.equal(JSON.parse(fs.readFileSync(activeFile)).phase,'verified');
 assert.deepEqual(fs.readFileSync(cursorFile),terminalCursor);assert.deepEqual(fs.readFileSync(failureFile),failureBytes);
 const afterRecovery=proof.snapshot(source,install,undefined,privateEnv);
 assert.equal(afterRecovery.listener_created,beforeRecovery.listener_created);assert.equal(afterRecovery.watcher_created,beforeRecovery.watcher_created);
 assert.equal(afterRecovery.node_sha256,beforeRecovery.node_sha256);assert.equal(afterRecovery.sentinel_sha256,beforeRecovery.sentinel_sha256);
 assert.deepEqual(fs.readFileSync(path.join(dir,'effect.json')),effectBytes);
 const repeated=JSON.parse(cli('protocol','reconcile',request.id,'--reason','private idempotent re-verification, no second effect'));
 assert(repeated.ok&&repeated.effect_replayed===false);
 save('reconciliation-e2e.json',{ok:true,native_actual_verifier:true,terminal_cursor_preserved:true,failed_return_preserved:true,processes_unchanged:true,effect_replayed:false});
 // Leave the fixture's original observation evidence intact for later inspection.
 fs.writeFileSync(cursorFile,originalCursor);fs.unlinkSync(failureFile);
 const recoveryChecks=8;
 save('result.json',{ok:true,request_id:request.id,head:packet.head,tree:packet.tree,ack_ms:ackMs,checks:10+negativeCount+admissionNegatives+recoveryChecks,skipped:0,paid_calls:0,actual_installer:true,actual_verifier:true,actual_reconciliation:true,scope:reconciliationOnly?'installation and reconciliation only':'installation negatives and reconciliation',private_source:source,notices:terminal.length});
 console.log(`sentinel private install ok (${10+negativeCount+admissionNegatives+recoveryChecks} checks, 0 skipped)`);
 }finally{
  if(releaseBusy)releaseBusy();
  if(fs.existsSync(path.join(box,'sentinel.pid'))){const pid=Number(fs.readFileSync(path.join(box,'sentinel.pid')));fs.writeFileSync(path.join(box,'stop'),'owned private fixture cleanup');await gone(pid);}
  if(fs.existsSync(path.join(install,'serve.pid'))){const pid=Number(fs.readFileSync(path.join(install,'serve.pid')));const {processIdentity}=await import(pathToFileURL(path.join(source,'scripts/sentinel-install-proof.mjs')).href);try{const identity=processIdentity(pid);assert.equal(fs.realpathSync(identity.image).toLowerCase(),fs.realpathSync(path.join(install,'wa.exe')).toLowerCase());process.kill(pid);await gone(pid);}catch(e){if(e.code!=='ESRCH'&&!String(e).includes('Cannot find a process'))throw e;}}
  if(node&&node.exitCode===null){node.kill();await gone(node.pid);}if(watch&&watch.exitCode===null){watch.kill();await gone(watch.pid);}
  if(mock){mock.closeAllConnections();await new Promise(r=>mock.close(r));}
  console.log('immutable private evidence: '+base);
 }
})().catch(error=>{save('failure.json',{error:error.stack});console.error(error);process.exitCode=1;});
