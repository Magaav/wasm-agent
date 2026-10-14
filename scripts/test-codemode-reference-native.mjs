// Model-free V1 proof: real Node guest -> shared native authorization -> real tools.
import fs from 'node:fs';import path from 'node:path';import cp from 'node:child_process';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {fileURLToPath} from 'node:url';
import {createReferenceServer} from '../benchmarks/codemode/reference-server.mjs';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');const [binary,assets,out]=process.argv.slice(2);assert([binary,assets,out].every(p=>p&&path.isAbsolute(p)));assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));const results=[];let ok=true;
async function native(env){const start=performance.now();const child=cp.spawn(binary,['--db',path.join(env.WASM_AGENT_HOME,'private.db')],{cwd:repo,env,stdio:['ignore','pipe','pipe'],windowsHide:true});child.stdout.setEncoding('utf8');child.stderr.setEncoding('utf8');let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);return await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{child.kill();reject(Error('native reference proof timeout'));},90000);child.on('error',reject);child.on('close',(exit,signal)=>{clearTimeout(timer);resolve({exit,signal,stdout,stderr,elapsed_ms:performance.now()-start});});});}
for(const mode of ['source','embedded']){
 const home=path.join(out,mode);fs.mkdirSync(home);
 for(const phase of ['seed','restart']){
  const key=crypto.randomBytes(32).toString('hex');const controller=await createReferenceServer({assets,key});
  await new Promise(resolve=>controller.server.listen(0,'127.0.0.1',resolve));const url='http://127.0.0.1:'+controller.server.address().port+'/quickjs';
  const denied=await fetch(url,{method:'POST',headers:{authorization:'Bearer wrong','content-type':'application/json'},body:JSON.stringify({action:'info',args:{}})});assert.equal(denied.status,401);
  let run;try{run=await native({...clean,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-codemode-native.lua'),WA_CODEMODE_PROOF_PHASE:phase,WA_CODEMODE_PROOF_BACKEND:'node-quickjs-wasi-reference',WA_CODEMODE_CONTROLLER_CLIENT:path.join(repo,'benchmarks/codemode/reference-client.lua'),WA_CODEMODE_CONTROLLER_URL:url,WA_CODEMODE_CONTROLLER_KEY:key,WA_QJS_ASSETS:assets,WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',...(mode==='source'?{WASM_AGENT_LUA_ROOT:repo}:{})});}
  finally{controller.dispose();await new Promise(resolve=>controller.server.close(resolve));assert.equal(controller.active(),0);}
  fs.writeFileSync(path.join(home,phase+'.stdout'),run.stdout);fs.writeFileSync(path.join(home,phase+'.stderr'),run.stderr);
  let summary;try{summary=JSON.parse(run.stdout.trim().split(/\r?\n/).at(-1));}catch{};
  const pass=run.exit===0&&summary?.ok===true&&summary.checks>=(phase==='seed'?42:2);results.push({mode,phase,exit:run.exit,signal:run.signal,elapsed_ms:run.elapsed_ms,checks:summary?.checks??null,skipped:summary?.skipped??0,controller_nonce_rejected:true,controller_drained:true});if(!pass){ok=false;break;}
 }
 if(!ok)break;
}
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');const receipt={ok,results,paid_solver_calls:0,binary_sha256:sha(fs.readFileSync(binary)),host:'upstream Pi VM over comparison-only Node controller; unchanged native Lua dispatcher',files:['benchmarks/codemode/reference-server.mjs','benchmarks/codemode/reference-client.lua','lua/core/codemode.lua','scripts/test-codemode-native.lua'].map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))}))};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));if(!ok)process.exitCode=1;
