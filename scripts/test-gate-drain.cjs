// Regression derived from independent reviewer ctx_b0a97f34a6c0: a timed
// shell lost an intermediate parent while real detached work survived.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {spawn, spawnSync} = require('node:child_process');
const {DatabaseSync} = require('node:sqlite');
const os=require('node:os');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-gate-drain-'));
if(process.platform!=='win32'){console.log('gate drain: 1 skipped (native Windows descendant fixture)');process.exit(0);}
const source=path.resolve(__dirname,'..');
fs.mkdirSync(root,{recursive:true});
const lane = path.join(source, 'scripts/gate-lane.mjs');
const finish = path.join(source, 'skills/parallel-evolution/scripts/finish.mjs');
const state = path.join(root, 'drain-lane');
const work = path.join(root, 'drain-work');
const remote = path.join(root, 'drain-origin.git');
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sourceHashes = {lane: sha(lane), finish: sha(finish)};
const env = {...process.env, WA_GATE_LANE_DIR: state, GATE_LANE_HELD:'', GATE_LANE_ORIGIN:'',
  WA_GATE_LANE:'', WA_GATE_LANE_WAIT_SECONDS:'3', WA_GATE_LANE_SAMPLE_SECONDS:'0'};
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
function run(program, args, cwd = work) {
  const result = spawnSync(program, args, {cwd, env, encoding:'utf8', windowsHide:true, timeout:15000});
  if (result.error) throw result.error;
  return result;
}
function git(...args) { const r = run('git', args); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); }
function inspect() {
  const r=run(process.execPath,[lane,'inspect','--json']); assert.equal(r.status,0,r.stderr); return JSON.parse(r.stdout);
}
async function until(fn, ms=15000) {
  const end=Date.now()+ms;
  while(Date.now()<end) { const found=fn(); if(found) return found; await sleep(150); }
  throw Error('owned probe timed out');
}
function stopOwned(pid) {
  if (!alive(pid)) return;
  const r=spawnSync('taskkill',['/F','/T','/PID',String(pid)],{encoding:'utf8',windowsHide:true});
  if (r.status!==0 && alive(pid)) throw Error(r.stderr || r.stdout);
}
async function main() {
  fs.mkdirSync(path.join(work,'scripts'),{recursive:true});
  const survivor=path.join(root,'owned-survivor.cjs');
  const launcher=path.join(root,'owned-launcher.cjs');
  const preload=path.join(root,'short-timeout-preload.cjs');
  const pidFile=path.join(root,'owned-survivor.json');
  fs.writeFileSync(survivor, 'setTimeout(()=>{},60000);\n');
  fs.writeFileSync(launcher, `const {spawn}=require('node:child_process');const fs=require('node:fs');
const child=spawn(process.execPath,[${JSON.stringify(survivor)}],{detached:true,stdio:'ignore',windowsHide:true});
fs.writeFileSync(${JSON.stringify(pidFile)},JSON.stringify({pid:child.pid,launcher:process.pid,parent:process.ppid}));child.unref();\n`);
  fs.writeFileSync(preload, `const cp=require('node:child_process');const {syncBuiltinESMExports}=require('node:module');
const original=cp.spawnSync;cp.spawnSync=function(command,args,options){
if(String(command).endsWith('bash.exe')&&args?.[0]==='scripts/test.sh'){
console.error('probe seam: native gate-shell timeout 2500 ms instead of 3500000 ms');
return original(command,args,{...options,timeout:2500});}
return original(command,args,options);};syncBuiltinESMExports();
let held=false;process.on('beforeExit',()=>{if(!held){held=true;setTimeout(()=>{},9000);}});\n`);
  const sh = text => "'"+text.replaceAll('\\','/').replaceAll("'","'\\'''")+"'";
  // Keep only the shell alive after the launcher exits, with no extra direct
  // timer child that could conservatively hold the slot after timeout.
  fs.writeFileSync(path.join(work,'scripts/test.sh'), `node ${sh(launcher)}\nwhile :; do :; done\n`);
  git('init','-q','--bare',remote); git('init','-q','--initial-branch=main');
  git('config','core.autocrlf','false'); git('config','user.name','fixture');git('config','user.email','fixture@example.invalid');
  git('add','.');git('commit','-qm','private timed-shell fixture');git('remote','add','origin',remote);git('push','-q','-u','origin','main');
  git('switch','-q','-c','change/drain-probe');git('push','-q','-u','origin','change/drain-probe');
  const head=git('rev-parse','HEAD');
  const child=spawn(process.execPath,['--require',preload,finish,'gate',work,head],{cwd:source,env,windowsHide:true,stdio:['ignore','pipe','pipe']});
  let out='',err='';child.stdout.on('data',c=>out+=c);child.stderr.on('data',c=>err+=c);
  const done=new Promise(resolve=>child.once('close',code=>resolve(code)));
  let survivorRecord, row;
  try {
    survivorRecord=await until(()=>fs.existsSync(pidFile)&&JSON.parse(fs.readFileSync(pidFile,'utf8')));
    const result=await until(()=>{try{return JSON.parse(out.trim());}catch{return null;}});
    assert.equal(result.gate_verified,false);assert.match(result.gate_error,/ETIMEDOUT/);
    assert.match(err,/reservation retained pending process drain/);
    const before=inspect();row=before.held.find(r=>r.label==='finish change/drain-probe');
    assert.ok(row && alive(child.pid) && alive(survivorRecord.pid));
    console.log(`while owner is alive: slot ${row.id} running; owned surviving work ${survivorRecord.pid} alive`);
    const historyDb=new DatabaseSync(path.join(state,'lane.sqlite'),{readOnly:true});
    const snap1=JSON.stringify(historyDb.prepare('SELECT * FROM requests ORDER BY id').all());
    const hist1=JSON.stringify(historyDb.prepare('SELECT * FROM history ORDER BY id').all());
    inspect();
    assert.equal(JSON.stringify(historyDb.prepare('SELECT * FROM requests ORDER BY id').all()),snap1);
    assert.equal(JSON.stringify(historyDb.prepare('SELECT * FROM history ORDER BY id').all()),hist1);historyDb.close();
    console.log('independent inspect: request rows and history unchanged');
    const blocked=run(process.execPath,[lane,'acquire','--holder-pid',String(process.pid),'--no-wait']);
    assert.equal(blocked.status,75);console.log('no-wait contender refused while owner retains acquisition');
    const exit=await done;assert.equal(exit,0);
    await until(()=>!alive(child.pid));
    await sleep(3000);
    const after=inspect();
    const ended=[...after.held,...after.recent].find(r=>r.id===row.id);
    const survived=alive(survivorRecord.pid);
    const contender=run(process.execPath,[lane,'run','--no-wait','--json','--sample-seconds','0','--',process.execPath,'-e',"console.log('smoke ok (0 skipped)')"]);
    const admitted=contender.status===0;
    assert.equal(result.runner.path,finish);assert.equal(result.runner.sha256,sourceHashes.finish);assert.equal(result.runner.platform,'win32');
    assert.equal(result.gate_lane.runner.path,lane);assert.equal(result.gate_lane.runner.sha256,sourceHashes.lane);
    const evidence={runner:finish,sourceHashes,timeoutSeamMs:2500,owner:child.pid,survivor:survivorRecord,
      result,stderr:err,before,after,afterContender:inspect(),ended,survivorAlive:survived,
      survivorAliveAfterContender:alive(survivorRecord.pid),contenderStatus:contender.status,
      contenderStdout:contender.stdout,contenderReceipt:contender.stdout};
    fs.writeFileSync(path.join(root,'drain-evidence.json'),JSON.stringify(evidence,null,2)+'\n');
    console.log(`after timed shell and owner exit: slot ${row.id} ${ended.state}; surviving work alive=${survived}; next private command admitted=${admitted}`);
    if (admitted && survived && evidence.survivorAliveAfterContender) console.log('FALSIFIED: a new private command ran while timed-shell descendant remained alive');
    assert.ok(survived && !admitted && contender.status===75 && after.slots_held===1,
      'unsafe drain: a surviving descendant did not retain its reservation');
    assert.equal(ended.drain_required,1,'uncertain drain is durable');
    stopOwned(survivorRecord.pid);await until(()=>!alive(survivorRecord.pid));
    const drained=run(process.execPath,[lane,'reconcile','--id',String(row.id),'--evidence','owned fixture survivor '+survivorRecord.pid+' stopped and observed absent after owner exit']);
    assert.equal(drained.status,0,drained.stderr);
    const resumed=run(process.execPath,[lane,'run','--no-wait','--sample-seconds','0','--',process.execPath,'-e',"console.log('smoke ok (0 skipped)')"]);
    assert.equal(resumed.status,0,resumed.stderr);
    assert.deepEqual({lane:sha(lane),finish:sha(finish)},sourceHashes);
    console.log('timeout drain check ok: attempted free-slot falsification refused; source/lease runner identity verified; exact source unchanged');
  } finally {
    try {
      if(survivorRecord) stopOwned(survivorRecord.pid);
      if(alive(child.pid)) stopOwned(child.pid);
      if(row && alive(row.pid)) stopOwned(row.pid);
    } finally {
      // The minted family must not outlive the run: the two captured streams go to
      // this reporter's stderr where they survive, then the root is removed - even
      // when one of the stops above threw.
      process.stderr.write('[gate-drain] drain-finish.stdout\n'+out+'\n[gate-drain] drain-finish.stderr\n'+err+'\n');
      fs.rmSync(root,{recursive:true,force:true,maxRetries:5,retryDelay:200});
    }
  }
}
main().catch(error=>{console.error(error.stack);process.exitCode=1;});
