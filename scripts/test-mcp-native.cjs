'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const args=process.argv.slice(2),sourceOnly=args[0]==='--source',post=args[0]==='--post';if(sourceOnly||post)args.shift();
if(args.length!==2)throw Error('usage: [--source|--post] test-mcp-native.cjs <absolute-wa> <fresh-evidence>');
const [binary,evidence]=args.map(v=>path.resolve(v)),repo=path.resolve(__dirname,'..'),receiptFile=path.join(evidence,'receipt.json');
const sources=['lua/core/envelope.lua','lua/core/mcp_session.lua','lua/core/web.lua','scripts/mcp-session.mjs','scripts/web-core.mjs','scripts/mcp-web.mjs','lua/vendor/json.lua','lua/core/mcp.lua','lua/core/tools.lua','lua/core/subagents.lua','lua/core/agent.lua','lua/core/whatsapp.lua','scripts/mcp-client.mjs','scripts/mcp-client-core.mjs','scripts/mcp-server-core.mjs','scripts/mcp-whatsapp.mjs','scripts/whatsapp-bound-identity.mjs','scripts/whatsapp-mcp-client.mjs','scripts/whatsapp-read.mjs','scripts/whatsapp-audio.mjs','scripts/whatsapp-store-send.mjs','scripts/fixtures/mcp-peer.mjs','scripts/test-mcp.lua','scripts/test-mcp-native.cjs'];
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if(post){const r=JSON.parse(fs.readFileSync(receiptFile));if(!r.ok||r.binary_sha256!==hash(binary))throw Error('missing success/changed binary');for(const [file,digest]of Object.entries(r.source_hashes))if(hash(path.join(repo,file))!==digest)throw Error('changed source: '+file);for(const [file,digest]of Object.entries(r.evidence_hashes))if(hash(path.join(evidence,file))!==digest)throw Error('changed evidence');console.log(JSON.stringify({ok:true,post:true,modes:r.modes}));process.exit(0);}
fs.mkdirSync(evidence,{recursive:false});const receipt={ok:false,binary,binary_sha256:hash(binary),source_hashes:Object.fromEntries(sources.map(f=>[f,hash(path.join(repo,f))])),evidence_hashes:{},modes:[],gate_verified:false,release_verified:false};
try{for(const mode of sourceOnly?['source']:['source','embedded']){
 const home=path.join(evidence,mode);fs.mkdirSync(home);const env={...process.env};for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(key))delete env[key];
 Object.assign(env,{WASM_AGENT_HOME:home,WA_SCRIPT:path.join(repo,'scripts/test-mcp.lua'),MCP_TEST_SOURCE:repo,WA_NODE:process.execPath,WA_MCP_SCRIPT_DIR:path.join(repo,'scripts')});if(mode==='source')env.WASM_AGENT_LUA_ROOT=repo;
 const r=cp.spawnSync(binary,['--db',path.join(home,'test.db')],{cwd:home,env,encoding:'utf8',timeout:120000,maxBuffer:8*1024*1024});
 for(const stream of ['stdout','stderr']){const file=mode+'/'+stream+'.log';fs.writeFileSync(path.join(evidence,file),r[stream]||'');receipt.evidence_hashes[file]=hash(path.join(evidence,file));}
 const matches=(r.stdout||'').match(/mcp native ok \((\d+) checks\)/g)||[],checks=matches.length===1?Number(matches[0].match(/\d+/)[0]):0;receipt.modes.push({mode,exit:r.status,signal:r.signal,checks});if(r.error||r.status!==0||checks<35)throw Error(mode+': '+(r.stderr||r.error?.message||'missing checks'));
}receipt.ok=true;}catch(error){receipt.error=String(error.message||error);process.exitCode=1;}
fs.writeFileSync(receiptFile,JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
