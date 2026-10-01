// Real independent SQLite connections and processes; no inference or operator state.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const repo=path.resolve(__dirname,'..');
const binary=path.resolve(process.argv[2]||'rust/target/release/wa.exe');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-selection-state-'));
const children=[];
const base=Object.fromEntries(Object.entries(process.env).filter(([k])=>! /^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(k)));
function run(phase,extra={}) {
  const child=spawn(binary,['--db',path.join(root,'db.sqlite')],{cwd:repo,windowsHide:true,env:{...base,
    WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WASM_AGENT_MODELS_DEV_URL:'off',WASM_AGENT_LLM_API_KEY:'fixture',
    WA_SCRIPT:path.join(repo,'scripts/test-selection-state.lua'),WA_SELECTION_PHASE:phase,WA_SELECTION_FIXTURE:root,...extra}});
  children.push(child);
  return new Promise((resolve,reject)=>{
    let out='',err=''; const timer=setTimeout(()=>{child.kill();reject(new Error('fixture deadline '+phase));},15000);
    child.stdout.on('data',s=>out+=s);child.stderr.on('data',s=>err+=s);
    child.on('error',reject);child.on('exit',code=>{clearTimeout(timer);code===0?resolve(out.trim()):reject(new Error(phase+' '+code+' '+err+' '+out));});
  });
}
const parse=s=>JSON.parse(s.split(/\r?\n/).at(-1));
(async()=>{
  try {
    const init=parse(await run('init')); assert.equal(init.provider,'opencode-go');
    const held=run('hold');
    for(let i=0;!fs.existsSync(path.join(root,'pinned'));i++){assert.ok(i<200,'pin readiness');await new Promise(r=>setTimeout(r,20));}
    const switched=parse(await run('switch')); assert.equal(switched.model,'gpt-6.1-sol');
    fs.writeFileSync(path.join(root,'release'),'observed switch');assert.match(await held,/pin held/);
    const outcomes=await Promise.all(['gpt-6-sol','gpt-6-astra'].map(model=>run('cas',{WA_SELECTION_REVISION:String(switched.revision),WA_SELECTION_MODEL:model}).then(parse)));
    assert.equal(outcomes.filter(o=>o.ok).length,1,'exactly one racing CAS succeeds');
    assert.equal(outcomes.filter(o=>o.error==='settings_conflict').length,1,'loser refuses rather than overwriting');
    const observed=parse(await run('read'));
    assert.equal(observed.revision,switched.revision+1);assert.equal(observed.provider,'openai-sub');
    assert.ok(['gpt-6-sol','gpt-6-astra'].includes(observed.model));
    console.log('selection state ok (9 checks, 0 skipped; real concurrent processes, pinned run, version conflict)');
  } finally {
    await Promise.all(children.map(async c=>{
      if(c.exitCode!==null||c.signalCode!==null)return;
      await new Promise(resolve=>{const timer=setTimeout(resolve,3000);c.once('exit',()=>{clearTimeout(timer);resolve();});c.kill();});
    }));
    if(children.some(c=>c.exitCode===null&&c.signalCode===null))throw new Error('owned process drain unverified; evidence retained at '+root);
    assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir())+path.sep),'scratch deletion stays in temporary root');
    fs.rmSync(root,{recursive:true,force:true});
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
