// Two real native managers and Lua's ordinary JSON encoder; no live runtime state.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const assert=require('node:assert/strict');
const {spawn,spawnSync}=require('node:child_process');
const {once}=require('node:events');
const repo=path.resolve(__dirname,'..');
const binary=path.resolve(process.argv[2]||path.join(repo,'rust/target/debug',process.platform==='win32'?'wa.exe':'wa'));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-operation-reconcile-json-'));
const env={...process.env};
for(const key of Object.keys(env))if(/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key))delete env[key];
Object.assign(env,{WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',
  WA_SCRIPT:path.join(repo,'scripts/test-operation-reconcile-json.lua'),WA_RECONCILE_JSON_ROOT:root});
let child,checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
function run(mode) {
  const r=spawnSync(binary,['--db',path.join(root,mode+'.db')],{cwd:repo,env:{...env,WA_RECONCILE_JSON_MODE:mode},encoding:'utf8',timeout:15000,windowsHide:true});
  fs.writeFileSync(path.join(root,mode+'.log'),String(r.stdout)+String(r.stderr));
  check(r.status===0,r.stderr||String(r.error));
  const result=JSON.parse(r.stdout.trim());
  check(result.ok===true&&result.mode===mode&&result.skipped===0,'native Lua result must identify actual mode/checks');
  checks+=result.checks;
}
(async()=>{try {
  const log=fs.openSync(path.join(root,'owner.log'),'w');
  child=spawn(binary,['--db',path.join(root,'owner.db')],{cwd:repo,env:{...env,WA_RECONCILE_JSON_MODE:'owner'},stdio:['ignore',log,log],windowsHide:true});
  fs.closeSync(log);
  for(let n=0;n<200&&!fs.existsSync(path.join(root,'ready.json'));n++) {
    assert.ok(child.exitCode===null&&child.signalCode===null,'owner exited before creating durable native state');
    await new Promise(resolve=>setTimeout(resolve,25));
  }
  check(fs.existsSync(path.join(root,'ready.json')),'owner must report before tests');
  run('live');
  const exited=once(child,'exit');
  fs.writeFileSync(path.join(root,'release'),'release exact private owner');
  const [code]=await exited;
  check(code===0,'private owner exits after command/lease ownership test');
  run('recover');
  console.log(JSON.stringify({ok:true,checks,skipped:0,scope:'operation-reconcile-json',full_release_gate:false}));
} catch(error) {
  console.error(error.stack);console.error('evidence: '+root);process.exitCode=1;
} finally {
  if(child&&child.exitCode===null&&child.signalCode===null) {
    const exited=once(child,'exit');child.kill();await exited;
  }
  if(!process.exitCode)fs.rmSync(root,{recursive:true,force:true});
}})();
