// Focused graph repair proof; private repositories, source+embedded, retained raw logs.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'..'),post=process.argv[2]==='--post',binary=path.resolve(process.argv[post?3:2]||''),out=path.resolve(process.argv[post?4:3]||'');
assert(process.argv[post?3:2]&&process.argv[post?4:3],'usage: [--post] <candidate-wa> <fresh-evidence>');
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
if(post){const r=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(r.ok);assert.equal(r.binary.sha256,sha(binary));for(const [p,h]of Object.entries(r.sources))assert.equal(sha(path.join(repo,p)),h);for(const [p,h]of Object.entries(r.artifacts))assert.equal(sha(path.join(out,p)),h);console.log(JSON.stringify({ok:true,post:true,runs:r.runs,skipped:0}));process.exit(0);}
assert(!fs.existsSync(out),'fresh evidence required');fs.mkdirSync(out,{recursive:true});
const sources=Object.fromEntries(['lua/core/patch_audit.lua','lua/core/graph.lua','rust/wa-graph/src/audit.rs','rust/wa-graph/src/extract.rs','rust/wa-graph/src/store.rs','rust/wa-graph/src/incremental.rs','rust/wa-graph/src/lib.rs','rust/wa-graph/src/watch.rs','rust/wa-host/src/graph.rs','rust/wa-graph/src/repair_tests.rs','rust/wa-graph/Cargo.toml','rust/Cargo.lock','scripts/test-graph-repair.lua','scripts/test-graph-repair.cjs'].map(p=>[p,sha(path.join(repo,p))]));
const receipt={ok:false,binary:{path:binary,sha256:sha(binary)},sources,artifacts:{},runs:[],skipped:0,gate_verified:false,release_verified:false};
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));
function run(program,args,cwd=repo){const r=cp.spawnSync(program,args,{cwd,encoding:'utf8',maxBuffer:32*1024*1024,timeout:120000,windowsHide:true});assert.equal(r.status,0,r.error?.message||r.stderr);return r.stdout;}
const real=path.join(out,'real104');run('git',['clone','--quiet','--shared','--no-checkout',repo,real]);run('git',['checkout','--quiet','476ccb7586f5b3cd5aae2c6783e8bc681ac06c3a'],real);
const patch=path.join(out,'real104.patch');fs.writeFileSync(patch,run('git',['diff','--binary','476ccb7586f5b3cd5aae2c6783e8bc681ac06c3a','fdc79bfc8bd78ab5e04ab3e925bb92a7dd8fffa5']));run('git',['apply','--index',patch],real);
fs.writeFileSync(path.join(out,'real104-index-before.txt'),run('git',['ls-files','--stage'],real));
const envBase=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(k)));
for(const mode of ['source','embedded']){
 const home=path.join(out,mode,'home');fs.mkdirSync(home,{recursive:true});
 const env={...envBase,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-graph-repair.lua'),WA_REPAIR_ROOT:path.join(out,mode,'fixtures'),WA_REPAIR_REAL104:mode==='source'?real:'',WA_GRAPH_ROOT:path.join(out,mode,'fixtures'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only'};
 if(mode==='source')env.WASM_AGENT_LUA_ROOT=repo;
 const r=cp.spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:repo,env,encoding:'utf8',maxBuffer:32*1024*1024,timeout:300000,windowsHide:true});
 for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(out,mode,stream+'.log'),r[stream]||'');
 receipt.runs.push({mode,exit:r.status,signal:r.signal,error:r.error?.message||null});fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));
 assert.equal(r.status,0,r.error?.message||r.stdout+r.stderr);assert(!r.signal);assert.match(r.stdout,/graph repair ok \(\d+ checks, 0 skips\)/);
}
fs.writeFileSync(path.join(out,'real104-index-after.txt'),run('git',['ls-files','--stage'],real));assert.equal(sha(path.join(out,'real104-index-before.txt')),sha(path.join(out,'real104-index-after.txt')));
for(const [p,h]of Object.entries(sources))assert.equal(sha(path.join(repo,p)),h,'source changed during proof');
for(const p of ['real104.patch','real104-index-before.txt','real104-index-after.txt','source/stdout.log','source/stderr.log','embedded/stdout.log','embedded/stderr.log'])receipt.artifacts[p]=sha(path.join(out,p));receipt.ok=true;
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify({ok:true,runs:receipt.runs,skipped:0,evidence:out}));
