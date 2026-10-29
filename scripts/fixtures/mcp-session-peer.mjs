// Private protocol fixture: no network/app. Optional notified schema change or EOF.
import readline from 'node:readline';import {appendFileSync} from 'node:fs';
const at=name=>process.argv[process.argv.indexOf(name)+1],log=process.argv.includes('--log')?at('--log'):null,mode=process.argv.includes('--mode')?at('--mode'):'normal';let changed=false;
const send=value=>process.stdout.write(JSON.stringify(value)+'\n');
const tools=()=>[{name:'echo',description:'Echo exact JSON',inputSchema:{type:'object',properties:{value:{},...(changed?{revision:{type:'string'}}:{})}}}];
for await(const line of readline.createInterface({input:process.stdin})){const m=JSON.parse(line);if(log)appendFileSync(log,JSON.stringify({pid:process.pid,method:m.method})+'\n');
 if(m.method==='notifications/initialized')continue;
 if(m.method==='initialize')send({jsonrpc:'2.0',id:m.id,result:{protocolVersion:m.params.protocolVersion,capabilities:{tools:{listChanged:true}},serverInfo:{name:'private-session-fixture',version:'1'}}});
 else if(m.method==='tools/list')send({jsonrpc:'2.0',id:m.id,result:{tools:tools()}});
 else if(m.method==='tools/call'){
  if(mode==='eof'){process.exit(0);}
  // The change is notified before the answer: sent after it, a slow host (openclaw, 29/10) let the client
  // issue the second call before it had read the notification, and the 'notified' case raced.
  if(mode==='change'&&!changed){changed=true;send({jsonrpc:'2.0',method:'notifications/tools/list_changed'});}
  send({jsonrpc:'2.0',id:m.id,result:{content:[{type:'text',text:JSON.stringify(m.params.arguments)}],structuredContent:m.params.arguments}});
 }
}
