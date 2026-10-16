import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdtempSync,readFileSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {requestMCP,schemaHash,validateServer} from './mcp-client-core.mjs';
const peer=fileURLToPath(new URL('./fixtures/mcp-peer.mjs',import.meta.url));
function stdio(mode='normal',extra={}){process.env.MCP_TEST_MODE=mode;return {transport:'stdio',program:process.execPath,args:[peer],env:{MCP_TEST_MODE:'MCP_TEST_MODE',...extra},timeout_seconds:3};}
const invoke=(server,extra={})=>requestMCP({action:'call',tool:'echo',server,arguments:{},...extra});
test('real stdio lifecycle, exact object/array/null arguments, deterministic schema identity',async()=>{
 const server=stdio(),probe=await requestMCP({action:'probe',server});assert.equal(probe.ok,true);assert.equal(probe.tool_call_issued,false);assert.equal(probe.tools[0].input_schema_json,JSON.stringify(probe.tools[0].inputSchema));
 const args={empty:{},array:[],nested:[null,{},[]]},result=await invoke(server,{schema_hash:probe.schema_hash,arguments_json:JSON.stringify(args)});assert.equal(result.ok,true);assert.deepEqual(result.result.structuredContent,args);assert.equal(schemaHash(probe.tools),probe.schema_hash);
});
test('changed schemas and malformed argument roots refuse before a call',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'mcp-schema-'));process.env.MCP_TEST_LOG=join(dir,'effects');let server=stdio('normal',{MCP_TEST_LOG:'MCP_TEST_LOG'});const probe=await requestMCP({action:'probe',server});
 server=stdio('changed',{MCP_TEST_LOG:'MCP_TEST_LOG'});const changed=await invoke(server,{schema_hash:probe.schema_hash});assert.equal(changed.error,'mcp_tool_schemas_changed');assert.equal(changed.tool_call_issued,false);assert.equal(existsSync(process.env.MCP_TEST_LOG),false);
 const root=await invoke(server,{arguments_json:'[]'});assert.equal(root.tool_call_issued,false);assert.equal(existsSync(process.env.MCP_TEST_LOG),false);
});
for(const mode of ['malformed','duplicate','bad_version'])test('protocol '+mode+' cannot become a successful probe',async()=>{const result=await requestMCP({action:'probe',server:stdio(mode)});assert.equal(result.ok,false);assert.equal(result.tool_call_issued,false);});
for(const mode of ['wrong_id','eof_call','hang_call'])test('post-call '+mode+' stays unknown and is not replayed',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'mcp-once-'));process.env.MCP_TEST_LOG=join(dir,'effects');const server={...stdio(mode,{MCP_TEST_LOG:'MCP_TEST_LOG'}),timeout_seconds:1};const result=await invoke(server);
 assert.equal(result.ok,false);assert.equal(result.outcome,'unknown');assert.equal(result.tool_call_issued,true);assert.equal(readFileSync(process.env.MCP_TEST_LOG,'utf8').trim().split('\n').length,1);
});
test('credential references, HTTPS/loopback policy and unsupported transports',async()=>{
 const result=await requestMCP({action:'probe',server:{...stdio(),env:{TOKEN:'MCP_MISSING_TEST_SECRET'}}});assert.match(result.error,/missing_environment_reference/);assert.equal(result.tool_call_issued,false);
 assert.throws(()=>validateServer({transport:'http',url:'http://outside.example/mcp'}),/https_or_loopback/);assert.throws(()=>validateServer({transport:'http',url:'https://user:pass@example.com/mcp'}));assert.throws(()=>validateServer({transport:'legacy-sse'}));
});
test('real Streamable HTTP SSE, pagination, negotiated headers and explicit session cleanup',async()=>{
 const seen=[];const tool={name:'echo',inputSchema:{type:'object',properties:{}}};process.env.MCP_TEST_TOKEN='fixture-secret';
 const server=createServer(async(req,res)=>{
  seen.push({method:req.method,headers:req.headers});if(req.method==='DELETE'){res.writeHead(204);res.end();return;}
  let body='';for await(const chunk of req)body+=chunk;const m=JSON.parse(body);
  if(!('id'in m)){res.writeHead(202);res.end();return;}
  let result;if(m.method==='initialize'){res.setHeader('Mcp-Session-Id','private-session');result={protocolVersion:'2025-06-18',capabilities:{tools:{}},serverInfo:{name:'http',version:'1'}};}
  else if(m.method==='tools/list')result=m.params.cursor?{tools:[tool]}:{tools:[],nextCursor:'next'};
  else result={content:[{type:'text',text:'done'}],structuredContent:m.params.arguments};
  res.writeHead(200,{'Content-Type':'text/event-stream'});res.end(': keepalive\n\ndata: '+JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\n\n');
 });await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try{const result=await invoke({transport:'http',url:`http://127.0.0.1:${server.address().port}/mcp`,headers:{Authorization:'MCP_TEST_TOKEN'},timeout_seconds:2});assert.equal(result.ok,true);assert.equal(result.protocol_version,'2025-06-18');assert.equal(seen.at(-1).method,'DELETE');for(const request of seen.slice(1)){assert.equal(request.headers['mcp-session-id'],'private-session');assert.equal(request.headers['mcp-protocol-version'],'2025-06-18');assert.equal(request.headers.authorization,'fixture-secret');}}
 finally{server.closeAllConnections();await new Promise(r=>server.close(r));}
});
// Linked-device account/scope/media/send-retirement negatives are in test-mcp-whatsapp.mjs.
test('configured credentials never enter probe metadata or returned data',async()=>{
 process.env.MCP_TEST_TOKEN='private-fixture-credential';
 const leaked=await requestMCP({action:'probe',server:stdio('leak_meta',{TOKEN:'MCP_TEST_TOKEN'})});assert.equal(leaked.ok,false);assert.equal(leaked.tool_call_issued,false);assert.equal(leaked.error,'mcp_metadata_contains_configured_credential');assert.equal(JSON.stringify(leaked).includes(process.env.MCP_TEST_TOKEN),false);
 const result=await invoke(stdio('leak_result',{TOKEN:'MCP_TEST_TOKEN'}));assert.equal(result.ok,true);assert.ok(result.configured_credential_redactions>=1);assert.equal(JSON.stringify(result).includes(process.env.MCP_TEST_TOKEN),false);
 const invalid=await invoke(stdio('bad_content'));assert.equal(invalid.ok,false);assert.equal(invalid.outcome,'unknown');
});
