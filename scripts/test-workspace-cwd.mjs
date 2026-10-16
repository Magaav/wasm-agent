// Model-free actual-process proof; every generation, including failures, is retained.
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const post=process.argv[2]==='--post';
const [binary,out,oldBinary]=process.argv.slice(post?3:2);
assert(binary&&out&&path.isAbsolute(binary)&&path.isAbsolute(out),'absolute candidate and fresh evidence required');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const names=['lua/core/tools.lua','rust/wa-host/src/host.rs','rust/wa-host/src/operations.rs','rust/wa-operation/src/lib.rs','rust/wa-operation/src/index.rs','lua/core/codemode.lua','scripts/test-workspace-cwd.lua','scripts/test-workspace-cwd.mjs'];
const sources=names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))}));
const binaryHash=sha(fs.readFileSync(binary));
if(post){
 const receipt=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(receipt.ok);assert.equal(receipt.binary_sha256,binaryHash);assert.deepEqual(receipt.sources,sources);
 for(const file of receipt.logs)assert.equal(sha(fs.readFileSync(path.join(out,file.name))),file.sha256,'retained log drift');
 console.log(JSON.stringify({ok:true,retained_hashes:true,checks:receipt.results.filter(r=>!r.negative).reduce((n,r)=>n+r.summary.checks,0)}));
 process.exit(0);
}
assert(!fs.existsSync(out),'retain old generations');fs.mkdirSync(out,{recursive:true});
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|PI_|OPENAI_|ANTHROPIC_|OPENCODE_|HOME$|USERPROFILE$)/i.test(k)));
const results=[];
function git(root,...args){const r=cp.spawnSync('git',['-C',root,...args],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
function run(mode,exe,negative=false){
 const root=path.join(out,mode);fs.mkdirSync(root);const home=path.join(root,'home');fs.mkdirSync(home);
 const canonical=path.join(root,'canonical');fs.mkdirSync(canonical);
 git(canonical,'init');git(canonical,'config','user.name','private-cwd-fixture');git(canonical,'config','user.email','fixture@invalid');
 fs.writeFileSync(path.join(canonical,'sentinel.txt'),'canonical must stay clean\n');git(canonical,'add','.');git(canonical,'commit','-m','private baseline');git(canonical,'update-ref','refs/remotes/origin/main','HEAD');
 const before={head:git(canonical,'rev-parse','HEAD'),tree:git(canonical,'rev-parse','HEAD^{tree}'),sentinel:sha(fs.readFileSync(path.join(canonical,'sentinel.txt')))};
 const install=path.join(root,'install');fs.mkdirSync(install);fs.cpSync(path.join(repo,'scripts'),path.join(install,'scripts'),{recursive:true});fs.writeFileSync(path.join(install,'runtime-worktree.txt'),canonical+'\n');
 // HOME also isolates wa-operation's native store, not just Lua's WASM_AGENT_HOME.
 const oldSource=mode.startsWith('old-source');
 const sourceRoot=oldSource?path.join(root,'old-lua'):repo;
 if(oldSource){
  fs.mkdirSync(sourceRoot);fs.cpSync(path.join(repo,'lua'),path.join(sourceRoot,'lua'),{recursive:true});fs.cpSync(path.join(repo,'scripts'),path.join(sourceRoot,'scripts'),{recursive:true});
  fs.writeFileSync(path.join(sourceRoot,'lua/core/tools.lua'),git(repo,'show','29b7ce0dacf16c9cd8ac231483f29c20fc7e29f1:lua/core/tools.lua')+'\n');
 }
 const env={...clean,HOME:home,USERPROFILE:home,WASM_AGENT_HOME:home,WA_INSTALL_DIR:install,WA_CWD_SOURCE:canonical,WA_CWD_NEGATIVE_OPERATION:mode==='old-source-operation'?'1':'0',WA_SCRIPT:path.join(repo,'scripts/test-workspace-cwd.lua'),WA_GRAPH_WATCH:'0',WASM_AGENT_MANAGED:'0',WASM_AGENT_CODEMODE:'native',...(mode==='source'||oldSource?{WASM_AGENT_LUA_ROOT:sourceRoot}:{})};
 const r=cp.spawnSync(exe,['--db',path.join(home,'private.db')],{cwd:canonical,env,encoding:'utf8',windowsHide:true,timeout:120000,maxBuffer:8*1024*1024});
 for(const stream of ['stdout','stderr'])fs.writeFileSync(path.join(root,stream),r[stream]||'');
 let summary;try{summary=JSON.parse((r.stdout||'').trim().split(/\r?\n/).at(-1));}catch{}
 const after={head:git(canonical,'rev-parse','HEAD'),tree:git(canonical,'rev-parse','HEAD^{tree}'),sentinel:sha(fs.readFileSync(path.join(canonical,'sentinel.txt'))),status:git(canonical,'status','--porcelain')};
 const result={mode,negative,binary_sha256:sha(fs.readFileSync(exe)),exit:r.status,signal:r.signal,error:r.error?.message,summary,before,after};results.push(result);
 assert.deepEqual({...after,status:undefined},{...before,status:undefined},'canonical identity unchanged');assert.equal(after.status,'','private canonical remains clean');
 if(negative){assert.notEqual(r.status,0,'old binary must fail actual regression');assert.match(r.stderr||'',/native launcher attribution matches actual process|pwd and Git root match binding|operation actual process must start in bound workspace/,'negative must fail real cwd assertion, not setup');}
 else {assert.equal(r.status,0,(r.stderr||'')+'\n'+(r.stdout||''));assert(summary?.ok&&summary.checks>=50,'complete assertion verdict');}
}
let ok=false,error;
try{for(const mode of ['source','embedded'])run(mode,binary);for(const mode of ['old-source-foreground','old-source-operation'])run(mode,binary,true);if(oldBinary)run('old-embedded',oldBinary,true);assert.deepEqual(names.map(name=>({name,sha256:sha(fs.readFileSync(path.join(repo,name)))})),sources,'source drift');ok=true;}catch(e){error=String(e);console.error(e.stack);process.exitCode=1;}
finally{const logs=results.flatMap(r=>['stdout','stderr'].map(stream=>({name:r.mode+'/'+stream,sha256:sha(fs.readFileSync(path.join(out,r.mode,stream)))})));const receipt={ok,error,binary_sha256:binaryHash,sources,results,logs,paid_calls:0};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({ok,error,results,evidence:out}));}
