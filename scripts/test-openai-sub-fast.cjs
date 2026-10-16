const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]);fs.mkdirSync(out);
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/i.test(k)));
const runs=[];const hash=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const sources=Object.fromEntries(['lua/core/agent.lua','lua/core/provider.lua','lua/core/state.lua','lua/core/server.lua','lua/core/openai_sub.lua','lua/core/openai_sub_fast_policy.lua','lua/core/subscription_wire.lua','lua/core/vault.lua','lua/core/openai_sub_auth.lua','rust/wa-host/src/serve.rs','scripts/test-openai-sub-fast.lua'].map(p=>[p,hash(root+'/'+p)]));
for(const embedded of [false,true]){
 const home=path.join(out,embedded?'embedded':'source');fs.mkdirSync(home);
 for(const phase of ['integration','restart','policy']){
  const env={...clean,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(root,'scripts/'+(phase==='policy'?'test-openai-sub-fast-stage1.lua':'test-openai-sub-fast.lua')),WA_FAST_RESTART:phase==='restart'?'1':'0'};
  if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
  const run=spawnSync(binary,['--db',home+'/test.db'],{cwd:out,env,encoding:'utf8',timeout:60000,windowsHide:true});
  const name=(embedded?'embedded':'source')+'-'+phase;
  fs.writeFileSync(out+'/'+name+'.stdout',run.stdout||'');fs.writeFileSync(out+'/'+name+'.stderr',run.stderr||'');
  runs.push({name,exit:run.status,signal:run.signal,stdout_sha256:hash(out+'/'+name+'.stdout'),stderr_sha256:hash(out+'/'+name+'.stderr')});
  fs.writeFileSync(out+'/receipt.json',JSON.stringify({binary,binary_sha256:hash(binary),root,sources,runs},null,2));
  process.stdout.write(name+': '+run.stdout);process.stderr.write(run.stderr||'');assert.equal(run.status,0);assert.match(run.stdout,/ok \([1-9][0-9]* checks/);
 }
}
console.log('Evidence: '+out);
