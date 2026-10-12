// Small interoperable stdio MCP server shell. Handlers own app semantics.
import { TextDecoder } from 'node:util';
export function serveMCP({name,version='1',tools,call}){
 let initialized=false,ready=false,buffer='',bytes=0;const decoder=new TextDecoder('utf-8',{fatal:true});let tail=Promise.resolve();
 const send=value=>process.stdout.write(JSON.stringify(value)+'\n');
 const error=(id,code,message)=>send({jsonrpc:'2.0',id,error:{code,message}});
 async function handle(message){
  if(!message||typeof message!=='object'||Array.isArray(message)||message.jsonrpc!=='2.0'){error(message?.id??null,-32600,'Invalid Request');return;}
  if(message.method==='notifications/initialized'){if(initialized)ready=true;return;}
  if(message.method==='notifications/cancelled')return;
  if(!('id'in message))return;
  if(message.method==='initialize'){
   if(initialized){error(message.id,-32600,'Already initialized');return;}
   const protocol=message.params?.protocolVersion;
   if(!['2025-11-25','2025-06-18','2024-11-05'].includes(protocol)){error(message.id,-32602,'Unsupported protocol');return;}
   initialized=true;send({jsonrpc:'2.0',id:message.id,result:{protocolVersion:protocol,capabilities:{tools:{}},serverInfo:{name,version}}});return;
  }
  if(message.method==='ping'){send({jsonrpc:'2.0',id:message.id,result:{}});return;}
  if(!ready){error(message.id,-32000,'Initialize first');return;}
  if(message.method==='tools/list'){send({jsonrpc:'2.0',id:message.id,result:{tools}});return;}
  if(message.method!=='tools/call'){error(message.id,-32601,'Method not found');return;}
  const tool=tools.find(t=>t.name===message.params?.name);
  if(!tool){error(message.id,-32602,'Unknown tool');return;}
  try{const data=await call(tool.name,message.params.arguments||{});send({jsonrpc:'2.0',id:message.id,result:{content:[{type:'text',text:JSON.stringify(data)}],structuredContent:data,isError:data?.ok===false}});}
  catch(failure){send({jsonrpc:'2.0',id:message.id,result:{content:[{type:'text',text:JSON.stringify({ok:false,error:String(failure.message||failure)})}],structuredContent:{ok:false,error:String(failure.message||failure)},isError:true}});}
 }
 process.stdin.on('data',chunk=>{try{bytes+=chunk.length;if(bytes>4*1024*1024)throw Error('mcp_input_too_large');buffer+=decoder.decode(chunk,{stream:true});let at;
  while((at=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,at);buffer=buffer.slice(at+1);if(Buffer.byteLength(line)>1024*1024)throw Error('mcp_line_too_large');let value;try{value=JSON.parse(line)}catch{error(null,-32700,'Parse error');continue;}tail=tail.then(()=>handle(value)).catch(e=>{console.error(String(e));process.exitCode=1;});}
 }catch(e){console.error(String(e));process.exitCode=1;process.stdin.destroy();}});
 process.stdin.on('end',()=>{tail.finally(()=>{if(buffer.trim())console.error('mcp_unterminated_message');});});
}
