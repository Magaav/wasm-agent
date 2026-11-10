// The connector HTTP client that survived the Node MCP bridge (deleted 10/11/2026).
//
// Self-contained: it starts its own loopback server and writes its own token file, so it measures the
// real request the operator send path makes without a connector, an account or a network.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {endpoint,connectorRequest,readBinding} from './whatsapp-connector-http.mjs';

const TOKEN='a'.repeat(64);
const account='5511999999999@s.whatsapp.net';

// One bound profile in a temp dir; the token is a FILE, never a value in the binding.
function fixture(overrides={}){
 const dir=mkdtempSync(join(tmpdir(),'wa-connector-http-'));
 const token_file=join(dir,'api.token');writeFileSync(token_file,TOKEN+'\n');
 return {dir,token_file,binding:{backend:'linked_device',account,generation:1,allowed_conversations:[account],token_file,...overrides}};
}

// Every refusal the binding check must keep: a missing or widened scope never becomes a request.
test('a binding must name account, generation and exact scope',()=>{
 const {dir,binding}=fixture();const clean=(patch)=>({...binding,connector_url:'http://127.0.0.1:28787/',...patch});
 try{
  assert.equal(endpoint(clean({})).hostname,'127.0.0.1');
  for(const patch of [{backend:'chrome'},{account:undefined},{generation:0},{generation:1.5},{allowed_conversations:[]},{account_wide:true},{token_file:undefined}]){
   assert.throws(()=>endpoint(clean(patch)),/linked_device_account_generation_chat_binding_required|connector_token_file_required/,JSON.stringify(patch));
  }
  // Account-wide reads need BOTH flags: one flag alone is a widening nobody approved.
  assert.throws(()=>endpoint(clean({allowed_conversations:undefined,account_wide:true})),/linked_device_account_generation_chat_binding_required/);
  assert.equal(endpoint(clean({allowed_conversations:undefined,account_wide:true,operator_account_read:true})).hostname,'127.0.0.1');
 } finally { rmSync(dir,{recursive:true,force:true}); }
});

// A credential goes to loopback or to authenticated HTTPS, never to a URL that names a path or a user.
test('the connector URL cannot carry credentials, a path or plaintext remote traffic',()=>{
 const {dir,binding}=fixture();const at=(url)=>({...binding,connector_url:url});
 try{
  assert.equal(endpoint(at('https://approved.internal/')).protocol,'https:');
  for(const url of ['http://approved.internal/','http://127.0.0.1:28787/x','http://127.0.0.1:28787/?a=1','http://user:pass@127.0.0.1:28787/']){
   assert.throws(()=>endpoint(at(url)),/connector_url_must_not_contain_credentials_or_path|authenticated_https_required_for_remote_connector/,url);
  }
 } finally { rmSync(dir,{recursive:true,force:true}); }
});

// The real request: POST /<method>, Bearer token from the file, account and generation in the body.
test('one request carries the bound account and the file token, and never retries',async()=>{
 const seen=[];const server=http.createServer((request,response)=>{
  let body='';request.on('data',chunk=>body+=chunk);request.on('end',()=>{
   seen.push({url:request.url,authorization:request.headers.authorization,body:JSON.parse(body)});
   response.writeHead(200,{'Content-Type':'application/json'});response.end(JSON.stringify({ok:true}));
  });
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const {dir,binding}=fixture();
 try{
  const bound={...binding,connector_url:`http://127.0.0.1:${server.address().port}/`};
  assert.deepEqual(await connectorRequest(bound,'status',{extra:7}),{ok:true});
  assert.equal(seen.length,1,'exactly one request, no retry');
  assert.equal(seen[0].url,'/status');
  assert.equal(seen[0].authorization,'Bearer '+TOKEN);
  assert.deepEqual(seen[0].body,{account,generation:1,extra:7});
  // A token that is not the connector's 64 hex characters refuses before any socket is opened.
  writeFileSync(binding.token_file,'not-a-token\n');
  await assert.rejects(()=>connectorRequest(bound,'status'),/invalid_private_connector_token/);
  writeFileSync(binding.token_file,TOKEN);
  rmSync(binding.token_file);
  await assert.rejects(()=>connectorRequest(bound,'status'),/connector_credential_or_ca_unreadable/);
 } finally { rmSync(dir,{recursive:true,force:true});server.closeAllConnections();await new Promise(r=>server.close(r)); }
});

// A redirect is a refusal, not a follow: the credential must not travel to wherever it points.
test('a redirect is refused instead of followed',async()=>{
 const server=http.createServer((request,response)=>{response.writeHead(302,{Location:'http://127.0.0.1:1/'});response.end();});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const {dir,binding}=fixture();
 try{
  const bound={...binding,connector_url:`http://127.0.0.1:${server.address().port}/`};
  await assert.rejects(()=>connectorRequest(bound,'status'),/connector_redirect_refused/);
 } finally { rmSync(dir,{recursive:true,force:true});server.closeAllConnections();await new Promise(r=>server.close(r)); }
});

// The profile file is the only place a binding comes from, and it is never guessed. The environment wins
// over the profile - this process may itself be a node holding a real binding (WA_WHATSAPP_* are set in
// the node's own shell), so the test clears them and restores them, and checks each half explicitly.
test('a profile binds the account and the environment overrides it',()=>{
 const saved=Object.fromEntries(Object.entries(process.env).filter(([key])=>key.startsWith('WA_WHATSAPP_')));
 for(const key of Object.keys(process.env))if(key.startsWith('WA_WHATSAPP_'))delete process.env[key];
 const {dir,token_file}=fixture();
 const profile_file=join(dir,'profile.json');
 writeFileSync(profile_file,JSON.stringify({resources:{backend:'linked_device',account:undefined,generation:3,connector_url:'http://127.0.0.1:28787/',token_file,allowed_conversations:[account]}}));
 try{
  const fromProfile=readBinding({profile_file});
  assert.equal(fromProfile.generation,3);
  assert.equal(fromProfile.token_file,token_file);
  assert.deepEqual(fromProfile.allowed_conversations,[account]);
  process.env.WA_WHATSAPP_GENERATION='7';
  assert.equal(readBinding({profile_file}).generation,7,'the environment names the binding when it sets it');
  assert.equal(readBinding({profile_file,account:'5511888888888@s.whatsapp.net'}).account,'5511888888888@s.whatsapp.net');
  // No profile, no account: the binding refuses downstream rather than discovering one.
  delete process.env.WA_WHATSAPP_GENERATION;
  const empty=readBinding({});
  assert.equal(empty.backend,'linked_device');
  assert.equal(empty.account,undefined);
  assert.throws(()=>endpoint(empty),/linked_device_account_generation_chat_binding_required/);
 } finally {
  for(const key of Object.keys(process.env))if(key.startsWith('WA_WHATSAPP_'))delete process.env[key];
  Object.assign(process.env,saved);
  rmSync(dir,{recursive:true,force:true});
 }
});
