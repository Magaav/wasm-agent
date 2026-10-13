// Native socket/terminal regression, paired disk/embedded Lua and causal old-host failure.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),crypto=require('node:crypto');
const {spawn}=require('node:child_process'),assert=require('node:assert/strict');
const args=process.argv.slice(2),post=args[0]==='--post';if(post)args.shift();
const [binary,out,oldBinary]=args,repo=path.resolve(__dirname,'..');
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
assert(binary&&out&&path.isAbsolute(binary)&&path.isAbsolute(out));
if(post){
 const r=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));
 assert(r.ok&&r.skipped===0&&r.paid_calls===0);assert.equal(hash(binary),r.binary_sha256);
 for(const [p,h]of Object.entries(r.sources))assert.equal(hash(path.join(repo,p)),h);
 for(const [p,h]of Object.entries(r.logs))assert.equal(hash(path.join(out,p)),h);
 console.log(JSON.stringify({ok:true,checks:r.checks,skipped:0,verified:true}));process.exit(0);
}
assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const sources=Object.fromEntries(['lua/core/subscription_wire.lua','rust/wa-host/src/host.rs',
 'scripts/test-subscription-terminal.lua','scripts/test-subscription-terminal.cjs',
 'scripts/test-subscription-server-recovery.lua'].map(p=>[p,hash(path.join(repo,p))]));
const logs={},runs=[],sockets=new Set();let checks=0;
const frame=e=>'data: '+JSON.stringify(e)+'\n\n';
const body=frame({type:'response.output_item.added',output_index:0,item:{type:'message',id:'text',phase:'final_answer'}})+
 frame({type:'response.output_text.delta',output_index:0,delta:'Finished'})+
 frame({type:'response.output_item.done',output_index:0,item:{type:'message',id:'text',phase:'final_answer',content:[{type:'output_text',text:'Finished'}]}})+
 frame({type:'response.completed',response:{id:'fixture-response',status:'completed',usage:{input_tokens:1,output_tokens:1,total_tokens:2}}});
let retryRequests=0;const retryBodies=[];
const server=http.createServer((req,res)=>{
 let input='';req.on('data',d=>input+=d);req.on('end',()=>{if(req.url==='/retry')retryBodies.push(JSON.parse(input));});
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 if(req.url==='/direct'){res.end('first\n\nlast\n\n');return;}
 if(req.url==='/retry'&&++retryRequests%2===1){
  const item={type:'function_call',id:'discarded',call_id:'discarded',name:'write',arguments:'{"path":"must-not-execute"}'};
  res.write(frame({type:'response.output_item.added',output_index:0,item})+
   frame({type:'response.output_item.done',output_index:0,item})+
   frame({type:'keepalive',sequence_number:2}));
  setTimeout(()=>res.destroy(),40).unref();return;
 }
 res.write(body);if(req.url==='/reset')setTimeout(()=>res.destroy(),40).unref();
 // /held never ends: success must be determined from the response terminal.
});
server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});
async function execute(name,exe,script,embedded=false,luaRoot=repo){
 const home=path.join(out,name+'-home');fs.mkdirSync(home,{recursive:true});
 const env={...process.env};for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/.test(k))delete env[k];
 Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts',script),
  WA_TEST_SSE_URL:'http://127.0.0.1:'+server.address().port});
 if(!embedded)env.WASM_AGENT_LUA_ROOT=luaRoot;
 const r=await new Promise(resolve=>{
  const child=spawn(exe,['--db',path.join(home,'test.db')],{cwd:repo,env,windowsHide:true});
  let stdout='',stderr='';const timer=setTimeout(()=>child.kill(),20000);
  child.stdout.on('data',d=>stdout+=d);child.stderr.on('data',d=>stderr+=d);
  child.on('error',e=>stderr+=String(e));
  child.on('close',(status,signal)=>{clearTimeout(timer);resolve({status,signal,stdout,stderr});});
 });
 for(const stream of ['stdout','stderr']){const p=name+'.'+stream;fs.writeFileSync(path.join(out,p),r[stream]);logs[p]=hash(path.join(out,p));}
 return r;
}
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 try{
  for(const mode of ['disk','embedded'])for(const [label,script]of [['socket','test-subscription-terminal.lua'],['recovery','test-subscription-server-recovery.lua']]){
   const name=mode+'-'+label,r=await execute(name,binary,script,mode==='embedded');
   assert.equal(r.status,0,r.stdout+r.stderr);const m=/ok \((\d+) checks, 0 skipped/.exec(r.stdout);assert(m,'missing verdict');
   checks+=Number(m[1]);runs.push({name,checks:Number(m[1])});
  }
  assert.equal(retryRequests,4);assert.equal(retryBodies.length,4);
  assert.deepEqual(retryBodies[0],retryBodies[1]);assert.deepEqual(retryBodies[2],retryBodies[3]);checks++;
  if(oldBinary){
   const r=await execute('old-host-negative',oldBinary,'test-subscription-terminal.lua');
   assert.notEqual(r.status,0);assert.match(r.stderr,/explicit false stops successfully/);checks++;
   const root=path.join(out,'old-policy');fs.cpSync(path.join(repo,'lua'),path.join(root,'lua'),{recursive:true});
   const {spawnSync}=require('node:child_process');
   const original=spawnSync('git',['show','b50abf97709d8be0d1dca17f4868333eff3fb964:lua/core/subscription_wire.lua'],{cwd:repo,encoding:'utf8'});
   assert.equal(original.status,0);fs.writeFileSync(path.join(root,'lua/core/subscription_wire.lua'),original.stdout);
   const old=await execute('old-policy-negative',binary,'test-subscription-server-recovery.lua',false,root);
   assert.notEqual(old.status,0);assert.match(old.stderr,/subscription_retry_suppressed: subscription_transport_read_failed: Peer disconnected \(after 235 line\(s\)\)/);checks++;
  }
  for(const [p,h]of Object.entries(sources))assert.equal(hash(path.join(repo,p)),h);
  const receipt={ok:true,checks,skipped:0,paid_calls:0,binary_sha256:hash(binary),sources,logs,runs,
   negative_control:oldBinary?'old_host_and_old_policy_fail':null,gate_verified:false,release_verified:false};
  fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify(receipt));
 }finally{for(const s of sockets)s.destroy();server.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
