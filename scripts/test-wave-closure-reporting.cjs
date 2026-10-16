// Private actual-agent provider fixture: source, standalone embedded, restart,
// baseline regression failure and possible model-echo duplication mechanism.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),[binArg,outArg]=process.argv.slice(2),binary=path.resolve(binArg),out=path.resolve(outArg);
assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const hash=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const files=['lua/core/agent.lua','lua/core/wave_autoflush.lua','scripts/test-wave-closure-reporting.lua','scripts/test-wave-closure-baseline.lua','scripts/test-wave-closure-reporting.cjs'];
const versions=Object.fromEntries(files.map(f=>[f,hash(repo+'/'+f)])),binaryHash=hash(binary);
const old=spawnSync('git',['show','d300a6b416af04324aefbf0a57f47d8fb507dc98:lua/core/agent.lua'],{cwd:repo,encoding:'utf8'});assert.equal(old.status,0);fs.writeFileSync(out+'/baseline-agent.lua',old.stdout);
const oldWave=spawnSync('git',['show','d300a6b416af04324aefbf0a57f47d8fb507dc98:lua/core/wave_autoflush.lua'],{cwd:repo,encoding:'utf8'});assert.equal(oldWave.status,0);fs.writeFileSync(out+'/baseline-wave.lua',oldWave.stdout);
const git=(cwd,...args)=>{const r=spawnSync('git',args,{cwd,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stdout+r.stderr);return r.stdout.trim();};
const main=out+'/native-main',own=out+'/native-own',install=out+'/native-install';fs.mkdirSync(main);fs.mkdirSync(install);
git(main,'init','-b','main');git(main,'config','user.name','private fixture');git(main,'config','user.email','fixture@invalid');fs.writeFileSync(main+'/private.txt','fixture\n');git(main,'add','.');git(main,'commit','-m','private baseline');git(main,'worktree','add','-b','change/private',own);
fs.writeFileSync(install+'/runtime-worktree.txt',main+'\n');
function run(name,embedded,extra={},dbName=name){
 const dir=out+'/'+name;fs.mkdirSync(dir);const dbDir=out+'/'+dbName;fs.mkdirSync(dbDir+'/home',{recursive:true});
 const env={...process.env,WASM_AGENT_HOME:dbDir+'/home',WASM_AGENT_LUA_ROOT:embedded?'':repo,WA_SCRIPT:repo+'/scripts/test-wave-closure-reporting.lua',WA_REPORT_FIXTURE:dbDir+'/fixture.json',WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',...extra};
 const r=spawnSync(binary,['--db',dbDir+'/private.db'],{cwd:embedded?dir:repo,env,encoding:'utf8',timeout:60000,windowsHide:true});
 for(const stream of ['stdout','stderr'])fs.writeFileSync(dir+'/'+stream,r[stream]||'');
 return {status:r.status,stdout:r.stdout||'',stderr:r.stderr||''};
}
const nativeNegative=run('native-negative',false,{WA_SCRIPT:repo+'/scripts/test-wave-closure-baseline.lua',WA_REPORT_OLD_AGENT:out+'/baseline-agent.lua',WA_REPORT_OLD_WAVE:out+'/baseline-wave.lua',WA_REPORT_MAIN:main,WA_REPORT_OWN:own,WA_INSTALL_DIR:install});assert.equal(nativeNegative.status,0,nativeNegative.stdout+nativeNegative.stderr);assert.match(nativeNegative.stdout,/wave_required_child_active/);
const negative=run('negative',false,{WA_REPORT_OLD_AGENT:out+'/baseline-agent.lua'});
assert.notEqual(negative.status,0);assert.match(negative.stderr+negative.stdout,/ordinary answer must not acquire raw closure suffix/);
const echo=run('echo-control',false,{WA_REPORT_OLD_AGENT:out+'/baseline-agent.lua',WA_REPORT_ECHO:'1'});assert.equal(echo.status,0,echo.stderr);assert.match(echo.stdout,/"markers":2/);
const reports=[];
for(const embedded of [false,true]){
 const name=embedded?'embedded':'source';const r=run(name,embedded);assert.equal(r.status,0,r.stdout+r.stderr);
 const restart=run(name+'-restart',embedded,{WA_REPORT_RESTART:out+'/'+name+'/fixture.json'},name);assert.equal(restart.status,0,restart.stdout+restart.stderr);
 reports.push({mode:name,result:JSON.parse(r.stdout.trim()),restart:JSON.parse(restart.stdout.trim()),stdout_sha256:hash(out+'/'+name+'/stdout')});
}
assert.equal(hash(binary),binaryHash);for(const[f,h]of Object.entries(versions))assert.equal(hash(repo+'/'+f),h);
const receipt={ok:true,binary_sha256:binaryHash,sources:versions,reports,negative_control:'exact old native lifecycle + actual agent reproduce raw active-child error; baseline actual agent fails clean-answer assertion',echo_control:'two markers with one finalize; possible mechanism only, historical cause unproven',paid_calls:0,live_installation:false,visual_ui_verified:false};
fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
