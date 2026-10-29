// Read-only WhatsApp reads through the linked-device MCP. Credentials stay in files.
import {callApp,readBinding} from './whatsapp-mcp-client.mjs';
const args=process.argv.slice(2);
const values=new Set(['--profile-file','--row','--resource','--field','--version','--offset','--length','--since','--sent-since','--until','--before','--limit','--chat','--query']);
const flags=new Set(['--list-chats','--refresh-names']);
try {
 const opts={};
 for(let i=0;i<args.length;i++) {
  const key=args[i];
  if(flags.has(key)){opts[key]=true;continue;}
  if(!values.has(key)||i+1>=args.length||args[i+1].startsWith('--')||key in opts)throw Error('invalid_argument');
  opts[key]=args[++i];
 }
 const field=opts['--row']!==undefined;
 const method=field?'read_field':opts['--list-chats']?'list_chats':'read_snapshot';
 const request=field?{resource:opts['--resource']||'read_snapshot',row:Number(opts['--row']),field:opts['--field'],version:opts['--version'],offset:Number(opts['--offset']||0),length:Number(opts['--length']||16384)}:
  {before:Number(opts['--before']||0),limit:Number(opts['--limit']||(opts['--refresh-names']?32:200)),...(opts['--refresh-names']?{refresh_names:true}:{}),...(opts['--chat']?{conversation_id:opts['--chat']}:{}),...(opts['--query']!==undefined?{query:opts['--query']}:{}),...(method==='read_snapshot'?{since:Number(opts['--since']||0),sent_since:Number(opts['--sent-since']||0),until:Number(opts['--until']||0)}:{})};
 if(opts['--chat']&&!['read_snapshot','list_chats'].includes(method))throw Error('chat_requires_context_page');
 if(opts['--refresh-names']&&method!=='list_chats')throw Error('refresh_requires_list_chats');
 const data=await callApp(method,request,readBinding({profile_file:opts['--profile-file']}));
 // Preserve wire order/cursors verbatim; this small index provides chronological
 // presentation of inline rows in this bounded page, not all-history ordering.
 if(data.ok&&method==='read_snapshot')data.chronological_inline_cursors=[...(data.messages||[])].sort((a,b)=>a.sent_at-b.sent_at||a.cursor-b.cursor).map(m=>m.cursor);
 console.log(JSON.stringify(data));if(!data.ok)process.exitCode=1;
} catch {console.log(JSON.stringify({ok:false,error:'linked_device_read_failed'}));process.exitCode=1;}
