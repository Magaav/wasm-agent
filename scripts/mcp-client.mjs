// Native-operation entrypoint. Large replies stay exact in a retained artifact.
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {requestMCP} from './mcp-client-core.mjs';
// The kernel read this file, checked the "server" inside it against the operator's approval, and handed
// this process the sha256 of THAT read (WA_MCP_REQUEST_SHA256, WA_MCP_REQUEST_FILE). Reading the file once
// and hashing those same bytes is what closes the window between its check and this spawn: a file
// rewritten in between - "server.program" swapped for another program, which would inherit the vault
// values in this environment - is refused here, before anything is spawned (round 5, docs/VAULT.md).
function sealedRequest(path){
 const expected=process.env.WA_MCP_REQUEST_SHA256;
 if(!expected)throw Error('mcp_request_not_approved');
 if(process.env.WA_MCP_REQUEST_FILE!==path)throw Error('mcp_request_path_mismatch');
 const bytes=readFileSync(path);if(bytes.length>1024*1024)throw Error('mcp_request_too_large');
 if(createHash('sha256').update(bytes).digest('hex')!==expected)throw Error('mcp_request_changed_since_approval');
 return bytes;
}
export async function main(argv=process.argv.slice(2)){
 const at=argv.indexOf('--request-file');if(at<0||!argv[at+1])throw Error('mcp_request_file_required');
 const bytes=sealedRequest(argv[at+1]);
 const input=JSON.parse(bytes.toString('utf8'));const result=await requestMCP(input);
 const envelope={...result};if(result.result){envelope.result_json=JSON.stringify(result.result);delete envelope.result;}
 if(input.result_file){
  const raw=Buffer.from(JSON.stringify(envelope));
  try{if(raw.length>80*1024*1024)throw Error('mcp_result_artifact_too_large');writeFileSync(input.result_file,raw,{mode:0o600,flag:'wx'});}catch(error){console.log(JSON.stringify({ok:false,error:'mcp_result_artifact_not_written',tool_call_issued:result.tool_call_issued,outcome:result.tool_call_issued?'unknown':'not_submitted'}));return;}
  console.log(JSON.stringify({ok:result.ok,result_path:input.result_file,result_sha256:createHash('sha256').update(raw).digest('hex'),result_bytes:raw.length,tool_call_issued:result.tool_call_issued,outcome:result.outcome}));
 }else console.log(JSON.stringify(envelope));return result;
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href)main().catch(error=>{console.log(JSON.stringify({ok:false,error:String(error.message||error),tool_call_issued:false,outcome:'not_submitted'}));process.exitCode=1;});
