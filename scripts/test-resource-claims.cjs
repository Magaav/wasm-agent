const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {spawn,spawnSync}=require('node:child_process'),{once}=require('node:events');
const repo=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]);
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-resource-claims-')),ready=path.join(root,'ready');
const env={...process.env};
for(const key of Object.keys(env))if(/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key))delete env[key];
Object.assign(env,{WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',
  WA_SCRIPT:path.join(repo,'scripts/test-resource-claims.lua'),WA_RESOURCE_READY:ready});
let child,checks=0;
function run(mode){
  const result=spawnSync(binary,['--db',path.join(root,mode+'.db')],{cwd:repo,env:{...env,WA_RESOURCE_MODE:mode},encoding:'utf8',timeout:30000,windowsHide:true});
  fs.writeFileSync(path.join(root,mode+'.log'),String(result.stdout)+String(result.stderr));
  assert.equal(result.status,0,result.stderr||String(result.error));
  assert.ok(result.stdout.includes('resource claims '+mode+' ok'));checks+=(result.stdout.match(/^CHECK /gm)||[]).length;
}
(async()=>{try{
  const log=fs.openSync(path.join(root,'hold.log'),'w');
  child=spawn(binary,['--db',path.join(root,'hold.db')],{cwd:repo,env:{...env,WA_RESOURCE_MODE:'hold'},stdio:['ignore',log,log],windowsHide:true});fs.closeSync(log);
  for(let n=0;n<100&&!fs.existsSync(ready);n++)await new Promise(r=>setTimeout(r,50));
  assert.ok(fs.existsSync(ready),'owner must acquire before contention');checks+=2;
  run('contend');
  const exited=once(child,'exit');child.kill('SIGKILL');await exited;
  run('recover');
  console.log(`resource claims ok (${checks} checks, 0 skipped; separate processes, actual process death, mock client)`);
}catch(error){console.error(error.stack);process.exitCode=1;}finally{if(child&&child.exitCode===null&&child.signalCode===null)child.kill();console.log('evidence: '+root);}})();
