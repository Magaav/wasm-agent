import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createWhatsAppAdapter} from './mcp-whatsapp.mjs';
import {bytePage} from './fixtures/whatsapp-byte-envelope.mjs';

test('navigation narrows operator-wide and delegated scopes before SQL; filters forwarded; foreign response refused',async()=>{
 const root=mkdtempSync(join(tmpdir(),'wa-nav-'));const token_file=join(root,'token');writeFileSync(token_file,'a'.repeat(64));
 const cid='200@s.whatsapp.net';let last,foreign=false,calls=0;
 const server=http.createServer((req,res)=>{let body='';req.on('data',b=>body+=b);req.on('end',()=>{
  calls++;last=JSON.parse(body);
  res.end(bytePage({ok:true,account:last.account,generation:last.generation,messages:[{id:'fixture',conversation_id:foreign?'300@g.us':cid,cursor:1}],conversations:[],posts:[],cursor_version:1,limit_scope:'total',scope_kind:last.account_wide?'account':'selected',source_state:{connection:'connected'},next_before:0}));
 });});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const b={backend:'linked_device',account:'100@s.whatsapp.net',generation:1,account_wide:true,operator_account_read:true,allowed_conversations:[],token_file,connector_url:`http://127.0.0.1:${server.address().port}`};
 try{
  const call=createWhatsAppAdapter(b);
  await call('read_snapshot',{conversation_id:cid,query:'orçamento',sent_since:100,until:200,limit:5});
  assert.deepEqual(last.conversations,[cid]);assert.equal(last.account_wide,undefined);assert.equal(last.query,'orçamento');assert.equal(last.sent_since,100);assert.equal(last.until,200);
  const narrow=createWhatsAppAdapter({...b,account_wide:false,operator_account_read:false,allowed_conversations:[cid,'400@lid']});
  await narrow('read_snapshot',{conversation_id:cid,query:'literal %_'});assert.deepEqual(last.conversations,[cid]);
  const n=calls;await assert.rejects(narrow('read_snapshot',{conversation_id:'300@g.us'}),/not_bound/);assert.equal(calls,n);
  for(const args of [{query:'x'.repeat(257)},{sent_since:201,until:200},{conversation_id:''},{account_wide:true}])await assert.rejects(call('read_snapshot',args));assert.equal(calls,n);
  foreign=true;await assert.rejects(call('read_snapshot',{conversation_id:cid}),/scope_or_limit_mismatch/);
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(root,{recursive:true});}
});
