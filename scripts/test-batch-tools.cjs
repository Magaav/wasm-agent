'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const argv=process.argv.slice(2),post=argv[0]==='--post',sourceOnly=argv[0]==='--source';
if(post||sourceOnly)argv.shift();
if(argv.length!==2)throw Error('usage: [--source|--post] test-batch-tools.cjs <absolute-wa> <fresh-evidence>');
const [binary,evidence]=argv.map(p=>path.resolve(p)),repo=path.resolve(__dirname,'..');
const sources=['lua/core/batch_tools.lua','lua/core/file_tools.lua','lua/core/tools.lua','lua/core/workspaces.lua','lua/core/subagents.lua','lua/core/history_search.lua','lua/core/tool_output.lua','lua/core/agent.lua','lua/core/telemetry.lua','lua/core/cli_view.lua','scripts/test-batch-tools.lua','scripts/test-batch-tools.cjs'];
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const receiptPath=path.join(evidence,'receipt.json');
if(post){
 const r=JSON.parse(fs.readFileSync(receiptPath,'utf8'));
 if(!r.ok||r.binary_sha256!==hash(binary))throw Error('missing success or changed binary');
 for(const [name,digest] of Object.entries(r.source_hashes))if(hash(path.join(repo,name))!==digest)throw Error('changed source: '+name);
 for(const [name,digest] of Object.entries(r.evidence_hashes))if(hash(path.join(evidence,name))!==digest)throw Error('changed evidence: '+name);
 console.log(JSON.stringify({ok:true,post:true,modes:r.modes.map(m=>m.mode),checks:r.modes.reduce((n,m)=>n+m.checks,0)}));
 process.exit(0);
}
fs.mkdirSync(evidence,{recursive:false});
const receipt={ok:false,repo,binary,binary_sha256:hash(binary),source_hashes:Object.fromEntries(sources.map(p=>[p,hash(path.join(repo,p))])),evidence_hashes:{},modes:[],gate_verified:false,release_verified:false};
try{
 for(const mode of sourceOnly?['source']:['source','embedded']){
  const home=path.join(evidence,mode);fs.mkdirSync(home);
  const env={...process.env};for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(key))delete env[key];
  Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-batch-tools.lua')});
  if(mode==='source')env.WASM_AGENT_LUA_ROOT=repo;
  const result=cp.spawnSync(binary,['--db',path.join(home,'test.db')],{cwd:home,env,encoding:'utf8',timeout:120000,maxBuffer:8*1024*1024});
  fs.writeFileSync(path.join(home,'stdout.log'),result.stdout||'');fs.writeFileSync(path.join(home,'stderr.log'),result.stderr||'');
  for(const stream of ['stdout','stderr']){const name=mode+'/'+stream+'.log';receipt.evidence_hashes[name]=hash(path.join(evidence,name));}
  const verdict=(result.stdout||'').match(/batch tools ok \((\d+) checks\)/g)||[];
  const checks=verdict.length===1?Number(verdict[0].match(/\d+/)[0]):0;
  const measurement=(result.stdout||'').match(/^batch envelope measurement (.+)$/m);
  const taskMeasurement=(result.stdout||'').match(/^batch task measurement (.+)$/m);
  receipt.modes.push({mode,exit:result.status,signal:result.signal,checks,measurement:measurement?JSON.parse(measurement[1]):null,task_measurement:taskMeasurement?JSON.parse(taskMeasurement[1]):null});
  if(result.error||result.status!==0||checks<30)throw Error(mode+': '+(result.stderr||result.error?.message||'missing completion'));
 }
 receipt.ok=true;
}catch(error){receipt.error=String(error.message||error);process.exitCode=1;}
fs.writeFileSync(receiptPath,JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt,null,2));
