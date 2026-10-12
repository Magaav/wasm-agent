'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const [oldBinary,newBinary,out]=process.argv.slice(2);if(!oldBinary||!newBinary||!out||![oldBinary,newBinary,out].every(p=>path.isAbsolute(p))||fs.existsSync(out))throw Error('usage: <baseline-wa> <candidate-wa> <fresh-evidence>');
const repo=path.resolve(__dirname,'..'),sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');fs.mkdirSync(out,{recursive:true});const runs=[];
for(const [name,binary,mode]of [['baseline-1',oldBinary,'primitive'],['candidate-1',newBinary,'batch'],['candidate-2',newBinary,'batch'],['baseline-2',oldBinary,'primitive']]){
 const home=path.join(out,name);fs.mkdirSync(home);const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(key)));
 Object.assign(env,{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:path.join(repo,'scripts/bench-retrieval.lua'),WA_GRAPH_WATCH:'0',WA_RETRIEVAL_BENCH_ROOT:repo,WA_RETRIEVAL_BENCH_DB:path.join(home,'graph.db'),WA_RETRIEVAL_BENCH_MODE:mode,WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0'});
 const started=performance.now(),r=cp.spawnSync(binary,['--db',path.join(home,'test.db')],{cwd:home,env,encoding:'utf8',windowsHide:true,timeout:300000,maxBuffer:8*1024*1024});for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(home,stream+'.log'),r[stream]||'');
 if(r.error||r.status!==0)throw Error(name+': '+(r.stderr||r.stdout||r.error?.message).slice(-2400));const result=JSON.parse(r.stdout.trim().split('\n').at(-1));if(!result.ok||result.skipped!==0||!result.source_sha256)throw Error(name+' invalid verdict');runs.push({name,binary_sha256:sha(binary),wall_ms:performance.now()-started,...result});
}
if(new Set(runs.map(r=>r.source_sha256)).size!==1)throw Error('arms did not retrieve identical sources');
const receipt={ok:true,runs,source_hashes:Object.fromEntries(['scripts/bench-retrieval.lua','scripts/bench-retrieval.cjs','lua/core/graph.lua'].map(p=>[p,sha(path.join(repo,p))])),gate_verified:false,release_verified:false};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
