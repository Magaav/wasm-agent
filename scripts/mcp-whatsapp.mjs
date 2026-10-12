// WhatsApp app capabilities, not Jobs. No trigger, cursor, eligibility or wake.
import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync,rmSync,mkdirSync} from 'node:fs';
import {dirname,join,resolve as resolvePath} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
import {serveMCP} from './mcp-server-core.mjs';
import {WebSocket} from './lib/websocket-runtime.mjs';
import {lookupExpression} from './whatsapp-reply-core.mjs';
import {accountMatches,parseEndpoint} from './whatsapp-store-core.mjs';
const directory=dirname(fileURLToPath(import.meta.url));
const object=value=>!!value&&typeof value==='object'&&!Array.isArray(value);
const schema=properties=>({type:'object',properties,additionalProperties:false});
const text={type:'string',minLength:1,maxLength:256};
export const WHATSAPP_TOOLS=[
 {name:'read_snapshot',description:'Read the bound account’s in-memory store. No eligibility, cursor advance, read marking or chat opening.',inputSchema:schema({since:{type:'number',minimum:0},limit:{type:'integer',minimum:1,maximum:10000}})},
 {name:'lookup_self',description:'Resolve notes-to-self using app-owned identity, never message direction.',inputSchema:schema({})},
 {name:'inspect_chat',description:'Inspect an exact chat’s metadata/draft presence without opening or changing it.',inputSchema:{...schema({conversation_id:text}),required:['conversation_id']}},
 {name:'download_audio',description:'Retrieve one exact audio message into the local media cache. Does not transcribe or schedule.',inputSchema:{...schema({conversation_id:text,message_id:text}),required:['conversation_id','message_id']}},
 {name:'send_message',description:'One verified app-store send. Requires a trusted local send binding, exact scope and an existing durable reservation; arguments cannot grant authority.',inputSchema:{...schema({conversation_id:text,body:{type:'string',minLength:1,maxLength:4096},confirm:{type:'boolean',const:true}}),required:['conversation_id','body','confirm']}}
];
async function page(endpoint,expression){
 const socket=new WebSocket(endpoint);let timer;
 try{
  await new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(Error('whatsapp_connect_timeout')),10000);socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',()=>reject(Error('whatsapp_connect_failed')),{once:true});});clearTimeout(timer);
  return await new Promise((resolve,reject)=>{
   timer=setTimeout(()=>reject(Error('whatsapp_read_timeout')),20000);
   socket.addEventListener('message',event=>{let frame;try{frame=JSON.parse(event.data)}catch{return;}if(frame.id!==1)return;
    if(frame.error||frame.result?.exceptionDetails){reject(Error('whatsapp_read_failed'));return;}
    try{resolve(JSON.parse(frame.result.result.value));}catch{reject(Error('whatsapp_read_result_unreadable'));}
   });socket.addEventListener('close',()=>reject(Error('whatsapp_read_eof')),{once:true});
   socket.send(JSON.stringify({id:1,method:'Runtime.evaluate',params:{expression,returnByValue:true,awaitPromise:true}}));
  });
 }finally{clearTimeout(timer);socket.close();}
}
async function backend(script,args){
 return await new Promise((resolve,reject)=>{
  const child=spawn(process.execPath,[resolvePath(directory,script),...args],{shell:false,windowsHide:true,stdio:['ignore','pipe','pipe']});let stdout='',bytes=0;
  child.stdout.on('data',chunk=>{bytes+=chunk.length;if(bytes>24*1024*1024){child.kill();reject(Error('whatsapp_backend_output_too_large'));}else stdout+=chunk.toString('utf8');});
  // stderr belongs to native operation evidence, never to a model instruction.
  child.stderr.on('data',chunk=>process.stderr.write(chunk));child.on('error',reject);
  child.on('close',()=>{try{const data=JSON.parse(stdout);if(!object(data))throw Error();resolve(data);}catch{reject(Error('whatsapp_backend_result_unreadable'));}});
 });
}
export function createWhatsAppAdapter(binding,driver){
 binding=binding||{};let sent=false;
 const bound=()=>{if(!binding.account||!parseEndpoint(binding.browser_endpoint))throw Error('whatsapp_account_page_binding_required');};
 const identity=async()=>{bound();const data=await (driver?.lookup?driver.lookup():page(binding.browser_endpoint,lookupExpression('',true)));
  if(!accountMatches(binding.account,data.account))throw Error('whatsapp_account_mismatch');return data;
 };
 const scope=conversation=>{if(Array.isArray(binding.allowed_conversations)&&!binding.allowed_conversations.includes(conversation))throw Error('whatsapp_conversation_not_bound');};
 return async function call(name,args){
  const tool=WHATSAPP_TOOLS.find(tool=>tool.name===name);if(!tool||!object(args))throw Error('invalid_whatsapp_mcp_call');
  for(const key of Object.keys(args))if(!(key in tool.inputSchema.properties))throw Error('unsupported_whatsapp_argument:'+key);
  for(const key of tool.inputSchema.required||[])if(args[key]===undefined)throw Error('whatsapp_argument_required:'+key);
  for(const key of ['conversation_id','message_id'])if(key in args&&(typeof args[key]!=='string'||!args[key]||args[key].length>256))throw Error('invalid_whatsapp_identity');
  if(args.conversation_id)scope(args.conversation_id);
  if(name==='send_message'){
   if(binding.allow_send!==true||typeof binding.reservation_key!=='string'||!binding.reservation_key||!Array.isArray(binding.allowed_conversations))throw Error('whatsapp_send_binding_required');
   if(args.confirm!==true||typeof args.body!=='string'||!args.body.trim()||Buffer.byteLength(args.body)>4096)throw Error('whatsapp_send_confirmation_body_required');
   if(sent)throw Error('whatsapp_mcp_send_already_dispatched');
  }
  const self=await identity();
  if(name==='lookup_self'){if(self.error)throw Error(self.error);return {ok:true,...self,browser_endpoint:binding.browser_endpoint};}
  if(name==='read_snapshot'){
   const since=args.since??0,limit=args.limit??2000;
   if(!Number.isFinite(since)||since<0||!Number.isInteger(limit)||limit<1||limit>10000)throw Error('invalid_whatsapp_snapshot_window');
   const endpoint=parseEndpoint(binding.browser_endpoint);
   const data=await (driver?.snapshot?driver.snapshot({since,limit}):backend('whatsapp-read.mjs',['--raw-store','--since',String(since),'--limit',String(limit),'--port',endpoint.port,'--expect-browser-endpoint',binding.browser_endpoint,'--expect-account',binding.account]));
   if(Array.isArray(binding.allowed_conversations)){
    data.conversations=(data.conversations||[]).filter(chat=>binding.allowed_conversations.includes(chat.id));
    data.messages=(data.messages||[]).filter(message=>binding.allowed_conversations.includes(message.conversation_id));
   }
   return data;
  }
  if(name==='inspect_chat'){
   const data=await (driver?.inspect?driver.inspect(args):backend('whatsapp-store-send.mjs',['--mcp-backend','--chat',args.conversation_id,'--expect-account',binding.account,'--expect-browser-endpoint',binding.browser_endpoint]));
   if(data.ok&&!accountMatches(binding.account,data.account))throw Error('whatsapp_account_mismatch');return data;
  }
  if(name==='download_audio'){
   if(typeof binding.cache_dir!=='string'||!binding.cache_dir||!binding.cache_dir.match(/^(?:[A-Za-z]:[\\/]|\/)/))throw Error('whatsapp_media_cache_unbound');
   mkdirSync(binding.cache_dir,{recursive:true,mode:0o700});const out=join(binding.cache_dir,randomUUID()+'.audio');
   const data=await (driver?.download?driver.download({...args,out}):backend('whatsapp-audio.mjs',['--mcp-backend','--message-id',args.message_id,'--chat',args.conversation_id,'--out',out,'--expect-browser-endpoint',binding.browser_endpoint,'--expect-account',binding.account]));
   return {...data,...(data.ok?{path:out}:{} )};
  }
  if(name==='send_message'){
   sent=true;let scratch;
   try{
    if(driver?.send)return await driver.send(args);
    if(binding.store_send_script && !resolvePath(binding.store_send_script).replaceAll('\\','/').endsWith('/whatsapp-store-send.mjs'))return {ok:false,error:'unsupported_whatsapp_store_script'};
    scratch=mkdtempSync(join(tmpdir(),'wa-mcp-body-'));const body=join(scratch,'body.txt');writeFileSync(body,args.body,{mode:0o600,flag:'wx'});
    return await backend(binding.store_send_script||'whatsapp-store-send.mjs',['--mcp-backend','--chat',args.conversation_id,'--body-file',body,'--expect-account',binding.account,'--expect-browser-endpoint',binding.browser_endpoint,'--send']);
   }catch(error){return {ok:false,error:String(error.message||error),dispatch:'mcp',outcome:'unknown'};}
   finally{if(scratch)try{rmSync(scratch,{recursive:true});}catch{process.stderr.write('mcp_body_cleanup_failed\n');}}
  }
  throw Error('unknown_whatsapp_mcp_tool');
 };
}
export function main(argv=process.argv.slice(2)){
 const envBinding={account:process.env.WA_MCP_WHATSAPP_ACCOUNT,browser_endpoint:process.env.WA_MCP_WHATSAPP_ENDPOINT,cache_dir:process.env.WA_MCP_WHATSAPP_CACHE};
 const at=argv.indexOf('--binding-json');const binding={...envBinding,...(at>=0?JSON.parse(argv[at+1]):{})};
 serveMCP({name:'wasm-agent-whatsapp',tools:WHATSAPP_TOOLS,call:createWhatsAppAdapter(binding)});
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href)try{main();}catch(error){console.error(String(error.message||error));process.exitCode=1;}
