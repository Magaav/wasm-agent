#!/usr/bin/env node
// Cross-platform isolated Lua/native integration; never touches a production database.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-efficiency-'));
const repo=path.resolve(__dirname,'..');
let bin=path.resolve(process.env.WA_BIN||path.join(repo,'rust/target/release',process.platform==='win32'?'wa.exe':'wa'));
if(process.platform==='win32'&&!fs.existsSync(bin)) bin+='.exe';
for(const mode of ['disk','embedded']) {
  const home=path.join(root,mode);fs.mkdirSync(home);
  const env={...process.env};
  for(const key of Object.keys(env)) if(/^(WA_|WASM_AGENT_)/.test(key)) delete env[key];
  Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:path.join(__dirname,'test-efficiency.lua')});
  if(mode==='disk') env.WASM_AGENT_LUA_ROOT=repo;
  const result=spawnSync(bin,['--db',path.join(home,'test.db')],{cwd:home,env,encoding:'utf8',timeout:60000,maxBuffer:1024*1024});
  fs.writeFileSync(path.join(home,'stdout.log'),result.stdout||'');fs.writeFileSync(path.join(home,'stderr.log'),result.stderr||'');
  console.log(mode+': '+(result.stdout||''));
  if(result.status!==0||!(result.stdout||'').includes('efficiency ok (')) {
    console.error(result.stderr||result.error?.message||'missing completion receipt');
    // The embedded half reads the Lua baked into the binary at build time, and it runs *after*
    // the disk half has already passed with the same script. So a failure here is the binary's
    // copy, not the change - and saying so is the difference between a rebuild and an hour spent
    // re-reading a diff that was right.
    if (mode === 'embedded') {
      let built = 'unknown';
      try { built = fs.statSync(bin).mtime.toISOString(); } catch { /* the message is worth less than the failure */ }
      console.error('the embedded Lua is baked into ' + bin + ' at build time; this binary is from ' + built + '.');
      console.error('the disk half passed with the same script, so this is the binary\'s copy of the Lua,');
      console.error('not the change: rebuild with cargo build --release --offline --manifest-path rust/Cargo.toml');
    }
    console.error('efficiency failure evidence: '+root);process.exitCode=1;break;
  }
}
if(!process.exitCode) fs.rmSync(root,{recursive:true});
