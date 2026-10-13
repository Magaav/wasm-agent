import {serveMCP} from './mcp-server-core.mjs';
import {createWebAdapter,WEB_TOOLS} from './web-core.mjs';
const at=process.argv.indexOf('--binding-json');if(at<0||!process.argv[at+1])throw Error('web_binding_required');
const binding=JSON.parse(process.argv[at+1]),adapter=createWebAdapter({cacheDir:binding.cache_dir});
serveMCP({name:'wasm-agent-web',tools:WEB_TOOLS,call:(name,args)=>adapter[name](args)});
