'use strict';
// Private source/embedded processes and retained hash postcheck; no live installation writes.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const args=process.argv.slice(2),sourceOnly=args[0]==='--source',post=args[0]==='--post';if(sourceOnly||post)args.shift();
assert(args.length===2&&args.every(path.isAbsolute),'usage: [--source|--post] <absolute-wa> <fresh-evidence>');
const [binary,out]=args,repo=path.resolve(__dirname,'..'),receiptFile=path.join(out,'receipt.json');
const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if(post){const r=JSON.parse(fs.readFileSync(receiptFile));assert(r.ok&&r.binary_sha256===sha(binary),'missing success/changed binary');for(const [p,h]of Object.entries(r.sources))assert.equal(sha(path.join(repo,p)),h,'changed source '+p);for(const [p,h]of Object.entries(r.logs))assert.equal(sha(path.join(out,p)),h,'changed evidence '+p);console.log(JSON.stringify({ok:true,post:true,runs:r.runs.length,checks:r.runs.map(v=>v.checks),skipped:0}));process.exit(0);}
assert(!fs.existsSync(out),'existing evidence; inspect instead of replay');fs.mkdirSync(out,{recursive:true});
const files=cp.execFileSync('git',['ls-files','--cached','--others','--exclude-standard','lua','scripts/test-skill-content.lua','scripts/test-skill-content.cjs'],{cwd:repo,encoding:'utf8'}).trim().split(/\r?\n/).filter(Boolean);
const r={ok:false,binary_sha256:sha(binary),sources:Object.fromEntries(files.map(p=>[p,sha(path.join(repo,p))])),logs:{},runs:[],skipped:0,gate_verified:false,release_verified:false};
try{for(const mode of sourceOnly?['source']:['source','embedded']){
 const home=path.join(out,mode);fs.mkdirSync(home);
 const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(key)));
 Object.assign(env,{SKILL_TEST_REPO:repo,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-skill-content.lua'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture'});if(mode==='source')env.WASM_AGENT_LUA_ROOT=repo;
 const p=cp.spawnSync(binary,['--db',path.join(home,'test.db')],{cwd:home,env,encoding:'utf8',windowsHide:true,timeout:60000,maxBuffer:8*1024*1024});
 for(const stream of ['stdout','stderr']){const file=mode+'/'+stream+'.log';fs.writeFileSync(path.join(out,file),p[stream]||'');r.logs[file]=sha(path.join(out,file));}
 const matches=[...(p.stdout||'').matchAll(/skill content ok \((\d+) checks; skipped0\)/g)];
 const checks=matches.length===1?Number(matches[0][1]):0;r.runs.push({mode,exit:p.status,signal:p.signal,error:p.error?.message,checks});
 assert(!p.error&&p.status===0&&checks===59,mode+': '+(p.stderr||p.stdout||p.error?.message).slice(-2500));
}for(const [p,h]of Object.entries(r.sources))assert.equal(sha(path.join(repo,p)),h,'changed source '+p);r.ok=true;}catch(e){r.error=e.message;process.exitCode=1;}
fs.writeFileSync(receiptFile,JSON.stringify(r,null,2));console.log(JSON.stringify({...r,sources:undefined,logs:undefined,out}));
