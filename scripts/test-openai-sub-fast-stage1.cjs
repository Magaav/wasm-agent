// Standalone source-root proof. No provider requests or account files.
const fs=require('node:fs'), path=require('node:path'), crypto=require('node:crypto');
const {spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..');
const [binaryArg,evidenceArg]=process.argv.slice(2);
if(!binaryArg||!evidenceArg) throw Error('usage: node scripts/test-openai-sub-fast-stage1.cjs <wa.exe> <fresh-evidence>');
const binary=path.resolve(binaryArg), evidence=path.resolve(evidenceArg);
fs.mkdirSync(evidence); // never overwrite prior evidence
const env={...process.env};
for(const key of Object.keys(env)) if(/^(WA_|WASM_AGENT_)/.test(key)) delete env[key];
Object.assign(env,{WASM_AGENT_LUA_ROOT:repo,WASM_AGENT_HOME:path.join(evidence,'home'),
  WA_SCRIPT:path.join(repo,'scripts/test-openai-sub-fast-stage1.lua'),
  WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:''});
fs.mkdirSync(env.WASM_AGENT_HOME);
const run=spawnSync(binary,['--db',path.join(evidence,'test.db')],{cwd:repo,env,encoding:'utf8',timeout:60000,windowsHide:true});
fs.writeFileSync(path.join(evidence,'stdout.txt'),run.stdout||'');
fs.writeFileSync(path.join(evidence,'stderr.txt'),run.stderr||'');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const files=['lua/core/openai_sub_fast_policy.lua','scripts/test-openai-sub-fast-stage1.lua',
 'lua/core/subscription_wire.lua','lua/core/openai_sub_catalogue.lua','lua/core/state.lua'];
const receipt={schema:1,source_root:repo,lua_root:env.WASM_AGENT_LUA_ROOT,binary,binary_sha256:hash(binary),
  exit:run.status,signal:run.signal,error:run.error?.message||null,embedded_tested:false,
  live_provider_tested:false,hashes:Object.fromEntries(files.map(file=>[file,hash(path.join(repo,file))])),
  stdout_sha256:hash(path.join(evidence,'stdout.txt')),stderr_sha256:hash(path.join(evidence,'stderr.txt'))};
fs.writeFileSync(path.join(evidence,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');
process.stdout.write(run.stdout||'');process.stderr.write(run.stderr||'');
if(run.status!==0 || !/openai-sub fast stage1 ok \(\d+ checks/.test(run.stdout||'')) process.exitCode=1;
