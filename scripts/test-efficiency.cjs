#!/usr/bin/env node
// Cross-platform isolated Lua/native integration; never touches a production database.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-efficiency-'));
const repo=path.resolve(__dirname,'..');
const env={...process.env};
for(const key of Object.keys(env)) if(/^(WA_|WASM_AGENT_)/.test(key)) delete env[key];
Object.assign(env,{WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:path.join(__dirname,'test-efficiency.lua')});
let bin=path.resolve(process.env.WA_BIN||path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
if(process.platform==='win32'&&!fs.existsSync(bin)) bin+='.exe';
const result=spawnSync(bin,['--db',path.join(root,'test.db')],{cwd:root,env,encoding:'utf8',timeout:60000,maxBuffer:1024*1024});
fs.writeFileSync(path.join(root,'stdout.log'),result.stdout||'');fs.writeFileSync(path.join(root,'stderr.log'),result.stderr||'');
console.log(result.stdout||'');
if(result.status!==0||!(result.stdout||'').includes('efficiency ok (')) {
  console.error(result.stderr||result.error?.message||'missing completion receipt');
  console.error('efficiency failure evidence: '+root);process.exitCode=1;
} else fs.rmSync(root,{recursive:true});
