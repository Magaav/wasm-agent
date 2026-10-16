// Fixed, side-effect-free equal guest workloads. Never opens a live model route.
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {createReferenceServer} from '../benchmarks/codemode/reference-server.mjs';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const [binary,assets,out]=process.argv.slice(2);
assert([binary,assets,out].every(x=>x&&path.isAbsolute(x))&&!fs.existsSync(out));
fs.mkdirSync(out,{recursive:true});
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
const runs=[];
async function run(backend,rep){
 const home=path.join(out,backend+'-'+rep);fs.mkdirSync(home);const bin=path.join(home,'bin');fs.mkdirSync(bin);
 const found=cp.spawnSync(process.platform==='win32'?'where.exe':'which',['rg'],{encoding:'utf8'});assert.equal(found.status,0,'existing rg required');const rg=found.stdout.trim().split(/\r?\n/)[0];fs.copyFileSync(rg,path.join(bin,process.platform==='win32'?'rg.exe':'rg'));
 let controller;const key=crypto.randomBytes(32).toString('hex');const t=performance.now();
 if(backend==='node'){controller=await createReferenceServer({assets,key});await new Promise(r=>controller.server.listen(0,'127.0.0.1',r));}
 const controller_setup_ms=performance.now()-t;
 const env={...clean,PATH:bin,Path:bin,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/codemode-equal-workload.lua'),WA_QJS_ASSETS:assets,WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',...(controller?{WA_DIAGNOSTIC_REFERENCE:'1',WA_CODEMODE_CONTROLLER_URL:'http://127.0.0.1:'+controller.server.address().port+'/quickjs',WA_CODEMODE_CONTROLLER_KEY:key}:{})};
 assert.equal(cp.spawnSync('node',['--version'],{env}).error?.code,'ENOENT','native actor cannot find Node');
 const start=performance.now();let stdout='',stderr='';let exit,signal;
 try{const child=cp.spawn(binary,['--db',path.join(home,'d.db')],{cwd:repo,env,windowsHide:true,stdio:['ignore','pipe','pipe']});child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);({exit,signal}=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',(exit,signal)=>resolve({exit,signal}));}));}
 finally{if(controller){controller.dispose();await new Promise(r=>controller.server.close(r));assert.equal(controller.active(),0);}}
 const process_wall_ms=performance.now()-start;
 fs.writeFileSync(path.join(home,'stdout'),stdout);fs.writeFileSync(path.join(home,'stderr'),stderr);
 let result;try{result=JSON.parse(stdout.trim().split(/\r?\n/).at(-1));}catch{}
 const record={backend,rep,exit,signal,controller_setup_ms,process_wall_ms,result,rg_sha256:sha(fs.readFileSync(rg)),stdout_sha256:sha(stdout),stderr_sha256:sha(stderr)};runs.push(record);fs.writeFileSync(path.join(out,'partial.json'),JSON.stringify(runs,null,2));
 assert.equal(exit,0,stderr);assert(result?.ok,'all workload correctness controls must pass');
}
// Fixed up front: 3 process pairs; alternate host order, 3 rounds of 6 cases each.
for(let rep=1;rep<=3;rep++)for(const backend of rep===2?['rust','node']:['node','rust'])await run(backend,rep);
const reference=runs[0].result.rows;
for(const r of runs){assert.equal(r.result.info.wasm_sha256,runs[0].result.info.wasm_sha256);assert.equal(r.result.info.prelude_sha256,runs[0].result.info.prelude_sha256);assert.deepEqual(r.result.rows.map(x=>[x.name,x.code_sha256,x.pass,x.calls,x.output_bytes,x.output_sha256,x.done.ok,x.done.value]),reference.map(x=>[x.name,x.code_sha256,x.pass,x.calls,x.output_bytes,x.output_sha256,x.done.ok,x.done.value]));}
const receipt={ok:true,paid_solver_calls:0,runs,binary_sha256:sha(fs.readFileSync(binary)),sources:['scripts/codemode-equal-workload.lua','scripts/codemode-equal-workload.mjs','benchmarks/codemode/reference-server.mjs','benchmarks/codemode/reference-client.lua'].map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))})),limitations:['Not autonomous usefulness evidence','start_ms includes host start/guest setup/evaluation; not separately identifiable','Node action times include loopback HTTP/JSON broker overhead; Rust is in-process','First guest in fresh host vs warm host/fresh guest; no warm persistent guest','Node reference controller module/JIT caches may persist across pairs','Wasmtime 500M fuel vs no equivalent Node fuel; same 30s deadline,64MiB guest heap,512KiB stack','No host CPU or peak memory measurement; unknown, not zero','Process wall includes native startup/DB and teardown; controller setup separately measured','Preparation assistant inference/spend not included; unknown']};
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({ok:true,runs:runs.length,cases:runs.reduce((n,r)=>n+r.result.rows.length,0),evidence:out}));
