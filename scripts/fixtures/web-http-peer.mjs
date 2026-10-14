import {serveMCP} from '../mcp-server-core.mjs';
import {createWebAdapter,WEB_TOOLS} from '../web-core.mjs';
import {appendFileSync} from 'node:fs';
const at=process.argv.indexOf('--binding-json'),binding=JSON.parse(process.argv[at+1]);
const adapter=createWebAdapter({cacheDir:binding.cache_dir,fetch:async url=>{
 appendFileSync(binding.cache_dir+'/http-calls.jsonl',JSON.stringify({url})+'\n');
 let status=200,body='FINAL_ASYNC_RESULT',headers={'content-type':'text/plain'};
 if(url.endsWith('/challenge')){status=202;body='<form id="challenge-form">human required</form>';headers['content-type']='text/html';}
 if(url.endsWith('/start')){status=202;body='accepted';headers.location='/monitor';}
 return {url,status,headers,bytes:Buffer.from(body)};
}});
serveMCP({name:'private-web-http',tools:WEB_TOOLS,call:(name,args)=>adapter[name](args)});
