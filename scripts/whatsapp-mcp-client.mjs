// Compatibility clients and deterministic Jobs call the same MCP app adapter.
// The caller owns eligibility, cursor, approval, reservation and wakes.
import {readFileSync} from 'node:fs';
import {dirname,join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {requestMCP} from './mcp-client-core.mjs';
const directory=dirname(fileURLToPath(import.meta.url));
export function readBinding(explicit={}){
 const {profile_file,...values}=explicit;
 let profile={};const path=profile_file||process.env.WA_WHATSAPP_PROFILE||'';
 if(path)try{profile=JSON.parse(readFileSync(path,'utf8')).resources||{};}catch{/* Missing binding refuses below, never discovers another account. */}
 return {account:process.env.WA_WHATSAPP_ACCOUNT||profile.account,browser_endpoint:process.env.WA_WHATSAPP_BROWSER_ENDPOINT||profile.browser_endpoint,
  cache_dir:join(process.env.WASM_AGENT_HOME||tmpdir(),'mcp-whatsapp-cache'),...values};
}
export async function callApp(method,args,binding=readBinding()){
 if(!binding.account||!binding.browser_endpoint)return {ok:false,error:'whatsapp_account_page_binding_required'};
 const server={transport:'stdio',program:process.execPath,args:[join(directory,'mcp-whatsapp.mjs'),'--binding-json',JSON.stringify(binding)],timeout_seconds:120};
 const result=await requestMCP({action:'call',server,tool:method,arguments:args});
 if(result.error)return {ok:false,error:result.error,dispatch:method==='send_message'&&result.tool_call_issued?'mcp':undefined,outcome:result.outcome};
 const data=result.result?.structuredContent;
 if(data&&typeof data==='object'&&!Array.isArray(data))return data;
 return {ok:false,error:'whatsapp_mcp_result_unreadable',dispatch:method==='send_message'&&result.tool_call_issued?'mcp':undefined,outcome:'unknown'};
}
