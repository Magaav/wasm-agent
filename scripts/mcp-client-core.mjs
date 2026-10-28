// MCP request-scoped connector. No model, scheduler, shell interpolation or retry.
import { spawn } from 'node:child_process';
import { TextDecoder } from 'node:util';
import { createHash, randomUUID } from 'node:crypto';

// 2025-03-26 is a published revision and the one mail-mcp answers with (measured 2026-10-28: it replies 2025-03-26 to any
// client version). Our calls are initialize / tools/list / tools/call, which that revision already defines.
export const VERSIONS=['2025-11-25','2025-06-18','2025-03-26','2024-11-05'];
const MAX_BYTES=32*1024*1024,MAX_LINE=24*1024*1024;
export function canonical(value){if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';return JSON.stringify(value);}
export const schemaHash=tools=>createHash('sha256').update(canonical(tools.map(t=>({name:t.name,inputSchema:t.inputSchema})).sort((a,b)=>a.name<b.name?-1:a.name>b.name?1:0))).digest('hex');
function fail(message){throw Error(message);}
function object(v){return !!v&&typeof v==='object'&&!Array.isArray(v);}
function references(refs){const result=Object.create(null);for(const [key,name]of Object.entries(refs||{})){if(typeof name!=='string'||!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name))fail('invalid_environment_reference');if(process.env[name]===undefined)fail('missing_environment_reference');result[key]=process.env[name];}return result;}
function environment(refs){const env={};for(const [k,v]of Object.entries(process.env))if(/^(PATH|PATHEXT|SYSTEMROOT|WINDIR|SYSTEMDRIVE|COMSPEC|TEMP|TMP|LANG|LC_ALL|HOME|USERPROFILE|LOCALAPPDATA|APPDATA|XDG_CACHE_HOME|XDG_CONFIG_HOME|XDG_DATA_HOME|WASM_AGENT_PROVENANCE|WASM_AGENT_RUN_ID|WASM_AGENT_SESSION_ID|WA_RUN_ID|WA_SESSION_ID)$/i.test(k))env[k]=v;return {...env,...references(refs)};}
function secretPolicy(server){
 const refs={...references(server.env),...references(server.headers)},names=new Set(server.secret_env||[]),values=[];
 for(const [key,value]of Object.entries(refs))if(Object.hasOwn(server.headers||{},key)||names.has(key)||/(?:TOKEN|API.?KEY|SECRET|PASSWORD|AUTH|CREDENTIAL|COOKIE|BEARER|DSN)/i.test(key)){
  if(value.length>=6)values.push(value,value.replace(/^Bearer\s+/i,''));
 }
 const secrets=[...new Set(values.filter(v=>v.length>=6))];let hits=0;
 const contains=value=>typeof value==='string'?secrets.some(secret=>value.includes(secret)):Array.isArray(value)?value.some(contains):object(value)?Object.values(value).some(contains):false;
 const redact=value=>typeof value==='string'?secrets.reduce((text,secret)=>{const parts=text.split(secret);hits+=parts.length-1;return parts.join('[configured MCP credential redacted]');},value):Array.isArray(value)?value.map(redact):object(value)?Object.fromEntries(Object.entries(value).map(([key,item])=>[key,redact(item)])):value;
 return {contains,redact,hits:()=>hits};
}
export function validateServer(server){
 if(!object(server)||!['stdio','http'].includes(server.transport))fail('invalid_mcp_transport');
 if(server.transport==='stdio'){
  if(typeof server.program!=='string'||!server.program||/[\r\n\0]/.test(server.program)||!Array.isArray(server.args)||server.args.some(v=>typeof v!=='string'||v.includes('\0')))fail('invalid_mcp_command');
 }else{
  let url;try{url=new URL(server.url)}catch{fail('invalid_mcp_url')}
  const local=['127.0.0.1','localhost','[::1]'].includes(url.hostname);
  if(url.username||url.password||url.hash||!['http:','https:'].includes(url.protocol)||url.protocol==='http:'&&!local)fail('mcp_url_requires_https_or_loopback');
 }
 if(server.cwd!==undefined&&typeof server.cwd!=='string')fail('invalid_mcp_cwd');
 if(server.timeout_seconds!==undefined&&(!Number.isInteger(server.timeout_seconds)||server.timeout_seconds<1||server.timeout_seconds>86400))fail('invalid_mcp_timeout');
 if(server.secret_env!==undefined&&(!Array.isArray(server.secret_env)||server.secret_env.some(key=>typeof key!=='string'||!Object.hasOwn(server.env||{},key))))fail('invalid_mcp_secret_env_tags');
 return server;
}
function validateMessage(message){
 if(!object(message)||message.jsonrpc!=='2.0')fail('invalid_mcp_jsonrpc');
 if('id'in message&&typeof message.id!=='string'&&typeof message.id!=='number')fail('invalid_mcp_id');
 if('result'in message&&'error'in message)fail('ambiguous_mcp_response');
 if(message.method!==undefined){if(typeof message.method!=='string'||!message.method)fail('invalid_mcp_method');}
 else if(!('id'in message)||!('result'in message)&&!('error'in message))fail('invalid_mcp_response_shape');
 if('error'in message&&(!object(message.error)||!Number.isInteger(message.error.code)||typeof message.error.message!=='string'))fail('invalid_mcp_rpc_error');
 return message;
}
function toolList(value){
 if(!object(value)||!Array.isArray(value.tools))fail('invalid_mcp_tools_list');
 for(const tool of value.tools)if(!object(tool)||typeof tool.name!=='string'||!tool.name||tool.name.length>128||!object(tool.inputSchema)||tool.inputSchema.type!=='object'||tool.description!==undefined&&typeof tool.description!=='string')fail('invalid_mcp_tool_schema');
 return value;
}
async function stdio(server,signal,stats){
 const child=spawn(server.program,server.args,{cwd:server.cwd||undefined,env:environment(server.env),shell:false,windowsHide:true,stdio:['pipe','pipe','pipe']});
 const decoder=new TextDecoder('utf-8',{fatal:true}),pending=new Map();let buffer='',bytes=0,closed=false,fault=null;let stderr='';
 const rejectAll=error=>{for(const slot of pending.values())slot.reject(error);pending.clear();};
 const send=message=>{if(closed||child.stdin.destroyed)fail('mcp_stdio_closed');child.stdin.write(JSON.stringify(message)+'\n');};
 const abort=()=>{rejectAll(Error('mcp_request_timeout_or_cancelled'));child.kill();};signal.addEventListener('abort',abort,{once:true});
 const closedError=()=>fault||Error('mcp_stdio_eof');
 const recordFault=error=>{fault=fault||error;rejectAll(error);};
 child.on('error',recordFault);child.on('close',(code,signal)=>{closed=true;stats.server_exit_code=code;stats.server_signal=signal;rejectAll(closedError());});
 child.stdin.on('error',recordFault);
 child.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString('utf8')).slice(-4096);});
 child.stdout.on('data',chunk=>{try{
  bytes+=chunk.length;if(bytes>MAX_BYTES)fail('mcp_stream_too_large');buffer+=decoder.decode(chunk,{stream:true});
  if(Buffer.byteLength(buffer)>MAX_LINE&&!buffer.includes('\n'))fail('mcp_line_too_large');
  let at;while((at=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,at).replace(/\r$/,'');buffer=buffer.slice(at+1);if(!line.trim())fail('mcp_non_protocol_stdout');if(Buffer.byteLength(line)>MAX_LINE)fail('mcp_line_too_large');const message=validateMessage(JSON.parse(line));
   if(message.method){if('id'in message)send({jsonrpc:'2.0',id:message.id,...(message.method==='ping'?{result:{}}:{error:{code:-32601,message:'Client feature not supported'}})});else {stats.notifications++;if(message.method==='notifications/tools/list_changed'){stats.tools_generation=(stats.tools_generation||0)+1;stats.tools_changed=true;}}continue;}
   const slot=pending.get(message.id);if(!slot)fail('mcp_unmatched_or_duplicate_response');pending.delete(message.id);slot.resolve(message);
  }
 }catch(error){fault=error;rejectAll(error);child.kill();}});
 return {
  async request(method,params){if(fault)throw fault;if(closed)throw closedError();const id=randomUUID();return new Promise((resolve,reject)=>{pending.set(id,{resolve,reject});try{send({jsonrpc:'2.0',id,method,params});}catch(error){pending.delete(id);reject(error);}});},
  async notify(method,params){send({jsonrpc:'2.0',method,params});},
  async close(){
   signal.removeEventListener('abort',abort);
   const waitClosed=async ms=>{if(closed)return;let timer,listener;try{await Promise.race([new Promise(r=>{listener=r;child.once('close',listener);}),new Promise(r=>{timer=setTimeout(r,ms);})]);}finally{clearTimeout(timer);if(listener)child.removeListener('close',listener);}};
   if(!closed){child.stdin.end();await waitClosed(200);if(!closed){child.kill();await waitClosed(1000);}}
   if(!closed)fail('mcp_server_cleanup_unverified');stats.stderr=stderr;if(fault)throw fault;
  },
 };
}
async function http(server,signal,stats){
 const credentials=references(server.headers);for(const k of Object.keys(credentials))if(['host','content-length','mcp-session-id','mcp-protocol-version','accept','content-type'].includes(k.toLowerCase()))fail('reserved_mcp_header');
 let session='',version='',received=0;
 const consume=chunk=>{received+=chunk.length;if(received>MAX_BYTES)fail('mcp_exchange_too_large');};
 async function post(message){
  const headers={...credentials,'Content-Type':'application/json',Accept:'application/json, text/event-stream',...(session?{'Mcp-Session-Id':session}:{}),...(version?{'MCP-Protocol-Version':version}:{})};
  const response=await fetch(server.url,{method:'POST',redirect:'error',headers,body:JSON.stringify(message),signal});
  if(!response.ok)fail('mcp_http_'+response.status);
  const supplied=response.headers.get('mcp-session-id');if(supplied!==null){if(!supplied||! /^[\x21-\x7e]+$/.test(supplied))fail('invalid_mcp_session_id');if(session&&supplied!==session)fail('mcp_session_changed');session=supplied;}
  if(!('id'in message)){if(response.status!==202)fail('mcp_notification_not_accepted');return;}
  const kind=(response.headers.get('content-type')||'').split(';')[0].trim();
  if(kind==='application/json'){
   let raw='',bytes=0;const decoder=new TextDecoder('utf-8',{fatal:true});for await(const chunk of response.body){consume(chunk);bytes+=chunk.length;if(bytes>MAX_BYTES)fail('mcp_response_too_large');raw+=decoder.decode(chunk,{stream:true});}raw+=decoder.decode();const value=validateMessage(JSON.parse(raw));if(value.id!==message.id)fail('mcp_response_id_mismatch');return value;
  }
  if(kind!=='text/event-stream')fail('unsupported_mcp_content_type');
  const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let buffer='',data=[],bytes=0;
  try{while(true){const part=await reader.read();if(part.done)break;consume(part.value);bytes+=part.value.length;if(bytes>MAX_BYTES)fail('mcp_response_too_large');buffer+=decoder.decode(part.value,{stream:true});let at;
   while((at=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,at).replace(/\r$/,'');buffer=buffer.slice(at+1);if(line.startsWith('data:'))data.push(line.slice(5).trimStart());else if(line===''&&data.length){const value=validateMessage(JSON.parse(data.join('\n')));data=[];if(value.method){stats.notifications++;if('id'in value)fail('unsupported_mcp_server_request');}else if(value.id===message.id)return value;else fail('mcp_response_id_mismatch');}}
  }}finally{await reader.cancel().catch(()=>{});}
  fail('mcp_sse_eof_before_response');
 }
 return {request:(method,params)=>post({jsonrpc:'2.0',id:randomUUID(),method,params}),notify:(method,params)=>post({jsonrpc:'2.0',method,params}),setVersion:value=>{version=value;},async close(){if(session){if(signal.aborted)fail('mcp_http_session_cleanup_unverified');const result=await fetch(server.url,{method:'DELETE',redirect:'error',headers:{...credentials,'Mcp-Session-Id':session,'MCP-Protocol-Version':version},signal});if(!result.ok&&result.status!==405)fail('mcp_http_session_cleanup_'+result.status);await result.body?.cancel();}}};
}
function resultOf(reply){if(reply.error){const error=Error('mcp_rpc_error:'+String(reply.error.code)+':'+String(reply.error.message));error.rpc_error=reply.error;throw error;}if(!object(reply.result))fail('invalid_mcp_result');return reply.result;}
// Session connection used only by approved read facades. Writes retain request-scoped settlement.
export async function openMCP(server){
 validateServer(server);const credentials=secretPolicy(server),stats={notifications:0};
 const controller=new AbortController();let timer=setTimeout(()=>controller.abort(),(server.timeout_seconds||30)*1000),transport,metadata,poisoned=false,busy=false;
 async function discover(){
  const generation=stats.tools_generation||0;
  const tools=[],cursors=new Set();let cursor;
  for(let pages=0;pages<32;pages++){
   const page=toolList(resultOf(await transport.request('tools/list',cursor?{cursor}:{})));tools.push(...page.tools);if(tools.length>1000)fail('mcp_tool_count_exceeds_bound');
   if(page.nextCursor===undefined)break;if(typeof page.nextCursor!=='string'||!page.nextCursor||cursors.has(page.nextCursor)||pages===31)fail('invalid_mcp_tools_cursor');cursors.add(page.nextCursor);cursor=page.nextCursor;
  }
  if(new Set(tools.map(t=>t.name)).size!==tools.length)fail('duplicate_mcp_tool_name');
  if(credentials.contains(tools))fail('mcp_metadata_contains_configured_credential');
  stats.tools_changed=(stats.tools_generation||0)!==generation;return tools;
 }
 try{
  transport=server.transport==='stdio'?await stdio(server,controller.signal,stats):await http(server,controller.signal,stats);
  const initialized=resultOf(await transport.request('initialize',{protocolVersion:VERSIONS[0],capabilities:{},clientInfo:{name:'wasm-agent',version:'1'}}));
  if(!VERSIONS.includes(initialized.protocolVersion)||!object(initialized.capabilities)||!object(initialized.serverInfo))fail('unsupported_mcp_initialize');
  if(credentials.contains(initialized.serverInfo))fail('mcp_metadata_contains_configured_credential');
  transport.setVersion?.(initialized.protocolVersion);await transport.notify('notifications/initialized',{});
  const tools=await discover();metadata={protocol_version:initialized.protocolVersion,server_info:initialized.serverInfo,tools:tools.map(t=>({...t,input_schema_json:JSON.stringify(t.inputSchema)})),schema_hash:schemaHash(tools),session_mode:'persistent-read'};
 }catch(error){try{await transport?.close();}catch{}clearTimeout(timer);throw error;}clearTimeout(timer);
 let calls=0;
 return {
  metadata:credentials.redact(metadata),
  async call(input){
   if(poisoned)return {ok:false,error:'mcp_connection_uncertain',outcome:'not_submitted',tool_call_issued:false};
   if(busy)return {ok:false,error:'mcp_connection_busy',outcome:'not_submitted',tool_call_issued:false};
   busy=true;let issued=false,phase='preflight';timer=setTimeout(()=>controller.abort(),(server.timeout_seconds||30)*1000);
   try{
    if(stats.tools_changed){phase='tools/list';const tools=await discover();metadata.tools=tools.map(t=>({...t,input_schema_json:JSON.stringify(t.inputSchema)}));metadata.schema_hash=schemaHash(tools);}
    if(stats.tools_changed)fail('mcp_catalogue_changing');
    const args=input.arguments_json!==undefined?JSON.parse(input.arguments_json):input.arguments||{};
    if(!object(args)||typeof input.tool!=='string')fail('invalid_mcp_action');
    if(input.schema_hash&&input.schema_hash!==metadata.schema_hash)fail('mcp_tool_schemas_changed');
    if(!metadata.tools.some(t=>t.name===input.tool))fail('unknown_mcp_tool');
    phase='tools/call';issued=true;const result=resultOf(await transport.request('tools/call',{name:input.tool,arguments:args}));
    if(!Array.isArray(result.content)||result.isError!==undefined&&typeof result.isError!=='boolean'||result.structuredContent!==undefined&&!object(result.structuredContent))fail('invalid_mcp_tool_result');
    for(const item of result.content)if(!object(item)||typeof item.type!=='string'||item.type==='text'&&typeof item.text!=='string')fail('invalid_mcp_content_block');
    const unsupported_content_types=[...new Set(result.content.filter(item=>item.type!=='text').map(item=>item.type))];
    const answer={ok:result.isError!==true,result,schema_hash:metadata.schema_hash,session_mode:'persistent-read',reused:calls++>0,tool_call_issued:true,...(unsupported_content_types.length?{unsupported_content_types,content_delivery:'raw evidence only; no image/resource materialization'}:{})};
    return credentials.redact(answer);
   }catch(error){if(issued||controller.signal.aborted)poisoned=true;return credentials.redact({ok:false,error:String(error.message||error),phase,tool_call_issued:issued,outcome:issued?'unknown':'not_submitted'});}
   finally{clearTimeout(timer);busy=false;}
  },
  async close(){poisoned=true;timer=setTimeout(()=>controller.abort(),3000);try{await transport.close();}finally{clearTimeout(timer);}},
 };
}
// A JSON-RPC error *reply* is a decision, not an unknown effect: the server parsed the request and
// refused it, so nothing ran. The difference is not cosmetic - the dispatcher holds an "unknown"
// submission durably and refuses that connector for the rest of the process (lua/core/mcp_session.lua
// returns mcp_connection_uncertain), so one wrong argument would cost the session. Measured
// 2026-10-28: `imap_get_message` without `message_id` answered -32602 and wedged a working mailbox.
// Only protocol-level codes qualify; an error raised *inside* a tool arrives as `result.isError`
// and is handled above, never here.
const REJECTION_CODES = new Set([-32700, -32600, -32601, -32602]);
function rpc_rejection(rpc_error) {
  return !!rpc_error && REJECTION_CODES.has(Number(rpc_error.code));
}

export async function requestMCP(input){
 let transport,issued=false,phase='preflight',answer,credentials;const stats={notifications:0};const controller=new AbortController();let timer;
 try{
  const server=validateServer(input.server);credentials=secretPolicy(server);timer=setTimeout(()=>controller.abort(),(server.timeout_seconds||30)*1000);
  transport=server.transport==='stdio'?await stdio(server,controller.signal,stats):await http(server,controller.signal,stats);
  phase='initialize';const initialized=resultOf(await transport.request('initialize',{protocolVersion:VERSIONS[0],capabilities:{},clientInfo:{name:'wasm-agent',version:'1'}}));
  if(!VERSIONS.includes(initialized.protocolVersion)||!object(initialized.capabilities)||!object(initialized.serverInfo))fail('unsupported_mcp_initialize');
  transport.setVersion?.(initialized.protocolVersion);await transport.notify('notifications/initialized',{});
  phase='tools/list';const tools=[],cursors=new Set();let cursor;
  for(let pages=0;pages<32;pages++){
   const page=toolList(resultOf(await transport.request('tools/list',cursor?{cursor}:{})));tools.push(...page.tools);if(tools.length>1000)fail('mcp_tool_count_exceeds_bound');
   if(page.nextCursor===undefined)break;if(typeof page.nextCursor!=='string'||!page.nextCursor||cursors.has(page.nextCursor)||pages===31)fail('invalid_mcp_tools_cursor');cursors.add(page.nextCursor);cursor=page.nextCursor;
  }
  if(new Set(tools.map(t=>t.name)).size!==tools.length)fail('duplicate_mcp_tool_name');
  if(credentials.contains(tools)||credentials.contains(initialized.serverInfo))fail('mcp_metadata_contains_configured_credential');
  const schema_hash=schemaHash(tools),metadata={protocol_version:initialized.protocolVersion,server_info:initialized.serverInfo,tools:tools.map(tool=>({...tool,input_schema_json:JSON.stringify(tool.inputSchema)})),schema_hash,session_mode:'request',notifications:stats.notifications};
  if(input.action==='probe')answer={ok:true,...metadata,tool_call_issued:false};
  else {
  const args=input.arguments_json!==undefined?JSON.parse(input.arguments_json):input.arguments||{};
  if(input.action!=='call'||typeof input.tool!=='string'||!object(args))fail('invalid_mcp_action');
  if(input.schema_hash&&input.schema_hash!==schema_hash)fail('mcp_tool_schemas_changed');
  if(!tools.some(t=>t.name===input.tool))fail('unknown_mcp_tool');
  phase='tools/call';issued=true;const result=resultOf(await transport.request('tools/call',{name:input.tool,arguments:args}));
  if(!Array.isArray(result.content)||result.isError!==undefined&&typeof result.isError!=='boolean'||result.structuredContent!==undefined&&!object(result.structuredContent))fail('invalid_mcp_tool_result');
  for(const item of result.content)if(!object(item)||typeof item.type!=='string'||item.type==='text'&&typeof item.text!=='string')fail('invalid_mcp_content_block');
  const unsupported_content_types=[...new Set(result.content.filter(item=>!object(item)||item.type!=='text').map(item=>item?.type||'invalid'))];
  answer={ok:result.isError!==true,result,...metadata,tool_call_issued:true,...(unsupported_content_types.length?{unsupported_content_types,content_delivery:'raw evidence only; no image/resource materialization'}:{})};
  }
 }catch(error){const rejected=rpc_rejection(error.rpc_error);answer={ok:false,error:String(error.message||error),rpc_error:error.rpc_error,phase,tool_call_issued:issued&&!rejected,outcome:(issued&&!rejected)?'unknown':'not_submitted'};}
 finally{if(transport)try{await transport.close();}catch(error){answer={...answer,ok:false,error:'mcp_cleanup_failed:'+String(error.message||error),tool_call_issued:issued,outcome:issued?'unknown':'not_submitted'};}clearTimeout(timer);}
 if(answer.ok===false&&stats.stderr)answer.server_stderr_tail=stats.stderr;
 if(stats.server_exit_code!==undefined)answer.server_exit_code=stats.server_exit_code;
 if(stats.server_signal)answer.server_signal=stats.server_signal;
 if(credentials){answer=credentials.redact(answer);if(credentials.hits())answer.configured_credential_redactions=credentials.hits();}
 return answer;
}
