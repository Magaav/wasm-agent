const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe');
const out=process.argv[3]?path.resolve(process.argv[3]):fs.mkdtempSync(path.join(os.tmpdir(),'wa-provider-proof-'));
fs.mkdirSync(out,{recursive:true});
const clean=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_)/i.test(key)));
for(const embedded of [false,true]){
 const home=path.join(out,embedded?'embedded':'source');fs.mkdirSync(home,{recursive:true});
 const env={...clean,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(root,'scripts/test-provider-management.lua')};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
 const r=spawnSync(binary,['--db',path.join(home,'fixture.db')],{cwd:out,env,encoding:'utf8',timeout:60000,windowsHide:true});
 fs.writeFileSync(home+'/stdout',r.stdout);fs.writeFileSync(home+'/stderr',r.stderr);assert.equal(r.status,0,r.stdout+r.stderr);assert.match(r.stdout,/checks, 0 skips, 0 paid calls/);console.log((embedded?'embedded: ':'source: ')+r.stdout.trim());
}
console.log('Evidence: '+out);
