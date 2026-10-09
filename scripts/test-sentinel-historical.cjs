// Private historical verifier using real Git/files/native child identities; fake health only.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),http=require('node:http'),{spawn,spawnSync}=require('node:child_process'),{pathToFileURL}=require('node:url');
const out=process.argv[2],sentinelBinary=process.argv[3],bootstrap=process.argv[4]==='bootstrap';assert(out&&path.isAbsolute(out)&&!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const repo=path.join(out,'source'),install=path.join(out,'install'),home=path.join(out,'home'),evidence=path.join(out,'evidence');for(const p of [repo,install,home,evidence])fs.mkdirSync(p);fs.mkdirSync(home+'/.wasm-agent/sentinel',{recursive:true});
const hash=b=>crypto.createHash('sha256').update(b).digest('hex'),put=(p,b)=>{fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,b);};
function git(...a){const r=spawnSync('git',['-C',repo,...a],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
put(repo+'/scripts/deploy.sh','never install fixture\n');put(repo+'/scripts/upgrade.sh','UI_FILES="index.html"\n');put(repo+'/scripts/probe.js','exact historical script\n');put(repo+'/skills/fixture/SKILL.md','historical skill\n');put(repo+'/ui/index.html','historical ui\n');
git('init','-b','main');git('config','core.autocrlf','false');git('config','core.hooksPath',out+'/no-hooks');git('config','user.email','fixture@invalid');git('config','user.name','fixture');git('add','.');git('commit','-m','historical source');const sha=git('rev-parse','HEAD'),tree=git('rev-parse','HEAD^{tree}');git('remote','add','origin',repo);git('fetch','origin');
const native=process.platform==='win32'?'.exe':'';fs.copyFileSync(process.execPath,install+'/wa'+native);fs.copyFileSync(sentinelBinary||process.execPath,install+'/wa-sentinel'+native);
const node=spawn(install+'/wa'+native,['-e',`const http=require('http');let idle=false;process.on('message',()=>{idle=true;process.send('idle');});const s=http.createServer((q,r)=>r.end(JSON.stringify(q.url.startsWith('/session/owner')?{session:{id:'parent',user_id:'owner'}}:q.url.startsWith('/sync/head')?{node_id:'private-node',node:'private-node'}:{ok:true,busy:!idle,worker:idle?'alive':'busy',current:idle?null:{run:1},queue:0,operation_overdue:false,workers:[{state:idle?'alive':'busy'}],execution_schema:1,operations:[],subagents:{queued:0,running:0,active:0}})));s.listen(0,'127.0.0.1',()=>process.send(s.address().port));`],{windowsHide:true,stdio:['ignore','ignore','ignore','ipc']});let watch;
const portPromise=new Promise(r=>node.once('message',r));
for(const rel of ['scripts/deploy.sh','scripts/upgrade.sh','scripts/probe.js','ui/index.html'])put(install+'/'+rel,fs.readFileSync(repo+'/'+rel));put(home+'/.wasm-agent/skills/fixture/SKILL.md',fs.readFileSync(repo+'/skills/fixture/SKILL.md'));put(install+'/serve.pid',String(node.pid));
const names=['deploy.sh','upgrade.sh','probe.js'],digest=(base,ns)=>hash(ns.map(n=>`${n}\0${hash(fs.readFileSync(base+'/'+n))}\n`).join('')),at=new Date().toISOString();
const intent={id:'historical-fixture',verb:'deploy',expected_sha:sha,session:'parent',owner:'owner',queued_at:Math.floor(Date.now()/1000)-1},binding={schema:1,id:intent.id,intent,parent:'parent',owner:'owner'},effect={id:intent.id,expected_sha:sha,tree,parent:'parent',owner:'owner',script_sha256:hash(fs.readFileSync(repo+'/scripts/deploy.sh'))},result={ok:true,request_id:intent.id,expected_sha:sha,node_sha256:hash(fs.readFileSync(install+'/wa'+native)),sentinel_sha256:hash(fs.readFileSync(install+'/wa-sentinel'+native)),at};
const installed={resolved_commit:sha,tree,source_provenance:'clean-built-by-deploy',record_role:'final',dirty:'0',at,sha256:result.node_sha256,node_sha256:result.node_sha256,sentinel_sha256:result.sentinel_sha256,scripts_sha256:digest(install+'/scripts',names),ui_sha256:digest(install+'/ui',['index.html']),script_files:JSON.stringify(names),listener_pid:'old-generation',watcher_pid:'old-generation'};
for(const [n,v]of [['intent.json',intent],['binding.json',binding],['effect.json',effect],['result.json',result]])put(evidence+'/'+n,JSON.stringify(v));const record=()=>put(install+'/installed.txt',Object.entries(installed).map(([k,v])=>`${k}=${v}`).join('\n')+'\n');record();
git('commit','--allow-empty','-m','main advanced without installing');git('fetch','origin');let checks=0;

(async()=>{try{const port=await portPromise;
const cleanEnv=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(k)));
const privateEnv={...cleanEnv,WASM_AGENT_HOME:home,WA_INSTALL_DIR:install,WASM_AGENT_PORT:String(port),WA_PORT:String(port),WA_SENTINEL_SUPERVISOR:'none',WA_SENTINEL_WAKE_BUDGET:'0'};
watch=spawn(install+'/wa-sentinel'+native,sentinelBinary?['watch']:['-e','setInterval(()=>{},1000)'],{windowsHide:true,env:privateEnv,stdio:['ignore','ignore','ignore']});
put(home+'/.wasm-agent/sentinel/sentinel.pid',String(watch.pid));
await new Promise(r=>setTimeout(r,500));
const {verifyHistorical}=await import(pathToFileURL(path.resolve('scripts/sentinel-historical-proof.mjs')).href);const env={...process.env,WASM_AGENT_HOME:home,WA_PORT:String(port),WASM_AGENT_IN_TURN:'0'};
const verify=()=>verifyHistorical(repo,install,intent,binding,evidence,env);const original=fs.readFileSync(install+'/installed.txt');let proof=verify();assert(proof.ok&&proof.current_source!==sha&&proof.listener_pid===node.pid&&proof.watcher_pid===watch.pid);checks++;
assert.throws(()=>verifyHistorical(repo,install,intent,binding,evidence,{...env,WASM_AGENT_IN_TURN:'1'}),/external_executor/);checks++;
const before=installed.node_sha256;installed.node_sha256='0'.repeat(64);record();assert.throws(verify,/node_hash_mismatch/);checks++;installed.node_sha256=before;record();
const file=install+'/scripts/probe.js',bytes=fs.readFileSync(file);put(file,'changed code\n');assert.throws(verify,/source_file_mismatch/);checks++;put(file,bytes);
installed.tree='b'.repeat(40);record();assert.throws(verify,/tree_mismatch/);checks++;installed.tree=tree;record();
const old=fs.readFileSync(evidence+'/result.json');put(evidence+'/result.json',JSON.stringify({...result,request_id:'foreign'}));assert.throws(verify,/result_mismatch/);checks++;put(evidence+'/result.json',old);
put(repo+'/dirty','uncommitted');assert.throws(verify,/source_dirty/);checks++;fs.rmSync(repo+'/dirty');
proof=verify();assert(proof.ok);assert(fs.readFileSync(install+'/installed.txt').equals(original),'verifier changed installed record');checks+=2;
if(sentinelBinary){
 put(install+'/runtime-worktree.txt',repo+'\n');
 const {processIdentity}=await import(pathToFileURL(path.resolve('scripts/sentinel-install-proof.mjs')).href);
 const box=home+'/.wasm-agent/sentinel',dir=box+'/deploy-protocol/'+intent.id;fs.mkdirSync(dir,{recursive:true});
 for(const n of ['intent.json','binding.json','effect.json','result.json'])fs.copyFileSync(evidence+'/'+n,dir+'/'+n);
 const admitted={...effect,source:repo,script:repo+'/scripts/deploy.sh',target_pid:node.pid,target_created:Number(processIdentity(node.pid).created),watcher_pid:watch.pid,at:intent.queued_at,phase:'admitted'};
 put(dir+'/effect.json',JSON.stringify(admitted));put(box+'/protocol-effect.json',JSON.stringify(admitted));
 put(box+'/node.json',JSON.stringify({schema:1,pid:node.pid,home,binary:install+'/wa'+native,node_id:'private-node',binary_sha256:result.node_sha256,started_at:intent.queued_at,process_start:'EXACT_CREATED'}).replace('"EXACT_CREATED"',processIdentity(node.pid).created));
 put(dir+'/observation.json',JSON.stringify({slot:1,next_at:18446744073709551615}));put(dir+'/return-status.json',JSON.stringify({phase:'unknown',detail:'original notification unknown'}));
 const originals=Object.fromEntries(['observation.json','return-status.json','result.json','effect.json'].map(n=>[n,fs.readFileSync(dir+'/'+n)]));
 for(const name of ['sentinel-historical-proof.mjs','sentinel-install-proof.mjs'])put(repo+'/scripts/'+name,fs.readFileSync(path.resolve('scripts',name)));
 git('add','.');git('commit','-m','current verifier source');git('fetch','origin');
 const target=spawnSync(install+'/wa-sentinel'+native,['protocol','target'],{env:privateEnv,cwd:repo,encoding:'utf8',timeout:15000});assert.equal(target.status,0,target.stderr);assert.equal(JSON.parse(target.stdout).target_pid,node.pid);checks++;
 const r=spawnSync(install+'/wa-sentinel'+native,['protocol','reconcile-historical',intent.id,'--reason','private historical recovery'],{env:privateEnv,cwd:repo,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});
 put(out+'/cli.stdout',r.stdout||'');put(out+'/cli.stderr',r.stderr||'');assert.equal(r.status,0,r.stderr);const cli=JSON.parse(r.stdout);assert(cli.ok&&cli.effect_replayed===false);assert.equal(JSON.parse(fs.readFileSync(box+'/protocol-effect.json')).phase,'verified');checks+=3;
 for(const [n,b]of Object.entries(originals)){assert(fs.readFileSync(dir+'/'+n).equals(b),'original changed '+n);checks++;}
 if(bootstrap){
  // Exact-source admission succeeds through the native bootstrap; private script
  // records argv only. It does not replace the private node or any installed bytes.
  const marker=out.replaceAll('\\','/')+'/bootstrap-marker';
  put(repo+'/scripts/deploy.sh',`#!/usr/bin/env bash\nprintf '%s\\n' "$@" > '${marker}'\n`);
  git('add','.');git('commit','-m','private bootstrap deployer');git('fetch','origin');
  const def=path.resolve('jobs/on-sentinel-return.json');
  for(const args of [['job','put',def],['job','enable','onSentinelReturn']]){const r=spawnSync(install+'/wa-sentinel'+native,args,{env:privateEnv,cwd:repo,encoding:'utf8'});assert.equal(r.status,0,r.stderr);}
  const waiting=new Promise(r=>node.once('message',r));node.send('idle');await waiting;
  const r=spawnSync(install+'/wa-sentinel'+native,['protocol','bootstrap','--expected-sha',git('rev-parse','HEAD'),'--owner','owner','--session','parent','--reason','private source-bound bootstrap'],{env:privateEnv,cwd:repo,encoding:'utf8',timeout:30000});
  put(out+'/bootstrap.stdout',r.stdout||'');put(out+'/bootstrap.stderr',r.stderr||'');assert.equal(r.status,0,r.stderr);const receipt=JSON.parse(r.stdout);assert(receipt.ok&&!receipt.installation_complete&&receipt.phase==='spawned');checks++;
  const deadline=Date.now()+10000;while(!fs.existsSync(marker)&&Date.now()<deadline)await new Promise(r=>setTimeout(r,20));assert(fs.existsSync(marker),'actual detached private deployer never ran');checks++;
  const args=fs.readFileSync(marker,'utf8');assert(args.includes(receipt.request_id)&&args.includes(git('rev-parse','HEAD')),'exact generation arguments missing');checks++;
  const reserved=JSON.parse(fs.readFileSync(box+'/protocol-effect.json'));assert.equal(reserved.id,receipt.request_id);assert.equal(reserved.phase,'admitted');checks++;
  const again=spawnSync(install+'/wa-sentinel'+native,['protocol','bootstrap','--expected-sha',git('rev-parse','HEAD'),'--owner','owner','--session','parent','--reason','private second attempt forbidden'],{env:privateEnv,cwd:repo,encoding:'utf8',timeout:15000});assert.notEqual(again.status,0);assert(again.stderr.includes('unsettled'));checks++;
 }
}
const receipt={ok:true,checks,skipped:0,labelled_mock:'health/owner HTTP only',native_processes:true,source_and_artifact_hashes:true,no_installer:true};put(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
}finally{node.kill();watch.kill();await Promise.all([new Promise(r=>node.exitCode!==null?r():node.once('exit',r)),new Promise(r=>watch.exitCode!==null?r():watch.once('exit',r))]);}})().catch(e=>{console.error(e);process.exitCode=1;});
