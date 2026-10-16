// Lookup compatibility only. No UI/store send or browser fallback.
import {callApp,readBinding} from './whatsapp-mcp-client.mjs';
if(process.argv.some(a=>['--send','--rehearse','--port','--expect-browser-endpoint'].includes(a))){console.log(JSON.stringify({ok:false,error:'browser_whatsapp_retired',pre_dispatch:true}));process.exitCode=1;}else{try{const data=await callApp('lookup_self',{},readBinding());console.log(JSON.stringify(data));if(!data.ok)process.exitCode=1;}catch{console.log(JSON.stringify({ok:false,error:'linked_device_lookup_failed'}));process.exitCode=1;}}
