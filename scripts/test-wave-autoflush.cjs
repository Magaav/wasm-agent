// Private source/standalone-embedded native fixture; no Sentinel/provider effects.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),[binaryArg,outArg]=process.argv.slice(2);assert(binaryArg&&outArg);
const binary=path.resolve(binaryArg),out=path.resolve(outArg);assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const hash=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const sourceNames=['lua/core/agent.lua','lua/core/codemode.lua','lua/core/completions.lua','lua/core/hook_events.lua','lua/core/integrate.lua','lua/core/subagents.lua','lua/core/tools.lua','lua/core/update.lua','lua/core/wave_autoflush.lua','scripts/test-wave-autoflush.lua','scripts/test-wave-autoflush-restart.lua','scripts/test-wave-autoflush.cjs'];
const versions=Object.fromEntries(sourceNames.map(p=>[p,hash(repo+'/'+p)])),binaryVersion=hash(binary);
const git=(cwd,...a)=>{const r=spawnSync('git',a,{cwd,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stdout+r.stderr);return r.stdout.trim();};
const reports=[];
for(const embedded of (process.argv.includes('--source-only')?[false]:[false,true])){
 const dir=out+'/'+(embedded?'embedded':'source');fs.mkdirSync(dir);const main=dir+'/main',own=dir+'/own',remote=dir+'/remote.git',home=dir+'/home';fs.mkdirSync(home);
 git(dir,'init','--bare',remote);git(dir,'init','-b','main',main);git(main,'config','core.autocrlf','false');git(main,'config','user.name','private fixture');git(main,'config','user.email','fixture@invalid');
 fs.mkdirSync(main+'/scripts');fs.mkdirSync(main+'/lua');fs.writeFileSync(main+'/scripts/deploy-shipped.json',fs.readFileSync(repo+'/scripts/deploy-shipped.json'));fs.writeFileSync(main+'/lua/private.lua','-- baseline\n');git(main,'add','.');git(main,'commit','-m','baseline');git(main,'remote','add','origin',remote);git(main,'push','-u','origin','main');const base=git(main,'rev-parse','HEAD');
 git(main,'worktree','add','-b','change/wave-fixture',own,'origin/main');fs.writeFileSync(own+'/lua/private.lua','-- changed shipped source\n');git(own,'add','.');git(own,'commit','-m','private worker task','-m','Agent: wasm-agent role=child session=wave-child-1');const tip=git(own,'rev-parse','HEAD');
 const old=dir+'/old-agent.lua';fs.writeFileSync(old,git(repo,'show','acde06f016d27e4a29c644c5bea897ae53febf8c:lua/core/agent.lua'));
 // Preserve inherited provenance/run markers. Positive queue is a Lua FAKE, not
 // a real forbidden child Sentinel invocation. No live-home or job activation.
 const env={...process.env,WASM_AGENT_HOME:home,WA_SCRIPT:repo+'/scripts/test-wave-autoflush.lua',WASM_AGENT_LUA_ROOT:embedded?'':repo,WA_WAVE_MAIN:main,WA_WAVE_OWN:own,WA_WAVE_BASE:base,WA_WAVE_TIP:tip,WA_WAVE_OLD_AGENT:old,WA_WAVE_QUEUE:dir+'/fake-queue.json',WA_WAVE_RESTART:dir+'/restart.json',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0'};
 const r=spawnSync(binary,['--db',home+'/memory.db'],{cwd:embedded?dir:repo,env,encoding:'utf8',windowsHide:true,timeout:180000,maxBuffer:4*1024*1024});
 fs.writeFileSync(dir+'/stdout',r.stdout||'');fs.writeFileSync(dir+'/stderr',r.stderr||'');assert.equal(r.status,0,r.stdout+r.stderr);
 const restart=spawnSync(binary,['--db',home+'/memory.db'],{cwd:embedded?dir:repo,env:{...env,WA_SCRIPT:repo+'/scripts/test-wave-autoflush-restart.lua'},encoding:'utf8',windowsHide:true,timeout:60000});
 fs.writeFileSync(dir+'/restart.stdout',restart.stdout||'');fs.writeFileSync(dir+'/restart.stderr',restart.stderr||'');assert.equal(restart.status,0,restart.stdout+restart.stderr);assert(JSON.parse(restart.stdout.trim()).ok);
 const result=JSON.parse(r.stdout.trim().split(/\r?\n/).at(-1));assert(result.ok);assert.equal(git(main,'status','--porcelain'),'');assert.equal(git(own,'status','--porcelain'),'');reports.push({mode:embedded?'standalone embedded':'source',...result,stdout_sha256:hash(dir+'/stdout'),stderr_sha256:hash(dir+'/stderr')});
}
const receipt={ok:true,scope:'private native Git/SQLite actual agent + fake inference/queue',binary_sha256:hash(binary),sources:versions,source_sha256:hash(repo+'/lua/core/wave_autoflush.lua'),reports,live_installation:false,independent_review:false};
assert.equal(hash(binary),binaryVersion,'binary unchanged throughout proof');for(const [p,h]of Object.entries(versions))assert.equal(hash(repo+'/'+p),h,'source unchanged throughout proof: '+p);
fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
