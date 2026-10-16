// Deterministic private actual-native proof; no model, network or installation.
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const post=process.argv[2]==='--post';
const [binary,out]=process.argv.slice(post?3:2);
assert(path.isAbsolute(binary||'')&&path.isAbsolute(out||''),'absolute binary and fresh evidence required');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const names=['lua/core/redact.lua','lua/core/json_contract.lua','lua/vendor/json.lua','lua/core/codemode.lua','lua/core/codemode_view.lua','lua/core/read_batch.lua','lua/core/tool_output.lua','scripts/test-codemode-presentation.lua','scripts/test-codemode-presentation.mjs'];
const sources=names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))}));
if(post){
 const receipt=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(receipt.ok);assert.equal(sha(fs.readFileSync(binary)),receipt.binary_sha256);assert.deepEqual(sources,receipt.sources);
 for(const f of receipt.files)assert.equal(sha(fs.readFileSync(path.join(out,f.name))),f.sha256,f.name);
 console.log(JSON.stringify({ok:true,retained_hashes:true,results:receipt.results}));
}else{
 assert(!fs.existsSync(out),'never overwrite failed generations');fs.mkdirSync(out,{recursive:true});
 for(const name of names){const p=path.join(out,'sources',name);fs.mkdirSync(path.dirname(p),{recursive:true});fs.copyFileSync(path.join(repo,name),p);}
 fs.copyFileSync(binary,path.join(out,'tested-wa'+(process.platform==='win32'?'.exe':'')));
 const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
 const results=[];let ok=true;
 for(const mode of ['source','embedded']){
  const home=path.join(out,mode);fs.mkdirSync(home);const bin=path.join(home,'bin');fs.mkdirSync(bin);
  const rg=cp.spawnSync(process.platform==='win32'?'where.exe':'which',['rg'],{encoding:'utf8'});assert.equal(rg.status,0);fs.copyFileSync(rg.stdout.trim().split(/\r?\n/)[0],path.join(bin,process.platform==='win32'?'rg.exe':'rg'));
  const env={...clean,PATH:bin,Path:bin,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-codemode-presentation.lua'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',...(mode==='source'?{WASM_AGENT_LUA_ROOT:repo}:{})};
  const noNode=cp.spawnSync('node',['--version'],{cwd:home,env});assert.equal(noNode.error?.code,'ENOENT');
  for(const phase of ['seed','restart']){
   const r=cp.spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:home,env:{...env,WA_PRESENTATION_PHASE:phase},encoding:'utf8',timeout:90000,maxBuffer:8*1024*1024,windowsHide:true});
   for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(home,phase+'.'+stream),r[stream]||'');
   let summary;try{summary=JSON.parse((r.stdout||'').trim().split(/\r?\n/).at(-1));}catch{}
   const passed=r.status===0&&summary?.ok===true&&summary.checks>=(phase==='seed'?40:1);
   results.push({mode,phase,status:r.status,signal:r.signal,error:r.error?.message,summary,node_unavailable:noNode.error.code});if(!passed){ok=false;break;}
  }
  if(!ok)break;
 }
 const files=[];function collect(dir){for(const ent of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,ent.name);if(ent.isDirectory())collect(p);else files.push({name:path.relative(out,p),sha256:sha(fs.readFileSync(p))});}}
 collect(out);assert.deepEqual(names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))})),sources,'source drift');
 const receipt={ok,sources,binary_sha256:sha(fs.readFileSync(binary)),results,files,paid_calls:0};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));if(!ok)process.exitCode=1;
}
