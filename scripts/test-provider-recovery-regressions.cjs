// Focused synthetic source + standalone embedding regression runner. Never inherits provider credentials.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe'),out=process.argv[3]?path.resolve(process.argv[3]):fs.mkdtempSync(path.join(os.tmpdir(),'wa-provider-regressions-'));fs.mkdirSync(out,{recursive:true});
const clean=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/i.test(key)));
console.log('Evidence: '+out);
fs.mkdirSync(out+'/scripts/lib',{recursive:true});
for(const fixture of ['scripts/lib/openai-sub-auth-mock.mjs','scripts/openai-sub-auth-worker.lua'])fs.copyFileSync(root+'/'+fixture,out+'/'+fixture);
fs.mkdirSync(out+'/tests/fixtures/subscription',{recursive:true});
fs.copyFileSync(root+'/tests/fixtures/subscription/codex-context-error-sse.txt',out+'/tests/fixtures/subscription/codex-context-error-sse.txt');
const suites=['test-provider-management.lua','test-native-subscription.lua','test-openai-sub-auth.lua','test-vault-routing.lua','test-native-disconnect-recovery.lua','test-subscription-server-recovery.lua','test-native-overflow-recovery.lua'];
let runs=0;
for(const embedded of [false,true])for(const script of suites){
 const home=path.join(out,(embedded?'embedded-':'source-')+script);fs.mkdirSync(home,{recursive:true});
 const env={...clean,WASM_AGENT_HOME:home,WASM_AGENT_BIN:binary,WA_SCRIPT:root+'/scripts/'+script};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
 const r=spawnSync(binary,['--db',home+'/fixture.db'],{cwd:out,env,encoding:'utf8',timeout:180000,windowsHide:true});fs.writeFileSync(home+'/stdout',r.stdout);fs.writeFileSync(home+'/stderr',r.stderr);console.log((embedded?'embedded ':'source ')+script+': '+r.status);if(r.status!==0)console.log((r.stdout+r.stderr).split(/\r?\n/).filter(line=>line.includes('FAIL')||line.includes('lua error:')).join('\n'));assert.equal(r.status,0,script);runs++;
}
for(const embedded of [false,true]){
 const home=path.join(out,embedded?'cli-embedded':'cli-source');fs.mkdirSync(home,{recursive:true});
 const env={...clean,WASM_AGENT_HOME:home,WASM_AGENT_OPENCODE_GO_VAULT_URL:'http://127.0.0.1:1',WASM_AGENT_OPENAI_SUB_VAULT_URL:'native'};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
 const r=spawnSync(binary,['--db',home+'/fixture.db','chat'],{cwd:out,env,input:'/provider\n\n/login\n\n/exit\n',encoding:'utf8',timeout:30000,windowsHide:true});fs.writeFileSync(home+'/stdout',r.stdout);fs.writeFileSync(home+'/stderr',r.stderr);assert.equal(r.status,0,r.stdout+r.stderr);assert.match(r.stdout,/OpenAI subscription/);assert.match(r.stdout,/OpenCode Go/);assert.match(r.stdout,/Cancelled; no changes/);assert.equal((r.stdout.match(/explicit selection and credential management/g)||[]).length,2,'provider and login alias both route without inference');assert.doesNotMatch(r.stdout,/paste.*API key/i);runs++;
 const nativeEnv={...env,WASM_AGENT_OPENAI_SUB_STORE:home+'/native/credentials.json',WASM_AGENT_PI_AUTH:home+'/missing-pi.json',WASM_AGENT_OPENAI_SUB_AUTH_BASE:'http://127.0.0.1:1'};
 for(const args of [['subscription','status'],['subscription','login','--browser']]){
  const result=spawnSync(binary,['--db',home+'/fixture.db',...args],{cwd:out,env:nativeEnv,encoding:'utf8',timeout:30000,windowsHide:true});
  fs.writeFileSync(home+'/'+args.at(-1)+'.stdout',result.stdout);fs.writeFileSync(home+'/'+args.at(-1)+'.stderr',result.stderr);
  assert.equal(result.status,0,result.stdout+result.stderr);assert.doesNotMatch(result.stdout+result.stderr,/embedded module missing/);
  if(args.at(-1)==='status')assert.match(result.stdout,/absent/);else assert.match(result.stdout,/waiting for the browser step/);runs++;
 }
}
console.log(JSON.stringify({process_runs:runs,paid_calls:0,evidence:out}));
