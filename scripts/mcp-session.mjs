// Owned, idle-bounded read session. No inference, subscriptions, reconnect or tool replay.
import {createServer} from 'node:http';
import {readFileSync,writeFileSync} from 'node:fs';
import {dirname,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {openMCP,canonical} from './mcp-client-core.mjs';
const at=process.argv.indexOf('--seed-file');if(at<0||!process.argv[at+1])throw Error('mcp_seed_file_required');
const seed=JSON.parse(readFileSync(process.argv[at+1],'utf8'));
for(const [key,expected]of Object.entries(seed.credential_hashes||{})){const [field,name]=key.split(':');const variable=seed.server[field]?.[name];if(createHash('sha256').update(process.env[variable]??'<missing>').digest('hex')!==expected)throw Error('mcp_environment_reference_changed');}
if(typeof seed.token!=='string'||seed.token.length<48||!Array.isArray(seed.read_tools)||seed.read_tools.length===0)throw Error('invalid_mcp_read_session');
const connection=await openMCP(seed.server),allowed=new Set(seed.read_tools),requests=new Set();let busy=false,closing=false,idle;
const digest=b=>createHash('sha256').update(b).digest('hex');
const server=createServer(async(req,res)=>{
 const reply=(code,value)=>{res.writeHead(code,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
 if(req.headers.origin||req.headers['x-wa-mcp-token']!==seed.token)return reply(403,{error:'forbidden'});
 if(req.url!=='/call'||req.method!=='POST')return reply(404,{error:'not_found'});
 if(closing||busy)return reply(409,{ok:false,error:'mcp_connection_busy',tool_call_issued:false,outcome:'not_submitted'});
 busy=true;clearTimeout(idle);let input,submitted=false;
 try{let size=0;const chunks=[];for await(const b of req){size+=b.length;if(size>1024*1024)throw Error('mcp_request_too_large');chunks.push(b);}input=JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if(typeof input.request_id!=='string'||!/^[-a-f0-9]{36}$/.test(input.request_id)||requests.has(input.request_id))throw Error('mcp_request_id_reused');
  if(!allowed.has(input.tool)||canonical(input.server)!==canonical(seed.server))throw Error('mcp_tool_not_approved_for_session');
  const resultPath=resolve(input.result_file||'');if(dirname(resultPath)!==resolve(seed.request_dir)||!resultPath.endsWith('.result.json'))throw Error('mcp_result_path_refused');
  requests.add(input.request_id);if(requests.size>1000)throw Error('mcp_session_request_bound');
  writeFileSync(resultPath+'.dispatch.json',JSON.stringify({request_id:input.request_id,tool:input.tool,state:'dispatching'}),{flag:'wx',mode:0o600});
  submitted=true;const result=await connection.call(input),envelope={...result,request_id:input.request_id};if(result.result){envelope.result_json=JSON.stringify(result.result);delete envelope.result;}
  const raw=Buffer.from(JSON.stringify(envelope));if(raw.length>80*1024*1024)throw Error('mcp_result_artifact_too_large');
  writeFileSync(resultPath,raw,{flag:'wx',mode:0o600});
  reply(200,{ok:result.ok,request_id:input.request_id,result_path:resultPath,result_bytes:raw.length,result_sha256:digest(raw),tool_call_issued:result.tool_call_issued,outcome:result.outcome});
 }catch(error){reply(400,{ok:false,error:String(error.message||error),tool_call_issued:submitted,outcome:submitted?'unknown':'not_submitted'});}
 finally{if(busy){busy=false;armIdle();}}
});
async function close(){if(closing)return;closing=true;clearTimeout(idle);server.close();try{await connection.close();}catch(error){console.error('mcp_session_cleanup_failed:'+String(error.message));process.exitCode=1;}}
function armIdle(){idle=setTimeout(()=>{if(!busy)void close();},seed.idle_ms||30000);}
await new Promise((done,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',done);});
writeFileSync(seed.ready_file,JSON.stringify({url:'http://127.0.0.1:'+server.address().port,token:seed.token,metadata:connection.metadata}),{flag:'wx',mode:0o600});armIdle();
process.on('SIGTERM',()=>void close());process.on('SIGINT',()=>void close());
