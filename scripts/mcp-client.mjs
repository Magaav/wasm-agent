// Native-operation entrypoint. Large replies stay exact in a retained artifact.
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {requestMCP} from './mcp-client-core.mjs';
export async function main(argv=process.argv.slice(2)){
 const at=argv.indexOf('--request-file');if(at<0||!argv[at+1])throw Error('mcp_request_file_required');
 const bytes=readFileSync(argv[at+1]);if(bytes.length>1024*1024)throw Error('mcp_request_too_large');
 const input=JSON.parse(bytes.toString('utf8'));const result=await requestMCP(input);
 const envelope={...result};if(result.result){envelope.result_json=JSON.stringify(result.result);delete envelope.result;}
 if(input.result_file){
  const raw=Buffer.from(JSON.stringify(envelope));
  try{if(raw.length>80*1024*1024)throw Error('mcp_result_artifact_too_large');writeFileSync(input.result_file,raw,{mode:0o600,flag:'wx'});}catch(error){console.log(JSON.stringify({ok:false,error:'mcp_result_artifact_not_written',tool_call_issued:result.tool_call_issued,outcome:result.tool_call_issued?'unknown':'not_submitted'}));return;}
  console.log(JSON.stringify({ok:result.ok,result_path:input.result_file,result_sha256:createHash('sha256').update(raw).digest('hex'),result_bytes:raw.length,tool_call_issued:result.tool_call_issued,outcome:result.outcome}));
 }else console.log(JSON.stringify(envelope));return result;
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href)main().catch(error=>{console.log(JSON.stringify({ok:false,error:String(error.message||error),tool_call_issued:false,outcome:'not_submitted'}));process.exitCode=1;});
