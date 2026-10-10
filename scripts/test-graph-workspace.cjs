// Isolated deterministic runner. No inference, production profile, watcher or SCM effects.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const post=process.argv[2]==='--post',binary=path.resolve(process.argv[post?3:2]||''),out=path.resolve(process.argv[post?4:3]||'');
assert(process.argv[post?3:2] && process.argv[post?4:3],'usage: [--post] <source-built-wa> <fresh-evidence-directory>');
if(post){
 const receipt=JSON.parse(fs.readFileSync(path.join(out,'receipt.json'),'utf8'));
 assert(receipt.ok && receipt.checks===37 && receipt.skipped===0);assert.equal(receipt.binary_sha256,sha(binary));
 for(const [name,hash] of Object.entries(receipt.logs))assert.equal(sha(path.join(out,name)),hash);
 for(const [name,hash] of Object.entries(receipt.sources))assert.equal(sha(path.join(repo,name)),hash);
 console.log(JSON.stringify({ok:true,checks:37,skipped:0,evidence_verified:true}));process.exit(0);
}
assert(!fs.existsSync(out),'fresh evidence directory required');fs.mkdirSync(out,{recursive:true});
const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(key)));
const sources=Object.fromEntries(['lua/core/tools.lua','lua/core/graph.lua','lua/core/patch_audit.lua','scripts/test-graph-workspace.lua','rust/wa-host/src/graph.rs','rust/wa-graph/src/audit.rs'].map(name=>[name,sha(path.join(repo,name))]));
const home=path.join(out,'home');fs.mkdirSync(home);
Object.assign(env,{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:path.join(repo,'scripts/test-graph-workspace.lua'),
 WA_GRAPH_ROOT:path.join(home,'.wasm-agent/graph-workspace-fixture/canonical'),WA_GRAPH_WATCH:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0',
 WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only'});
const result=spawnSync(binary,['--db',path.join(home,'fixture.db')],{cwd:repo,env,encoding:'utf8',timeout:120000,maxBuffer:4*1024*1024,windowsHide:true});
fs.writeFileSync(path.join(out,'stdout.log'),result.stdout||'');fs.writeFileSync(path.join(out,'stderr.log'),result.stderr||'');
assert.equal(result.status,0,result.error?.message||result.stdout+result.stderr);assert(!result.signal);
assert((result.stdout||'').includes('graph workspace ok (37 checks)'),'missing complete fixture verdict');
for(const [name,hash] of Object.entries(sources))assert.equal(sha(path.join(repo,name)),hash,'source changed during fixture');
const receipt={ok:true,checks:37,skipped:0,exit:result.status,binary_sha256:sha(binary),sources,
 logs:Object.fromEntries(['stdout.log','stderr.log'].map(name=>[name,sha(path.join(out,name))])),evidence:out};
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({ok:true,checks:37,skipped:0,exit:result.status,evidence:out}));
