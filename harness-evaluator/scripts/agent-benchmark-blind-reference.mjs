// Pin the pre-task verification binary's embedded Lua, not an image tag guess.
// The generic probe is removed before any task bytes/model tool run is admitted.
import cp from 'node:child_process';import assert from 'node:assert/strict';import crypto from 'node:crypto';
export function verifyBlindReference(sandbox,repo){
 const ref=cp.spawnSync('git',['-C',repo,'rev-parse','1ab3024e2e8098718efae269d20bbe60181a4900^{commit}'],{encoding:'utf8',timeout:15000});assert(ref.status===0,'pre-task verification source missing');const source=ref.stdout.trim();
 const ancestry=cp.spawnSync('git',['-C',repo,'merge-base','--is-ancestor',source,'dc11c4626358438514624afa05c20bacb68cdbe7'],{timeout:15000});assert(ancestry.status===0,'verification source must precede task');
 const script="local j=assert(load(EMBEDDED['lua/vendor/json.lua']))();local rows={};for p,b in pairs(EMBEDDED)do rows[#rows+1]={path=p,sha256=host.sha256(b)}end;print(j.encode(rows))\n";
 sandbox.call('write_file',['.reference-probe.lua',script]);let output;
 try{const result=JSON.parse(sandbox.call('exec',['env WA_SCRIPT=/tmp/work/.reference-probe.lua WASM_AGENT_HOME=/tmp/.reference-probe /usr/local/bin/wa --db /tmp/.reference-probe.db','',30]));assert(result.code===0,'pre-task embedded probe failed');output=JSON.parse(result.stdout.trim());}
 finally{sandbox.call('exec',['rm -f -- /tmp/work/.reference-probe.lua','',10]);}
 const observed=Object.fromEntries(output.map(x=>[x.path,x.sha256]));const critical=['lua/core/tools.lua','lua/core/envelope.lua'];
 for(const p of critical){const r=cp.spawnSync('git',['-C',repo,'show',source+':'+p],{encoding:null,timeout:15000});if(r.status!==0){assert(!observed[p],'unexpected post-task reference module: '+p);continue;}const hash=crypto.createHash('sha256').update(r.stdout).digest('hex');assert(observed[p]===hash,'verification image Lua does not match pre-task source: '+p);}
 return {critical_lua_source:source,binary_source:null,critical:Object.fromEntries(critical.map(p=>[p,observed[p]??null])),embedded_modules:output.length,embedded_hashes:observed};
}
