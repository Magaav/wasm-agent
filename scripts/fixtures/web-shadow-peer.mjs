// Same read-only backend for all three shadow arms. No Internet/model/app actions.
import {readFileSync,appendFileSync,mkdirSync} from 'node:fs';
import {serveMCP} from '../mcp-server-core.mjs';import {createWebAdapter,WEB_TOOLS} from '../web-core.mjs';
const at=process.argv.indexOf('--binding-json'),binding=JSON.parse(process.argv[at+1]);mkdirSync(binding.cache_dir,{recursive:true});
const fixture=JSON.parse(readFileSync(new URL('../../benchmarks/web-envelope/simple.json',import.meta.url),'utf8')),log=binding.cache_dir+'/protocol.jsonl';
let buffer='';process.stdin.on('data',b=>{buffer+=b.toString('utf8');let i;while((i=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,i);buffer=buffer.slice(i+1);const m=JSON.parse(line);appendFileSync(log,JSON.stringify({pid:process.pid,method:m.method})+'\n');}});
const rss='<rss><channel>'+fixture.sources.map(s=>'<item><title>'+s.title+'</title><link>'+s.url+'</link><description>Short protocol reference</description></item>').join('')+'</channel></rss>';
const api=createWebAdapter({cacheDir:binding.cache_dir,searchURL:q=>'https://www.bing.com/search?format=rss&q='+encodeURIComponent(q),clock:()=>fixture.clock,fetch:async url=>{appendFileSync(binding.cache_dir+'/fetch.jsonl',JSON.stringify({url})+'\n');const source=fixture.sources.find(s=>s.url===url);if(!source&&!url.startsWith('https://www.bing.com/search?'))throw Error('fixture_unknown_url');return {status:200,url,headers:{'content-type':source?'text/html':'application/rss+xml'},bytes:Buffer.from(source?source.html:rss)};}});
serveMCP({name:'web-shadow-fixture',tools:WEB_TOOLS,call:(name,args)=>api[name](args)});
