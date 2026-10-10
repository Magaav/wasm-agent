// Native child-marker refusals before any request/job/service effect. Private home only.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const binary=path.resolve(process.argv[2]||'rust/target/debug/wa-sentinel.exe'),root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-child-supervisor-'));
const env={...process.env};for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(key))delete env[key];
let checks=0;try{for(const args of [['request','deploy'],['request','run','--script','missing.cjs'],['job','enable','fake'],['start'],['protocol','bootstrap']]){
 const r=spawnSync(binary,args,{env:{...env,WASM_AGENT_HOME:root,WASM_AGENT_PROVENANCE:'child'},encoding:'utf8',windowsHide:true,timeout:10000});assert.notEqual(r.status,0);assert((r.stderr+r.stdout).includes('sentinel_coordinator_only'));assert.equal(fs.readdirSync(root).length,0);checks+=3;
}console.log(JSON.stringify({ok:true,checks,skipped:0,scope:'private-child-supervisor-denial'}));}finally{fs.rmSync(root,{recursive:true,force:true});}
