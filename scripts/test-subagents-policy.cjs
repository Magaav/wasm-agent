// The policy fixture writes profiles. It MUST run with an isolated home, not just a scratch DB.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..');
const wa=path.resolve(process.argv[2]||path.join(repo,'rust/target/release/wa'+(process.platform==='win32'?'.exe':'')));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-subagent-policy-'));
const config=path.join(root,'.wasm-agent'),token=randomUUID();
fs.writeFileSync(path.join(root,'.subagent-policy-fixture'),token);
const system=/^(PATH|PATHEXT|SYSTEMROOT|WINDIR|SYSTEMDRIVE|COMSPEC|TEMP|TMP|PROCESSOR_ARCHITECTURE|NUMBER_OF_PROCESSORS)$/i;
const env={...Object.fromEntries(Object.entries(process.env).filter(([key])=>system.test(key))),
 HOME:root,USERPROFILE:root,LOCALAPPDATA:path.join(root,'LocalAppData'),APPDATA:path.join(root,'AppData'),
 WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WA_TEST_SUBAGENT_HOME:root,WA_TEST_SUBAGENT_TOKEN:token,
 WASM_AGENT_LLM_MODEL:'policy-fixture-unpriced',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only',
 HTTP_PROXY:'',HTTPS_PROXY:'',ALL_PROXY:'',NO_PROXY:'127.0.0.1,localhost,::1',
 WA_SCRIPT:path.join(repo,'scripts/test-subagents-profiles.lua')};
let checks=0;
function run(label,overrides={}){
 const result=spawnSync(wa,['--db',path.join(root,label+'.db')],{env:{...env,...overrides},encoding:'utf8',timeout:30000,windowsHide:true});
 fs.writeFileSync(path.join(root,label+'.log'),String(result.stdout||'')+String(result.stderr||'')+String(result.error||''));
 return result;
}
try{
 // Mutations are still isolated: proving the guard never risks the real home.
 for(const [label,overrides,reason] of [
  ['missing-marker',{WA_TEST_SUBAGENT_TOKEN:''},'policy_fixture_requires_isolated_wrapper'],
  ['wrong-home',{WA_TEST_SUBAGENT_HOME:path.join(root,'wrong')},'policy_fixture_home_mismatch'],
 ]){
  const result=run(label,overrides);
  assert.notEqual(result.status,0,label+' must fail');assert.ok(result.stderr.includes(reason),label+' must explain refusal');
  assert.ok(!fs.existsSync(path.join(config,'subagent-profiles')),label+' must not write profiles');checks++;
 }
 const result=run('policy');
 assert.equal(result.status,0,result.stderr||String(result.error));
 const count=Number(result.stdout.match(/^subagents profiles ok \((\d+) checks\)$/m)?.[1]);
 assert.ok(count>=59,'missing or dropped policy verdict');checks+=count;
 const tasks=path.join(config,'subagents');
 assert.ok(!fs.existsSync(tasks)||fs.readdirSync(tasks).length===0,'model-free policy must not admit a native child');checks++;
 fs.writeFileSync(path.join(root,'verdict.json'),JSON.stringify({suite:'test-subagents-policy',checks,failed:0,skipped:0,ok:true},null,2));
 console.log(result.stdout.trim());console.log(`isolated policy ok (${checks} checks, 0 skipped; system-only environment and no child admission)\nevidence: ${root}`);
}catch(error){console.error(error.stack);console.error('evidence: '+root);process.exitCode=1;}
