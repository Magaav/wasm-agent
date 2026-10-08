// Private paired source/embedded verification and causal old-policy negative control.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const args=process.argv.slice(2),post=args[0]==='--post';if(post)args.shift();const [binary,out]=args;
const repo=path.resolve(__dirname,'..'),hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
assert(binary&&out&&path.isAbsolute(binary)&&path.isAbsolute(out),'absolute binary/fresh evidence required');
if(post){const r=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(r.ok&&r.skipped===0);assert.equal(hash(binary),r.binary_sha256);for(const [p,h]of Object.entries(r.sources))assert.equal(hash(path.join(repo,p)),h);for(const [p,h]of Object.entries(r.logs))assert.equal(hash(path.join(out,p)),h);console.log(JSON.stringify({ok:true,verified:true,skipped:0,checks:r.checks,negative_control:r.negative_control}));process.exit(0);}
assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const sources=Object.fromEntries(['lua/core/openai_sub_bridge.lua','lua/core/openai_sub.lua','scripts/test-subscription-transport.cjs','scripts/test-subscription-empty-start.cjs'].map(p=>[p,hash(path.join(repo,p))]));
const logs={},runs=[];let checks=0;
function execute(name,args,cwd=repo){const r=spawnSync(process.execPath,args,{cwd,encoding:'utf8',timeout:120000,maxBuffer:4*1024*1024,windowsHide:true});for(const [stream,text]of [['stdout',r.stdout||''],['stderr',r.stderr||'']]){const p=name+'.'+stream;fs.writeFileSync(path.join(out,p),text);logs[p]=hash(path.join(out,p));}return r;}
for(const mode of ['disk','embedded']){const r=execute(mode,[path.join(repo,'scripts/test-subscription-transport.cjs'),out,binary,...(mode==='embedded'?['embedded']:[])]);assert.equal(r.status,0,r.stderr);const verdict=JSON.parse(r.stdout.trim().split('\n').at(-1));assert(verdict.ok&&verdict.skipped===0&&verdict.paid_calls===0);runs.push({mode,checks:verdict.checks});checks+=verdict.checks;}
// Restore only the old empty-start classification in a private tree. New assertions
// must fail on the first safe-replay positive case; no real adapter/model is used.
const mutant=path.join(out,'mutant');fs.mkdirSync(path.join(mutant,'scripts'),{recursive:true});fs.mkdirSync(path.join(mutant,'lua/core'),{recursive:true});
const current=fs.readFileSync(path.join(repo,'lua/core/openai_sub_bridge.lua'),'utf8');const anchor='    if(emptyItemStart(event)) {';assert.equal(current.split(anchor).length,2);
fs.writeFileSync(path.join(mutant,'lua/core/openai_sub_bridge.lua'),current.replace(anchor,'    if(false && emptyItemStart(event)) {'));
fs.copyFileSync(path.join(repo,'scripts/test-subscription-transport.cjs'),path.join(mutant,'scripts/test-subscription-transport.cjs'));
const negative=execute('negative',[path.join(mutant,'scripts/test-subscription-transport.cjs'),out],mutant);assert.notEqual(negative.status,0,'old-policy mutation incorrectly passed');assert((negative.stderr+negative.stdout).includes('model_output_seen=true'),'negative failed for unexpected cause');checks++;
for(const [p,h]of Object.entries(sources))assert.equal(hash(path.join(repo,p)),h,'source changed');
const receipt={ok:true,checks,skipped:0,paid_calls:0,negative_control:'old_empty_start_policy_fails',binary_sha256:hash(binary),sources,logs,runs,gate_verified:false,release_verified:false};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify(receipt));
