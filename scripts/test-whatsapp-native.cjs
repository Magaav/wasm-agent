'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),net=require('node:net'),crypto=require('node:crypto');
const [binary,connector,evidence]=process.argv.slice(2).map(v=>path.resolve(v));if(!evidence)throw Error('usage: <absolute-wa> <absolute-wa-whatsapp> <fresh-private-evidence>');
const repo=path.resolve(__dirname,'..'),hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
(async()=>{
 fs.mkdirSync(evidence);const state=path.join(evidence,'unpaired-state'),owners=path.join(evidence,'owners');
 const initialized=cp.spawnSync(connector,['init','--state',state,'--account','100@s.whatsapp.net','--all-chats'],{encoding:'utf8',timeout:10000});if(initialized.status!==0)throw Error('fixture initialization failed');
 const socket=net.createServer();await new Promise(r=>socket.listen(0,'127.0.0.1',r));const port=socket.address().port;await new Promise(r=>socket.close(r));const url=`http://127.0.0.1:${port}/`;
 const service=cp.spawn(connector,['serve','--state',state,'--owners',owners,'--listen',`127.0.0.1:${port}`],{stdio:['ignore','pipe','pipe']});let logs='';service.stdout.on('data',b=>logs+=b);service.stderr.on('data',b=>logs+=b);
 const receipt={ok:false,binary_sha256:hash(binary),connector_sha256:hash(connector),modes:[],gate_verified:false,release_verified:false};
 try{
  const token=fs.readFileSync(path.join(state,'api.token'),'utf8');let status;
  for(let i=0;i<80;i++){try{const response=await fetch(new URL('status',url),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({account:'100@s.whatsapp.net',generation:1})});status=await response.json();break;}catch{await new Promise(r=>setTimeout(r,50));}}
  if(status?.connection!=='needs_pairing'||status.config.requested_on!==false)throw Error('private unpaired service unavailable');
  for(const mode of ['source','embedded']){
   const home=path.join(evidence,mode);fs.mkdirSync(home);const env={...process.env};for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(key))delete env[key];Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-whatsapp-native.lua'),WA_MCP_SCRIPT_DIR:path.join(repo,'scripts'),WA_NODE:process.execPath,WA_TEST_CONNECTOR_URL:url,WA_TEST_CONNECTOR_TOKEN_FILE:path.join(state,'api.token')});if(mode==='source')env.WASM_AGENT_LUA_ROOT=repo;
   const run=cp.spawnSync(binary,['--db',path.join(home,'fixture.db')],{cwd:home,env,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(home,stream+'.log'),run[stream]||'');receipt.modes.push({mode,exit:run.status,signal:run.signal});if(run.status!==0||!run.stdout.includes('whatsapp native linked boundary ok (9 checks)'))throw Error(mode+' native boundary failed; inspect private evidence');
   env.WA_SCRIPT=path.join(repo,'tests/whatsapp-scoped.lua');const scoped=cp.spawnSync(binary,['--db',path.join(home,'scoped.db')],{cwd:home,env,encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(home,'scoped-'+stream+'.log'),scoped[stream]||'');if(scoped.status!==0||!scoped.stdout.includes('whatsapp scoped retirement ok (12 checks)'))throw Error(mode+' native scope negatives failed; inspect private evidence');
  }
  if(logs!=='')throw Error('unexpected unpaired service logging');receipt.ok=true;
 }catch(error){receipt.error=error.message;process.exitCode=1;}finally{
  if(service.exitCode===null)await new Promise(r=>{service.once('close',r);service.kill();});
  // Synthetic credentials/session fixture is private, never copied into retained evidence.
  fs.rmSync(state,{recursive:true,force:true});fs.rmSync(owners,{recursive:true,force:true});
  receipt.source_hashes=Object.fromEntries(['lua/core/whatsapp.lua','lua/core/mcp.lua','scripts/mcp-whatsapp.mjs','scripts/test-whatsapp-native.lua','scripts/test-whatsapp-native.cjs','tests/whatsapp-scoped.lua'].map(p=>[p,hash(path.join(repo,p))]));
  fs.writeFileSync(path.join(evidence,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
 }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
