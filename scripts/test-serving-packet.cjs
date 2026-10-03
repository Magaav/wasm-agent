// Focused exact-tip evidence, explicitly not the repository's full release gate.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]||fs.mkdtempSync(path.join(os.tmpdir(),'wa-serving-packet-')));fs.mkdirSync(out,{recursive:true});
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
function git(...args){const r=spawnSync('git',args,{cwd:root,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
assert.equal(git('status','--porcelain'),'','focused packet requires a clean committed source tree');
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|SERVING_TEST_|ORCHESTRATOR_TEST_)/i.test(k)));
const jobs=[
 ['serving','test-provider-serving.cjs',false,false,/4 private process runs passed/],
 ['contract','test-serving-contract.cjs',true,false,/Serving contract source \+ embedded/],
 ['http','test-serving-http.cjs',true,false,/Actual source \+ embedded HTTP/],
 ['guards','test-serving-guards.cjs',true,false,/12 causal guard removals rejected/],
 ['binding-negative','test-provider-binding-negative.cjs',false,false,/embedded raw-binding mutation rejected/],
 ['compat-source','test-orchestrator.cjs',false,false,/20 checks, 0 skipped/],
 ['compat-embedded','test-orchestrator.cjs',false,true,/20 checks, 0 skipped/],
 ['queue-race','test-orchestrator-queue-race.cjs',true,false,/F5 causal timer-sampling failure reproduced/]
];
const packet={kind:'focused-serving-eligibility',full_gate:false,head:git('rev-parse','HEAD'),tree:git('rev-parse','HEAD^{tree}'),base:git('rev-parse','origin/main'),binary,binary_sha256:hash(binary),runner_sha256:hash(__filename),zero_paid_probes:true,skips:0,checks:[]};
for(const [name,file,owned,embedded,verdict] of jobs){
 const runner=path.join(root,'scripts',file),args=[runner,binary];if(owned)args.push(path.join(out,name));
 const env={...clean};if(embedded)env.ORCHESTRATOR_TEST_EMBEDDED='1';
 const started=Date.now(),r=spawnSync(process.execPath,args,{cwd:root,env,encoding:'utf8',timeout:240000,windowsHide:true});
 const log=path.join(out,name+'.log');fs.writeFileSync(log,r.stdout+'\nSTDERR\n'+r.stderr);
 packet.checks.push({name,exit:r.status,signal:r.signal,ms:Date.now()-started,runner_sha256:hash(runner),log,log_sha256:hash(log)});
 // Preserve each actual private compatibility/binding fixture, not just its path.
 const retained=[...r.stdout.matchAll(/(?:evidence: |evidence )(C:[^\r\n]+)/g)].map(m=>m[1]);
 for(let i=0;i<retained.length;i++)if(fs.existsSync(retained[i]))fs.cpSync(retained[i],path.join(out,name+'-retained-'+i),{recursive:true});
 fs.writeFileSync(path.join(out,'PACKET.json'),JSON.stringify(packet,null,2));
 assert.equal(r.status,0,name+': '+r.stderr);assert.match(r.stdout,verdict,name+' verdict');console.log(name+' passed; focused evidence '+log);
}
assert.equal(git('rev-parse','HEAD'),packet.head,'HEAD changed while testing');assert.equal(git('status','--porcelain'),'','source changed while testing');
packet.complete=true;fs.writeFileSync(path.join(out,'PACKET.json'),JSON.stringify(packet,null,2));
console.log('Focused serving packet passed; source + embedded, 0 skips, 0 paid probes; full gate remains independent: '+path.join(out,'PACKET.json'));
