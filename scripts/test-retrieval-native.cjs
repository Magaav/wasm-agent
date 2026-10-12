'use strict';
// Source and embedded private processes, immutable evidence, no inference or installed writes.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const args=process.argv.slice(2),post=args[0]==='--post';if(post)args.shift();
if(args.length!==2||args.some(a=>!path.isAbsolute(a)))throw Error('usage: [--post] <absolute-built-wa> <fresh-evidence>');
const [binary,out]=args,repo=path.resolve(__dirname,'..'),sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const receiptPath=path.join(out,'receipt.json');
if(post){const r=JSON.parse(fs.readFileSync(receiptPath));if(!r.ok||r.binary_sha256!==sha(binary))throw Error('missing success/changed binary');for(const [p,h]of Object.entries(r.sources))if(sha(path.join(repo,p))!==h)throw Error('changed source '+p);for(const [p,h]of Object.entries(r.logs))if(sha(path.join(out,p))!==h)throw Error('changed evidence '+p);console.log(JSON.stringify({ok:true,post:true,runs:r.runs.length,skipped:0}));process.exit(0);}
if(fs.existsSync(out))throw Error('evidence already exists');fs.mkdirSync(out,{recursive:true});
const files=cp.execFileSync('git',['ls-files','--cached','--others','--exclude-standard','lua','rust/wa-graph','rust/wa-host/src','scripts/test-retrieval-native.cjs','scripts/test-tool-call-projection.lua','scripts/test-graph-automatic.lua','scripts/test-graph-freshness.lua','scripts/test-graph-tool.lua','scripts/test-graph-watch.lua','scripts/test-graph-index-failure.lua','scripts/test-session-view.lua'],{cwd:repo,encoding:'utf8'}).trim().split(/\r?\n/).filter(Boolean);
const r={ok:false,binary_sha256:sha(binary),sources:Object.fromEntries(files.map(p=>[p,sha(path.join(repo,p))])),logs:{},runs:[],skipped:0,gate_verified:false,release_verified:false};
const cases=[['test-tool-call-projection.lua','tool-call projection ok (18 checks;'],['test-graph-automatic.lua','graph automatic native ok (18 checks)'],['test-graph-freshness.lua','graph freshness ok'],['test-graph-tool.lua','graph tool ok'],['test-graph-watch.lua','graph external watch ok',{WA_GRAPH_WATCH:'1'}],['test-graph-index-failure.lua','graph failed index ok',{WA_GRAPH_PARSE_TIMEOUT_MS:'invalid'}],['test-session-view.lua','session view ok']];
try{
 for(const mode of ['source','embedded'])for(const [script,marker,overrides]of cases){
  const name=mode+'-'+script,home=path.join(out,name);fs.mkdirSync(home);
  const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(key)));
  Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts',script),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture'});if(mode==='source')env.WASM_AGENT_LUA_ROOT=repo;Object.assign(env,overrides||{});
  const result=cp.spawnSync(binary,['--db',path.join(home,'test.db')],{cwd:home,env,encoding:'utf8',windowsHide:true,timeout:180000,maxBuffer:8*1024*1024});
  for(const stream of ['stdout','stderr']){const p=name+'/'+stream+'.log';fs.writeFileSync(path.join(out,p),result[stream]||'');r.logs[p]=sha(path.join(out,p));}
  r.runs.push({mode,script,exit:result.status,signal:result.signal,error:result.error?.message,marker});
  if(result.error||result.status!==0||(result.stdout||'').split(marker).length!==2)throw Error(name+': '+(result.stderr||result.stdout||result.error?.message).slice(-2500));
 }
 for(const [p,h]of Object.entries(r.sources))if(sha(path.join(repo,p))!==h)throw Error('source changed during proof '+p);
 r.ok=true;
}catch(e){r.error=e.message;process.exitCode=1;}
fs.writeFileSync(receiptPath,JSON.stringify(r,null,2));console.log(JSON.stringify({...r,sources:undefined,logs:undefined,out}));
