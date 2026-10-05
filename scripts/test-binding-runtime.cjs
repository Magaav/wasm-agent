const fs=require('fs'),os=require('os'),path=require('path'),assert=require('assert/strict'),{spawnSync}=require('child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/release/wa.exe');
const home=fs.mkdtempSync(path.join(os.tmpdir(),'wa-binding-runtime-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_)/i.test(k)));
Object.assign(env,{WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:root,WA_SCRIPT:path.join(root,'scripts/test-binding-runtime.lua')});
const r=spawnSync(binary,['status'],{cwd:home,env,encoding:'utf8',timeout:30000});fs.writeFileSync(path.join(home,'result.json'),JSON.stringify({code:r.status,stdout:r.stdout,stderr:r.stderr}));
console.log(r.stdout);console.log('evidence: '+home);assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/binding runtime ok \(16 checks, 0 skipped\)/);
