// Linked-device app boundary. No Chrome, discovery, arbitrary SQL or model-send route.
import {readFileSync} from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import {pathToFileURL} from 'node:url';
import {serveMCP} from './mcp-server-core.mjs';
const schema=properties=>({type:'object',properties,additionalProperties:false});
const text={type:'string',minLength:1,maxLength:256};
export const WHATSAPP_TOOLS=[
 {name:'read_snapshot',description:'Read the scoped linked-device journal; partial history, no read marking.',inputSchema:schema({since:{type:'number',minimum:0},before:{type:'integer',minimum:0},limit:{type:'integer',minimum:1,maximum:10000}})},
 {name:'lookup_self',description:'Read the explicitly bound paired account identity.',inputSchema:schema({})},
 {name:'inspect_chat',description:'Read exact chat scope; cross-device drafts are unsupported, not absent.',inputSchema:{...schema({conversation_id:text}),required:['conversation_id']}},
 {name:'download_audio',description:'Private media access is reserved to the deterministic connector worker.',inputSchema:{...schema({conversation_id:text,message_id:text}),required:['conversation_id','message_id']}},
 {name:'send_message',description:'General model sends fail closed: cross-device draft visibility is unsupported. Transcript posting is a separate explicitly activated deterministic policy.',inputSchema:{...schema({conversation_id:text,body:{type:'string',minLength:1,maxLength:4096},confirm:{type:'boolean',const:true}}),required:['conversation_id','body','confirm']}}
];
export function endpoint(binding){
 if(binding.backend!=='linked_device'||!binding.account||!Number.isSafeInteger(binding.generation)||binding.generation<1||!Array.isArray(binding.allowed_conversations)||!binding.allowed_conversations.length)throw Error('linked_device_account_generation_chat_binding_required');
 const url=new URL(binding.connector_url);
 if(url.username||url.password||url.search||url.hash||url.pathname!=='/')throw Error('connector_url_must_not_contain_credentials_or_path');
 if(url.protocol!=='https:'&&!(url.protocol==='http:'&&['127.0.0.1','[::1]'].includes(url.hostname)))throw Error('authenticated_https_required_for_remote_connector');
 if(typeof binding.token_file!=='string'||!binding.token_file)throw Error('connector_token_file_required');
 return url;
}
export async function connectorRequest(binding,method,args={}){
 const url=endpoint(binding);let token,ca;
 try{token=readFileSync(binding.token_file,'utf8').trim();if(binding.ca_file)ca=readFileSync(binding.ca_file);}catch{throw Error('connector_credential_or_ca_unreadable');}
 if(!/^[0-9a-f]{64}$/.test(token))throw Error('invalid_private_connector_token');
 const body=JSON.stringify({account:binding.account,generation:binding.generation,...args});
 return await new Promise((resolve,reject)=>{
  const request=(url.protocol==='https:'?https:http).request(new URL('/'+method,url),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)},...(ca?{ca}:{}),rejectUnauthorized:true,timeout:15000},response=>{
   let bytes=0;const parts=[];response.on('data',chunk=>{bytes+=chunk.length;if(bytes>24*1024*1024){response.destroy();reject(Error('connector_response_too_large'));}else parts.push(chunk);});response.on('end',()=>{if(response.statusCode>=300&&response.statusCode<400){reject(Error('connector_redirect_refused'));return;}try{resolve(JSON.parse(Buffer.concat(parts).toString('utf8')));}catch{reject(Error('connector_response_invalid'));}});response.on('error',()=>reject(Error('connector_response_failed')));
  });request.on('timeout',()=>request.destroy());request.on('error',()=>reject(Error('connector_transport_failed')));request.end(body);
 });
}
export function createWhatsAppAdapter(binding){
 return async(name,args)=>{
  endpoint(binding);const tool=WHATSAPP_TOOLS.find(t=>t.name===name);if(!tool||!args||typeof args!=='object'||Array.isArray(args))throw Error('invalid_whatsapp_mcp_call');
  for(const key of Object.keys(args))if(!(key in tool.inputSchema.properties))throw Error('unsupported_whatsapp_argument:'+key);
  for(const key of tool.inputSchema.required||[])if(args[key]===undefined)throw Error('whatsapp_argument_required:'+key);
  if(args.conversation_id&&!binding.allowed_conversations.includes(args.conversation_id))throw Error('whatsapp_conversation_not_bound');
  if(name==='send_message')return {ok:false,error:'general_send_refused_draft_visibility_unsupported',pre_dispatch:true};
  if(name==='download_audio')return {ok:false,error:'media_is_private_to_deterministic_worker',pre_dispatch:true};
  if(name==='read_snapshot'){
   const since=args.since??0,before=args.before??0,limit=args.limit??2000;if(!Number.isSafeInteger(before)||before<0||!Number.isSafeInteger(since)||since<0||!Number.isInteger(limit)||limit<1||limit>10000)throw Error('invalid_whatsapp_snapshot_window');
   // Query each authorized chat, never fetch unrelated chats then filter.
   const data={ok:true,account:binding.account,generation:binding.generation,messages:[],conversations:[],coverage:'partial',draft_visibility:'unsupported'};
   for(const conversation_id of binding.allowed_conversations){const part=await connectorRequest(binding,name,{conversation_id,since,before,limit});if(!part.ok)return part;if(part.account!==binding.account||part.generation!==binding.generation||(part.messages||[]).some(m=>m.conversation_id!==conversation_id)||(part.conversations||[]).some(c=>c.id!==conversation_id))throw Error('connector_response_scope_mismatch');data.messages.push(...part.messages);data.conversations.push(...part.conversations);if(part.truncated)data.truncated=true;}
   return data;
  }
  const data=await connectorRequest(binding,name,args);if(data.ok&&(data.account!==binding.account||data.generation!==binding.generation))throw Error('connector_response_scope_mismatch');return data;
 };
}
export function main(argv=process.argv.slice(2)){
 const at=argv.indexOf('--binding-json');const explicit=at>=0?JSON.parse(argv[at+1]):{};
 const binding={backend:'linked_device',account:process.env.WA_MCP_WHATSAPP_ACCOUNT,generation:Number(process.env.WA_MCP_WHATSAPP_GENERATION),connector_url:process.env.WA_MCP_WHATSAPP_URL,token_file:process.env.WA_MCP_WHATSAPP_TOKEN_FILE,ca_file:process.env.WA_MCP_WHATSAPP_CA_FILE,...explicit};
 serveMCP({name:'wasm-agent-whatsapp',tools:WHATSAPP_TOOLS,call:createWhatsAppAdapter(binding)});
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href)try{main();}catch{console.error('whatsapp_connector_configuration_invalid');process.exitCode=1;}
