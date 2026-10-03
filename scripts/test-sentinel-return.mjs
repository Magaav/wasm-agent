import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {classify,instructionBlock,reconcile} from './sentinel-return-hook.mjs';
const sha='a'.repeat(40),req={id:'fixture-1',expected_sha:sha,session:'busy-parent',queued_at:10};
const ack={...req,phase:'accepted',at:11};
assert.equal(classify(req,null,null,null,null,null,14999).phase,'queued');
assert.equal(classify(req,null,null,null,null,null,15000).phase,'unknown');
assert.equal(classify(req,ack,null,null,null,null,20000).phase,'accepted');
assert.equal(classify(req,ack,{...ack,phase:'spawned'},null,null,null,20000).phase,'updating');
const result={ok:true,request_id:req.id,expected_sha:sha,at:16,commit:sha};
const installed={commit:sha,at:15,source_provenance:'clean-built-by-deploy',record_role:'final'};
const verify={ok:true,request_id:req.id,expected_sha:sha,at:17};
assert.equal(classify(req,ack,ack,result,installed,verify,20000).phase,'verified');
for(const changed of [{...result,request_id:'other'},{...result,expected_sha:'b'.repeat(40)},{...result,at:undefined},{...result,at:9}])assert.equal(classify(req,ack,ack,changed,installed,verify,20000).phase,'unknown');
assert.equal(classify(req,ack,ack,result,{...installed,at:undefined},verify,20000).phase,'unknown');
assert.equal(classify(req,ack,ack,result,{...installed,source_provenance:'unverified-binary'},verify,20000).phase,'unknown');
assert.equal(classify(req,ack,ack,result,installed,null,20000).phase,'unknown');
assert.equal(classify(req,ack,ack,{...result,ok:false,detail:'syntax error'},null,null,20000).detail,'syntax error');
assert.match(instructionBlock({...req,phase:'failed',detail:'syntax error'}),/root cause/);
const home=fs.mkdtempSync(path.join(os.tmpdir(),'wa-return-'));
try{
 const dir=path.join(home,'.wasm-agent/sentinel/deploy-protocol',req.id);fs.mkdirSync(dir,{recursive:true});
 for(const [name,value] of [['intent',req],['ack',ack],['state',{...ack,phase:'spawned'}]])fs.writeFileSync(path.join(dir,`${name}.json`),JSON.stringify(value));
 const calls=path.join(home,'calls');
 // node's job argument is a private no-effect emitter, not a provider or installed supervisor.
 fs.writeFileSync(path.join(home,'job'),`require('fs').appendFileSync(${JSON.stringify(calls)},'emission\\n');console.log(JSON.stringify({queued:1}))`);
 process.env.WA_SENTINEL_BIN=process.execPath;
 const cwd=process.cwd();process.chdir(home);
 try{
 reconcile(home,home,20000);reconcile(home,home,29999);
 assert.equal(fs.readFileSync(calls,'utf8').trim().split('\n').length,1);
 reconcile(home,home,30000);reconcile(home,home,40000);
 assert.equal(fs.readFileSync(calls,'utf8').trim().split('\n').length,2);
 assert.equal(JSON.parse(fs.readFileSync(path.join(dir,'check.json'))).at,30000);
 }finally{process.chdir(cwd);}
}finally{fs.rmSync(home,{recursive:true,force:true});}
// Mutation-sensitive predicates: each deliberately broken decision must contradict an assertion.
const source=fs.readFileSync(new URL('./sentinel-return-hook.mjs',import.meta.url),'utf8');
let red=0;
for(const [from,to,check] of [
 ['now - stamp(request.queued_at) >= 5000','now - stamp(request.queued_at) >= 50000',m=>assert.equal(m.classify(req,null,null,null,null,null,15000).phase,'unknown')],
 ["result.request_id !== request.id","false",m=>assert.equal(m.classify(req,ack,ack,{...result,request_id:'other'},installed,verify,20000).phase,'unknown')],
 ["!validTime(installed.at)","false",m=>assert.equal(m.classify(req,ack,ack,result,{...installed,at:undefined},verify,20000).phase,'unknown')]
]){
 assert.ok(source.includes(from));
 const mutant=await import(`data:text/javascript;base64,${Buffer.from(source.replace(from,to)).toString('base64')}`);
 try{check(mutant);}catch(error){if(error.code==='ERR_ASSERTION')red++;else throw error;}
}
assert.equal(red,3,'all three mutations must be red');
console.log('sentinel return ok; mutation reds=3; skips=0; provider calls=0');
