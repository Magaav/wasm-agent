// Real offline helper build in an explicit Windows Sentinel-like environment.
// No installer/CLI recovery is invoked. Existing run/provenance markers are preserved.
import fs from 'node:fs';import path from 'node:path';import cp from 'node:child_process';import crypto from 'node:crypto';import assert from 'node:assert/strict';import {fileURLToPath} from 'node:url';import {resolveRipgrep} from './codemode-build.mjs';
const post=process.argv[2]==='--post';const [root,assets,out]=process.argv.slice(post?3:2);assert([root,assets,out].every(p=>p&&path.isAbsolute(p)));const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
if(post){const r=JSON.parse(fs.readFileSync(out+'/receipt.json'));assert(r.ok);for(const [p,h]of Object.entries(r.hashes))assert.equal(sha(p),h,p);console.log(JSON.stringify({ok:true,post:true,binary_sha256:r.binary_sha256}));process.exit(0);}
assert.equal(process.platform,'win32','explicit Windows context proof');assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const hashes={};const keep=(name,b)=>{const p=out+'/'+name;fs.writeFileSync(p,b);hashes[p]=sha(p);};let receipt={ok:false,installed:false};
try{
 const where=path.join(process.env.SystemRoot,'System32/where.exe');
 const locate=name=>{const r=cp.spawnSync(where,[name],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim().split(/\r?\n/)[0];};
 const programs={cargo:locate('cargo'),git:locate('git'),bash:locate('bash'),node:process.execPath};
 const plain=[...new Set([...Object.values(programs).map(p=>path.dirname(p)),process.env.SystemRoot+'/System32',process.env.SystemRoot])].join(path.delimiter);
 const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>/^(SYSTEMROOT|WINDIR|SYSTEMDRIVE|COMSPEC|PATHEXT|TEMP|TMP|USERPROFILE|HOME|HOMEDRIVE|HOMEPATH|APPDATA|LOCALAPPDATA|PROCESSOR_ARCHITECTURE|NUMBER_OF_PROCESSORS|INCLUDE|LIB|LIBPATH|VCINSTALLDIR|VCToolsInstallDir|WindowsSdkDir|UCRTVersion|WASM_AGENT_IN_TURN|WASM_AGENT_PROVENANCE)$/i.test(k)));
 Object.assign(env,{PATH:plain,Path:plain,WASM_AGENT_HOME:out+'/private-home'});
 const missing=cp.spawnSync('rg',['--version'],{env,encoding:'utf8',windowsHide:true});assert.equal(missing.error?.code,'ENOENT','plain context must not inherit agent-only rg');
 const rg=resolveRipgrep();const local=env.WASM_AGENT_HOME+'/.wasm-agent/bin/rg.exe';fs.mkdirSync(path.dirname(local),{recursive:true});fs.copyFileSync(rg.path,local);assert.equal(sha(local),rg.sha256);
 const helper=root+'/scripts/codemode-build.mjs';
 const result=cp.spawnSync(programs.node,[helper,'build',root,'--assets',assets],{cwd:root,env,encoding:'utf8',windowsHide:true,timeout:1800000,maxBuffer:32*1024*1024});
 keep('helper.stdout',result.stdout||'');keep('helper.stderr',result.stderr||'');assert.equal(result.status,0,result.stderr||result.stdout||String(result.error));
 const build=JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));assert(build.ok&&build.ripgrep.sha256===rg.sha256&&build.runtime_ripgrep.sha256===rg.sha256);
 const stderr=fs.readFileSync(path.join(build.evidence,'embedded.stderr'),'utf8');assert(!/ripgrep missing; installing|ripgrep_unavailable:/.test(stderr),'no provisioning/download attempt');
 for(const name of ['receipt.json','cargo.stdout','cargo.stderr','embedded.stdout','embedded.stderr'])keep(name==='receipt.json'?'build-receipt.json':name,fs.readFileSync(path.join(build.evidence,name)));
 for(const p of [helper,root+'/scripts/check-embedded-runtime.lua',fileURLToPath(import.meta.url),build.binary,local])hashes[p]=sha(p);
 receipt={ok:true,installed:false,source_commit:build.source_commit,source_tree:build.source_tree,source_dirty:build.source_dirty,programs,plain_path:plain,rg_on_path:false,rg_source_sha256:rg.sha256,run_marker_preserved:env.WASM_AGENT_IN_TURN===process.env.WASM_AGENT_IN_TURN,child_marker_preserved:env.WASM_AGENT_PROVENANCE===process.env.WASM_AGENT_PROVENANCE,binary:build.binary,binary_sha256:build.binary_sha256,build_evidence:build.evidence};
}catch(e){receipt.error=String(e);process.exitCode=1;}
receipt.hashes=hashes;fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,hashes:undefined}));
