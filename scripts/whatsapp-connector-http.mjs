// The linked-device connector's HTTP client, and nothing else: the binding's validation, one POST to
// the loopback API, and the profile/env resolution the callers share.
//
// This module is what survived the Node MCP bridge (scripts/mcp-whatsapp.mjs, deleted 10/11). The
// bridge was two things: the MCP stdio server an operator registered as a connector, and this client.
// Only the client is still used - by the operator send path (scripts/whatsapp-operator.mjs, run by the
// node through lua/core/federation.lua) and by the read-only readiness check - so it lives here with
// the same refusals and the same limits, and the server half is gone.
//
// Every function takes the binding explicitly. There is no ambient account, no discovery and no
// fallback: a missing field refuses, it never guesses another account.
import {readFileSync} from 'node:fs';
import http from 'node:http';
import https from 'node:https';

// A binding is usable only when it names a linked-device account, its generation and its exact chat
// scope (or the explicitly granted account-wide read), and a token FILE - never a token value.
export function endpoint(binding){
 const wide=binding.account_wide===true&&binding.operator_account_read===true;
 if(binding.backend!=='linked_device'||!binding.account||!Number.isSafeInteger(binding.generation)||binding.generation<1||(!wide&&(!Array.isArray(binding.allowed_conversations)||!binding.allowed_conversations.length||binding.allowed_conversations.length>256))||(!wide&&binding.account_wide===true))throw Error('linked_device_account_generation_chat_binding_required');
 const url=new URL(binding.connector_url);
 if(url.username||url.password||url.search||url.hash||url.pathname!=='/')throw Error('connector_url_must_not_contain_credentials_or_path');
 if(url.protocol!=='https:'&&!(url.protocol==='http:'&&['127.0.0.1','[::1]'].includes(url.hostname)))throw Error('authenticated_https_required_for_remote_connector');
 if(typeof binding.token_file!=='string'||!binding.token_file)throw Error('connector_token_file_required');
 return url;
}

// One request, no retry, bounded by method: paged reads keep their 4 MiB page contract, a field chunk
// its 64 KiB, everything else 24 MiB. A redirect is refused rather than followed, so a credential is
// never sent somewhere the binding did not name.
export async function connectorRequest(binding,method,args={}){
 const url=endpoint(binding);let token,ca;
 try{token=readFileSync(binding.token_file,'utf8').trim();if(binding.ca_file)ca=readFileSync(binding.ca_file);}catch{throw Error('connector_credential_or_ca_unreadable');}
 if(!/^[0-9a-f]{64}$/.test(token))throw Error('invalid_private_connector_token');
 const paged=['read_snapshot','list_chats','posting_status'].includes(method);const responseLimit=paged?4*1024*1024:method==='read_field'?64*1024:24*1024*1024;
 const body=JSON.stringify({account:binding.account,generation:binding.generation,...args});
 return await new Promise((resolve,reject)=>{
  const request=(url.protocol==='https:'?https:http).request(new URL('/'+method,url),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)},...(ca?{ca}:{}),rejectUnauthorized:true,timeout:15000},response=>{
   let bytes=0;const parts=[];response.on('data',chunk=>{bytes+=chunk.length;if(bytes>responseLimit){response.destroy();reject(Error('connector_response_too_large'));}else parts.push(chunk);});response.on('end',()=>{if(response.statusCode>=300&&response.statusCode<400){reject(Error('connector_redirect_refused'));return;}try{const data=JSON.parse(Buffer.concat(parts).toString('utf8'));if(paged&&data.ok&&(data.page_version!==2||data.encoded_bytes!==bytes||data.byte_limit!==4*1024*1024)){reject(Error('connector_requires_byte_page_v2'));return;}resolve(data);}catch{reject(Error('connector_response_invalid'));}});response.on('error',()=>reject(Error('connector_response_failed')));
  });request.on('timeout',()=>request.destroy());request.on('error',()=>reject(Error('connector_transport_failed')));request.end(body);
 });
}

// The binding a profile file and the environment name. A missing file refuses below (the endpoint
// check), never discovers another account.
export function readBinding(explicit={}){
 const {profile_file,...values}=explicit;
 let profile={};const path=profile_file||process.env.WA_WHATSAPP_PROFILE||'';
 if(path)try{profile=JSON.parse(readFileSync(path,'utf8')).resources||{};}catch{/* Missing binding refuses below, never discovers another account. */}
 return {backend:'linked_device',account:process.env.WA_WHATSAPP_ACCOUNT||profile.account,
  generation:Number(process.env.WA_WHATSAPP_GENERATION||profile.generation),
  connector_url:process.env.WA_WHATSAPP_CONNECTOR_URL||profile.connector_url,
  token_file:process.env.WA_WHATSAPP_TOKEN_FILE||profile.token_file,
  ca_file:process.env.WA_WHATSAPP_CA_FILE||profile.ca_file,
  account_wide:profile.account_wide===true&&profile.operator_account_read===true,
  operator_account_read:profile.operator_account_read===true,
  allowed_conversations:profile.allowed_conversations,...values};
}
