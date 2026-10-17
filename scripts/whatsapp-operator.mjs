// Dedicated owner-capability CLI. Not registered as generic MCP or a child tool.
// One request, no retries, no credential values in argv or output.
import {readFileSync,lstatSync} from 'node:fs';
import {isAbsolute} from 'node:path';
import {pathToFileURL} from 'node:url';
import {connectorRequest} from './mcp-whatsapp.mjs';
export function operatorConfig(path,action){
 if(!isAbsolute(path))throw Error('operator_absolute_authority_file_required');
 const info=lstatSync(path);if(!info.isFile()||info.isSymbolicLink()||info.size>65536||(process.platform!=='win32'&&(info.mode&0o077)))throw Error('operator_private_authority_file_required');
 const config=JSON.parse(readFileSync(path,'utf8'));
 if(config.kind!=='whatsapp-operator-v1'||!config.account||!Number.isSafeInteger(config.generation)||config.generation<1||!Array.isArray(config.conversations)||!config.conversations.length||config.conversations.length>256)throw Error('operator_authority_configuration_required');
 const token_file=action==='approve'?config.approval_token_file:config.dispatch_token_file;
 if(typeof token_file!=='string'||!isAbsolute(token_file))throw Error('operator_separate_capability_file_required');
 const key=lstatSync(token_file);if(!key.isFile()||key.isSymbolicLink()||key.size!==64||(process.platform!=='win32'&&(key.mode&0o077)))throw Error('operator_private_capability_file_required');
 return {...config,backend:'linked_device',token_file,allowed_conversations:config.conversations};
}
export async function operatorCall(config,action,request){
 if(!['prepare','approve','send','status'].includes(action))throw Error('operator_action_unsupported');
 const common=['conversation_id'];const fields=action==='prepare'?[...common,'body','reply_to']:action==='approve'?[...common,'body','reply_to','intent_id','approval_digest']:[...common,'intent_id'];
 if(!request||typeof request!=='object'||Array.isArray(request)||Object.keys(request).some(key=>!fields.includes(key)))throw Error('operator_request_fields_invalid');
 if(!config.conversations.includes(request.conversation_id))throw Error('operator_conversation_not_provisioned');
 if(['prepare','approve'].includes(action)&&(typeof request.body!=='string'||!request.body.trim()||Buffer.byteLength(request.body)>4096||Buffer.from(request.body,'utf8').toString('utf8')!==request.body))throw Error('operator_exact_text_required');
 if(action!=='prepare'&&(!/^[0-9a-f]{64}$/.test(request.intent_id??'')))throw Error('operator_intent_id_required');
 if(action==='approve'&&!/^[0-9a-f]{64}$/.test(request.approval_digest??''))throw Error('operator_exact_approval_digest_required');
 // Only references are configured. Account/generation cannot come from a request.
 return await connectorRequest(config,'operator/'+action,request);
}
export async function main(argv=process.argv.slice(2)){
 const [action,profileFlag,profile,requestFlag,path,...rest]=argv;
 if(profileFlag!=='--authority-file'||requestFlag!=='--request-file'||rest.length||!isAbsolute(path??''))throw Error('usage: whatsapp-operator.mjs prepare|approve|send|status --authority-file ABSOLUTE_PRIVATE_CONFIG --request-file ABSOLUTE_PRIVATE_JSON');
 const config=operatorConfig(profile,action),info=lstatSync(path);
 if(!info.isFile()||info.isSymbolicLink()||info.size>32768)throw Error('operator_bounded_request_file_required');
 const result=await operatorCall(config,action,JSON.parse(readFileSync(path,'utf8')));
 console.log(JSON.stringify(result));if(result.ok!==true)process.exitCode=1;
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href)main().catch(()=>{console.error('operator_request_failed_no_replay_inspect_exact_intent_status');process.exitCode=1;});
