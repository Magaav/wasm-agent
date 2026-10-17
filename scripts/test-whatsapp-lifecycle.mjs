import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const exec=promisify(execFile);
test('readiness requires explicit authenticated observation, not just local identity and socket-labelled connection',async()=>{
 const root=mkdtempSync(join(tmpdir(),'wa-lifecycle-'));let auth='not_authenticated';
 const server=http.createServer((req,res)=>{
  let body='';req.on('data',b=>body+=b);req.on('end',()=>{
   const r=JSON.parse(body);assert.equal(r.account,'100@s.whatsapp.net');
   res.setHeader('Content-Type','application/json');
   const value=req.url==='/lookup_self'?{ok:true,account:r.account,generation:1}:{ok:true,config:{account:r.account,generation:1,all_chats:true,language:'pt',requested_on:true},connection:'connected',source_state:{persistence_gap:false},unknown_sends:0,audio:{},...(auth==='absent'?{}:{session_observation:{authentication:auth}})};
   res.end(JSON.stringify(value));
  });
 });await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try{
  const token=join(root,'token'),profile=join(root,'profile');writeFileSync(token,'a'.repeat(64));
  writeFileSync(profile,JSON.stringify({resources:{backend:'linked_device',account:'100@s.whatsapp.net',generation:1,connector_url:`http://127.0.0.1:${server.address().port}`,token_file:token,account_wide:true,operator_account_read:true,allowed_conversations:[]}}));
  const env={...process.env};for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(k))delete env[k];
  for(const observation of ['not_authenticated','unobserved','absent','authenticated_event_observed']){
   auth=observation;let result;
   try{result=await exec(process.execPath,[resolve('scripts/whatsapp-readiness.mjs'),'--profile-file',profile],{env,timeout:10000});result.code=0;}catch(error){result=error;}
   const data=JSON.parse(result.stdout);assert.equal(data.checks.authenticated,observation==='authenticated_event_observed');assert.equal(data.ok,observation==='authenticated_event_observed');assert.equal(result.code,observation==='authenticated_event_observed'?0:1);
   assert.equal(result.stderr,'');
  }
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(root,{recursive:true});}
});
