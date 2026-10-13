// Hash-bound source/embedded control-frame proof and causal pre-fix refusal.
'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const args=process.argv.slice(2),post=args[0]==='--post';if(post)args.shift();
assert.equal(args.length,2,'usage: [--post] test-subscription-keepalive.cjs <wa> <fresh-evidence>');
const [binary,out]=args.map(p=>path.resolve(p)),repo=path.resolve(__dirname,'..'),receipt=out+'/receipt.json';
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const files=['lua/core/subscription_wire.lua','scripts/test-subscription-keepalive.lua','scripts/test-subscription-keepalive.cjs','scripts/test-subscription-terminal.cjs','scripts/test-subscription-terminal.lua','scripts/test-subscription-server-recovery.lua'];
if(post){const r=JSON.parse(fs.readFileSync(receipt));assert(r.ok&&r.skipped===0&&r.paid_calls===0);for(const [p,h]of Object.entries(r.hashes))assert.equal(sha(p),h,p);console.log(JSON.stringify({ok:true,checks:r.checks,skipped:0,paid_calls:0,post:true}));process.exit(0);}
fs.mkdirSync(out);const r={ok:false,checks:0,skipped:0,paid_calls:0,gate_verified:false,release_verified:false,modes:[],hashes:Object.fromEntries([binary,...files.map(f=>repo+'/'+f)].map(p=>[p,sha(p)]))};
function execute(name,root){
 const home=out+'/'+name;fs.mkdirSync(home);
 const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
 Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:repo+'/scripts/test-subscription-keepalive.lua',WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0'});if(root)env.WASM_AGENT_LUA_ROOT=root;
 const child=cp.spawnSync(binary,['--db',home+'/private.db'],{cwd:repo,env,encoding:'utf8',windowsHide:true,timeout:20000,maxBuffer:8*1024*1024});
 for(const stream of ['stdout','stderr']){const p=home+'/'+stream+'.log';fs.writeFileSync(p,child[stream]||'');r.hashes[p]=sha(p);}return child;
}
try{
 for(const mode of ['source','embedded']){const c=execute(mode,mode==='source'?repo:null);assert.equal(c.status,0,c.stdout+c.stderr);const m=/subscription keepalive ok \((\d+) checks, 0 skipped/.exec(c.stdout);assert(m);r.checks+=Number(m[1]);r.modes.push({mode,status:0,checks:Number(m[1])});}
 const old=out+'/pre-fix';fs.cpSync(repo+'/lua',old+'/lua',{recursive:true});
 const captured=cp.spawnSync('git',['show','e6ceaa49f3eb2616790cb02a41c0b1234e8e131d:lua/core/subscription_wire.lua'],{cwd:repo,encoding:'utf8'});assert.equal(captured.status,0);fs.writeFileSync(old+'/lua/core/subscription_wire.lua',captured.stdout);r.hashes[old+'/lua/core/subscription_wire.lua']=sha(old+'/lua/core/subscription_wire.lua');
 const negative=execute('pre-fix-negative',old);assert.notEqual(negative.status,0);assert.match(negative.stderr,/known keepalive remains inference-only and retry-safe/);r.checks++;r.negative_control='exact_pre_fix_wire_fails_keepalive_safety';
 for(const [p,h]of Object.entries(r.hashes))assert.equal(sha(p),h,p);r.ok=true;
}catch(e){r.error=String(e);process.exitCode=1;}
fs.writeFileSync(receipt,JSON.stringify(r,null,2)+'\n');console.log(JSON.stringify({...r,hashes:undefined,out}));
