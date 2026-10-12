// Disposable protocol peer; no app, inference or external side effects.
import {appendFileSync} from 'node:fs';
let ready=false,buffer='';const mode=process.env.MCP_TEST_MODE||'normal';
const tools=[{name:'echo',description:'Fixture echo',inputSchema:{type:'object',properties:{value:{}},required:[]}}];
if(mode==='leak_meta')tools[0].description=process.env.TOKEN;
if(mode==='changed')tools[0].inputSchema.properties.changed={type:'boolean'};
const send=value=>{const line=JSON.stringify(value)+'\n';process.stdout.write(line);if(mode==='duplicate')process.stdout.write(line);};
process.stdin.on('data',chunk=>{buffer+=chunk.toString();let at;while((at=buffer.indexOf('\n'))>=0){const message=JSON.parse(buffer.slice(0,at));buffer=buffer.slice(at+1);
 if(message.method==='notifications/initialized'){ready=true;continue;}
 if(!('id' in message))continue;
 if(mode==='malformed'){process.stdout.write('not JSON\n');continue;}
 if(message.method==='initialize'){send({jsonrpc:'2.0',id:message.id,result:{protocolVersion:mode==='bad_version'?'future':message.params.protocolVersion,capabilities:{tools:{}},serverInfo:{name:'fixture',version:'1'}}});continue;}
 if(!ready){send({jsonrpc:'2.0',id:message.id,error:{code:-32000,message:'not initialized'}});continue;}
 if(message.method==='tools/list'){send({jsonrpc:'2.0',id:message.id,result:{tools}});continue;}
 if(message.method==='tools/call'){
  if(process.env.MCP_TEST_LOG)appendFileSync(process.env.MCP_TEST_LOG,JSON.stringify(message)+'\n');
  if(mode==='hang_call'){setTimeout(()=>{},10000);continue;}
  if(mode==='eof_call'){process.exit(0);}
  const argumentsValue=mode==='leak_result'?{credential:process.env.TOKEN}:message.params.arguments;
  send({jsonrpc:'2.0',id:mode==='wrong_id'?'wrong':message.id,result:{content:mode==='bad_content'?[{type:'text'}]:[{type:'text',text:JSON.stringify(argumentsValue)}],structuredContent:argumentsValue}});
 }
}});
