// Fixed private fixture: the policy/command choice remains in trusted Node/Lua.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process'),{once}=require('node:events'),{DatabaseSync}=require('node:sqlite');
const source=__filename,repo=path.resolve(__dirname,'..');
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
function envFor(root,binary,mode){
  const env={...process.env};
  for(const key of Object.keys(env))if(/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key))delete env[key];
  return {...env,WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:repo,WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',
    WA_SCRIPT:path.join(repo,'scripts/test-native-target-resource.lua'),WA_TARGET_MODE:mode,WA_TARGET_ROOT:root,
    WA_TARGET_BINARY:binary,WA_TARGET_EFFECT:source,WA_TARGET_EFFECT_SHA256:hash(fs.readFileSync(source))};
}
function run(root,binary,mode){
  const r=spawnSync(binary,['--db',path.join(root,mode+'.db')],{cwd:repo,env:envFor(root,binary,mode),encoding:'utf8',timeout:35000,windowsHide:true});
  fs.writeFileSync(path.join(root,mode+'.log'),String(r.stdout)+String(r.stderr));
  assert.equal(r.status,0,r.stderr||String(r.error));
  assert.ok(r.stdout.includes('native target '+mode+' ok'));
  return (r.stdout.match(/^CHECK /gm)||[]).length;
}
function git(root,...args){const r=spawnSync('git',['--git-dir',path.join(root,'git'),...args],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
function initialize(root){fs.mkdirSync(path.join(root,'git'));git(root,'init','--bare');}
if(process.argv[2]==='effect'){
  const root=process.argv[3],binary=process.argv[4],r=JSON.parse(fs.readFileSync(path.join(root,'receipt.json')));
  const rows=new DatabaseSync(path.join(root,'.wasm-agent/resources/claims.sqlite'),{readOnly:true});
  try{
    const claim=rows.prepare('SELECT * FROM claims WHERE key=?').get(r.key);
    assert.equal(claim.boot,r.boot); assert.equal(claim.run,r.run);
    const identity=JSON.parse(rows.prepare('SELECT identity FROM claim_identity WHERE key=? AND boot=?').get(r.key,r.boot).identity);
    assert.equal(identity.process_id,r.process_id);assert.equal(identity.creation_stamp,r.creation_stamp);
  }finally{rows.close();}
  if(process.platform==='win32'){
    const observed=spawnSync('powershell.exe',['-NoProfile','-Command',`(Get-Process -Id ${r.process_id}).StartTime.ToFileTimeUtc()`],{encoding:'utf8',windowsHide:true});
    assert.equal(observed.status,0,observed.stderr);
    assert.equal(r.creation_stamp,'windows-filetime:'+observed.stdout.trim());
  }else if(process.platform==='linux'){
    const stat=fs.readFileSync(`/proc/${r.process_id}/stat`,'utf8');
    const ticks=stat.slice(stat.lastIndexOf(')')+1).trim().split(/\s+/)[19];
    assert.equal(r.creation_stamp,`linux:${fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim()}:${ticks}`);
  }else throw Error('creation identity fixture unavailable');
  const lease=new DatabaseSync(path.join(root,'.wasm-agent/resources',`target-${r.key.slice(7)}.lease.sqlite`));
  try{assert.throws(()=>lease.exec('BEGIN EXCLUSIVE'),/locked|busy/);}finally{lease.close();}
  const checks=run(root,binary,'contend');
  const reservation=new DatabaseSync(path.join(root,'private-consumption.sqlite'));
  try{reservation.exec('CREATE TABLE consumed(receipt TEXT PRIMARY KEY); BEGIN IMMEDIATE');reservation.prepare('INSERT INTO consumed VALUES(?)').run(r.receipt_id);reservation.exec('COMMIT');}finally{reservation.close();}
  const tree=git(root,'mktree');
  const commit=git(root,'-c','user.name=Private Fixture','-c','user.email=fixture@invalid','commit-tree',tree,'-m','private held target effect');
  git(root,'update-ref','refs/heads/fixture',commit,'0000000000000000000000000000000000000000');
  assert.equal(git(root,'rev-parse','refs/heads/fixture'),commit);
  const held=new DatabaseSync(path.join(root,'.wasm-agent/resources',`target-${r.key.slice(7)}.lease.sqlite`));
  try{assert.throws(()=>held.exec('BEGIN EXCLUSIVE'),/locked|busy/);}finally{held.close();}
  fs.writeFileSync(path.join(root,'effect.json'),JSON.stringify({kind:'private-source-pinned-publication',source_sha256:hash(fs.readFileSync(source)),receipt:r,commit,competing_checks:checks,creation_stamp_observed:true,exclusion_before_and_after:true},null,2)+'\n');
  console.log('private external effect ok');
}else{
  const binary=path.resolve(process.argv[2]),evidence=fs.mkdtempSync(path.join(os.tmpdir(),'wa-native-target-evidence-'));
  const positive=path.join(evidence,'positive'),crash=path.join(evidence,'crash');fs.mkdirSync(positive);fs.mkdirSync(crash);
  initialize(positive);initialize(crash);
  let child,checks=0;
  (async()=>{try{
    checks+=run(positive,binary,'hold');
    checks+=JSON.parse(fs.readFileSync(path.join(positive,'effect.json'))).competing_checks;
    checks+=run(positive,binary,'forged');
    const log=fs.openSync(path.join(crash,'crash.log'),'w');
    child=spawn(binary,['--db',path.join(crash,'crash.db')],{cwd:repo,env:envFor(crash,binary,'crash'),stdio:['ignore',log,log],windowsHide:true});fs.closeSync(log);
    for(let n=0;n<150&&!fs.existsSync(path.join(crash,'ready'));n++)await new Promise(r=>setTimeout(r,50));
    assert.ok(fs.existsSync(path.join(crash,'ready')),'real owner must hold before crash');
    const receipt=JSON.parse(fs.readFileSync(path.join(crash,'receipt.json')));assert.equal(receipt.process_id,child.pid);
    const db=new DatabaseSync(path.join(crash,'.wasm-agent/resources/claims.sqlite'),{readOnly:true});
    const original=db.prepare('SELECT * FROM claims WHERE key=?').get(receipt.key);db.close();
    const exited=once(child,'exit');child.kill('SIGKILL');await exited;
    checks+=run(crash,binary,'restart');
    const after=new DatabaseSync(path.join(crash,'.wasm-agent/resources/claims.sqlite'),{readOnly:true});
    assert.deepEqual(after.prepare('SELECT * FROM claims WHERE key=?').get(receipt.key),original,'crash/restart preserves durable owner');after.close();
    const report={schema:1,kind:'private-native-target-capability-tests',binary,binary_sha256:hash(fs.readFileSync(binary)),
      source_sha256:hash(fs.readFileSync(source)),resources_sha256:hash(fs.readFileSync(path.join(repo,'rust/wa-host/src/resources.rs'))),
      lua_source_sha256:hash(fs.readFileSync(path.join(repo,'scripts/test-native-target-resource.lua'))),checks:checks+3,skipped:0,
      positive,crash,production_touched:false,independent_review:'required after delivery'};
    fs.writeFileSync(path.join(evidence,'report.json'),JSON.stringify(report,null,2)+'\n');
    console.log(`native target capability ok (${report.checks} checks, 0 skipped; actual processes, SQLite, creation stamps, private Git CAS)`);
  }catch(error){console.error(error.stack);process.exitCode=1;}finally{
    if(child&&child.exitCode===null&&child.signalCode===null){const exited=once(child,'exit');child.kill();await exited;}
    console.log('evidence: '+evidence);
  }})();
}
