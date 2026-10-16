// Actual-agent privacy/model/SSE/session proof; never inference or installation.
import fs from 'node:fs';import path from 'node:path';import cp from 'node:child_process';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');const post=process.argv[2]==='--post';const [binary,out,prior]=process.argv.slice(post?3:2);
assert(path.isAbsolute(binary||'')&&path.isAbsolute(out||'')&&(!prior||path.isAbsolute(prior)),'absolute binary/fresh evidence/[prior binary] required');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const names=['lua/core/codemode.lua','lua/core/codemode_view.lua','lua/core/redact.lua','lua/core/json_contract.lua','lua/vendor/json.lua','lua/core/agent.lua','lua/core/server.lua','lua/core/provider.lua','lua/core/memory.lua','lua/core/session_view.lua','lua/core/tools.lua','lua/core/read_batch.lua','lua/core/tool_output.lua','scripts/test-codemode-model-boundary.lua','scripts/test-codemode-model-boundary.mjs','scripts/test-redact-secrets.lua','scripts/test-json-parsing.lua'];
const sources=names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))}));
if(post){const r=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(r.ok);assert.equal(sha(fs.readFileSync(binary)),r.binary_sha256);assert.deepEqual(sources,r.sources);for(const f of r.files)assert.equal(sha(fs.readFileSync(path.join(out,f.name))),f.sha256,f.name);console.log(JSON.stringify({ok:true,retained_hashes:true,results:r.results}));}
else{
 assert(!fs.existsSync(out),'failed generations are immutable');fs.mkdirSync(out,{recursive:true});
 for(const name of names){const p=path.join(out,'sources',name);fs.mkdirSync(path.dirname(p),{recursive:true});fs.copyFileSync(path.join(repo,name),p);}
 const tested=path.join(out,'tested-wa.exe');fs.copyFileSync(binary,tested);if(prior)fs.copyFileSync(prior,path.join(out,'prior-wa.exe'));
 const baseline=cp.spawnSync('git',['show','bebef12a85ce6c46236c59be27be67a6fcc0fe35:lua/core/codemode_view.lua'],{cwd:repo,maxBuffer:8*1024*1024});assert.equal(baseline.status,0);const baselineFile=path.join(out,'old-codemode_view.lua');fs.writeFileSync(baselineFile,baseline.stdout);
 const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
 const results=[];let ok=true;
 for(const mode of ['old-source',...(prior?['prior-embedded']:[]),'source','embedded']){
  const home=path.join(out,mode);fs.mkdirSync(home);const bin=path.join(home,'bin');fs.mkdirSync(bin);const rg=cp.spawnSync(process.platform==='win32'?'where.exe':'which',['rg'],{encoding:'utf8'});assert.equal(rg.status,0);fs.copyFileSync(rg.stdout.trim().split(/\r?\n/)[0],path.join(bin,process.platform==='win32'?'rg.exe':'rg'));
  const source=mode==='source'||mode==='old-source';const negative=mode==='old-source'||mode==='prior-embedded';
  const env={...clean,PATH:bin,Path:bin,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-codemode-model-boundary.lua'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',...(source?{WASM_AGENT_LUA_ROOT:repo}:{}),...(mode==='old-source'?{WA_BOUNDARY_OLD_VIEW:baselineFile}:{})};
  assert.equal(cp.spawnSync('node',['--version'],{cwd:home,env}).error?.code,'ENOENT');
  for(const phase of negative?['seed']:['seed','restart']){
   const r=cp.spawnSync(mode==='prior-embedded'?path.join(out,'prior-wa.exe'):tested,['--db',path.join(home,'private.db')],{cwd:home,env:{...env,WA_BOUNDARY_PHASE:phase},encoding:'utf8',timeout:120000,maxBuffer:8*1024*1024,windowsHide:true});
   for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(home,phase+'.'+stream),r[stream]||'');let summary;try{summary=JSON.parse(r.stdout.trim().split(/\r?\n/).at(-1));}catch{}
   let passed,emptyDefect=false;
   if(negative){let observed;try{observed=JSON.parse(fs.readFileSync(path.join(home,'.wasm-agent/small-observed.json')));}catch{}
    emptyDefect=observed?.shown?.[0]?.complete===true&&Array.isArray(observed?.shown?.[0]?.result)&&observed.shown[0].result.length===0;
    passed=r.status!==0&&emptyDefect;
    if(emptyDefect){const ref=observed.calls[0].evidence;const original=fs.readFileSync(ref.path);assert.equal(sha(original),ref.sha256);assert(JSON.parse(original).results[0].content.length>0,'negative control original is NOT empty');}
   }else passed=r.status===0&&summary?.ok===true&&summary.checks>=(phase==='seed'?450:30);
   const privateLogsSafe=![r.stdout||'',r.stderr||''].some(t=>t.includes('fixture_private_value_79a0f12e_not_a_real_credential')||t.includes('fxt12345'));
   passed=passed&&privateLogsSafe;
   results.push({mode,phase,status:r.status,signal:r.signal,error:r.error?.message,summary,expected_failure:negative,displayed_empty_defect:emptyDefect,node_unavailable:true,private_logs_safe:privateLogsSafe,passed});if(!passed){ok=false;break;}
  }
  if(ok&&!negative)for(const fixture of ['test-redact-secrets.lua','test-json-parsing.lua']){
   const compatibleHome=path.join(home,fixture.replace('.lua',''));fs.mkdirSync(compatibleHome);
   const r=cp.spawnSync(tested,['--db',path.join(compatibleHome,'private.db')],{cwd:compatibleHome,env:{...env,WASM_AGENT_HOME:compatibleHome,WA_SCRIPT:path.join(repo,'scripts',fixture)},encoding:'utf8',timeout:60000,maxBuffer:8*1024*1024,windowsHide:true});
   for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(compatibleHome,stream),r[stream]||'');
   let summary;let passed=r.status===0;
   if(fixture==='test-json-parsing.lua'){try{summary=JSON.parse(r.stdout.trim());}catch{};passed=passed&&summary?.checks===18&&summary?.skipped===0&&summary?.source===sources.find(s=>s.name==='lua/vendor/json.lua').sha256;}
   else passed=passed&&/redact secrets ok \(18 checks\)/.test(r.stdout||'');
   results.push({mode,phase:fixture,status:r.status,signal:r.signal,error:r.error?.message,summary,passed,node_unavailable:true});if(!passed){ok=false;break;}
  }
  if(!ok)break;
 }
 const files=[];function collect(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,e.name);if(e.isDirectory())collect(p);else files.push({name:path.relative(out,p),sha256:sha(fs.readFileSync(p))});}}collect(out);
 assert.deepEqual(names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))})),sources,'source drift');
 const receipt={ok,sources,baseline_view_sha256:sha(baseline.stdout),binary_sha256:sha(fs.readFileSync(tested)),prior_binary_sha256:prior?sha(fs.readFileSync(path.join(out,'prior-wa.exe'))):null,results,files,paid_calls:0,gate_verified:false,release_verified:false};
 fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({ok,results,binary_sha256:receipt.binary_sha256,retained_files:files.length,paid_calls:0}));if(!ok)process.exitCode=1;
}
