// Read-only compatibility entrypoint, linked-device MCP only.
import {callApp,readBinding} from './whatsapp-mcp-client.mjs';
const args=process.argv.slice(2);const arg=name=>{const at=args.indexOf(name);return at<0?undefined:args[at+1]};
if(args.some(a=>['--raw-store','--mcp-backend','--port','--expect-browser-endpoint'].includes(a))){console.log(JSON.stringify({ok:false,error:'browser_whatsapp_retired'}));process.exitCode=1;}else{
 try{const data=await callApp('read_snapshot',{since:Number(arg('--since')||0),before:Number(arg('--before')||0),limit:Number(arg('--limit')||2000)},readBinding({profile_file:arg('--profile-file')}));console.log(JSON.stringify(data));if(!data.ok)process.exitCode=1;}catch{console.log(JSON.stringify({ok:false,error:'linked_device_read_failed'}));process.exitCode=1;}
}
