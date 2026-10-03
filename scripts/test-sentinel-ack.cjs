// Actual native observer; isolated private stores and HTTP binding, no effect/provider.
const fs=require('fs'),os=require('os'),path=require('path'),http=require('http'),assert=require('assert/strict'),{spawn}=require('child_process');
const sentinel=path.resolve(process.argv[2]),expected=process.argv[3]||'unknown';
const home=fs.mkdtempSync(path.join(os.tmpdir(),'wa-ack-native-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>['PATH','SYSTEMROOT','WINDIR','COMSPEC','TEMP','TMP','PATHEXT','SYSTEMDRIVE'].includes(k.toUpperCase())));
let posts=0;const server=http.createServer((q,r)=>{if(q.method==='POST')posts++;r.end(JSON.stringify({session:{id:'parent',user_id:'owner'}}));});
const write=(dir,name,v)=>fs.writeFileSync(path.join(dir,name+'.json'),JSON.stringify(v));
const run=(args=['protocol','observe'])=>new Promise((resolve,reject)=>{const c=spawn(sentinel,args,{env:privateEnv,cwd:home,windowsHide:true});let stdout='',stderr='';c.stdout.on('data',b=>stdout+=b);c.stderr.on('data',b=>stderr+=b);c.on('error',reject);c.on('exit',code=>{fs.appendFileSync(path.join(home,'cli.jsonl'),JSON.stringify({args,code,stdout,stderr})+'\n');resolve({code,stdout,stderr});});});
let privateEnv;const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));privateEnv={...env,WASM_AGENT_HOME:home,WASM_AGENT_PORT:String(server.address().port),WA_INSTALL_DIR:path.join(home,'install'),WA_SENTINEL_SUPERVISOR:'none'};
try {
 if(expected!=='held'){const hook=path.resolve(__dirname,'../jobs/on-sentinel-return.json');assert.equal((await run(['job','put',hook])).code,0);assert.equal((await run(['job','enable','onSentinelReturn'])).code,0);}
 const box=path.join(home,'.wasm-agent/sentinel/deploy-protocol');
 const fixture=id=>{const dir=path.join(box,id);fs.mkdirSync(dir,{recursive:true});const intent={id,verb:'deploy',expected_sha:'a'.repeat(40),session:'parent',owner:'owner',queued_at:Math.floor(Date.now()/1000)-20};write(dir,'intent',intent);return {dir,intent};};
 const missing=fixture('missing-ack');await run();await run();let journal=JSON.parse(fs.readFileSync(path.join(missing.dir,'returns/missing-ack-0.json')));assert.equal(journal.phase,expected);assert(!fs.existsSync(path.join(missing.dir,'ack.json')));assert.equal(posts,0);
 if(expected==='held'){console.log('prepatch missing ack reproduced: held; 2 checks, 0 skipped');return;}
 assert(!fs.existsSync(path.join(missing.dir,'check.json')));
 assert(!fs.existsSync(path.join(missing.dir,'pending-return.json')),'enabled hook cannot admit missing ack');
 write(missing.dir,'state',{id:missing.intent.id,expected_sha:missing.intent.expected_sha,phase:'failed',at:Math.floor(Date.now()/1000)});await run();assert.equal(JSON.parse(fs.readFileSync(path.join(missing.dir,'ack-problem.json'))).phase,'unknown','failed state cannot replace missing ack');
 fs.renameSync(missing.dir,path.join(home,'missing-evidence'));
 const delayed=fixture('delayed-ack'),at=Math.floor(Date.now()/1000),ack={schema:1,id:delayed.intent.id,expected_sha:delayed.intent.expected_sha,session:'parent',owner:'owner',queued_at:delayed.intent.queued_at,phase:'held',detail:'private delayed intake',at};write(delayed.dir,'ack',ack);
 const start=Date.now();await run();const check=JSON.parse(fs.readFileSync(path.join(delayed.dir,'check.json')));assert.equal(check.next_at,at+10);assert(!fs.readdirSync(delayed.dir).some(n=>/^check-\d+\.json$/.test(n)),'queue age cannot make ack check due');
 await sleep(11000);await run();assert(Date.now()-start>=10000);assert(fs.existsSync(path.join(delayed.dir,'check-'+(at+10)+'.json')));const due=JSON.parse(fs.readFileSync(path.join(delayed.dir,'check-'+(at+10)+'.json')));assert.equal(due.due_at,at+10);
 const originalCheck=fs.readFileSync(path.join(delayed.dir,'check.json'));
 write(delayed.dir,'ack',{...ack,detail:'revised ack'});await run();assert.equal(JSON.parse(fs.readFileSync(path.join(delayed.dir,'ack-problem.json'))).phase,'unknown');assert.deepEqual(fs.readFileSync(path.join(delayed.dir,'check.json')),originalCheck,'revised ack cannot advance timer');
 const eventFile=path.join(home,'event.json');fs.writeFileSync(eventFile,JSON.stringify({id:ack.id,event_key:ack.id+'-0'}));const revoked=await run(['protocol','compose',eventFile]);assert.equal(revoked.code,1);assert.match(revoked.stderr,/check_ack_binding_changed/,'pending held journal cannot wake after ack revision');
 write(delayed.dir,'ack',ack);write(delayed.dir,'check',{id:ack.id,next_at:ack.at+10});await run();assert.equal(JSON.parse(fs.readFileSync(path.join(delayed.dir,'ack-problem.json'))).phase,'unknown','legacy check cannot fabricate ack basis');
 fs.renameSync(delayed.dir,path.join(home,'delayed-evidence'));
 let controls=0;
 for(const change of [{id:'other'},{expected_sha:'b'.repeat(40)},{expected_sha:'a'.repeat(7)},{owner:'other'},{session:'other'},{queued_at:at-21},{at:at+100},{at:undefined},{schema:2},{revision:2}]){const f=fixture('wrong-'+controls),bad={...ack,id:f.intent.id,queued_at:f.intent.queued_at,...change};write(f.dir,'ack',bad);await run();assert.equal(JSON.parse(fs.readFileSync(path.join(f.dir,'returns/'+f.intent.id+'-0.json'))).phase,'unknown');assert(!fs.existsSync(path.join(f.dir,'check.json')));fs.renameSync(f.dir,path.join(home,f.intent.id+'-evidence'));controls++;}
 const corrupt=fixture('corrupt-ack');fs.writeFileSync(path.join(corrupt.dir,'ack.json'),'{');await run();assert.equal(JSON.parse(fs.readFileSync(path.join(corrupt.dir,'returns/corrupt-ack-0.json'))).phase,'unknown');fs.renameSync(corrupt.dir,path.join(home,'corrupt-evidence'));
 const binding=fixture('wrong-binding');write(binding.dir,'ack',{...ack,id:binding.intent.id,queued_at:binding.intent.queued_at});write(binding.dir,'binding',{schema:1,id:binding.intent.id,intent:binding.intent,parent:'victim',owner:'owner'});const refused=await run();assert.match(refused.stderr,/parent_binding_changed/);assert(!fs.existsSync(path.join(binding.dir,'returns')));
 assert.equal(posts,0);const result={ok:true,checks:controls+9,skipped:0,posts,home,ack_at:at,queued_at:delayed.intent.queued_at,due_at:due.due_at,elapsed_ms:Date.now()-start};write(home,'result',result);console.log(JSON.stringify(result));
}finally{await new Promise(r=>server.close(r));console.log('evidence: '+home);}})().catch(e=>{console.error(e);process.exitCode=1;});
