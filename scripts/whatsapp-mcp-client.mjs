// Compatibility clients and deterministic Jobs call the same MCP app adapter.
// The caller owns eligibility, cursor, approval, reservation and wakes.
import {readFileSync} from 'node:fs';
import {dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {requestMCP} from './mcp-client-core.mjs';
const directory=dirname(fileURLToPath(import.meta.url));
export function readBinding(explicit={}){
 const {profile_file,...values}=explicit;
 let profile={};const path=profile_file||process.env.WA_WHATSAPP_PROFILE||'';
 if(path)try{profile=JSON.parse(readFileSync(path,'utf8')).resources||{};}catch{/* Missing binding refuses below, never discovers another account. */}
 return {backend:'linked_device',account:process.env.WA_WHATSAPP_ACCOUNT||profile.account,
  generation:Number(process.env.WA_WHATSAPP_GENERATION||profile.generation),
  connector_url:process.env.WA_WHATSAPP_CONNECTOR_URL||profile.connector_url,
  token_file:process.env.WA_WHATSAPP_TOKEN_FILE||profile.token_file,
  ca_file:process.env.WA_WHATSAPP_CA_FILE||profile.ca_file,
  allowed_conversations:profile.allowed_conversations,...values};
}
export async function callApp(method,args,binding=readBinding()){
 if(binding.backend!=='linked_device'||!binding.account||!binding.connector_url)return {ok:false,error:'linked_device_binding_required'};
 const server={transport:'stdio',program:process.execPath,args:[join(directory,'mcp-whatsapp.mjs'),'--binding-json',JSON.stringify(binding)],timeout_seconds:120};
 const result=await requestMCP({action:'call',server,tool:method,arguments:args});
 if(result.error)return {ok:false,error:result.error,dispatch:method==='send_message'&&result.tool_call_issued?'mcp':undefined,outcome:result.outcome};
 const data=result.result?.structuredContent;
 if(data&&typeof data==='object'&&!Array.isArray(data))return data;
 return {ok:false,error:'whatsapp_mcp_result_unreadable',dispatch:method==='send_message'&&result.tool_call_issued?'mcp':undefined,outcome:'unknown'};
}
