// Source + standalone embedded role/report proof; no model calls or installed state.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'..'),[binArg,outArg]=process.argv.slice(2);assert(binArg&&outArg,'usage: <candidate-wa> <fresh-evidence>');const binary=path.resolve(binArg),out=path.resolve(outArg);assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const files=['AGENTS.subagents.md','AGENTS.orchestrator.md','AGENTS.md','AGENTS.guest.md','lua/core/agent.lua','scripts/test-evaluation-feedback.lua','scripts/test-evaluation-feedback.cjs'];
const receipt={ok:false,provider_calls:0,gate_verified:false,release_verified:false,runs:[],hashes:Object.fromEntries([binary,...files.map(p=>repo+'/'+p)].map(p=>[p,sha(p)]))};
for(const role of ['subagents','orchestrator']){
 const r=cp.spawnSync('git',['show','bd1c72ce90be6e5378f98fd2b0b971aa68e8f831:AGENTS.'+role+'.md'],{cwd:repo,encoding:'utf8'});assert.equal(r.status,0,r.stderr);fs.writeFileSync(out+'/old-'+role+'.md',r.stdout);receipt.hashes[out+'/old-'+role+'.md']=sha(out+'/old-'+role+'.md');
}
try{for(const mode of ['source','embedded']){
 const home=out+'/'+mode;fs.mkdirSync(home);const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
 Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:repo+'/scripts/test-evaluation-feedback.lua',WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',WA_EVAL_OLD_SUBAGENTS:out+'/old-subagents.md',WA_EVAL_OLD_ORCHESTRATOR:out+'/old-orchestrator.md',WA_EVAL_CAPTURE:home+'/capture.json'});if(mode==='source')env.WASM_AGENT_LUA_ROOT=repo;
 const r=cp.spawnSync(binary,['--db',home+'/private.db'],{cwd:mode==='source'?repo:home,env,encoding:'utf8',windowsHide:true,timeout:90000,maxBuffer:8388608});
 for(const s of ['stdout','stderr']){const p=home+'/'+s+'.log';fs.writeFileSync(p,r[s]||'');receipt.hashes[p]=sha(p);}assert.equal(r.status,0,r.stdout+r.stderr);
 const capture=home+'/capture.json',c=JSON.parse(fs.readFileSync(capture));receipt.hashes[capture]=sha(capture);assert(c.ok&&c.checks>30);assert.equal(c.provider_calls,0);
 for(const p of [c.worker_path,c.owner_path])assert.equal(p.startsWith('embedded:'),mode==='embedded',p);
 for(const role of ['worker','owner'])assert.equal(c[role],fs.readFileSync(repo+'/AGENTS.'+(role==='worker'?'subagents':'orchestrator')+'.md','utf8'));
 receipt.runs.push({mode,checks:c.checks,skipped:0,worker_path:c.worker_path,owner_path:c.owner_path});
}for(const [p,h]of Object.entries(receipt.hashes))assert.equal(sha(p),h,p);receipt.ok=true;
}catch(e){receipt.error=String(e);process.exitCode=1;}fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify(receipt));
