// The capability inventory has one source (`rust/wa-host/src/capabilities.rs`) and four surfaces.
// This proof checks two of them against each other, byte for byte: the CLI (`wa capabilities
// --json`) and the codemode sandbox (`capabilities()`/`describe()`), both read the registry's own
// JSON text, so their digests must be equal. Model-free: no provider, no network.
//
//   node scripts/test-capability-inventory.mjs <absolute-built-wa> <fresh-evidence-dir> [--post]
import fs from 'node:fs';import path from 'node:path';import cp from 'node:child_process';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const post=process.argv[2]==='--post';const [binary,out]=process.argv.slice(post?3:2);
assert(binary&&out&&path.isAbsolute(binary)&&path.isAbsolute(out),'usage: <absolute-binary> <fresh-evidence-dir> [--post]');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const names=['rust/wa-host/src/capabilities.rs','rust/wa-host/src/main.rs','rust/wa-host/src/serve.rs','lua/core/capability_inventory.lua','lua/core/codemode.lua','lua/core/init.lua','docs/HOST.md','scripts/test-capability-inventory.lua','scripts/test-capability-inventory.mjs'];
const sources=names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))}));
if(post){const r=JSON.parse(fs.readFileSync(out+'/receipt.json'));assert.equal(r.ok,true);assert.equal(sha(fs.readFileSync(binary)),r.binary_sha256);assert.deepEqual(r.sources,sources);for(const f of r.files)assert.equal(sha(fs.readFileSync(out+'/'+f.name)),f.sha256,f.name);console.log(JSON.stringify({ok:true,retained_hashes:true,results:r.results}));process.exit(0);}
assert(!fs.existsSync(out),'fresh evidence dir required: '+out);fs.mkdirSync(out,{recursive:true});
const files=[],results=[];let ok=false;const keep=(name,b)=>{const p=out+'/'+name;fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,b);files.push({name,sha256:sha(b)});};
for(const s of sources)keep('sources/'+s.name,fs.readFileSync(path.join(repo,s.name)));
// A private node: its own home, its own ledger, and none of the operator's environment.
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_)/i.test(k)));
try{
 const home=out+'/home';fs.mkdirSync(home);const bin=home+'/bin';fs.mkdirSync(bin);
 const rg=cp.spawnSync(process.platform==='win32'?'where.exe':'which',['rg'],{encoding:'utf8'});assert.equal(rg.status,0,'rg available for the private PATH');
 fs.copyFileSync(rg.stdout.trim().split(/\r?\n/)[0],bin+'/'+(process.platform==='win32'?'rg.exe':'rg'));
 const env={...clean,PATH:bin+(process.platform==='win32'?';'+clean.PATH:':'+clean.PATH),Path:bin+(process.platform==='win32'?';'+clean.Path:':'+clean.Path),WASM_AGENT_HOME:home,WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',WASM_AGENT_LUA_ROOT:repo};
 const run=(args,extra)=>{const r=cp.spawnSync(binary,['--db',home+'/private.db',...args],{cwd:home,env:{...env,...extra},encoding:'utf8',windowsHide:true,timeout:120000,maxBuffer:16*1024*1024});return r;};
 // 1. The CLI half: `--json` parses and lists every capability, with the three fields per entry.
 const cli=run(['capabilities','--json']);keep('capabilities.json',Buffer.from(cli.stdout||''));keep('capabilities.stderr',Buffer.from(cli.stderr||''));
 assert.equal(cli.status,0,'wa capabilities --json exits 0: '+cli.stderr);
 const text=cli.stdout.replace(/\r?\n$/,'');const list=JSON.parse(text);assert(Array.isArray(list)&&list.length>0,'the CLI answers a JSON array');
 for(const entry of list){for(const field of ['name','description','effect'])assert.equal(typeof entry[field],'string','every entry carries '+field);assert(['read-only','writes files','runs a process','network','device'].includes(entry.effect),'known effect class: '+entry.effect);}
 assert(new Set(list.map(e=>e.name)).size===list.length,'no capability is listed twice');
 results.push({surface:'cli --json',entries:list.length,bytes:Buffer.byteLength(text),sha256:sha(text)});
 // 2. The human form: same count, same digest, no JSON.
 const human=run(['capabilities']);keep('capabilities.txt',Buffer.from(human.stdout||''));
 assert.equal(human.status,0,'wa capabilities exits 0: '+human.stderr);
 assert(human.stdout.includes('('+list.length+' capabilities; sha256 '+sha(text)+')'),'the text form names the same count and digest');
 results.push({surface:'cli text',bytes:Buffer.byteLength(human.stdout),digest_line:true});
 // 3. The sandbox half, over the real QuickJS artifact, asserting the registry document unchanged.
 const lua=run([],{WA_SCRIPT:path.join(repo,'scripts/test-capability-inventory.lua')});keep('sandbox.stdout',Buffer.from(lua.stdout||''));keep('sandbox.stderr',Buffer.from(lua.stderr||''));
 let summary;try{summary=JSON.parse((lua.stdout||'').trim().split(/\r?\n/).at(-1));}catch{}
 assert.equal(lua.status,0,'the sandbox proof exits 0: '+(lua.stdout||'')+(lua.stderr||''));
 assert(summary&&summary.ok===true,'the sandbox proof reports ok: '+(lua.stdout||'')+(lua.stderr||''));
 // 4. Equality: the sandbox read the registry's own bytes, so the CLI's document IS the sandbox's.
 assert.equal(summary.sha256,sha(text),'sandbox capabilities() hashes the exact text `wa capabilities --json` prints');
 assert.equal(summary.bytes,Buffer.byteLength(text),'sandbox and CLI answer the same number of bytes');
 assert.equal(summary.count,list.length,'sandbox and CLI list the same number of capabilities');
 assert.equal(summary.backend,'rust-wasmtime-quickjs-wasi','the sandbox half ran in the real native VM');
 results.push({surface:'sandbox capabilities()/describe()',entries:summary.count,bytes:summary.bytes,checks:summary.checks,sha256:summary.sha256,backend:summary.backend,paid_calls:0});
 ok=true;
}catch(error){results.push({failure:String(error&&error.message||error)});process.exitCode=1;}
assert.deepEqual(sources,names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))})),'source drift during the proof');
const receipt={ok,results,sources,files,binary_sha256:sha(fs.readFileSync(binary)),paid_calls:0,gate_verified:false,release_verified:false};
fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));
console.log(JSON.stringify({ok,results,binary_sha256:receipt.binary_sha256}));
