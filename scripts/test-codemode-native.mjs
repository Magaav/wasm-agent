// Fresh evidence collector; --post validates retained evidence without replay.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import cp from 'node:child_process';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const post=process.argv[2]==='--post';const [binary,out,assets]=process.argv.slice(post?3:2);
assert(binary&&out&&path.isAbsolute(binary)&&path.isAbsolute(out),'absolute binary/fresh evidence required');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const sourceNames=['lua/core/codemode.lua','lua/core/tools.lua','lua/core/envelope.lua','rust/wa-host/src/quickjs.rs','rust/wa-host/src/main.rs','rust/wa-host/build.rs','scripts/test-codemode-native.lua','scripts/test-codemode-native.mjs'];
const sources=sourceNames.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))}));
if(post){const receipt=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(receipt.ok);for(const file of receipt.files)assert(sha(fs.readFileSync(path.join(out,file.name)))===file.sha256,'retained proof drift');assert(sha(fs.readFileSync(binary))===receipt.binary_sha256);assert.deepEqual(sources,receipt.sources,'tested source/fixture drift');console.log(JSON.stringify({ok:true,checks:receipt.results.reduce((n,r)=>n+r.checks,0),retained_hashes:true}));}
else{
 assert(!fs.existsSync(out),'evidence generation exists');fs.mkdirSync(out,{recursive:true});
 const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
 const results=[],files=[];let ok=true;
 const keep=(name,bytes)=>{fs.writeFileSync(path.join(out,name),bytes);files.push({name,sha256:sha(bytes)});};
 for(const mode of ['source','embedded']){
  const home=path.join(out,mode);fs.mkdirSync(home);const bin=path.join(home,'bin');fs.mkdirSync(bin);
  const rg=cp.spawnSync(process.platform==='win32'?'where.exe':'which',['rg'],{encoding:'utf8'});assert(rg.status===0,'provisioned rg required');const rgPath=rg.stdout.trim().split(/\r?\n/)[0];fs.copyFileSync(rgPath,path.join(bin,process.platform==='win32'?'rg.exe':'rg'));
  const env={...clean,PATH:bin,Path:bin,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-codemode-native.lua'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',...(assets?{WA_QJS_ASSETS:assets}:{}),...(mode==='source'?{WASM_AGENT_LUA_ROOT:repo}:{})};
  const missingNode=cp.spawnSync('node',['--version'],{cwd:home,env,encoding:'utf8'});assert(missingNode.error?.code==='ENOENT','Node must be unavailable in native runtime PATH');
  for(const phase of ['seed','restart']){
  const phaseEnv={...env,WA_CODEMODE_PROOF_PHASE:phase};
  const started=performance.now();const r=cp.spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:repo,env:phaseEnv,encoding:'utf8',windowsHide:true,timeout:90000,maxBuffer:8*1024*1024});
  keep(mode+'/'+phase+'.stdout',Buffer.from(r.stdout||''));keep(mode+'/'+phase+'.stderr',Buffer.from(r.stderr||''));
  let summary;try{summary=JSON.parse((r.stdout||'').trim().split(/\r?\n/).at(-1));}catch{};
  const passed=r.status===0&&summary?.ok===true&&summary.checks>=(phase==='restart'?2:37);results.push({mode,phase,exit:r.status,signal:r.signal,error:r.error?.message,checks:summary?.checks??null,elapsed_ms:performance.now()-started,node_unavailable:missingNode.error.code});if(!passed){ok=false;break;}
  }
  if(!ok)break;
 }
 for(const mode of ['source','embedded'])if(fs.existsSync(path.join(out,mode)))for(const entry of fs.readdirSync(path.join(out,mode))){if(entry.endsWith('.db'))files.push({name:mode+'/'+entry,sha256:sha(fs.readFileSync(path.join(out,mode,entry)))});}
 assert.deepEqual(sourceNames.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))})),sources,'source changed during proof');
 const receipt={ok,results,sources,binary_sha256:sha(fs.readFileSync(binary)),files,paid_calls:0,assets:assets?'external pinned':'embedded pinned'};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({ok,results,binary_sha256:receipt.binary_sha256,retained_files:files.length,paid_calls:0,assets:receipt.assets}));if(!ok)process.exitCode=1;
}
