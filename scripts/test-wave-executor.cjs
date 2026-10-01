// Real native operation driver in a private runtime home, with source Lua root.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2] || path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-wave-executor-')),home=path.join(root,'home'),cwd=path.join(root,'executor');
fs.mkdirSync(home);fs.mkdirSync(cwd);let checks=0,passed=false;
function drive(id,args) {
  const env={...process.env};for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key))delete env[key];
  Object.assign(env,{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:path.join(repo,'scripts/wave-executor.lua'),WA_WAVE_ID:'private-wave',WA_WAVE_OPERATION_ID:id,
    WA_WAVE_COMMAND:JSON.stringify({program:process.execPath,args,cwd,timeout_seconds:5}),WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture',WASM_AGENT_LLM_MODEL:'fixture',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0'});
  const result=spawnSync(binary,['--db',path.join(root,'memory.db')],{cwd:repo,env,encoding:'utf8',windowsHide:true,timeout:15000});
  assert.equal(result.status,0,result.stderr);return JSON.parse(result.stdout);
}
try{
  const good=drive('wave-op-good',['-e',"require('fs').writeFileSync('effect','once')"]);
  assert.equal(good.ok,true);checks++;assert.equal(good.settled,true);checks++;
  assert.equal(good.operation_id,'wave-op-good');checks++;assert.ok(good.native_operation_id.startsWith('op-'));checks++;
  assert.equal(fs.readFileSync(path.join(cwd,'effect'),'utf8'),'once');checks++;
  const state=JSON.parse(fs.readFileSync(path.join(home,'.wasm-agent','operations',good.native_operation_id,'state.json')));
  assert.equal(state.owner,'wave:private-wave:operation:wave-op-good');checks++;
  assert.equal(state.cwd.replaceAll('\\','/').toLowerCase(),cwd.replaceAll('\\','/').toLowerCase());checks++;
  assert.ok(state.owner_boot && state.owner_process_id);checks++;
  const failure=drive('wave-op-failed',['-e','process.exit(7)']);
  assert.equal(failure.ok,false);checks++;assert.equal(failure.settled,true);checks++;assert.equal(failure.code,7);checks++;
  passed=true;console.log(`wave executor ok (${checks} checks; real native children, private home, source Lua root, no inference)`);
}finally{if(passed)fs.rmSync(root,{recursive:true});else console.error(`wave executor fixture retained: ${root}`);}
